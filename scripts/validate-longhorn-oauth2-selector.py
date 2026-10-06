#!/usr/bin/env python3
"""Validate migration-safe selectors for the existing Longhorn oauth2-proxy."""

from __future__ import annotations

import re
import sys
from pathlib import Path


EXPECTED = "longhorn-oauth2-proxy"


def find_document(documents: list[str], kind: str, name: str) -> str:
    for document in documents:
        if re.search(rf"^kind:\s+{re.escape(kind)}\s*$", document, re.MULTILINE) and re.search(
            rf"^\s{{2}}name:\s+{re.escape(name)}\s*$", document, re.MULTILINE
        ):
            return document
    raise SystemExit(f"ERROR: rendered {kind}/{name} not found")


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit(f"Usage: {sys.argv[0]} <rendered-yaml>")

    rendered = Path(sys.argv[1]).read_text(encoding="utf-8")
    documents = re.split(r"^---\s*$", rendered, flags=re.MULTILINE)

    deployment = find_document(documents, "Deployment", EXPECTED)
    service = find_document(documents, "Service", EXPECTED)

    deployment_selector = re.compile(
        r"^\s{2}selector:\s*\n"
        r"^\s{4}matchLabels:\s*\n"
        rf"^\s{{6}}app:\s+{re.escape(EXPECTED)}\s*$",
        re.MULTILINE,
    )
    pod_label = re.compile(
        rf"^\s{{8}}app:\s+{re.escape(EXPECTED)}\s*$",
        re.MULTILINE,
    )
    service_selector = re.compile(
        r"^\s{2}selector:\s*\n"
        rf"^\s{{4}}app:\s+{re.escape(EXPECTED)}\s*$",
        re.MULTILINE,
    )

    if not deployment_selector.search(deployment):
        raise SystemExit(
            "ERROR: Longhorn Deployment selector changed. "
            "spec.selector is immutable on the deployed resource."
        )
    if not pod_label.search(deployment):
        raise SystemExit(
            "ERROR: Longhorn pod template no longer carries app=longhorn-oauth2-proxy."
        )
    if not service_selector.search(service):
        raise SystemExit(
            "ERROR: Longhorn Service selector no longer matches the deployed pod label."
        )

    print("Longhorn oauth2-proxy selector compatibility: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
