# Kubernetes platform

This directory contains Kubernetes system and platform capabilities that workloads depend on.

> **Rule:** `platform/` makes Kubernetes work. `services/`, `infra/`, and `workloads/` consume the platform.

## Structure

- `networking/` — CNI, cluster DNS, LoadBalancer implementation, and network policy baseline.
- `storage/` — CSI/persistent storage and node-local provisioning capabilities.
- `virtualization/` — KubeVirt and CDI platform controllers.
- `observability/` — metrics, logs, dashboards, alerting, and cluster monitoring components.
- `security/` — cluster-wide security controllers such as cert-manager and External Secrets.

## GitOps model

Critical or stateful platform components keep their existing dedicated Flux `Kustomization` boundaries under `clusters/k8s-homelab/platform/`. Repository restructuring must not change their ownership or persistence behavior unless an explicit staged migration is planned.

## Lessons learned

### KubeVirt VMs must pin `macAddress` on every interface (2026-09-22)

Symptom: after a VM restart (e.g. following a cluster upgrade), the guest boots, the
qemu-guest-agent connects fine, but the guest NIC never gets an IP — `ip a` inside the
guest shows the interface `state DOWN`/`qdisc noop`, and no DHCP request is ever sent.
KubeVirt's own masquerade DHCP responder (`SingleClientDHCPServer` in the virt-launcher
logs) is healthy and just never receives a request — the fault is entirely guest-side.

Root cause: cloud-init generates `/etc/netplan/50-cloud-init.yaml` on first boot and
caches it, matching the NIC by the MAC address seen at that time
(`match: macaddress: <mac>`). If the `VirtualMachine` manifest doesn't pin
`spec.template.spec.domain.devices.interfaces[].macAddress`, KubeVirt assigns a new
random MAC on every VM restart/recreate. The cached netplan match then silently stops
applying — `systemd-networkd` never configures the interface, no DHCP is attempted, and
nothing in the virt-launcher or cloud-init logs flags it as an error.

Fix / rule for all future VMs: always set an explicit `macAddress` on every VM interface
in the manifest (see `workloads/vms/debian-bookworm-vm.yaml`). Pick any locally-administered
MAC, or read the one cloud-init already cached from the guest's generated netplan file if
recovering an existing VM. Never leave it to KubeVirt to auto-assign for anything but
fully disposable/stateless VMs.


Application and VM workloads live under `workloads/apps/` and `workloads/vms/`.
