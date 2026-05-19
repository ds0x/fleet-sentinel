# homebrew-tap

Homebrew tap for `fleet-sentinel`.

## How this is laid out

Homebrew expects taps to live in a GitHub repo named **`homebrew-<name>`**
under your account, with formulae under `Formula/`. To make
`brew install ds0x/tap/fleet-sentinel` work, this directory's contents
must be published as:

    https://github.com/ds0x/homebrew-tap

That is, the Git repo's name is literally `homebrew-tap`, and the tap is
referenced as `ds0x/tap` (Homebrew strips the `homebrew-` prefix).

## Publishing a new version

1. Tag a release in the main `fleet-sentinel` repo:
   ```bash
   git tag v0.1.0 && git push --tags
   ```
2. Download the auto-generated tarball and grab its sha256:
   ```bash
   curl -sL https://github.com/ds0x/fleet-sentinel/archive/refs/tags/v0.1.0.tar.gz \
     | shasum -a 256
   ```
3. In this tap repo, edit `Formula/fleet-sentinel.rb`:
   - update `version`
   - update `url` (the tag in the URL)
   - update `sha256`
4. Commit, push.
5. End users get the new version with `brew upgrade fleet-sentinel`.

## What gets installed

The formula installs the single script `bin/fleet-sentinel` from the
release tarball into Homebrew's bin path, plus three runtime deps:

- `cirruslabs/cli/tart`
- `fleetdm/fleet/fleetctl`
- `hudochenkov/sshpass/sshpass`

If any of those taps haven't been added on the user's machine, Homebrew
adds them as part of resolving the dependency.

## Local testing without publishing

```bash
# From inside this directory:
brew install --build-from-source ./Formula/fleet-sentinel.rb
fleet-sentinel --version
brew uninstall fleet-sentinel
```
