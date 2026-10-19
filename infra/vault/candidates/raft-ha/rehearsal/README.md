# Synthetic Vault 2.0.4 file-to-Raft rehearsal (issue #256)

**Manual only. Not referenced from a Flux Kustomization.** Rehearsal uses only synthetic secrets and an isolated namespace. No production backup, Shamir share, or root token may enter this namespace.

## Rehearsal prerequisites

- `kubectl`, `helm`, `jq` and a local `vault` CLI matching **2.0.4** (or `kubectl exec`).
- Three schedulable Longhorn workers, healthy CSI and a temporary disk budget for four 10Gi claims (source + three Raft nodes).
- Chart **vault 0.34.1** (same as production Git), Vault image **2.0.4**, `longhorn-worker`.
- Never run this against namespace `vault`. Run from repository root; record results in a private operator log **without token/share values**.

## Steps

1. `kubectl apply -f infra/vault/candidates/raft-ha/rehearsal/base.yaml`
2. `kubectl -n vault-raft-rehearsal wait --for=condition=Ready pod/vault-file-source --timeout=5m` (pod has no readiness probe; if pending inspect scheduling/Longhorn).
3. `kubectl -n vault-raft-rehearsal exec vault-file-source -- vault operator init -key-shares=3 -key-threshold=2`. **Capture synthetic** shares/token securely in temporary local operator custody, not Git, ticket or shell history.
4. Unseal the source by running `kubectl -n vault-raft-rehearsal exec -it vault-file-source -- vault operator unseal` **twice**, entering a **different synthetic Shamir share** at the CLI's hidden interactive prompt each time. **Do not add `-`**: `vault operator unseal -` treats it as the key and fails with HTTP 400 (`key must be a valid hex or base64 string`). If that error already happened, do **not** reinitialize; simply run the corrected interactive command. Confirm `Initialized: true`, `Sealed: false` using `kubectl -n vault-raft-rehearsal exec vault-file-source -- vault status`. Never place shares on command arguments, in shell history, Git or chat.
5. Create synthetic KV v2 + policy + auth/SSH fixture on the source with a separately scoped temporary token; verify readback and record non-secret checksums/counts. Set `VAULT_ADDR=http://127.0.0.1:8200` within the pod; do not log token values.
6. **Stop** the file backend: `kubectl -n vault-raft-rehearsal delete pod vault-file-source --wait=true`. Confirm no process mounts `vault-file-source` and both PVCs are Bound. Retain an independently verified cold copy of the synthetic file tree if testing rollback.
7. `kubectl apply -f infra/vault/candidates/raft-ha/rehearsal/migrate-job.yaml`; `kubectl -n vault-raft-rehearsal wait --for=condition=Complete job/vault-file-to-raft --timeout=10m`. Inspect job logs for migration **success only**, never dump storage. Failure is a stop gate; do not rerun over a nonempty Raft target.
8. **Critical: isolate rehearsal Helm from the live production release.** The official chart defaults `server.authDelegator.enabled=true`, creating the **cluster-scoped** `ClusterRoleBinding/vault-server-binding`, which is already owned by the production `vault` release. Never remove, rename, adopt or re-annotate that production binding. For **synthetic rehearsal only**, set `server.authDelegator.enabled=false`; Kubernetes `TokenReview`/Kubernetes-auth validation is outside this rehearsal's test coverage. Keep the production setting unchanged.

   Before starting Vault, keep the migrated `data-vault-0` claim Bound to the **same verified Longhorn PV**; preserve the old source claim and cold backup. Use local Python `yq` (the `jq` wrapper) to extract the candidate values, then render and verify:

   ```bash
   VALUES=/tmp/vault-raft-rehearsal-values.yaml
   yq -y '.spec.values | .server.ha.replicas = 1 | .server.authDelegator.enabled = false' \
     infra/vault/candidates/raft-ha/helmrelease.yaml > "$VALUES"
   helm repo add hashicorp https://helm.releases.hashicorp.com --force-update
   helm template vault hashicorp/vault --version 0.34.1 \
     -n vault-raft-rehearsal -f "$VALUES" > /tmp/vault-raft-rehearsal-render.yaml
   yq -r 'select(.kind == "ClusterRole" or .kind == "ClusterRoleBinding") | .kind + " " + .metadata.name' \
     /tmp/vault-raft-rehearsal-render.yaml
   yq -r 'select(.kind == "StatefulSet" and .metadata.name == "vault") | \
     [.spec.replicas, .spec.volumeClaimTemplates[0].metadata.name, .spec.volumeClaimTemplates[0].spec.storageClassName] | @tsv' \
     /tmp/vault-raft-rehearsal-render.yaml
   helm list -n vault-raft-rehearsal -a
   ```

   The cluster-scoped resource check must print **nothing**; the StatefulSet must print `1 data longhorn-worker` (tab-separated), with enforced per-worker node affinity and pod anti-affinity. An affinity merge warning may appear because the chart's default is a string but the candidate is a map; verify the **rendered** affinity rather than assuming it was lost. If `helm list` shows any existing release, **stop and inspect** instead of installing over it. Only with correct output, install with `helm install vault hashicorp/vault --version 0.34.1 -n vault-raft-rehearsal -f "$VALUES"` (no `--wait`: the new instance is sealed). Inspect that `vault-0` binds the migrated `data-vault-0`, and stop if Vault reports `Initialized=false`. **Never `operator init` migrated storage.** Production `infra/vault/helmrelease.yaml` must remain untouched.
9. Unseal **vault-0 with synthetic source shares**, never run `vault operator init`; verify synthetic data, policies, SSH fixtures, and Kubernetes auth structure.
10. Upgrade to three replicas (same Helm release, no PVC deletion). For each `vault-1` and `vault-2`, confirm new claim `data-vault-1/2`, join using `vault operator raft join http://vault-0.vault-internal:8200` from its pod, then enter synthetic shares via `scripts/lifecycle/vault-unseal-ha.sh` with `VAULT_NAMESPACE=vault-raft-rehearsal`.
11. With an authenticated Vault CLI on the current active server, verify `vault operator raft list-peers` has three **voters** and `vault operator raft autopilot state` is healthy. Confirm one pod per worker (`kubectl get pod -o wide`), three 10Gi Longhorn RWO Bound PVCs, and the PDB `maxUnavailable: 1`.
12. Restart **the leader only**, manually unseal it if required, and prove surviving quorum serves synthetic reads before unsealing the restarted node. Verify Raft peers/Autopilot and client readiness again. Note: PDB covers voluntary eviction, not arbitrary `kubectl delete pod`.
13. Capture a **synthetic Raft snapshot** to an independent client with `vault operator raft snapshot save <local-file>`. Record SHA-256, inspect file size and test snapshot restoration **into an empty disposable rehearsal cluster**; do not overwrite an active cluster.
14. Rehearse rollback separately: halt Raft pods, restore the independently captured synthetic file data on a fresh source claim, boot standalone and unseal with synthetic shares. Validate the same fixture. A rollback to a pre-cutover filesystem copy loses **all Raft-era writes**.

**Exit:** record times (RTO), snapshot age (RPO), three voters, placement, failover, source restore, missing dependencies and any issues; only then approve a production maintenance window.

**Cleanup after evidence:** uninstall rehearsal Helm release first, delete job/pods, then namespace. `longhorn-worker` PV reclaimPolicy is **Retain**, so identify and remove ONLY synthetic PVs/Longhorn volumes after independently verifying names. Do not accidentally delete the production PV.

**Stop immediately** on any unknown state, initialization prompt for migrated data, changed node IDs, unexpected claim binding, or any real secret entering rehearsal.
