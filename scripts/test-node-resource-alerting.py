#!/usr/bin/env python3
"""Validate Grafana wiring and test the provisioned PromQL/timers with promtool.

Requires PyYAML and promtool. This does not claim to test a live Grafana or Discord.
"""
import copy
import json
from pathlib import Path
import subprocess
import tempfile

import yaml

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'platform/observability'
GRAFANA = BASE / 'grafana'


def read(name):
    return yaml.safe_load((GRAFANA / name).read_text())


cm = read('alerting-rules-node-resources-configmap.yaml')
group = yaml.safe_load(cm['data']['rules-node-resources.yaml'])['groups'][0]
dashboard = json.loads((GRAFANA / 'dashboards/kubernetes/kubernetes-node-resource-capacity.json').read_text())
panels = {p['id']: p for p in dashboard['panels']}
expected = {'NodeCPUUsageHigh': (90, '30m'), 'NodeMemoryUsageHigh': (85, '4h'), 'NodeRootDiskUsageHigh': (70, '4h')}
assert len(group['rules']) == 3
assert group['interval'] == '1m'
exported = []
for rule in group['rules']:
    threshold, duration = expected[rule['title']]
    a, b, c = [x['model'] for x in rule['data']]
    evaluator = c['conditions'][0]['evaluator']
    assert evaluator == {'params': [threshold], 'type': 'gt'}
    assert rule['condition'] == 'C' and rule['for'] == duration
    assert a['instant'] and not a['range']
    assert b['type'] == 'reduce' and b['reducer'] == 'last' and b['expression'] == 'A'
    assert c['type'] == 'threshold' and c['expression'] == 'B'
    assert rule['noDataState'] == 'NoData' and rule['execErrState'] == 'Alerting'
    assert rule['labels']['severity'] == 'warning'
    assert rule['annotations']['__dashboardUid__'] == dashboard['uid']
    panel = panels[int(rule['annotations']['__panelId__'])]
    assert panel['targets'][0]['expr'] == a['expr']
    assert panel['fieldConfig']['defaults']['thresholds']['steps'][1]['value'] == threshold
    history = panels[panel['id'] + 3]
    assert history['targets'][0]['expr'] == a['expr']
    assert history['fieldConfig']['defaults']['custom']['thresholdsStyle']['mode'] == 'line'
    exported.append({'alert': rule['title'], 'expr': '(' + a['expr'] + f') > {threshold}', 'for': duration, 'labels': rule['labels']})

deployment = list(yaml.safe_load_all((GRAFANA / 'deployment.yaml').read_text()))[0]
spec = deployment['spec']['template']['spec']
volumes = {v['name']: v for v in spec['volumes']}
mounts = spec['containers'][0]['volumeMounts']
resources = yaml.safe_load((BASE / 'kustomization.yaml').read_text())['resources']
for name, key, filename in [('alerting-rules-node-resources', 'rules-node-resources.yaml', 'alerting-rules-node-resources-configmap.yaml')]:
    assert 'grafana/' + filename in resources
    assert volumes[name]['configMap']['name'] == read(filename)['metadata']['name']
    mount = next(m for m in mounts if m['name'] == name)
    assert mount['readOnly'] and mount['subPath'] == key
    assert mount['mountPath'].endswith('/' + key)
generator = next(g for g in yaml.safe_load((BASE / 'kustomization.yaml').read_text())['configMapGenerator'] if g['name'] == 'grafana-dashboard-kubernetes-node-resources')
assert generator['files'] == ['kubernetes-node-resource-capacity.json=grafana/dashboards/kubernetes/kubernetes-node-resource-capacity.json']
source = next(s['configMap'] for s in volumes['dashboards']['projected']['sources'] if s['configMap']['name'] == generator['name'])
assert source['items'] == [{'key': 'kubernetes-node-resource-capacity.json', 'path': 'Kubernetes/kubernetes-node-resource-capacity.json'}]
mount = next(m for m in mounts if m['name'] == 'dashboards')
assert mount['readOnly'] and 'subPath' not in mount
assert mount['mountPath'] == '/var/lib/grafana/dashboards'
contact = yaml.safe_load(read('alerting-contact-points-configmap.yaml')['data']['contact-points.yaml'])['contactPoints'][0]
receiver = contact['receivers'][0]
assert contact['name'] == 'discord-primary' and receiver['disableResolveMessage'] is False
assert receiver['settings']['url'] == '$GRAFANA_DISCORD_WEBHOOK_URL'
for text in ['.Status', '.Labels.alertname', '.Labels.instance', '.Labels.severity', '.Annotations.summary', '.Annotations.description', '.DashboardURL']:
    assert text in receiver['settings']['message']
policy = yaml.safe_load(read('alerting-notification-policies-configmap.yaml')['data']['notification-policies.yaml'])['policies'][0]
assert policy['receiver'] == 'discord-primary' and policy['group_by'] == ['alertname', 'instance']
print('Grafana dashboard, thresholds, label-preserving expressions, mounts, and Discord wiring: PASS', flush=True)

# Use real metric inputs with two instances: worker01 breaches, worker02 stays
# healthy. Also include a different scrape job to prove it is not alerted on.
series = []
for instance, high in [('worker01:9100', True), ('worker02:9100', False)]:
    labels = f'job="node-exporter",instance="{instance}",node="{instance.split(":")[0]}"'
    for cpu in [0, 1]:
        series.append({'series': f'node_cpu_seconds_total{{{labels},cpu="{cpu}",mode="idle"}}', 'values': '0+' + ('3' if high else '30') + 'x250'})
    for metric, value in [('node_memory_MemAvailable_bytes', 10 if high else 50), ('node_memory_MemTotal_bytes', 100)]:
        series.append({'series': f'{metric}{{{labels}}}', 'values': f'{value}+0x250'})
    for metric, value in [('node_filesystem_avail_bytes', 20 if high else 50), ('node_filesystem_size_bytes', 100)]:
        series.append({'series': f'{metric}{{{labels},mountpoint="/",fstype="ext4",device="/dev/root"}}', 'values': f'{value}+0x250'})
series.extend([{'series': 'node_memory_MemAvailable_bytes{job="other",instance="ignored:9100",node="ignored"}', 'values': '1+0x250'}, {'series': 'node_memory_MemTotal_bytes{job="other",instance="ignored:9100",node="ignored"}', 'values': '100+0x250'}])


def alert_test(rule, time, firing):
    return {'eval_time': time, 'alertname': rule['alert'], 'exp_alerts': [{'exp_labels': dict(rule['labels'], instance='worker01:9100', node='worker01'), 'exp_annotations': {}}] if firing else []}


checks = []
for rule in exported:
    cpu = rule['alert'] == 'NodeCPUUsageHigh'
    # CPU needs two samples before rate() is evaluable; its Pending starts at 1m.
    checks.extend([alert_test(rule, '30m' if cpu else '3h59m', False), alert_test(rule, '31m' if cpu else '4h', True)])
tests = [{'name': 'sustained breaches and per-instance isolation', 'interval': '1m', 'input_series': series, 'alert_rule_test': checks}]
reset = copy.deepcopy(series)
for item in reset:
    if 'worker01' in item['series'] and 'node_memory_MemAvailable' in item['series']:
        item['values'] = '10+0x119 50 10+0x129'
    if 'worker01' in item['series'] and 'node_filesystem_avail' in item['series']:
        item['values'] = '20+0x119 50 20+0x129'
tests.append({'name': 'a healthy sample resets the four-hour pending timer', 'interval': '1m', 'input_series': reset, 'alert_rule_test': [alert_test(r, '4h', False) for r in exported if r['for'] == '4h']})
resolved = copy.deepcopy(series)
for item in resolved:
    if 'worker01' in item['series'] and ('node_memory_MemAvailable' in item['series'] or 'node_filesystem_avail' in item['series']):
        item['values'] = ('10' if 'node_memory' in item['series'] else '20') + '+0x240 50+0x9'
tests.append({'name': 'recovery removes firing alert instances', 'interval': '1m', 'input_series': resolved, 'alert_rule_test': [alert_test(r, '4h1m', False) for r in exported if r['for'] == '4h']})
with tempfile.TemporaryDirectory() as temp:
    path = Path(temp)
    (path / 'rules.yaml').write_text(yaml.safe_dump({'groups': [{'name': 'node-resources', 'interval': '1m', 'rules': exported}]}))
    (path / 'tests.yaml').write_text(yaml.safe_dump({'rule_files': ['rules.yaml'], 'evaluation_interval': '1m', 'tests': tests}))
    subprocess.run(['promtool', 'test', 'rules', str(path / 'tests.yaml')], cwd=temp, check=True)
print('PromQL, sustained thresholds, per-node isolation, pending reset and recovery: PASS')
