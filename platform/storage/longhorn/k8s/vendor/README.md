# Reviewed Longhorn v1.12.1 artifacts

These files are inert: the active Kustomization still references the v1.11.0 upstream URL.

- Upstream repository: `longhorn/longhorn`
- Release: `v1.12.1` (stable)
- Immutable upstream commit: `f349c091c50700cb6cb8a4df8aaa29ea214bdd48`
- Retrieved: 2026-09-11 over HTTPS from `raw.githubusercontent.com/longhorn/longhorn`
- Manifest: `deploy/longhorn.yaml` (5,783 lines, 52 YAML documents)
- Image inventory: `deploy/longhorn-images.txt`
- Integrity: locally computed SHA-256 values are recorded in `SHA256SUMS`

Review notes: the manifest is an upstream Helm-rendered Kubernetes bundle. It contains the
expected Longhorn CRDs, namespace-scoped workloads, one ClusterRole, hostPath mounts, and one
privileged workload required by Longhorn's node/storage integration. It contains no shell
download pipeline. Manifest image references match the separately retrieved upstream image
inventory; that inventory additionally lists `longhorn-cli`, which is not a static workload
image in the rendered manifest.

Before activation, verify:

```bash
cd services/storage/longhorn/k8s/vendor
sha256sum -c SHA256SUMS
```

Activation requires an explicit operator approval and the successful read-only Semaphore
Wave 1 preparation gate. Never apply this manifest directly; activate it only through the
documented Git/Flux diff.
