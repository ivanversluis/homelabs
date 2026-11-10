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
    values = {'__rate_interval': '5m', '__interval': '5m', 'namespace': '.*', 'pvc': '.*',
              'pod': '.*', 'node': '.*', 'device': '.*', 'client': 'client-a',
              'device_id': '.*', 'solar_goal_kwh_m2': '1.0', '__from': '0', '__to': '300',
              '__range_s': '300', 'elec_t1_eur_kwh': '0.2703',
              'elec_t2_eur_kwh': '0.2703', 'credit_t1_eur_kwh': '0.2703',
              'credit_t2_eur_kwh': '0.2703', 'feedin_fee_eur_kwh': '0',
              'elec_fixed_eur_day': '-0.13', 'gas_eur_m3': '1.59',
              'gas_fixed_eur_day': '1.04', **(values or {})}
    # Consume the entire Grafana interpolation, including date:seconds.
    # The old pattern only consumed ':date', leaving ':seconds}' for promtool.
    return re.sub(r'\$\{(\w+)(?::\w+)*\}|\$(\w+)', lambda m: values[m[1] or m[2]], expr)


assert expand('last_over_time(up[15m] @ ${__from:date:seconds})') == 'last_over_time(up[15m] @ 0)'
assert expand('last_over_time(up[15m] @ ${__to:date:seconds})') == 'last_over_time(up[15m] @ 300)'
assert expand('up{namespace="$namespace"}') == 'up{namespace=".*"}'


dashboards = {}
paths = {}
for path in sorted(SOURCE.rglob('*.json')):
    dashboard = json.loads(path.read_text())  # Reject concatenated JSON.
    uid = dashboard['uid']
    assert uid not in dashboards, f'Duplicate UID: {uid}'
    dashboards[uid] = dashboard
    paths[uid] = path
assert len(dashboards) >= 21, 'Expected the existing dashboards and two entry points'

# Energy accounting must use boundary meter registers and make contract input editable.
energy = dashboards['home-energy-insights']
assert energy['timezone'] == 'Europe/Amsterdam'
assert energy['time'] == {'from': 'now/d', 'to': 'now'}
assert energy['editable'] is False
assert len(energy['templating']['list']) == 8
assert all(v['type'] == 'textbox' for v in energy['templating']['list'])
energy_panels = {p['id']: p for p in energy['panels']}
for panel_id, register in [(1, 'dsmr_electricity_import_total_kwh_tariff_1'),
                            (2, 'dsmr_electricity_export_total_kwh_tariff_1'),
                            (4, 'dsmr_gas_total_m3'),
                            (5, 'goodwe_total_generation_kwh')]:
    expr = energy_panels[panel_id]['targets'][0]['expr']
    assert register in expr
    assert '${__from:date:seconds}' in expr and '${__to:date:seconds}' in expr
    assert 'last_over_time(' in expr and '[15m] @' in expr
for chart_id, duration in [(20, '1h'), (23, '1d'), (26, '30d')]:
    expr = energy_panels[chart_id]['targets'][0]['expr']
    assert f'offset {duration}' in expr, (chart_id, expr)
assert 'gas_eur_m3' in energy_panels[8]['targets'][0]['expr']
assert '__range_s' in energy_panels[9]['targets'][0]['expr']
assert '/d/home-energy-insights' in paths['homelab-overview'].read_text()
assert 'grafana-dashboard-home-energy-insights' in read_yaml(BASE / 'kustomization.yaml').__str__()

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
                for selector in re.findall(r'\{([^{}]+)\}', expr):
                    jobs = re.findall(r'\bjob="([^"]+)"', selector)
                    assert len(set(jobs)) <= 1, f'{uid}/{panel["id"]}: contradictory job matchers'
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
mounts = {m['name']: m for m in spec['containers'][0]['volumeMounts']}
mounted = {}
folders = set()
for volume in spec['volumes']:
    if volume['name'].startswith('dashboards-') and 'projected' in volume:
        mount = mounts[volume['name']]
        assert mount['readOnly'] and 'subPath' not in mount
        assert Path(mount['mountPath']).parent == Path(provider['options']['path'])
        folders.add(Path(mount['mountPath']).name)
        sources = volume['projected']['sources']
    elif volume['name'] == 'dashboard-homelab-overview':
        mount = mounts[volume['name']]
        assert mount['readOnly'] and mount['subPath'] == 'homelab-overview.json'
        assert mount['mountPath'] == provider['options']['path'] + '/homelab-overview.json'
        sources = [{'configMap': {**volume['configMap'], 'items': [{'key': 'homelab-overview.json', 'path': 'homelab-overview.json'}]}}]
    else:
        continue
    for source in sources:
        configmap = source['configMap']
        assert re.search(r'-[a-z0-9]{10}$', configmap['name']), 'Dashboard hashes must trigger rollouts'
        cm = cms[configmap['name']]
        for item in configmap['items']:
            assert '/' not in item['path'], 'Projection must have file symlinks, not folder symlinks'
            dashboard_json = cm['data'][item['key']]
            dashboard = json.loads(dashboard_json)
            uid = dashboard['uid']
            if uid == 'home-energy-insights':
                # Flux is configured with strict postBuild substitution. Its
                # controller must preserve *all* Grafana ${...} expressions.
                assert cm['metadata'].get('annotations', {}).get(
                    'kustomize.toolkit.fluxcd.io/substitute') == 'disabled', (
                    'Grafana energy ConfigMap would fail Flux envsubst'
                )
                assert '${__to:date:seconds}' in dashboard_json
                assert '${__from:date:seconds}' in dashboard_json
                assert '${elec_t1_eur_kwh}' in dashboard_json
                assert '${gas_eur_m3}' in dashboard_json
                assert '${DOMAIN}' not in dashboard_json
            assert uid not in mounted
            mounted[uid] = dashboard
            assert item['path'] == paths[uid].name
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
try:
    subprocess.run(['promtool', 'check', 'config', '--syntax-only', str(BASE / 'prometheus/prometheus.yml')],
                   check=True, text=True, capture_output=True)
except subprocess.CalledProcessError as exc:
    details = f'{exc.stdout or ""}\n{exc.stderr or ""}'
    if 'field kubernetes_sd_configs not found in type config.ScrapeConfig' in details:
        print('Skipping promtool config syntax check: installed promtool lacks kubernetes_sd_configs support')
    else:
        raise


def query(uid, panel_id, target=0, values=None):
    panel = next(p for p in panels(dashboards[uid]) if p['id'] == panel_id)
    return expand(panel['targets'][target]['expr'], values)


def check(expr, value, labels='{}'):
    return {'expr': expr, 'eval_time': '5m', 'exp_samples': [{'labels': labels, 'value': value}]}


# Different exporter labels reproduce the previous empty-vector subtraction.
# A distractor pod/room proves filtering; POD/empty containers must not count.
input_series = [
    {'series': 'kube_node_status_condition{job="kube-state-metrics",node="worker01",condition="Ready",status="true"}', 'values': '1+0x10'},
    {'series': 'kube_node_status_condition{job="kube-state-metrics",node="worker02",condition="Ready",status="true"}', 'values': '0+0x10'},
    {'series': 'kube_node_status_condition{job="other",node="ignore",condition="Ready",status="true"}', 'values': '1+0x10'},
    {'series': 'kube_node_info{job="kube-state-metrics",node="worker01"}', 'values': '1+0x10'},
    {'series': 'kube_node_info{job="kube-state-metrics",node="worker02"}', 'values': '1+0x10'},
    {'series': 'kube_node_info{job="other",node="ignore"}', 'values': '1+0x10'},
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
    check(query('k8s-platform-overview', 1), 1),
    check(query('k8s-platform-overview', 2), 2),
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
# Validate charging recommendations against synthetic complete/partial forecasts
# and independent freshness conditions. A 15-minute Prometheus scrape interval
# uses the same 30-minute last_over_time windows as the dashboard.
def solar_forecast_fixture(first_wm2, second_wm2, *, stale=False, missing_hour=None):
    length = 80 if stale else 10
    series = [
        {'series': 'weather_up{job="weather-prometheus-exporter"}', 'values': f'1+0x{length}'},
        {'series': 'up{job="weather-prometheus-exporter"}', 'values': f'1+0x{length}'},
        {'series': 'weather_last_success_timestamp_seconds{job="weather-prometheus-exporter"}',
         'values': f'{0 if stale else 250}+0x{length}'},
    ]
    for hour in range(48):
        if hour == missing_hour:
            continue
        watts = first_wm2 if hour < 24 else second_wm2
        series.append({
            'series': f'weather_forecast_solar_radiation_watts_per_square_meter{{job="weather-prometheus-exporter",horizon_hours="{hour}"}}',
            'values': f'{watts}+0x{length}',
        })
    return series


def ev_checks(expected, evaluation='5m'):
    checks = []
    for panel_id, value in zip((23, 24, 25), expected):
        checks.append({
            'expr': query('home-weather', panel_id),
            'eval_time': evaluation,
            'exp_samples': [] if value is None else [{'labels': '{}', 'value': value}],
        })
    return checks


test_cases.extend([
    {
        'name': 'EV weather outlook prefers strong first 24h and shows weaker second 24h',
        'interval': '1m',
        'input_series': solar_forecast_fixture(50, 25),
        'promql_expr_test': ev_checks((100, 60, 1)),
    },
    {
        'name': 'EV weather outlook prefers strong second 24h',
        'interval': '1m',
        'input_series': solar_forecast_fixture(25, 50),
        'promql_expr_test': ev_checks((60, 100, 2)),
    },
    {
        'name': 'EV weather outlook declines both weak windows without inventing sunshine',
        'interval': '1m',
        'input_series': solar_forecast_fixture(20, 30),
        'promql_expr_test': ev_checks((48, 72, 0)),
    },
    {
        'name': 'EV weather outlook hides stale API data instead of suggesting charging',
        'interval': '1m',
        'input_series': solar_forecast_fixture(50, 50, stale=True),
        'promql_expr_test': ev_checks((None, None, None), '60m'),
    },
    {
        'name': 'EV outlook requires all 24 forecast hours per window',
        'interval': '1m',
        'input_series': solar_forecast_fixture(50, 50, missing_hour=20),
        'promql_expr_test': ev_checks((None, 100, None)),
    },
])

with tempfile.TemporaryDirectory() as temp:
    path = Path(temp)
    (path / 'queries.yaml').write_text(yaml.safe_dump({'groups': [{'name': 'dashboard-queries', 'rules': rules}]}))
    subprocess.run(['promtool', 'check', 'rules', str(path / 'queries.yaml')], check=True)
    (path / 'tests.yaml').write_text(yaml.safe_dump({'evaluation_interval': '1m', 'tests': test_cases}))
    subprocess.run(['promtool', 'test', 'rules', str(path / 'tests.yaml')], check=True)
print(f'PASS: {len(dashboards)} dashboards, {len(rules)} PromQL queries, five folders, provisioning and metric regression tests')
