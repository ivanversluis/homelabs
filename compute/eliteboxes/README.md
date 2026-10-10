# EliteBoxes

The existing HP EliteDesk Kubernetes cluster uses this directory as its Flux root. It replaces the former `clusters/k8s-homelab` repository path.

`kustomization.yaml` retains the existing `flux-system`, `platform`, `infra`, `services`, `workloads`, and `argo-cd` wiring. Relative references to shared repository areas remain at the same depth. Flux identities, inventory ownership, dependencies, pruning, and persistent resources are preserved.

The root `flux-system` Kustomization uses `spec.path: ./compute/eliteboxes`. Child Flux Kustomizations continue targeting the shared component paths. Argo CD's Firewall Manager ApplicationSet still targets `workloads/apps/firewall-manager/overlays/{{.env}}` in this repository.

Use [the cutover procedure](../../docs/lifecycle/compute-layout-migration.md) to update the live Flux root when merging this move.
