#!/usr/bin/env bash
set -euo pipefail

# Install and configure chrony on multiple nodes using the NL NTP pool.
#
# Usage examples:
#   ./scripts/rollout-chrony-nl.sh 172.16.20.200 172.16.20.201
#   SSH_USER=admin ./scripts/rollout-chrony-nl.sh 172.16.20.200 172.16.20.201 172.16.20.202 172.16.20.203
#   NTP_POOL=nl.pool.ntp.org ./scripts/rollout-chrony-nl.sh <node-ip> [...]
#
# Notes:
# - This script expects passwordless sudo on target nodes, or it will prompt.
# - Target nodes are assumed to run Arch Linux (pacman + chronyd).

SSH_USER="${SSH_USER:-admin}"
NTP_POOL="${NTP_POOL:-nl.pool.ntp.org}"

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <node-ip-or-hostname> [more nodes...]"
  exit 1
fi

run_on_node() {
  local node="$1"
  echo "=================================================="
  echo "Node: $node"
  echo "=================================================="

  ssh -tt -o BatchMode=no -o ConnectTimeout=10 "${SSH_USER}@${node}" "NTP_POOL='${NTP_POOL}' bash -s" <<'REMOTE'
set -euo pipefail

echo "[0/5] Validating sudo access"
sudo -v

echo "[1/5] Installing chrony"
sudo pacman -S --needed --noconfirm chrony

echo "[2/5] Disabling systemd-timesyncd (if enabled)"
sudo systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true

echo "[3/5] Writing managed chrony config block"
sudo cp /etc/chrony.conf /etc/chrony.conf.bak.$(date +%Y%m%d%H%M%S)

sudo awk '
  BEGIN { inblock=0 }
  /^# BEGIN HOMELABS NTP MANAGED$/ { inblock=1; next }
  /^# END HOMELABS NTP MANAGED$/ { inblock=0; next }
  inblock==0 { print }
' /etc/chrony.conf | sudo tee /etc/chrony.conf.tmp >/dev/null

cat <<EOF | sudo tee -a /etc/chrony.conf.tmp >/dev/null
# BEGIN HOMELABS NTP MANAGED
pool ${NTP_POOL} iburst maxsources 4
# END HOMELABS NTP MANAGED
EOF

sudo mv /etc/chrony.conf.tmp /etc/chrony.conf

echo "[4/5] Enabling chronyd and forcing initial sync"
sudo systemctl enable --now chronyd
sudo chronyc -a burst 4/4 || true
sudo chronyc -a makestep || true

echo "[5/5] Verification"
timedatectl status | egrep 'System clock synchronized|NTP service|Time zone' || true
chronyc tracking | egrep 'Reference ID|Stratum|System time|Last offset|Leap status' || true
echo "Sources:"
chronyc sources -v | sed -n '1,12p' || true
REMOTE
}

failed=0
for node in "$@"; do
  if ! run_on_node "$node"; then
    echo "[ERROR] Failed on node: $node"
    failed=1
  fi
done

echo
if [ "$failed" -eq 0 ]; then
  echo "All nodes processed successfully."
else
  echo "One or more nodes failed. Review output above."
  exit 1
fi
