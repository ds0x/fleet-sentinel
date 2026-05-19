# Getting started — from these files to a live test

This walkthrough takes you from "the files exist on my Mac" to
"`brew install ds0x/tap/fleet-sentinel && fleet-sentinel <url> <secret>`
spawns a Fleet-enrolled VM." Approx 30–60 minutes wall-clock, most of it
spent in the Debian installer in Phase 4.

Throughout, replace **`ds0x`** with your actual GitHub username if
different. (If `ds0x` IS your username, the commands work as-is.)

You'll create **two GitHub repos**:

- `github.com/ds0x/fleet-sentinel`  → wrapper + build scripts + docs
- `github.com/ds0x/homebrew-tap`    → just the Homebrew formula

This split is required: Homebrew taps must live in a repo literally
named `homebrew-<something>`.

---

## Phase 0 — One-time prerequisites (~10 min)

```bash
# Required tools
brew install gh                                  # GitHub CLI (simplest path)
brew install git                                 # if not already
brew install cirruslabs/cli/tart                 # Tart (Apple Silicon VMs)
brew install fleetctl                            # Fleet's CLI
brew install hudochenkov/sshpass/sshpass         # SSH-with-password helper
brew install qemu                                # for ISO downloads' qemu-img
brew install curl wget                           # usually present
```

Authenticate `gh` against GitHub (handles git auth too, opens a browser):

```bash
gh auth login
# Choose: GitHub.com → HTTPS → Yes, authenticate Git → Login with a web browser
```

You'll also need a **GitHub Personal Access Token** with `write:packages`
scope for pushing the OCI image to ghcr.io. `gh auth`'s token doesn't
include that scope by default. Generate one at
**https://github.com/settings/tokens** (classic tokens, easier here):

- Scopes: `write:packages`, `read:packages`, `delete:packages` (optional)
- Save the token somewhere; you'll export it as `GITHUB_TOKEN` in Phase 5.

A Fleet server to enroll against. Grab the enroll secret now:

```bash
fleetctl get enroll_secret
# or via Fleet UI: Settings → Teams → [team] → Manage enroll secret
```

---

## Phase 1 — Copy the files into a working git directory (~2 min)

The current files live in your Cowork session's outputs folder. Copy
them somewhere persistent that you'll use as the git working tree:

```bash
mkdir -p ~/code
cp -R "$HOME/Library/Application Support/Claude/local-agent-mode-sessions/"*/local_*/outputs/fleet-sentinel ~/code/fleet-sentinel
cd ~/code/fleet-sentinel
ls -la
# You should see: README.md  BUILDER.md  GETTING-STARTED.md  bin/  golden/  homebrew-tap/  resource-sizing.md
```

Make the shell scripts executable (in case the copy didn't preserve it):

```bash
chmod +x bin/fleet-sentinel golden/*.sh
```

Add a tiny LICENSE file (the Homebrew formula declares MIT):

```bash
cat > LICENSE <<'EOF'
MIT License

Copyright (c) 2026 Dave Siederer

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
EOF
```

---

## Phase 2 — Create + push the main repo (~3 min)

```bash
cd ~/code/fleet-sentinel
git init
git add .
git commit -m "Initial commit: fleet-sentinel v0.1.0"
git branch -M main

# Create the repo on GitHub and push in one shot:
gh repo create ds0x/fleet-sentinel \
  --public \
  --source=. \
  --remote=origin \
  --description "Fleet-enrolled, GUI-ready Debian VM on Apple Silicon, in one command" \
  --push
```

> **Manual path (if you'd rather not use `gh`):**
> 1. Visit https://github.com/new — name: `fleet-sentinel`, public, no README/license/gitignore.
> 2. `git remote add origin git@github.com:ds0x/fleet-sentinel.git`
> 3. `git push -u origin main`

Tag a release. This is what the Homebrew formula will pull:

```bash
git tag v0.1.0
git push --tags
```

GitHub now exposes an auto-generated source tarball at:

```
https://github.com/ds0x/fleet-sentinel/archive/refs/tags/v0.1.0.tar.gz
```

Compute its sha256 — you'll need it in Phase 3:

```bash
TARBALL_SHA=$(curl -sL https://github.com/ds0x/fleet-sentinel/archive/refs/tags/v0.1.0.tar.gz \
  | shasum -a 256 | awk '{print $1}')
echo "Tarball sha256: $TARBALL_SHA"
```

---

## Phase 3 — Create + push the Homebrew tap repo (~3 min)

The tap is a **separate repo** that contains just the formula.

```bash
mkdir -p ~/code/homebrew-tap
cp -R ~/code/fleet-sentinel/homebrew-tap/* ~/code/homebrew-tap/
cd ~/code/homebrew-tap

# Plug in the tarball sha256 you computed above:
sed -i.bak "s/REPLACE_WITH_SHA256_OF_TARBALL/$TARBALL_SHA/" Formula/fleet-sentinel.rb
rm Formula/fleet-sentinel.rb.bak

# Sanity-check the formula:
grep -E '^\s*(version|url|sha256)\s' Formula/fleet-sentinel.rb
# version "0.1.0"
# url     "https://github.com/ds0x/fleet-sentinel/archive/refs/tags/v0.1.0.tar.gz"
# sha256  "abcdef…"
```

Push it:

```bash
git init
git add .
git commit -m "Initial tap with fleet-sentinel v0.1.0"
git branch -M main

gh repo create ds0x/homebrew-tap \
  --public \
  --source=. \
  --remote=origin \
  --description "Homebrew tap for fleet-sentinel" \
  --push
```

> Same manual fallback applies if you skip `gh`.
> **Critical:** the repo name on GitHub MUST be literally `homebrew-tap`
> (with the `homebrew-` prefix). Homebrew strips the prefix when you
> `brew tap ds0x/tap`.

---

## Phase 4 — Build the golden Tart image (~25 min, mostly waiting)

```bash
cd ~/code/fleet-sentinel/golden
./build-golden.sh
```

The script will:

1. Download the Debian 12 ARM64 netinst ISO (~600 MB, one-time).
2. Create an empty Tart Linux VM called `fleet-sentinel-debian`.
3. Boot the installer in a Tart window and pause for you to walk it.

Inside the installer, follow these EXACT choices (the script also prints them):

| Field | Value |
|---|---|
| Mode | Graphical install |
| Hostname | `fleet-sentinel-debian` |
| Domain | (blank) |
| Root password | (blank — locks root) |
| Username | `fleet` |
| Password | `fleet` |
| Partitioning | Guided → entire disk → single partition → write |
| Software | **only** `SSH server` + `standard system utilities` |
| GRUB | `/dev/vda` |

When the installed system boots and shows you a `login:` prompt, the
script automatically reconnects over SSH, scp's `setup-debian.sh`, runs
it, and shuts the VM down. ~5–8 min for that automated stage.

When `build-golden.sh` exits cleanly, you have a stopped Tart VM ready
to publish. Optional sanity check:

```bash
tart run fleet-sentinel-debian
# Should boot to an XFCE desktop, auto-logged-in as 'fleet'.
# Close the window when satisfied; that hibernates the VM.
tart stop fleet-sentinel-debian
```

---

## Phase 5 — Push the image to ghcr.io (~2 min)

```bash
cd ~/code/fleet-sentinel/golden

export GITHUB_TOKEN='ghp_yourPATfromPhase0'    # the one with write:packages
export GITHUB_USER='ds0x'                      # your actual GitHub username

./push-image.sh
```

This pushes two tags:

- `ghcr.io/ds0x/fleet-sentinel-debian:latest`
- `ghcr.io/ds0x/fleet-sentinel-debian:YYYY.MM.DD`

**One-time: make the package public.** First push creates it private.

1. Visit https://github.com/ds0x?tab=packages
2. Click `fleet-sentinel-debian`
3. Right sidebar → **Package settings** → **Change visibility** → **Public** → type the name to confirm.

After this, anyone with `tart` can `tart clone ghcr.io/ds0x/fleet-sentinel-debian:latest` without auth.

> If you'd rather keep the image private, skip the visibility change.
> End users will need `tart login ghcr.io` with their own PAT before
> running `fleet-sentinel`. The wrapper doesn't currently handle that
> auto-login; let me know if you want it added.

---

## Phase 6 — Test the end-user install path (~3 min)

Simulate what an end user does on a brand-new Mac. If you've been
testing locally, first clear any prior state:

```bash
tart stop fleet-sentinel    2>/dev/null || true
tart delete fleet-sentinel  2>/dev/null || true
brew untap ds0x/tap         2>/dev/null || true
brew uninstall fleet-sentinel 2>/dev/null || true
```

The real test — two commands:

```bash
brew install ds0x/tap/fleet-sentinel
fleet-sentinel https://YOUR-FLEET.example.com YOUR_ENROLL_SECRET
```

Watch for:

- `Cloning ghcr.io/ds0x/fleet-sentinel-debian:latest → fleet-sentinel`
  (this pulls ~1.5 GB on first run; cached afterward)
- `Building fleetd ARM64 .deb via fleetctl`
- `Starting 'fleet-sentinel' headless`
- `VM IP: 192.168.64.X`
- `Enrolling into Fleet at https://...`
- `Switching to a graphical session`
- A Tart window opens with the XFCE desktop. Auto-logs in as `fleet`.

Within ~30 seconds, your Fleet UI should show a new host named
`fleet-sentinel-<6hex>`.

---

## Phase 7 — Iterate

Once Phase 6 works end-to-end:

- **Wrapper changes** (bug in `bin/fleet-sentinel`):
  ```bash
  cd ~/code/fleet-sentinel
  # edit bin/fleet-sentinel
  git commit -am "Fix X"
  git tag v0.1.1 && git push --tags
  # then in the tap repo, bump version + sha256 + url, commit, push
  # end users: brew upgrade fleet-sentinel
  ```
- **Image changes** (something in the VM itself):
  ```bash
  tart delete fleet-sentinel-debian
  cd ~/code/fleet-sentinel/golden
  ./build-golden.sh   # rebuild golden
  ./push-image.sh     # republish — same :latest tag overwrites
  # end users: next fleet-sentinel call auto-pulls the new image
  ```
- **Both at once**: bump wrapper version, rebuild image, push both.

---

## Common gotchas

**"Repository not found" when running `gh repo create`**
You're not logged in to gh. Run `gh auth status` to check.

**`brew install` says formula not found**
The tap repo isn't named `homebrew-tap` on GitHub (with the prefix), or
isn't public. Verify at `https://github.com/ds0x/homebrew-tap`.

**`brew install` succeeds but `fleet-sentinel --version` says "command not found"**
The formula's `install` block isn't finding `bin/fleet-sentinel` in the
release tarball. Make sure the wrapper is at `bin/fleet-sentinel` in the
*tagged* release tarball (not just on `main`).

**`tart push` fails with "unauthorized"**
`GITHUB_TOKEN` doesn't have `write:packages`. Recreate the PAT with the
right scope.

**`fleet-sentinel` runs but VM has no IP**
Tart's Linux networking sometimes takes 60+ s on first boot. The script
waits 2 minutes. If it gives up, run `tart ip fleet-sentinel` manually a
few times until you see an address. If you never get one, check
`/tmp/fleet-sentinel-fleet-sentinel.log` for QEMU errors.

**Host appears in Fleet but immediately goes offline**
The VM rebooted into the GUI session faster than orbit started. Wait
another minute. If it stays offline, SSH in:
`ssh fleet@$(tart ip fleet-sentinel)` and check
`sudo systemctl status orbit`.

**`fleetctl package` complains about arch**
`brew upgrade fleetctl` — ARM64 packaging needs a recent fleetctl.

---

## What success looks like

After Phase 6 runs cleanly:

- `tart list` shows `fleet-sentinel` running.
- A Tart window with an XFCE desktop is on your screen.
- Your Fleet UI has a new host visible (within ~30 s).
- The host's hostname matches `fleet-sentinel-<6hex>`.

Running `fleet-sentinel https://...` again replaces the VM with a fresh
one; the previous host stays in Fleet (you can delete it from the UI).
