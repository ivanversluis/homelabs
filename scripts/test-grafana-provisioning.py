#!/usr/bin/env python3
"""Load the rendered dashboards in an isolated Grafana and verify its HTTP API.

Requires Docker, kubectl and PyYAML. No live credentials or homelab endpoints
are used. The container has no published port; HTTP requests run inside it.
"""
import json
import subprocess
import tempfile
import time
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'platform/observability'


def docker(*args):
    return subprocess.check_output(['docker', *args], text=True).strip()


objects = list(yaml.safe_load_all(subprocess.check_output(['kubectl', 'kustomize', str(BASE)], text=True)))
cms = {o['metadata']['name']: o for o in objects if o['kind'] == 'ConfigMap'}
deployment = next(o for o in objects if o['kind'] == 'Deployment' and o['metadata']['name'] == 'grafana')
spec = deployment['spec']['template']['spec']
image = spec['containers'][0]['image']
mounts = {m['name']: m for m in spec['containers'][0]['volumeMounts']}
projected = []
for volume in spec['volumes']:
    if volume['name'].startswith('dashboards-') and 'projected' in volume:
        folder = Path(mounts[volume['name']]['mountPath']).name
        for source in volume['projected']['sources']:
            source = json.loads(json.dumps(source))
            for item in source['configMap']['items']:
                item['path'] = folder + '/' + item['path']
            projected.append(source)
    elif volume['name'] == 'dashboard-homelab-overview':
        projected.append({'configMap': {'name': volume['configMap']['name'], 'items': [{'key': 'homelab-overview.json', 'path': 'homelab-overview.json'}]}})
expected = {}
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    dashboard_dir = root / 'dashboards'
    providers = root / 'provisioning/dashboards'
    datasource_dir = root / 'provisioning/datasources'
    providers.mkdir(parents=True)
    datasource_dir.mkdir(parents=True)
    (providers / 'default.yaml').write_text(cms['grafana-dashboards-provider']['data']['default.yaml'])
    (datasource_dir / 'datasources.yaml').write_text(cms['grafana-datasources']['data']['datasources.yaml'])
    (root / 'grafana.ini').write_text(cms['grafana-config']['data']['grafana.ini'])
    for source in projected:
        configmap = source['configMap']
        for item in configmap['items']:
            text = cms[configmap['name']]['data'][item['key']]
            path = dashboard_dir / item['path']
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            model = json.loads(text)
            expected[model['uid']] = (model, path.parent.name if path.parent != dashboard_dir else None, item['path'])
    # Match Kubernetes AtomicWriter's projected-volume layout. Inside each
    # mounted folder, visible files are symlinks into ..data. This catches
    # providers that load a flat copy but fail to traverse real mounts.
    for folder in list(dashboard_dir.iterdir()):
        if not folder.is_dir():
            continue  # The home page is a resolved subPath file mount.
        generation = folder / '..test-generation'
        generation.mkdir()
        for entry in list(folder.iterdir()):
            if entry == generation:
                continue
            entry.rename(generation / entry.name)
            entry.symlink_to(Path('..data') / entry.name)
        (folder / '..data').symlink_to(generation.name, target_is_directory=True)
    # Copied files must be readable by the image's non-root Grafana user.
    for path in root.rglob('*'):
        path.chmod(0o755 if path.is_dir() else 0o644)
    container = docker('create', '--network', 'none',
                       '-e', 'GF_AUTH_ANONYMOUS_ENABLED=true',
                       '-e', 'GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer',
                       '-e', 'GF_ANALYTICS_REPORTING_ENABLED=false',
                       '-e', 'GF_ANALYTICS_CHECK_FOR_UPDATES=false',
                       '-e', 'GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false',
                       image)
    try:
        docker('cp', str(root / 'provisioning') + '/.', container + ':/etc/grafana/provisioning/')
        docker('cp', str(dashboard_dir), container + ':/var/lib/grafana/dashboards')
        docker('cp', str(root / 'grafana.ini'), container + ':/etc/grafana/grafana.ini')
        docker('start', container)

        def api(path):
            response = docker('exec', container, 'wget', '-Y', 'off', '-qO-', 'http://127.0.0.1:3000' + path)
            return json.loads(response)

        deadline = time.monotonic() + 60
        while True:
            try:
                results = api('/api/search?type=dash-db&limit=1000')
                if len(results) == len(expected):
                    break
            except (subprocess.CalledProcessError, json.JSONDecodeError):
                pass
            if time.monotonic() >= deadline:
                raise AssertionError('Grafana did not provision every dashboard within 60 seconds')
            time.sleep(1)
        assert {r['uid'] for r in results} == set(expected)
        folders = set()
        for uid, (source, folder, filename) in expected.items():
            loaded = api('/api/dashboards/uid/' + uid)
            assert loaded['meta']['provisioned'], uid
            assert loaded['meta']['provisionedExternalId'].endswith(filename), (uid, loaded['meta']['provisionedExternalId'], filename)
            if folder:
                assert loaded['meta']['folderTitle'] == folder, (uid, loaded['meta'])
                folders.add(folder)
            assert loaded['dashboard']['title'] == source['title']
            assert {p['id'] for p in loaded['dashboard']['panels']} == {p['id'] for p in source['panels']}
        assert len(folders) == 5
        assert api('/api/datasources/uid/prometheus')['type'] == 'prometheus'
        home = api('/api/dashboards/home')
        assert home.get('dashboard', {}).get('uid') == 'homelab-overview' or home.get('redirectUri') in {
            '/d/homelab-overview/homelab-overview',
            '/d/default-home-dashboard/homelab-overview',
        }, home
        print(f'PASS: Grafana {image} provisioned {len(expected)} dashboards into five folders; UID and panel IDs preserved')
    except Exception:
        print(docker('logs', container))
        raise
    finally:
        docker('rm', '-f', container)
