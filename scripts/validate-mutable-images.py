#!/usr/bin/env python3
"""Fail when the repository's known moving image-reference baseline changes."""

from __future__ import annotations

import os
import re
import sys
from collections import Counter
from pathlib import Path


ROOT = Path(os.environ.get("MUTABLE_IMAGE_REPO_ROOT", Path(__file__).resolve().parents[1]))
BASELINE = Path(
    os.environ.get(
        "MUTABLE_IMAGE_BASELINE",
        ROOT / "scripts" / "mutable-image-allowlist.txt",
    )
)
SCAN_ROOTS = ("clusters", "infra", "platform", "services", "workloads")
MOVING_TAGS = {
    "alpine",
    "canary",
    "dev",
    "develop",
    "development",
    "edge",
    "latest",
    "main",
    "master",
    "nightly",
    "stable",
    "staging",
}
KEY_VALUE = re.compile(r"^\s*(?:-\s*)?(image|newTag|tag):\s*(.*?)\s*$")
REPOSITORY = re.compile(r"^\s*(?:-\s*)?repository:\s*\S+")


def clean_value(raw: str) -> str:
    value = raw.split(" #", 1)[0].strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        value = value[1:-1]
    return value


def moving_image(image: str) -> bool:
    if "@sha256:" in image:
        return False
    name = image.rsplit("/", 1)[-1]
    if ":" not in name:
        return True
    return name.rsplit(":", 1)[1].lower() in MOVING_TAGS


def split_image_tag(lines: list[str], index: int) -> bool:
    """Only treat tag as an image tag when a nearby sibling repository exists."""
    current_indent = len(lines[index]) - len(lines[index].lstrip())
    for previous in range(index - 1, max(-1, index - 9), -1):
        candidate = lines[previous]
        if not candidate.strip() or candidate.lstrip().startswith("#"):
            continue
        indent = len(candidate) - len(candidate.lstrip())
        if indent < current_indent:
            return False
        if REPOSITORY.match(candidate):
            return True
    return False


def excluded(path: Path) -> bool:
    relative = path.relative_to(ROOT)
    return "vendor" in relative.parts or relative.as_posix() == (
        "clusters/k8s-homelab/flux-system/gotk-components.yaml"
    )


def inventory() -> list[str]:
    findings: list[str] = []
    for root_name in SCAN_ROOTS:
        scan_root = ROOT / root_name
        if not scan_root.exists():
            continue
        for path in sorted((*scan_root.rglob("*.yaml"), *scan_root.rglob("*.yml"))):
            if excluded(path):
                continue
            lines = path.read_text(encoding="utf-8").splitlines()
            for index, line in enumerate(lines):
                if line.lstrip().startswith("#"):
                    continue
                match = KEY_VALUE.match(line)
                if not match:
                    continue
                key, raw_value = match.groups()
                value = clean_value(raw_value)
                if not value:
                    continue
                is_moving = (
                    key == "image" and moving_image(value)
                    or key == "newTag" and value.lower() in MOVING_TAGS
                    or key == "tag"
                    and value.lower() in MOVING_TAGS
                    and split_image_tag(lines, index)
                )
                if is_moving:
                    relative = path.relative_to(ROOT).as_posix()
                    findings.append(f"{relative}|{key}={value}")
    return sorted(findings)


def load_baseline() -> list[str]:
    if not BASELINE.is_file():
        raise SystemExit(f"ERROR: mutable image baseline not found: {BASELINE}")
    return sorted(
        line.strip()
        for line in BASELINE.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    )


def expanded_difference(left: Counter[str], right: Counter[str]) -> list[str]:
    return sorted((left - right).elements())


def main() -> int:
    actual = Counter(inventory())
    expected = Counter(load_baseline())
    unexpected = expanded_difference(actual, expected)
    stale = expanded_difference(expected, actual)

    if unexpected or stale:
        print("ERROR: mutable image baseline changed.", file=sys.stderr)
        for item in unexpected:
            print(f"  + unexpected: {item}", file=sys.stderr)
        for item in stale:
            print(f"  - stale baseline: {item}", file=sys.stderr)
        print(
            "Pin the reference, or update the baseline in the same reviewed change.",
            file=sys.stderr,
        )
        return 1

    print(f"Mutable image baseline matches {sum(actual.values())} known reference(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
