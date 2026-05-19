# Building and publishing the fleet-sentinel-ubuntu image

Audience: **you (the maintainer)**. End users never need this — they just
`brew install ds0x/tap/fleet-sentinel` and run the wrapper.

This walkthrough takes a clean Apple Silicon Mac to a published Tart
image on ghcr.io in roughly 30 minutes.

## Phase 0 — Prereqs

```bash
brew install cirruslabs/cli/tart
# fleetctl ships via ds0x's own Homebrew tap (Fleet's CLI isn't in
# homebrew-core; `fleet-cli` in core is Rancher's Kubernetes Fleet):
brew install ds0x/fleetctl/fleetctl
brew install hudochenkov/sshpass/sshpass
brew install curl
```

A **GitHub Personal Access Token** with `write:packages` scope:
https://github.com/settings/tokens (Classic tokens, or fine-grained with
"Packages: read/write" on `ds0x/*`).

```bash
export GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx
export GITHUB_USER=ds0x
```

## Phase 1 — Build the golden VM

```bash
cd golden/
chmod +x build-golden.sh setup-vm.sh push-image.sh
./build-golden.sh
```

The script will:

1. `tart clone ghcr.io/cirruslabs/ubuntu:22.04 fleet-sentinel-ubuntu`
   (first run pulls ~700 MB; subsequent rebuilds reuse the cache).
2. Boot the VM headless, wait for SSH.
3. scp `setup-vm.sh` and run it: installs XFCE + lightdm with autologin,
   creates the `fleet` user, disables cloud-init, stages
   `/opt/fleet-sentinel/enroll.sh`, removes the cirruslabs `admin` user,
   and clears identifiers.
4. Shut the VM down.

Expected runtime:
- First run: ~5 min (~3 min pull + ~2 min provisioning)
- Subsequent rebuilds: ~2 min

At the end you have a stopped Tart VM that's ready to publish.

### Verifying the image before pushing

```bash
tart run fleet-sentinel-ubuntu
# Should boot to an XFCE desktop, auto-logged-in as 'fleet'.
# Confirm /opt/fleet-sentinel/enroll.sh exists.
# Confirm /var/log/fleet-sentinel/ exists.
# Shut it down: sudo shutdown -h now (or close the window).
```

## Phase 2 — Push to ghcr.io

```bash
./push-image.sh
```

This pushes two tags:

- `ghcr.io/ds0x/fleet-sentinel-ubuntu:latest`
- `ghcr.io/ds0x/fleet-sentinel-ubuntu:YYYY.MM.DD`

Override the version tag if you want semver:

```bash
VERSION=v0.1.0 ./push-image.sh
```

After the first push, make the package public in the GitHub UI:
**github.com/ds0x?tab=packages → fleet-sentinel-ubuntu → Package
settings → Change visibility → Public.** This is a one-time step per
package; subsequent pushes keep the visibility you set.

## Phase 3 — Cut a release of the wrapper

The wrapper script (`bin/fleet-sentinel`) is what Homebrew distributes.

1. Tag the wrapper repo:
   ```bash
   cd /path/to/fleet-sentinel
   git tag v0.1.0 && git push --tags
   ```
2. Get the tarball checksum:
   ```bash
   curl -sL https://github.com/ds0x/fleet-sentinel/archive/refs/tags/v0.1.0.tar.gz \
     | shasum -a 256
   ```
3. Edit the tap repo's `Formula/fleet-sentinel.rb`:
   - `version "0.1.0"`
   - `url ".../v0.1.0.tar.gz"`
   - `sha256 "<the digest you just computed>"`
4. Commit + push the tap repo.

End users now get the new wrapper with `brew upgrade fleet-sentinel`. The
golden image is decoupled — bumping `:latest` on ghcr.io doesn't require
a wrapper release.

## Phase 4 — Test the end-to-end flow

From a clean Mac that has only Homebrew:

```bash
brew tap ds0x/tap
brew install ds0x/tap/fleet-sentinel
fleet-sentinel https://fleet.example.com  YOUR_TEST_SECRET
```

You should see:
- "Cloning ghcr.io/..." (image pull on first call)
- "Building fleetd ARM64 .deb via fleetctl"
- "Starting 'fleet-sentinel' headless"
- "VM IP: 192.168.64.X"
- "Enrolling into Fleet at ..."
- "Switching to a graphical session"
- A Tart window opens with the XFCE desktop.
- Your Fleet UI shows a new host within ~30 seconds.

## CI build (future improvement)

Tart-on-CI requires Apple Silicon runners. Two options:

- **Cirrus CI** (free Apple Silicon macOS runners for open-source).
  Cirrus Labs maintains Tart; their docs at
  `https://tart.run/integrations/cirrus-ci/` cover this.
- **GitHub Actions** on a self-hosted Apple Silicon runner.

The build script is fully non-interactive (it pulls a Tart-native base
image from cirruslabs and customizes via SSH — no installer to walk),
so dropping it into a Cirrus CI or GitHub Actions workflow on an
Apple Silicon runner is straightforward. Stub workflow ideas:

- Trigger on tag push (`v*.*.*`).
- Set up `GITHUB_TOKEN` with `write:packages` via OIDC or repo secret.
- Run `./golden/build-golden.sh && VERSION=$TAG ./golden/push-image.sh`.

Tracking this as a follow-up rather than a blocker — manual rebuilds
are ~5 min, fast enough to not be in the way.

## When to bump what

| Change                                  | Bump                                |
|-----------------------------------------|-------------------------------------|
| Wrapper bug fix, no behavior change     | wrapper patch version (0.1.0 → 0.1.1) |
| Wrapper takes new env var or flag       | wrapper minor (0.1.0 → 0.2.0)         |
| Image: security upgrade, no behavior chg| image date tag only (no wrapper release) |
| Image: new packages or layout change    | image date tag + wrapper minor      |
| Breaking change in image-wrapper contract | wrapper major (0.x → 1.0)         |
