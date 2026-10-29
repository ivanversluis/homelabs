#!/usr/bin/env bash
# Read-only, bounded disk diagnosis; called inline over Ansible SSH (no remote file writes).
set -eu
export LC_ALL=C

root="${DISK_INSPECTION_ROOT:-/}"
longhorn="${DISK_INSPECTION_LONGHORN_PATH:-/var/lib/longhorn}"
levels="${DISK_PATH_MAX_LEVELS:-5}"
longhorn_levels="${DISK_PATH_LONGHORN_LEVELS:-2}"
max_entries="${DISK_PATH_TOP_ENTRIES:-15}"
scan_timeout="${DISK_PATH_TIMEOUT_SECONDS:-120}"
incomplete=0

# Guard an accidental alternate scan root (also used by local tests).
case "$root" in /*) ;; *) echo "ERROR: root path must be absolute" >&2; exit 1 ;; esac
case "$longhorn" in /*) ;; *) echo "ERROR: Longhorn path must be absolute" >&2; exit 1 ;; esac
if [ ! -d "$root" ]; then
  echo "ERROR: scan root does not exist: $root" >&2
  exit 1
fi

scan_one_level() {
  # Debian/Arch GNU coreutils and util-linux: bounded I/O and CPU priority.
  # du -x never traverses another filesystem (e.g., PVCs mounted by kubelet).
  if command -v ionice >/dev/null 2>&1; then
    timeout --signal=TERM --kill-after=5s "${scan_timeout}s" \
      nice -n 19 ionice -c3 du -x -B1 --max-depth=1 -- "$1"
  else
    timeout --signal=TERM --kill-after=5s "${scan_timeout}s" \
      nice -n 19 du -x -B1 --max-depth=1 -- "$1"
  fi
}

inspect_path() {
  label="$1"
  cursor="$2"
  maximum="$3"
  step=0

  printf '\n===== %s =====\n' "$label"
  printf 'Scope: %s, filesystem boundary enforced (-x)\n' "$cursor"
  while [ "$step" -lt "$maximum" ]; do
    printf '\n-- Depth %s: %s --\n' "$step" "$cursor"
    # Keep all scan values in memory: no temp output files on a full disk.
    if rows="$(scan_one_level "$cursor" 2>/dev/null)"; then
      sorted="$(printf '%s\n' "$rows" | sort -k1,1nr)"
    else
      printf 'INCOMPLETE: du failed or exceeded %ss scanning %s; no size conclusion is safe.\n' "$scan_timeout" "$cursor"
      incomplete=1
      break
    fi

    if [ "$step" -eq 0 ] && [ "$label" = "Root filesystem" ]; then
      show_all=1
    else
      show_all=0
    fi
    printf '%s\n' "$sorted" | awk -F '\t' \
      -v current="$cursor" -v top="$max_entries" -v show_all="$show_all" '
        $2 == current {
          printf "TOTAL %10.2f GiB  %s\n", $1 / 1073741824, $2
          next
        }
        show_all == 1 || printed < top {
          printf "      %10.2f GiB  %s\n", $1 / 1073741824, $2
          printed++
          next
        }
        { omitted++ }
        END { if (omitted > 0) printf "      ... %d smaller sibling directories omitted\n", omitted }
      '

    biggest="$(printf '%s\n' "$sorted" | awk -F '\t' -v current="$cursor" '$2 != current { print $2; exit }')"
    if [ -z "$biggest" ] || [ "$biggest" = "$cursor" ]; then
      printf 'No further child directory available.\n'
      break
    fi

    printf 'LARGEST CHILD: %s\n' "$biggest"
    cursor="$biggest"
    step=$((step + 1))
  done
  printf 'DEEPEST INVESTIGATED PATH: %s\n' "$cursor"
}

printf '===== NODE: %s =====\n' "${DISK_INSPECTION_NODE_NAME:-$(hostname -s)}"
printf '\n-- Filesystems (df -hPT) --\n'
df -hPT "$root"
printf '\n-- Inodes (df -iP) --\n'
df -iP "$root"
printf '\n-- Root mount (findmnt) --\n'
findmnt -T "$root" -o TARGET,SOURCE,FSTYPE -n || true

if [ -d "$longhorn" ]; then
  printf '\n-- Longhorn storage path and mount --\n'
  df -hPT "$longhorn"
  findmnt -T "$longhorn" -o TARGET,SOURCE,FSTYPE -n || true
  root_device="$(stat -c '%d' "$root")"
  longhorn_device="$(stat -c '%d' "$longhorn")"
  if [ "$root_device" = "$longhorn_device" ]; then
    printf 'Longhorn path shares the root filesystem. Root scan includes it.\n'
  else
    printf 'Longhorn uses a separate filesystem; it is not included in the root scan.\n'
  fi
fi

# First list EVERY first-level directory below /, then recurse only
# into the single largest child at each depth to limit disk I/O.
inspect_path "Root filesystem" "$root" "$levels"

if [ "$longhorn_levels" -gt 0 ] && [ -d "$longhorn" ]; then
  # Force visibility for Longhorn, even if its directory wasn't the
  # largest root branch. This is particularly important on a second disk.
  inspect_path "Longhorn storage path" "$longhorn" "$longhorn_levels"
fi

printf '\n-- System journal allocation (informational) --\n'
if command -v journalctl >/dev/null 2>&1; then
  journalctl --disk-usage 2>/dev/null || true
fi

printf '\n-- Interpretation --\n'
printf 'Directory sizes are allocated blocks in GiB, not file content size.\n'
printf 'du -x excludes mounted PVCs and other devices; df may still include reserved or open-deleted blocks.\n'
printf 'The largest path is evidence to investigate, not an instruction to delete anything.\n'

if [ "$incomplete" -ne 0 ]; then
  printf 'ERROR: One or more scans were incomplete. Treat this report as partial.\n' >&2
  exit 1
fi
