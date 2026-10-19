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
   helm list -n vault-raft-rehearsal
   ```

   The cluster-scoped resource check must print **nothing**; the StatefulSet must print `1 data longhorn-worker` (tab-separated), with enforced per-worker node affinity and pod anti-affinity. An affinity merge warning may appear because the chart's default is a string but the candidate is a map; verify the **rendered** affinity rather than assuming it was lost. If `helm list` shows any existing release, **stop and inspect** instead of installing over it. Only with correct output, install with `helm install vault hashicorp/vault --version 0.34.1 -n vault-raft-rehearsal -f "$VALUES"` (no `--wait`: the new instance is sealed). Inspect that `vault-0` binds the migrated `data-vault-0`, and stop if Vault reports `Initialized=false`. **Never `operator init` migrated storage.** Production `infra/vault/helmrelease.yaml` must remain untouched.
9. Unseal **vault-0 with the original synthetic source shares**, never run `vault operator init`; verify KV v2 fixture value, `rehearsal-read` policy, `userpass/` auth, `ssh-test/` engine, original SSH CA public-key hash, and one healthy Raft voter. **Observed on the 2026-10-19 rehearsal:** with the candidate's HTTP liveness probe enabled at initial startup, Vault stalled on `/v1/sys/health` and kubelet killed it after probe timeouts (exit 137). Liveness was **temporarily disabled only for the rehearsal** using `helm upgrade ... --set server.livenessProbe.enabled=false`, then `vault-0` was recreated under the StatefulSet's `OnDelete` policy and eventually returned HTTP 503 while sealed. After interactive unseal, `vault-0` became `1/1 Ready` with no restarts. The underlying slow-start condition has **not** been root-caused; this is **not** an acceptable final HA/prod liveness configuration.

10. **Scale one follower at a time, and wait for each node to be healthy and voting before adding the next.** Use the locally extracted rehearsal `$VALUES` file where `server.authDelegator.enabled=false` and preserve the temporary liveness override on every upgrade; otherwise Helm will restore the enabled candidate value unexpectedly. With `updateStrategyType: OnDelete`, scaling creates a *new* pod without automatically restarting the existing healthy leader. Join a new `raft` **storage** node *before* unsealing it (Shamir); do not initialize it.

    ```bash
    VALUES=/tmp/vault-raft-rehearsal-values.yaml
    yq -r '[.server.ha.raft.enabled, .server.authDelegator.enabled] | @tsv' "$VALUES"
    helm upgrade vault hashicorp/vault --version 0.34.1 \
      -n vault-raft-rehearsal -f "$VALUES" \
      --set server.ha.replicas=2 --set server.livenessProbe.enabled=false

    kubectl -n vault-raft-rehearsal get pods,pvc -o wide
    kubectl -n vault-raft-rehearsal exec vault-1 -- \
      vault operator raft join http://vault-0.vault-internal:8200
    kubectl -n vault-raft-rehearsal exec -it vault-1 -- vault operator unseal
    kubectl -n vault-raft-rehearsal exec -it vault-1 -- vault operator unseal
    kubectl -n vault-raft-rehearsal exec vault-0 -- vault operator raft list-peers
    ```

    Confirm `vault-0` and `vault-1` are healthy, both voters, one per worker, `data-vault-0` is unchanged, `data-vault-1` is Bound. Then scale to three and join the last follower:

    ```bash
    helm upgrade vault hashicorp/vault --version 0.34.1 \
      -n vault-raft-rehearsal -f "$VALUES" \
      --set server.ha.replicas=3 --set server.livenessProbe.enabled=false
    kubectl -n vault-raft-rehearsal get pods,pvc -o wide
    kubectl -n vault-raft-rehearsal exec vault-2 -- \
      vault operator raft join http://vault-0.vault-internal:8200
    kubectl -n vault-raft-rehearsal exec -it vault-2 -- vault operator unseal
    kubectl -n vault-raft-rehearsal exec -it vault-2 -- vault operator unseal
    kubectl -n vault-raft-rehearsal exec vault-0 -- vault operator raft list-peers
    ```

    **Observed follower startup failure and fix (2026-10-19):** after scaling to 2, `vault-1` immediately entered `CrashLoopBackOff` (exit 1) with `failed to create fsm: failed to open bolt file: open /vault/data/raft/vault.db: no such file or directory`. The migration Job pre-created `/vault/data/raft` on `data-vault-0`, but the fresh `data-vault-1` PVC had no nested directory. The review candidate now sets `server.extraInitContainers` with a non-root UID 100 / GID 1000 BusyBox initializer mounting the `data` volume and running `mkdir -p /vault/data/raft && chmod 0700 /vault/data/raft`. This is safe for pre-existing Raft storage and does not touch the database files. **The pre-fix release must be upgraded with the updated candidate values and the failing follower pod recreated** because `OnDelete` will not update it automatically; never delete either PVC or the healthy leader. Verify the rendered StatefulSet has `initContainers[0].name=prepare-raft-directory`, and confirm that the init completes before issuing `vault operator raft join`. If init fails, inspect `kubectl logs vault-1 -c prepare-raft-directory` and check Longhorn volume ownership before modifying permissions. Keep `server.authDelegator.enabled=false` and `server.livenessProbe.enabled=false` for this *rehearsal only* (the latter remains a mandatory unresolved production gate).

    For nodes where `kubectl exec` initially fails, inspect readiness, events, Longhorn attachment and logs; do not rerun joins without checking the member state. Never put Shamir shares into commands or Git.

11. With an authenticated Vault CLI on the current active server, verify `vault operator raft list-peers` reports **three voters** and `vault operator raft autopilot state` is healthy. Confirm one pod per worker, three 10Gi Longhorn RWO Bound Raft PVCs, and PDB `maxUnavailable: 1`. **Mandatory additional acceptance gate:** investigate startup slowness and restore/retest correctly configured liveness probes, ideally with startup grace appropriate to Longhorn/Raft initialization, using a controlled one-member-at-a-time rollout under `OnDelete`. Do not consider HA production-ready while liveness remains disabled.
12. Restart **the leader only**, manually unseal it if required, and prove surviving quorum serves synthetic reads before unsealing the restarted node. Verify Raft peers/Autopilot and client readiness again. Note: PDB covers voluntary eviction, not arbitrary `kubectl delete pod`.

    **Observed 2026-10-19 failover:** direct deletion of `vault-0` caused `vault-1` to become active while `vault-2` remained standby; the original synthetic `rehearsal/fixture` still read back `synthetic-only`. `vault-0` retained its original Longhorn PV, restarted sealed and was manually unsealed using original synthetic Shamir shares. After recovery, all three pods were `1/1 Ready` with zero restarts; Autopilot reported `Healthy: true`, `Failure Tolerance: 1`, three voters all synchronized at index 151. RTO was **not measured** and cannot be inferred from these logs.

13. Capture a **synthetic Raft snapshot** to an independent client. The operation saves a point-in-time copy without restoring/overwriting the running cluster. As of this rehearsal, `vault-1` is active and already has an authenticated CLI. Do **not** run `vault operator raft snapshot restore` against the active rehearsal or production. The snapshot may contain Vault secrets, so use `umask 077`, a private directory and no Git commits.

    ```bash
    umask 077
    SNAPDIR="$HOME/vault-rehearsal-backups"
    mkdir -p "$SNAPDIR"
    SNAP="$SNAPDIR/raft-ha-20261019.snap"
    kubectl -n vault-raft-rehearsal exec vault-1 -c vault -- \
      vault operator raft snapshot save /tmp/raft-ha-20261019.snap
    kubectl -n vault-raft-rehearsal exec vault-1 -c vault -- \
      vault operator raft snapshot inspect /tmp/raft-ha-20261019.snap
    kubectl -n vault-raft-rehearsal exec vault-1 -c vault -- \
      sha256sum /tmp/raft-ha-20261019.snap
    kubectl -n vault-raft-rehearsal exec vault-1 -c vault -- \
      cat /tmp/raft-ha-20261019.snap > "$SNAP"
    test -s "$SNAP" && sha256sum "$SNAP" && ls -lh "$SNAP"
    ```

    Confirm matching remote and local SHA-256 hashes. The local copy is *independent of the running Kubernetes pods*, but does not by itself prove disaster recoverability. The separate **destructive** snapshot-restore validation must take place on an **empty, disposable, isolated** Vault/Raft cluster after documenting the restore prerequisites, original synthetic unseal-key handling and suitable storage; never overwrite the active three-voter rehearsal cluster.

    **Observed 2026-10-19 snapshot validation — PASSED:** active server `vault-1`; `snapshot inspect` reported `ID=bolt-snapshot`, index **153**, term **4**, version **1**, total **27.7KB**. The private off-cluster copy `$HOME/vault-rehearsal-backups/raft-ha-20261019.snap` has file mode `0600`, non-zero size (~27KiB) and an exact SHA-256 match to the original file in the pod:

    ```text
    1332b62341b992e108927524df2170d5232616a8f35ca52abf971e45f7c42e15
    ```

    **Observed 2026-10-19 restore preflight — PASSED:** `kubectl config current-context` was `kubernetes-admin@kubernetes`; original three-voter rehearsal Autopilot remained `Healthy: true`, `Failure Tolerance: 1`, with all three members synchronized at index 164. Backup checksum still matched `1332b62341b992e108927524df2170d5232616a8f35ca52abf971e45f7c42e15`. The target namespace did not yet exist.

    **Bootstrap an isolated restore target (no restore command yet):** keep this separate from production `vault` and the working `vault-raft-rehearsal`. Two review-only files live in this directory:

    - `restore-isolation.yaml`: a new `vault-raft-restore-test` namespace plus all-ingress/all-egress deny-all NetworkPolicy. Apply this **first** and verify it exists before creating the target pod.
    - `restore-target.yaml`: a standalone, manual Vault 2.0.4 pod named `vault-restore`, dedicated new 10Gi `longhorn-worker` PVC, namespace-local ConfigMap, and a non-root init container to create `/vault/data/raft`. The API and cluster listeners bind only to `127.0.0.1`; no Service, no Kubernetes service-account token, no service registration, no Flux/Helm adoption, no external network access. Its Raft `node_id` is `vault-1` to match one peer from the source snapshot, **not** as permission to reconnect to the source. The startup readiness check will fail while uninitialized or sealed; no liveness probe restarts it.

    ```bash
    kubectl config current-context
    kubectl apply -f infra/vault/candidates/raft-ha/rehearsal/restore-isolation.yaml
    kubectl -n vault-raft-restore-test get networkpolicy deny-all
    kubectl apply -f infra/vault/candidates/raft-ha/rehearsal/restore-target.yaml
    kubectl -n vault-raft-restore-test get pod,pvc,svc -o wide
    kubectl -n vault-raft-restore-test logs vault-restore -c prepare-raft-directory
    kubectl -n vault-raft-restore-test logs vault-restore -c vault --tail=35
    kubectl -n vault-raft-restore-test exec vault-restore -c vault -- \
      sh -c 'vault status; echo "vault status exit=$?"'
    ```

    **Stop gate before target initialization:** ensure the namespace is exactly `vault-raft-restore-test`, deny-all exists, no Service is created, new PVC is Bound and different from all rehearsal/prod claims, init container succeeded, and `vault status` reports Raft `Initialized: false` and `Sealed: true`. A pod stuck `0/1 Ready` while sealed is expected. Do NOT attempt `vault operator init` against a preinitialized/unknown target, and never run `vault operator raft snapshot restore` against either existing namespace. After these checks, follow the official init → temporary unseal/login → local snapshot copy/hash → `snapshot restore -force` → original Shamir unseal flow; this is staged separately, not automated.

    **Restore preflight / mandatory gates:**
    - Verify `kubectl config current-context`, file hash, and that source rehearsal Autopilot is still healthy. Capture a recovery record before destructive testing.
    - Restore only in a **new** namespace (e.g. `vault-raft-restore-test`) with a **new** empty Longhorn PVC and a dedicated Vault instance. Enforce deny-all ingress and egress with **no connectivity to source rehearsal or production Vault**. Make API access only via `kubectl exec` into the isolated pod. Never run `vault operator raft snapshot restore` in namespaces `vault` or `vault-raft-rehearsal`.
    - Follow HashiCorp's restore procedure: initialize/unseal the empty *target* using **temporary new synthetic shares**, authenticate with the temporary target root token, copy and checksum the snapshot into the **target**, then and **only then** perform the documented force-restore; after restore use the **original snapshot source synthetic Shamir shares**, not the temporary target shares. Never store or publish shares or tokens. HashiCorp docs: https://developer.hashicorp.com/vault/docs/sysadmin/snapshots/restore
    - The snapshot was captured from a **3-voter Raft cluster**. A separate one-node restore target may inherit a 3-voter peer set, so its leader election/quorum is **not automatically assured**. Test correct raft peer identity and inspect snapshot-restored peer membership; if quorum recovery is needed, plan controlled `peers.json` recovery *only within the disposable target*, with a matching `VAULT_RAFT_NODE_ID`, and only after observing the target state. HashiCorp quorum reference: https://developer.hashicorp.com/vault/tutorials/raft/raft-lost-quorum
    - Snapshot restore is **not complete when the restore CLI returns**. Verify post-restore logs, actual unseal, Vault status, exact original synthetic KV/policy/auth/SSH CA fingerprint, and independent one-voter quorum (or intentionally rejoined three-voter cluster) in the target before declaring disaster recovery passed. Preserve the original three-voter rehearsal unchanged.
14. Rehearse rollback separately: halt Raft pods, restore the independently captured synthetic file data on a fresh source claim, boot standalone and unseal with synthetic shares. Validate the same fixture. A rollback to a pre-cutover filesystem copy loses **all Raft-era writes**.

**Exit:** record times (RTO), snapshot age (RPO), three voters, placement, failover, source restore, missing dependencies and any issues; only then approve a production maintenance window.

**Cleanup after evidence:** uninstall rehearsal Helm release first, delete job/pods, then namespace. `longhorn-worker` PV reclaimPolicy is **Retain**, so identify and remove ONLY synthetic PVs/Longhorn volumes after independently verifying names. Do not accidentally delete the production PV.

**Stop immediately** on any unknown state, initialization prompt for migrated data, changed node IDs, unexpected claim binding, or any real secret entering rehearsal.
