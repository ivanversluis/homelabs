# Shared helper for the private-data git hooks. Sourced, not executed.
# Enable the hooks once per clone:  git config core.hooksPath .githooks

guard_scan() {
  # guard_scan LABEL [FILE...]  (stdin when no FILE)
  local root rc=0
  root="$(git rev-parse --show-toplevel)"
  "$root/scripts/check-sensitive-data.sh" --label "$@" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1)
      echo "BLOCKED: a private value (e.g. the real domain) is in the $1." >&2
      echo "Use \${DOMAIN} in manifests/docs or <domain> in prose, then retry." >&2
      exit 1
      ;;
    3)
      if [ "${ALLOW_MISSING_SENSITIVE_PATTERNS:-}" = "1" ]; then
        return 0
      fi
      echo "BLOCKED: no private patterns configured, so the leak check cannot run." >&2
      echo "Create .git/info/forbidden-patterns (see docs/sensitive-data-guard.md)" >&2
      echo "or set ALLOW_MISSING_SENSITIVE_PATTERNS=1 for this command." >&2
      exit 1
      ;;
    *) echo "BLOCKED: leak check failed with exit code $rc." >&2; exit 1 ;;
  esac
}
