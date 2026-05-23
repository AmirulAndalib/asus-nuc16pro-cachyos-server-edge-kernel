# Lenovo V15 G2 ITL, CachyOS ServerMax Kernel

Bleeding-edge [CachyOS](https://github.com/CachyOS/linux-cachyos) kernel pipeline for the Lenovo V15 G2 ITL (Intel Core i5-1135G7), tuned for AC-powered server/homelab workloads.

Tracks `linux-cachyos-server`, CachyOS stable server variant with server-optimized base config.

## Target System

| Field          | Value                                                         |
| -------------- | ------------------------------------------------------------- |
| Machine        | Lenovo V15 G2 ITL                                             |
| CPU            | Intel Core i5-1135G7 / Tiger Lake (4C/8T, 2.4-4.2 GHz)        |
| iGPU           | Intel Iris Xe (i915, GuC/HuC, Quick Sync)                     |
| WiFi           | Intel Wi-Fi 6 AX201                                           |
| Architecture   | x86-64-v3                                                     |
| Target OS      | Ubuntu 26.04 LTS (amd64)                                      |
| Kernel base    | [linux-cachyos-server](https://github.com/CachyOS/linux-cachyos) |
| Package format | Debian/Ubuntu `.deb`                                        |

## Kernel Profile

| Setting                | Value                                                        |
| ---------------------- | ------------------------------------------------------------ |
| Base scheduler         | EEVDF (servermax profile)                                    |
| sched_ext              | Compiled in, `scx_bpfland --server` auto-starts on install |
| Compiler               | LLVM / Clang + LLD                                           |
| LTO                    | ThinLTO                                                      |
| CPU target             | x86-64-v3 (AVX2, BMI2, FMA, LZCNT)                           |
| Timer frequency        | 100 Hz                                                       |
| Preemption             | None (max throughput)                                        |
| Transparent Huge Pages | always                                                       |
| TCP congestion         | BBR (mainline)                                               |
| I/O scheduler          | ADIOS (SSDs/NVMe), BFQ (HDDs) via udev                       |
| Zswap                  | Enabled (zstd, z3fold, 20% pool)                             |
| Async I/O              | io_uring enabled                                             |
| Network offload        | TLS kernel offload, XDP sockets                              |
| Block layer            | BLK_WBT writeback throttling, NVMe multipath                 |
| Cgroup v2              | Full stack (CFS_BANDWIDTH, all controllers)                  |
| CRIU                   | CHECKPOINT_RESTORE enabled                                   |
| PCIe                   | ASPM performance mode + PTM                                  |
| RCU lazy               | Disabled (AC-only, no power-saving bias)                     |
| GuC / HuC              | `i915.enable_guc=3`                                        |
| BTF                    | Enabled (`/sys/kernel/btf/vmlinux` for scx tools)          |
| Debug info             | DWARF (toolchain default) - required for BTF                 |

## Pipeline

Builds on a self-hosted Oracle Ampere A1 (AArch64) runner. LLVM cross-compiles natively - no QEMU emulation.

```text
Oracle A1 (ARM64) -> clang --target=x86_64-linux-gnu -> .deb (amd64)
```

Schedule: daily at 09:00 UTC. Pre-flight check compares upstream `pkgver` against recent releases - **skips the build if the kernel version already exists** (no duplicate releases).

### Release assets

- `linux-image-*.deb` - kernel image and modules
- `linux-headers-*.deb` - headers for DKMS / out-of-tree modules
- `linux-libc-dev_*.deb` - userspace kernel headers
- `SHA256SUMS` - SHA-256 checksums for all packages
- `BUILD_MANIFEST` - compiler version, CachyOS commit, build timestamp, full config metadata

Release tag format: `v{KERNEL}-cachyos-servermax-x86_64v3-{YYYYMMDD}.{RUN}`

Example: `v7.1.rc2-cachyos-servermax-x86_64v3-20260510.5`

RC kernels are published as pre-releases.

## Required GitHub Runner Labels

```text
self-hosted
Linux
ARM64
oracle-a1
tkg-builder
```

## Setup

### 1. Clone and set OWNER_REPO

```bash
git clone https://github.com/AmirulAndalib/lenovo-v15g2-itl-cachyos-server-edge-kernel.git
```

Set your repo in two places:

**`scripts/lenovo-kernel-updater.sh`** line 4:

```bash
OWNER_REPO="${OWNER_REPO:-AmirulAndalib/lenovo-v15g2-itl-cachyos-server-edge-kernel}"
```

**`systemd/lenovo-kernel-updater.service`** Environment line:

```ini
Environment=OWNER_REPO=AmirulAndalib/lenovo-v15g2-itl-cachyos-server-edge-kernel
```

### 2. Register the self-hosted runner

On your Oracle A1 instance:

```bash
./config.sh \
  --url https://github.com/AmirulAndalib/lenovo-v15g2-itl-cachyos-server-edge-kernel \
  --token YOUR_RUNNER_TOKEN \
  --labels self-hosted,Linux,ARM64,oracle-a1,tkg-builder
```

Docker must be installed and the runner user must have permission to run Docker without sudo.

### 3. Install the auto-updater on the Lenovo machine

Run as root:

```bash
cp scripts/lenovo-kernel-updater.sh /usr/local/sbin/lenovo-kernel-updater.sh
chmod 700 /usr/local/sbin/lenovo-kernel-updater.sh

cp systemd/lenovo-kernel-updater.service /etc/systemd/system/
cp systemd/lenovo-kernel-updater.timer   /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now lenovo-kernel-updater.timer
```

Timer fires daily at 04:00 local time. The installer is idempotent - records the installed tag in `/var/lib/lenovo-kernel-updater/last-installed-tag` and skips reinstall if already on that release.

### 4. What the installer does automatically

On first run and each new release, the installer handles everything without manual steps:

- Downloads and verifies `.deb` packages (SHA-256)
- Installs kernel packages via `dpkg`
- Installs `linux-image-generic` as fallback
- Writes `/etc/modprobe.d/i915-guc.conf` (`enable_guc=3`)
- Writes `/etc/sysctl.d/99-lenovo-v15g2-servermax.conf` (BBR+FQ, large buffers, inotify, vm tuning, i915 perf)
- Writes `/etc/udev/rules.d/60-lenovo-v15g2-ioschedulers.rules` (ADIOS for SSDs, BFQ for HDDs)
- Installs and enables `/etc/systemd/system/lenovo-v15g2-servermax-cpupower.service` (performance governor + EPP)
- Installs `scx-scheds`/`scx-tools` (sched_ext userspace schedulers)
- Enables `scx_loader` with `scx_bpfland` in Server mode (or direct service as fallback)
- Updates GRUB cmdline: `i915.enable_guc=3 zswap.enabled=1 zswap.shrinker_enabled=1 zswap.compressor=zstd zswap.max_pool_percent=20 zswap.zpool=z3fold mitigations=auto intel_pstate=active`
- Purges all previous custom `cachyos-lenovov15g2` kernels, keeping only the newest installed + the currently running kernel (panic fallback)
- Adds `lz4` to initramfs modules
- Runs `update-initramfs` + `update-grub`
- Sets the new kernel as GRUB default
- Reboots

### 5. sched_ext schedulers

The kernel has `CONFIG_SCHED_CLASS_EXT=y` and `CONFIG_DEBUG_INFO_BTF=y`. After install, `scx_bpfland` runs in Server mode automatically.

To switch schedulers manually:

```bash
# Stop current scheduler
systemctl stop lenovo-v15g2-scx-server.service  # or scx_loader

# Run a different scheduler
sudo scx_bpfland -s 20000 -S        # bpfland server
sudo scx_p2dq --keep-running         # p2dq server
sudo scx_rusty                       # rusty (general)
sudo scx_lavd --performance          # lavd (latency-focused)

# Or switch via scx_loader
scxctl start --scheduler scx_bpfland --mode Server
```

## Manual Build

GitHub Actions → **Build Lenovo V15 G2 ITL CachyOS Edge Kernel** → **Run workflow**.

## Manual Install

```bash
sudo /usr/local/sbin/lenovo-kernel-updater.sh
```

## Logs

```bash
ls /var/log/lenovo-kernel-updater/
journalctl -u lenovo-kernel-updater.service
journalctl -u lenovo-v15g2-scx-server.service
```

## Fallback

`linux-image-generic` is always installed before switching. GRUB shows the new custom kernel, the previously running custom kernel (kept as panic fallback), and the generic Ubuntu kernel. Old custom kernels beyond that pair are purged. GRUB config backup written to `/var/lib/lenovo-kernel-updater/backups/` on each install.
