#!/usr/bin/env bash
# setup-debian.sh
# -----------------------------------------------------------------------------
# Runs inside the freshly-installed Debian 12 ARM64 VM during the golden-image
# build (driven by build-golden.sh). End users NEVER run this — the published
# Tart image already has all of this baked in.
#
# What it does:
#   1. Slim base + install lightweight XFCE desktop with autologin.
#   2. Stage /opt/fleet-sentinel/enroll.sh — invoked by the fleet-sentinel
#      wrapper on the host to perform enrollment on a fresh clone.
#   3. Clear identifiers so the image is safe to publish + clone.
# -----------------------------------------------------------------------------
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }

log() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }

export DEBIAN_FRONTEND=noninteractive

# -----------------------------------------------------------------------------
# 1. Base
# -----------------------------------------------------------------------------
log "Updating apt + base utilities"
apt-get update
apt-get -y upgrade
apt-get -y install \
  curl ca-certificates gnupg \
  sudo openssh-server \
  qemu-guest-agent spice-vdagent \
  dbus-user-session uuid-runtime jq

# -----------------------------------------------------------------------------
# 2. Lightweight desktop
# -----------------------------------------------------------------------------
log "Installing XFCE + lightdm"
apt-get -y install --no-install-recommends \
  xfce4 xfce4-terminal \
  lightdm lightdm-gtk-greeter \
  xserver-xorg-core xserver-xorg-video-fbdev \
  xserver-xorg-input-libinput \
  fonts-dejavu-core \
  network-manager network-manager-gnome \
  polkitd     # 'policykit-1' was renamed to 'polkitd' in Debian 12

systemctl enable lightdm.service

# Autologin so end users see a desktop immediately when the GUI window opens.
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-autologin.conf <<EOF
[Seat:*]
autologin-user=fleet
autologin-user-timeout=0
EOF

# -----------------------------------------------------------------------------
# 3. Default user 'fleet' (password 'fleet'; rotated per build elsewhere if needed)
# -----------------------------------------------------------------------------
log "Configuring user 'fleet'"
id fleet >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo fleet
echo 'fleet:fleet' | chpasswd
# Allow passwordless sudo for the wrapper's enrollment SSH commands.
echo 'fleet ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-fleet
chmod 0440 /etc/sudoers.d/90-fleet

# -----------------------------------------------------------------------------
# 4. Pre-stage layout for the wrapper
# -----------------------------------------------------------------------------
log "Staging /opt/fleet-sentinel + /etc/fleet-sentinel"
mkdir -p /opt/fleet-sentinel /etc/fleet-sentinel /var/log/fleet-sentinel
chown root:root /opt/fleet-sentinel /etc/fleet-sentinel
chmod 0755 /opt/fleet-sentinel
chmod 0700 /etc/fleet-sentinel

# -----------------------------------------------------------------------------
# 5. The enroll script the wrapper triggers via SSH on each fresh clone
# -----------------------------------------------------------------------------
install -m 0755 /dev/stdin /opt/fleet-sentinel/enroll.sh <<'ENROLL'
#!/usr/bin/env bash
# /opt/fleet-sentinel/enroll.sh
# Invoked by the fleet-sentinel host wrapper after it has scp'd:
#   /etc/fleet-sentinel/config.env                       (FLEET_URL, FLEET_ENROLL_SECRET, PREFIX)
#   /opt/fleet-sentinel/fleet-osquery_arm64.deb          (built by `fleetctl package`)
set -euo pipefail

LOG=/var/log/fleet-sentinel/enroll.log
mkdir -p "$(dirname "$LOG")"
# Log to file *and* keep stdout/stderr so `ssh ... enroll.sh` shows progress.
exec > >(tee -a "$LOG") 2>&1
echo "=== fleet-sentinel enroll @ $(date -Is) ==="

CONFIG=/etc/fleet-sentinel/config.env
DEB=/opt/fleet-sentinel/fleet-osquery_arm64.deb
[[ -f "$CONFIG" ]] || { echo "Missing $CONFIG"; exit 1; }
[[ -f "$DEB"    ]] || { echo "Missing $DEB";    exit 1; }
# shellcheck disable=SC1090
source "$CONFIG"
: "${FLEET_URL:?FLEET_URL is required}"
: "${FLEET_ENROLL_SECRET:?FLEET_ENROLL_SECRET is required}"
PREFIX="${FLEET_HOSTNAME_PREFIX:-fleet-sentinel}"

# --- Unique machine-id (in case the image was cloned without re-genning) ---
echo "Regenerating /etc/machine-id"
rm -f /etc/machine-id /var/lib/dbus/machine-id
systemd-machine-id-setup
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# --- Unique hostname using `od` (always present via coreutils; no xxd dep) ---
SUFFIX=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
NEWHOST="${PREFIX}-${SUFFIX}"
echo "Setting hostname → $NEWHOST"
hostnamectl set-hostname "$NEWHOST"
if grep -q '^127\.0\.1\.1' /etc/hosts; then
  sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NEWHOST/" /etc/hosts
else
  printf '127.0.1.1\t%s\n' "$NEWHOST" >> /etc/hosts
fi

# --- Clear any prior orbit/osquery state (defensive; should be empty on a fresh clone) ---
rm -rf /var/lib/orbit /var/osquery/osquery.db
systemctl stop orbit 2>/dev/null || true

# --- Install fleetd ---
echo "Installing fleetd from $DEB"
dpkg -i "$DEB" || apt-get -y -f install

# --- Start + verify ---
systemctl enable --now orbit.service
sleep 2
systemctl is-active --quiet orbit.service && echo "orbit: active" || echo "orbit: NOT active (check $LOG)"
echo "=== enroll complete @ $(date -Is) ==="
ENROLL

# -----------------------------------------------------------------------------
# 6. Clean for image publication
# -----------------------------------------------------------------------------
log "Cleaning apt caches"
apt-get clean
rm -rf /var/lib/apt/lists/*

log "Truncating logs + zeroing identifiers"
find /var/log -type f -exec truncate -s 0 {} \;
> /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id
rm -f /etc/ssh/ssh_host_*    # sshd regenerates on next boot

# Zero swap if present.
SWAPDEV=$(swapon --show=NAME --noheadings 2>/dev/null | head -n1 || true)
[[ -n "$SWAPDEV" ]] && swapoff "$SWAPDEV" || true

log "Setup complete. Shut down with: sudo shutdown -h now"
