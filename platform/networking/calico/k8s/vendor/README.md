# Calico v3.32.1 provenance

Source: https://github.com/projectcalico/calico/tree/0ca9d1b93644778cafdf1812f3dda02ac0c361e8/manifests

Release commit: `0ca9d1b93644778cafdf1812f3dda02ac0c361e8` (v3.32.1).
Runtime operator image: `quay.io/tigera/operator:v1.42.3`.

| Upstream file | SHA-256 |
| --- | --- |
| v1_crd_projectcalico_org.yaml | 192f8b2d934ef24b62e86b7e1a6e1762d1c8af26a916f78057bc13fa5ed60f71 |
| tigera-operator.yaml | f18e073794207d372606bc3ea6f8fd73972f86d6828f4ba666dfe0d4aa8ab07f |

Retrieved from the immutable commit over HTTPS and hashed locally. These are local
integrity records, not a claim of independently verified publisher signatures.
`operator-crds.yaml` at this commit is byte-identical to
`v1_crd_projectcalico_org.yaml`; do not apply both. The smaller `crds.yaml` is not
the operator upgrade bundle required by the official procedure.

`scripts/lifecycle/vendor-calico.py` verifies these hashes and splits at document
boundaries, preserving every object. Output contains 32 CRDs and seven runtime
resources. `v3.32.1/SHA256SUMS` covers all generated resource definitions.
Run `sha256sum -c SHA256SUMS` from `v3.32.1` with LF checkouts.

Review: cluster-scoped CRD/RBAC privileges and host-network operator Deployment
are upstream requirements. Operator retains `-manage-crds=true`. No workloads,
Goldmane, Whisker, or native v3 datastore migration resources are added here.
The existing Installation, IP pool, BGP, VXLAN cross-subnet, iptables and
maxUnavailable=1 settings are unchanged by this upgrade.

Flux applies `calico-crds` first and waits for CRD readiness, then `calico`
updates the operator and existing Installation. Both disable force and pruning.
Old schemas absent from the release are therefore not deleted during transfer.

Official procedure: https://docs.tigera.io/calico/latest/operations/upgrading/kubernetes-upgrade
Release: https://github.com/projectcalico/calico/releases/tag/v3.32.1
