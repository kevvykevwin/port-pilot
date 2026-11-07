#!/usr/bin/env python3
"""Publication audit for PortPilot (python3 stdlib only, no network).

Audits an exact publication candidate described by a manifest, binds the result
to a manual privacy review, and writes a receipt only when everything passes.

  audit-publication.py --manifest M --manual-review R --receipt X
  audit-publication.py --verify-receipt --manifest M --manual-review R --receipt X
  audit-publication.py --print-manifest-template --repo PATH --rev REV
                       [--ref NAME ...] [--artifact PATH ...]
                       [--include-untracked PATH ...] [--text PATH ...]
                       [--private-patterns PATH] [--published-base REF]

Exit codes: 0 pass, 1 audit findings or mismatch, 2 usage / incomplete inputs.

Diagnostics print a category code and a location only. Matched values and the
text around them are never printed. Automated checks do not certify the absence
of all sensitive data; the manual personal-data review remains required.
"""

import argparse
import bz2
import ctypes
import datetime
import errno
import fnmatch
import hashlib
import io
import json
import lzma
import os
import re
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import zipfile
import zlib

TOOL_VERSION = "1.0.0"
SCHEMA_VERSION = 1
MAX_FILE_BYTES = 64 * 1024 * 1024  # per-file scan cap; larger fails closed
MAX_ARCHIVE_MEMBERS = 20000
MAX_ARCHIVE_TOTAL_BYTES = 512 * 1024 * 1024
MAX_ARCHIVE_DEPTH = 3
MAX_XATTR_BYTES = 1024 * 1024
MAX_XATTRS = 256
MAX_PRINTED_FINDINGS = 200
REMINDER = (
    "NOTE: automated checks do not certify absence of all sensitive "
    "data; the manual personal-data review is still required."
)

EXIT_PASS, EXIT_FINDINGS, EXIT_USAGE = 0, 1, 2

# --------------------------------------------------------------------- patterns
# Name may end at "/", end of input, a quote, whitespace or any other delimiter.
HOME_RX = re.compile(rb"/Users/([A-Za-z0-9._-]+)(?![A-Za-z0-9._-])")
# Allowed /Users/<name> values: the macOS shared folder, plus obviously synthetic
# placeholder names that tests and doc comments use instead of a real username.
HOME_ALLOW = {b"Shared", b"someone", b"example"}
SECRET_PATTERNS = [
    ("sentinel", re.compile(rb"PRIVATE_SENTINEL_[0-9]+")),
    ("secret_pem", re.compile(rb"-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----")),
    (
        "secret_github_token",
        re.compile(rb"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"),
    ),
    ("secret_slack_token", re.compile(rb"\bxox[baprs]-[A-Za-z0-9-]{10,}")),
    ("secret_aws_key", re.compile(rb"\bAKIA[0-9A-Z]{16}\b")),
    ("secret_anthropic_key", re.compile(rb"\bsk-ant-[A-Za-z0-9_-]{10,}")),
    ("secret_bearer", re.compile(rb"\b[Bb]earer\s+[A-Za-z0-9._~+/=-]{20,}")),
]
FORBIDDEN_NAMES = [
    "private-config.json",
    "credential-*.json",
    "gui-credential.json",
    "actors.json",
    "export-*.json",
    "*.pem",
    "*.key",
    ".env*",
]
PNG_SIG = b"\x89PNG\r\n\x1a\n"


class UsageError(Exception):
    """Incomplete or invalid inputs (exit 2). Message never contains content."""


class GitError(Exception):
    pass


# ---------------------------------------------------------------------- helpers
def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def is_inside(path, root):
    path, root = os.path.realpath(path), os.path.realpath(root)
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def git_env():
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(
        GIT_CONFIG_NOSYSTEM="1",
        GIT_CONFIG_GLOBAL=os.devnull,
        GIT_TERMINAL_PROMPT="0",
        # refs/replace/* would make git hand back different bytes than a push sends.
        GIT_NO_REPLACE_OBJECTS="1",
    )
    return env


def check_history_integrity(repo, findings):
    """Shallow clones and grafts mean the audited history is not what a push sends."""
    try:
        shallow = git(repo, "rev-parse", "--is-shallow-repository").decode().strip()
        grafts = git(repo, "rev-parse", "--git-path", "info/grafts").decode().strip()
    except GitError:
        findings.add("history_unverifiable", "repo")
        return
    if shallow != "false":
        findings.add("shallow_repo", "repo")
    grafts_path = grafts if os.path.isabs(grafts) else os.path.join(repo, grafts)
    if os.path.lexists(grafts_path):
        findings.add("grafts_present", "repo")


def git(repo, *args):
    cmd = [
        "git",
        "-C",
        repo,
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.quotepath=off",
        *args,
    ]
    try:
        proc = subprocess.run(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=git_env()
        )
    except OSError:
        raise GitError("git unavailable")
    if proc.returncode != 0:
        raise GitError("git failed")
    return proc.stdout


class CatFile:
    """Synchronous `git cat-file --batch` reader with a size cap."""

    def __init__(self, repo):
        self.proc = subprocess.Popen(
            ["git", "-C", repo, "cat-file", "--batch"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=git_env(),
        )

    def get(self, sha):
        """Return (type, size, data); data is None when over the size cap."""
        try:
            self.proc.stdin.write(sha.encode() + b"\n")
            self.proc.stdin.flush()
            header = self.proc.stdout.readline().split()
            if len(header) != 3:
                raise GitError("object missing")
            otype, size = header[1].decode(), int(header[2])
            if size > MAX_FILE_BYTES:
                remaining = size + 1
                while remaining:
                    chunk = self.proc.stdout.read(min(remaining, 1 << 20))
                    if not chunk:
                        raise GitError("cat-file ended early")
                    remaining -= len(chunk)
                return otype, size, None
            data = self.proc.stdout.read(size)
            if len(data) != size or self.proc.stdout.read(1) != b"\n":
                raise GitError("cat-file short read")
        except (OSError, ValueError):
            raise GitError("cat-file stream failed")
        return otype, size, data

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()


def forbidden_name(basename):
    return any(fnmatch.fnmatch(basename, pat) for pat in FORBIDDEN_NAMES)


# --------------------------------------------------------------------- findings
class Findings:
    def __init__(self, extra_rx):
        self._seen = set()
        self.items = []
        self._redact = [rx for _, rx in SECRET_PATTERNS] + [r for r in extra_rx]

    def location(self, loc):
        """Locations can embed file names, so they get every content pattern.
        Spans from every pattern are collected on the ORIGINAL bytes and merged,
        so overlapping matches cannot leave a remainder behind."""
        raw = loc.encode("utf-8", "surrogateescape")
        spans = []
        for rx in self._redact:
            for m in rx.finditer(raw):
                if m.end() > m.start():
                    spans.append((m.start(), m.end(), b"<redacted>"))
        for m in HOME_RX.finditer(raw):
            if m.group(1) not in HOME_ALLOW:
                spans.append((m.start(), m.end(), b"/Users/<redacted>"))
        spans.sort(key=lambda t: (t[0], -t[1]))
        out, pos, i = bytearray(), 0, 0
        while i < len(spans):
            start, end, repl = spans[i]
            i += 1
            while i < len(spans) and spans[i][0] < end:
                end, repl = max(end, spans[i][1]), b"<redacted>"
                i += 1
            out += raw[pos:start] + repl
            pos = end
        out += raw[pos:]
        return bytes(out).decode("utf-8", "replace")

    def add(self, code, loc):
        key = (code, loc)
        if key not in self._seen:
            self._seen.add(key)
            self.items.append((code, self.location(loc)))

    def __bool__(self):
        return bool(self.items)


# ---------------------------------------------------------------------- scanner
class Scanner:
    def __init__(self, findings, private_rx, published=frozenset(), public_paths=frozenset()):
        self.f = findings
        # Path strings already public in the base (files and their directories).
        self.public_paths = public_paths
        self.private_rx = private_rx
        # Object ids already public (reachable from the declared published base).
        self.published = published
        self.skipped_public = set()
        self.archive_budget = MAX_ARCHIVE_TOTAL_BYTES

    def scan_bytes(self, data, loc):
        for code, rx in SECRET_PATTERNS:
            if rx.search(data):
                self.f.add(code, loc)
        for m in HOME_RX.finditer(data):
            if m.group(1) not in HOME_ALLOW:
                self.f.add("home_path", loc)
                break
        for rx in self.private_rx:
            if rx.search(data):
                self.f.add("private_pattern", loc)
        if data.startswith(PNG_SIG):
            for status, inflated in png_inflated_metadata(data):
                if status == "ok":
                    self.scan_bytes(inflated, loc + "#png-metadata")
                else:
                    self.f.add(status, loc + "#png-metadata")

    def scan_blob(self, data, name, loc, depth=0):
        """Scan one file's bytes: name policy, raw content, archive members."""
        if forbidden_name(os.path.basename(name)):
            self.f.add("forbidden_file", loc)
        self.scan_bytes(data, loc)
        self.scan_utf16(data, name, loc)
        kind = archive_kind(data)
        if kind:
            if depth >= MAX_ARCHIVE_DEPTH:
                self.f.add("archive_depth", loc)
            else:
                self.scan_archive(data, kind, loc, depth, name)

    def scan_utf16(self, data, name, loc):
        """Scan UTF-16 decodings: BOM present, or a .strings file."""
        if data[:2] in (b"\xff\xfe", b"\xfe\xff"):
            codecs = ["utf-16"]
        elif name.lower().endswith(".strings"):
            codecs = ["utf-16-le", "utf-16-be"]
        else:
            return
        for codec in codecs:
            text = data.decode(codec, "ignore").encode("utf-8", "replace")
            self.scan_bytes(text, loc + "#utf16")

    def scan_archive(self, data, kind, loc, depth, name="-"):
        try:
            if kind == "zip":
                self._scan_zip(data, loc, depth)
            elif kind == "tar":
                self._scan_tar(data, loc, depth)
            else:
                self._scan_compressed(data, kind, loc, depth, name)
        except _TooLarge:
            self.f.add("too_large", loc)
        except (
            zipfile.BadZipFile,
            tarfile.TarError,
            EOFError,
            OSError,
            zlib.error,
            lzma.LZMAError,
            ValueError,
            NotImplementedError,
            RuntimeError,
            OverflowError,
        ):
            self.f.add("archive_unreadable", loc)

    def _scan_compressed(self, data, kind, loc, depth, name):
        """Decompress gzip/bz2/xz (bounded). A tar result is scanned member by
        member; anything else is scanned as bytes and re-checked for archives."""
        out = decompress_bounded(data, kind)
        if not self._take_budget(len(out), loc):
            return
        if out[257:262] == b"ustar":
            # Raw bytes too: tar readers can skip data a push still carries.
            self.scan_bytes(out, loc + "#decompressed")
            self._scan_tar(out, loc, depth)
            return
        inner = name
        for ext in (".gz", ".bz2", ".xz", ".tgz"):
            if inner.lower().endswith(ext):
                inner = inner[: -len(ext)]
                break
        self.scan_blob(out, inner, loc + "#decompressed", depth + 1)

    def _member_ok(self, name, mloc):
        # Defense in depth: member names are also present in the raw archive
        # bytes (scanned by scan_blob), so this catches them only if a future
        # container stores names in a transformed form.
        self.scan_bytes(name.encode("utf-8", "replace"), mloc)
        norm = name.replace("\\", "/")
        parts = [p for p in norm.split("/") if p not in ("", ".")]
        if norm.startswith("/") or ".." in parts or re.match(r"^[A-Za-z]:", norm):
            self.f.add("archive_traversal", mloc)
            return False
        if ".git" in parts:
            self.f.add("nested_repo", mloc)
        return True

    def _take_budget(self, size, loc):
        self.archive_budget -= size
        if self.archive_budget < 0:
            self.f.add("archive_limit", loc)
            return False
        return True

    def _scan_zip(self, data, loc, depth):
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            infos = zf.infolist()
            if len(infos) > MAX_ARCHIVE_MEMBERS:
                self.f.add("archive_limit", loc)
                return
            consistent, bodies = _walk_zip(data, infos, zf.start_dir, max(self.archive_budget, 0))
            if not consistent:
                # zipfile trusts only the central directory; a stream extractor
                # (bsdtar -xOf -) walks local headers and can read entries the
                # directory never lists or sizes differently.
                self.f.add("archive_unreadable", loc)
                for name, body in bodies:
                    if not self._take_budget(len(body), loc):
                        return
                    self.scan_bytes(body, f"{loc}!{name}#local-header")
            # Release the walk's decoded bodies before the member loop.
            bodies = None
            for info in infos:
                mloc = f"{loc}!{info.filename}"
                if not self._member_ok(info.filename, mloc) or info.is_dir():
                    continue
                if info.file_size > MAX_FILE_BYTES:
                    self.f.add("too_large", mloc)
                    continue
                if not self._take_budget(info.file_size, loc):
                    return
                with zf.open(info) as fh:
                    body = fh.read(MAX_FILE_BYTES + 1)
                if len(body) > MAX_FILE_BYTES:
                    self.f.add("too_large", mloc)
                    continue
                self.scan_blob(body, info.filename, mloc, depth + 1)

    def _scan_tar(self, data, loc, depth):
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:", ignore_zeros=True) as tf:
            count = 0
            for member in tf:
                count += 1
                if count > MAX_ARCHIVE_MEMBERS:
                    self.f.add("archive_limit", loc)
                    return
                mloc = f"{loc}!{member.name}"
                if not self._member_ok(member.name, mloc):
                    continue
                if member.issym() or member.islnk():
                    target = member.linkname.replace("\\", "/")
                    if target.startswith("/") or ".." in target.split("/"):
                        self.f.add("archive_traversal", mloc)
                    continue
                if not member.isfile():
                    continue
                if member.size > MAX_FILE_BYTES:
                    self.f.add("too_large", mloc)
                    continue
                if not self._take_budget(member.size, loc):
                    return
                body = tf.extractfile(member).read()
                self.scan_blob(body, member.name, mloc, depth + 1)


ZIP_LOCAL_SIG = b"PK\x03\x04"
ZIP_DD_SIG = b"PK\x07\x08"
_ZIP_LOCAL_FMT = "<4sHHHHHIIIHH"  # 30 bytes
_INFLATE_CHUNK = 1 << 16


class _WalkStop(Exception):
    """The walk cannot tell where the next local header starts."""


def _inflate_span(data, start, budget):
    """Inflate the raw deflate stream at data[start:]. Returns (output, end)
    where end is the first byte after the stream (zlib's unused_data decides)."""
    d = zlib.decompressobj(-15)
    out = bytearray()
    pos = start
    while not d.eof:
        if pos >= len(data):
            raise _WalkStop
        chunk = data[pos : pos + _INFLATE_CHUNK]
        pos += len(chunk)
        while chunk:
            out += d.decompress(chunk, MAX_FILE_BYTES + 1 - len(out))
            if len(out) > MAX_FILE_BYTES or len(out) > budget:
                raise _TooLarge()
            if d.eof:
                break
            chunk = d.unconsumed_tail
    return bytes(out), pos - len(d.unused_data)


def _data_descriptor_end(data, pos, crc, csize, usize, boundaries):
    """End offset of a data descriptor at pos (signed or not, 32- or 64-bit
    sizes) whose values match and which is followed by a plausible boundary."""
    for sig in (ZIP_DD_SIG, b""):
        if data[pos : pos + len(sig)] != sig:
            continue
        body = pos + len(sig)
        for fmt in ("<III", "<IQQ"):
            size = struct.calcsize(fmt)
            if len(data) < body + size:
                continue
            if struct.unpack(fmt, data[body : body + size]) != (crc, csize, usize):
                continue
            end = body + size
            if end in boundaries or data.startswith(ZIP_LOCAL_SIG, end):
                return end
    return None


_ZIP64_UNSET = 0xFFFFFFFF


def _local_zip64_sizes(extra, need_usize, need_csize):
    """Read (usize, csize) from the zip64 extra (id 0x0001) of a local header.
    A local header carries both sizes in it. Returns None if missing/malformed."""
    pos = 0
    while pos + 4 <= len(extra):
        hid, hlen = struct.unpack("<HH", extra[pos : pos + 4])
        field = extra[pos + 4 : pos + 4 + hlen]
        pos += 4 + hlen
        if len(field) != hlen:
            return None
        if hid != 1:
            continue
        if need_usize and need_csize:
            if hlen < 16:
                return None
            return struct.unpack("<QQ", field[:16])
        # One size unset. APPNOTE 4.5.3 puts both sizes (uncompressed, then
        # compressed) in a local extra, but libarchive reads only the unset
        # field from the first 8 bytes. Accept only a reading both agree on:
        # an extractor following the other reading would see different entries.
        if hlen < 8:
            return None
        first = struct.unpack("<Q", field[:8])[0]
        if need_usize:
            return first, None
        if hlen >= 16 and struct.unpack("<Q", field[8:16])[0] != first:
            return None
        if hlen != 8 and hlen < 16:
            return None
        return None, first
    return None


def _zip_tail_ok(data, start_dir):
    """The central directory must be followed only by its end records, with the
    end-record comment followed only by zero padding, and no local-header
    signature after the directory outside the directory's own records."""
    pos = start_dir
    while data.startswith(b"PK\x01\x02", pos):
        if len(data) < pos + 46:
            return False
        n, m, k = struct.unpack("<HHH", data[pos + 28 : pos + 34])
        pos += 46 + n + m + k
    if data.startswith(b"PK\x06\x06", pos):
        if len(data) < pos + 12:
            return False
        pos += 12 + struct.unpack("<Q", data[pos + 4 : pos + 12])[0]
    if data.startswith(b"PK\x06\x07", pos):
        pos += 20
    if not data.startswith(b"PK\x05\x06", pos) or len(data) < pos + 22:
        return False
    clen = struct.unpack("<H", data[pos + 20 : pos + 22])[0]
    # bsdtar zero-pads a zip written to a non-seekable output to a block size;
    # extractors accept that, so only non-zero bytes after the comment are bad.
    end = pos + 22 + clen
    if end > len(data) or any(data[end:]):
        return False
    return data.find(ZIP_LOCAL_SIG, pos) == -1


def _walk_zip(data, infos, start_dir, budget=MAX_ARCHIVE_TOTAL_BYTES):
    """Walk local headers the way a streaming extractor does and compare with
    the central directory. Returns (consistent, bodies); bodies holds
    (name, decoded bytes) for entries whose local view differs from the
    directory or that the directory does not list, so callers can scan them.
    Decoding is bounded by budget (the scanner's remaining archive budget);
    exceeding it raises _TooLarge."""
    by_offset = {i.header_offset: i for i in infos}
    boundaries = set(by_offset) | {start_dir}
    consistent = len(by_offset) == len(infos)
    bodies, seen, cursor = [], set(), 0
    try:
        while cursor < start_dir and data.startswith(ZIP_LOCAL_SIG, cursor):
            if len(data) < cursor + 30:
                raise _WalkStop
            _, _, flags, method, _, _, crc, csize, usize, nlen, elen = struct.unpack(
                _ZIP_LOCAL_FMT, data[cursor : cursor + 30]
            )
            lname = data[cursor + 30 : cursor + 30 + nlen]
            body_start = cursor + 30 + nlen + elen
            extra = data[cursor + 30 + nlen : body_start]
            info = by_offset.get(cursor)
            seen.add(cursor)
            entry_ok = info is not None
            if info is not None:
                enc = "utf-8" if info.flag_bits & 0x800 else "cp437"
                entry_ok = (
                    lname == info.orig_filename.encode(enc, "surrogateescape")
                    and method == info.compress_type
                    and (flags & 0x9) == (info.flag_bits & 0x9)
                )
            if flags & 0x1 or method not in (0, 8):
                consistent = False
                raise _WalkStop  # encrypted / unsupported: cannot find the end
            has_dd = bool(flags & 0x8)
            z64 = None
            if _ZIP64_UNSET in (csize, usize):
                z64 = _local_zip64_sizes(extra, usize == _ZIP64_UNSET, csize == _ZIP64_UNSET)
                if z64 is None:
                    consistent = False
                    raise _WalkStop  # zip64 sizes promised but absent / malformed
                if usize == _ZIP64_UNSET:
                    usize = z64[0]
                if csize == _ZIP64_UNSET:
                    csize = z64[1]
                if info is not None and not has_dd and (
                    (usize, csize) != (info.file_size, info.compress_size)
                ):
                    entry_ok = False
            if method == 8:
                body, end = _inflate_span(data, body_start, budget)
            else:
                if has_dd:
                    raise _WalkStop  # stored + descriptor: end is not knowable
                if body_start + csize > len(data):
                    raise _WalkStop
                body, end = data[body_start : body_start + csize], body_start + csize
            budget -= len(body)
            if budget < 0:
                raise _TooLarge()
            if has_dd:
                if info is not None:
                    want = (info.CRC, info.compress_size, info.file_size)
                else:
                    want = (zlib.crc32(body) & 0xFFFFFFFF, end - body_start, len(body))
                dd_end = _data_descriptor_end(data, end, *want, boundaries)
                if dd_end is None:
                    entry_ok = False
                    raise _WalkStop
                end = dd_end
            elif info is not None and (
                end - body_start != info.compress_size or len(body) != info.file_size
            ):
                entry_ok = False
            if not entry_ok:
                consistent = False
                bodies.append((lname.decode("utf-8", "replace"), body))
            cursor = end
    except _WalkStop:
        consistent = False
    tail_ok = _zip_tail_ok(data, start_dir)
    return (consistent and tail_ok and seen == set(by_offset) and cursor == start_dir), bodies


class _TooLarge(Exception):
    pass


def decompress_bounded(data, kind):
    """Decompress concatenated gzip/bz2/xz streams, capped at MAX_FILE_BYTES.
    Truncated or corrupt input raises (callers report archive_unreadable)."""
    magic = {"gz": b"\x1f\x8b", "bz2": b"BZh", "xz": b"\xfd7zXZ\x00"}[kind]
    out = bytearray()
    rest = data
    while rest.startswith(magic):
        if kind == "gz":
            d = zlib.decompressobj(31)
        elif kind == "bz2":
            d = bz2.BZ2Decompressor()
        else:
            d = lzma.LZMADecompressor()
        chunk = d.decompress(rest, MAX_FILE_BYTES + 1 - len(out))
        out += chunk
        if len(out) > MAX_FILE_BYTES:
            raise _TooLarge()
        if not d.eof:
            # The cap is enforced above (max_length is one byte past it), so an
            # unfinished stream here means the input ran out: truncated.
            raise EOFError("truncated stream")
        rest = d.unused_data
    return bytes(out)


def archive_kind(data):
    if data[:4] == b"PK\x03\x04":
        return "zip"
    if data[:2] == b"\x1f\x8b":
        return "gz"
    if data[:3] == b"BZh":
        return "bz2"
    if data[:6] == b"\xfd7zXZ\x00":
        return "xz"
    if data[257:262] == b"ustar":
        return "tar"
    # A zip behind a prefix (self-extracting script, PNG polyglot): extractors
    # find it through the end record at the tail.
    if (
        b"PK\x05\x06" in data[-65557:] or b"PK\x06\x07" in data[-65557:]
    ) and zipfile.is_zipfile(io.BytesIO(data)):
        return "zip"
    return None


def png_inflated_metadata(data):
    """Yield (status, bytes) for zTXt/iTXt payloads: ("ok", inflated), or
    ("too_large" | "unreadable", b"") when it cannot be fully inflated within the
    cap. Raw bytes are scanned separately, so tEXt/eXIf are already covered."""
    pos = len(PNG_SIG)
    while pos + 8 <= len(data):
        length = int.from_bytes(data[pos : pos + 4], "big")
        ctype = data[pos + 4 : pos + 8]
        body = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        compressed = None
        if ctype == b"zTXt":
            end = body.find(b"\0")
            if end >= 0:
                compressed = body[end + 2 :]
        elif ctype == b"iTXt":
            end = body.find(b"\0")
            if end >= 0 and len(body) > end + 2 and body[end + 1] == 1:
                rest = body[end + 3 :]
                for _ in range(2):  # language tag, translated keyword
                    cut = rest.find(b"\0")
                    rest = rest[cut + 1 :] if cut >= 0 else b""
                compressed = rest
        if compressed:
            try:
                d = zlib.decompressobj()
                out = d.decompress(compressed, MAX_FILE_BYTES + 1)
            except zlib.error:
                yield "unreadable", b""
                continue
            if len(out) > MAX_FILE_BYTES:
                yield "too_large", b""
            elif not d.eof:
                yield "unreadable", b""  # truncated stream
            else:
                yield "ok", out


# ------------------------------------------------------------ extended attrs
def read_xattrs(path):
    """Return ([(name, value_bytes_or_None)], problems) for `path`. None marks a
    value over MAX_XATTR_BYTES. `problems` holds "too_large" (more than
    MAX_XATTRS attributes) and/or "unreadable" (any listing/read error); a
    platform without xattr support is simply empty. os.*xattr is Linux-only, so
    macOS goes through libc via ctypes."""
    out, problems = [], set()
    try:
        if hasattr(os, "listxattr"):
            names = os.listxattr(path, follow_symlinks=False)
            if len(names) > MAX_XATTRS:
                problems.add("too_large")
            for n in names[:MAX_XATTRS]:
                try:
                    v = os.getxattr(path, n, follow_symlinks=False)
                except OSError:
                    problems.add("unreadable")
                    continue
                out.append((n, v if len(v) <= MAX_XATTR_BYTES else None))
            return out, problems
        if sys.platform != "darwin":
            return out, problems
        libc = ctypes.CDLL(None, use_errno=True)
        bpath = os.fsencode(path)
        nofollow = 1  # XATTR_NOFOLLOW
        size = libc.listxattr(bpath, None, 0, nofollow)
        if size < 0:
            if ctypes.get_errno() not in (errno.ENOTSUP, errno.EPERM):
                problems.add("unreadable")
            return out, problems
        if size == 0:
            return out, problems
        buf = ctypes.create_string_buffer(size)
        size = libc.listxattr(bpath, buf, size, nofollow)
        if size < 0:
            problems.add("unreadable")
            return out, problems
        names = [r for r in buf.raw[:size].split(b"\0") if r]
        if len(names) > MAX_XATTRS:
            problems.add("too_large")
        for raw in names[:MAX_XATTRS]:
            vsize = libc.getxattr(bpath, raw, None, 0, 0, nofollow)
            if vsize < 0:
                problems.add("unreadable")
                continue
            if vsize > MAX_XATTR_BYTES:
                out.append((raw.decode("utf-8", "replace"), None))
                continue
            vbuf = ctypes.create_string_buffer(max(vsize, 1))
            got = libc.getxattr(bpath, raw, vbuf, vsize, 0, nofollow)
            if got < 0:
                problems.add("unreadable")
                continue
            out.append((raw.decode("utf-8", "replace"), vbuf.raw[:got]))
    except (OSError, AttributeError, ValueError, TypeError):
        problems.add("unreadable")
    return out, problems


# ---------------------------------------------------------- filesystem hashing
def hash_and_scan_path(path, loc, scanner, root_for_links=None):
    """Hash `path` (file, or directory via deterministic tree hash) and scan it.
    Symlinks are never followed; links leaving the directory are findings.
    Anything unreadable, or neither file/dir/symlink, is a finding."""
    f = scanner.f
    try:
        mode = os.lstat(path).st_mode
    except OSError:
        f.add("missing_path", loc)
        return None
    if stat.S_ISLNK(mode):
        f.add("symlink_escape", loc)
        try:
            target = os.readlink(path)
        except OSError:
            f.add("unreadable", loc)
            return None
        scanner.scan_bytes(os.fsencode(target), loc)
        return sha256_bytes(b"L\0" + target.encode("utf-8", "replace"))
    if stat.S_ISREG(mode):
        return _hash_scan_file(path, loc, scanner)
    if not stat.S_ISDIR(mode):
        f.add("special_file", loc)
        return None
    root = os.path.realpath(path)
    entries = []

    def walk_error(exc):
        name = getattr(exc, "filename", None) or path
        rel = os.path.relpath(name, path).replace(os.sep, "/")
        f.add("unreadable", loc if rel == "." else f"{loc}/{rel}")

    for dirpath, dirnames, filenames in os.walk(
        path, followlinks=False, onerror=walk_error
    ):
        dirnames.sort()
        for name in dirnames + sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, path).replace(os.sep, "/")
            scanner.scan_bytes(rel.encode("utf-8", "surrogateescape"), f"{loc}/{rel}")
            try:
                fmode = os.lstat(full).st_mode
            except OSError:
                f.add("unreadable", f"{loc}/{rel}")
                continue
            if stat.S_ISLNK(fmode):
                try:
                    target = os.readlink(full)
                except OSError:
                    f.add("unreadable", f"{loc}/{rel}")
                    entries.append((rel, "L", ""))
                    continue
                scanner.scan_bytes(os.fsencode(target), f"{loc}/{rel}")
                if not is_inside(os.path.join(os.path.dirname(full), target), root):
                    f.add("symlink_escape", f"{loc}/{rel}")
                entries.append((rel, "L", target))
            elif stat.S_ISDIR(fmode):
                entries.append((rel, "D", ""))
            elif stat.S_ISREG(fmode):
                entries.append(
                    (rel, "F", _hash_scan_file(full, f"{loc}/{rel}", scanner))
                )
            else:
                f.add("special_file", f"{loc}/{rel}")
                entries.append((rel, "S", ""))
            if name == ".git":
                f.add("nested_repo", f"{loc}/{rel}")
    entries.sort()
    h = hashlib.sha256()
    for rel, kind, val in entries:
        h.update(f"{kind}\0{rel}\0{val}\n".encode("utf-8", "surrogateescape"))
    return h.hexdigest()


def _hash_scan_file(path, loc, scanner):
    try:
        size = os.path.getsize(path)
        digest = sha256_file(path)
        if size > MAX_FILE_BYTES:
            scanner.f.add("too_large", loc)
            return digest
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        scanner.f.add("unreadable", loc)
        return None
    scanner.scan_blob(data, path, loc)
    xattrs, problems = read_xattrs(path)
    xloc = loc + "#xattr"
    for problem in sorted(problems):
        scanner.f.add(problem, xloc)
    for xname, xval in xattrs:
        if xval is None:
            scanner.f.add("too_large", xloc)
            continue
        scanner.scan_bytes(xname.encode("utf-8", "replace"), xloc)
        scanner.scan_bytes(xval, xloc)
    return digest


# -------------------------------------------------------------------- manifest
def resolve(base, p):
    p = os.path.expanduser(p)
    return p if os.path.isabs(p) else os.path.join(base, p)


def require_list(manifest, key):
    val = manifest.get(key, [])
    if not isinstance(val, list):
        raise UsageError(f"manifest field {key} must be a list")
    return val


def validate_manifest(m):
    if not isinstance(m, dict) or m.get("schemaVersion") != SCHEMA_VERSION:
        raise UsageError("manifest schemaVersion unsupported")
    if not isinstance(m.get("repo"), str) or not m["repo"]:
        raise UsageError("manifest repo missing")
    cand = m.get("candidate")
    if not (
        isinstance(cand, dict)
        and isinstance(cand.get("commit"), str)
        and isinstance(cand.get("tree"), str)
        and re.fullmatch(r"[0-9a-f]{40,64}", cand["commit"])
        and re.fullmatch(r"[0-9a-f]{40,64}", cand["tree"])
    ):
        raise UsageError("manifest candidate commit/tree invalid")
    for key, fields in (
        ("refs", ("name", "sha")),
        ("files", ("path", "sha256")),
        ("artifacts", ("path", "sha256")),
        ("texts", ("path", "sha256")),
    ):
        for item in require_list(m, key):
            if not (
                isinstance(item, dict)
                and all(isinstance(item.get(k), str) and item[k] for k in fields)
            ):
                raise UsageError(f"manifest {key} entry invalid")
    for item in require_list(m, "nestedRepos"):
        if not isinstance(item, str):
            raise UsageError("manifest nestedRepos entry invalid")
    pb = m.get("publishedBase")
    if pb is not None and not (
        isinstance(pb, dict)
        and isinstance(pb.get("ref"), str)
        and pb["ref"]
        and isinstance(pb.get("sha"), str)
        and re.fullmatch(r"[0-9a-f]{40,64}", pb["sha"])
    ):
        raise UsageError("manifest publishedBase invalid")
    ppf = m.get("privatePatternsFile")
    if ppf is not None and not (isinstance(ppf, str) and ppf):
        raise UsageError("manifest privatePatternsFile invalid")
    if ppf is not None and not (
        isinstance(m.get("privatePatternsSha256"), str)
        and re.fullmatch(r"[0-9a-f]{64}", m["privatePatternsSha256"])
    ):
        raise UsageError(
            "manifest privatePatternsSha256 required with privatePatternsFile"
        )
    if not m.get("refs"):
        raise UsageError("manifest must pin at least one published ref")


def load_json(path, what):
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError:
        raise UsageError(f"{what} unreadable")
    try:
        return raw, json.loads(raw)
    except ValueError:
        raise UsageError(f"{what} is not valid JSON")


def load_private_patterns(path):
    """Return (compiled patterns, sha256 of the exact bytes read)."""
    rx = []
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError:
        raise UsageError("private patterns file unreadable")
    lines = raw.splitlines()
    for line in lines:
        line = line.strip()
        if not line or line.startswith(b"#"):
            continue
        try:
            rx.append(
                re.compile(line[3:] if line.startswith(b"re:") else re.escape(line))
            )
        except re.error:
            raise UsageError("private patterns file has an invalid regex")
    return rx, sha256_bytes(raw)


def validate_review(review, manifest_sha, findings):
    if not isinstance(review, dict):
        findings.add("review_incomplete", "manual-review")
        return
    if review.get("schemaVersion") != SCHEMA_VERSION:
        findings.add("review_incomplete", "manual-review:schemaVersion")
    if review.get("manifestSha256") != manifest_sha:
        findings.add("review_mismatch", "manual-review:manifestSha256")
    decision = review.get("decision")
    if decision is None:
        findings.add("review_incomplete", "manual-review:decision")
    elif decision != "approved":
        findings.add("review_not_approved", "manual-review:decision")
    if not (isinstance(review.get("reviewer"), str) and review["reviewer"].strip()):
        findings.add("review_incomplete", "manual-review:reviewer")
    try:
        datetime.date.fromisoformat(str(review.get("date", ""))[:10])
        date_ok = isinstance(review.get("date"), str)
    except ValueError:
        date_ok = False
    if not date_ok:
        findings.add("review_incomplete", "manual-review:date")
    if review.get("personalDataReviewedManually") is not True:
        findings.add("review_incomplete", "manual-review:personalDataReviewedManually")


# ----------------------------------------------------------------------- audit
def rev_parse(repo, name):
    return git(repo, "rev-parse", "--verify", "--quiet", name).decode().strip()


def load_published_base(repo, manifest, findings):
    """Return the set of object ids reachable from the declared published base.
    The ref must resolve to exactly the declared sha; otherwise report
    published_base_mismatch and treat nothing as public (everything is scanned)."""
    pb = manifest.get("publishedBase")
    if pb is None:
        return frozenset(), frozenset()
    try:
        actual = rev_parse(repo, pb["ref"] + "^{commit}")
        if actual != pb["sha"]:
            raise GitError("sha differs")
        listing = git(repo, "rev-list", "--objects", actual).decode("utf-8", "replace")
        touched = git(
            repo, "log", "--name-only", "-z", "--format=", "--no-renames", "-m",
            "--root", actual,
        ).decode("utf-8", "replace")
    except GitError:
        findings.add("published_base_mismatch", "publishedBase")
        return frozenset(), frozenset()
    objects = frozenset(line.split(" ", 1)[0] for line in listing.splitlines() if line)
    paths = set()
    names = [line.split(" ", 1)[1] for line in listing.splitlines() if " " in line]
    for name in names + touched.split("\0"):
        name = name.strip("\n")
        parts = name.split("/")
        paths.update("/".join(parts[:i]) for i in range(1, len(parts) + 1) if name)
    return objects, frozenset(paths)


def audit_candidate(repo, manifest, scanner):
    f = scanner.f
    cand = manifest["candidate"]
    try:
        commit = rev_parse(repo, cand["commit"] + "^{commit}")
        tree = rev_parse(repo, cand["commit"] + "^{tree}")
    except GitError:
        f.add("candidate_mismatch", "candidate:commit")
        return
    if commit != cand["commit"]:
        f.add("candidate_mismatch", "candidate:commit")
    if tree != cand["tree"]:
        f.add("candidate_mismatch", "candidate:tree")
    declared_nested = set(manifest.get("nestedRepos", []))
    reader = CatFile(repo)
    scanned = set()
    short = commit[:10]
    try:
        listing = git(repo, "ls-tree", "-r", "-z", "--full-tree", commit)
        for entry in listing.split(b"\0"):
            if not entry:
                continue
            meta, _, rawpath = entry.partition(b"\t")
            mode, otype, sha = meta.decode().split()
            path = rawpath.decode("utf-8", "replace")
            loc = f"tree@{short}:{path}"
            if mode == "160000":
                if path not in declared_nested:
                    f.add("nested_repo", loc)
                continue
            if ".git" in path.split("/"):
                f.add("nested_repo", loc)
            scan_git_object(reader, sha, path, loc, scanner)
            scanned.add(sha)
        scanned.add(commit)
        scan_git_object(reader, commit, "", f"commit@{short}", scanner)
        for ref in manifest["refs"]:
            audit_ref(repo, ref, reader, scanned, scanner)
    finally:
        reader.close()


def scan_git_object(reader, sha, path, loc, scanner):
    if path and (sha not in scanner.published or path not in scanner.public_paths):
        # Tree objects store one component at a time, so a home path split
        # across directories only exists in the full path string. This runs
        # before the published early return: a public blob can be moved to a
        # new path. A path already public in the base is not re-flagged.
        scanner.scan_bytes(path.encode("utf-8", "surrogateescape"), loc)
    if sha in scanner.published:
        # Already public: content is not re-audited, but name policy still applies.
        scanner.skipped_public.add(sha)
        if path and forbidden_name(os.path.basename(path)):
            scanner.f.add("forbidden_file", loc)
        return
    try:
        otype, size, data = reader.get(sha)
    except GitError:
        scanner.f.add("object_unreadable", loc)
        return
    if otype == "tree":
        # Entry names live in tree bytes; scan them but not as a named file.
        if data is None:
            scanner.f.add("too_large", loc)
        else:
            scanner.scan_bytes(data, loc)
        return
    if data is None:
        scanner.f.add("too_large", loc)
        return
    scanner.scan_blob(data, path or "-", loc)


def audit_ref(repo, ref, reader, scanned, scanner):
    f = scanner.f
    name = ref["name"]
    try:
        actual = rev_parse(repo, name)
    except GitError:
        actual = ""
    if actual != ref["sha"]:
        f.add("ref_mismatch", f"ref:{name}")
        return
    try:
        listing = git(repo, "rev-list", "--objects", actual).decode("utf-8", "replace")
    except GitError:
        f.add("ref_unreadable", f"ref:{name}")
        return
    # rev-list --objects names each blob once (first path seen), so renames hide
    # earlier names. Name policy is therefore applied to every path touched by
    # every commit, independent of blob dedup.
    try:
        touched = git(
            repo,
            "log",
            "--name-only",
            "-z",
            "--format=",
            "--no-renames",
            "-m",
            "--root",
            actual,
        )
    except GitError:
        f.add("ref_unreadable", f"ref:{name}")
        return
    for raw in set(touched.split(b"\0")):
        path = raw.decode("utf-8", "replace").strip("\n")
        if path and forbidden_name(os.path.basename(path)):
            f.add("forbidden_file", f"{name}:history:{path}")
    for line in listing.splitlines():
        sha, _, path = line.partition(" ")
        loc = f"{name}@{sha[:10]}" + (f":{path}" if path else "")
        if path and forbidden_name(os.path.basename(path)):
            f.add("forbidden_file", loc)
        if sha in scanned:
            # Same object under another path: the object was audited, the path
            # string (which can hold a home path) was not.
            if path and path not in scanner.public_paths:
                scanner.scan_bytes(path.encode("utf-8", "surrogateescape"), loc)
            continue
        scanned.add(sha)
        scan_git_object(reader, sha, path, loc, scanner)


def audit_dirty(repo, manifest, f):
    try:
        head = rev_parse(repo, "HEAD")
    except GitError:
        return
    if head != manifest["candidate"]["commit"]:
        return
    out = git(repo, "status", "--porcelain=v1", "-z", "--untracked-files=no")
    declared = [d["path"].rstrip("/") for d in manifest.get("files", [])]
    for rec in out.split(b"\0"):
        if len(rec) < 4:
            continue
        path = rec[3:].decode("utf-8", "replace")
        if not any(path == d or path.startswith(d + "/") for d in declared):
            f.add("undeclared_dirty", f"worktree:{path}")


def audit_included(repo, manifest, scanner):
    f = scanner.f
    declared_nested = set(manifest.get("nestedRepos", []))
    for item in manifest.get("files", []):
        rel = item["path"]
        full = os.path.join(repo, rel)
        loc = f"file:{rel}"
        if (
            os.path.isabs(rel)
            or ".." in rel.replace("\\", "/").split("/")
            or not is_inside(os.path.dirname(full) or repo, repo)
        ):
            f.add("path_outside_repo", loc)
            continue
        digest = hash_and_scan_path(full, loc, scanner)
        if digest is not None and digest != item["sha256"]:
            f.add("hash_mismatch", loc)
        if (
            os.path.isdir(full)
            and os.path.exists(os.path.join(full, ".git"))
            and rel.rstrip("/") in declared_nested
        ):
            # Declared nested repo: .git marker already recorded; keep it
            # declared rather than failing.
            f.items[:] = [
                i
                for i in f.items
                if not (i[0] == "nested_repo" and i[1].startswith(loc + "/.git"))
            ]
    # The declared nested root may itself be a directory containing .git.
    return


def audit_external(manifest, base, key, kind, scanner):
    f = scanner.f
    for item in manifest.get(key, []):
        full = resolve(base, item["path"])
        loc = f"{kind}:{item['path']}"
        digest = hash_and_scan_path(full, loc, scanner)
        if digest is not None and digest != item["sha256"]:
            f.add("hash_mismatch", loc)


def run_audit(args, write_receipt):
    for name in ("manifest", "manual_review", "receipt"):
        if not getattr(args, name):
            raise UsageError(
                f"--{name.replace('_', '-')} is required and must be nonempty"
            )
    manifest_path = os.path.abspath(args.manifest)
    review_path = os.path.abspath(args.manual_review)
    receipt_path = os.path.abspath(args.receipt)
    manifest_raw, manifest = load_json(manifest_path, "manifest")
    validate_manifest(manifest)
    manifest_sha = sha256_bytes(manifest_raw)
    base = os.path.dirname(manifest_path)

    repo = os.path.realpath(resolve(base, manifest["repo"]))
    try:
        toplevel = os.path.realpath(
            git(repo, "rev-parse", "--show-toplevel").decode().strip()
        )
    except GitError:
        raise UsageError("manifest repo is not a git work tree")
    for label, p in (
        ("manifest", manifest_path),
        ("manual review", review_path),
        ("receipt", receipt_path),
    ):
        if is_inside(p, toplevel):
            raise UsageError(f"{label} path must be outside the candidate repository")

    patterns_path = manifest.get("privatePatternsFile")
    private_rx = []
    if patterns_path:
        patterns_path = resolve(base, patterns_path)
        if is_inside(patterns_path, toplevel):
            raise UsageError(
                "private patterns file must be outside the candidate repository"
            )
        private_rx, patterns_sha = load_private_patterns(patterns_path)
    else:
        patterns_sha = None
    findings = Findings(private_rx)
    if patterns_path and patterns_sha != manifest["privatePatternsSha256"]:
        findings.add("hash_mismatch", "private-patterns-file")

    review_raw, review = load_json(review_path, "manual review")
    review_sha = sha256_bytes(review_raw)
    validate_review(review, manifest_sha, findings)

    published, public_paths = load_published_base(toplevel, manifest, findings)
    scanner = Scanner(findings, private_rx, published, public_paths)
    check_history_integrity(toplevel, findings)
    audit_candidate(toplevel, manifest, scanner)
    audit_dirty(toplevel, manifest, findings)
    audit_included(toplevel, manifest, scanner)
    audit_external(manifest, base, "artifacts", "artifact", scanner)
    audit_external(manifest, base, "texts", "text", scanner)
    if published:
        print(
            f"NOTE: {len(scanner.skipped_public)} objects already public at "
            f"{manifest['publishedBase']['sha'][:12]} were not re-audited"
        )

    receipt = {
        "schemaVersion": SCHEMA_VERSION,
        "toolVersion": TOOL_VERSION,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "manifestSha256": manifest_sha,
        "reviewSha256": review_sha,
        "candidate": manifest["candidate"],
        "refs": manifest["refs"],
        "files": manifest.get("files", []),
        "artifacts": manifest.get("artifacts", []),
        "texts": manifest.get("texts", []),
        "privatePatternsSha256": patterns_sha,
        "publishedBase": manifest.get("publishedBase"),
    }
    return findings, receipt, receipt_path, write_receipt


def read_receipt(path):
    try:
        with open(path, "rb") as f:
            data = json.loads(f.read())
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def write_receipt_atomic(path, receipt):
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".receipt-", dir=directory)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as fh:
            json.dump(receipt, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def print_findings(findings):
    for code, loc in findings.items[:MAX_PRINTED_FINDINGS]:
        print(f"FINDING {code} {loc}")
    extra = len(findings.items) - MAX_PRINTED_FINDINGS
    if extra > 0:
        print(f"FINDING truncated {extra} more")


def cmd_audit(args):
    findings, receipt, receipt_path, _ = run_audit(args, True)
    existing = read_receipt(receipt_path) if os.path.exists(receipt_path) else None
    if (
        existing is not None
        and existing.get("manifestSha256") != receipt["manifestSha256"]
    ):
        # A receipt for another candidate is never overwritten.
        findings.add("receipt_conflict", "receipt")
        print_findings(findings)
        print(
            "FAIL: audit did not pass; existing receipt for a different manifest left untouched"
        )
        print(REMINDER)
        return EXIT_FINDINGS
    if findings:
        if existing is not None:  # stale receipt for this same candidate is revoked
            os.unlink(receipt_path)
        print_findings(findings)
        print(f"FAIL: {len(findings.items)} finding(s); no receipt written")
        print(REMINDER)
        return EXIT_FINDINGS
    write_receipt_atomic(receipt_path, receipt)
    print(f"PASS: audit clean; receipt written to {receipt_path}")
    print(REMINDER)
    return EXIT_PASS


def cmd_verify(args):
    findings, receipt, receipt_path, _ = run_audit(args, False)
    stored = read_receipt(receipt_path)
    if stored is None:
        findings.add("receipt_missing", "receipt")
    else:
        for key in (
            "manifestSha256",
            "reviewSha256",
            "candidate",
            "refs",
            "files",
            "artifacts",
            "texts",
            "privatePatternsSha256",
            "publishedBase",
        ):
            if stored.get(key) != receipt[key]:
                findings.add("receipt_mismatch", f"receipt:{key}")
    if findings:
        print_findings(findings)
        print("FAIL: receipt does not match the current candidate")
        print(REMINDER)
        return EXIT_FINDINGS
    print("PASS: receipt matches the current candidate")
    print(REMINDER)
    return EXIT_PASS


def cmd_template(args):
    if not args.repo or not args.rev:
        raise UsageError("--repo and --rev are required")
    repo = os.path.realpath(os.path.expanduser(args.repo))
    try:
        toplevel = os.path.realpath(
            git(repo, "rev-parse", "--show-toplevel").decode().strip()
        )
        commit = rev_parse(toplevel, args.rev + "^{commit}")
        tree = rev_parse(toplevel, args.rev + "^{tree}")
        refs = [{"name": r, "sha": rev_parse(toplevel, r)} for r in args.ref or []]
    except GitError:
        raise UsageError("repo, rev or ref could not be resolved")
    if not refs:
        raise UsageError("at least one --ref is required")
    sink = Scanner(Findings([]), [])  # hashing only; findings are discarded
    files = []
    for p in args.include_untracked or []:
        rel = os.path.relpath(os.path.realpath(os.path.join(toplevel, p)), toplevel)
        files.append(
            {
                "path": rel,
                "sha256": hash_and_scan_path(os.path.join(toplevel, rel), rel, sink),
            }
        )
    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "repo": toplevel,
        "candidate": {"commit": commit, "tree": tree},
        "refs": refs,
        "files": files,
        "nestedRepos": [],
        "artifacts": [
            {
                "path": os.path.abspath(p),
                "sha256": hash_and_scan_path(os.path.abspath(p), p, sink),
            }
            for p in args.artifact or []
        ],
        "texts": [
            {
                "path": os.path.abspath(p),
                "sha256": hash_and_scan_path(os.path.abspath(p), p, sink),
            }
            for p in args.text or []
        ],
    }
    if args.published_base:
        try:
            manifest["publishedBase"] = {
                "ref": args.published_base,
                "sha": rev_parse(toplevel, args.published_base + "^{commit}"),
            }
        except GitError:
            raise UsageError("published base ref could not be resolved")
    if args.private_patterns:
        pp = os.path.abspath(args.private_patterns)
        manifest["privatePatternsFile"] = pp
        manifest["privatePatternsSha256"] = sha256_file(pp)
    json.dump(manifest, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return EXIT_PASS


def build_parser():
    p = argparse.ArgumentParser(description="PortPilot publication audit")
    p.add_argument("--manifest")
    p.add_argument("--manual-review")
    p.add_argument("--receipt")
    p.add_argument("--verify-receipt", action="store_true")
    p.add_argument("--print-manifest-template", action="store_true")
    p.add_argument("--repo")
    p.add_argument("--rev")
    p.add_argument("--ref", action="append")
    p.add_argument("--artifact", action="append")
    p.add_argument("--include-untracked", action="append")
    p.add_argument("--text", action="append")
    p.add_argument("--private-patterns")
    p.add_argument("--published-base")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)  # argparse errors exit 2
    try:
        if args.print_manifest_template:
            return cmd_template(args)
        return cmd_verify(args) if args.verify_receipt else cmd_audit(args)
    except UsageError as exc:
        print(f"USAGE: {exc}", file=sys.stderr)
        return EXIT_USAGE
    except GitError:
        print("USAGE: git operation failed", file=sys.stderr)
        return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main())
