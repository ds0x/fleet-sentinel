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

echo "==> Shutting down for image publication"
# We just removed the admin user; if that succeeded, this ssh will fail —
# that's fine, shutdown -h will already have been requested OR we can fall
# back to the fleet user.
sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no "${SSH_USER}@${IP}" \
  'sudo shutdown -h now' 2>/dev/null \
  || sshpass -p fleet ssh -o StrictHostKeyChecking=no "fleet@${IP}" \
       'sudo shutdown -h now' 2>/dev/null \
  || true

# Wait up to 60s for the headless tart run to exit cleanly.
for _ in $(seq 1 30); do
  kill -0 $TART_PID 2>/dev/null || break
  sleep 2
done
kill $TART_PID 2>/dev/null || true

cat <<EOF

==> Golden image built: $VM

Next steps:
  1. (Optional) Test boot:  tart run $VM   # XFCE auto-logs in as 'fleet'
  2. Publish to ghcr.io:    ./push-image.sh
EOF
