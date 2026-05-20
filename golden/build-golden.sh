#!/usr/bin/env bash
# build-golden.sh
# -----------------------------------------------------------------------------
# Build the fleet-sentinel-ubuntu golden Tart image.
#
# Strategy: clone the cirruslabs/ubuntu base (already a Tart-native Linux
# image, no ISO install needed), boot it headless, SSH in, run setup-vm.sh
# to add XFCE + the fleet user + the enroll.sh staging, then shut down.
#
# Total wall-clock: ~5 min on first run (~700 MB pull); ~2 min on rebuilds.
#
# Re-running with the same VM name will refuse to clobber an existing build —
# delete it first: `tart delete fleet-sentinel-ubuntu`.
# -----------------------------------------------------------------------------
set -euo pipefail

VM="${VM_NAME:-fleet-sentinel-ubuntu}"
BASE="${BASE_IMAGE:-ghcr.io/cirruslabs/ubuntu:22.04}"
RAM_MB=2048
CPUS=2
SSH_USER=admin       # cirruslabs default; setup-vm.sh removes this user later
SSH_PASS=admin

here="$(cd "$(dirname "$0")" && pwd)"

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------
for c in tart sshpass; do
  command -v "$c" >/dev/null || { echo "Missing dependency: $c"; exit 1; }
done

if tart list 2>/dev/null | awk '{print $2}' | grep -qx "$VM"; then
  echo "VM '$VM' already exists. Delete it first: tart delete $VM"
  exit 1
fi

# -----------------------------------------------------------------------------
# Clone the cirruslabs base
# -----------------------------------------------------------------------------
echo "==> Cloning $BASE → $VM (first run pulls ~700 MB)"
tart clone "$BASE" "$VM"
tart set "$VM" --memory "$RAM_MB" --cpu "$CPUS"
echo "    RAM: ${RAM_MB} MB / vCPUs: ${CPUS} / disk: cirruslabs default (50 GB thin)"

# -----------------------------------------------------------------------------
# Boot headless and wait for SSH
# -----------------------------------------------------------------------------
echo "==> Starting '$VM' headless"
tart run --no-graphics "$VM" >/tmp/tart-build-${VM}.log 2>&1 &
TART_PID=$!

IP=""
for _ in $(seq 1 60); do
  IP=$(tart ip "$VM" 2>/dev/null || true)
  [[ -n "$IP" ]] && break
  sleep 2
done
if [[ -z "$IP" ]]; then
  echo "No IP from VM after 2 min. Check /tmp/tart-build-${VM}.log"
  kill $TART_PID 2>/dev/null || true
  exit 1
fi
echo "    VM IP: $IP"

echo "==> Waiting for SSH (cirruslabs default: $SSH_USER/$SSH_PASS)"
for _ in $(seq 1 30); do
  sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 \
    "${SSH_USER}@${IP}" true 2>/dev/null && break
  sleep 2
done

# -----------------------------------------------------------------------------
# Push setup-vm.sh and run it
# -----------------------------------------------------------------------------
echo "==> Pushing setup-vm.sh and running provisioning (~3 min)"
sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no \
  "$here/setup-vm.sh" "${SSH_USER}@${IP}":/tmp/setup-vm.sh
sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no "${SSH_USER}@${IP}" \
  'sudo bash /tmp/setup-vm.sh'

# -----------------------------------------------------------------------------
# Finalize from a fleet-user SSH session. Doing the admin-user deletion and
# the identity-clearing from the admin session itself would kill our own SSH
# (deluser admin SIGHUPs our shell). Hopping to fleet first sidesteps that.
# -----------------------------------------------------------------------------
echo "==> Verifying fleet user works"
for _ in $(seq 1 15); do
  sshpass -p fleet ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 \
    "fleet@${IP}" true 2>/dev/null && break
  sleep 2
done

echo "==> Finalizing image as fleet user (remove admin, clean caches, zero IDs, poweroff)"
sshpass -p fleet ssh -o StrictHostKeyChecking=no "fleet@${IP}" bash <<'FINALIZE'
set -euo pipefail
echo "--- removing cirruslabs admin user"
if id admin >/dev/null 2>&1; then
  sudo pkill -u admin 2>/dev/null || true
  sleep 1
  sudo deluser --remove-home admin 2>/dev/null || sudo userdel -r admin 2>/dev/null || true
fi

echo "--- apt clean + autoremove"
sudo apt-get -y autoremove --purge
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*

echo "--- truncating logs + zeroing identifiers"
sudo find /var/log -type f -exec truncate -s 0 {} \;
sudo bash -c '> /etc/machine-id'
sudo rm -f /var/lib/dbus/machine-id
sudo ln -s /etc/machine-id /var/lib/dbus/machine-id
sudo rm -f /etc/ssh/ssh_host_*    # sshd regenerates on next boot

SWAPDEV=$(swapon --show=NAME --noheadings 2>/dev/null | head -n1 || true)
if [[ -n "$SWAPDEV" ]]; then sudo swapoff "$SWAPDEV" || true; fi

echo "--- powering off"
sudo systemctl poweroff
FINALIZE

# Wait for the VM to actually be down. We poll for two things:
#   (a) `tart ip` stops returning an address (definitive signal that the VM
#       is no longer reachable on the network).
#   (b) the headless `tart run` process exits.
# Give it up to 90 s total — Ubuntu's shutdown can stall briefly on cgroup
# teardown if cloud-init was incompletely purged.
echo "    Waiting for VM to power off (up to 90s)…"
for i in $(seq 1 45); do
  if ! tart ip "$VM" >/dev/null 2>&1; then
    # IP gone — VM is down or unreachable. Give the tart process a few more
    # seconds to notice and exit.
    for _ in $(seq 1 10); do
      kill -0 $TART_PID 2>/dev/null || break 2
      sleep 1
    done
    break
  fi
  sleep 2
done

# Only ungracefully kill if the VM truly didn't go down.
if kill -0 $TART_PID 2>/dev/null; then
  echo "    [!] VM did not power off cleanly within 90s — sending SIGTERM to tart"
  echo "        (this can leave the image in a sub-optimal state; see BUILDER.md)"
  kill $TART_PID 2>/dev/null || true
  wait $TART_PID 2>/dev/null || true
else
  echo "    VM powered off cleanly."
fi

cat <<EOF

==> Golden image built: $VM

Next steps:
  1. (Optional) Test boot:  tart run $VM   # XFCE auto-logs in as 'fleet'
  2. Publish to ghcr.io:    ./push-image.sh
EOF
