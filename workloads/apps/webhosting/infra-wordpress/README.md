# Pi4 legacy infra-wordpress: safe Git handover (NOT auto-deployed)

The local Portainer stack `infra-wordpress` is still the owner of the original
`dmz-wordpress` network and currently has **three running services**:
`infra-hosting-mariadb`, `infra-hosting-redis`, and
`infra-hosting-iso2010-nginx`. The two WordPress PHP 7.4 containers are exited
and MUST remain off. The Networknet Hugo nginx container is already managed
separately from Git at `../docker-compose.yml`.

`docker-compose.yml` in this directory is a **cutover candidate**, not a
drop-in live update. It intentionally omits both WordPress/PHP services and the
Networknet nginx service. It retains original static IPs, aliases and host
ports and declares the DMZ as **external**, so it never creates/destroys the
shared network. No Kubernetes Flux reconciliation or automatic deployment is
configured.

## Security actions first

The original local Portainer editor stack exposed live database credentials in
its Compose/environment. Consider both credentials disclosed. Rotate the
MariaDB root and application users' passwords **inside the existing database**,
after inventorying all consumers (including ISO2010), and update clients
through a protected secret store. Do not just change the Compose env variables:
the official MariaDB image uses initialization variables when the data directory
is empty, not as a general password-reset mechanism.

Neither production passwords nor the real homelab domain belong in this repo,
GitHub issue/PR text, Portainer Git environment variables, Portainer screenshots,
or terminal history. Do not reuse the exposed credentials. If sharing evidence,
redact credentials, domains and other sensitive values. Ensure the former
Portainer editor values are removed after the migration and assess any
credential history or backups with access controls.

**Portainer authentication:** the login screenshot alone does not establish
whether local admin or Authentik/OIDC is in use. In Portainer, inspect
`Settings -> Authentication` and the corresponding provider settings.
Keep a tested break-glass local admin with MFA as an operator decision;
do not disable working SSO or change global authentication as part of this PR.

## One-time Pi4 preparation (do not run a replacement yet)

1. Inventory existing workloads, clients and runtime, including the existing
   local Compose stack; capture private backups of the stack and its host
   storage. Verify MariaDB logical + filesystem backups and a test restore.
   Check that services still depend on MariaDB/Redis before retiring them.
2. Confirm what `infra-hosting-iso2010-nginx` currently serves. Its old
   FastCGI configuration might reference the stopped `iso2010-wordpress`
   container; do not assume it is safe/functional merely because nginx runs.
   Confirm an HTTP smoke test and `nginx -t`.
3. Record **current** resolved MariaDB and Redis images/digests on the Pi4,
   their compatibility requirements and persistent state; choose supported,
   tested explicit image references and set **non-secret** Portainer variables
   `MARIADB_IMAGE` and `REDIS_IMAGE` when configuring the Git stack.
   Avoid moving to an untested major version just to remove `:latest`.
4. Confirm on Pi4 that the host directories in the Compose file already exist
   and that their permissions and owner are correct. For MariaDB, create the
   separate root-owned secret directory outside of the database volume:
   `/containers/infra-wordpress/secrets/mariadb`. It must contain
   `mariadb-root-password` and `mariadb-user-password` with the
   **new, rotated** values and restrictive permissions suitable for the
   container runtime. These are bind-mounted at `/run/secrets/` and passed
   to the official MariaDB image via the `MARIADB_*_FILE` variables.
   These files do not themselves rotate an already initialized database.
5. Redis currently uses append-only persistence but the **old Compose has no
   host-backed /data volume**. A container replacement may destroy its AOF.
   Inspect `podman inspect infra-hosting-redis` mounts, resolve the active
   Redis data directory and copy its persistent files into
   `/containers/infra-wordpress/redis/data` using a consistent snapshot/
   maintenance window. Verify ownership and contents before any new container
   starts. Do not blindly mount an empty directory over live data.
6. Check if any live client depends on MariaDB's host TCP/3306 or ISO2010's
   published TCP/80. Candidate Compose keeps both bindings for parity; plan
   network exposure reduction later as a separate change.
7. Avoid updating or deleting the original local `infra-wordpress` stack
   while it owns the DMZ network; this could remove a shared bridge and break
   the active Cloudflare Tunnel and Networknet nginx.

## Inspect read-only before cutover

```sh
sudo podman ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
sudo podman network inspect dmz-wordpress | jq '.[0] | {name,driver,dns_enabled,subnets}'
for c in infra-hosting-mariadb infra-hosting-redis infra-hosting-iso2010-nginx; do
  sudo podman inspect "$c" --format '{{.Name}} image={{.ImageName}} status={{.State.Status}}'
  sudo podman inspect "$c" --format '{{json .Mounts}}' |
    jq 'map({Source,Destination,Type,RW})'
done
sudo podman exec infra-hosting-iso2010-nginx nginx -t
```

Do not export full `podman inspect` or Portainer Compose to public issues
because they may contain credentials.

## Git-backed management cutover (manual maintenance window)

1. Back up Portainer database and old local Compose metadata. Verify backups
   and snapshots and stop all automation that might redeploy the old stack.
2. Ensure the DMZ network lifecycle has been transferred to a dedicated
   controller or is explicitly retained by Podman. **Do not delete the local
   Portainer stack with network removal enabled** while other services
   still share this bridge.
3. Stop only the three legacy containers, retaining their host paths and any
   Redis state needed for recovery. Confirm no other controller recreates them.
   Remove only those stopped container objects to release their names/IPs;
   never remove volumes, host bind directories or the DMZ network.
4. In the Pi4 rootful Podman environment use **Stacks -> Add stack ->
   Git repository** with repository
   `https://github.com/ivanversluis/homelabs`, branch
   `refs/heads/main`, Compose path
   `workloads/apps/webhosting/infra-wordpress/docker-compose.yml`,
   and a *new* stack name such as `infra-wordpress-legacy`. Configure
   only non-secret pinned image references as environment variables.
   Keep Git auto-updates off initially.
5. Confirm the 3 services start with the same IPs/aliases, that MariaDB
   authenticates with **rotated** credentials, that Redis AOF is present,
   and that ISO2010/Networknet Cloudflare routes still work. Check host
   port publication and MariaDB data integrity before transferring ownership
   of the old Portainer stack metadata.
6. Retire or detach old Portainer metadata only after verifying the new
   Git stack owns the intended containers and the DMZ network is preserved.
   Some Portainer/Podman versions cannot adopt an existing local stack
   directly; do not click Delete stack blindly. Use documented orphan/
   associate recovery when applicable.

## Ongoing configuration

- **Networknet Hugo**: `workloads/apps/webhosting/docker-compose.yml`.
- **Legacy infra services**: this folder's candidate Compose after cutover.
- **Retired WordPress PHP**: deliberately absent; do not restart.
- **Secrets**: Pi4-protected host secret files or a future Vault/ESO-backed
  materialization process. Never commit plaintext, even in a sample.
- **Portainer itself**: separately managed; check actual authentication,
  current installed version, backups and patch level before changing it.

The candidate is intended for operator review and does not alter any running
Pi4 service by merging this PR.
