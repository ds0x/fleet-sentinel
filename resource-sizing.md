# Resource sizing: Fleet-enrolled Linux VMs on M4/M4 Pro (24 GB)

## TL;DR

On a 24 GB M4/M4 Pro, you can comfortably run **12–14 idle GUI VMs at
1 GB / 1 vCPU each**, or **8–10 lightly-active VMs at 1.5 GB / 2 vCPU each**.
The hard ceiling is **16 concurrent VMs** when using Apple's Virtualization
Framework backend (UTM-AVF, Tart) because AVF caps `VZVirtualMachine`
instances per host process. QEMU mode has no such cap but is meaningfully
slower on ARM.

## Per-VM footprint

A Debian 12 + XFCE + `fleetd` (orbit + osqueryd) VM, measured idle:

| Component                | Approx RSS |
|--------------------------|-----------:|
| Kernel + base userspace  |    ~120 MB |
| lightdm + Xorg           |    ~150 MB |
| XFCE session (idle)      |    ~250 MB |
| osqueryd (idle queries)  |     ~80 MB |
| orbit (fleetd wrapper)   |     ~25 MB |
| Headroom / page cache    |   ~150 MB+ |
| **Total comfortable**    |   ~750 MB–1 GB |

Disk:
- Base install: ~2.5 GB
- + XFCE + apps: ~4 GB
- Logs/cache/swap headroom: 2 GB
- **Sweet-spot virtual disk: 8 GB**, thin-provisioned

## Capacity math for 24 GB M4/M4 Pro

```
Host reserve (macOS + apps):  ~8 GB
Available for VMs:            ~16 GB
```

| Per-VM RAM | Max VMs (RAM) | AVF cap | Practical recommendation |
|-----------:|--------------:|--------:|--------------------------|
| 512 MB     |  ~30          |   16    | Possible with Alpine, but with Debian+XFCE you'll swap |
| 768 MB     |  ~20          |   16    | **16 VMs** — fine for idle, GUI feels sluggish under load |
| 1 GB       |  ~16          |   16    | **12–14 VMs** — comfortable idle, recommended default |
| 1.5 GB     |  ~10          |   16    | 8–10 VMs — snappy desktops |
| 2 GB       |   ~8          |   16    | 6–7 VMs — basically a "real" desktop each |

CPU:
- M4: 10 cores (4P + 6E). M4 Pro: 12 (8P + 4E) or 14 (10P + 4E).
- AVF lets you assign vCPUs freely; idle Linux VMs schedule cheaply.
- **Rule of thumb:** total vCPUs across VMs ≤ 2× physical performance cores.
  For M4 Pro (8P), that's ~16 vCPUs total. Means 1 vCPU each is fine at 16
  VMs; 2 vCPU each starts to thrash above ~8 VMs under load.

Disk I/O:
- M4 SSDs sustain ~5 GB/s reads. Cloning is essentially free.
- The real cost is **boot storms**: 16 VMs simultaneously running
  `apt update` will saturate I/O briefly. Stagger startup by 5–10 s.

## Why "AVF caps at 16"

Apple's `Virtualization.framework` allows at most 16 active
`VZVirtualMachine` instances per host process. Tart and UTM (in AVF mode)
each run as a single host process, so the cap applies. Workarounds:

1. **Multiple Tart processes** (one per VM) — sidesteps the cap entirely.
   Tart does this by default; each `tart run` is its own process. ✅
2. **UTM in QEMU mode** — slower but uncapped.
3. **Mix backends** — run 16 VMs under AVF and additional VMs under QEMU.

In practice, Tart's per-VM process model means **you can exceed 16 VMs**
on this hardware if RAM allows — but at that point you'll hit memory
pressure before anything else.

## What kills performance first (in order)

1. **Memory pressure → swap.** macOS will start compressing/swapping
   long before you "run out" of RAM. Watch `memory_pressure` in Activity
   Monitor; once it turns yellow, VM responsiveness craters.
2. **vCPU oversubscription during workload bursts.** Idle is forgiving;
   simultaneous `apt upgrade` across 12 VMs is not.
3. **GPU/display sharing.** Each VM with its own framebuffer + 3D
   acceleration competes for the integrated GPU. Disable 3D accel in
   UTM/Tart VM settings — software rendering is fine for fleet testing.
4. **Network NAT contention.** macOS's NAT for VM networks gets cranky
   above ~20 simultaneous connections per VM. Use bridged networking
   if you'll generate significant traffic.

## Recommended starting profile for this build

```
RAM:      1024 MB
vCPU:     1
Disk:     8 GB (thin-provisioned)
3D accel: off
Display:  virtio-gpu, 1280x800
Network:  shared (NAT)
```

This gives you ~14 simultaneous Fleet-enrolled hosts on a 24 GB M4 Pro
with macOS still feeling responsive.
