#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if ! command -v "$KUBECTL_BIN" >/dev/null 2>&1; then
  echo "ERROR: $KUBECTL_BIN is required to render Kustomizations" >&2
  exit 1
fi

declare -A expected_empty=(
  [services]=1
  [workloads/apps]=1
)

mapfile -d '' kustomizations < <(
  find \
    "$REPO_ROOT/clusters/k8s-homelab" \
    "$REPO_ROOT/infra" \
    "$REPO_ROOT/platform" \
    "$REPO_ROOT/services" \
    "$REPO_ROOT/workloads" \
    -type f -name kustomization.yaml -print0 |
    sort -z
)

if (("${#kustomizations[@]}" == 0)); then
  echo "ERROR: no Kustomizations found" >&2
  exit 1
fi

for index in "${!kustomizations[@]}"; do
  file="${kustomizations[$index]}"
  directory="$(dirname "$file")"
  relative="${directory#"$REPO_ROOT"/}"
  rendered="$TMP_DIR/rendered-$index.yaml"
  substituted="$TMP_DIR/substituted-$index.yaml"

  echo "::group::Render $relative"
  "$KUBECTL_BIN" kustomize "$directory" \
    --load-restrictor=LoadRestrictionsNone >"$rendered"

  if [[ ! -s "$rendered" ]]; then
    if [[ -n "${expected_empty[$relative]:-}" ]]; then
      echo "Expected empty ownership aggregator: $relative"
      echo "::endgroup::"
      continue
    fi

    echo "ERROR: $relative rendered no resources" >&2
    exit 1
  fi

  sed \
    -e 's/${DOMAIN}/ci.example.invalid/g' \
    -e 's/${ACME_EMAIL}/ci@example.invalid/g' \
    -e 's/${KONG_LB_IP}/192.0.2.10/g' \
    -e 's/${KONG_EXTERNAL_LB_IP}/192.0.2.11/g' \
    -e 's/${MIKROTIK_IP}/192.0.2.12/g' \
    -e 's#${GOODWE_INVERTER_CIDR}#192.0.2.0/24#g' \
    "$rendered" >"$substituted"

  if grep -vE '^[[:space:]]*#' "$substituted" |
    grep -nE '\$\{[A-Z][A-Z0-9_]*\}'; then
    echo "ERROR: $relative contains an unresolved Flux substitution" >&2
    exit 1
  fi

  echo "::endgroup::"
done

echo "Rendered and checked ${#kustomizations[@]} Kustomizations."
