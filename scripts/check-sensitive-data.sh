#!/usr/bin/env bash
# Scan text for private values (such as the real homelab domain) without ever
# printing the value itself. Used by .githooks/*, the Copilot agent hook and CI.
#
# Usage: check-sensitive-data.sh [--label NAME] [FILE...]   (stdin when no FILE)
#
# Patterns are literal, case-insensitive, one per line, and are merged from:
#   $PRIVATE_PUBLIC_DOMAIN, $SENSITIVE_PATTERNS,
#   <git-common-dir>/info/forbidden-patterns, ~/.config/homelabs/forbidden-patterns
#
# Exit codes: 0 clean, 1 match found, 3 no patterns configured.
set -euo pipefail

label=""
if [ "${1:-}" = "--label" ]; then
  label="$2"
  shift 2
fi

patterns="$(mktemp)"
trap 'rm -f "$patterns"' EXIT

{
  printf '%s\n' "${PRIVATE_PUBLIC_DOMAIN:-}"
  printf '%s\n' "${SENSITIVE_PATTERNS:-}"
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  [ -n "$common_dir" ] && [ -r "$common_dir/info/forbidden-patterns" ] && cat "$common_dir/info/forbidden-patterns"
  [ -r "${HOME:-}/.config/homelabs/forbidden-patterns" ] && cat "$HOME/.config/homelabs/forbidden-patterns"
} 2>/dev/null | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' -e '/^#/d' | sort -u > "$patterns" || true

if [ ! -s "$patterns" ]; then
  echo "check-sensitive-data: no private patterns configured (see docs/sensitive-data-guard.md)" >&2
  exit 3
fi

found=0
scan() {
  local name="$1" file="$2" lines
  lines="$(grep -n -i -F -f "$patterns" -- "$file" 2>/dev/null | cut -d: -f1 | sort -un | tr '\n' ' ' || true)"
  if [ -n "$lines" ]; then
    echo "check-sensitive-data: private value found in ${name} (line(s): ${lines% }); value hidden" >&2
    found=1
  fi
}

if [ "$#" -eq 0 ]; then
  scan "${label:-stdin}" /dev/stdin
else
  for f in "$@"; do
    scan "${label:+$label: }$f" "$f"
  done
fi

exit "$found"
