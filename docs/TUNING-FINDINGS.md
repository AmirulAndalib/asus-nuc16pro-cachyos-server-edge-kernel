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

## 15. Drift check now clears the drift, and the CI got its own CI (2026-09-17)

Finding 14 made the drift check correct. It was still only a smoke alarm: it compared, it went
red, and then it waited for the relevant build workflow's next daily cron. Between an upstream
release and that cron the box was knowingly behind for up to 24 hours, with a red badge nobody
could act on. Three consecutive scheduled runs failed on exactly that, all reporting the same
real gap (CachyOS 7.2.6, newest release here 7.2.5) and none of them doing anything about it.

The check now dispatches the build that closes the gap: kernel drift starts
`build-cachyos-server.yml`, scx drift starts `build-scx-schedulers.yml`. Neither is forced,
because each build's own pre-flight skips a version that already has a release, and that
idempotency is exactly what makes a redundant dispatch harmless.

### Three constraints shaped the design

**Recursion is a real failure mode, not a theoretical one.** `workflow_dispatch` is one of the
two events GitHub explicitly exempts from "events triggered by `GITHUB_TOKEN` do not create a
new workflow run". So a dispatch from this check really does start a build, and that build's
completion really does re-trigger the check through `workflow_run`. On the happy path that
terminates, because the build publishes a release and the drift clears. On the failure path it
does not: a build that fails, or one whose pre-flight skips a version that never produced a
release, leaves the drift in place and gets dispatched again, forever.

The guard is structural rather than clever. The dispatch step is gated off the `workflow_run`
trigger entirely, which makes the 4-hourly cron the only dispatch clock. A build completion can
report, but it can never re-arm the build.

**The Oracle A1 cross-build is never dispatched.** It is the fallback for when the
GitHub-hosted build fails, it runs on a self-hosted machine that may be powered down (a
dispatch would queue indefinitely rather than fail), and racing the two can publish two
releases for one kernel version. Its own 21:00 UTC cron already covers the case it exists for.

**A GitHub expression trap almost made the whole thing inert.** The dispatch gate was first
written as `inputs.auto_build != false`. On a `schedule` event there is no `inputs` context, so
that operand is null, and GitHub compares mixed types by casting both sides to numbers: null
becomes 0 and `false` becomes 0. `null != false` is therefore **false**, and the step would
have been silently skipped on the one trigger allowed to dispatch. No error, no annotation, the
step simply shows as skipped. It is written as an event guard now:

```yaml
if: >-
  github.event_name != 'workflow_run' &&
  (github.event_name != 'workflow_dispatch' || inputs.auto_build) &&
  (steps.resolve.outputs.kernel_state == 'DRIFT' || steps.resolve.outputs.scx_state == 'DRIFT')
```

Neither `actionlint` nor `zizmor` flags the broken form. Both spellings are valid syntax.

### Badge semantics changed

| state | job |
| ----- | --- |
| no drift | green |
| drift, build dispatched by this run | green |
| drift, build already queued or running | green |
| drift still present after a build completed | **red** |
| dispatch itself failed | **red** |

Red now means the pipeline is genuinely broken rather than merely behind. The old red window
between an upstream release and the next daily build was noise, and noise on a badge trains
people to ignore it.

### Silent-failure surfaces that got closed

A `workflow_run` trigger naming a workflow it cannot resolve **fails open**: GitHub neither
errors nor fires it. A rename of any build workflow therefore used to degrade this check to
cron-only with no signal anywhere. A step now reads each build workflow's own `name:`, asserts
it appears in the `on.workflow_run.workflows` list, and cross-checks that the dispatch targets
are registered with GitHub Actions, so that degradation is a red job.

### Nothing was auditing the CI

The workflows build a kernel and publish it to a machine on the open internet, and nothing
reviewed them. `lint-ci.yml` now runs actionlint (checksum-pinned), zizmor for Actions-specific
security, shellcheck over `scripts/` at error severity, and a regeneration check on the
updater. Its first run failed on its own file, catching markdown backticks inside a
single-quoted `printf` (`SC2016`), and then a comment beginning with the linter's own name,
which is parsed as an inline directive rather than prose (`SC1073`). Both were reachable only
through actionlint's shellcheck integration, which spawns a process per `run:` block: fast on
the Linux runner, unusably slow under Windows, so local checking had skipped it.

zizmor's findings across the existing workflows were real and are fixed: workflow inputs and
third-party API strings (the sched-ext tag, the `force` input) reached the shell by string
interpolation into `run:` bodies and now arrive through `env`, quoted on use; every checkout
sets `persist-credentials: false`; each file starts at `permissions: {}` with jobs widening to
exactly what they need. The one suppression is the `workflow_run` trigger itself, annotated in
place with the reason it is safe here: it triggers only on this repo's own workflows, checks
out the default branch rather than any PR head, and runs nothing from the triggering run.

### Release assets carry provenance

Every published `.deb` and scx binary now gets a signed SLSA build-provenance attestation from
the workflow's own OIDC identity. `SHA256SUMS` proves a file was not altered in transit; the
attestation proves which workflow run, from which commit, produced it, which is the stronger
claim on a box that installs these packages unattended. Verify with:

```bash
gh attestation verify linux-image-*.deb \
  --repo AmirulAndalib/asus-nuc16pro-cachyos-server-edge-kernel
```

The attest step runs **after** the release, not before. Attestation is additive, and a Sigstore
outage must not discard a kernel that already built for six hours and published successfully.

### Verified in production, not just reasoned about

The dispatch path was exercised end to end on 2026-09-17 rather than left as static analysis:

- a manual run found the real 7.2.6 drift and dispatched `build-cachyos-server.yml`
  (`event=workflow_dispatch`); the job reported `DRIFT - build dispatched` and went **green**,
  where the three preceding scheduled runs on the same drift had gone red and done nothing
- the dispatched build's pre-flight did **not** skip, confirming it resolved a version with no
  existing release
- the next 4-hourly cron, firing while that build was still running, hit the in-flight guard:
  `skipping dispatch of build-cachyos-server.yml, a run is queued or in progress`, reported
  `DRIFT - build already running`, and stayed green. `gh run list` confirmed exactly one kernel
  build existed, so the guard prevented a duplicate rather than merely claiming to

Separately, `build-scx-schedulers.yml` ran on its own cron with the modernised file and
succeeded, which validated the boolean-input-through-`env` pattern on the schedule path where
`inputs` does not exist: `FORCE_BUILD` arrived empty and correctly did not force.

### Deliberately not done

The two kernel build workflows are roughly 95% identical and an obvious candidate for a
`workflow_call` reusable workflow. It was left alone. They diverge on runner (hosted versus
self-hosted label set, which forces `runs-on` through `fromJSON` on an input), timeout, swap
size, Docker build path (Buildx with GHA cache versus plain `docker build`), ccache key,
validation strategy (QEMU/KVM boot test versus package content inspection), and the
cross-compile environment. Collapsing that into one parameterised workflow means roughly eight
inputs and several conditional steps, which is not obviously simpler than two readable files,
and it is a refactor with a six-hour feedback loop on a pipeline that currently works. Doing it
in the same change as the drift plumbing would also have given any breakage two candidate
causes.

---

## 16. Three-way benchmark: stock vs servermax vs ultimate (2026-09-26)

Section 12 set the rule that a tuning change needs a number behind it, but the box had no way
to produce one. `scripts/nuc16pro-bench.sh` is that missing capability, and this is its first
real result: an interleaved, order-rotated comparison of three runtime profiles on the live
box while it served its normal ~91 containers.

**Scope, stated plainly.** All three profiles run on the SAME kernel. This measures the
runtime tuning layer only. It cannot A/B the kernel build itself (ThinLTO, x86-64-v3, HZ=100,
preempt=lazy, ADIOS compiled in), because that needs a reboot into a different kernel image,
and only the CachyOS kernel is installed. "stock" below means this kernel with the tuning
removed, not the stock Ubuntu kernel.

| profile | what it is |
| ------- | ---------- |
| stock | EEVDF (scx detached), PMD-only THP, mq-deadline + nr_requests 64, distro sysctls (swappiness 60, cubic, pfifo_fast) |
| servermax | what this repo ships: scx_flash, mTHP 16k/32k/64k, ADIOS + nr_requests 1023, bbr + fq, swappiness 10 |
| ultimate | servermax plus the candidates under test: `scx_flash --slice-us 3000`, `tcp_slow_start_after_idle=0`, `tcp_notsent_lowat=128k` |

### Results

5 rounds per benchmark, 12s per run, profile order rotated every round. Medians shown;
"noise floor" is the larger of the two within-profile spreads, expressed as a percentage.

| benchmark | stock vs servermax | ultimate vs servermax | noise floor | verdict on ultimate |
| --------- | ------------------ | --------------------- | ----------- | ------------------- |
| cpu throughput | -0.7% | -0.4% | 28.3% | NOISE |
| context switch | -16.8% | -9.4% | 33.0% | NOISE |
| fork/exec churn | -14.0% | +3.2% | 18.3% | NOISE |
| disk 4k randread | +14.7% | +1.4% | 14.2% | NOISE |
| loopback TCP | +48.7% | -0.5% | 9.1% | NOISE |

### What this settles

**The ultimate profile does not ship.** Not one of its three candidates cleared the noise
floor on any benchmark. The `scx_flash` server slice was the single biggest unexploited lever
in this repo: `config.toml` sets `default_mode = "Server"` but defines no `server_mode` flag
array, so flash has always run upstream defaults, and section 10 explicitly left it alone for
want of a measurement. It now has one, and the answer is that a 3000us slice buys nothing
here. The `[scheds.flash] server_mode` array stays absent, and that is now a measured
decision rather than an open question.

**The binding constraint is no longer any kernel knob: it is measurement noise.** The
within-profile spread on this box ranges from 9% (loopback) to 33% (context switch) while it
serves live traffic. Any tuning change worth less than roughly a third of a context-switch
benchmark is unprovable here without quiescing the machine, and quiescing it means taking down
DNS, Plex and Home Assistant. That is the real ceiling, and it retroactively justifies the
section 10 decision to withdraw the wbt/rq_affinity change on a sub-5% fio delta.

**scx_flash earns its place on scheduler-shaped work.** servermax beats stock by 16.8% on
context switching and 14.0% on fork/exec churn. Both sit under the noise floor so neither is
proof, but the direction is consistent and it is the workload shape this box actually has:
~91 containers, not one hot loop. Nothing here argues for going back to EEVDF.

### Two results that look like wins and are not

**Loopback TCP, stock +48.7%.** This one clears its noise floor, and it is still not a reason
to change anything. stock uses cubic with pfifo_fast; servermax uses BBR with fq. On loopback
there is no bottleneck link and no real RTT, so fq's pacing is pure overhead and BBR's
bandwidth probing has nothing to discover. That is a known property of measuring BBR on a
zero-latency path, not a defect in the setting. BBR plus fq is chosen for the real 2.5GbE
bond and the WAN upload path, neither of which this benchmark touches. The honest conclusion
is that the loopback benchmark cannot answer the BBR question; a proper answer needs iperf3
against a second host. That test was then run and is recorded in section 17, which also
corrects this sentence: the traffic did not cross the bond, because the bond carries no
outbound traffic at all.

**Disk 4k randread, stock +14.7%.** It clears its floor by 0.5 points, which is not a margin
worth acting on, and the shape of the data argues against it: stock's spread is 300714 IOPS
(31% of its own median) while servermax's is 32905 (3.4%). ADIOS is dramatically more
consistent; mq-deadline occasionally spikes higher. A single 4k randread pattern is also a
poor proxy for ~91 containers doing mixed IO through LUKS. Not actionable as it stands.

### Method notes worth keeping

The first run of this harness used a fixed profile order and produced a clean-looking and
completely false result: stock flat near 39000 while servermax climbed 36139 to 38747 across
rounds, which read as "stock wins CPU by 8%". It was position bias. Whichever profile ran
first each round benchmarked on a machine that had just finished settling, and the later ones
paid for a scheduler restart. Rotating the order per round removed the effect entirely and the
same comparison came back as -0.7%, which is to say nothing at all.

The harness proves itself before it is trusted: `nuc16pro-bench.sh selftest` runs two
identical profiles against each other and must report NOISE. It does.

Every profile switch is reverted on exit, including on interrupt, and the restore is verified
against scx attachment, mTHP orders, the IO scheduler, swappiness, congestion control and the
zswap compressor. After this run the box was confirmed back on servermax on every one.

---

## 17. The 2.5GbE bond carries no outbound traffic; WiFi 7 MLO is the real path (2026-09-26)

Chasing the BBR question from section 16 onto a real network turned up something much larger
than the congestion-control answer.

### What was found

`ip route get <lan-peer>` resolves to `dev wlo1`. There is no bond0 route in the table at
all: `ip route show dev bond0` returns nothing, and the only LAN route is
`<lan-subnet> dev wlo1 ... metric 600`. bond0 holds an address but has nowhere to send.

Interface counters since boot make it unambiguous:

| interface | rx | tx |
| --------- | -- | -- |
| wlo1 | 21 GB | **467 GB** |
| bond0 | 7 GB | **0 GB** (see note) |
| enp86s0 | 3 GB | 0 GB |
| enp87s0 | 3 GB | 0 GB |

Measured directly: an iperf3 transfer of 3053 MB moved 3053 MB on wlo1 and exactly 0 on
bond0 and both of its slaves.

Note on that zero: it was zero at the moment of discovery, before anything in this audit ran.
bond0's counter is no longer zero today, because the `--bind-dev` comparison further down this
section deliberately forced about 4 GB through it. Nothing else has ever used it.

Inbound still arrives over ethernet (bond0 rx is 7 GB) because the switch ARPs for the bond's
address and the link answers. Outbound leaves over WiFi. That asymmetry is precisely why
`rp_filter=2` (loose) is required in `sysctl.d/99-nuc16pro-servermax.conf`; strict reverse-path
filtering would drop these packets.

### The link the traffic actually uses

The AP is a WiFi 7 unit sitting immediately beside the box, and the association is nothing
like the 80MHz WiFi 6 link recorded in section 11:

```
Link 0  2462 MHz      Link 1  5805 MHz      Link 2  7055 MHz     (Multi-Link Operation)
tx bitrate: 5187.1 MBit/s   320MHz   EHT-MCS 12   EHT-NSS 2
signal: -12 dBm
```

Three simultaneous bands at 5187 Mbit/s of PHY rate, at a signal level that means the radio is
effectively touching the AP. Section 11's entry saying WiFi is "not at ceiling, but the limit
is the AP (WiFi 6, no 6GHz/320MHz)" is obsolete: the AP was replaced and that limit is gone.

### Which path is faster: measured three ways, and the answer is "the client decides"

The obvious next question is whether WiFi is beating the bond. The first attempt to answer it
was wrong, and the corrected answer is more interesting than either.

The test client reaches the network through a 2.5GbE switch, so any measurement between these
two machines is capped by that segment rather than by the link under test. Three paths were
measured with 4 streams for 8 seconds each:

| path | throughput | retransmits |
| ---- | ---------- | ----------- |
| NUC wlo1 (WiFi 7 MLO) to client on ethernet | 2.32 Gbit/s | 0 |
| NUC bond0 forced with `--bind-dev`, client on ethernet | 2.36 Gbit/s | 24925 |
| NUC wlo1 to the same client on its own WiFi 7 radio | 0.658 Gbit/s | 1 |

Three things fall out of this.

**Wired and wireless are indistinguishable to this client.** 2.32 against 2.36 Gbit/s is a 2%
gap with both sitting at roughly 92% of a 2.5GbE segment. Neither link is the bottleneck. An
earlier draft of this section claimed WiFi was "the faster path" on the strength of a single
2.29 Gbit/s figure; that number was the ceiling of the client's switch hop, not of the radio,
and the bond matches it when asked. Separating them needs a client that is not behind a 2.5GbE
hop, which this deployment does not have.

**Wireless to wireless is the configuration to avoid.** Moving the client onto its own WiFi 7
radio collapsed throughput to 658 Mbit/s, roughly 28% of the wired-client result, because both
stations then contend for the same airtime and the AP has to receive every frame before
re-transmitting it. This matters for how the box is measured in future: benchmarking the NUC's
WiFi against a wireless peer understates it by more than 3x. Test against a wired peer.

**The bond's retransmit count is the real signal in that table.** 24925 retransmits against
zero on WiFi, for a 2% throughput gain. That is not evidence the bond is unhealthy on its own
merits: forcing traffic out bond0 with `SO_BINDTODEVICE` while the return path still arrives
over WiFi creates exactly the asymmetry that provokes it. It does say that bond0 cannot simply
be forced into service one socket at a time, and that any future move back to wired has to fix
the routing properly rather than pin individual applications to the interface.

What this does establish is that **bond0 is fully functional hardware**: bound explicitly it
moves 2.36 Gbit/s, both slaves link at 2500 Mbps full duplex, and it is not a dead link. It
simply has no route.

### Status: accepted, not fixed

This is recorded as the operator's deliberate position rather than a defect to repair. WiFi 7
MLO is at least the equal of the wired bond on every measurement available here, the AP is
adjacent to the box, and the traffic is not being slowed by using it.

Nothing was changed on the box. Re-pointing the default route at bond0 is exactly the
operation that has dropped SSH on this machine before and needs console access to recover, so
it is not something to attempt remotely for a path that is currently slower anyway.

What this does change is the documentation. The repo described a 2x2.5GbE bond as the primary
path with WiFi as failover. The truth is the reverse, and several things tuned for the bond
are inert while that remains true:

- the igc ring buffer sizing (rx=4096 tx=4096) applies to interfaces carrying zero outbound bytes
- the balance-xor / layer3+4 hash policy is not distributing anything
- `bond0` rx drops and errors are still worth watching, because inbound does use it

### Honest correction to section 16

Section 16 proposed testing BBR "against a second host across the bond". That test was run and
BBR held up, but it crossed WiFi, not the bond, because the bond cannot send. The result
stands as a real-network measurement, but it crossed WiFi: the word "bond" in that sentence
was wrong.
