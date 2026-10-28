#!/usr/bin/env python3
"""Validate Longhorn dashboard, alerting, scrape, and NetworkPolicy contracts.

Requires PyYAML and promtool; live cluster and Discord delivery need separate
post-merge checks. Uses the actual Grafana provisioned expressions in promtool.
"""
import json
import subprocess
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
OBS = ROOT / "platform/observability"
STORAGE = ROOT / "platform/storage/longhorn/k8s"


def read(path):
    return yaml.safe_load(path.read_text())


dashboard = json.loads((OBS / "grafana/dashboards/kubernetes/kubernetes-longhorn-scheduling.json").read_text())
assert dashboard["uid"] == "k8s-longhorn-scheduling"
assert dashboard["editable"] is False
panels = {p["id"]: p for p in dashboard["panels"]}
assert {2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}.issubset(panels)
assert panels[6]["type"] == "table" and panels[7]["type"] == "table"
assert "joinByField" in [t["id"] for t in panels[6]["transformations"]]
assert "longhorn_disk_status" in panels[7]["targets"][4]["expr"]
assert "longhorn_node_status" in panels[3]["targets"][0]["expr"]
assert "longhorn_disk_status" in panels[3]["targets"][0]["expr"]
assert all(t["datasource"]["uid"] == "prometheus"
           for p in panels.values() for t in p.get("targets", []))

for name in ["kubernetes-node-resource-capacity.json", "kubernetes-platform-overview.json"]:
    item = json.loads((OBS / "grafana/dashboards/kubernetes" / name).read_text())
    assert any(l.get("url") == "/d/k8s-longhorn-scheduling" for l in item["links"])
root = json.loads((OBS / "grafana/dashboards/homelab-overview.json").read_text())
assert any(l.get("url") == "/d/k8s-longhorn-scheduling" for l in root["links"])
for uid in [root, json.loads((OBS / "grafana/dashboards/kubernetes/kubernetes-node-resource-capacity.json").read_text())]:
    assert any("longhorn_node_status" in t.get("expr", "")
               for p in uid["panels"] for t in p.get("targets", []))

job = next(j for j in read(OBS / "prometheus/prometheus.yml")["scrape_configs"]
           if j["job_name"] == "longhorn-manager")
assert job["kubernetes_sd_configs"] == [{"role": "endpoints", "namespaces": {"names": ["longhorn-system"]}}]
assert job["metrics_path"] == "/metrics"
assert any(r.get("regex") == "longhorn-backend" and r.get("action") == "keep"
           for r in job["relabel_configs"])
assert any(r.get("regex") == "manager" and r.get("action") == "keep"
           for r in job["relabel_configs"])
assert any(r.get("target_label") == "manager_node" for r in job["relabel_configs"])

policy = read(STORAGE / "monitoring-prometheus-netpol.yaml")
assert policy["metadata"]["namespace"] == "longhorn-system"
assert policy["spec"]["podSelector"]["matchLabels"] == {"app": "longhorn-manager"}
ingress = policy["spec"]["ingress"][0]
assert ingress["ports"] == [{"protocol": "TCP", "port": 9500}]
assert ingress["from"] == [{
    "namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "observability"}},
    "podSelector": {"matchLabels": {"app.kubernetes.io/name": "prometheus"}}}]
assert "monitoring-prometheus-netpol.yaml" in read(STORAGE / "kustomization.yaml")["resources"]

cfg = read(OBS / "grafana/alerting-rules-longhorn-configmap.yaml")
groups = yaml.safe_load(cfg["data"]["rules-longhorn.yaml"])["groups"]
assert len(groups) == 1 and groups[0]["name"] == "longhorn-storage"
assert groups[0]["interval"] == "1m"
rules = {r["title"]: r for r in groups[0]["rules"]}
expected = {
    "LonghornDiskUsageWarning": (65, "gt", "10m"),
    "LonghornDiskUsageCritical": (72, "gt", "2m"),
    "LonghornDiskUnschedulable": (1, "lt", "2m"),
    "LonghornDiskNotReady": (1, "lt", "2m"),
    "LonghornNodeNotReady": (1, "lt", "2m"),
    "LonghornNodeSchedulingBlocked": (1, "lt", "2m"),
    "LonghornSchedulableNodesLow": (3, "lt", "3m"),
    "LonghornVolumeDegraded": (0, "gt", "2m"),
    "LonghornVolumeFaulted": (0, "gt", "1m"),
    "LonghornManagerScrapeFailed": (1, "lt", "5m"),
    "LonghornManagerTargetsMissing": (3, "lt", "5m"),
}
assert set(rules) == set(expected)
assert len({r["uid"] for r in rules.values()}) == len(expected)
prom_rules = []
for title, (threshold, operator, duration) in expected.items():
    r = rules[title]
    a, b, c = [data["model"] for data in r["data"]]
    assert r["condition"] == "C" and r["for"] == duration
    assert a["datasource"]["uid"] == "prometheus"
    assert a["instant"] and a["range"] is False
    assert b["type"] == "reduce" and b["expression"] == "A" and b["reducer"] == "last"
    assert c["type"] == "threshold" and c["expression"] == "B"
    assert c["conditions"][0]["evaluator"] == {"params": [threshold], "type": operator}
    assert r["noDataState"] == "NoData" and r["execErrState"] == "Alerting"
    assert r["annotations"]["__dashboardUid__"] == dashboard["uid"]
    assert int(r["annotations"]["__panelId__"]) in panels
    assert r["labels"]["component"] == "longhorn"
    prom_rules.append({"alert": title, "expr": f"({a['expr']}) { '<' if operator == 'lt' else '>' } {threshold}",
                       "for": duration, "labels": r["labels"]})

dep = list(yaml.safe_load_all((OBS / "grafana/deployment.yaml").read_text()))[0]
volumes = {v["name"]: v for v in dep["spec"]["template"]["spec"]["volumes"]}
mounts = {m["name"]: m for m in dep["spec"]["template"]["spec"]["containers"][0]["volumeMounts"]}
assert volumes["alerting-rules-longhorn"]["configMap"]["name"] == "grafana-alerting-rules-longhorn"
assert mounts["alerting-rules-longhorn"]["subPath"] == "rules-longhorn.yaml"
assert mounts["alerting-rules-longhorn"]["readOnly"]
assert any(s["configMap"]["name"] == "grafana-dashboard-kubernetes-longhorn"
           for s in volumes["dashboards-kubernetes"]["projected"]["sources"])
obs_kust = read(OBS / "kustomization.yaml")
assert "grafana/alerting-rules-longhorn-configmap.yaml" in obs_kust["resources"]
assert any(g["name"] == "grafana-dashboard-kubernetes-longhorn"
           for g in obs_kust["configMapGenerator"])

# Synthetic three-node regression: a disk on worker03 is 75% full and
# unschedulable, leaving two nodes eligible (the reported real-world failure).
series = []
for i in range(1, 4):
    node = f"k8s-worker0{i}"
    disk = f"disk0{i}"
    for condition in ("ready", "schedulable", "allowScheduling"):
        series.append({
            "series": f'longhorn_node_status{{job="longhorn-manager",node="{node}",condition="{condition}",condition_reason=""}}',
            "values": "1+0x12",
        })
    for condition in ("ready", "schedulable"):
        bad = i == 3 and condition == "schedulable"
        reason = "DiskPressure" if bad else ""
        series.append({
            "series": f'longhorn_disk_status{{job="longhorn-manager",node="{node}",disk="{disk}",condition="{condition}",condition_reason="{reason}"}}',
            "values": ("0" if bad else "1") + "+0x12",
        })
    for metric, value in (("capacity", 100), ("usage", 75 if i == 3 else 20)):
        series.append({
            "series": f'longhorn_disk_{metric}_bytes{{job="longhorn-manager",node="{node}",disk="{disk}"}}',
            "values": f"{value}+0x12",
        })
    series.append({
        "series": f'up{{job="longhorn-manager",instance="10.0.0.{i}:9500",manager_node="{node}"}}',
        "values": "1+0x12",
    })
series += [{
    "series": 'longhorn_volume_robustness{job="longhorn-manager",volume="example",pvc="example",pvc_namespace="apps",state="degraded"}',
    "values": "0+0x12",
}, {
    "series": 'longhorn_volume_robustness{job="longhorn-manager",volume="example",pvc="example",pvc_namespace="apps",state="faulted"}',
    "values": "0+0x12",
}]

labels = {"component": "longhorn", "engine": "grafana"}
def expected_alert(name, extra, severity):
    return {"eval_time": "4m", "alertname": name,
            "exp_alerts": [{"exp_labels": {**labels, "severity": severity, **extra}, "exp_annotations": {}}]}

checks = [
    expected_alert("LonghornDiskUsageCritical", {"node": "k8s-worker03", "disk": "disk03"}, "critical"),
    expected_alert("LonghornDiskUnschedulable",
                   {"node": "k8s-worker03", "disk": "disk03", "condition_reason": "DiskPressure"}, "critical"),
    expected_alert("LonghornSchedulableNodesLow", {}, "critical"),
    {"eval_time": "4m", "alertname": "LonghornManagerTargetsMissing", "exp_alerts": []},
    {"eval_time": "4m", "alertname": "LonghornVolumeDegraded", "exp_alerts": []},
]
with tempfile.TemporaryDirectory() as temp:
    dest = Path(temp)
    (dest / "rules.yaml").write_text(yaml.safe_dump({"groups": [{
        "name": "longhorn-storage", "interval": "1m", "rules": prom_rules
    }]}))
    subprocess.run(["promtool", "check", "rules", "rules.yaml"], cwd=temp, check=True)
    (dest / "tests.yaml").write_text(yaml.safe_dump({
        "rule_files": ["rules.yaml"],
        "evaluation_interval": "1m",
        "tests": [{"name": "one unschedulable node plus 75% disk usage",
                   "interval": "1m", "input_series": series, "alert_rule_test": checks}]
    }))
    subprocess.run(["promtool", "test", "rules", "tests.yaml"], cwd=temp, check=True)

print("PASS: Longhorn dashboard, per-manager scrape, scoped NetworkPolicy, 11 alerts and PromQL fixtures")
