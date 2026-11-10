#!/usr/bin/env python3
"""Static regression test for the weather exporter, Vault, zero-trust and Grafana integration.

No Kubernetes or Vault credentials are needed. Requires PyYAML and kubectl kustomize.
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
EXPORTERS = ROOT / "services/telemetry/home-exporters"
OBS = ROOT / "platform/observability"


def load_yaml(path):
    return yaml.safe_load(path.read_text())


def objects(path):
    return list(yaml.safe_load_all(subprocess.check_output(
        ["kubectl", "kustomize", str(path)], text=True)))


def get(items, kind, name):
    hits = [o for o in items if o["kind"] == kind and o["metadata"]["name"] == name]
    assert len(hits) == 1, (kind, name, len(hits))
    return hits[0]


exporters = objects(EXPORTERS)
deployment = get(exporters, "Deployment", "weather-prometheus-exporter")
service = get(exporters, "Service", "weather-prometheus-exporter")
configmap = get(exporters, "ConfigMap", "weather-prometheus-exporter-config")
netpol = get(exporters, "NetworkPolicy", "weather-prometheus-exporter")
general = get(exporters, "NetworkPolicy", "allow-same-namespace")
location = get(exporters, "ExternalSecret", "weather-prometheus-exporter-location")
registry = get(exporters, "ExternalSecret", "weather-prometheus-exporter-ghcr")

assert all(o["metadata"]["namespace"] == "home-exporters" for o in
           [deployment, service, configmap, netpol, general, location, registry])
assert configmap["data"]["WEATHER_LATITUDE"] == "52.3676"
assert configmap["data"]["WEATHER_LONGITUDE"] == "4.9041"
assert configmap["data"]["WEATHER_POLL_INTERVAL_SECONDS"] == "600"
assert service["spec"]["type"] == "ClusterIP"
assert service["spec"]["ports"][0]["port"] == 9100

spec = deployment["spec"]["template"]["spec"]
assert deployment["spec"]["replicas"] == 1
assert spec["automountServiceAccountToken"] is False
assert spec["securityContext"]["runAsNonRoot"] is True
assert spec["securityContext"]["runAsUser"] == 1000
assert spec["securityContext"]["seccompProfile"]["type"] == "RuntimeDefault"
assert spec["imagePullSecrets"] == [{"name": "weather-prometheus-exporter-ghcr"}]
container = spec["containers"][0]
image = container["image"]
assert image.startswith("ghcr.io/ivanversluis/weather-prometheus-exporter@sha256:")
assert len(image.split("@sha256:")[1]) == 64
assert container["securityContext"]["readOnlyRootFilesystem"] is True
assert container["securityContext"]["allowPrivilegeEscalation"] is False
assert container["securityContext"]["capabilities"]["drop"] == ["ALL"]
assert "weather-prometheus-exporter-config" == container["envFrom"][0]["configMapRef"]["name"]
assert container["envFrom"][1]["secretRef"] == {
    "name": "weather-prometheus-exporter-location", "optional": True}
assert container["ports"][0]["containerPort"] == 9100
assert container["resources"]["limits"]["memory"] == "128Mi"

assert location["spec"]["secretStoreRef"] == {
    "kind": "ClusterSecretStore", "name": "vault-backend"}
assert location["spec"]["target"]["name"] == "weather-prometheus-exporter-location"
keys = {d["secretKey"]: d["remoteRef"] for d in location["spec"]["data"]}
assert set(keys) == {"WEATHER_LATITUDE", "WEATHER_LONGITUDE"}
for name in keys:
    assert keys[name] == {
        "key": "infra/home-exporters/weather-prometheus-exporter", "property": name}

assert registry["spec"]["target"]["template"]["type"] == "kubernetes.io/dockerconfigjson"
assert registry["spec"]["target"]["name"] == "weather-prometheus-exporter-ghcr"
assert all(d["remoteRef"]["key"] == "infra/argocd" for d in registry["spec"]["data"])
assert {d["remoteRef"]["property"] for d in registry["spec"]["data"]} == {
    "github-registry-firewall-manager_username", "github-registry-firewall-manager_token"}

# All policies are additive: the legacy allow-same-namespace MUST exclude weather
# or it bypasses the narrow weather-specific ingress rule.
deny_weather = general["spec"]["podSelector"]["matchExpressions"]
assert any(x.get("key") == "app" and x.get("operator") == "NotIn"
           and "weather-prometheus-exporter" in x.get("values", [])
           for x in deny_weather)
assert netpol["spec"]["podSelector"]["matchLabels"]["app"] == "weather-prometheus-exporter"
assert set(netpol["spec"]["policyTypes"]) == {"Ingress", "Egress"}
assert netpol["spec"]["ingress"] == [{
    "from": [{"namespaceSelector": {"matchLabels":
        {"kubernetes.io/metadata.name": "observability"}},
              "podSelector": {"matchLabels": {"app.kubernetes.io/name": "prometheus"}}}],
    "ports": [{"protocol": "TCP", "port": 9100}]}]
egress = netpol["spec"]["egress"]
assert len(egress) == 2
dns_ports = {(p["protocol"], p["port"]) for p in egress[0]["ports"]}
assert dns_ports == {("UDP", 53), ("TCP", 53)}
assert egress[1]["ports"] == [{"protocol": "TCP", "port": 443}]
cidr = egress[1]["to"][0]["ipBlock"]
assert cidr["cidr"] == "0.0.0.0/0"
assert {"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
        "169.254.0.0/16", "127.0.0.0/8"} <= set(cidr["except"])

prometheus = load_yaml(OBS / "prometheus/prometheus.yml")
weather_jobs = [j for j in prometheus["scrape_configs"]
                if j["job_name"] == "weather-prometheus-exporter"]
assert len(weather_jobs) == 1
job = weather_jobs[0]
assert job["scrape_interval"] == "15m"
assert job["scrape_timeout"] == "10s"
assert job["static_configs"][0]["targets"] == [
    "weather-prometheus-exporter.home-exporters.svc.cluster.local:9100"]

dashboard = json.loads((OBS / "grafana/dashboards/home/home-weather.json").read_text())
assert dashboard["uid"] == "home-weather"
assert dashboard["timezone"] == "Europe/Amsterdam"
assert dashboard["editable"] is False
assert len({p["id"] for p in dashboard["panels"]}) == len(dashboard["panels"])
assert len(dashboard["panels"]) >= 15
assert "/d/home-weather" in (OBS / "grafana/dashboards/homelab-overview.json").read_text()
forecast = next(p for p in dashboard["panels"] if p["title"].startswith("48-hour forecast"))
assert forecast["type"] == "table"
assert len(forecast["targets"]) == 5
assert any(x["id"] == "joinByField" and x["options"]["byField"] == "horizon_hours"
           for x in forecast["transformations"])
forecast_metric_names = {
    "weather_forecast_temperature_celsius", "weather_forecast_precipitation_mm",
    "weather_forecast_cloud_cover_percent",
    "weather_forecast_solar_radiation_watts_per_square_meter",
    "weather_forecast_valid_timestamp_seconds",
}
assert all(any(name in t["expr"] for t in forecast["targets"])
           for name in forecast_metric_names)
for panel in dashboard["panels"]:
    for target in panel.get("targets", []):
        if "weather_" in target.get("expr", ""):
            assert "last_over_time(" in target["expr"]
            assert "[30m]" in target["expr"]
            assert 'job="weather-prometheus-exporter"' in target["expr"]
assert "52.3676" not in json.dumps(dashboard)
assert "4.9041" not in json.dumps(dashboard)
assert not any(key in json.dumps(dashboard) for key in (
    "WEATHER_LATITUDE", "WEATHER_LONGITUDE"))
# Weather forecasts are anchored by validity times and retain the detail table.
visuals = [p for p in dashboard["panels"] if p["id"] in {26, 27, 28, 29}]
assert len(visuals) == 4 and all(p["type"] == "barchart" for p in visuals)
for p in visuals:
    assert len(p["targets"]) == 2
    assert all(t["instant"] and t["format"] == "table" for t in p["targets"])
    assert "weather_forecast_valid_timestamp_seconds" in p["targets"][1]["expr"]
    assert " * 1000" in p["targets"][1]["expr"]
    assert p["options"]["xField"] == "Forecast time"
    assert any(t["id"] == "joinByField" and t["options"]["byField"] == "horizon_hours" for t in p["transformations"])
    assert any(t["id"] == "convertFieldType" for t in p["transformations"])
    assert p["datasource"]["uid"] == "prometheus"
ev = [p for p in dashboard["panels"] if p["id"] in {23, 24, 25}]
assert len(ev) == 3 and sorted(p["type"] for p in ev) == ["gauge", "gauge", "stat"]
solar_goal = next(v for v in dashboard["templating"]["list"] if v["name"] == "solar_goal_kwh_m2")
assert solar_goal["type"] == "textbox" and solar_goal["current"]["value"] == "1.0"
for p in ev:
    expr = p["targets"][0]["expr"]
    assert "weather_forecast_solar_radiation_watts_per_square_meter" in expr
    assert "weather_up" in expr and "weather_last_success_timestamp_seconds" in expr
    assert "up{" in expr and 'job="weather-prometheus-exporter"' in expr
    assert "== 24" in expr and "[30m]" in expr and "$solar_goal_kwh_m2" in expr
assert "(2[4-9]|3[0-9]|4[0-7])" in ev[1]["targets"][0]["expr"]
assert "(2[4-9]|3[0-9]|4[0-7])" in ev[2]["targets"][0]["expr"]
assert all(p["fieldConfig"]["defaults"]["max"] == 100 for p in ev if p["type"] == "gauge")
assert "suffix: mm" in str(forecast["fieldConfig"]["overrides"])
assert "suffix: W/m²" in str(forecast["fieldConfig"]["overrides"])

print("PASS: Weather exporter: 15m scrape, Vault/registry wiring, isolated NetPol, Grafana 48h forecast and EV outlook")
