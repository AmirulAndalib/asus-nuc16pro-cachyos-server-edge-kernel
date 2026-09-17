# ASUS NUC 16 Pro, CachyOS ServerMax Kernel

[![kernel build](https://github.com/AmirulAndalib/asus-nuc16pro-cachyos-server-edge-kernel/actions/workflows/build-cachyos-server.yml/badge.svg)](https://github.com/AmirulAndalib/asus-nuc16pro-cachyos-server-edge-kernel/actions/workflows/build-cachyos-server.yml)
[![scx build](https://github.com/AmirulAndalib/asus-nuc16pro-cachyos-server-edge-kernel/actions/workflows/build-scx-schedulers.yml/badge.svg)](https://github.com/AmirulAndalib/asus-nuc16pro-cachyos-server-edge-kernel/actions/workflows/build-scx-schedulers.yml)
[![version drift](https://github.com/AmirulAndalib/asus-nuc16pro-cachyos-server-edge-kernel/actions/workflows/version-drift-check.yml/badge.svg)](https://github.com/AmirulAndalib/asus-nuc16pro-cachyos-server-edge-kernel/actions/workflows/version-drift-check.yml)
[![updater in sync](https://github.com/AmirulAndalib/asus-nuc16pro-cachyos-server-edge-kernel/actions/workflows/check-kernel-updater-sync.yml/badge.svg)](https://github.com/AmirulAndalib/asus-nuc16pro-cachyos-server-edge-kernel/actions/workflows/check-kernel-updater-sync.yml)

[![latest release](https://img.shields.io/github/v/release/AmirulAndalib/asus-nuc16pro-cachyos-server-edge-kernel?sort=date&label=latest%20build&color=blue)](https://github.com/AmirulAndalib/asus-nuc16pro-cachyos-server-edge-kernel/releases/latest)
[![upstream cachyos](https://img.shields.io/badge/dynamic/regex?url=https%3A%2F%2Fraw.githubusercontent.com%2FCachyOS%2Flinux-cachyos%2Fmaster%2Flinux-cachyos-server%2FPKGBUILD&search=_major%3D%28%5B0-9.%5D%2B%29%5B%5Cs%5CS%5D*%3F_minor%3D%28%5B0-9%5D%2B%29&replace=%241.%242&label=upstream%20cachyos&color=green)](https://github.com/CachyOS/linux-cachyos/blob/master/linux-cachyos-server/PKGBUILD)
[![upstream scx](https://img.shields.io/github/v/release/sched-ext/scx?label=upstream%20scx&color=orange)](https://github.com/sched-ext/scx/releases/latest)
[![kernel.org stable](https://img.shields.io/badge/dynamic/regex?url=https%3A%2F%2Fwww.kernel.org%2Ffinger_banner&search=latest%20stable%20version%20of%20the%20Linux%20kernel%20is%3A%5Cs*%28%5B0-9.%5D%2B%29&replace=%241&label=kernel.org%20stable&color=lightgrey)](https://www.kernel.org/)
[![release date](https://img.shields.io/github/release-date/AmirulAndalib/asus-nuc16pro-cachyos-server-edge-kernel?label=built&color=informational)](https://github.com/AmirulAndalib/asus-nuc16pro-cachyos-server-edge-kernel/releases)

The **version drift** badge is the one that matters for a no-pinning pipeline. Drift means the
newest kernel release here has stopped matching the CachyOS `linux-cachyos-server` PKGBUILD,
which is the version this pipeline actually builds from, or the newest scx release here has
stopped matching `sched-ext/scx`'s latest tag. kernel.org stable is reported alongside as
context so CachyOS falling behind mainline stays visible, but it is not a failure condition:
nothing here can make CachyOS rebase.

The check does not just report drift, it clears it. On finding drift it dispatches the matching
build workflow immediately, rather than leaving the box behind until that workflow's next daily
cron. So the badge reads:

- **green** - either nothing is stale, or drift was found and the build that fixes it is
  already running.
- **red** - drift is still there after a build completed. That is the genuinely broken case:
  the build failed, or it skipped a version that never produced a release.

The check runs every 4 hours and again the moment any build workflow completes. Only the
4-hourly cron is allowed to dispatch; a build completion can report but never re-arm the build,
because `workflow_dispatch` is exempt from GitHub's "GITHUB_TOKEN does not trigger new runs"
rule and a failing build would otherwise re-dispatch itself forever. Kernel drift dispatches the
GitHub-hosted build only - never the Oracle A1 fallback, whose self-hosted runner may be powered
down and whose own cron already covers that case. See
[`version-drift-check.yml`](.github/workflows/version-drift-check.yml) and
[the correction that produced this behaviour](docs/TUNING-FINDINGS.md#14-drift-check-corrected-2026-09-13).

Reading the version badges: **latest build** should equal **upstream cachyos**, which is read
live from the `linux-cachyos-server` PKGBUILD and is the only kernel version this pipeline can
act on. **upstream scx** should equal the newest `scx-` release here. **kernel.org stable** is
informational: it shows how far CachyOS trails mainline, and it is normal for it to sit one
patch release ahead.

Bleeding-edge [CachyOS](https://github.com/CachyOS/linux-cachyos) kernel pipeline for the ASUS NUC 16 Pro (Intel Core Ultra 7 356H / Panther Lake), tuned for AC-powered server/homelab workloads.

Tracks `linux-cachyos-server`, CachyOS stable server variant with server-optimized base config.

## Target System

| Field          | Value                                                                                                                            |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Machine        | ASUS NUC 16 Pro                                                                                                                  |
| CPU            | Intel Core Ultra 7 356H / Panther Lake (4P+8E+4LP-E, 16C/16T, no HT)                                                             |
| Process        | Intel 18A (CPU die), Intel 3 (GPU die)                                                                                           |
| iGPU           | Intel Xe3 LP (`xe` driver, device 0xB0A0, 4 Xe3-cores, 2.45 GHz)                                                               |
| NPU            | Intel NPU 50 TOPS (`intel_vpu` / IVPU driver, 5th Gen, vpu_50xx firmware)                                                      |
| Ethernet       | Dual Intel I226-V 2.5GbE (`igc` driver)                                                                                        |
| WiFi           | Intel Wi-Fi 7 BE211 (`iwlwifi` + `iwlmvm`, 320 MHz, MLO, BT 6.0)                                                             |
| Storage        | 2x NVMe; measured link: Crucial P310 Gen4 x4, Micron 2200 Gen3 x4 ([audit](docs/TUNING-FINDINGS.md#11-hardware-ceiling-audit))    |
| Memory         | DDR5 CSO-DIMM; fitted 2x16GB DDR5-4800 at 4800 MT/s, dual controller ([audit](docs/TUNING-FINDINGS.md#11-hardware-ceiling-audit)) |
| Connectivity   | Thunderbolt 4 / USB4 x2, USB 3.2 Gen 2x2 (20 Gbps)                                                                               |
| Architecture   | x86-64-v3                                                                                                                        |
| Target OS      | Ubuntu 26.04 LTS (amd64)                                                                                                         |
| Kernel base    | [linux-cachyos-server](https://github.com/CachyOS/linux-cachyos)                                                                  |
| Package format | Debian/Ubuntu `.deb`                                                                                                            |
| AC adapter     | 120W (19VDC, 6.32A)                                                                                                              |

## Kernel Profile

Everything below is what the box actually runs, not a wishlist. Rows carrying a link were
established by measurement; the number behind them is in
[`docs/TUNING-FINDINGS.md`](docs/TUNING-FINDINGS.md).

### Build and scheduler

| Setting         | Value                                                                                                                                                                                                                                         |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Base scheduler  | EEVDF (servermax profile)                                                                                                                                                                                                                     |
| sched_ext       | Compiled in (`CONFIG_SCHED_CLASS_EXT=y`), `scx_flash` auto-starts before the docker fleet (unit ordered `After=basic.target Before=docker.service`, bounded retry on boot-storm ENOMEM; verifies attach, falls back to `scx_bpfland`) |
| Compiler        | LLVM / Clang + LLD                                                                                                                                                                                                                            |
| LTO             | ThinLTO                                                                                                                                                                                                                                       |
| CPU target      | x86-64-v3 (AVX2, BMI2, FMA, LZCNT). v4 is impossible on this silicon: no AVX-512 ([audit](docs/TUNING-FINDINGS.md#11-hardware-ceiling-audit))                                                                                                  |
| Timer frequency | 100 Hz (`CONFIG_HZ_100`)                                                                                                                                                                                                                    |
| Preemption      | Lazy (`preempt=lazy`, throughput lean; RT-class IRQs preempt immediately)                                                                                                                                                                   |
| Cgroup v2       | Full stack (CFS_BANDWIDTH, all controllers)                                                                                                                                                                                                   |
| CRIU            | CHECKPOINT_RESTORE enabled                                                                                                                                                                                                                    |
| BTF             | Enabled (`/sys/kernel/btf/vmlinux` for scx tools)                                                                                                                                                                                           |
| Debug info      | DWARF (toolchain default), required for BTF                                                                                                                                                                                                   |

### Memory

| Setting                | Value                                                                                                                                                  |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Transparent Huge Pages | always,**plus multi-size THP (mTHP) orders 16k/32k/64k enabled** ([measured](docs/TUNING-FINDINGS.md#multi-size-thp-mthp-the-biggest-single-win)) |
| mTHP shrinker          | `shrink_underused=1`: reclaim mostly-zero THPs instead of pinning the memory                                                                         |
| MGLRU                  | Fully enabled (`0x0007`), the multi-generational LRU doing the cold-anon work                                                                        |
| Zswap                  | Enabled at boot, zstd compressor, zsmalloc pool,**30%** pool ceiling, shrinker on ([measured](docs/TUNING-FINDINGS.md#smaller-items))             |
| Proactive reclaim      | None. DAMON_RECLAIM tried, reclaimed 0 bytes in 19h, dropped ([measured](docs/TUNING-FINDINGS.md#smaller-items))                                        |
| KSM                    | Off, deliberately: measured negative`general_profit` here ([measured](docs/TUNING-FINDINGS.md#tested-and-rejected))                                   |
| Swappiness             | `vm.swappiness=10` (swap only under real pressure; zswap absorbs the rest)                                                                           |
| Cache pressure         | `vm.vfs_cache_pressure=50` (keep dentry/inode cache for ~80 containers)                                                                              |
| Dirty writeback        | `vm.dirty_background_ratio=5`, `vm.dirty_ratio=20`                                                                                                 |
| Known ceiling          | RAM capacity is the box's real bottleneck, not a tunable ([audit](docs/TUNING-FINDINGS.md#11-hardware-ceiling-audit))                                   |

### Storage and I/O

| Setting           | Value                                                                                                                                                                         |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| I/O scheduler     | ADIOS (SSDs/NVMe), BFQ (HDDs) via udev +`modules-load.d` (adios is `=m`)                                                                                                  |
| Block layer       | NVMe multipath; kernel-default wbt + rq_affinity (fio showed no win,[measured](docs/TUNING-FINDINGS.md#block-layer-tried-wbt-off-plus-rq_affinity2-measured-nothing-reverted)) |
| NVMe queue depth  | `nr_requests=1023` per namespace at boot                                                                                                                                    |
| NVMe power states | Disabled (`nvme_core.default_ps_max_latency_us=0`, Gen4/Gen5 max perf)                                                                                                      |
| dm-crypt          | `no_read_workqueue` + `no_write_workqueue` on all LUKS devices ([measured](docs/TUNING-FINDINGS.md#dm-crypt-workqueue-bypass))                                             |
| Async I/O         | io_uring enabled                                                                                                                                                              |
| Filesystem        | `noatime` on the media data disks (box-local `fstab`, host-specific)                                                                                                      |
| File handles      | `fs.file-max=2097152`                                                                                                                                                       |
| inotify           | `max_user_watches=1048576`, `max_user_instances=1024` (the container fleet needs both raised)                                                                             |

### Network

| Setting             | Value                                                                         |
| ------------------- | ----------------------------------------------------------------------------- |
| TCP congestion      | BBR (mainline,`CONFIG_DEFAULT_TCP_CONG="bbr"`)                              |
| Queueing discipline | `fq`, BBR's intended pacing partner                                         |
| TCP Fast Open       | `net.ipv4.tcp_fastopen=3` (client and server)                               |
| Socket buffers      | `rmem_max`/`wmem_max` 128MB, `tcp_rmem`/`tcp_wmem` autotuned to 128MB |
| Backlog             | `net.core.netdev_max_backlog=16384`                                         |
| Bonding             | 2x 2.5GbE bonded (balance-xor, static LAG; see section 5); WiFi 7 failover    |
| Reverse path filter | `rp_filter=2` loose, required for asymmetric paths across bond0 + wlo1      |
| igc ring buffers    | rx=4096 tx=4096 on both I226-V 2.5GbE ports                                   |
| Network offload     | TLS kernel offload, XDP sockets                                               |
| WiFi power save     | Disabled (`iwlwifi power_save=0`, `iwlmvm power_scheme=1`)                |

### Graphics and media

| Setting     | Value                                                                                                                                      |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| GPU driver  | `xe` (Intel Xe3 LP Panther Lake, GuC auto-enabled); `i915` kept as fallback                                                            |
| Vulkan      | **Software (lavapipe) by design** until Mesa >= 26.1.2; box has 26.0.8 ([why](docs/TUNING-FINDINGS.md#13-routine-checkup-2026-09-01)) |
| VA-API      | Hardware iHD 26.3.2, 45 profiles; separate stack, unaffected by the Vulkan pin                                                             |
| iGPU clocks | Unrestricted:`max_freq` == `rp0_freq` == 2450MHz ([audit](docs/TUNING-FINDINGS.md#11-hardware-ceiling-audit))                           |

### Power, thermal, and interrupts

| Setting          | Value                                                                                         |
| ---------------- | --------------------------------------------------------------------------------------------- |
| P-state driver   | `intel_pstate=active` (hardware-managed P-states / HWP)                                     |
| CPU power limits | BIOS-owned PL1/PL2/Tau; silicon caps at 80W MTP                                               |
| Fan control      | BIOS/firmware owns curves; the OS does not set them                                           |
| energy_perf_bias | 0 (no microarchitecture power-saving bias on any core)                                        |
| Uncore frequency | `intel_uncore_freq_control` built as a module for ring/fabric visibility                    |
| RCU lazy         | Disabled (AC-only, no power-saving bias)                                                      |
| IRQ affinity     | `threadirqs`: spread IRQs across P/E/LP-E cores                                             |
| irqbalance       | Not installed: no P/E/LP-E awareness ([rejected](docs/TUNING-FINDINGS.md#tested-and-rejected)) |
| USB autosuspend  | Disabled (`usbcore.autosuspend=-1`): full power on all ports                                |
| PCIe             | ASPM performance mode + PTM                                                                   |
| Timekeeping      | `tsc=reliable`: skip the clocksource watchdog on a known-good TSC                           |
| Thermal trip     | Passive trip at TjMax (100C), no software throttle before hardware PROCHOT                    |

### Security posture

| Setting         | Value                                                                                                                                                  |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| CPU mitigations | `mitigations=auto`, permanently. The box is internet-exposed with published ports, so this is a security decision rather than a missing optimisation |
| Split-lock      | Left at kernel default.`split_lock_mitigate=0` would let one misbehaving container stall the memory bus for every other one                          |
| NMI watchdog    | `nmi_watchdog=0`; `kernel.watchdog` soft/hard lockup detection is retained, since the box is administered remotely                                 |
| Isolation knobs | `nohz_full` / `rcu_nocbs` compiled in and deliberately unused ([rejected](docs/TUNING-FINDINGS.md#tested-and-rejected))                             |

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

|              | GHA`ubuntu-latest`                  | Oracle A1 self-hosted             |
| ------------ | ------------------------------------- | --------------------------------- |
| Architecture | x86-64 (native)                       | ARM64 -> x86-64 (cross)           |
| Disk free    | `slimhub_actions` (~40-60 GB freed) | Persistent runner, manual cleanup |
| Swap         | 32 GB on`/mnt`                      | 16 GB on`/mnt`                  |
| Docker cache | Buildx GHA cache                      | Local layer cache (persistent)    |
| Timeout      | 360 min                               | 480 min                           |

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

Release tag format: `v{KERNEL}-cachyos-servermax-nuc16pro-x86_64v3-{YYYYMMDD}.{RUN}`

Example: `v7.2.4-cachyos-servermax-nuc16pro-x86_64v3-20260909.140`

Tags published before 2026-09-13 omit the `nuc16pro-` segment. Everything that reads
these tags (the build preflight, the drift check, the on-box updater) accepts both forms,
so older releases stay discoverable.

RC kernels are published as pre-releases.

### Build provenance

Every published `.deb`, and every scx binary, carries a signed SLSA build-provenance
attestation generated from the workflow's own OIDC identity. `SHA256SUMS` proves a file was not
altered in transit; the attestation proves *which workflow run, from which commit, on which
runner* produced it. That matters on a box that installs these packages unattended from the
internet.

```bash
# Verify a downloaded package before installing it
gh attestation verify linux-image-*.deb \
  --repo AmirulAndalib/asus-nuc16pro-cachyos-server-edge-kernel
```

### Workflows

| workflow | trigger | what it does |
|---|---|---|
| `build-cachyos-server.yml` | 09:00 UTC daily, drift dispatch, manual | primary kernel build on a GitHub-hosted runner, QEMU/KVM boot test, release |
| `build-cachyos-server-oracle.yml` | 21:00 UTC daily, manual | fallback cross-build on the self-hosted Oracle A1; skips when the primary already released |
| `build-scx-schedulers.yml` | 03:00 UTC daily, drift dispatch, manual | builds sched-ext/scx schedulers plus `scx_loader`/`scxctl` |
| `version-drift-check.yml` | every 4 h, after any build, manual | compares released versions to upstream and dispatches the build that clears any drift |
| `check-kernel-updater-sync.yml` | push/PR touching the updater's sources | regenerates the updater and fails if the committed copy differs |
| `lint-ci.yml` | push/PR touching `.github/` or `scripts/` | actionlint, zizmor (Actions security audit), shellcheck, generated-file check |

Every third-party action is pinned to a commit SHA, Dependabot bumps them weekly in one grouped
PR, and `lint-ci.yml` audits the workflows themselves so a broken expression or an over-broad
permission is caught before it ships rather than after.

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
- Installs the Intel VA-API media userspace (`intel-media-va-driver-non-free`, `libigdgmm12`, `libmfx-gen1.2`, `libvpl-tools`, `vainfo`) plus `smartmontools` + `nvme-cli` in a separate non-fatal apt step; deliberately excludes `intel-gsc` (absent from the Ubuntu 26.04 repos, and bundling it would abort the whole transaction)
- Where `gnome-remote-desktop` is present, writes `/etc/systemd/system/gnome-remote-desktop.service.d/10-software-vulkan.conf` plus matching `/etc/environment` lines (`VK_DRIVER_FILES`/`VK_ICD_FILENAMES` -> lavapipe) and adds `mesa-vulkan-drivers`: the RDP `--handover` session daemon SIGSEGVs inside the Intel Mesa Vulkan driver on Xe3 (black screen then client drop), so its Vulkan is pinned to the software rasteriser. VA-API hardware transcode is unaffected (separate iHD driver)
- Writes `/etc/modprobe.d/xe-nuc16pro.conf` (comment-only; `xe` driver needs no options for Panther Lake iGPU)
- Writes `/etc/modprobe.d/nuc16pro-wifi.conf` (`iwlwifi power_save=0`, `iwlmvm power_scheme=1`)
- Writes `/etc/sysctl.d/99-nuc16pro-servermax.conf` (BBR+FQ, large buffers, inotify, vm tuning, `rp_filter=2` for dual NIC)
- Writes `/etc/udev/rules.d/60-nuc16pro-ioschedulers.rules` (ADIOS for SSDs/NVMe, BFQ for HDDs) plus `/etc/modules-load.d/nuc16pro-adios.conf` - adios is built `=m` and lacks the `<name>-iosched` autoload alias bfq has, so without force-loading it the udev rule silently no-ops and SSD/NVMe fall back to mq-deadline/none
- Installs and enables `/etc/systemd/system/nuc16pro-servermax-cpupower.service` (EPP=performance, HWP dynamic boost, and platform_profile=performance on all P/E/LP-E cores; masks `power-profiles-daemon` so it stays the single owner). The cpufreq `scaling_governor` is left at **`powersave` on purpose, this is not a downgrade**: under `intel_pstate` active mode + HWP the governor name is misleading, the hardware auto-scales each core from ~400 MHz idle to full ~4.7 GHz turbo on demand, biased hard toward performance by `EPP=performance` + `hwp_dynamic_boost=1`. A pinned `performance` governor would hold *idle* cores at max P-state too, wasting power budget that, under the 80 W MTP cap, is better handed to the *loaded* cores so they turbo higher. So `powersave`+EPP=performance is the faster config here and still ramps to max exactly when needed.
- Installs and enables `/etc/systemd/system/nuc16pro-servermax-power.service` (BIOS owns PL1/PL2/Tau and the platform profile; the OS sets only energy_perf_bias=0, NVMe nr_requests=1023, igc ring buffers on every I226-V port, and the TjMax 100°C thermal trip, all within the BIOS power envelope)
- Writes `/etc/systemd/system/plymouth-quit-wait.service.d/10-headless-noop.conf` - this headless box has no graphical handoff, so the stock `plymouth --wait` blocks `multi-user.target` forever (infinite timeout) and starves every `After=multi-user.target` unit including the tuning oneshots; the drop-in replaces it with a no-op so the target completes and tuning applies on boot
- Downloads the 6 schedulers (`scx_flash`, `scx_bpfland`, `scx_p2dq`, `scx_rusty`, `scx_beerland`, `scx_lavd`) plus `scx_loader` + `scxctl` and their systemd/DBus/polkit files from this repo's own `scx-*` GitHub release (built by `build-scx-schedulers.yml`, which also builds `sched-ext/scx-loader`), verifies against `SHA256SUMS`, installs binaries to `/usr/local/bin` and the control plane to the DBus/systemd/polkit dirs
- Enables `scx_loader` with `scx_flash` in Server mode (or direct service as fallback)
- Installs and enables `nuc16pro-healthcheck.timer`: a read-only post-boot (~5 min) and daily health report (kernel, failed units, sched_ext attach state + cgroup_init count, xe/firmware, VA-API, bond, memory, thermal, NVMe SMART, docker health) logged to the journal (`journalctl -u nuc16pro-healthcheck`)
- Updates GRUB cmdline: `threadirqs usbcore.autosuspend=-1 nvme_core.default_ps_max_latency_us=0 zswap.enabled=1 zswap.shrinker_enabled=1 zswap.compressor=zstd zswap.max_pool_percent=20 mitigations=auto intel_pstate=active preempt=lazy tsc=reliable nmi_watchdog=0` and strips `splash` (headless box: the plymouth splash starves `multi-user.target`, complementing the plymouth-quit-wait drop-in above). `tsc=reliable` skips the clocksource watchdog (TSC is constant/nonstop/known-freq); `nmi_watchdog=0` frees the per-core perf counter the hard-lockup detector holds. `zswap.zpool=z3fold` dropped: z3fold was removed upstream, zswap falls back to the zsmalloc default. `mitigations=auto` kept on (internet-exposed).
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

### 7. GPU media stack, PXP/GSC firmware, and monitoring

The `xe` driver binds Panther Lake (`8086:b0a0`) natively with no `force_probe`, and the DMC, GuC, HuC, and GSC firmware all load.

**VA-API hardware transcode needs a userspace driver the kernel does not ship.** On a fresh box `vainfo` fails with `va_openDriver() returns -1` until the Intel iHD media stack is present. The updater now installs it automatically in a separate, non-fatal apt step: `intel-media-va-driver-non-free`, `libigdgmm12`, `libmfx-gen1.2`, `libvpl-tools`, `vainfo`. Two gotchas, both learned on this box:

- **Do not add `intel-gsc` to that apt line.** It is not in the Ubuntu 26.04 repos; apt validates the whole package list up front, so one unavailable name aborts the entire transaction and leaves VA-API broken. The kernel-side GSC firmware (`xe/ptl_gsc_1.bin`) loads regardless and is unrelated to this userspace package.
- Plex bundles its own iHD driver and VA libraries inside its container, so Plex transcodes even without the host stack. The host packages matter for other host-side or containerized transcoders that use `/dev/dri` plus the host `iHD_drv_video.so`.

**PXP (protected content) is unavailable, and that is expected.** The kernel refuses PXP because the PTL GSC firmware currently shipped by `linux-firmware` is older than the build the kernel requires. `journalctl -k | grep -i pxp` shows the message and the exact required build:

```
xe 0000:00:02.0: [drm] PXP requires PTL GSC build <N> or newer
```

Ordinary VA-API decode/encode/transcode is unaffected. This is a firmware-version limitation, not a kernel bug: do not hand-replace the GSC firmware; wait for a `linux-firmware` update to ship a new enough PTL GSC build.

**Monitoring: use `nvtop`.** `intel_gpu_top` enumerates Panther Lake (`intel_gpu_top -L`) but cannot read live engine telemetry under the `xe` driver yet (`Failed to detect engines... i915 PMU`); it expects the old i915 PMU interface. `nvtop` reads the `xe` telemetry correctly (per-engine load, clocks, VRAM, per-process). No kernel change is warranted for `intel_gpu_top`.

### 8. sched_ext boot ENOMEM (expected, self-healing)

On this box `scx_flash`'s `ops.cgroup_init()` transiently fails `-ENOMEM` during the boot container storm (verified: several events per boot). This is not a fault. The start script's bounded `try_primary` retry re-attaches `scx_flash` once the storm eases, so the scheduler ends up attached and stable with the scx unit's `NRestarts=0` (systemd never even has to restart it). Verified steady state: `sched_ext: enabled`, `root/ops = flash_...`. No action needed; the fallback chain (`scx_bpfland` and the rest) and the systemd `Restart=on-failure` remain as deeper safety nets. The health-check reports the per-boot count so a genuine regression (scheduler ending up detached) is visible.

### 9. Known-benign firmware messages (BIOS/EC, not the kernel)

These appear in the log on this board and are harmless to operation. They are ASUS BIOS/EC firmware issues, not custom-kernel issues; report them to ASUS if you want them fixed upstream:

- `ACPI BIOS Error ... Could not resolve symbol [\_SB.PC00.LPCB.HEC.RCFS/RFCS]` and the DPTF/`_FST` fan-state methods that abort from it (repeats roughly every few minutes). CPU temperature monitoring and BIOS/EC fan control keep working.
- `ucsi_acpi USBC000:00: error -ETIMEDOUT: PPM init failed` (USB-C UCSI). No observed impact on operation; USB-C/TB4 function was not part of this validation.
- `ACPI: thermal: [Firmware Bug]: Invalid critical threshold (-274000)` and `intel-hid ...: failed to enable HID power button`.

The updater does not suppress these; their cause is understood (firmware) and silencing them would hide real future messages.

### 10. Tuning findings, measurements, and rejected candidates

The detailed measurement log lives in **[`docs/TUNING-FINDINGS.md`](docs/TUNING-FINDINGS.md)**,
so this file stays a reference for the box rather than a lab notebook. It covers:

| section                                                          | subject                                                                                                                                         |
| ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| [10](docs/TUNING-FINDINGS.md#10-tuning-round-2-2026-08-23)        | Tuning round 2: mTHP, dm-crypt bypass, zswap, boot ordering, and everything tested and rejected (KSM, DAMON, blk-wbt, irqbalance,`nohz_full`) |
| [11](docs/TUNING-FINDINGS.md#11-hardware-ceiling-audit)           | Hardware ceiling audit: per-component register readings, what is already maxed, and the four limits that are physical rather than configurable  |
| [12](docs/TUNING-FINDINGS.md#12-verification-discipline)          | Verification discipline: why a change needs a number, and how to benchmark this specific box without fooling yourself                           |
| [13](docs/TUNING-FINDINGS.md#13-routine-checkup-2026-09-01)       | Routine checkup: why Vulkan stays on lavapipe, and why`scxctl get` reporting "its own defaults" is healthy                                    |
| [14](docs/TUNING-FINDINGS.md#14-drift-check-corrected-2026-09-13) | Drift check corrected: it was comparing against kernel.org instead of the CachyOS PKGBUILD the build actually consumes                          |

The short version of the rule those sections establish: **a tuning change stays only if it has
a number behind it.** Four changes once shipped on mechanism alone; two of them were then
measured and removed. Rejected candidates are documented rather than dropped, so a future pass
does not re-propose something already disproven on this hardware.

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
