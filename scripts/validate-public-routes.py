#!/usr/bin/env python3
"""Validate the declared public Cloudflare ingress inventory end to end.

The Terraform managed_apps map is the canonical list of public hostnames and
architecture groups. Gatus monitors each host and Homepage presents each one.
The markdown ingress overview includes the declared origin and probe, and is
checked for drift. No live Cloudflare API or private domain value is needed.
"""
from collections import Counter
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TUNNEL = ROOT / "automation/infra-as-code/terraform/deployments/tunnel.tf"
GATUS = ROOT / "platform/observability/monitoring/gatus/gatus-configmap-config.yaml"
HOMEPAGE = ROOT / "workloads/apps/homepage/homepage-configmap.yaml"
OVERVIEW = ROOT / "docs/networking/ingress-overview.md"

# These are Gatus UI group IDs, ordered by architectural responsibility.
GROUPS = {
    "00-edge",
    "10-platform",
    "20-infra",
    "30-services",
    "40-workloads",
    "50-compute-synology",
}
PUBLIC_GROUPS = {"10-platform", "20-infra", "30-services", "40-workloads"}
HOMEPAGE_GROUPS = {
    "Platform": "10-platform",
    "Infrastructure": "20-infra",
    "Services": "30-services",
    "Workloads": "40-workloads",
    "Unmanaged / verify": None,
}
# Internal Kong ingress reached from inside Kubernetes, NOT published by tunnel.tf.
INTERNAL_HOSTS = {"api-gw": "30-services"}
# The edge synthetic certificate/domain check intentionally duplicates Homepage.
SYNTHETIC_ENDPOINTS = {"cloudflare-domain": ("homepage", "00-edge")}
# Preserved from the previous Homepage. Not claimed to be published or reachable.
UNMANAGED_HOMEPAGE_HOSTS = {"pihole"}


def tunnel_routes():
    """Extract hostname -> (architecture group, service origin) from HCL."""
    text = TUNNEL.read_text()
    match = re.search(r"managed_apps\s*=\s*\{(.*?)\n  \}", text, re.S)
    if not match:
        raise ValueError("Cannot find managed_apps in tunnel.tf")
    body = match.group(1)
    routes = {}
    declarations = re.findall(
        r'^\s*"([a-z0-9-]+)\.\$\{var\.domain\}"\s*=',
        body, re.M,
    )
    for row in re.finditer(
        r'^\s*"([a-z0-9-]+)\.\$\{var\.domain\}"\s*=\s*\{([^}\n]*)\}',
        body, re.M,
    ):
        host, attributes = row.groups()
        service = re.search(r'\bservice\s*=\s*"([^"]+)"', attributes)
        group = re.search(r'\bgroup\s*=\s*"([a-z0-9-]+)"', attributes)
        if not service or not group:
            raise ValueError(f"Route '{host}' needs service and group metadata")
        if host in routes:
            raise ValueError(f"Duplicate Terraform hostname '{host}'")
        routes[host] = {"group": group.group(1), "service": service.group(1)}
    if len(declarations) != len(routes):
        raise ValueError("Could not parse every declared managed_apps route")
    return routes


def gatus_endpoints():
    """Read individual endpoint blocks across Gatus embedded YAML documents."""
    endpoints = []
    current = None
    in_endpoints = False
    for line in GATUS.read_text().splitlines():
        section = re.match(r"^  ([a-z0-9-]+\.yaml): \|$", line)
        if section:
            in_endpoints = section.group(1) != "00-base.yaml"
            current = None
            continue
        if not in_endpoints:
            continue
        name = re.match(r"^ {6,10}- name: (.+)$", line)
        if name:
            current = {"name": name.group(1).strip().strip('"'), "enabled": True}
            endpoints.append(current)
        elif current is not None:
            if group := re.match(r"^\s+group: ([a-z0-9-]+)$", line):
                current["group"] = group.group(1)
            elif url := re.match(
                r'^\s+url: "?https://([a-z0-9-]+)\.\$\{DOMAIN\}',
                line,
            ):
                current["host"] = url.group(1)
            elif re.match(r"^\s+enabled: false\s*$", line):
                current["enabled"] = False
    return endpoints


def homepage_links():
    """Read Homepage service cards without counting widget or bookmark links."""
    text = HOMEPAGE.read_text()
    match = re.search(r"^  services\.yaml: \|\n(.*?)^  widgets\.yaml: \|",
                      text, re.M | re.S)
    if not match:
        raise ValueError("Homepage services.yaml block not found")
    links, category = [], None
    for line in match.group(1).splitlines():
        if heading := re.match(r"^    - (.+):\s*$", line):
            category = heading.group(1)
        elif url := re.match(
            r'^            href: "https://([a-z0-9-]+)\.\$\{DOMAIN\}(?:/[^"]*)?"',
            line,
        ):
            links.append({"host": url.group(1), "category": category})
    return links


def overview_routes():
    """Route table row: hostname | group | origin | primary Gatus endpoint."""
    catalog = {}
    for host, group, origin, probe in re.findall(
        r'^\| `([a-z0-9-]+)` \| `([a-z0-9-]+)` '
        r'\| `(https?://[^`]+)` \| `([a-z0-9-]+)` \|$',
        OVERVIEW.read_text(), re.M,
    ):
        if host in catalog:
            raise ValueError(f"Duplicate ingress catalog hostname '{host}'")
        catalog[host] = {"group": group, "service": origin, "probe": probe}
    return catalog


def main():
    errors = []
    try:
        routes = tunnel_routes()
        endpoints = gatus_endpoints()
        links = homepage_links()
        catalog = overview_routes()
    except (OSError, ValueError) as exc:
        print(f"ERROR: {exc}")
        return 1

    for host, route in routes.items():
        if route["group"] not in PUBLIC_GROUPS:
            errors.append(f"Terraform hostname '{host}' has invalid group '{route['group']}'")
    for endpoint in endpoints:
        if endpoint.get("group") not in GROUPS:
            errors.append(f"Gatus endpoint '{endpoint['name']}' has an invalid/missing group")
        if "host" not in endpoint:
            errors.append(f"Gatus endpoint '{endpoint['name']}' has no supported URL host")
    for name, count in Counter(e["name"] for e in endpoints).items():
        if count != 1:
            errors.append(f"duplicate Gatus endpoint name '{name}'")

    by_host = {}
    for endpoint in endpoints:
        if not endpoint["enabled"] or "host" not in endpoint:
            continue
        host = endpoint["host"]
        expected_synthetic = SYNTHETIC_ENDPOINTS.get(endpoint["name"])
        if expected_synthetic:
            if (host, endpoint.get("group")) != expected_synthetic:
                errors.append(f"edge synthetic '{endpoint['name']}' changed host/group")
            continue
        if host not in routes and host not in INTERNAL_HOSTS:
            errors.append(
                f"Gatus endpoint '{endpoint['name']}' checks unpublished host '{host}'"
            )
        if host in INTERNAL_HOSTS and endpoint.get("group") != INTERNAL_HOSTS[host]:
            errors.append(f"internal host '{host}' has wrong group in Gatus")
        by_host.setdefault(host, []).append(endpoint)

    for host, route in routes.items():
        monitors = by_host.get(host, [])
        if len(monitors) != 1:
            errors.append(f"published host '{host}' needs exactly one primary Gatus check, found {len(monitors)}")
        elif monitors[0].get("group") != route["group"]:
            errors.append(f"published host '{host}' has wrong Gatus group")
    for host in routes:
        if host in INTERNAL_HOSTS:
            errors.append(f"public host '{host}' is also marked internal only")

    by_link = {}
    for link in links:
        host, heading = link["host"], link["category"]
        if heading not in HOMEPAGE_GROUPS:
            errors.append(f"Homepage host '{host}' has unknown heading '{heading}'")
            continue
        if host in by_link:
            errors.append(f"duplicate Homepage link for '{host}'")
        by_link[host] = link
        if host in routes:
            if HOMEPAGE_GROUPS[heading] != routes[host]["group"]:
                errors.append(f"Homepage '{host}' group disagrees with Terraform")
        elif host not in UNMANAGED_HOMEPAGE_HOSTS or HOMEPAGE_GROUPS[heading] is not None:
            errors.append(f"Homepage links to undeclared public host '{host}'")
    for host in routes:
        if host not in by_link:
            errors.append(f"published host '{host}' missing from Homepage")
    for host in UNMANAGED_HOMEPAGE_HOSTS:
        if host in routes:
            errors.append(f"legacy Homepage exception '{host}' is now managed; remove exception")

    for host, route in routes.items():
        entry = catalog.get(host)
        if entry is None:
            errors.append(f"published host '{host}' missing from ingress overview")
            continue
        if entry["group"] != route["group"] or entry["service"] != route["service"]:
            errors.append(f"ingress overview drift: host/group/origin of '{host}'")
        monitors = by_host.get(host, [])
        if len(monitors) == 1 and entry["probe"] != monitors[0]["name"]:
            errors.append(f"ingress overview '{host}' has wrong Gatus probe")
    for host in catalog.keys() - routes.keys():
        errors.append(f"ingress overview lists unpublished hostname '{host}'")

    active = sum(e["enabled"] for e in endpoints)
    print(
        f"{len(routes)} declared public routes, {len(links)} Homepage links, "
        f"{active} active Gatus checks ({len(endpoints)} total), "
        f"{len(catalog)} ingress catalog entries"
    )
    for error in errors:
        print(f"ERROR: {error}")
    if not errors:
        print("PASS: Terraform, Gatus, Homepage and ingress overview agree")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
