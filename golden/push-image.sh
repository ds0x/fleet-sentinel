#!/usr/bin/env bash
# push-image.sh
# -----------------------------------------------------------------------------
# Publish the freshly-built golden Tart image to ghcr.io.
#
# Prereqs:
#   1. `tart` installed and a built VM named "fleet-sentinel-debian" exists
#      (run ./build-golden.sh first).
#   2. A GitHub Personal Access Token with `write:packages` scope, exported as
#      GITHUB_TOKEN. Generate at: https://github.com/settings/tokens
#      Permissions needed:  write:packages, read:packages, delete:packages
#   3. GITHUB_USER set to your GitHub username (defaults to $USER).
#
# Pushes two tags:
#   ghcr.io/ds0x/fleet-sentinel-debian:latest
#   ghcr.io/ds0x/fleet-sentinel-debian:<VERSION>      (default: today's date)
# -----------------------------------------------------------------------------
set -euo pipefail

VM="${VM_NAME:-fleet-sentinel-debian}"
REGISTRY="${REGISTRY:-ghcr.io}"
NAMESPACE="${NAMESPACE:-ds0x}"
IMAGE="${IMAGE:-fleet-sentinel-debian}"
VERSION="${VERSION:-$(date +%Y.%m.%d)}"

LATEST="$REGISTRY/$NAMESPACE/$IMAGE:latest"
VERSIONED="$REGISTRY/$NAMESPACE/$IMAGE:$VERSION"

# Pre-flight
command -v tart >/dev/null || { echo "tart not installed"; exit 1; }
tart list 2>/dev/null | awk '{print $2}' | grep -qx "$VM" \
  || { echo "VM '$VM' not found. Run ./build-golden.sh first."; exit 1; }

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "Set GITHUB_TOKEN (PAT with write:packages scope) and re-run."
  echo "  https://github.com/settings/tokens"
  exit 1
fi
GITHUB_USER="${GITHUB_USER:-$USER}"

echo "==> Logging in to $REGISTRY as $GITHUB_USER"
echo "$GITHUB_TOKEN" | tart login "$REGISTRY" --username "$GITHUB_USER" --password-stdin

echo "==> Pushing $VERSIONED"
tart push "$VM" "$VERSIONED"

echo "==> Tagging as :latest → $LATEST"
tart push "$VM" "$LATEST"

cat <<EOF

==> Published.
    $VERSIONED
    $LATEST

End users can now run:
  brew install ds0x/tap/fleet-sentinel
  fleet-sentinel https://fleet.example.com  YOUR_ENROLL_SECRET

Or, the raw tart equivalent (no wrapper):
  tart clone $LATEST fleet-sentinel
  tart run fleet-sentinel       # (no automatic enrollment — wrapper handles that)
EOF
