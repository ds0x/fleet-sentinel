# fleet-sentinel

A Fleet-enrolled, GUI-ready Debian VM on Apple Silicon, in **one command**.

```bash
brew install ds0x/tap/fleet-sentinel
fleet-sentinel https://fleet.example.com  super-secret-enroll-key
```

Behind the scenes, that single line:

1. Pulls a pre-built ARM64 Debian + XFCE image from `ghcr.io/ds0x/fleet-sentinel-debian:latest`.
2. Stops + deletes any previous `fleet-sentinel` VM (always-fresh lifecycle).
3. Clones the golden image as a new Tart VM.
4. Builds a one-off `fleetd` package for *your* Fleet URL and enroll secret.
5. SSHes in, drops the package and config, runs the enrollment script.
6. Reboots and opens an XFCE desktop window. Within ~30 s the host
   appears in your Fleet UI as a new host.

Tear-down is implicit: just run the command again and the previous VM is
replaced.

## Requirements

- Apple Silicon Mac (M1/M2/M3/M4).
- macOS 13 or later.
- Outbound HTTPS to `ghcr.io` (image pull) and to your Fleet server (enrollment).
- ~1.5 GB free disk for the image, plus 8 GB per running VM.

Homebrew pulls all runtime deps for you (`tart`, `fleetctl`, `sshpass`).
No manual install needed.

## Usage

```bash
fleet-sentinel <fleet_url> <enroll_secret>
fleet-sentinel --help
fleet-sentinel --version
```

### Environment overrides

| Variable                          | Default                                       | Purpose |
|-----------------------------------|-----------------------------------------------|---------|
| `FLEET_SENTINEL_IMAGE`            | `ghcr.io/ds0x/fleet-sentinel-debian:latest`   | Use a different golden image |
| `FLEET_SENTINEL_VM_NAME`          | `fleet-sentinel`                              | Override the Tart VM name |
| `FLEET_SENTINEL_RAM_MB`           | `1024`                                        | RAM allocated to the VM |
| `FLEET_SENTINEL_CPUS`             | `1`                                           | vCPUs allocated to the VM |
| `FLEET_SENTINEL_DISK_GB`          | `8`                                           | Disk size (image must fit) |
| `FLEET_SENTINEL_HEADLESS`         | _(unset)_                                     | Set to `1` to skip the GUI window |
| `FLEET_SENTINEL_HOSTNAME_PREFIX`  | `fleet-sentinel`                              | Used to form the in-VM hostname |

### Examples

Headless:

```bash
FLEET_SENTINEL_HEADLESS=1 fleet-sentinel https://fleet.example.com  ABC123
```

Beefier VM (e.g. to install + run a Chromium-based browser inside):

```bash
FLEET_SENTINEL_RAM_MB=2048 FLEET_SENTINEL_CPUS=2 \
  fleet-sentinel https://fleet.example.com  ABC123
```

Multiple sentinels side-by-side:

```bash
FLEET_SENTINEL_VM_NAME=sentinel-a fleet-sentinel  https://fleet.example.com  ABC123
FLEET_SENTINEL_VM_NAME=sentinel-b fleet-sentinel  https://fleet.example.com  ABC123
```

Each call enrolls as a separate host (random 6-hex hostname suffix per VM).

## Practical capacity on Apple Silicon

The default profile (1 GB RAM / 1 vCPU / 8 GB disk) supports roughly:

- 24 GB Mac → ~12–14 concurrent VMs before swap pressure
- 32 GB Mac → ~20 concurrent VMs
- 64 GB+ Mac → 40+ concurrent VMs

Note: Apple's Virtualization Framework caps `VZVirtualMachine` instances
at **16 per host process**. Since each `tart run` is its own process,
fleet-sentinel sidesteps that limit, but RAM is still the hard ceiling.

## Raw Tart equivalent (no wrapper)

If you don't want to install the wrapper, the manual two-command
equivalent is:

```bash
tart clone ghcr.io/ds0x/fleet-sentinel-debian:latest fleet-sentinel
tart run  fleet-sentinel
# ...then SSH in and place /etc/fleet-sentinel/config.env + the .deb yourself,
# then run /opt/fleet-sentinel/enroll.sh. See BUILDER.md.
```

The wrapper exists because step 3 (config + .deb + enroll.sh) is what
turns a generic clone into a Fleet-enrolled one.

## Repository layout

```
fleet-sentinel/
├── README.md                    ← you are here
├── BUILDER.md                   ← how to rebuild + republish the image
├── resource-sizing.md           ← detailed capacity analysis
├── bin/
│   └── fleet-sentinel           ← the wrapper installed by Homebrew
├── golden/
│   ├── build-golden.sh          ← Mac-side: builds the golden Tart VM
│   ├── push-image.sh            ← Mac-side: pushes it to ghcr.io
│   └── setup-debian.sh          ← runs inside the VM during build
└── homebrew-tap/
    ├── README.md                ← tap repo conventions
    └── Formula/
        └── fleet-sentinel.rb    ← the Homebrew formula
```

## Troubleshooting

**`tart clone` fails with "unauthorized" or "denied"**
The image is public, but if you renamed it to a private registry path,
log in first: `tart login ghcr.io --username YOUR_GITHUB_USER`.

**VM enrolls but Fleet UI doesn't show it**
The default 30 s grace is usually enough. Check from inside the VM:
```bash
ssh fleet@$(tart ip fleet-sentinel)
sudo systemctl status orbit
sudo tail -50 /var/log/fleet-sentinel/enroll.log
```
Most common cause: the URL or secret is wrong, or the VM can't reach
the Fleet URL (corporate proxy / split DNS).

**`fleetctl package` fails with arch error**
Update fleetctl: `brew upgrade fleetctl`. ARM64 packaging needs a
recent release.

**Memory pressure on macOS goes yellow**
Lower `FLEET_SENTINEL_RAM_MB=768` or stop other sentinels:
`tart stop fleet-sentinel`.

## License

MIT.
