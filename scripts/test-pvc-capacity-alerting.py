#!/usr/bin/env python3
"""Contract tests for GitOps-managed PVC metrics, alerting and dashboard."""
import json
from pathlib import Path
import yaml

ROOT = Path(__file__).resolve().parents[1]
OBS = ROOT / 'platform/observability'
load = lambda p: yaml.safe_load((OBS / p).read_text())
dashboard = json.loads((OBS / 'grafana/dashboards/kubernetes/kubernetes-pvc-capacity.json').read_text())
assert dashboard['uid'] == 'k8s-pvc-capacity'
panels = {p['id']: p for p in dashboard['panels']}
assert {6, 7, 8, 9, 10, 11}.issubset(panels)
assert panels[6]['type'] == 'table' and len(panels[6]['targets']) == 5
assert 'joinByField' in [t['id'] for t in panels[6]['transformations']]
assert all('claim' in t['expr'] for t in panels[6]['targets'])
assert all(t['datasource']['uid'] == 'prometheus' for p in dashboard['panels'] for t in p.get('targets', []))
assert 'kubelet_volume_stats_available_bytes' in panels[7]['targets'][0]['expr']
assert 'kubelet_volume_stats_capacity_bytes' in panels[7]['targets'][0]['expr']
assert 'kube_pod_spec_volumes_persistentvolumeclaims_info' in panels[9]['targets'][0]['expr']
prometheus = load('prometheus/prometheus.yml')
jobs = {j['job_name']: j for j in prometheus['scrape_configs']}
job = jobs['kubernetes-kubelet-volumes']
assert job['scheme'] == 'https' and job['authorization']['credentials_file']
assert job['tls_config']['ca_file'] and not job['tls_config'].get('insecure_skip_verify')
assert any(r.get('replacement') == '/api/v1/nodes/$1/proxy/metrics' for r in job['relabel_configs'])
assert any('kubelet_volume_stats_' in r.get('regex', '') for r in job['metric_relabel_configs'])
config = load('grafana/alerting-rules-pvc-configmap.yaml')
rules = yaml.safe_load(config['data']['rules-pvc.yaml'])['groups'][0]['rules']
expected = {'PVCFilesystemUsageHigh': (80, '15m'), 'PVCFilesystemUsageCritical': (95, '2m'),
            'PVCMountedVolumeMetricsMissing': (0, '10m'), 'PVCKubeletScrapeUnavailable': (1, '5m')}
assert len(rules) == len(expected)
for rule in rules:
    threshold, duration = expected[rule['title']]
    assert rule['for'] == duration
    assert rule['condition'] == 'C' and rule['data'][2]['model']['conditions'][0]['evaluator']['params'] == [threshold]
    assert rule['data'][0]['model']['datasource']['uid'] == 'prometheus'
    assert rule['data'][0]['model']['instant'] and not rule['data'][0]['model']['range']
    assert rule['data'][1]['model']['type'] == 'reduce' and rule['data'][2]['model']['type'] == 'threshold'
    assert rule['annotations']['__dashboardUid__'] == dashboard['uid']
    assert int(rule['annotations']['__panelId__']) in panels
    assert rule['labels']['component'] == 'pvc-capacity'
dep = list(yaml.safe_load_all((OBS / 'grafana/deployment.yaml').read_text()))[0]
vols = {v['name']: v for v in dep['spec']['template']['spec']['volumes']}
mounts = {m['name']: m for m in dep['spec']['template']['spec']['containers'][0]['volumeMounts']}
assert vols['alerting-rules-pvc']['configMap']['name'] == 'grafana-alerting-rules-pvc'
assert mounts['alerting-rules-pvc']['subPath'] == 'rules-pvc.yaml'
assert any(s['configMap']['name'] == 'grafana-dashboard-kubernetes-pvc'
           for s in vols['dashboards-kubernetes']['projected']['sources'])
k = load('kustomization.yaml')
assert any(g['name'] == 'grafana-dashboard-kubernetes-pvc' for g in k['configMapGenerator'])
assert 'grafana/alerting-rules-pvc-configmap.yaml' in k['resources']
policies = list(yaml.safe_load_all((OBS / 'observability-netpol.yaml').read_text()))
discord = next(p for p in policies if p['metadata']['name'] == 'allow-grafana-discord-https')
assert discord['spec']['podSelector']['matchLabels']['app.kubernetes.io/name'] == 'grafana'
assert discord['spec']['egress'][0]['ports'] == [{'protocol': 'TCP', 'port': 443}]
assert discord['spec']['egress'][0]['to'][0]['ipBlock']['except']
print('PASS: PVC dashboard, kubelet scrape, Grafana rules, provisioning and Discord NetworkPolicy')
