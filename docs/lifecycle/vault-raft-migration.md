# Vault #256 — gated file-to-Raft HA migration

**Status as of 2026-10-19: synthetic file -> Raft HA, failover and independent snapshot verification PASSED; isolated snapshot restore target staged but NOT initialized; production cutover NOT APPROVED.** The operator confirmed Vault 2.0.4, existing standalone `file` backend on k8s-master01 with retained local-path PV, healthy Longhorn/workers and manual Shamir custody. Git still deploys chart 0.34.1 in production standalone mode. The candidate `infra/vault/candidates/raft-ha/helmrelease.yaml` remains **excluded from live GitOps Kustomizations**.

**Detailed engineering report and tomorrow's exact recovery checkpoint:** [Vault migration rehearsal — 2026-10-19](./vault-raft-migration-rehearsal-2026-10-19.md). The [rehearsal README](../../infra/vault/candidates/raft-ha/rehearsal/README.md) remains the procedural manifest guide. Review [PR #355](https://github.com/ivanversluis/homelabs/pull/355) before merging; its current scope now includes Helm RBAC isolation, Raft directory initialization, Calico rehearsal policy, isolated restore manifests and evidence.

## Recovery objective and limits

**Proposed, pending owner acceptance:** withstand loss of one worker/member (Raft majority 2/3); 30–60 minute RTO with manual Shamir unseal; 24h RPO with successful daily **off-cluster Raft snapshots**. Quorum does not auto-unseal a restarted sealed member. Two simultaneous failures lose quorum. Longhorn's two replicas per PVC and Raft's three independent data sets serve different purposes. Backups and Shamir shares must not share a single failure domain.

## Rehearsal checkpoint and still-open blockers (2026-10-19)

**Observed complete:** synthetic cold backup, offline `vault operator migrate`, three independent Longhorn Raft voters, manual Shamir unseal, KV/policy/userpass/SSH CA readback, successful leader failover and return to three healthy voters (Autopilot Healthy=true, Failure Tolerance=1). Raft snapshot index 153/term 4 transferred off-cluster with matching SHA-256 `1332b62341b992e108927524df2170d5232616a8f35ca52abf971e45f7c42e15`.

**Safe stop:** a separate `vault-raft-restore-test` target was created with an independent 10Gi PVC, loopback listener and denied network access. Its Vault 2.0.4 status is `Initialized=false`, `Sealed=true`. **Do not run init, restore, peer recovery or cleanup until the next supervised session.** Original 3-voter rehearsal remains healthy. Read-only resume commands and mandatory gates are in the linked field report.

**Critical remaining gates:** (1) initialize, restore and verify the snapshot in the isolated disposable target, including restored seal-key handling and possible isolated lost-quorum recovery; (2) rehearse original file cold-backup rollback; (3) fix probe-induced liveness restarts using startup grace and one-at-a-time validation; (4) verify production Kubernetes-auth RBAC/TokenReview, ESO, SSH signing and Semaphore, plus monitoring; (5) deploy/test off-cluster daily snapshot automation and settle RTO/RPO, custody and maintenance decisions. **The production cutover is not cleared.**

**Operational warning:** do not use legacy `scripts/vault-post-deploy.sh` to perform this migration or HA recovery; it assumes a single Vault pod and may initialize/handle key material. Use the review helper `scripts/lifecycle/vault-unseal-ha.sh` and interactive, threshold-held shares only after confirming `Initialized=true`.

## Hard preparation gates

- Independent `admin`/`wheel` SSH path functional without Vault/Semaphore; declare maintenance window and a downtime notice for ESO, SSH signing and Semaphore.
- Rehearsal passes all steps in [rehearsal/README.md](../../infra/vault/candidates/raft-ha/rehearsal/README.md) with Vault **2.0.4**; capture non-secret evidence of three voters, Autopilot, failover, readback and **rollback**.
- Fresh offline `/vault/data` backup **after source shutdown**, SHA-256 verified locally and on Synology. Do not use an online tarball. Back up PV/PVC YAML, namespace, Helm release version, Flux configuration and record immutable PV identity. Do not paste contents, Vault key shares or tokens into ticket/PR.
- Confirm 3 distinct ready workers and sufficient Longhorn capacity. Retained local-path PV must still show `Retain`. `longhorn-worker` StorageClass is `WaitForFirstConsumer`, `Retain`, RWO with 2 storage replicas.
- Independently held threshold Shamir shares, checked in advance **outside** Kubernetes, GitHub, Vault, Semaphore, local-path/Longhorn and the same Synology backup set.
- Backup restore and snapshot/off-cluster transfer credentials are independent of Vault and Semaphore (avoid circular bootstrap).
- Agree downtime, rollback deadline, RTO/RPO, stop/go owner, where the daily snapshot jobs run, credentials, offsite destination, retention, immutability and snapshot restore validation. **No daily Raft snapshot job is deployed by this PR**; do not claim RPO 24h until that is installed and tested.
- Confirm network policy/API reachability between all three Vault members on 8200 and 8201. TLS is disabled for API because this matches the current private-cluster architecture; internal Raft transport still uses Vault cluster TLS. Secure external ingress and revisit API TLS as separate follow-up.
- Confirm `Vault` executable and HashiCorp `operator migrate` availability at the pinned release, source config, `node_id`, and resulting storage layout from the rehearsal.

## Pre-cutover non-secret inventory

```bash
kubectl -n vault get pods -o wide
kubectl -n vault get pvc -o wide
kubectl -n vault get sts vault -o yaml > vault-sts-before.yaml
PV=$(kubectl -n vault get pvc data-vault-0 -o jsonpath='{.spec.volumeName}')
kubectl get pv "$PV" -o custom-columns=NAME:.metadata.name,CLASS:.spec.storageClassName,RECLAIM:.spec.persistentVolumeReclaimPolicy
kubectl get nodes -o wide
kubectl -n longhorn-system get volumes.longhorn.io
kubectl -n flux-system get kustomizations
kubectl -n vault get helmrelease vault -o yaml > vault-helmrelease-before.yaml
```

## Production migration (human executed, maintenance only)

1. **Suspend the controlling Flux Kustomization AND HelmRelease**, and any Argo CD controller if it also owns these objects; verify reconciliation truly stopped. Since `infra/vault` sits under `infra/kustomization.yaml`, check actual Flux ownership, not a guessed name. Example: `flux suspend helmrelease vault -n vault` and `flux suspend kustomization flux-system -n flux-system` **only if** that is its actual parent; suspending the root Flux configuration impacts the whole cluster, so design a narrower GitOps boundary before production when possible.
2. Stop all Vault-dependent writes, scale old standalone `statefulset/vault` to zero, wait until pod and local volume are unmounted. Take **new cold backup**, verify its checksums and the independent Synology copy. A pre-stop backup is **not** a final cold backup. Preserve the old PVC/PV untouched with `Retain`; no direct `kubectl delete pv` or destructive patch.
3. Do **not** mutate old `data-vault-0` into Longhorn: its storage class is immutable, and StatefulSet `volumeClaimTemplates` cannot be modified in place. Plan an explicit **StatefulSet replacement** after owner signoff, with old PVC removed **only after** its retained PV + cold backup are verified. The retained old PV may require a later explicit rebinding to a new local-path claim for rollback. Do not repurpose the same name while it is bound. Snapshot PVC/PV metadata first.
4. Stage the **source as a separate, verified cold-backup restore** into a temporary accessible scratch claim or offline directory (do not use the live retained source PV as a migration input). Preserve source backup immutable. Provision the **destination** in `longhorn-worker` separately and mount into a one-shot Vault 2.0.4 migration job. Because of local-path scheduling, the migration worker must be able to mount both source **scratch copy** and destination; test this in rehearsal. The synthetic rehearsal job and config are templates, not production commands.
5. Use `vault operator migrate -config=<verified-migration.hcl>` with `storage_source "file"` at scratch source, `storage_destination "raft"` at a **new empty** Longhorn volume, and `node_id = "vault-0"`. The final Vault storage stanza is `storage "raft" { path = "/vault/data/raft" }` and `VAULT_RAFT_NODE_ID=vault-0`. Check the exact Raft destination directory and `node_id` from rehearsal **before** migration. Do not initialize migrated storage.
6. Before installing new chart, safely arrange the migrated destination as **exactly** `data-vault-0` in `vault`, correctly Bound to its retained Longhorn PV and with class `longhorn-worker`; inspect `kubectl get pvc -o wide`. The old retained local-path PV/PVC must be isolated. **Never start Vault until the PVC bound to the intended migrated volume is verified**, and never delete the Longhorn PV while rebinding. StatefulSet name and service remain `vault` to preserve ESO `http://vault.vault.svc.cluster.local:8200`.
7. In the approved maintenance window, manually activate the candidate Helm values with `server.ha.replicas: 1` initially. Avoid relying on Helm upgrade to mutate StatefulSet volume templates: **retire/delete the old StatefulSet with orphan-safe retention after verifying no old pods and then install/reconcile the new StatefulSet**. Observe Helm ownership and immutable volume template behavior; validate with dry-run and rehearsal. Do not merge the candidate into `infra/vault/kustomization.yaml` automatically.
8. Start only `vault-0`, manually unseal using **original** Shamir shares; verify initialized=true, KV mounts, policies, Kubernetes auth, SSH signing CA identity/public key, policy reads, synthetic test writes/reads and expected data. **Stop if it asks to initialize**.
9. Scale to three Raft pods; each gets a fresh 10Gi RWO claim in `longhorn-worker`. On each **uninitialized follower**, run `vault operator raft join http://vault-0.vault-internal:8200` **before** manual unseal, one at a time; do not `operator init`. Use `scripts/lifecycle/vault-unseal-ha.sh` from a trusted TTY with separately held shares. Never pass shares on argv/history.
10. Require `vault operator raft list-peers` to show 3 voter IDs `vault-0`, `vault-1`, `vault-2`; `vault operator raft autopilot state` healthy; verify all three hostnames distinct; PDB maxUnavailable=1; three 10Gi Bound RWO claims, no old PVC mounted.
11. Planned leader failover: first prove quorum, restart the current leader in a controlled window, confirm two remaining members elect/serve writes, manually unseal restarted pod, revalidate peer IDs/quorum. A PDB governs voluntary eviction **not all deletions**. Validate readiness for active+standby endpoints.
12. Confirm External Secrets store Ready and actual secret reconciliation, Vault SSH signing and certificate validation without exposing private key, Semaphore recovery task and Grafana/health checks. Independently save an authenticated `vault operator raft snapshot save <filename>`, checksum and move off-cluster. Verify off-cluster checksum and rehearse restore into empty isolated Raft test cluster.
13. Only after all gates pass, commit approved candidate as active HelmRelease, then **resume** correct Flux scopes. Monitor at least one complete backup cycle and agreed rollback interval. Snapshot scheduling and credential handling need a follow-up deployment before promising 24h RPO.
14. Preserve original local-path retained PV and a verified cold backup through rollback period. Do not garbage-collect it as part of PR.

## Rollback

**Stop point:** any unexpected 404/503, uninitialized Vault after migration, mismatch in KV/policies/SSH CA, missing voting peer, incorrect Longhorn binding, or test failure. Stop new writes immediately. Suspend Flux, shut down **all** Raft Vault pods, preserve Raft PVCs and take a diagnostic snapshot if cluster is healthy. Restore the **original** standalone HelmRelease and its file configuration; recreate the old StatefulSet and explicitly rebind its PVC to the retained original local-path PV using previously recorded PV metadata and claim identity, without modifying backend data. Manually unseal with the original shares. Validate ESO/SSH signer/Semaphore. **Rollback recovers state only up to the cold-backup cutover point**; any post-migration writes are not in the old file backend and require an application-level replay/restore decision. Never initialize or overwrite either backend as a rollback shortcut.

## Reference and ownership

- Candidate: `infra/vault/candidates/raft-ha/helmrelease.yaml` (excluded from GitOps).
- Rehearsal: `infra/vault/candidates/raft-ha/rehearsal/README.md`.
- HA helper: `scripts/lifecycle/vault-unseal-ha.sh`.
- Historic standalone restore: `docs/lifecycle/restore-runbook.md`.
- HashiCorp: https://developer.hashicorp.com/vault/docs/commands/operator/migrate ; https://developer.hashicorp.com/vault/docs/commands/operator/raft ; https://developer.hashicorp.com/vault/docs/concepts/integrated-storage
