#!/usr/bin/env python3
"""Check that public tunnel routes and Gatus endpoints match one to one.

Terraform (tunnel.tf, managed_apps) publishes the public routes; Gatus must
monitor every one of them, and every public Gatus URL must be a published route.
Pure standard library, no domain values: hosts are compared by prefix.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TUNNEL = ROOT / "automation/infra-as-code/terraform/deployments/tunnel.tf"
GATUS = ROOT / "platform/observability/monitoring/gatus/gatus-configmap-config.yaml"

# Hosts that Gatus checks but that are intentionally not published through the tunnel.
INTERNAL_HOSTS = {"api-gw"}  # Kong host, resolved in-cluster by CoreDNS
GROUPS = {"00-edge", "10-platform", "20-ai", "30-apps", "35-firewall-manager", "40-storage",
          "50-admin", "60-synology", "70-network"}


def tunnel_hosts():
    text = TUNNEL.read_text()
    body = re.search(r"managed_apps\s*=\s*\{(.*?)\n  \}", text, re.S).group(1)
    return set(re.findall(r'"([a-z0-9-]+)\.\$\{var\.domain\}"\s*=', body))


def gatus_endpoints():
    endpoints, current = [], None
    for line in GATUS.read_text().splitlines():
        m = re.match(r"\s+- name: (.+)", line)
        if m:
            current = {"name": m.group(1).strip().strip('"'), "enabled": True}
            endpoints.append(current)
        elif current is not None:
            if (m := re.match(r"\s+group: (\S+)", line)):
                current["group"] = m.group(1)
            elif (m := re.match(r'\s+url: "?https://([a-z0-9-]+)\.\$\{DOMAIN\}', line)):
                current["host"] = m.group(1)
            elif re.match(r"\s+enabled: false", line):
                current["enabled"] = False
    return [e for e in endpoints if "group" in e]


def main():
    routes, endpoints = tunnel_hosts(), gatus_endpoints()
    active = [e for e in endpoints if e["enabled"] and e.get("host")]
    monitored = {e["host"] for e in active}
    errors = []
    for host in sorted(routes - monitored):
        errors.append(f"public route '{host}' has no enabled Gatus endpoint")
    for e in active:
        if e["host"] not in routes and e["host"] not in INTERNAL_HOSTS:
            errors.append(f"Gatus endpoint '{e['name']}' checks '{e['host']}', which is not a published route")
    for e in endpoints:
        if e["group"] not in GROUPS:
            errors.append(f"Gatus endpoint '{e['name']}' uses unknown group '{e['group']}'")
    names = [e["name"] for e in endpoints]
    for name in sorted({n for n in names if names.count(n) > 1}):
        errors.append(f"duplicate Gatus endpoint name '{name}'")
    print(f"{len(routes)} public routes, {len(active)} active Gatus endpoints, {len(endpoints)} total")
    for err in errors:
        print(f"ERROR: {err}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
