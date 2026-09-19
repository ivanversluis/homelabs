#!/usr/bin/env python3
"""Split verified Calico v3.32.1 manifests without changing their YAML objects.

Requires PyYAML. Inputs must be downloaded from the commit recorded below.
Re-run with: python vendor-calico.py SOURCE_DIRECTORY OUTPUT_DIRECTORY
"""
import hashlib
from pathlib import Path
import re
import sys

import yaml

COMMIT = "0ca9d1b93644778cafdf1812f3dda02ac0c361e8"
EXPECTED = {
    "v1_crd_projectcalico_org.yaml": "192f8b2d934ef24b62e86b7e1a6e1762d1c8af26a916f78057bc13fa5ed60f71",
    "tigera-operator.yaml": "f18e073794207d372606bc3ea6f8fd73972f86d6828f4ba666dfe0d4aa8ab07f",
}


def split(source, output):
    source, output = Path(source), Path(output)
    expected_objects = []
    paths = {"crds": [], "runtime": []}
    checksums = []
    identities = set()
    for filename, expected_hash in EXPECTED.items():
        data = (source / filename).read_bytes()
        assert hashlib.sha256(data).hexdigest() == expected_hash, filename
        for part in re.split(r"(?m)^---[ \t]*\r?$", data.decode("utf-8-sig")):
            obj = yaml.safe_load(part)
            if obj is None:
                continue
            key = (obj["apiVersion"], obj["kind"], obj["metadata"].get("namespace", ""), obj["metadata"]["name"])
            assert key not in identities, key
            identities.add(key)
            expected_objects.append(obj)
            group = "crds" if obj["kind"] == "CustomResourceDefinition" else "runtime"
            name = f"{obj['kind'].lower()}-{obj['metadata']['name']}.yaml"
            assert re.fullmatch(r"[a-z0-9.-]+", name), name
            target = output / group / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((part.strip().replace("\r\n", "\n") + "\n").encode())
            paths[group].append(name)
            checksums.append(f"{hashlib.sha256(target.read_bytes()).hexdigest()}  {group}/{name}")
    for group, names in paths.items():
        (output / group / "kustomization.yaml").write_text(
            "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n"
            + "".join(f"  - {name}\n" for name in names), encoding="utf-8")
    actual = [yaml.safe_load((output / group / name).read_text()) for group, names in paths.items() for name in names]
    assert actual == expected_objects, "Split output differs from upstream"
    (output / "SHA256SUMS").write_text("\n".join(checksums) + "\n", encoding="utf-8")
    print(f"Verified {len(paths['crds'])} CRDs and {len(paths['runtime'])} runtime resources; exact object equivalence.")


if __name__ == "__main__":
    split(*sys.argv[1:])
