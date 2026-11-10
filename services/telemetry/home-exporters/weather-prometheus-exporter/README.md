# Weather Prometheus Exporter

The exporter is pinned to image `ghcr.io/ivanversluis/weather-prometheus-exporter:sha-026a483@sha256:ebbccd049963cf99a037d0534578758a4c12b1b7a8b7f98640bad2c55e428742`, built and pushed successfully from weather exporter `main` commit `026a483aaff909f919c8421ca2d6d5d9cf95a17c` on 2026-11-10. The source tag is `sha-026a483`, also pullable with `docker pull ghcr.io/ivanversluis/weather-prometheus-exporter:sha-026a483`. Kubernetes uses the accompanying immutable manifest digest, so a moved tag cannot silently change the running build. The previous `v0.1.0` tag does not exist.

The exporter polls Open-Meteo every **600 seconds** (10 minutes); the standalone `observability` Prometheus scrapes `weather-prometheus-exporter.home-exporters.svc.cluster.local:9100/metrics` every **15 minutes**. Grafana queries use `last_over_time(metric[30m])` to bridge the five-minute default instant-query lookback. This is a cached *forecast and model-derived weather observation*, not a home weather station.

## Vault-backed location (no coordinates in Git)

The location uses an ExternalSecret with the existing `vault-backend` ClusterSecretStore (Vault KV v2 mounted at `secret/`). Seed the path with **public Amsterdam centre** coordinates before merging for a clean ExternalSecret status:

```bash
# Run only from your trusted Vault-authenticated admin terminal.
vault kv put -mount=secret infra/home-exporters/weather-prometheus-exporter \
  WEATHER_LATITUDE="52.3676" \
  WEATHER_LONGITUDE="4.9041"

# Read status only; do not print Secret values into a public log.
kubectl -n home-exporters get externalsecret weather-prometheus-exporter-location
kubectl -n home-exporters get externalsecret weather-prometheus-exporter-ghcr
```

To change to your own location later, run the same `vault kv put -mount=secret ...` command with private values from a trusted terminal (prefer private/secure input); **never paste personal coordinates into GitHub or a chat/PR**. The optional Kubernetes Secret loaded after the public ConfigMap overrides `WEATHER_LATITUDE` and `WEATHER_LONGITUDE` (two keys, no extra labels). Vault ESO refreshes hourly, but environment variables are read at pod startup; restart the weather Deployment after rotation. If the optional Secret is not available, the public Amsterdam defaults apply. Missing KV data makes the ExternalSecret report NotReady even while the pod uses Amsterdam; seed it before approving the PR. Open-Meteo receives the configured coordinates via HTTPS.

## GHCR pull auth (P1 fix)

This cluster requires GHCR credentials even for some public packages. A **separate** `weather-prometheus-exporter-ghcr` DockerConfigJson ExternalSecret uses the existing Vault secret at `infra/argocd` and the same read-only GHCR keys already used by DNS/unbound. The pod references this imagePullSecret. Confirm the referenced token has `read:packages` permission to this exporter image (may require package visibility/access grant). Never commit credentials. The new location Secret is not used for registry access.

## NetworkPolicy

The weather pod is excluded from the namespace-wide `allow-same-namespace` policy, leaving only its dedicated policy: ingress from the *Prometheus pods* in `observability` on TCP 9100; DNS to `kube-system` on TCP/UDP 53; outbound HTTPS on TCP 443 only to public IPv4 ranges. No service-account token, no privileges, run as UID 1000, read-only root filesystem. Standard Kubernetes NetworkPolicy cannot restrict HTTPS to `api.open-meteo.com` by hostname; that would require Calico FQDN controls or an egress proxy. Check that GlobalNetworkPolicy allows this egress.

## Operational verification

```bash
flux get kustomizations -n flux-system
kubectl -n home-exporters get externalsecrets weather-prometheus-exporter-location weather-prometheus-exporter-ghcr
kubectl -n home-exporters rollout status deploy/weather-prometheus-exporter
kubectl -n home-exporters get pods -l app=weather-prometheus-exporter
# From a second local terminal, after starting port-forward below:
# kubectl -n home-exporters port-forward svc/weather-prometheus-exporter 9100:9100
# curl -s http://localhost:9100/metrics | grep '^weather_up '
```

Prometheus target: `job="weather-prometheus-exporter"` (scrape every `15m`). Grafana dashboard: **Home / Weather & Solar Forecast** (`home-weather`). Check `weather_up`, `up{job="weather-prometheus-exporter"}` and `time() - last_over_time(weather_last_success_timestamp_seconds[30m])` before using data for automation. The 48 horizon-labelled forecast points describe *future validity times*, not Prometheus scrape timestamps. Dashboard separates snapshots from historical time-series data. Forecast solar radiation is **not** predicted PV electricity yield and does not yet schedule EV charging.
