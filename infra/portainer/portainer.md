# Portainer EE Homelab Wiki

## Documentation
https://docs.portainer.io/
https://artifacthub.io/packages/helm/portainer/portainer

## Repo
https://github.com/portainer/portainer
https://github.com/portainer/k8s

## Releases
https://github.com/portainer/portainer/releases

## Current Version
Chart: 2.33.6
App: 2.33.6
Image: portainer/portainer-ee:2.33.6-alpine

## Objective
As home-admin I want to manage my Kubernetes cluster through a self-hosted web UI with persistent state, migrating from the existing Docker Compose instance running on Synology NAS.

## Implementation
Portainer Enterprise Edition is deployed on Kubernetes with Flux CD using the official Helm chart. RBAC is configured via a dedicated ServiceAccount with cluster-admin access. Persistence is backed by Longhorn storage. The deployment replaces the legacy Docker Compose instance on the Synology NAS.

## Stack
- Flux CD HelmRelease + HelmRepository
- Enterprise Edition (portainer-ee)
- Longhorn persistent storage (1Gi PVC)
- RBAC: ServiceAccount + ClusterRole (cluster-admin)
- Helm chart from https://portainer.github.io/k8s/

## LLD

### Namespace
`portainer`

### Service
`portainer` (ClusterIP)
- HTTPS UI: port 9443
- HTTP UI: port 9000
- Edge agent tunnel: port 8000

### Persistence
1Gi Longhorn PVC for `/data` (Portainer's internal database)

### RBAC
- ServiceAccount: `portainer-sa`
- ClusterRole: `portainer-cluster-admin` (full cluster access)
- ClusterRoleBinding: `portainer-cluster-admin` → `portainer-sa`

### TLS
Forced HTTPS via `tls.force: true` in Helm values

---

## Migration from Synology NAS (Docker Compose)

### Current Synology Setup (as-is)

The current Portainer EE instance runs as a Docker Compose stack on the Synology NAS:

```yaml
services:
  portainer:
    image: portainer/portainer-ee:2.33.6-alpine
    container_name: portainer
    hostname: portainer
    restart: always
    volumes:
      - /volume1/containers/core-infra/portainer/run/:/var/run/
      - /volume1/containers/core-infra/portainer/data:/data
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      vlan402:
        ipv4_address: 172.16.19.2

networks:
  vlan402:
    external: true
```

**Key details of the current instance:**
- **Image**: `portainer/portainer-ee:2.33.6-alpine`
- **Network**: Static IP `172.16.19.2` on VLAN 402 (macvlan driver)
- **Data directory**: `/volume1/containers/core-infra/portainer/data` — contains the BoltDB database (`portainer.db`) with all Portainer configuration, users, endpoints, stacks, and settings
- **Docker socket**: Mounted for managing Docker containers on the Synology NAS directly
- **Database**: Embedded BoltDB (single file: `portainer.db`)

### What is stored in the Portainer BoltDB database

The `/data/portainer.db` file contains:
- **Users & teams**: All user accounts, passwords (hashed), team memberships, and role assignments
- **Endpoints/environments**: Configured Docker/Kubernetes endpoints the Portainer instance manages
- **Stacks**: Docker Compose stack definitions deployed through Portainer
- **Settings**: Global Portainer settings, authentication config, LDAP/OAuth settings
- **Edge agent configurations**: Edge agent tokens and tunnel configurations
- **Resource controls**: Access control rules for containers, volumes, networks
- **Registries**: Configured container registries and their credentials
- **Custom templates**: Any custom templates created in Portainer
- **Webhooks**: Configured webhooks for stack/service updates

### Migration Decision

**Option A: Fresh start (Recommended)**

Start with a clean Portainer instance on Kubernetes. This is recommended because:
- The Synology instance manages Docker containers — those endpoints won't exist in Kubernetes
- Kubernetes environments need to be configured differently (in-cluster ServiceAccount vs Docker socket)
- Stack definitions from Docker Compose don't apply to Kubernetes deployments
- A fresh instance avoids carrying over stale Docker-specific configuration
- The Kubernetes instance auto-discovers the cluster via the `portainer-sa` ServiceAccount

Steps:
1. Deploy the Kubernetes manifests via Flux CD
2. Access Portainer on port 9443 and create a new admin user
3. The local Kubernetes environment is auto-detected via the ServiceAccount
4. Optionally add the Synology Docker instance as a remote environment (via Edge agent or API)
5. Decommission the Synology Docker Compose stack once satisfied

**Option B: Database migration (if history is needed)**

If you need to preserve users, settings, or audit history:
1. Stop the Synology Portainer instance:
   ```bash
   ssh synology
   cd /volume1/containers/core-infra/portainer
   docker compose down
   ```
2. Copy the database from the Synology NAS:
   ```bash
   scp synology:/volume1/containers/core-infra/portainer/data/portainer.db ./portainer.db
   ```
3. Deploy the Kubernetes manifests first (let Portainer initialize)
4. Scale down the Portainer pod:
   ```bash
   kubectl -n portainer scale deployment portainer --replicas=0
   ```
5. Copy the database into the PVC:
   ```bash
   # Create a temporary pod to access the PVC
   kubectl -n portainer run pvc-copy --image=busybox --restart=Never \
     --overrides='{"spec":{"containers":[{"name":"pvc-copy","image":"busybox","command":["sleep","3600"],"volumeMounts":[{"name":"data","mountPath":"/data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"portainer-pvc"}}]}}'

   # Wait for the pod to be ready
   kubectl -n portainer wait --for=condition=Ready pod/pvc-copy --timeout=60s

   # Copy the database
   kubectl -n portainer cp ./portainer.db pvc-copy:/data/portainer.db

   # Clean up the temporary pod
   kubectl -n portainer delete pod pvc-copy
   ```
6. Scale Portainer back up:
   ```bash
   kubectl -n portainer scale deployment portainer --replicas=1
   ```
7. Verify Portainer starts and existing users/settings are visible
8. **Important**: Remove or reconfigure any Docker socket-based endpoints — they won't work from inside Kubernetes

### Post-Migration Cleanup (Synology)

Once the Kubernetes instance is confirmed working:
```bash
# On the Synology NAS
ssh synology
cd /volume1/containers/core-infra/portainer
docker compose down

# Optionally archive the data directory before deleting
tar czf /volume1/backups/portainer-synology-backup-$(date +%Y%m%d).tar.gz data/

# Remove the compose stack
rm -rf /volume1/containers/core-infra/portainer
```

### Network Considerations

- **Synology instance**: Used static IP `172.16.19.2` on VLAN 402 (macvlan)
- **Kubernetes instance**: Runs as ClusterIP service — access via Cloudflare tunnel or port-forward
- If you need the same network accessibility, consider configuring the Cloudflare tunnel service to route to the Portainer service on port 9443
