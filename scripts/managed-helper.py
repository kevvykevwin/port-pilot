#!/usr/bin/env python3
"""Explicit per-user helper lifecycle. Never invoked by a build.

Upgrade/uninstall require an enrolled local user credential and a successful
quiescence handshake. Active children defer the transaction. No Tailscale writes.
"""
import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import stat
import struct
import subprocess
import tempfile
import time
import uuid


LABEL = "com.portpilot.managed-helper"


@contextmanager
def writer_gate(root):
    fd = os.open(root / "writer.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def private_file(path, limit=4096):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_size > limit:
            raise RuntimeError("Private local user credential required")
        return json.load(stream)


def request(root, credential, operation, payload=None):
    body = json.dumps(dict(protocolVersion=1, requestId=str(uuid.uuid4()), operation=operation,
                           actor=credential["actor"], credential=credential["credential"], payload=payload or {})).encode()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(str(root / "control.sock"))
        connection.sendall(struct.pack(">I", len(body)) + body)

        def receive(count):
            data = bytearray()
            while len(data) < count:
                chunk = connection.recv(count - len(data))
                if not chunk:
                    raise RuntimeError("Helper disconnected")
                data.extend(chunk)
            return data

        size = struct.unpack(">I", receive(4))[0]
        if not 0 < size <= 1048576:
            raise RuntimeError("Invalid helper response")
        response = json.loads(receive(size))
        if response.get("error"):
            raise RuntimeError("Helper refused: " + response["error"])
        return response.get("data", {})


def job(app, root):
    return dict(Label=LABEL, ProgramArguments=[str(app / "Contents/Helpers/PortPilotHelper"), "--state-dir", str(root), "serve"],
                RunAtLoad=True, KeepAlive=True, ThrottleInterval=10, ProcessType="Background",
                AbandonProcessGroup=True, Umask=0o077)


def atomic_plist(path, content):
    fd, name = tempfile.mkstemp(prefix=".portpilot-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            plistlib.dump(content, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def command(argv):
    result = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, timeout=15, check=False)
    if result.returncode:
        raise RuntimeError("Lifecycle command failed: " + Path(argv[0]).name)


def health(root, auth, checkpoint):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        try:
            result = request(root, auth, "status")
            if result.get("schema") != 1 or result.get("protocolVersion") != 1:
                raise RuntimeError("Unsupported helper schema/protocol")
            if checkpoint is not None and (result.get("checkpoint") != checkpoint or result.get("mutationsEnabled") is not False):
                raise RuntimeError("Replacement did not preserve quiescence")
            return
        except (OSError, RuntimeError):
            time.sleep(0.1)
    raise RuntimeError("Helper health check failed; preserve checkpoint for recovery")


EXPORT_STATE = "export-state.json"


def probe_capabilities(helper):
    """Ask a candidate helper what it supports. Returns None for a helper that cannot say
    (older build without --capabilities, crash, timeout, unparsable output)."""
    try:
        result = subprocess.run([str(helper), "--capabilities"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, timeout=15, check=False)
        if result.returncode:
            return None
        value = json.loads(result.stdout[:65536])
        return value if isinstance(value, dict) else None
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def check_export_compatibility(root, candidate_app):
    """PC18: runs while the current helper is still serving. An unsupported transition is
    rejected here, before quiescing or replacing anything. Fails closed on an unreadable sidecar."""
    path = root / EXPORT_STATE
    if not path.exists() and not path.is_symlink():
        return
    try:
        book = private_file(path, limit=4 * 1024 * 1024)
        schema = book["schema"]
        enrollments = book.get("enrollments", [])
        if not isinstance(schema, int) or not isinstance(enrollments, list):
            raise ValueError("shape")
        states = [item["state"] for item in enrollments]
    except (OSError, ValueError, KeyError, TypeError, RuntimeError):
        raise RuntimeError("Export state is unreadable; complete export shutdown before replacing the helper")
    capabilities = probe_capabilities(candidate_app / "Contents/Helpers/PortPilotHelper")
    supported = (capabilities or {}).get("exportStateSchemas")
    if isinstance(supported, list) and schema in supported:
        return
    # Candidate cannot read this sidecar, so it could not enforce revocation. That is only
    # acceptable when export is already fully shut: acknowledged or explicitly abandoned.
    if all(state in ("acknowledged", "abandoned") for state in states):
        return
    raise RuntimeError("Complete export shutdown before replacing the helper")


def transact(args):
    app, root, agent = args.app.absolute(), args.state_dir.absolute(), args.agent.absolute()
    info = root.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RuntimeError("Enroll a private helper state root first")
    auth = private_file(args.credential_file or root / "gui-credential.json")
    lock_fd = os.open(root / "lifecycle.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock_fd, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        agent.parent.mkdir(parents=True, exist_ok=True)
        expected = job(app, root)
        if agent.is_symlink():
            raise RuntimeError("Refusing symlink launch-agent path")
        existing = plistlib.loads(agent.read_bytes()) if agent.exists() else None
        if existing is not None and existing != expected:
            raise RuntimeError("Existing launch agent differs; reconcile explicitly")
        domain = "gui/" + str(os.getuid())
        if args.action == "install":
            if existing is not None:
                health(root, auth, None)
                return
            if not os.access(expected["ProgramArguments"][0], os.X_OK):
                raise RuntimeError("Packaged helper missing")
            command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
            atomic_plist(agent, expected)
            try:
                command([args.launchctl, "bootstrap", domain, str(agent)])
                health(root, auth, None)
            except Exception:
                # Bootout must succeed before removing a possibly loaded job.
                command([args.launchctl, "bootout", domain, str(agent)])
                agent.unlink()
                raise
            return
        if existing is None:
            raise RuntimeError("No owned helper launch agent")
        staging = None
        if args.action == "upgrade":
            if args.candidate is None or args.candidate.resolve() == app.resolve():
                raise RuntimeError("Upgrade requires a distinct built candidate app")
            command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(args.candidate)])
            check_export_compatibility(root, args.candidate)
            staging = app.parent / (".PortPilot-stage-" + str(uuid.uuid4()))
            shutil.copytree(args.candidate, staging, symlinks=True)
        checkpoint = None
        backup = app.parent / (".PortPilot-backup-" + str(uuid.uuid4()))
        receipt = root.parent / ("Managed-checkpoint-" + str(uuid.uuid4()))
        stopped = False
        replaced = False
        resume_started = False
        try:
            checkpoint = request(root, auth, "lifecycle.quiesce")["checkpoint"]
            if args.action == "upgrade":
                # An enrollment may have landed between the first check and quiesce. Re-check now that
                # mutations are blocked; the surrounding handler resumes the helper and leaves the app alone.
                check_export_compatibility(root, args.candidate)
            health(root, auth, checkpoint)
            shutil.copytree(root, receipt, ignore=shutil.ignore_patterns("control.sock", "writer.lock", "lifecycle.lock"))
            command([args.launchctl, "bootout", domain, str(agent)])
            stopped = True
            if args.action == "uninstall":
                # Preserve credentials, claims, recipes and maintenance marker.
                # Reinstallation requires explicit resume with this checkpoint.
                agent.unlink()
                print("Helper disabled. State retained; checkpoint: " + checkpoint)
                return
            with writer_gate(root):
                os.replace(app, backup)
                try:
                    os.replace(staging, app)
                except Exception:
                    os.replace(backup, app)
                    raise
            replaced = True
            command([args.launchctl, "bootstrap", domain, str(agent)])
            stopped = False
            health(root, auth, checkpoint)
            # Resume is the commit point. A lost response might follow accepted
            # writes, so no rollback is allowed after sending this request.
            resume_started = True
            request(root, auth, "lifecycle.resume", {"checkpoint": checkpoint})
            print("Helper upgraded. Previous app and state checkpoint retained.")
        except Exception:
            if resume_started:
                raise RuntimeError("Upgrade activation completed; resume result uncertain. Preserve current app/state and inspect helper status; do not roll back.")
            if checkpoint is not None:
                if replaced:
                    if not stopped:
                        command([args.launchctl, "bootout", domain, str(agent)])
                    with writer_gate(root):
                        failed = app.parent / (".PortPilot-failed-" + str(uuid.uuid4()))
                        os.replace(app, failed)
                        os.replace(backup, app)
                        # No new writes were accepted while the candidate was quiesced.
                        # Keep failed state for inspection, restore only checkpoint files.
                        failed_state = root.parent / ("Managed-failed-" + str(uuid.uuid4()))
                        shutil.copytree(root, failed_state, ignore=shutil.ignore_patterns("control.sock", "writer.lock", "lifecycle.lock"))
                        for item in receipt.iterdir():
                            # Never restore export-state.json over a file that exists now: a
                            # revocation made during this transaction must not be undone by an
                            # older checkpoint (PC18). It is restored only if it has vanished.
                            if item.name == EXPORT_STATE and (root / item.name).exists():
                                continue
                            if item.is_file():
                                shutil.copy2(item, root / item.name)
                    stopped = True
                if stopped:
                    command([args.launchctl, "bootstrap", domain, str(agent)])
                health(root, auth, checkpoint)
                request(root, auth, "lifecycle.resume", {"checkpoint": checkpoint})
            raise
        finally:
            if staging is not None and staging.exists():
                shutil.rmtree(staging)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["install", "uninstall", "upgrade"])
    parser.add_argument("--app", type=Path, default=Path("/Applications/PortPilot.app"))
    parser.add_argument("--candidate", type=Path)
    parser.add_argument("--state-dir", type=Path, default=Path.home() / "Library/Application Support/PortPilot/Managed")
    parser.add_argument("--credential-file", type=Path)
    parser.add_argument("--agent", type=Path, default=Path.home() / "Library/LaunchAgents/com.portpilot.managed-helper.plist")
    parser.add_argument("--launchctl", default="/bin/launchctl")
    args = parser.parse_args()
    try:
        transact(args)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
