#!/usr/bin/env python3
"""Publication audit for PortPilot (python3 stdlib only, no network).

Audits an exact publication candidate described by a manifest, binds the result
to a manual privacy review, and writes a receipt only when everything passes.

  audit-publication.py --manifest M --manual-review R --receipt X
  audit-publication.py --verify-receipt --manifest M --manual-review R --receipt X
  audit-publication.py --print-manifest-template --repo PATH --rev REV
                       [--ref NAME ...] [--artifact PATH ...]
                       [--include-untracked PATH ...] [--text PATH ...]
                       [--private-patterns PATH]

Exit codes: 0 pass, 1 audit findings or mismatch, 2 usage / incomplete inputs.

Diagnostics print a category code and a location only. Matched values and the
text around them are never printed. Automated checks do not certify the absence
of all sensitive data; the manual personal-data review remains required.
"""

import argparse
import bz2
import ctypes
import datetime
import fnmatch
import hashlib
import io
import json
import lzma
import os
import re
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
HOME_ALLOW = {b"Shared"}
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
        GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT="0"
    )
    return env


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
        self.proc.stdin.write(sha.encode() + b"\n")
        self.proc.stdin.flush()
        header = self.proc.stdout.readline().split()
        if len(header) != 3:
            raise GitError("object missing")
        otype, size = header[1].decode(), int(header[2])
        if size > MAX_FILE_BYTES:
            remaining = size + 1
            while remaining:
                remaining -= len(self.proc.stdout.read(min(remaining, 1 << 20)))
            return otype, size, None
        data = self.proc.stdout.read(size)
        self.proc.stdout.read(1)
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
        self._redact = [rx for _, rx in SECRET_PATTERNS[:1]] + [r for r in extra_rx]

    def location(self, loc):
        raw = loc.encode("utf-8", "replace")
        if any(rx.search(raw) for rx in self._redact):
            return "<redacted-location>"
        return loc

    def add(self, code, loc):
        key = (code, loc)
        if key not in self._seen:
            self._seen.add(key)
            self.items.append((code, self.location(loc)))

    def __bool__(self):
        return bool(self.items)


# ---------------------------------------------------------------------- scanner
class Scanner:
    def __init__(self, findings, private_rx):
        self.f = findings
        self.private_rx = private_rx
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
            for inflated in png_inflated_metadata(data):
                self.scan_bytes(inflated, loc + "#png-metadata")

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
            ValueError,
            NotImplementedError,
            RuntimeError,
        ):
            self.f.add("archive_unreadable", loc)

    def _scan_compressed(self, data, kind, loc, depth, name):
        """Decompress gzip/bz2/xz (bounded). A tar result is scanned member by
        member; anything else is scanned as bytes and re-checked for archives."""
        out = decompress_bounded(data, kind)
        if not self._take_budget(len(out), loc):
            return
        if out[257:262] == b"ustar":
            self._scan_tar(out, loc, depth)
            return
        inner = name
        for ext in (".gz", ".bz2", ".xz", ".tgz"):
            if inner.lower().endswith(ext):
                inner = inner[: -len(ext)]
                break
        self.scan_blob(out, inner, loc + "#decompressed", depth + 1)

    def _member_ok(self, name, mloc):
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
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as tf:
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
            # Not finished: either input ran out (truncated) or the cap hit.
            if len(out) >= MAX_FILE_BYTES:
                raise _TooLarge()
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
    return None


def png_inflated_metadata(data):
    """Yield decompressed zTXt/iTXt payloads (bounded). Raw bytes are scanned
    separately, so uncompressed tEXt/eXIf are already covered."""
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
                out = zlib.decompressobj().decompress(compressed, MAX_FILE_BYTES)
            except zlib.error:
                continue
            yield out


# ------------------------------------------------------------ extended attrs
def read_xattrs(path):
    """Return [(name, value_bytes_or_None)] for `path`; [] when unsupported.
    None marks a value over MAX_XATTR_BYTES. os.*xattr is Linux-only, so macOS
    goes through libc via ctypes."""
    try:
        if hasattr(os, "listxattr"):
            out = []
            for n in os.listxattr(path, follow_symlinks=False)[:MAX_XATTRS]:
                try:
                    v = os.getxattr(path, n, follow_symlinks=False)
                except OSError:
                    continue
                out.append((n, v if len(v) <= MAX_XATTR_BYTES else None))
            return out
        if sys.platform != "darwin":
            return []
        libc = ctypes.CDLL(None, use_errno=True)
        bpath = os.fsencode(path)
        nofollow = 1  # XATTR_NOFOLLOW
        size = libc.listxattr(bpath, None, 0, nofollow)
        if size <= 0:
            return []
        buf = ctypes.create_string_buffer(size)
        size = libc.listxattr(bpath, buf, size, nofollow)
        if size <= 0:
            return []
        out = []
        for raw in buf.raw[:size].split(b"\0")[:MAX_XATTRS]:
            if not raw:
                continue
            vsize = libc.getxattr(bpath, raw, None, 0, 0, nofollow)
            if vsize < 0:
                continue
            if vsize > MAX_XATTR_BYTES:
                out.append((raw.decode("utf-8", "replace"), None))
                continue
            vbuf = ctypes.create_string_buffer(max(vsize, 1))
            got = libc.getxattr(bpath, raw, vbuf, vsize, 0, nofollow)
            if got >= 0:
                out.append((raw.decode("utf-8", "replace"), vbuf.raw[:got]))
        return out
    except (OSError, AttributeError, ValueError, TypeError):
        return []


# ---------------------------------------------------------- filesystem hashing
def hash_and_scan_path(path, loc, scanner, root_for_links=None):
    """Hash `path` (file, or directory via deterministic tree hash) and scan it.
    Symlinks are never followed; links leaving the directory are findings."""
    f = scanner.f
    if os.path.islink(path):
        f.add("symlink_escape", loc)
        return sha256_bytes(b"L\0" + os.readlink(path).encode("utf-8", "replace"))
    if os.path.isfile(path):
        return _hash_scan_file(path, loc, scanner)
    if not os.path.isdir(path):
        f.add("missing_path", loc)
        return None
    root = os.path.realpath(path)
    entries = []
    for dirpath, dirnames, filenames in os.walk(path, followlinks=False):
        dirnames.sort()
        for name in dirnames + sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, path).replace(os.sep, "/")
            if os.path.islink(full):
                target = os.readlink(full)
                if not is_inside(os.path.join(os.path.dirname(full), target), root):
                    f.add("symlink_escape", f"{loc}/{rel}")
                entries.append((rel, "L", target))
            elif os.path.isdir(full):
                entries.append((rel, "D", ""))
            else:
                entries.append(
                    (rel, "F", _hash_scan_file(full, f"{loc}/{rel}", scanner))
                )
            if name == ".git":
                f.add("nested_repo", f"{loc}/{rel}")
    entries.sort()
    h = hashlib.sha256()
    for rel, kind, val in entries:
        h.update(f"{kind}\0{rel}\0{val}\n".encode("utf-8", "surrogateescape"))
    return h.hexdigest()


def _hash_scan_file(path, loc, scanner):
    size = os.path.getsize(path)
    digest = sha256_file(path)
    if size > MAX_FILE_BYTES:
        scanner.f.add("too_large", loc)
        return digest
    with open(path, "rb") as fh:
        data = fh.read()
    scanner.scan_blob(data, path, loc)
    for xname, xval in read_xattrs(path):
        xloc = loc + "#xattr"
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
    ppf = m.get("privatePatternsFile")
    if ppf is not None and not (isinstance(ppf, str) and ppf):
        raise UsageError("manifest privatePatternsFile invalid")
    if ppf is not None and not (
        isinstance(m.get("privatePatternsSha256"), str)
        and re.fullmatch(r"[0-9a-f]{64}", m["privatePatternsSha256"])
    ):
        raise UsageError("manifest privatePatternsSha256 required with privatePatternsFile")
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
    try:
        otype, size, data = reader.get(sha)
    except GitError:
        scanner.f.add("object_unreadable", loc)
        return
    if otype == "tree":
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
            repo, "log", "--name-only", "-z", "--format=", "--no-renames", "-m", "--root", actual
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

    scanner = Scanner(findings, private_rx)
    audit_candidate(toplevel, manifest, scanner)
    audit_dirty(toplevel, manifest, findings)
    audit_included(toplevel, manifest, scanner)
    audit_external(manifest, base, "artifacts", "artifact", scanner)
    audit_external(manifest, base, "texts", "text", scanner)

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
