# Networknet nginx — Pi4 / Portainer

Portainer Git-based Compose stack for the existing **rootful Podman** Pi4 nginx origin. This replaces only the retired nginx container, **not** the host content, Cloudflare Tunnel, or WordPress/PHP. Nothing in this folder is reconciled by Kubernetes Flux.

- **Compose file:** `workloads/apps/webhosting/docker-compose.yml`
- **Image:** official multi-architecture `nginx:1.30.7-alpine3.24`, with the 18 November 2026 nginx2root fixes. Do not use the older image digest or the floating `nginx:alpine` tag for recovery.
- **Podman bridge:** existing external `dmz-wordpress` (`10.10.10.0/24`, DNS enabled). Preserve `10.10.10.5:80` and the DNS aliases until the Cloudflare Tunnel origin target is checked. The Synology `vlan401` / `172.16.18.11` configuration is obsolete on the Pi4.
- **Host mounts:** existing absolute Pi4 paths; the nginx config stays writable for the Networknet guarded 301/404 deployment and log file, while the Hugo document root is read-only to nginx. No ports are published on the Pi4 host.

## Before deployment (on the Pi4)

Do not create or replace the DMZ network, remove data directories, start the retired WordPress/PHP service, or deploy a second container at `10.10.10.5`.

```sh
sudo podman network inspect dmz-wordpress | jq '.[0] | {name, driver, dns_enabled, subnets}'
sudo podman ps -a --filter network=dmz-wordpress --format 'table {{.Names}}\t{{.Status}}'
sudo test -f /containers/infra-wordpress/nginx-networknet/nginx.conf
sudo test -d /containers/infra-wordpress/nginx-networknet/logs
sudo test -f /containers/infra-wordpress/wordpress/data/networknet/index.html
sudo test -f /containers/infra-wordpress/wordpress/data/networknet/404.html
```

Check **Cloudflare Zero Trust → Tunnels → your tunnel → Published applications / Public hostnames** for the Networknet origin. If it targets `http://10.10.10.5:80`, retain the static IP. If it uses a hostname, verify that the hostname is one of the aliases on `dmz-wordpress`. Prefer `http://networknet-nginx:80` after DNS has been tested; do not change a functioning route during the nginx cutover.

If the previous container still exists (even if stopped), it may reserve both the name and IP. Save any required inspect evidence **privately** and, after confirming that the service is stopped and the bind-mounted files are intact, remove **only the old container** (`sudo podman rm infra-hosting-networknet-nginx`) before creating the new one. Never use `-v`, remove the external network, or delete the host directories. Do not restart the old vulnerable image as a rollback.

## Portainer stack configuration

In the Pi4 **Podman** environment, choose **Stacks → Add stack → Git repository**:

| Setting | Value |
| --- | --- |
| Repository URL | `https://github.com/ivanversluis/homelabs` |
| Repository reference | `refs/heads/main` (after merging the PR) |
| Compose path | `workloads/apps/webhosting/docker-compose.yml` |
| Stack name | `networknet-webhosting` |

Ensure that Portainer is connected to the **rootful Podman** store that owns `dmz-wordpress` and the existing host binds. Do not enable automatic Git updates until the initial cutover has passed validation.

## Validate after deployment

```sh
sudo podman exec infra-hosting-networknet-nginx nginx -v
sudo podman exec infra-hosting-networknet-nginx nginx -t
sudo podman inspect infra-hosting-networknet-nginx \
  --format '{{json .NetworkSettings.Networks}}' | jq 'to_entries | map({network: .key, ip: .value.IPAddress, aliases: .value.Aliases})'
sudo podman port infra-hosting-networknet-nginx  # must print nothing
curl -sSI --max-time 5 http://10.10.10.5/
```

Verify the public site through Cloudflare: homepage returns successfully, a known `/apps/wp/` route redirects with **301**, an unknown URL returns **404**, and a retired PHP route returns **410**. Verify Hugo archive content and the persistent `nginx-networknet/logs/404.jsonl` output. See `ivanversluis/networknet` → `docs/wordpress-301-cutover.md` for the authoritative redirect and log checks.

The patched nginx image requires a **new container process**; `nginx -s reload` on the old image is insufficient. Review the Pi4 **host kernel** separately for the nginx2root-related kernel escalation advisory: an nginx image update does not patch the host.
