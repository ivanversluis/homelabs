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
script = next(t["ansible.builtin.raw"] for t in tasks if "ansible.builtin.raw" in t)
assert next(t for t in tasks if "ansible.builtin.raw" in t)["changed_when"] is False
assert all(token not in script for token in (
    "rm -rf ", "crictl ", "fstrim ", "systemctl stop",
    "kubectl delete", "journalctl --vacuum", "du --apparent-size",
))
vars = playbook["vars"]
for key, replacement in (
    ("disk_path_max_levels", "4"),
    ("disk_path_top_entries", "10"),
    ("disk_path_longhorn_levels", "2"),
    ("disk_path_timeout_seconds", "30"),
):
    script = script.replace("{{ " + key + " | int }}", replacement)
script = script.replace("{{ inventory_hostname }}", "synthetic-worker")

assert "{{" not in script, "Unexpanded Ansible template"
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
               DISK_INSPECTION_LONGHORN_PATH=str(longhorn))
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
    assert "No further child directory" not in out or "Longhorn" in out
    assert (deep / "test-image.bin").stat().st_size == 1024 * 1024
    assert (longhorn / "test-replica.bin").stat().st_size == 131072

    bad_env = dict(env, DISK_INSPECTION_ROOT=str(root / "nonexistent"))
    bad = subprocess.run(["bash", "-c", script], env=bad_env,
                         text=True, capture_output=True, timeout=10)
    assert bad.returncode != 0 and "does not exist" in bad.stderr

print("PASS: read-only bounded disk drill-down, largest-path selection, Longhorn scope and failure reporting")
