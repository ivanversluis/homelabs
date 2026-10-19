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
4. Unseal the source via `kubectl -n vault-raft-rehearsal exec -i vault-file-source -- vault operator unseal -` (type one share on stdin, repeat with a different share). Use `kubectl -n vault-raft-rehearsal exec vault-file-source -- vault status`.
5. Create synthetic KV v2 + policy + auth/SSH fixture on the source with a separately scoped temporary token; verify readback and record non-secret checksums/counts. Set `VAULT_ADDR=http://127.0.0.1:8200` within the pod; do not log token values.
6. **Stop** the file backend: `kubectl -n vault-raft-rehearsal delete pod vault-file-source --wait=true`. Confirm no process mounts `vault-file-source` and both PVCs are Bound. Retain an independently verified cold copy of the synthetic file tree if testing rollback.
7. `kubectl apply -f infra/vault/candidates/raft-ha/rehearsal/migrate-job.yaml`; `kubectl -n vault-raft-rehearsal wait --for=condition=Complete job/vault-file-to-raft --timeout=10m`. Inspect job logs for migration **success only**, never dump storage. Failure is a stop gate; do not rerun over a nonempty Raft target.
8. **Critical:** before starting chart, provision the matching Raft claims and keep the migrated `data-vault-0` intact. Install chart with `helm upgrade --install vault hashicorp/vault --version 0.34.1 -n vault-raft-rehearsal -f <rehearsal-values.yaml>` where values are copied from the candidate's `spec.values` and namespace-specific selectors remain `vault`. Set initial `server.ha.replicas=1`. Pin `server.image.tag=2.0.4`. The chart's `data-vault-0` must bind to the migrated claim; **check before starting** and verify exact PV identity. The candidate contains production node names and is NOT itself a helm values file.
9. Unseal **vault-0 with synthetic source shares**, never run `vault operator init`; verify synthetic data, policies, SSH fixtures, and Kubernetes auth structure.
10. Upgrade to three replicas (same Helm release, no PVC deletion). For each `vault-1` and `vault-2`, confirm new claim `data-vault-1/2`, join using `vault operator raft join http://vault-0.vault-internal:8200` from its pod, then enter synthetic shares via `scripts/lifecycle/vault-unseal-ha.sh` with `VAULT_NAMESPACE=vault-raft-rehearsal`.
11. With an authenticated Vault CLI on the current active server, verify `vault operator raft list-peers` has three **voters** and `vault operator raft autopilot state` is healthy. Confirm one pod per worker (`kubectl get pod -o wide`), three 10Gi Longhorn RWO Bound PVCs, and the PDB `maxUnavailable: 1`.
12. Restart **the leader only**, manually unseal it if required, and prove surviving quorum serves synthetic reads before unsealing the restarted node. Verify Raft peers/Autopilot and client readiness again. Note: PDB covers voluntary eviction, not arbitrary `kubectl delete pod`.
13. Capture a **synthetic Raft snapshot** to an independent client with `vault operator raft snapshot save <local-file>`. Record SHA-256, inspect file size and test snapshot restoration **into an empty disposable rehearsal cluster**; do not overwrite an active cluster.
14. Rehearse rollback separately: halt Raft pods, restore the independently captured synthetic file data on a fresh source claim, boot standalone and unseal with synthetic shares. Validate the same fixture. A rollback to a pre-cutover filesystem copy loses **all Raft-era writes**.

**Exit:** record times (RTO), snapshot age (RPO), three voters, placement, failover, source restore, missing dependencies and any issues; only then approve a production maintenance window.

**Cleanup after evidence:** uninstall rehearsal Helm release first, delete job/pods, then namespace. `longhorn-worker` PV reclaimPolicy is **Retain**, so identify and remove ONLY synthetic PVs/Longhorn volumes after independently verifying names. Do not accidentally delete the production PV.

**Stop immediately** on any unknown state, initialization prompt for migrated data, changed node IDs, unexpected claim binding, or any real secret entering rehearsal.
