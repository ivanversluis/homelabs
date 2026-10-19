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
14. Rehearse rollback separately: halt Raft pods, restore the independently captured synthetic file data on a fresh source claim, boot standalone and unseal with synthetic shares. Validate the same fixture. A rollback to a pre-cutover filesystem copy loses **all Raft-era writes**.

**Exit:** record times (RTO), snapshot age (RPO), three voters, placement, failover, source restore, missing dependencies and any issues; only then approve a production maintenance window.

**Cleanup after evidence:** uninstall rehearsal Helm release first, delete job/pods, then namespace. `longhorn-worker` PV reclaimPolicy is **Retain**, so identify and remove ONLY synthetic PVs/Longhorn volumes after independently verifying names. Do not accidentally delete the production PV.

**Stop immediately** on any unknown state, initialization prompt for migrated data, changed node IDs, unexpected claim binding, or any real secret entering rehearsal.
