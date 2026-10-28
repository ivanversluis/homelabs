#!/usr/bin/env python3
"""Validate Kubernetes image-maintenance reporting contracts."""
from pathlib import Path
import subprocess
import yaml

root = Path(__file__).resolve().parents[3]
play = yaml.safe_load((root / 'automation/ansible/playbooks/96-containerd-image-prune.yml').read_text())[0]
tasks = {task['name']: task for task in play['tasks']}
assert play['serial'] == 1
for name in ('Collect usage before image cleanup', 'Verify containerd and collect usage after image cleanup'):
    command = tasks[name]['ansible.builtin.raw']
    assert 'df -B1 --output=used /' in command
    assert 'df -B1P' not in command
    assert 'du -sxB1 /var/lib/containerd' in command

measured = subprocess.check_output(['df', '-B1', '--output=used', '/'], text=True).splitlines()[-1].strip()
assert int(measured) > 1048576, 'Disk measurement should be in bytes'
prune = tasks['Prune unused CRI images and retain partial-error evidence']
assert prune['failed_when'] is False
assert 'timeout --signal=TERM --kill-after=10s 20m' in prune['ansible.builtin.raw']
assert play['vars']['containerd_cri_timeout'] == '30s'
order = [task['name'] for task in play['tasks']]
assert order.index('Print cleanup result and reclaimed capacity') < order.index('Fail after reporting if CRI image removal was incomplete')
assert tasks['Fail after reporting if CRI image removal was incomplete']['ansible.builtin.assert']['that']
print('PASS: byte-unit accounting and partial-cleanup reporting')
