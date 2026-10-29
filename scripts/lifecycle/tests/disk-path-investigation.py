#!/usr/bin/env python3
"""Exercise the read-only disk investigation raw script on a synthetic filesystem.

This runs against temporary fixture paths, NEVER the real root filesystem.
"""
import os
import subprocess
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]
playbook = yaml.safe_load((ROOT / "automation/ansible/playbooks/97-disk-path-investigation.yml").read_text())[0]
assert playbook["hosts"] == "k8s_homelab"
assert playbook["gather_facts"] is False and playbook["serial"] == 1
tasks = playbook["tasks"]
remote = next(t for t in tasks if "ansible.builtin.raw" in t)
assert remote["changed_when"] is False
assert "disk-path-investigation.sh" in remote["ansible.builtin.raw"]
assert "lookup(" in remote["ansible.builtin.raw"]
script = (ROOT / "automation/ansible/scripts/disk-path-investigation.sh").read_text()
assert all(token not in script for token in (
    "rm -rf ", "crictl ", "fstrim ", "systemctl stop",
    "kubectl delete", "journalctl --vacuum", "du --apparent-size",
))
vars = playbook["vars"]
assert vars["disk_path_max_levels"] <= 7
assert "{{" not in script, "Shell helper must not depend on remote Jinja substitution"
with tempfile.TemporaryDirectory(prefix="test-disk-path-") as directory:
    root = Path(directory) / "root"
    deep = root / "var" / "lib" / "containerd"
    deep.mkdir(parents=True)
    (deep / "test-image.bin").write_bytes(b"X" * (1024 * 1024))
    small = root / "home"
    small.mkdir()
    (small / "small.bin").write_bytes(b"Y" * 4096)
    longhorn = root / "var" / "lib" / "longhorn"
    longhorn.mkdir()
    (longhorn / "test-replica.bin").write_bytes(b"Z" * 131072)

    env = dict(os.environ,
               DISK_INSPECTION_ROOT=str(root),
               DISK_INSPECTION_LONGHORN_PATH=str(longhorn),
               DISK_INSPECTION_NODE_NAME="synthetic-worker",
               DISK_PATH_MAX_LEVELS="4",
               DISK_PATH_TOP_ENTRIES="10",
               DISK_PATH_LONGHORN_LEVELS="2",
               DISK_PATH_TIMEOUT_SECONDS="30")
    result = subprocess.run(["bash", "-c", script], env=env,
                            text=True, capture_output=True, timeout=40)
    assert result.returncode == 0, (result.stdout[-4000:], result.stderr)
    out = result.stdout
    assert "NODE: synthetic-worker" in out
    assert "Root filesystem" in out
    assert "Depth 0:" in out
    assert "LARGEST CHILD: " + str(root / "var") in out
    assert "LARGEST CHILD: " + str(root / "var" / "lib") in out
    assert str(root / "home") in out, "Root must list all first-level folders"
    assert "Longhorn storage path" in out
    assert str(longhorn) in out
    assert "DEEPEST INVESTIGATED PATH" in out
    assert (deep / "test-image.bin").stat().st_size == 1024 * 1024
    assert (longhorn / "test-replica.bin").stat().st_size == 131072

    bad_env = dict(env, DISK_INSPECTION_ROOT=str(root / "nonexistent"))
    bad = subprocess.run(["bash", "-c", script], env=bad_env,
                         text=True, capture_output=True, timeout=10)
    assert bad.returncode != 0 and "does not exist" in bad.stderr

print("PASS: read-only bounded disk drill-down, largest-path selection, Longhorn scope and failure reporting")
