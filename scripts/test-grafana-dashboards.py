#!/usr/bin/env python3
"""Validate provisioned dashboards, datasource/link contracts and real PromQL.

Requires PyYAML, kubectl and promtool. Tests repository configuration and sample
metric semantics; live target health and user-created Grafana dashboards require
separate post-deployment verification.
"""
import json
import re
import subprocess
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'platform/observability'
GRAFANA = BASE / 'grafana'
SOURCE = GRAFANA / 'dashboards'


def read_yaml(path):
    return yaml.safe_load(path.read_text())


def panels(dashboard):
    for panel in dashboard['panels']:
        yield panel
        yield from panel.get('panels', [])


def expand(expr, values=None):
    values = {'__rate_interval': '5m', '__interval': '5m', 'namespace': '.*',
              'pod': '.*', 'node': '.*', 'device': '.*', 'client': 'client-a',
              'device_id': '.*', **(values or {})}
    return re.sub(r'\$\{?(\w+)(?::\w+)?\}?', lambda m: values[m[1]], expr)


dashboards = {}
paths = {}
for path in sorted(SOURCE.rglob('*.json')):
    dashboard = json.loads(path.read_text())  # Reject concatenated JSON.
    uid = dashboard['uid']
    assert uid not in dashboards, f'Duplicate UID: {uid}'
    dashboards[uid] = dashboard
    paths[uid] = path
assert len(dashboards) >= 21, 'Expected the existing dashboards and two entry points'

ds_config = read_yaml(GRAFANA / 'datasources-configmap.yaml')
datasources = yaml.safe_load(ds_config['data']['datasources.yaml'])['datasources']
assert any(d['uid'] == 'prometheus' and d['url'] == 'http://prometheus:9090' for d in datasources)
provider = yaml.safe_load(read_yaml(GRAFANA / 'dashboards-provider-configmap.yaml')['data']['default.yaml'])['providers'][0]
assert provider['options'] == {'path': '/var/lib/grafana/dashboards', 'foldersFromFilesStructure': True}
assert not provider.get('folder') and not provider.get('folderUid')
assert provider['allowUiUpdates'] is False

rules = []
for uid, dashboard in dashboards.items():
    assert dashboard['editable'] is False
    ids = [p['id'] for p in panels(dashboard)]
    assert len(ids) == len(set(ids)), f'{uid}: duplicate panel IDs'
    for panel in panels(dashboard):
        pos = panel['gridPos']
        assert 0 <= pos['x'] and pos['x'] + pos['w'] <= 24 and pos['h'] > 0
        if panel['type'] in ['text', 'row']:
            continue
        assert panel['datasource'] == {'type': 'prometheus', 'uid': 'prometheus'}, uid
        refs = [t['refId'] for t in panel.get('targets', [])]
        assert len(refs) == len(set(refs)), f'{uid}/{panel["id"]}: duplicate target refs'
        for target in panel.get('targets', []):
            assert target['datasource'] == panel['datasource']
            if panel['type'] in ['stat', 'gauge', 'bargauge', 'piechart']:
                assert target['instant'] and target['range'] is False
            if target.get('expr'):
                expr = expand(target['expr'])
                rules.append({'record': f'dashboard_query_{len(rules)}', 'expr': expr})
    # Both top-level navigation and panel data links must resolve to managed UIDs.
    for match in re.finditer(r'/d/([\w-]+)', json.dumps(dashboard)):
        assert match[1] in dashboards, f'{uid}: broken link to {match[1]}'
    assert any(link.get('url') == '/d/homelab-overview' for link in dashboard['links']) or uid == 'homelab-overview'

# Verify what Kustomize actually deploys, not just source JSON and raw names.
rendered = subprocess.check_output(['kubectl', 'kustomize', str(BASE)], text=True)
objects = list(yaml.safe_load_all(rendered))
cms = {o['metadata']['name']: o for o in objects if o['kind'] == 'ConfigMap'}
deployment = next(o for o in objects if o['kind'] == 'Deployment' and o['metadata']['name'] == 'grafana')
spec = deployment['spec']['template']['spec']
volume = next(v for v in spec['volumes'] if v['name'] == 'dashboards')
mount = next(m for m in spec['containers'][0]['volumeMounts'] if m['name'] == 'dashboards')
assert mount['mountPath'] == provider['options']['path'] and mount['readOnly']
assert 'subPath' not in mount, 'Directory projection must update atomically'
mounted = {}
folders = set()
for source in volume['projected']['sources']:
    configmap = source['configMap']
    assert re.search(r'-[a-z0-9]{10}$', configmap['name']), 'Dashboard hashes must trigger rollouts'
    cm = cms[configmap['name']]
    for item in configmap['items']:
        dashboard = json.loads(cm['data'][item['key']])
        uid = dashboard['uid']
        assert uid not in mounted
        mounted[uid] = dashboard
        if '/' in item['path']: folders.add(item['path'].split('/')[0])
        assert Path(item['path']).name == paths[uid].name
assert mounted == dashboards, 'Every dashboard must be rendered and mounted exactly once'
assert folders == {'Kubernetes', 'DNS', 'Home', 'Firewall Manager', 'Platform Services'}

prometheus = read_yaml(BASE / 'prometheus/prometheus.yml')
jobs = {j['job_name']: j for j in prometheus['scrape_configs']}
assert jobs['daikin-prometheus-exporter']['scrape_interval'] == '30s'
cadvisor = jobs['kubernetes-cadvisor']
assert cadvisor['scheme'] == 'https' and cadvisor['tls_config']['ca_file']
assert not cadvisor['tls_config'].get('insecure_skip_verify', False)
assert cadvisor['authorization']['credentials_file']
assert any(r.get('replacement') == '/api/v1/nodes/$1/proxy/metrics/cadvisor' for r in cadvisor['relabel_configs'])
assert cadvisor['metric_relabel_configs'][0]['action'] == 'keep'
subprocess.run(['promtool', 'check', 'config', '--syntax-only', str(BASE / 'prometheus/prometheus.yml')], check=True)


def query(uid, panel_id, target=0, values=None):
    panel = next(p for p in panels(dashboards[uid]) if p['id'] == panel_id)
    return expand(panel['targets'][target]['expr'], values)


def check(expr, value, labels='{}'):
    return {'expr': expr, 'eval_time': '5m', 'exp_samples': [{'labels': labels, 'value': value}]}


# Different exporter labels reproduce the previous empty-vector subtraction.
# A distractor pod/room proves filtering; POD/empty containers must not count.
input_series = [
    {'series': 'goodwe_power_watts{job="goodwe-prometheus-exporter",instance="goodwe:9100",inverter="roof"}', 'values': '1000+0x10'},
    {'series': 'dsmr_electricity_power_export_kw{job="dsmr-p1-prometheus-exporter",instance="meter:9100"}', 'values': '0.2+0x10'},
    {'series': 'daikin_last_scrape_success_timestamp{job="daikin-prometheus-exporter"}', 'values': '1700000000+0x10'},
    {'series': 'daikin_indoor_temperature_celsius{device_name="Kitchen",device_id="one"}', 'values': '22+0x10'},
    {'series': 'daikin_indoor_temperature_celsius{device_name="Bedroom",device_id="two"}', 'values': '18+0x10'},
    {'series': 'node_time_seconds{job="node-exporter",node="worker01"}', 'values': '1700000000+0x10'},
    {'series': 'node_cpu_seconds_total{job="node-exporter",instance="worker01:9100",cpu="0",mode="idle"}', 'values': '0+30x10'},
    {'series': 'node_cpu_seconds_total{job="other",instance="ignore:9100",cpu="0",mode="idle"}', 'values': '0+0x10'},
    {'series': 'container_cpu_usage_seconds_total{job="kubernetes-cadvisor",namespace="app",pod="web",container="api"}', 'values': '0+15x10'},
    {'series': 'container_cpu_usage_seconds_total{job="kubernetes-cadvisor",namespace="app",pod="web",container="POD"}', 'values': '0+60x10'},
    {'series': 'container_cpu_usage_seconds_total{job="kubernetes-cadvisor",namespace="other",pod="other",container="api"}', 'values': '0+60x10'},
    {'series': 'container_memory_working_set_bytes{job="kubernetes-cadvisor",namespace="app",pod="web",container="api"}', 'values': '100+0x10'},
    {'series': 'container_memory_working_set_bytes{job="kubernetes-cadvisor",namespace="app",pod="web",container="POD"}', 'values': '900+0x10'},
    {'series': 'container_memory_working_set_bytes{job="kubernetes-cadvisor",namespace="other",pod="other",container="api"}', 'values': '900+0x10'},
]
checks = [
    check(query('dsmr-energy', 24, 2), 800),
    check(query('dsmr-energy', 29), 80),
    check(query('home-climate', 10), 1700000000000, '{job="daikin-prometheus-exporter"}'),
    check(query('home-climate', 1, values={'device': 'Kitchen'}), 22),
    check(query('k8s-time-sync', 3), 1700000000000, '{job="node-exporter",node="worker01"}'),
    check(query('k8s-platform-overview', 5), 0.5),
    check(query('k8s-workloads', 5, values={'namespace': 'app', 'pod': 'web'}), 0.25, '{namespace="app",pod="web"}'),
    check(query('k8s-workloads', 6, values={'namespace': 'app', 'pod': 'web'}), 100, '{namespace="app",pod="web"}'),
]
test_cases = [{'name': 'dashboard conversions, selection and cross-exporter arithmetic', 'interval': '1m', 'input_series': input_series, 'promql_expr_test': checks}]
test_cases.append({'name': 'zero solar power has no self-consumption ratio', 'interval': '1m', 'input_series': [
    {'series': 'goodwe_power_watts{inverter="roof"}', 'values': '0+0x10'},
    {'series': 'dsmr_electricity_power_export_kw', 'values': '0+0x10'}],
    'promql_expr_test': [{'expr': query('dsmr-energy', 29), 'eval_time': '5m', 'exp_samples': []}]})
test_cases.append({'name': 'missing telemetry stays missing', 'interval': '1m', 'input_series': [],
    'promql_expr_test': [{'expr': query('home-climate', 10), 'eval_time': '5m', 'exp_samples': []},
                         {'expr': query('k8s-workloads', 5), 'eval_time': '5m', 'exp_samples': []}]})
with tempfile.TemporaryDirectory() as temp:
    path = Path(temp)
    (path / 'queries.yaml').write_text(yaml.safe_dump({'groups': [{'name': 'dashboard-queries', 'rules': rules}]}))
    subprocess.run(['promtool', 'check', 'rules', str(path / 'queries.yaml')], check=True)
    (path / 'tests.yaml').write_text(yaml.safe_dump({'evaluation_interval': '1m', 'tests': test_cases}))
    subprocess.run(['promtool', 'test', 'rules', str(path / 'tests.yaml')], check=True)
print(f'PASS: {len(dashboards)} dashboards, {len(rules)} PromQL queries, five folders, provisioning and metric regression tests')
