# Weather Prometheus Exporter

Open-Meteo current weather (10-minute API poll) and 48-hour hourly forecast, sourced from [weather-prometheus-exporter](https://github.com/ivanversluis/weather-prometheus-exporter).

## Release dependency

**Merge the exporter PR and publish the `v0.1.0` release/tag first.** Confirm `ghcr.io/ivanversluis/weather-prometheus-exporter:v0.1.0` is available and anonymously pullable (or configure an imagePullSecret) before merging this deployment. The homelab is GitOps-managed by the existing `home-exporters` Flux Kustomization; it is not necessary to create another Flux object.

The metrics endpoint is `weather-prometheus-exporter.home-exporters.svc.cluster.local:9100/metrics`. The standalone observability Prometheus job scrapes it every **15 minutes**. The exporter requests external data every **10 minutes** and caches results. Note: Prometheus default instant lookback is 5 minutes; use `last_over_time(weather_temperature_celsius[30m])` for current weather and inspect `time() - last_over_time(weather_last_success_timestamp_seconds[30m])` for stale API polls.

## Location privacy

Public default coordinates correspond to Amsterdam city centre; they do not represent a home. If using precise coordinates later, create a Secret **outside Git** in the `home-exporters` namespace named `weather-prometheus-exporter-location`, with `WEATHER_LATITUDE` and `WEATHER_LONGITUDE` keys. The optional Secret is loaded after the public ConfigMap so it overrides the defaults. Prefer Vault-backed ExternalSecret, managed independently without committing its values; never put home coordinates into this repository, ConfigMaps, Flux substitution variables tracked in Git, metric labels, dashboards, PRs or logs. Restart the deployment to pick up created/rotated environment values. Open-Meteo receives configured coordinates over TLS.

## Security

- One non-root pod, read-only filesystem, dropped capabilities, no service-account token.
- Metrics reachable from `observability` only on TCP 9100; network policy allows DNS and external HTTPS but excludes RFC1918/metadata IPv4 ranges.
- Kubernetes NetworkPolicy cannot restrict to api.open-meteo.com by hostname; optional Calico FQDN controls/egress proxy would be required for that higher level of precision.
- Fail closed for automated control: use fresh successful API polls, not stale forecast data, for any future heating/EV planning.

## Validation after merge

```bash
flux get kustomizations home-exporters -n flux-system
kubectl -n home-exporters rollout status deployment/weather-prometheus-exporter
kubectl -n observability exec deploy/prometheus -- wget -qO- http://weather-prometheus-exporter.home-exporters.svc.cluster.local:9100/metrics
```

Grafana PromQL example: `last_over_time(weather_temperature_celsius[30m])`. Compare outside temperature to existing Home Climate/DSMR metrics; do not implement automatic heating/charging control in this exporter.
