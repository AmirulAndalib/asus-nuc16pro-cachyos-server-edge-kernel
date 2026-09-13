# Tuning findings

Measurement log for the ASUS NUC 16 Pro ServerMax box. Every entry here was taken from the
live machine, not inferred from documentation. Rejected candidates are kept alongside the
accepted ones, because the rejections are the more useful half of the record: they stop a
future pass from re-proposing something that has already been measured and found worthless.

The governing rule for this repo is in [section 12](#12-verification-discipline): a tuning
change stays only if it has a number behind it.

Back to the [README](../README.md).

| section | subject |
| ------- | ------- |
| [10](#10-tuning-round-2-2026-08-23) | Tuning round 2: memory, dm-crypt, boot order |
| [11](#11-hardware-ceiling-audit) | Hardware ceiling audit: what is maxed and what cannot be |
| [12](#12-verification-discipline) | Verification discipline |
| [13](#13-routine-checkup-2026-09-01) | Routine checkup: Vulkan status and the scx mode question |

---

## 10. Tuning round 2 (2026-08-23)

Memory, dm-crypt, and boot ordering. Everything here was measured on the live box before it
was committed.

### Multi-size THP (mTHP), the biggest single win

The kernel defaults every anonymous THP order except PMD (2MB) to `never`
([`transhuge.rst`](https://docs.kernel.org/admin-guide/mm/transhuge.html): *"By default,
PMD-sized hugepages have enabled=inherit and all other hugepage sizes have
enabled=never"*). On a 30GB box running ~70 containers with a ~17GB page cache, 2MB
contiguous allocations mostly cannot be served, and there was no smaller huge-page order to
fall back to. Measured before the change:

```
thp_fault_alloc     172801
thp_fault_fallback 1573192      -> 81% of THP faults degraded to 4k pages
```

`nuc16pro-servermax-mm.service` enables orders 16k/32k/64k. Re-measured ~10 minutes after:

| order | alloc | fallback | success |
| ----- | ----- | -------- | ------- |
| 64kB | 363443 | 51554 | **87.6%** |
| 16kB | 215758 | 85548 | 71.6% |
| 32kB | 123649 | 70767 | 63.6% |
| 2048kB (PMD, unchanged) | 36299 | 152647 | 19.2% |

~700k huge-page allocations succeeded that would otherwise have been 4k pages. Orders
128k-1024k are left off on purpose: each additional order adds internal fragmentation and
another rung for the allocator to try and fail on, and they rarely match real allocation
sizes. PMD keeps `inherit` so it still follows the global `enabled=always`.

Verify: `for d in /sys/kernel/mm/transparent_hugepage/hugepages-*kB; do echo "$(basename $d) $(cat $d/enabled)"; done`

Revert: `systemctl disable --now nuc16pro-servermax-mm.service` and write `never` back.

### dm-crypt workqueue bypass

The root LV and both media disks are LUKS, so every container read and write pays the
dm-crypt path. dm-crypt defaults to handing crypto to an unbound workqueue and offloading
writes again to a second thread. With hardware AES (this box exposes `vaes`, cipher is
`aes-xts-plain64`, `xts(aes)` resolves to a VAES/AVX2 driver) the encryption is cheaper than
that scheduling round-trip. `no-read-workqueue` / `no-write-workqueue`
([`crypttab(5)`](https://man7.org/linux/man-pages/man5/crypttab.5.html), kernel 5.9+) make
dm-crypt process requests synchronously instead.

The updater rewrites whatever `crypttab` entries the box has (auto-detected, no UUIDs in this
repo), applies them live with `cryptsetup refresh` wherever a keyfile exists, and regenerates
the initramfs for the root entry. Devices unlocked by TPM or passphrase pick the flags up on
the next boot.

Verify: `sudo dmsetup table --target crypt` should show `no_read_workqueue no_write_workqueue`.

### Block layer: tried wbt off plus rq_affinity=2, measured nothing, reverted

The mechanism argument was sound. ADIOS already does latency-targeted arbitration with its
own per-op latency models, so blk-wbt is a second and blinder throttle on top of a smarter
one (upstream reached the same conclusion for BFQ), and `rq_affinity=2` completes on the
submitting CPU rather than its cache group, which should matter on a hybrid part where a
group spans dissimilar cores.

Then it was actually benchmarked, with `fio` on the NVMe behind the LUKS data disk, five
interleaved A/B pairs so drift could not favour one side:

| config | READ KB/s mean / median | WRITE KB/s mean / median |
| ------ | ----------------------- | ------------------------ |
| wbt=0, rq_affinity=2 | 161358 / 163783 | 133294 / 135919 |
| kernel defaults | **164477 / 164417** | 131533 / **136501** |

The spread *within* each config was wider than the difference *between* them, and the kernel
defaults came out marginally ahead on both medians. The change bought nothing measurable on
this workload, so the udev rule was withdrawn. The defaults are also the better-tested path.
`nr_requests=1023` and the ADIOS elevator itself are unaffected and stay.

Worth stating plainly: this is what the rest of this section would look like if it had been
wrong. mTHP has counters behind it, the crypt flags have a dm table behind them, and this one
had only a story, so it went.

### Boot ordering: tuning now lands before dockerd

Measured: `multi-user.target` only went active at **42.8s**, while `docker.service` started at
**19.5s**. Every unit ordered `After=multi-user.target`, which was both tuning oneshots, was
therefore applying CPU, NVMe, NIC and thermal policy *23 seconds after* ~70 containers had
already started, under the firmware's cold-boot power policy. All three tuning units are now
`After=basic.target` + `Before=docker.service`, the same fix already proven for the sched_ext
attach. The healthcheck asserts the ordering every boot so this cannot regress silently again.

### Smaller items

- **zswap pool 20% to 30%.** 12.77M writeouts against 7.88M readins is a pool too small to
  hold the working set, so pages were being pushed out and pulled straight back off the
  encrypted root. The pool is a ceiling, not a reservation.
- **DAMON proactive reclaim: tried, measured, removed.** It was enabled with a 128MiB/s
  quota, a 10ms/s CPU quota and 60s `min_age`, with watermarks deliberately set to
  high=1000/mid=1000/low=0 because this box runs at ~1.5% free memory with most of RAM as page
  cache, so the documented example `wmarks_low=200` would have parked it below its own low
  watermark and it would never have run at all. After ~19 hours:
  `bytes_reclaimed_regions=0`, `nr_reclaimed_regions=0`, while `nr_quota_exceeds=2` proved the
  kdamond was alive and actually hitting its quota, and the box was still holding 6.6GB of
  swap. It ran, it cost CPU, and it reclaimed nothing measurable. The reason is that MGLRU
  (fully enabled at `0x0007`) plus the zswap shrinker already drain cold anon continuously, so
  nothing survives to 60s idle. DAMON is aimed at bursty latency-sensitive reclaim; a media
  server that swaps steadily is not that shape. Asserted `N` so a stale module parameter
  cannot restart it.
- **Docker log rotation** (50m x 3, compressed) merged into the existing `daemon.json`. The
  default json-file driver has no size cap, which on ~70 containers is a real disk-fill risk
  on the encrypted root. dockerd is deliberately *not* restarted by the updater.
- **`noatime`** on the two media data disks (box-local `fstab`, not repo-tracked: the mount
  points and UUIDs are host-specific).
- **Bluetooth stays enabled.** It produces the large majority of the journal error lines on
  this box (9436 of 10182 in one boot) because it keeps finding nearby devices it cannot pair
  with, and disabling it was briefly attempted for that reason. That was wrong: Home Assistant
  uses the adapter for its BLE integrations (the container is privileged, `net=host`, with
  `/run/dbus` bind-mounted, talking to `hci0` via BlueZ). Log noise is cosmetic, a broken smart
  home is not. The healthcheck reports bluetooth state and flags neither direction, because
  whether it is on is an operator decision and not a health defect. A plain `systemctl disable`
  does not survive a reboot here anyway, since systemd presets and the bluez postinst re-enable
  it.

### Tested and rejected

| candidate | verdict |
| --------- | ------- |
| **KSM** (kernel samepage merging) | **Rejected on measurement.** Enabled with `advisor_mode=scan-time`; after 436 full scans and 1.6M pages scanned it had merged **15 pages** with `general_profit = -1884032`, a net *loss* of ~1.8MB. KSM only examines memory a process opted in via `MADV_MERGEABLE`/`PR_SET_MEMORY_MERGE`, and Docker sets neither; container image layers are already shared through the overlayfs page cache. Asserted off so a default flip cannot re-enable it. |
| **irqbalance** | Not installed. It has no awareness of P/E/LP-E asymmetry, so on this part it can migrate a NIC queue's IRQ onto a low-power core. The kernel's default spread plus `threadirqs` is left in place. |
| **`nohz_full` / `rcu_nocbs`** | Available in the config (`CONFIG_NO_HZ_FULL=y`, `CONFIG_RCU_NOCB_CPU=y`) and deliberately unused. Both are for pinned, isolated, single-tenant-per-core workloads; on a box with ~70 containers freely scheduled across all 16 cores they cost housekeeping-CPU capacity and gain nothing. |
| **`mitigations=off`** and per-mitigation opt-outs | Permanently off the table. The box is internet-exposed with published ports. |
| **`split_lock_mitigate=0`**, `kernel.watchdog=0` | Rejected: the first lets a misbehaving container stall the memory bus for everyone, the second removes hang detection from a machine that is administered remotely. |
| **RAPL / PL1 / PL2 writes, C-state forcing, `performance` governor pinning** | Unchanged. The 356H is silicon-capped at 80W MTP and light cores releasing power budget is what lets loaded cores turbo. See README section 6. |
| **scx_flash explicit `server_mode` flags** | Left alone. `config.toml` sets `default_mode = "Server"`, but per the scx_loader schema a mode only means something if a `[scheds.'flash'] server_mode = [...]` array defines flags, so flash currently runs with its own upstream defaults, confirmed by `ps` showing zero arguments. That is a healthy, supported state (attached, `NRestarts=0`), so the mode line is cosmetic rather than broken and the scheduler was not touched. |
| **Jumbo frames, `busy_poll`, coalescing changes** | Not pursued: WAN-capped upload workload on a 1500-MTU LAN with mixed clients, and `rx-usecs=3` is already the aggressive end. |

---

## 11. Hardware ceiling audit

What is actually maxed, and what cannot be. Read from hardware registers rather than
inferred, so this is a factual ledger rather than an aspiration. It exists so that a future
"max everything out" pass starts from what is already at its limit instead of re-litigating
it.

| component | measured state | verdict |
| --------- | -------------- | ------- |
| CPU | `cpuinfo_max_freq` 4.7GHz == `scaling_max_freq`, `no_turbo=0`, `max_perf_pct=100`, no core capped | **at ceiling** |
| Instruction set | `avx2` + `avx_vnni`, **no AVX-512 of any kind** | **x86-64-v3 is a hard ceiling**; v4 is impossible on this silicon, never propose it |
| PCIe | every device negotiates at its full `LnkCap`: Crucial P310 16GT/s x4 (Gen4), Micron 2200 8GT/s x4 (Gen3, the drive's own limit), both I226-V 5GT/s x1 | **at ceiling**, nothing under-negotiating |
| iGPU (Xe3) | `max_freq` == `rp0_freq` == 2450MHz | **unrestricted** |
| Memory | 2x16GB DDR5-4800 running at 4800 MT/s on **both** controllers | at these modules' rated max |
| Ethernet | both ports 2500Mb/s full duplex | I226-V silicon max |
| USB | root hubs at 20000M/x2 | USB 3.2 Gen2x2 max |
| Thunderbolt | `domain0` present, nothing attached | n/a |
| Display | all four DP/HDMI connectors disconnected | headless, nothing to tune |
| WiFi (BE211) | associated 5GHz ch161 at **80MHz HE (WiFi 6)**, MCS11 NSS2, 1200Mbit tx | **not** at ceiling, but the limit is the AP (WiFi 6, no 6GHz/320MHz) and `wlo1` is failover-only behind bond0 |

Idle cores sitting at 400MHz is the intended power-budget sharing on an 80W-capped part, not a
fault. One PCIe root port reporting width `x0` is an empty slot, not a defect.

**What is left is physical, not configuration:**

1. **Memory is the real bottleneck.** 30% of zswap writeouts get read back and the box holds
   several GB of swap. No kernel setting fixes a capacity shortage; larger or faster SODIMMs
   would outweigh every software change in sections 10 and 11 combined.
2. **WiFi** needs a WiFi 7 AP to reach 320MHz. It is a failover path, so this is low value.
3. **The Micron 2200 is a Gen3 drive.** x4 Gen3 is its ceiling; only a newer drive changes it.
4. **Sustained CPU power** is bounded by the 80W MTP silicon cap and the cooler, both
   BIOS-owned (README section 6).
5. **`mitigations=auto`** stays. Internet-exposed box; this is a security decision, not a
   missing optimisation.

---

## 12. Verification discipline

Why part of section 10 was withdrawn. Round two originally shipped four changes on mechanism
alone. They were then measured, and two did not survive. The rule this establishes for this
repo:

**A tuning change stays only if it has a number behind it.** mTHP has per-order allocation
counters. The dm-crypt flags have a `dmsetup table` line. KSM had `general_profit`, DAMON had
`bytes_reclaimed_regions`, and the block-layer knobs had an fio A/B; all three of those numbers
came back negative, zero, or noise, so all three are gone.

Practical notes for benchmarking this specific box:

- There was **no benchmark capability at all** until `fio` was installed. Mechanism-only
  reasoning is what let two unverifiable changes ship, so measure before claiming.
- The box idles around load 5 with ~70 containers. **fio deltas under roughly 5% are noise
  here.** Interleave A/B/A/B so drift cannot favour one side, run at least five pairs, and
  compare medians as well as means. A single before/after pair is worthless.
- Hardware ceilings (section 11) come from registers and are deterministic; those do not need
  repeated sampling, unlike throughput.

This rule also covers documentation. A claim in these files is only allowed to outlive the
measurement that produced it if someone re-checks it, which is what section 13 is.

---

## 13. Routine checkup (2026-09-01)

Two specific doubts were raised and both were chased to a definite answer.

### "Vulkan is not hardware" is correct, and it must stay that way for now

The box forces software Vulkan (lavapipe) via `/etc/environment` and a
`gnome-remote-desktop.service` drop-in, so anything that opens a Vulkan device gets llvmpipe:

```
driverName = llvmpipe   deviceName = llvmpipe (LLVM 21.1.8, 256 bits)
```

Forcing the hardware ICD (`/usr/share/vulkan/icd.d/intel_icd.json`) does now enumerate the real
GPU cleanly, which is a genuine change since the workaround was written:

```
deviceName = Intel(R) Graphics (PTL)   deviceType = INTEGRATED_GPU
driverName = Intel open-source Mesa driver   Mesa 26.0.8   ERRORS: 0
```

**That is not sufficient evidence to remove the workaround, and it was nearly mistaken for it.**
`vulkaninfo` only enumerates: it creates an instance and queries properties. The July SIGSEGV was
in `GrdHwAccelVulkan`, on the PipeWire **dmabuf import plus compute colour-convert** path, which
`vulkaninfo` never touches. Enumeration working proves nothing about the path that crashed.

The decisive fact is the Mesa version. The relevant upstream fix, *"ANV: dEQP ASTC tests crash w/
FPE_INTDIV on Xe3"*, shipped in **Mesa 26.1.2**. This box runs **26.0.8**, and 26.0.8 is the newest
build Ubuntu resolute offers (`apt-cache policy` shows candidate == installed). So the box does not
have the Xe3 ANV fixes, and the crash conditions are still present.

Corroborating, and easy to misread: there have been **zero** GRD crashes and zero ANV segfaults this
boot. That is the workaround doing its job, not evidence the bug is gone. The Intel ICD is never
loaded, so it cannot crash.

**Verdict: keep the lavapipe pin.** Revisit when Mesa >= 26.1.2 reaches this release. The cost is
narrow: the RDP colour-convert runs on CPU, H.264 encode stays hardware VAAPI, and VA-API is a
completely separate stack that is unaffected (45 profiles, iHD 26.3.2 live). Plex, HA, metube and
convertx transcode through `/dev/dri` on VA-API and never touch Vulkan.

### `scxctl get` says "with its own defaults", which is expected

The recollection that it used to say Server mode is half right. The loader *is* applying Server
mode; the string just reports the argument state. The evidence:

```
scx_loader[..]: switching Flash with mode Server..
scx_loader[..]: WARN: switching Flash to Server mode, but no mode-specific
                arguments are configured; the scheduler will run with its own defaults
SchedulerMode (DBus property) = 4        # 4 = Server
/proc/<pid>/cmdline            = "scx_flash"   # no args
```

Mode selection is working and `config.toml`'s `default_mode = "Server"` is honoured. What is
absent is a `[scheds.'flash'] server_mode = [...]` array defining *which flags* Server mode should
pass, so the loader falls through to flash's upstream defaults and says so. Flash is attached with
`NRestarts=0`; this is a healthy state, and the wording changed because newer scx-loader added that
explicit warning.

Deliberately not "fixed" by inventing flags. Flash's defaults (`--slice-us 700`,
`--slice-us-lag 20000`) are upstream's tuned values, and picking different numbers without an A/B
on this workload would be exactly the mechanism-only change that section 12 exists to prevent.

### Version mismatch explained

`scxctl`/`scx_loader` report **1.1.2** while `scx_flash` reports **1.1.3**. Not a packaging fault:
`sched-ext/scx` latest release is v1.1.3, but `sched-ext/scx-loader` is a **separate repository**
whose newest tag is **v1.1.2**. The build script tries the matching tag and falls back to the
default branch, so 1.1.2 is the newest loader that exists. Both are current.

### Everything else

Kernel auto-tracked to **7.2.2**, which kernel.org confirmed was the latest stable at the time
(7.3 was still `-rc1`), and scx is at the latest v1.1.3. The no-pinning pipeline working
unattended again. Healthcheck `warnings=0`, 0 failed units, 80 containers 0 unhealthy, 0 throttle
events at 73C, bond 2/2, dm-crypt 3/3, all four tuning units confirmed applying **before** docker.

mTHP at scale, the headline win, keeps holding: **74.3M** huge-page allocations at 98-99% success
(16k 22.5M, 32k 13.4M, 64k 38.4M) against PMD's 10%.

One number worth watching: the zswap refault ratio has risen from 30% to **56%**, and swap sits at
10GB. That is the RAM-capacity ceiling from section 11 asserting itself as the container count grew
to 80, not a tuning regression. No software setting fixes it.

---

## 14. Drift check corrected (2026-09-13)

The version drift check was failing with a kernel mismatch that was not real. It compared the
repo's newest kernel release against **kernel.org** latest stable, but this pipeline does not
build from a kernel.org tarball. `scripts/build-cachyos-server.sh` clones
`CachyOS/linux-cachyos` and sources the `linux-cachyos-server` PKGBUILD for `pkgver`, so the
CachyOS PKGBUILD version is the only upstream the pipeline can act on.

The three versions at the time of the alarm:

| source | version | meaning |
| ------ | ------- | ------- |
| kernel.org latest stable | 7.2.5 | what the check was comparing against |
| CachyOS `linux-cachyos-server` PKGBUILD | 7.2.4 | what the build actually consumes |
| newest release in this repo | 7.2.4 | what the pipeline produced |

The repo was correct and the check was wrong. Failing on kernel.org also made it an alarm with
no fix available: nothing here can make CachyOS rebase onto a newer stable.

What changed in `version-drift-check.yml`:

- The **failure condition** now compares the newest repo release against the CachyOS PKGBUILD
  version, read straight from the raw PKGBUILD with `grep`/`sed` rather than by sourcing
  third-party shell in CI. An unparseable `_major` fails the job loudly, so a CachyOS layout
  change surfaces as a red check instead of a silent comparison against an empty string.
- **kernel.org is still reported**, as a non-failing context line showing how far CachyOS
  trails mainline. Losing that visibility was the one real thing the old check provided.
- **Release selection is by version, not list order.** The old code took the first `^v[0-9]`
  row from `gh release list`. Releases published in the same batch can share a `createdAt`
  timestamp, and ordering between ties is not guaranteed, so it could pick an older tag and
  invent drift. It now extracts all matching tags and takes the maximum via `sort -V`, which
  also fixes plain lexical sort ranking `7.2.4` above `7.2.10`.
- **Schedule is every 4 hours** (`0 3-23/4 * * *`) instead of once daily at 06:15 UTC. The old
  time sat before the 09:00 build, so the check always graded the previous day's output.
- **The check is coupled to the builds properly.** Cron alone only bounds staleness; it cannot
  guarantee the check runs after a build finishes. A `workflow_run` trigger on all three build
  workflows fires the check the moment one completes. Those workflow names must match the
  build workflows' `name:` fields exactly, because GitHub silently never fires a `workflow_run`
  trigger naming a workflow it cannot resolve.

`CACHY_VARIANT` is pinned to `linux-cachyos-server` in the check's `env:` block to match what
both build workflows pass to the build script. Verified at the time of the fix: both
`build-cachyos-server.yml` and `build-cachyos-server-oracle.yml` pass
`CACHY_VARIANT="linux-cachyos-server"`, and CachyOS's `linux-cachyos-rc` variant sits at 7.3.0,
which confirms 7.2.4 on the server variant is deliberate rather than a stalled repo.
