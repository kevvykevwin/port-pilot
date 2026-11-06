"""Filesystem transaction tests; only launchctl, codesign and IPC are stubbed."""
import importlib.util
import json
import plistlib
from pathlib import Path
from types import SimpleNamespace
import pytest


spec = importlib.util.spec_from_file_location("managed_helper", Path(__file__).resolve().parents[2] / "scripts/managed-helper.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


@pytest.fixture
def transaction(tmp_path, monkeypatch):
    root = tmp_path / "state"
    root.mkdir(mode=0o700)
    auth = root / "gui-credential.json"
    auth.write_text(json.dumps({"actor": "fixture", "credential": "fixture-token"}))
    auth.chmod(0o600)
    (root / "registry.json").write_text("original-state")
    app, candidate = tmp_path / "PortPilot.app", tmp_path / "candidate.app"
    for path, value in [(app, "old"), (candidate, "new")]:
        helper = path / "Contents/Helpers/PortPilotHelper"
        helper.parent.mkdir(parents=True)
        helper.write_text(value)
        helper.chmod(0o700)
    agent = tmp_path / "agents/helper.plist"
    agent.parent.mkdir()
    agent.write_bytes(plistlib.dumps(module.job(app, root)))
    args = SimpleNamespace(action="upgrade", app=app, candidate=candidate, state_dir=root,
                           credential_file=None, agent=agent, launchctl="fixture-launchctl")
    calls = []

    def request(root, auth, operation, payload=None):
        calls.append(operation)
        return {"checkpoint": "checkpoint-fixture"}

    monkeypatch.setattr(module, "request", request)
    monkeypatch.setattr(module, "health", lambda *args: None)
    monkeypatch.setattr(module, "command", lambda argv: calls.append(argv[1]))
    return args, calls


def binary(app):
    return (app / "Contents/Helpers/PortPilotHelper").read_text()


def test_success_preserves_previous_app_and_private_checkpoint(transaction):
    args, calls = transaction
    module.transact(args)
    assert binary(args.app) == "new"
    assert calls[-1] == "lifecycle.resume"
    backup = next(args.app.parent.glob(".PortPilot-backup-*"))
    assert binary(backup) == "old"
    checkpoint = next(args.state_dir.parent.glob("Managed-checkpoint-*"))
    assert (checkpoint / "registry.json").read_text() == "original-state"
    assert checkpoint.stat().st_mode & 0o077 == 0


def test_active_child_deferral_does_not_stop_or_replace(transaction, monkeypatch):
    args, calls = transaction
    def refuse(*args, **kwargs):
        raise RuntimeError("Helper refused: needs_decision")
    monkeypatch.setattr(module, "request", refuse)
    with pytest.raises(RuntimeError, match="needs_decision"):
        module.transact(args)
    assert binary(args.app) == "old"
    assert "bootout" not in calls
    assert not list(args.app.parent.glob(".PortPilot-stage-*"))


@pytest.mark.parametrize("boundary", ["bootout", "bootstrap", "health", "checkpoint", "activate"])
def test_failure_before_resume_restores_old_app_and_state(transaction, monkeypatch, boundary):
    args, calls = transaction
    failed = False
    original_command = module.command
    original_copy = module.shutil.copytree
    original_replace = module.os.replace

    def fail_once(name):
        nonlocal failed
        if boundary == name and not failed:
            failed = True
            raise RuntimeError("injected " + name)

    def command(argv):
        fail_once(argv[1])
        original_command(argv)

    health_count = 0
    def health(*unused):
        nonlocal health_count
        health_count += 1
        if health_count == 2 and boundary == "health":
            (args.state_dir / "registry.json").write_text("candidate-state")
            fail_once("health")

    def copy(source, target, *positional, **kwargs):
        if Path(source) == args.state_dir and "checkpoint" in str(target):
            fail_once("checkpoint")
        return original_copy(source, target, *positional, **kwargs)

    def replace(source, target):
        if ".PortPilot-stage-" in str(source):
            fail_once("activate")
        return original_replace(source, target)

    monkeypatch.setattr(module, "command", command)
    monkeypatch.setattr(module, "health", health)
    monkeypatch.setattr(module.shutil, "copytree", copy)
    monkeypatch.setattr(module.os, "replace", replace)
    with pytest.raises(RuntimeError, match="injected"):
        module.transact(args)
    assert binary(args.app) == "old"
    assert (args.state_dir / "registry.json").read_text() == "original-state"
    assert "lifecycle.resume" in calls


def test_uncertain_resume_never_discards_potentially_accepted_writes(transaction, monkeypatch):
    args, calls = transaction
    original = module.request
    def request(root, auth, operation, payload=None):
        if operation == "lifecycle.resume":
            (root / "registry.json").write_text("new-accepted-claim")
            raise OSError("reply lost")
        return original(root, auth, operation, payload)
    monkeypatch.setattr(module, "request", request)
    with pytest.raises(RuntimeError, match="do not roll back"):
        module.transact(args)
    assert binary(args.app) == "new"
    assert (args.state_dir / "registry.json").read_text() == "new-accepted-claim"


def test_uninstall_preserves_state_and_never_touches_tailnet(transaction):
    args, calls = transaction
    args.action = "uninstall"
    module.transact(args)
    assert not args.agent.exists()
    assert binary(args.app) == "old"
    assert (args.state_dir / "registry.json").read_text() == "original-state"
    assert "lifecycle.resume" not in calls
    assert calls == ["lifecycle.quiesce", "bootout"]


def test_foreign_job_is_never_overwritten(transaction):
    args, calls = transaction
    original = plistlib.dumps({"Label": "some-other-app"})
    args.agent.write_bytes(original)
    with pytest.raises(RuntimeError, match="differs"):
        module.transact(args)
    assert args.agent.read_bytes() == original
    assert calls == []


# --- PC18: export sidecar compatibility is decided before the running helper is quiesced ---

def write_sidecar(args, schema=1, states=("active",), raw=None):
    path = args.state_dir / "export-state.json"
    path.write_text(raw if raw is not None else json.dumps({"schema": schema, "enrollments": [{"state": s} for s in states]}))
    path.chmod(0o600)
    return path


def assert_untouched(args, calls):
    assert "lifecycle.quiesce" not in calls
    assert "bootout" not in calls
    assert binary(args.app) == "old"
    assert not list(args.app.parent.glob(".PortPilot-stage-*"))


def test_unsupported_transition_with_active_enrollment_is_rejected_before_quiesce(transaction, monkeypatch):
    # Bug caught: replacing the helper with one that cannot read the sidecar while export is live.
    args, calls = transaction
    write_sidecar(args, schema=1, states=("active",))
    monkeypatch.setattr(module, "probe_capabilities", lambda path: None)
    with pytest.raises(RuntimeError, match="Complete export shutdown"):
        module.transact(args)
    assert_untouched(args, calls)


def test_candidate_that_cannot_read_new_schema_is_rejected_while_revocation_unconfirmed(transaction, monkeypatch):
    # Bug caught: treating a revoked-but-unacknowledged enrollment as safe to strand on an old helper.
    args, calls = transaction
    write_sidecar(args, schema=2, states=("revoked",))
    monkeypatch.setattr(module, "probe_capabilities", lambda path: {"exportStateSchemas": [1]})
    with pytest.raises(RuntimeError, match="Complete export shutdown"):
        module.transact(args)
    assert_untouched(args, calls)


def test_old_helper_is_allowed_once_export_is_fully_shut(transaction, monkeypatch):
    # Bug caught: blocking every downgrade even after shutdown was confirmed or explicitly abandoned.
    args, calls = transaction
    write_sidecar(args, schema=1, states=("acknowledged", "abandoned"))
    monkeypatch.setattr(module, "probe_capabilities", lambda path: None)
    module.transact(args)
    assert binary(args.app) == "new"
    assert "lifecycle.quiesce" in calls


def test_supported_schema_is_allowed_with_active_enrollment(transaction, monkeypatch):
    # Bug caught: refusing an ordinary upgrade whose helper understands the sidecar.
    args, calls = transaction
    write_sidecar(args, schema=1, states=("active",))
    monkeypatch.setattr(module, "probe_capabilities", lambda path: {"exportStateSchemas": [1]})
    module.transact(args)
    assert binary(args.app) == "new"


def test_no_sidecar_needs_no_probe(transaction, monkeypatch):
    # Bug caught: export-disabled installs being forced through the capability probe.
    args, calls = transaction
    monkeypatch.setattr(module, "probe_capabilities", lambda path: pytest.fail("probe not expected"))
    module.transact(args)
    assert binary(args.app) == "new"


@pytest.mark.parametrize("raw", ["not json", "[]", '{"schema": "1", "enrollments": []}', '{"schema": 1, "enrollments": [{}]}'])
def test_unreadable_sidecar_is_rejected_before_quiesce(transaction, monkeypatch, raw):
    # Bug caught: failing open when the sidecar is corrupt, which could hide an active export.
    args, calls = transaction
    write_sidecar(args, raw=raw)
    monkeypatch.setattr(module, "probe_capabilities", lambda path: {"exportStateSchemas": [1]})
    with pytest.raises(RuntimeError, match="unreadable"):
        module.transact(args)
    assert_untouched(args, calls)


def test_group_readable_sidecar_is_rejected(transaction, monkeypatch):
    # Bug caught: trusting a sidecar another user could have rewritten.
    args, calls = transaction
    write_sidecar(args).chmod(0o644)
    monkeypatch.setattr(module, "probe_capabilities", lambda path: {"exportStateSchemas": [1]})
    with pytest.raises(RuntimeError, match="unreadable"):
        module.transact(args)
    assert_untouched(args, calls)


def test_rollback_keeps_revocation_made_during_the_transaction(transaction, monkeypatch):
    # Bug caught: restoring the checkpoint's export-state.json and reviving a revoked enrollment.
    args, calls = transaction
    sidecar = write_sidecar(args, schema=1, states=("active",))
    monkeypatch.setattr(module, "probe_capabilities", lambda path: {"exportStateSchemas": [1]})
    original = module.health
    count = 0

    def health(*unused):
        nonlocal count
        count += 1
        if count == 2:
            sidecar.write_text(json.dumps({"schema": 1, "enrollments": [{"state": "revoked"}]}))
            raise RuntimeError("injected health failure")

    monkeypatch.setattr(module, "health", health)
    with pytest.raises(RuntimeError, match="injected"):
        module.transact(args)
    assert binary(args.app) == "old"
    assert json.loads(sidecar.read_text())["enrollments"][0]["state"] == "revoked"
    assert (args.state_dir / "registry.json").read_text() == "original-state"
    assert "lifecycle.resume" in calls


def test_sidecar_that_becomes_incompatible_after_quiesce_aborts_and_resumes(transaction, monkeypatch):
    # Bug caught: an enrollment landing between the first compatibility check and quiesce slipping past it.
    args, calls = transaction
    monkeypatch.setattr(module, "probe_capabilities", lambda path: None)
    original = module.request

    def request(root, auth, operation, payload=None):
        result = original(root, auth, operation, payload)
        if operation == "lifecycle.quiesce":
            write_sidecar(args, schema=1, states=("active",))
        return result

    monkeypatch.setattr(module, "request", request)
    with pytest.raises(RuntimeError, match="Complete export shutdown"):
        module.transact(args)
    assert binary(args.app) == "old"
    assert "bootout" not in calls
    assert calls[-1] == "lifecycle.resume"
    assert not list(args.app.parent.glob(".PortPilot-stage-*"))
