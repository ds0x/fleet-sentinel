#!/usr/bin/env bash
# setup-vm.sh
# -----------------------------------------------------------------------------
# Customizes a cirruslabs/ubuntu-based Tart VM into the fleet-sentinel golden
# image. Runs inside the VM via SSH, driven by build-golden.sh.
#
# Works on any apt-based distro (kept distro-agnostic in case we ever want to
# swap the base back to Debian or out to a different Ubuntu LTS).
#
# What it does:
#   1. Installs lightweight XFCE + lightdm with autologin for the 'fleet' user.
#   2. Creates the 'fleet' user (cirruslabs ships with 'admin'; our wrapper
#      expects 'fleet').
#   3. Disables cloud-init so it doesn't undo our identity changes on first boot.
#   4. Stages /opt/fleet-sentinel/enroll.sh — invoked by the host wrapper on
#      each fresh clone to enroll into Fleet.
#   5. Clears identifiers so the image is safe to publish + clone.
# -----------------------------------------------------------------------------
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }

log() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }

export DEBIAN_FRONTEND=noninteractive

# -----------------------------------------------------------------------------
# 1. Base updates. cirruslabs/ubuntu already ships curl, ssh-server, sudo,
#    qemu-guest-agent, ca-certificates — so this is mostly upgrade + extras.
# -----------------------------------------------------------------------------
log "Refreshing apt metadata + installing base utilities"
# Note: we do NOT run `apt-get upgrade`. The cirruslabs/ubuntu base image's
# cached metadata can lag behind ports.ubuntu.com's pool — i.e. the metadata
# lists a package version whose .deb has already been GC'd from the mirror.
# That manifests as 404s during upgrade. Since this image is going to be
# managed by fleetd (which is what we're enrolling), the base just needs
# to be functional, not patched-to-the-minute.
apt-get update
apt-get -y --fix-missing install --no-install-recommends \
  spice-vdagent \
  dbus-user-session \
  uuid-runtime jq

# -----------------------------------------------------------------------------
# 2. Disable cloud-init. cirruslabs images use it to inject SSH keys + set
#    hostnames at first boot; we override both of those ourselves.
# -----------------------------------------------------------------------------
log "Disabling cloud-init"
apt-get -y purge cloud-init || true
rm -rf /etc/cloud /var/lib/cloud

# -----------------------------------------------------------------------------
# 3. Lightweight desktop
# -----------------------------------------------------------------------------
log "Installing XFCE + lightdm"
apt-get -y --fix-missing install --no-install-recommends \
  xfce4 xfce4-terminal \
  lightdm lightdm-gtk-greeter \
  xserver-xorg-core xserver-xorg-video-fbdev \
  xserver-xorg-input-libinput \
  fonts-dejavu-core \
  network-manager network-manager-gnome \
  polkitd

# Don't install pulseaudio (~30-50 MB) — image stays thin. The cosmetic
# "Not connected to PulseAudio" complaint persists; it's a known XFCE
# pre-startup notice that doesn't block anything. We CANNOT purge
# xfce4-pulseaudio-plugin here: it's a hard Depends of the xfce4 meta
# package, so removing the plugin cascades to remove xfce4 itself.

systemctl enable lightdm.service

# Autologin so the end user sees the desktop immediately when fleet-sentinel
# switches to graphical mode.
#
# On Ubuntu 22.04, lightdm's autologin requires the user to be in the
# `autologin` group (sometimes `nopasswdlogin`). Without that, lightdm
# silently falls back to a normal login screen.
groupadd -f autologin
groupadd -f nopasswdlogin

mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-autologin.conf <<EOF
[Seat:*]
autologin-user=fleet
autologin-user-timeout=0
autologin-session=xfce
EOF

# -----------------------------------------------------------------------------
# 4. Create the 'fleet' user that the host wrapper SSHes in as
# -----------------------------------------------------------------------------
log "Creating user 'fleet' (and adding to autologin/nopasswdlogin groups)"
id fleet >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo fleet
echo 'fleet:fleet' | chpasswd
usermod -aG autologin,nopasswdlogin fleet
echo 'fleet ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-fleet
chmod 0440 /etc/sudoers.d/90-fleet

# -----------------------------------------------------------------------------
# 5. Pre-stage the fleet-sentinel layout
# -----------------------------------------------------------------------------
log "Staging /opt/fleet-sentinel + /etc/fleet-sentinel"
mkdir -p /opt/fleet-sentinel /etc/fleet-sentinel /var/log/fleet-sentinel
chown root:root /opt/fleet-sentinel /etc/fleet-sentinel
chmod 0755 /opt/fleet-sentinel
chmod 0700 /etc/fleet-sentinel

# -----------------------------------------------------------------------------
# 6. enroll.sh — invoked by the host wrapper on each fresh clone
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

# Unique machine-id
echo "Regenerating /etc/machine-id"
rm -f /etc/machine-id /var/lib/dbus/machine-id
systemd-machine-id-setup
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# Unique hostname (od is in coreutils, always present; no xxd dependency)
SUFFIX=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
NEWHOST="${PREFIX}-${SUFFIX}"
echo "Setting hostname → $NEWHOST"
hostnamectl set-hostname "$NEWHOST"
if grep -q '^127\.0\.1\.1' /etc/hosts; then
  sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NEWHOST/" /etc/hosts
else
  printf '127.0.1.1\t%s\n' "$NEWHOST" >> /etc/hosts
fi

# Clear prior orbit state defensively
rm -rf /var/lib/orbit /var/osquery/osquery.db
systemctl stop orbit 2>/dev/null || true

echo "Installing fleetd from $DEB"
dpkg -i "$DEB" || apt-get -y -f install

systemctl enable --now orbit.service
sleep 2
systemctl is-active --quiet orbit.service && echo "orbit: active" || echo "orbit: NOT active (check $LOG)"
echo "=== enroll complete @ $(date -Is) ==="
ENROLL

# -----------------------------------------------------------------------------
# Cleanup that needs admin removed AND poweroff is handled by build-golden.sh
# in a *separate* fleet-user SSH session. Doing it from here would kill our
# own session: this script runs over `ssh admin@VM 'sudo bash setup-vm.sh'`,
# and `deluser admin` cascades SIGHUP through the admin shell that owns us.
# -----------------------------------------------------------------------------
log "Setup complete. build-golden.sh will now finalize via the fleet user."
