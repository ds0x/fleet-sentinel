#!/usr/bin/env bash
# build-golden.sh
# -----------------------------------------------------------------------------
# Build the fleet-sentinel-debian golden Tart image from scratch.
#
# Runs entirely on macOS (Apple Silicon). End-to-end:
#   1. Downloads the Debian 12 ARM64 netinst ISO (if not present).
#   2. Creates a fresh Tart Linux VM and boots the ISO in an interactive
#      window — you walk the installer once.
#   3. After install, headlessly drives setup-debian.sh via SSH.
#   4. Shuts down. Result: a Tart VM named "fleet-sentinel-debian" ready
#      for `push-image.sh` to publish to ghcr.io.
#
# Re-running with the same VM name will refuse to clobber an existing build —
# delete it first: `tart delete fleet-sentinel-debian`.
# -----------------------------------------------------------------------------
set -euo pipefail

VM="${VM_NAME:-fleet-sentinel-debian}"
ISO_VER="${DEBIAN_ISO_VER:-12.11.0}"
ISO_URL="https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/debian-${ISO_VER}-arm64-netinst.iso"
ISO_LOCAL="./debian-${ISO_VER}-arm64-netinst.iso"
RAM_MB=2048
CPUS=2
DISK_GB=8

here="$(cd "$(dirname "$0")" && pwd)"

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------
for c in tart sshpass curl; do
  command -v "$c" >/dev/null || { echo "Missing dependency: $c"; exit 1; }
done

if tart list 2>/dev/null | awk '{print $2}' | grep -qx "$VM"; then
  echo "VM '$VM' already exists. Delete it first: tart delete $VM"
  exit 1
fi

# -----------------------------------------------------------------------------
# Step 1: ISO
# -----------------------------------------------------------------------------
if [[ ! -f "$ISO_LOCAL" ]]; then
  echo "==> Downloading Debian $ISO_VER ARM64 netinst ISO (~600 MB)…"
  curl -L -o "$ISO_LOCAL" "$ISO_URL"
fi

# -----------------------------------------------------------------------------
# Step 2: create + boot installer interactively
# -----------------------------------------------------------------------------
echo "==> Creating Tart VM '$VM' (${RAM_MB} MB / ${CPUS} vCPU / ${DISK_GB} GB)"
tart create --linux "$VM"
tart set "$VM" --memory "$RAM_MB" --cpu "$CPUS" --disk-size "$DISK_GB"

cat <<EOF

==> Booting the Debian installer in a Tart window.

WALK THROUGH THE INSTALLER WITH THESE EXACT CHOICES:

  • Mode:             Graphical install
  • Hostname:         fleet-sentinel-debian
  • Domain:           (leave blank)
  • Root password:    (leave BLANK — locks root, forces sudo)
  • Username:         fleet
  • Password:         fleet
  • Partitioning:     Guided — use entire disk → single partition → finish
  • Software select:  UNCHECK everything except:
                        [x] SSH server
                        [x] standard system utilities
                      (NO desktop tasks — this script installs XFCE later.)
  • GRUB:             install to /dev/vda

When the installer reboots into the running system and presents you with a
"fleet-sentinel-debian login:" prompt, leave it as-is and CLOSE the Tart
window (or just leave it — this script will reconnect over SSH).

EOF
read -n 1 -s -r -p "Press any key to launch the installer…"
echo
tart run "$VM" --cdrom="$ISO_LOCAL"

# -----------------------------------------------------------------------------
# Step 3: headless provisioning over SSH
# -----------------------------------------------------------------------------
echo "==> Booting '$VM' headless for provisioning"
tart run --no-graphics "$VM" >/tmp/tart-build-$VM.log 2>&1 &
TART_PID=$!

# Wait for IP
IP=""
for _ in $(seq 1 60); do
  IP=$(tart ip "$VM" 2>/dev/null || true)
  [[ -n "$IP" ]] && break
  sleep 2
done
[[ -n "$IP" ]] || { echo "No IP after 2 min; aborting."; kill $TART_PID; exit 1; }
echo "    IP: $IP"

# Wait for SSH
for _ in $(seq 1 30); do
  sshpass -p fleet ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 \
    fleet@"$IP" true 2>/dev/null && break
  sleep 2
done

echo "==> Pushing setup-debian.sh and running it"
sshpass -p fleet scp -o StrictHostKeyChecking=no \
  "$here/setup-debian.sh" fleet@"$IP":/tmp/setup-debian.sh
sshpass -p fleet ssh -o StrictHostKeyChecking=no fleet@"$IP" \
  'sudo bash /tmp/setup-debian.sh'

echo "==> Shutting down for image publication"
sshpass -p fleet ssh -o StrictHostKeyChecking=no fleet@"$IP" \
  'sudo shutdown -h now' || true

# Wait up to 60s for the headless tart run to exit cleanly.
for _ in $(seq 1 30); do
  kill -0 $TART_PID 2>/dev/null || break
  sleep 2
done
kill $TART_PID 2>/dev/null || true

cat <<EOF

==> Golden image built: $VM

Next steps:
  1. Inspect:           tart list
  2. Test boot:         tart run $VM
  3. Publish:           ./push-image.sh   (or see BUILDER.md)
EOF
