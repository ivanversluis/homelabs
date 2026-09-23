# Manifest render validation

The repository validates every `kustomization.yaml` below the cluster, infrastructure, platform, service, and workload roots. The check is read-only: it runs `kubectl kustomize`, writes rendered output only to a temporary directory, and never connects to or changes a cluster.

Run the same validation locally:

```bash
bash scripts/validate-kustomizations.sh
```

## Synthetic substitutions

Flux replaces deployment settings after Kustomize renders a source. CI uses deterministic non-secret values so render validation does not depend on the live `flux-domain-vars` Secret.

| Variable | CI value |
|---|---|
| `DOMAIN` | `ci.example.invalid` |
| `ACME_EMAIL` | `ci@example.invalid` |
| `KONG_LB_IP` | `192.0.2.10` |
| `KONG_EXTERNAL_LB_IP` | `192.0.2.11` |
| `MIKROTIK_IP` | `192.0.2.12` |
| `GOODWE_INVERTER_CIDR` | `192.0.2.0/24` |

The domain is reserved for examples, and the addresses come from the TEST-NET-1 documentation range. The check fails if a rendered manifest contains another unresolved uppercase Flux placeholder, making new substitutions explicit.

## Scope and limits

This check catches missing resources, invalid Kustomize structure, failed generators or patches, unexpected empty renders, and undocumented Flux substitutions. The `services/` and `workloads/apps/` aggregators are explicitly allowed to render empty because their resources are owned by dedicated Flux Kustomizations; any other empty root fails.

The check does not apply resources, contact the Kubernetes API, fetch secrets, evaluate admission webhooks, or validate custom resources against CRDs. Runtime and admission behavior still require the component-specific validation described in its runbook.
