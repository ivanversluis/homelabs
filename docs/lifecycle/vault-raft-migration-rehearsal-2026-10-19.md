# Vault file-to-Raft HA — architecture, rehearsal evidence and operator handover

**Issue:** [#256](https://github.com/ivanversluis/homelabs/issues/256)  
**Review PR:** [#355](https://github.com/ivanversluis/homelabs/pull/355)  
**Rehearsal date:** 19 October 2026 (Europe/Amsterdam)  
**Scope:** synthetic data only, manually applied Kubernetes resources, no production changes  
**Status at stopping point:** migration/HA/failover/snapshot proven; isolated restore target **created but NOT initialized**, restore NOT performed  
**Companion authoritative cutover guide:** [vault-raft-migration.md](./vault-raft-migration.md)  
**Step-by-step synthetic manifest instructions:** [rehearsal/README.md](../../infra/vault/candidates/raft-ha/rehearsal/README.md)

> This is an evidence-based *engineering record and learning guide*, not a production change authorization. Configurations documented as observed were confirmed from operator outputs; current desired state was inspected via the GitHub App. No real data, Shamir share or token was copied to the rehearsal or to Git. Do not run destructive steps from this document without satisfying every explicit gate.

## 1. Executive summary

Vault currently underpins External Secrets Operator (ESO), short-lived SSH certificates for Semaphore/Ansible, and application secret delivery. Its production deployment is a **single standalone Vault process with the file storage backend**. Kubernetes/Longhorn storage availability and a healthy Vault process are different concerns; the old deployment also requires **manual Shamir unseal** after restart.

We proved the *feasibility* of converting a synthetic Vault 2.0.4 file backend into integrated Raft storage, running a three-member HA cluster on distinct Longhorn worker nodes, retaining data and SSH CA identity, recovering from one leader outage, and exporting an application-consistent snapshot. These successes **do not** authorize a production migration. A fresh isolated snapshot restore, file-backend rollback, liveness/startup-probe correction, application integration tests and owner approval are still outstanding.

### Observed outcome table

| Milestone | Evidence | Status |
| --- | --- | --- |
| File-source initialized and fixtures written | KV, policy, userpass, SSH signer; synthetic Shamir 3 shares / threshold 2 | PASS |
| Independent file cold backup | `file-cold.tgz`, local checksum and archive integrity verified | PASS (synthetic) |
| Offline file -> Raft migration | One-shot job: “All of the keys have been migrated.” | PASS |
| New Raft leader | `vault-0` initialized, unsealed, data readable | PASS |
| Two then three members | Explicit join, original synthetic shares, 3/3 voters on distinct workers | PASS |
| Autopilot and placement | `Healthy=true`, `Failure Tolerance=1`, synchronized indexes | PASS |
| Leader loss and recovery | `vault-0` restarted, `vault-1` elected, data readable, `vault-0` re-unsealed | PASS |
| Independent Raft snapshot | index 153, term 4, SHA-256 identical on pod and workstation | PASS |
| Separate restore test | isolated pod, separate 10Gi PVC, `Initialized=false`, `Sealed=true` | PREPARED; **NOT STARTED** |
| Snapshot restore/readback | new target initialization, snapshot force restore, quorum adjustment, fixture verification | PENDING |
| Rehearsed return to file backend | restore independently retained cold file copy, verify fixtures | PENDING |
| Liveness/startup behavior | initial probe-induced restarts; liveness disabled temporarily in rehearsal | **OPEN BLOCKER** |
| Production integrations/controls | ESO, Semaphore/SSH signer, Kubernetes TokenReview and monitoring | NOT TESTED in this synthetic exercise |
| Production cutover | old storage and live dependencies must remain untouched | NOT APPROVED |

## 2. Motivation, boundaries and decisions

The original issue was triggered when a sealed Vault returned HTTP 503 during Wave 3 maintenance and prevented Semaphore from obtaining a Vault-signed SSH certificate. Three-voter Raft solves the **single Vault process** availability problem; it does **not** remove the manual unseal or independent operator access requirement.

- **Manual Shamir is deliberately retained** for this experiment. Synthetic source shares were 3 with threshold 2, reused on the migrated Raft members. Those shares must never appear in CLI arguments, tickets, logs, Git or this report.
- **Raft and Longhorn provide different failure protection.** Three Raft voters require any two to continue serving; Longhorn separately supplies replicated PVC block storage. Each Vault voter must have its *own* 10Gi RWO PVC and be placed on a distinct worker.
- **Proposed objectives, not accepted SLOs:** tolerate one member/worker loss; 30–60-minute operator-mediated RTO; <=24-hour RPO **only after** automated verified daily off-cluster Raft snapshots and restoration are operational.
- **Keep an independent break-glass path.** The existing admin/wheel access, key custodians and backups must not rely on Vault, ESO or Semaphore.
- **No production change has been applied.** The active file backend remains in `infra/vault/helmrelease.yaml`; the candidate in `infra/vault/candidates/raft-ha/helmrelease.yaml` is excluded from Flux Kustomizations.
- **Review PR isolation:** rehearsal Helm must use `server.authDelegator.enabled=false` to avoid claiming the production-owned cluster-wide `vault-server-binding`. This cannot count as validation of production Kubernetes authentication.

## 3. Architecture and storage flow

~~~text
                         PRODUCTION (unchanged)
        namespace vault / standalone file backend
                existing retained local-path PV
                         (NOT touched)
                             |
              independent admin / cold backup
                             |
                             v
                    SYNTHETIC rehearsal only
 namespace vault-raft-rehearsal
  vault-file-source PVC --(cold stop + backup)--> migration Job
             `file`                             file -> raft
                                                 |
                                                 v
                                    data-vault-0 (Longhorn)
                                          vault-0
                                   leader originally on
                                       worker03
                                          |
                        Raft cluster TCP/8201 (internal TLS)
                                   /               \
                           data-vault-1        data-vault-2
                              vault-1             vault-2
                             worker01            worker02
                            (new leader)           (voter)
                                   |
                           snapshot index 153
                                   |
                        authenticated snapshot save
                                   v
             /home/ivan/vault-rehearsal-backups/raft-ha-20261019.snap
                        independent local copy
                                   |
                    ISOLATED restore staging only
 namespace vault-raft-restore-test; deny-all ingress + egress
      no Service / no SA token / loopback-only listener
                     vault-restore + fresh PVC
                      initialized=false, sealed=true
                     SNAPSHOT NOT RESTORED YET
~~~

Vault chart **0.34.1**, Vault image **2.0.4**, Raft directory **/vault/data/raft**, worker StorageClass **longhorn-worker**. On the candidate, topology hard constraints select workers 01/02/03 and pod anti-affinity prevents two voters on the same worker. `OnDelete` avoids automatic pod rollout/unseal; operators must handle individual replacements explicitly. The chart uses private-cluster HTTP on port 8200; Vault's internal cluster communication uses port 8201. Review API TLS independently before production.

## 4. Evidence: exact infrastructure identities

### Namespace and source/destination boundaries

| Purpose | Namespace | Resource | Bound PV | Observed state |
| --- | --- | --- | --- | --- |
| Synthetic source | vault-raft-rehearsal | vault-file-source | pvc-3e062ce6-8ca7-4d2c-9a43-fcce41a01c5e | 10Gi Bound; source pod stopped |
| Migrated leader | vault-raft-rehearsal | data-vault-0 | pvc-a074dc12-06c1-4f21-bb26-e0b736ecc59e | 10Gi Bound |
| Raft peer 1 | vault-raft-rehearsal | data-vault-1 | pvc-59e801eb-bb6a-4f5a-9f8c-2b21a1403e7a | 10Gi Bound |
| Raft peer 2 | vault-raft-rehearsal | data-vault-2 | pvc-a8421171-e14f-4d59-b24e-8a51294e2c72 | 10Gi Bound |
| Independent restore TARGET | vault-raft-restore-test | vault-restore-data | pvc-ff2f8187-15c0-4556-ae5b-779eb611ae7d | 10Gi Bound; **empty/uninitialized target** |

**Do not use these PV identifiers as deletion or patch targets.** Revalidate on the cluster before any operation; a GitHub document is not live state. Production resources are intentionally omitted.

### Data, trust and persistence

| Check | Observed result |
| --- | --- |
| KV v2 engine/key | `rehearsal/fixture` -> value `synthetic-only` |
| ACL | `rehearsal-read` policy: read `rehearsal/data/fixture` |
| Auth method | `userpass/` persisted across migration |
| Secret engines | `rehearsal/` KV and `ssh-test/` SSH persisted |
| SSH CA public key SHA-256 | `01f57f9cb24a9b8ce03f98a0c7eca5986238d383b02ada96bd110f50a945569f` |
| Original file cold archive SHA-256 | `cde4506b48b230990aeac55b016d1404569795d4c715b052325992553e537efd` |
| Vault Raft cluster | `vault-cluster-23fb06b6`; ID `4f13cd74-a8f9-75a7-ae6a-25f9462e3192` |
| Raft snapshot | 19 October 2026, `bolt-snapshot`, index 153, term 4, v1, ~27.7KiB |
| Snapshot SHA-256 | `1332b62341b992e108927524df2170d5232616a8f35ca52abf971e45f7c42e15` |
| Local copy permissions | `0600`; path `/home/ivan/vault-rehearsal-backups/raft-ha-20261019.snap` |

The snapshots contain recoverable Vault state and must be treated as highly sensitive even when the content is synthetic. Hashes are evidence of integrity, not a substitute for testing restore, backup retention or offsite redundancy.

## 5. Rehearsal sequence (completed)

1. Created `vault-raft-rehearsal`, source pod/PVC and the destination `data-vault-0` PVC.
2. Initialized **synthetic-only** file Vault with 3 Shamir shares / threshold 2. Unsealed interactively with two distinct shares, added test secrets, a policy, `userpass/`, an SSH CA.
3. Stopped the source pod. Captured/verified `file-cold.tgz` and SHA-256 before touching source storage. No Vault process was left writing to the source.
4. Ran the one-shot `vault operator migrate` Job against the file source and an **empty** Raft destination, using Raft ID `vault-0`. Job completed successfully. **Do not rerun** against this initialized destination.
5. Rendered the review candidate's Helm values for **one replica**, temporarily disabled `authDelegator` *only in rehearsal*, installed directly with Helm into the rehearsal namespace. The production release/ClusterRoleBinding were never adopted.
6. After investigating probe timeouts, disabled liveness *for the rehearsal only*, recreated `vault-0` under `OnDelete`, observed HTTP 503 while sealed, then manually unsealed. Data, policy, mounts and SSH CA hash matched source.
7. Scaled to **two** replicas. Fixed missing Raft subdirectory initialization on fresh Longhorn PVC with a non-root `prepare-raft-directory` init container. Explicitly joined and unsealed `vault-1`; it became a healthy voter.
8. Scaled to **three**. Joined/unsealed `vault-2`. It was initially a non-voter during Raft catch-up; Autopilot later promoted it to a voter. All three pods became 1/1 Ready, with no restarts and one pod per worker.
9. Proved `Healthy: true`, `Failure Tolerance: 1`, three voters and synchronized indexes. Restarted **only the original leader vault-0**. Surviving quorum elected `vault-1`; the synthetic KV read still succeeded.
10. Re-unsealed the restarted `vault-0`; it rejoined as standby. Autopilot returned to Healthy/FT=1 with indexes synchronized (observed at 151).
11. Saved and inspected a snapshot on the active `vault-1`, independently copied it to a private workstation file and verified matching SHA-256.
12. Created a **third** isolated namespace `vault-raft-restore-test`, applied deny-all first, provisioned a new 10Gi PVC, started an isolated Vault target. Verified it is **not initialized** and is **sealed**. **Stopped here.**

**No measured time-series RTO or RPO exists.** Clock timestamps and status messages in this conversation must not be relabeled as an approved SLO.

## 6. Findings and corrections

### A. Cluster-scoped Helm RBAC ownership conflict

The chart defaults to creating `ClusterRoleBinding/vault-server-binding`, already owned by the active production release. A second same-named Helm release fails adoption.

**Rehearsal fix:** persist `server.authDelegator.enabled=false` throughout every install/upgrade and verify a rendered template contains no surprise `ClusterRole` / `ClusterRoleBinding`. **Production:** retain or explicitly redesign TokenReview RBAC; do not quietly disable authentication delegation.

~~~bash
VALUES=/tmp/vault-raft-rehearsal-values.yaml
helm template vault hashicorp/vault --version 0.34.1 \
  -n vault-raft-rehearsal -f "$VALUES" > /tmp/vault-rehearsal-render.yaml
yq -r 'select(.kind == "ClusterRole" or .kind == "ClusterRoleBinding") | .kind + " " + .metadata.name' \
  /tmp/vault-rehearsal-render.yaml
~~~

The last check must emit **nothing**. Local `yq` in this rehearsal is the Python/jq-wrapper variant; use its `-y` / `-r` syntax, not Mike Farah-specific flags. Prior Codex feedback requested retaining RBAC override during replica upgrades; the documented upgrades now pass the same `-f "$VALUES"` and explicit overrides.

### B. Zero Trust policy missing from new namespace

Calico `zt-default-deny` affects `vault-raft-rehearsal`; the existing production `vault-netpol.yaml` has namespace-specific rules and does **not** apply automatically. A review-only `networkpolicy.yaml` now allows peer communication on TCP 8200/8201, DNS and API egress for the synthetic namespace.

**Distinction:** localhost `127.0.0.1:8200` timeouts were not proof that network policy caused liveness failure. Later API 503 responses and successful manual unseal confirmed the API was reachable. Avoid broadening the global deny or assuming localhost is blocked by it.

### C. Slow HTTP health response / premature restarts

First `vault-0` ran with probe timeouts (3 seconds), returned no timely HTTP headers and was killed by kubelet; exit 137 was a symptom of the probe-triggered kill, **not** proof of OOM. `vault status` and localhost health also initially stalled. With liveness temporarily disabled and an intentional restart, `vault-0` responded HTTP 503 while sealed and became healthy after manual unseal.

**Open defect:** determine whether the root cause is Longhorn startup latency, Raft recovery/I/O, CPU pressure, timeout settings or an actual Vault stall. Design and render a suitable `startupProbe`/liveness grace period, restore probes **one member at a time**, and demonstrate startup, sealed state and recovery with probes enabled. Never accept `livenessProbe.enabled=false` as final production configuration.

### D. Follower PVC lacks nested Raft directory

`vault-1` originally crashed with exit 1:

~~~text
failed to create fsm: failed to open bolt file:
open /vault/data/raft/vault.db: no such file or directory
~~~

The migrated leader's `/vault/data/raft` directory existed because the migration Job created it. Empty follower PVCs lacked the subdirectory. PR #355 adds a non-root init container to `server.extraInitContainers`:

~~~sh
mkdir -p /vault/data/raft
chmod 0700 /vault/data/raft
~~~

It mounts each member's own `data` volume and preserves existing databases. Recreate only a *failing follower pod* after upgrading its template; never delete its PVC. The fix passed on `vault-1` and `vault-2`.

### E. Voter catch-up is asynchronous

`vault-2` initially showed `Voter=false`, last index 0, Autopilot Healthy=false, and FT=0 while catching up. It subsequently became a healthy voter. Do not force-add peers or restart a leader just because a new follower is temporarily non-voting; wait and inspect replication/logs first.

### F. Independent admin and deprecated helper warning

`scripts/lifecycle/vault-unseal-ha.sh` is a manual interactive helper; it **does not** initialize Vault. In contrast, `scripts/vault-post-deploy.sh` is an older *initial bootstrap* script that can initialize Vault and handles key material in ways unsuitable for this HA migration. **Do not run `scripts/vault-post-deploy.sh` during Raft migration, HA recovery, snapshot restore or production cutover.** Its hard-coded single-pod assumptions require a separate security/maintenance review.

## 7. Current checkpoint — safe to leave overnight

**Verified 2026-10-19 (~20:00 CEST, operator outputs):**

- Current kubectl context: `kubernetes-admin@kubernetes`; recheck on resumption.
- Original **production namespace `vault`** remains outside all rehearsal changes, with standalone file backend in Git.
- Three-voter **`vault-raft-rehearsal`** healthy; Autopilot `Healthy=true`, `Failure Tolerance=1`, leader `vault-1`, all peers last index 164 in the last preflight output.
- Snapshot SHA-256: `1332b62341b992e108927524df2170d5232616a8f35ca52abf971e45f7c42e15`. It represents snapshot index 153; cluster index 164 later is expected, not evidence of mismatch.
- New **`vault-raft-restore-test`** PVC `vault-restore-data`, PV `pvc-ff2f8187-15c0-4556-ae5b-779eb611ae7d`, 10Gi Bound.
- Restore pod `vault-restore` reports `Initialized=false`, `Sealed=true`, total shares 0, threshold 0, storage Raft, Vault v2.0.4, exit code 2. It has **NOT** been initialized, unsealed or restored.
- Isolation manifests `restore-isolation.yaml` and `restore-target.yaml` were applied by the operator. The manifest declares deny-all NetworkPolicy, no Service, no automatic service-account token and loopback-only Vault listeners; recheck the **live** NetworkPolicy and Services tomorrow.
- Do not initialize, restore, restart or delete anything merely to “clean up” the environment overnight. Preserve all source and destination PVCs plus both cold backup and Raft snapshot.

## 8. Tomorrow — read-only resumption gate

All commands below are **read-only**. Stop if context, namespace, Vault status, PVC ownership or checksum differs from the expected checkpoints.

~~~bash
kubectl config current-context
kubectl -n vault-raft-restore-test get networkpolicy,pod,pvc,svc -o wide
kubectl -n vault-raft-restore-test exec vault-restore -c vault -- \
  sh -c 'vault status; echo "status exit=$?"'
sha256sum "$HOME/vault-rehearsal-backups/raft-ha-20261019.snap"
kubectl -n vault-raft-rehearsal exec vault-1 -c vault -- \
  vault operator raft autopilot state
kubectl -n vault-raft-rehearsal get pod,pvc -o wide
~~~

Check: context is expected, target `deny-all` applies, no restore-target Service is exposed, target PVC has *its own* PV, target remains `Initialized=false / Sealed=true`, snapshot hash matches, and source Raft is healthy. If a different Raft node is active, direct the Autopilot command at that node instead.

### Subsequent restore run (NOT executed; only after explicit operator go/no-go)

**Prerequisites:** HashiCorp [restore a snapshot](https://developer.hashicorp.com/vault/docs/sysadmin/snapshots/restore) and [lost quorum](https://developer.hashicorp.com/vault/tutorials/raft/raft-lost-quorum) guidance reviewed; isolated network verified; temporary and original synthetic Shamir shares available to distinct authorized custodians. Restore a snapshot from a *different* initialized Vault to the isolated target requires `-force` **because the seal keys differ**, not because force is a safe default. Never use the procedure in `vault` or `vault-raft-rehearsal`.

1. Initialize **ONLY** the new uninitialized `vault-restore` with 3 temporary *synthetic* shares and threshold 2. Carefully capture temporary shares/root token outside Git, logs and shell history. Do not reuse original cluster credentials for target initialization.
2. Unseal the target interactively with two distinct **temporary target** shares; verify it is an independent, initialized *one-node target*. Authenticate to the target using the **temporary target root token** interactively.
3. Copy the verified `raft-ha-20261019.snap` to the target's private `/tmp` using `kubectl exec -i` and redirect into a file, **without `-t`**, then compare SHA-256 in the pod and on the workstation.
4. Only after an explicit gate on namespace, target identity, hash and target root token, perform the official `vault operator raft snapshot restore -force` **on the isolated target**. Do not interpret command return as restore completion: inspect Vault logs and final status. The temporary target token and shares are superseded by the restored snapshot state.
5. Unseal with the **original synthetic source snapshot shares** (not the temporary target shares). If the one-node target cannot form quorum because the 3-voter snapshot's peer configuration is retained, **stop** and plan explicit lost-quorum recovery limited to the target. Never improvise a `peers.json` path; in the official example the `storage "raft"` path differs from ours, so locate actual peer-file directory from the on-disk Raft layout and HashiCorp documentation before editing.
6. After real recovery, validate `Initialized=true`, `Sealed=false`, healthy independent leader/quorum, `synthetic-only` fixture, policy, `userpass/`, `ssh-test/`, and original SSH CA fingerprint. The original three-node source must remain healthy and unchanged.

**Do not automate this sequence yet.** A successful process requires observed state after each gate. No writes must reach real apps or production integrations from the restored snapshot.

## 9. Production migration: gates and change control

The authoritative sequence remains [vault-raft-migration.md](./vault-raft-migration.md). This section documents explicit *missing* gates, not instructions to cut over now.

| Decision/test | Why it matters | Status |
| --- | --- | --- |
| Owner-approved maintenance, change owner and rollback deadline | Prevent unplanned outage | OPEN |
| Live PVC/PV class/Retain, Longhorn topology + capacity record | Avoid losing old local-path data | Operator-reported; reconfirm just before cutover |
| Verified **fresh** cold production file backup + independent Synology checksum | Authoritative point of recovery | NOT captured for this cutover |
| Immutable source PV and separately tested migration scratch copy | StatefulSet/PVC name/StorageClass immutability | DESIGN GATE |
| Exact chart Helm/Flux ownership plan | No simultaneous controllers or adoption of old resources | DESIGN GATE |
| Real Vault Kubernetes auth, ESO and Semaphore integration | Synthetic RBAC intentionally disabled | NOT TESTED |
| Three-voter HA and failover | Tolerate one member loss | PASS synthetic only |
| Snapshot save/integrity | Application-consistent backup | PASS synthetic only |
| Empty isolated Raft restore | Prove snapshot can recover Vault | PENDING |
| Old file backend restore / rollback | Prove a safe retreat from cutover | PENDING |
| Liveness with startup grace and full recovery | Avoid probe-induced reboot loops | BLOCKER |
| Daily off-cluster snapshot scheduling, alert, retention, encryption | Make proposed RPO achievable | NOT DEPLOYED |
| Break-glass Shamir key custody and manual-unseal coverage | HA does not auto-unseal | Operator decision, custody to reconfirm |
| Agreed RTO/RPO measured and signed off | Objective requires end-to-end recovery | NOT ACCEPTED / NOT MEASURED |

### Production rollback design (not yet tested)

Suspend verified owning reconciliation scope; stop all new Vault writes and all Raft pods, retaining their volumes. Restore prior **standalone file HelmRelease** and bind a recreated PVC to the **retained old local-path PV**, after checking its exact saved claim metadata. Never modify an immutable PVC StorageClass in place, never delete the old PV as a shortcut, never overwrite a running Raft filesystem with a tarball. Unseal with the original production shares, verify ESO/SSH/Semaphore, and account for all writes since the last cold backup: rollback is a **point-in-time restore**, not lossless reverse replication. Require owner approval before leaving a maintenance window.

Snapshot restore of the *new* Raft backend and rollback to the *old* file backend are different exercises; passing one does not prove the other.

## 10. Day-2 operations and monitoring model

- Normal pod restart: detect sealed/readiness 503, check storage and quorum, use trusted interactive Shamir custody, unseal **only** the sealed initialized node, then confirm Raft catch-up. Do not initialize any existing member.
- Healthy majority: monitor `vault operator raft autopilot state` (Healthy, failure tolerance, voters), 3/3 pods Ready, Longhorn volume/replica health and PodDisruptionBudget, along with Vault process metrics and restart counts.
- Alerts to design: unavailable/unknown Vault; sealed with duration; fewer than 3 ready; no healthy majority; low disk space, filesystem/Longhorn I/O degradation; Raft voter/index drift; missing or stale verified snapshot; backup job and independent storage failure. Verify actual Prometheus metrics exist before writing PromQL alert rules.
- Maintenance: worker-at-a-time; never voluntarily disrupt a member without confirmed quorum, fresh backup and an available share custodian. PDB protects eligible evictions but **not** arbitrary pod deletion.
- Daily snapshot **not yet implemented** for Vault Community: build a separate operator/cron workflow with least-privilege Vault policy/token lifecycle, independent encryption/transport, checksum, rotation, retention, alerting and periodic isolated restore. Built-in automated snapshots may have edition restrictions; do not assume the Helm chart delivers them.
- Access: deny by default, explicit Raft peer ingress/egress, DNS + Kubernetes API egress if required, metrics/ESO/Semaphore integration paths, and no globally broad allow rules.
- Security: never expose root tokens in `kubectl exec` args, never publish a Shamir share or Vault data backup, and do not rely on Vault to retrieve the credentials needed to recover Vault.

## 11. Operator decision record and open questions

**Decisions already made for synthetic rehearsal:** Vault 2.0.4/chart 0.34.1, three Longhorn workers, per-member 10Gi PVC, Shamir 3/2, no auto-unseal, explicit join and interactive unseal, no production dependencies, isolated snapshot restore.

**Awaiting owner decision:** production seal custody and delegated responsibilities; target RTO/RPO acceptance; maintenance window and rollback cutoff; service impact to ESO/Semaphore; Longhorn backup replication/retention; API TLS and network design; operational alert ownership; backup schedule/destination/encryption; final Helm/Flux cutover mechanics.

### Resume checkpoint

**The next actual action is a read-only preflight of the existing `vault-raft-restore-test` target, not redoing migration and not touching production.** Continue only if the target still reports `Initialized=false` and `Sealed=true`; then, in the next supervised session, initialize the *target*, transfer the verified snapshot, and perform an isolated restore through the explicit gates above.

## 12. Source references (traceability)

Repo files:

- `infra/vault/helmrelease.yaml` — active, **unchanged** standalone file Vault.
- `infra/vault/vault.md` — service overview, status and links.
- `infra/vault/candidates/raft-ha/helmrelease.yaml` — GitOps-excluded HA candidate with the follower directory init fix on PR #355.
- `infra/vault/candidates/raft-ha/rehearsal/README.md` — synthetic stepwise execution.
- `infra/vault/candidates/raft-ha/rehearsal/base.yaml`, `migrate-job.yaml`, `networkpolicy.yaml` — synthetic source, migration, and Calico allow rules.
- `infra/vault/candidates/raft-ha/rehearsal/restore-isolation.yaml` and `restore-target.yaml` — deny-all separated target, reviewed under PR #355.
- `scripts/lifecycle/vault-unseal-ha.sh` — manual interactive helper.
- `docs/lifecycle/restore-runbook.md` — general cluster and Vault restore, updated guidance for the future Raft state.
- `docs/lifecycle/vault-raft-migration.md` — authoritative **future production** migration/rollback gates.
- [Issue #256](https://github.com/ivanversluis/homelabs/issues/256) and [PR #355](https://github.com/ivanversluis/homelabs/pull/355).

HashiCorp:

- https://developer.hashicorp.com/vault/docs/commands/operator/migrate
- https://developer.hashicorp.com/vault/docs/commands/operator/raft
- https://developer.hashicorp.com/vault/docs/sysadmin/snapshots/restore
- https://developer.hashicorp.com/vault/tutorials/raft/raft-lost-quorum
- https://developer.hashicorp.com/vault/docs/commands/operator/unseal

**End state on 19 October 2026: leave the isolated restore target uninitialized and all three Raft rehearsal members healthy.**
