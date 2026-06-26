# ASUS NUC 16 Pro, CachyOS ServerMax Kernel

Bleeding-edge [CachyOS](https://github.com/CachyOS/linux-cachyos) kernel pipeline for the ASUS NUC 16 Pro (Intel Core Ultra 7 356H / Panther Lake), tuned for AC-powered server/homelab workloads.

Tracks `linux-cachyos-server`, CachyOS stable server variant with server-optimized base config.

## Target System

| Field          | Value                                                                          |
| -------------- | ------------------------------------------------------------------------------ |
| Machine        | ASUS NUC 16 Pro                                                                |
| CPU            | Intel Core Ultra 7 356H / Panther Lake (4P+8E+4LP-E, 16C/16T, no HT)         |
| Process        | Intel 18A (CPU die), Intel 3 (GPU die)                                         |
| iGPU           | Intel Xe3 LP (`xe` driver, device 0xB0A0, 4 Xe3-cores, 2.45 GHz)             |
| NPU            | Intel NPU 50 TOPS (`intel_vpu` / IVPU driver, 5th Gen, vpu_50xx firmware)     |
| Ethernet       | Dual Intel I226-V 2.5GbE (`igc` driver)                                       |
| WiFi           | Intel Wi-Fi 7 BE211 (`iwlwifi` + `iwlmvm`, 320 MHz, MLO, BT 6.0)             |
| Storage        | PCIe Gen5 x4 + PCIe Gen4 x4 NVMe                                              |
| Memory         | DDR5-6400 CSO-DIMM (up to 128 GB)                                             |
| Connectivity   | Thunderbolt 4 / USB4 x2, USB 3.2 Gen 2x2 (20 Gbps)                           |
| Architecture   | x86-64-v3                                                                      |
| Target OS      | Ubuntu 26.04 LTS (amd64)                                                       |
| Kernel base    | [linux-cachyos-server](https://github.com/CachyOS/linux-cachyos)              |
| Package format | Debian/Ubuntu `.deb`                                                           |
| AC adapter     | 120W (19VDC, 6.32A)                                                            |

## Kernel Profile

| Setting                | Value                                                                        |
| ---------------------- | ---------------------------------------------------------------------------- |
| Base scheduler         | EEVDF (servermax profile)                                                    |
| sched_ext              | Compiled in, `scx_flash` auto-starts before the docker fleet (unit ordered `After=basic.target Before=docker.service`, bounded retry on boot-storm ENOMEM; verifies attach, falls back to `scx_bpfland`) |
| Compiler               | LLVM / Clang + LLD                                                           |
| LTO                    | ThinLTO                                                                      |
| CPU target             | x86-64-v3 (AVX2, BMI2, FMA, LZCNT)                                          |
| Timer frequency        | 100 Hz                                                                       |
| Preemption             | Lazy (throughput lean; RT-class IRQs preempt immediately)                                                        |
| Transparent Huge Pages | always                                                                       |
| TCP congestion         | BBR (mainline)                                                               |
| I/O scheduler          | ADIOS (SSDs/NVMe), BFQ (HDDs) via udev + `modules-load.d` (adios is `=m`)                                       |
| Zswap                  | Enabled (zstd compressor, zsmalloc pool, 20%)                                             |
| Async I/O              | io_uring enabled                                                             |
| Network offload        | TLS kernel offload, XDP sockets                                              |
| Block layer            | BLK_WBT writeback throttling, NVMe multipath                                 |
| NVMe power states      | Disabled (`nvme_core.default_ps_max_latency_us=0`, Gen4/Gen5 max perf)       |
| Network                | 2x 2.5GbE bonded (balance-xor, static LAG; §5); WiFi 7 failover; `rp_filter=2` loose                     |
| GPU driver             | `xe` (Intel Xe3 LP Panther Lake, GuC auto-enabled); `i915` kept as fallback  |
| IRQ affinity           | `threadirqs`: spread IRQs across P/E/LP-E cores                              |
| Cgroup v2              | Full stack (CFS_BANDWIDTH, all controllers)                                  |
| CRIU                   | CHECKPOINT_RESTORE enabled                                                   |
| PCIe                   | ASPM performance mode + PTM                                                  |
| RCU lazy               | Disabled (AC-only, no power-saving bias)                                     |
| BTF                    | Enabled (`/sys/kernel/btf/vmlinux` for scx tools)                           |
| Debug info             | DWARF (toolchain default), required for BTF                                  |
| CPU power limits       | BIOS-owned PL1/PL2/Tau; silicon caps at 80W MTP                              |
| Fan control            | BIOS/firmware owns curves; OS does not set them                              |
| USB autosuspend        | Disabled (`usbcore.autosuspend=-1`): full power all ports                    |
| WiFi power save        | Disabled (`iwlwifi power_save=0`, `iwlmvm power_scheme=1`)                   |
| energy_perf_bias       | 0 (no microarchitecture power-saving bias on any core)                       |
| NVMe queue depth       | `nr_requests=1023` per namespace at boot                                     |
| igc ring buffers       | rx=4096 tx=4096 on both I226-V 2.5GbE ports                              |
| Thermal trip           | Passive trip at TjMax (100°C) - no software throttle before hardware PROCHOT |

## SCX Scheduler Notes (Panther Lake)

Panther Lake has 4P + 8E + 4LP-E = 16C/16T with Intel Thread Director + HFI, heterogeneous topology.

- **Primary**: `scx_flash` (EDF scheduler with dynamic per-task latency weights; prioritizes latency-sensitive tasks that yield early, deprioritizes batch tasks that burn their full slice - well matched to Plex transcode running alongside interactive streaming + high-speed networking)
- **Fallback chain**: `scx_bpfland -s 20000 -S` -> `scx_p2dq` -> `scx_bpfland` (no args) -> `scx_rusty` -> `scx_beerland` -> `scx_lavd`

The start script **verifies each scheduler actually attaches** to sched_ext (`/sys/kernel/sched_ext/root/ops`) before committing to it. A primary that dies or never attaches degrades to the next candidate, never to "no scheduler". So if `scx_flash` is absent or fails to attach, the box lands on the proven `scx_bpfland`.

**Boot ordering:** the unit is `After=basic.target` + `Before=docker.service`, so `scx_flash` attaches while the system is quiet, before the ~20 `docker-<app>.service` units launch. sched_ext runs `ops.cgroup_init()` once per existing cgroup at attach time, so attaching mid-storm tried to initialize ~175 cgroups in one batch under boot slab pressure and transiently failed `-ENOMEM` (demoting to the fallback). Attaching first means a handful of cgroups, then each container's cgroup is initialized incrementally as it starts. A bounded retry (`try_primary`) covers the residual early-boot slab-pressure case.

`scx_lavd` is topology-aware for P/E/LP-E but has a documented E-core over-prioritization issue (observed on the sibling Lunar Lake architecture). It remains as a late fallback until upstream resolves it.

`scx_loader` is preferred when available; it handles kernel upgrades without a service restart.

## Pipeline

Two independent build paths produce identical `.deb` packages. The Oracle A1 workflow runs 12 hours after GHA as a fallback. If GHA already built successfully, Oracle's pre-flight check finds the release and skips.

```text
GHA ubuntu-latest (native x86-64, daily 09:00 UTC)
  -> make ARCH=x86_64 LLVM=1 LLVM_IAS=1 CC="ccache clang"
  -> KCFLAGS="-march=x86-64-v3" KBUILD_DEBARCH=amd64
  -> .deb (amd64)

Oracle A1 self-hosted (ARM64, daily 21:00 UTC, 12 h after GHA)
  -> make ARCH=x86_64 LLVM=1 LLVM_IAS=1 CC="ccache clang"
     (clang is a cross-compiler; no CROSS_COMPILE= needed with LLVM=1)
  -> KCFLAGS="-march=x86-64-v3" KBUILD_DEBARCH=amd64
  -> .deb (amd64)
```

Both workflows run a pre-flight check that compares upstream `pkgver` against recent releases. If the version already exists, the build is skipped entirely; only checkout and pre-flight run.

### Caching

**GHA workflow** (`build-cachyos-server.yml`):
- **Docker Buildx**: builder image layers cached in GHA cache (`type=gha`); warm builds skip the ~5-minute package install
- **ccache**: 8 GB, persisted via `actions/cache`, keyed on kernel version (`ccache-Linux-x86_64v3-{kver}`); incremental rebuilds skip unchanged translation units

**Oracle A1 workflow** (`build-cachyos-server-oracle.yml`):
- **Docker**: plain `docker build --pull`; the persistent self-hosted runner keeps Docker's own layer cache between runs, no GHA cache used
- **ccache**: 8 GB, persisted via `actions/cache`, keyed separately (`ccache-Linux-aarch64-cross-x86_64v3-{kver}`); separate from the GHA cache bucket

### Build environment

| | GHA `ubuntu-latest` | Oracle A1 self-hosted |
|---|---|---|
| Architecture | x86-64 (native) | ARM64 -> x86-64 (cross) |
| Disk free | `slimhub_actions` (~40-60 GB freed) | Persistent runner, manual cleanup |
| Swap | 32 GB on `/mnt` | 16 GB on `/mnt` |
| Docker cache | Buildx GHA cache | Local layer cache (persistent) |
| Timeout | 360 min | 480 min |

The BTF+ThinLTO peak can spike past available RAM during linking; swap prevents OOM-kill. Oracle A1 uses 16 GB because cross-compile peak is lower than native ThinLTO on x86.

### Boot test

After building, each workflow checks the kernel. On failure the build stops and no release is created.

- **GHA**: boots the kernel in `qemu-system-x86_64` with KVM. A minimal busybox initramfs runs as init, prints `BOOT_TEST_SUCCESS`, and poweroffs. The workflow runs `sudo chmod 666 /dev/kvm` before the test because GHA runners have `/dev/kvm` owned by `root:kvm` (660) and the runner user is not in the kvm group.
- **Oracle A1**: no boot test. QEMU TCG emulation of x86-64 on ARM64 takes 20-30 minutes per boot, too slow for CI. Instead, the .deb contents are validated (vmlinuz present, modules tree present, arch=amd64). GHA validates boot correctness before Oracle runs.

### Release assets

- `linux-image-*.deb`: kernel image and modules
- `linux-headers-*.deb`: headers for DKMS / out-of-tree modules
- `linux-libc-dev_*.deb`: userspace kernel headers
- `SHA256SUMS`: SHA-256 checksums for all packages
- `BUILD_MANIFEST`: compiler version, CachyOS commit, build timestamp, full config metadata

Release tag format: `v{KERNEL}-cachyos-servermax-x86_64v3-{YYYYMMDD}.{RUN}`

Example: `v7.1.rc2-cachyos-servermax-x86_64v3-20260610.3`

RC kernels are published as pre-releases.

## Quick Install (NUC 16 Pro machine)

Run as root on the NUC. Downloads, installs, and enables the auto-updater in one shot:

```bash
sudo bash -c '
  BASE=https://raw.githubusercontent.com/AmirulAndalib/asus-nuc16pro-cachyos-server-edge-kernel/refs/heads/master
  wget -qO /usr/local/sbin/nuc16pro-kernel-updater.sh         "$BASE/scripts/nuc16pro-kernel-updater.sh"
  wget -qO /etc/systemd/system/nuc16pro-kernel-updater.service "$BASE/systemd/nuc16pro-kernel-updater.service"
  wget -qO /etc/systemd/system/nuc16pro-kernel-updater.timer   "$BASE/systemd/nuc16pro-kernel-updater.timer"
  chmod 700 /usr/local/sbin/nuc16pro-kernel-updater.sh
  systemctl daemon-reload
  systemctl enable --now nuc16pro-kernel-updater.timer
  echo "Done. Timer status: $(systemctl is-active nuc16pro-kernel-updater.timer)"
'
```

Or with `curl` if `wget` is unavailable:

```bash
sudo bash -c '
  BASE=https://raw.githubusercontent.com/AmirulAndalib/asus-nuc16pro-cachyos-server-edge-kernel/refs/heads/master
  curl -fsSLo /usr/local/sbin/nuc16pro-kernel-updater.sh         "$BASE/scripts/nuc16pro-kernel-updater.sh"
  curl -fsSLo /etc/systemd/system/nuc16pro-kernel-updater.service "$BASE/systemd/nuc16pro-kernel-updater.service"
  curl -fsSLo /etc/systemd/system/nuc16pro-kernel-updater.timer   "$BASE/systemd/nuc16pro-kernel-updater.timer"
  chmod 700 /usr/local/sbin/nuc16pro-kernel-updater.sh
  systemctl daemon-reload
  systemctl enable --now nuc16pro-kernel-updater.timer
  echo "Done. Timer status: $(systemctl is-active nuc16pro-kernel-updater.timer)"
'
```

After setup, trigger a manual run immediately:

```bash
sudo /usr/local/sbin/nuc16pro-kernel-updater.sh
```

See [What the installer does automatically](#3-what-the-installer-does-automatically) for the full list of changes applied on each run.

---

## Setup

`scripts/nuc16pro-kernel-updater.sh` is generated, not hand-edited. The config/unit bodies it deploys live as separate tracked files (`modprobe.d/`, `sysctl.d/`, `udev/`, `systemd/`) and get spliced into `scripts/nuc16pro-kernel-updater.sh.in` by `scripts/assemble-kernel-updater.sh`. To change a config, edit the source file or the `.in` template, re-run the assembler, and commit the regenerated script. `check-kernel-updater-sync.yml` fails CI if the committed script drifts from its sources.

### 1. Clone and set OWNER_REPO

```bash
git clone https://github.com/AmirulAndalib/asus-nuc16pro-cachyos-server-edge-kernel.git
```

Set your repo in two places:

**`scripts/nuc16pro-kernel-updater.sh`** line 4:

```bash
OWNER_REPO="${OWNER_REPO:-AmirulAndalib/asus-nuc16pro-cachyos-server-edge-kernel}"
```

**`systemd/nuc16pro-kernel-updater.service`** Environment line:

```ini
Environment=OWNER_REPO=AmirulAndalib/asus-nuc16pro-cachyos-server-edge-kernel
```

### 2. Install the auto-updater on the NUC

Run as root:

```bash
cp scripts/nuc16pro-kernel-updater.sh /usr/local/sbin/nuc16pro-kernel-updater.sh
chmod 700 /usr/local/sbin/nuc16pro-kernel-updater.sh

cp systemd/nuc16pro-kernel-updater.service /etc/systemd/system/
cp systemd/nuc16pro-kernel-updater.timer   /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now nuc16pro-kernel-updater.timer
```

Timer fires daily at 04:00 local time. The installer is idempotent: records the installed tag in `/var/lib/nuc16pro-kernel-updater/last-installed-tag` and skips reinstall if already on that release.

### 3. What the installer does automatically

On first run and each new release, the installer handles everything without manual steps:

- Downloads and verifies `.deb` packages (SHA-256)
- Installs kernel packages via `dpkg`
- Installs `linux-image-generic` as fallback
- Writes `/etc/modprobe.d/xe-nuc16pro.conf` (comment-only; `xe` driver needs no options for Panther Lake iGPU)
- Writes `/etc/modprobe.d/nuc16pro-wifi.conf` (`iwlwifi power_save=0`, `iwlmvm power_scheme=1`)
- Writes `/etc/sysctl.d/99-nuc16pro-servermax.conf` (BBR+FQ, large buffers, inotify, vm tuning, `rp_filter=2` for dual NIC)
- Writes `/etc/udev/rules.d/60-nuc16pro-ioschedulers.rules` (ADIOS for SSDs/NVMe, BFQ for HDDs) plus `/etc/modules-load.d/nuc16pro-adios.conf` - adios is built `=m` and lacks the `<name>-iosched` autoload alias bfq has, so without force-loading it the udev rule silently no-ops and SSD/NVMe fall back to mq-deadline/none
- Installs and enables `/etc/systemd/system/nuc16pro-servermax-cpupower.service` (EPP=performance, HWP dynamic boost, and platform_profile=performance on all P/E/LP-E cores; masks `power-profiles-daemon` so it stays the single owner)
- Installs and enables `/etc/systemd/system/nuc16pro-servermax-power.service` (BIOS owns PL1/PL2/Tau and the platform profile; the OS sets only energy_perf_bias=0, NVMe nr_requests=1023, igc ring buffers on every I226-V port, and the TjMax 100°C thermal trip, all within the BIOS power envelope)
- Writes `/etc/systemd/system/plymouth-quit-wait.service.d/10-headless-noop.conf` - this headless box has no graphical handoff, so the stock `plymouth --wait` blocks `multi-user.target` forever (infinite timeout) and starves every `After=multi-user.target` unit including the tuning oneshots; the drop-in replaces it with a no-op so the target completes and tuning applies on boot
- Downloads `scx_flash`, `scx_bpfland`, `scx_p2dq`, `scx_rusty`, `scx_beerland`, `scx_lavd` from this repo's own `scx-*` GitHub release (built by `build-scx-schedulers.yml`), verifies against `SHA256SUMS`, installs to `/usr/local/bin`
- Enables `scx_loader` with `scx_flash` in Server mode (or direct service as fallback)
- Updates GRUB cmdline: `threadirqs usbcore.autosuspend=-1 nvme_core.default_ps_max_latency_us=0 zswap.enabled=1 zswap.shrinker_enabled=1 zswap.compressor=zstd zswap.max_pool_percent=20 mitigations=auto intel_pstate=active preempt=lazy` (`zswap.zpool=z3fold` dropped: z3fold was removed upstream, zswap falls back to the zsmalloc default)
- Removes stale `i915.enable_guc=3` if present from previous config
- Purges all previous custom `cachyos-nuc16pro` kernels, keeping only the newest installed + the currently running kernel (panic fallback)
- Adds `lz4` and `asus_wmi` to initramfs modules
- Runs `update-initramfs` + `update-grub`
- Sets the new kernel as GRUB default (hidden menu, Shift to show)
- Reboots

### 4. sched_ext schedulers

The kernel has `CONFIG_SCHED_CLASS_EXT=y` and `CONFIG_DEBUG_INFO_BTF=y`. After install, `scx_flash` runs automatically (the start script falls back to `scx_bpfland` if it is absent or fails to attach).

To switch schedulers manually:

```bash
# Stop current scheduler
systemctl stop nuc16pro-scx-server.service  # or scx_loader

# Run a different scheduler
sudo scx_flash                       # flash (primary, EDF latency-weighted)
sudo scx_bpfland -s 20000 -S         # bpfland server (fallback)
sudo scx_p2dq --keep-running         # p2dq server
sudo scx_rusty                       # rusty (general)
sudo scx_lavd                        # lavd (P/E/LP-E topology-aware, use with caution)

# Or switch via scx_loader
scxctl start --scheduler scx_flash --mode Server
```

### 5. Network: dual 2.5GbE bond + WiFi failover

The box has two Intel I226-V 2.5GbE ports plus WiFi 7. The two wired ports are bonded for aggregate LAN throughput and link redundancy; WiFi stays a separate failover path.

**This box uses `balance-xor` (static LAG).** The upstream switch is a Grandstream GWN7721 (Lite-managed), which supports **static** link aggregation only - no LACP / 802.3ad. So the bond runs `mode: balance-xor` to match a static trunk: both ports active, TX spread across them by the hash policy. The bond mode must match the switch LAG type (static <-> `balance-xor`, LACP <-> `802.3ad`) or the link flaps. If your switch *does* support 802.3ad, use `mode: 802.3ad` + `lacp-rate: fast` instead (cleaner, switch-negotiated, detects miswiring).

**Reality check:** a single TCP stream still caps at one link's 2.5 Gbps - the bond aggregates *across multiple concurrent flows*, it does not speed up one transfer. Internet traffic is capped by the WAN uplink, so the bond mainly helps LAN-internal many-flow workloads. WiFi cannot be bonded with Ethernet for throughput; its role is failover.

**Hash policy - keep `layer3+4`.** The transmit hash is a *local* decision on the NUC (which slave each outgoing flow uses); the switch does not parse or need to "understand" it. `layer3+4` (src/dst IP + L4 port) spreads flows best - including internet-bound traffic, which all shares the router's MAC and would pile onto **one** link under `layer2`. So `layer2` is the *wrong* move here despite common advice; `layer3+4` is correct for an internet-facing server. (RX distribution, switch -> NUC, is the switch's own hash, not tunable on a basic switch; the NUC accepts frames on both ports regardless.)

**Prerequisite (switch side):** create a **static LAG / trunk** on the two ports the NICs connect to (Grandstream GWN7721: *Link Aggregation* -> add both ports). The Linux bond mode must match: static trunk -> `balance-xor`; LACP/dynamic -> `802.3ad`.

`netplan/99-nuc16pro-bond.yaml` is the canonical config (`balance-xor`, `layer3+4`, bond MAC cloned from the primary NIC so the DHCP lease / IP and router port-forwards are preserved). `scripts/nuc16pro-bond-apply.sh` applies it **safely**: it arms a PID1-owned auto-revert that survives the SSH drop during cutover and keeps the bond only if the box can still reach its gateway, so a wrong switch LAG just rolls back.

Run it from the **physical console** (the cutover briefly drops SSH as the IP moves to `bond0`):

```bash
sudo bash scripts/nuc16pro-bond-apply.sh
```

Verify it is aggregating:

```bash
cat /proc/net/bonding/bond0                       # Bonding Mode: load balancing (xor); both slaves MII up, Link Failure Count 0
cat /sys/class/net/enp86s0/statistics/tx_packets  # both counters climb under multi-flow load
cat /sys/class/net/enp87s0/statistics/tx_packets
```

For an `802.3ad` LAG instead, "working" is `Partner Mac` = the switch's real MAC, both slaves on the same `Aggregator ID`, `Number of ports: 2`. A `Partner Mac` of all-zeros means the switch is not running LACP on those ports (confirm with `tcpdump -i <slave> -nne ether proto 0x8809`: only the NUC's own NIC MACs appear) - use `balance-xor` + a static LAG, as here.

This is a deliberate one-time manual step, **not** part of the daily updater - auto-applying a bond unattended could leave the box unreachable on reboot if the switch side changes. Once applied the config lives in `/etc/netplan` and persists across reboots (NM connections `autoconnect=yes`, MAC cloned so the IP holds). The `netplan apply` "systemd-networkd ... Falling back to a hard restart" line is benign on this NetworkManager-rendered box.

`net.ipv4.conf.all.rp_filter = 2` (loose) stays set so the WiFi failover path and the wired path can both receive traffic without the kernel dropping asymmetrically-routed packets.

### 6. Power Limits and Fan Control

The NUC 16 Pro runs on a 120W AC adapter (19VDC, 6.32A) and has dual fans. **Power limits (PL1/PL2/Tau) and the fan curves are owned by the BIOS, not the OS.** This box runs custom BIOS power limits and fan curves, so `nuc16pro-servermax-power.service` deliberately does **not** write RAPL or `platform_profile`; BIOS/firmware keeps full ownership of power and fan/thermal policy. The fans follow the BIOS/EC curve under any booted OS, so if a fan does not ramp the way you expect, fix the curve in BIOS; that is where fan behavior is set, not in the kernel.

There is also nothing for the OS to unlock: the Core Ultra 7 356H is hard-capped at its **80W Maximum Turbo Power** (Intel spec), confirmed on-device (the package stays at ~80W under stress even with RAPL raised to 104W). An OS RAPL write above 80W is inert; below it would only throttle. So the service tunes only devices that sit **within** the BIOS power envelope and never touch PL/Tau or fan curves:

- `energy_perf_bias=0` (HWP bias toward performance; a hint, not a power limit)
- NVMe `nr_requests=1023` per namespace (Gen4/Gen5 queue depth)
- igc (I226-V) ring buffers rx/tx=4096
- x86 package passive thermal trip raised to TjMax (100°C) so the kernel does not software-throttle before hardware PROCHOT. This is a CPU-throttle threshold, not a fan curve, and does not touch BIOS/EC fan control.

Frequency scaling stays aggressive via `nuc16pro-servermax-cpupower.service`, which sets EPP=performance on every core, enables HWP dynamic boost (faster ramp on task wakeup, lower latency), and asserts `platform_profile=performance` (the firmware DPTF power slider; cold-boot default is `balanced`). intel_pstate runs in active mode and the powersave governor is kept on purpose: on this power-limited package it lets idle cores drop frequency and release budget so loaded cores turbo higher (pinning the performance governor would hold idle cores at max and steal that budget). `power-profiles-daemon` is masked so this stays the single, deterministic owner of these knobs.

**ACPI platform_profile** is a firmware thermal/turbo knob (backed by the DPTF "SoC Power Slider"). The cpupower service asserts `performance` here, since the cold-boot firmware default is `balanced` and `power-profiles-daemon` (which used to drive it) is masked. Fan RPM is not surfaced through standard hwmon on this board, so the temperature sensors (per-core coretemp, `x86_pkg_temp`, NVMe, WiFi) are the actionable thermal signal while the BIOS/EC governs the fan response.

To check power and thermal state (the RAPL reads show the BIOS-set limits):

```bash
cat /sys/firmware/acpi/platform_profile                                       # current profile (BIOS default)
cat /sys/class/powercap/intel-rapl/intel-rapl:0/constraint_0_power_limit_uw   # BIOS-set PL1
cat /sys/class/powercap/intel-rapl/intel-rapl:0/constraint_1_power_limit_uw   # BIOS-set PL2
sensors  # requires lm-sensors
```

To check or switch the platform profile (cpupower.service sets `performance` at boot; switch it live if you want quieter and cooler):

```bash
cat /sys/firmware/acpi/platform_profile_choices                  # low-power balanced performance
echo performance | sudo tee /sys/firmware/acpi/platform_profile  # bias toward max turbo
echo balanced | sudo tee /sys/firmware/acpi/platform_profile     # lower sustained power, quieter
```

## Manual Build

To trigger the GHA workflow: GitHub Actions -> **Build ASUS NUC 16 Pro CachyOS ServerMax Kernel** -> **Run workflow**.

To trigger the Oracle A1 cross-compile fallback: GitHub Actions -> **Build ASUS NUC 16 Pro CachyOS ServerMax Kernel (Oracle A1 ARM64 cross)** -> **Run workflow**.

Both workflows accept a `force` input (`true`) to bypass the version pre-flight check and rebuild even if a release for the current kernel version already exists.

## Manual Install

```bash
sudo /usr/local/sbin/nuc16pro-kernel-updater.sh
```

## Logs

```bash
ls /var/log/nuc16pro-kernel-updater/
journalctl -u nuc16pro-kernel-updater.service
journalctl -u nuc16pro-scx-server.service
```

## Fallback

`linux-image-generic` is always installed before switching. GRUB shows the new custom kernel, the previously running custom kernel (kept as panic fallback), and the generic Ubuntu kernel. Old custom kernels beyond that pair are purged. GRUB config backup written to `/var/lib/nuc16pro-kernel-updater/backups/` on each install.

## Archive

The previous Lenovo V15 G2 ITL configuration is preserved in the `archive/lenovo-v15g2-itl` branch.
