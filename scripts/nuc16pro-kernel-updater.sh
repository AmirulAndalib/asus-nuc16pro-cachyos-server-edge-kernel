#!/usr/bin/env bash
set -euo pipefail

OWNER_REPO="${OWNER_REPO:-AmirulAndalib/asus-nuc16pro-cachyos-server-edge-kernel}"

STATE_DIR="/var/lib/nuc16pro-kernel-updater"
LOG_DIR="/var/log/nuc16pro-kernel-updater"
WORK_DIR="/tmp/nuc16pro-kernel-install"
LOCK_FILE="/run/nuc16pro-kernel-updater.lock"

mkdir -p "$STATE_DIR" "$LOG_DIR" "$WORK_DIR"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "another instance is already running"
  exit 0
fi

LOG="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

msg() { echo ":: $*"; }

# Keep newest installed cachyos-nuc16pro kernel + currently running kernel.
# Purge all other cachyos-nuc16pro image and header packages.
# Must run before update-initramfs to avoid regenerating for kernels about to be removed.
purge_old_custom_kernels() {
  local target_kver="$1"
  msg "purging old custom kernels"

  mapfile -t ALL_CUSTOM_IMG < <(
    dpkg -l | awk '/^ii/ && /linux-image-.*cachyos.*nuc16pro/ {print $2}' | sort -V
  )

  if [ "${#ALL_CUSTOM_IMG[@]}" -le 1 ]; then
    echo "  only ${#ALL_CUSTOM_IMG[@]} custom kernel installed, nothing to purge"
    return 0
  fi

  # Keep the kernel that matches the current release version, not the highest sort order.
  # RC kernels (e.g. 7.1.0-rc2) sort higher than stable (7.0.10) but are not the target.
  KEEP_TARGET=""
  for pkg in "${ALL_CUSTOM_IMG[@]}"; do
    if echo "$pkg" | grep -qF "$target_kver"; then
      KEEP_TARGET="$pkg"
      break
    fi
  done
  [ -z "$KEEP_TARGET" ] && KEEP_TARGET="${ALL_CUSTOM_IMG[-1]}"

  RUNNING_PKG="linux-image-$(uname -r)"

  PKGS_TO_PURGE=()
  for pkg in "${ALL_CUSTOM_IMG[@]}"; do
    if [ "$pkg" = "$KEEP_TARGET" ]; then
      echo "  keep (target):  $pkg"
      continue
    fi
    if [ "$pkg" = "$RUNNING_PKG" ]; then
      echo "  keep (running): $pkg"
      continue
    fi
    PKGS_TO_PURGE+=("$pkg")
    HDR="${pkg/linux-image-/linux-headers-}"
    if dpkg -l "$HDR" 2>/dev/null | grep -q '^ii'; then
      PKGS_TO_PURGE+=("$HDR")
    fi
  done

  if [ "${#PKGS_TO_PURGE[@]}" -eq 0 ]; then
    echo "  nothing to purge"
    return 0
  fi

  echo "  purging: ${PKGS_TO_PURGE[*]}"
  apt-get purge -y "${PKGS_TO_PURGE[@]}" || true
}

msg "nuc16pro kernel updater"
date
uname -a

msg "ensuring tools"
apt-get update -qq
apt-get install -y curl jq ca-certificates ethtool lm-sensors

msg "fetching latest release"
# Use list endpoint, not /releases/latest, so RC prereleases are included
curl -fsSL "https://api.github.com/repos/${OWNER_REPO}/releases" | \
  jq '.[0]' > "$WORK_DIR/latest-release.json"

TAG="$(jq -r '.tag_name' "$WORK_DIR/latest-release.json")"

if [ -z "$TAG" ] || [ "$TAG" = "null" ]; then
  echo "error: no release tag found"
  exit 1
fi

# upstream kernel version extracted from tag: v7.0.10-cachyos-... -> 7.0.10
TAG_KVER="$(echo "$TAG" | sed 's/^v//; s/-cachyos.*//')"
echo "latest release: $TAG ($TAG_KVER)"

LAST_TAG_FILE="$STATE_DIR/last-installed-tag"

CURRENT_KERNEL="$(uname -r)"
echo "running: $CURRENT_KERNEL"

NEED_REBOOT_ONLY=0

if [ -f "$LAST_TAG_FILE" ] && [ "$(cat "$LAST_TAG_FILE")" = "$TAG" ]; then
  echo "$TAG already recorded as installed"

  if echo "$CURRENT_KERNEL" | grep -q 'cachyos.*nuc16pro'; then
    echo "already running custom kernel, re-applying tuning and checking SCX"
    NEED_REBOOT_ONLY=2
  elif dpkg -l | grep -qE '^ii[[:space:]]+linux-image-.*cachyos.*nuc16pro'; then
    echo "custom kernel installed but not running, will set GRUB default and reboot"
    NEED_REBOOT_ONLY=1
  fi
fi

# Verify the specific kernel version from this tag is actually present.
# The state file can lie if the package was never installed or was purged.
if [ "$NEED_REBOOT_ONLY" -ne 0 ]; then
  if ! dpkg -l 2>/dev/null | grep -qE "^ii[[:space:]]+linux-image-${TAG_KVER}" && \
     ! ls /boot/vmlinuz-"${TAG_KVER}"* 2>/dev/null | grep -q .; then
    echo "warn: state file says $TAG installed but kernel ${TAG_KVER} not found in dpkg/boot, reinstalling"
    NEED_REBOOT_ONLY=0
  fi
fi

if [ "$NEED_REBOOT_ONLY" -eq 0 ]; then
  msg "downloading release assets"
  rm -rf "$WORK_DIR/assets"
  mkdir -p "$WORK_DIR/assets"

  jq -r '.assets[] | select(.name | test("^(linux-(image|headers).*\\.deb|linux-libc-dev_.*\\.deb|SHA256SUMS|BUILD_MANIFEST)$")) | .browser_download_url' \
    "$WORK_DIR/latest-release.json" > "$WORK_DIR/urls.txt"

  cat "$WORK_DIR/urls.txt"

  grep -q 'linux-image'   "$WORK_DIR/urls.txt" || { echo "error: no linux-image asset";   exit 1; }
  grep -q 'linux-headers' "$WORK_DIR/urls.txt" || { echo "error: no linux-headers asset"; exit 1; }
  grep -q 'SHA256SUMS'    "$WORK_DIR/urls.txt" || { echo "error: no SHA256SUMS asset";    exit 1; }

  cd "$WORK_DIR/assets"
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    echo "  -> $url"
    curl -fLJO "$url"
  done < "$WORK_DIR/urls.txt"

  ls -lh

  cat BUILD_MANIFEST 2>/dev/null || true

  msg "verifying checksums"
  sha256sum -c SHA256SUMS

  msg "verifying package architecture"
  for deb in *.deb; do
    ARCH="$(dpkg --info "$deb" | awk '/Architecture:/ {print $2}')"
    if [ "$ARCH" != "amd64" ] && [ "$ARCH" != "all" ]; then
      echo "error: unexpected architecture for $deb: $ARCH"
      exit 1
    fi
    dpkg --info "$deb" | grep -E 'Package:|Version:|Architecture:'
  done

  msg "installing fallback kernel"
  apt-get install -y linux-image-generic linux-headers-generic || true

  msg "installing kernel packages"
  mapfile -t DEBS < <(
    find . -maxdepth 1 -type f \
      \( -name 'linux-headers-*.deb' -o -name 'linux-image-*.deb' -o -name 'linux-libc-dev_*.deb' \) |
      sort
  )

  if [ "${#DEBS[@]}" -eq 0 ]; then
    echo "error: no .deb kernel packages found"; exit 1
  fi

  dpkg -i "${DEBS[@]}"
  apt-get -f install -y
fi

msg "system tuning"

BACKUP_DIR="$STATE_DIR/backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -a /etc/default/grub "$BACKUP_DIR/grub.bak" 2>/dev/null || true

# Intel Xe3 LP (Panther Lake iGPU, device 0xB0A0): xe driver, no i915 options needed
# xe driver auto-enables GuC firmware submission; no modprobe options required
install -Dm644 /dev/stdin /etc/modprobe.d/xe-nuc16pro.conf <<'MODPROBE'
# Intel Xe3 LP (Panther Lake, device 0xB0A0): xe driver
# GuC firmware submission is enabled by default in xe; no options needed.
# i915 is kept as fallback module but Panther Lake iGPU will bind to xe at boot.
MODPROBE

# Intel Wi-Fi 7 BE211: disable power save for max throughput on AC
install -Dm644 /dev/stdin /etc/modprobe.d/nuc16pro-wifi.conf <<'MODPROBE_WIFI'
options iwlwifi power_save=0
options iwlmvm power_scheme=1
MODPROBE_WIFI

# server sysctl tuning
install -Dm644 /dev/stdin /etc/sysctl.d/99-nuc16pro-servermax.conf <<'SYSCTL'
# TCP: BBR + FQ
net.core.default_qdisc             = fq
net.ipv4.tcp_congestion_control    = bbr
net.ipv4.tcp_fastopen              = 3

# large socket buffers (Plex, LAN transfers, Docker)
net.core.rmem_max                  = 134217728
net.core.wmem_max                  = 134217728
net.ipv4.tcp_rmem                  = 4096 87380 134217728
net.ipv4.tcp_wmem                  = 4096 65536 134217728

# inotify limits for Docker/containers
fs.inotify.max_user_watches        = 1048576
fs.inotify.max_user_instances      = 1024

# server memory bias
vm.swappiness                      = 10
vm.vfs_cache_pressure              = 50
vm.dirty_background_ratio          = 5
vm.dirty_ratio                     = 20

# high-load limits
fs.file-max                        = 2097152
net.core.netdev_max_backlog        = 16384

# Dual NIC: loose reverse-path filter allows multi-homed WiFi+ETH simultaneously.
# rp_filter=2 (loose) instead of 1 (strict) so both NICs can receive traffic
# when routing via the other interface (e.g. default via eth, DNS via wifi).
# NOT setting ip_forward: this is a workstation, not a router.
net.ipv4.conf.all.rp_filter        = 2
net.ipv4.conf.default.rp_filter    = 2

# NVMe: disable power-saving latency states for Gen4/Gen5 max throughput
# (mirrors kernel cmdline nvme_core.default_ps_max_latency_us=0)
# This is belt-and-suspenders; cmdline takes effect earlier at boot.
# dev.nvme is not a sysctl namespace; NVMe PS is controlled via cmdline only.
SYSCTL

# I/O scheduler: ADIOS for SSDs/NVMe, BFQ for spinning disks
install -Dm644 /dev/stdin /etc/udev/rules.d/60-nuc16pro-ioschedulers.rules <<'UDEV'
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
ACTION=="add|change", KERNEL=="sd[a-z]|mmcblk[0-9]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="adios"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="adios"
UDEV

# CPU performance governor + EPP via systemd oneshot
# Panther Lake: 4P + 8E + 4LP-E = 16C/16T, no HT
# All CPU* loops cover P/E/LP-E uniformly; Intel Thread Director + HFI
# handles per-core-type scheduling automatically at the firmware level.
install -Dm644 /dev/stdin /etc/systemd/system/nuc16pro-servermax-cpupower.service <<'SERVICE'
[Unit]
Description=NUC 16 Pro ServerMax CPU full performance policy (Panther Lake P/E/LP-E)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -w "$g" ] && echo performance > "$g" || true; done'
ExecStart=/bin/sh -c 'for e in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do [ -w "$e" ] && echo performance > "$e" || true; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable nuc16pro-servermax-cpupower.service || true
# restart, not just enable: RemainAfterExit=yes means an already-active oneshot
# won't re-run ExecStart just because the unit file changed underneath it
systemctl restart nuc16pro-servermax-cpupower.service || true

# Runtime power tuning: RAPL PL1/PL2, platform profile, energy_perf_bias, NVMe queue depth, igc rings
install -Dm644 /dev/stdin /etc/systemd/system/nuc16pro-servermax-power.service <<'POWER_SVC'
[Unit]
Description=NUC 16 Pro ServerMax runtime power limits and device tuning
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
# ACPI platform profile: request performance fan curve from EC/BIOS
ExecStart=/bin/sh -c '[ -f /sys/firmware/acpi/platform_profile ] && echo performance > /sys/firmware/acpi/platform_profile || true'
# Intel RAPL on 120W AC: PL1=104W, PL2=104W, Tau=224s (BIOS-unlocked ceiling, matches firmware Power Limit 1/2 + Time Window)
# Setting PL1=PL2 removes the sustained/burst distinction for max continuous performance.
# 104W package + iGPU/NPU/board draw stays under the 120W adapter; sustained ceiling is bounded by cooling, not the OS.
# BIOS may lock the MSR; read back actual value after write to confirm.
ExecStart=/bin/sh -c 'p=/sys/class/powercap/intel-rapl/intel-rapl:0; [ -d "$p" ] && printf 104000000 > "$p/constraint_0_power_limit_uw" && echo "RAPL PL1=$(cat $p/constraint_0_power_limit_uw)uW" || true'
ExecStart=/bin/sh -c 'p=/sys/class/powercap/intel-rapl/intel-rapl:0; [ -d "$p" ] && printf 104000000 > "$p/constraint_1_power_limit_uw" && echo "RAPL PL2=$(cat $p/constraint_1_power_limit_uw)uW" || true'
ExecStart=/bin/sh -c 'p=/sys/class/powercap/intel-rapl/intel-rapl:0; [ -d "$p" ] && printf 224000000 > "$p/constraint_0_time_window_us" || true'
ExecStart=/bin/sh -c 'p=/sys/class/powercap/intel-rapl/intel-rapl:0; [ -d "$p" ] && printf 224000000 > "$p/constraint_1_time_window_us" || true'
# energy_perf_bias=0: no microarchitecture power-saving bias on any core
ExecStart=/bin/sh -c 'for b in /sys/devices/system/cpu/cpu*/power/energy_perf_bias; do [ -w "$b" ] && printf 0 > "$b"; done; true'
# NVMe: maximize request queue depth per namespace for Gen4/Gen5 throughput
ExecStart=/bin/sh -c 'for q in /sys/block/nvme*/queue/nr_requests; do [ -w "$q" ] && printf 1023 > "$q"; done; true'
# igc (I226-V 2.5GbE): maximize ring buffers for throughput
ExecStart=/bin/sh -c 'iface=$(ls /sys/class/net/ 2>/dev/null | grep -m1 "^e" || true); [ -n "$iface" ] && ethtool -G "$iface" rx 4096 tx 4096 2>/dev/null || true'
# Thermal: set x86 package passive trip point to 100C = TjMax for Panther Lake 356H.
# This lets the CPU run at full turbo until hardware PROCHOT fires at TjMax.
# Only type=passive trips are touched; type=critical (emergency shutdown) is left untouched.
# Millidegrees: 100000. Writable unconditionally in kernel 6.14+ (no CONFIG_THERMAL_WRITABLE_TRIPS needed).
ExecStart=/bin/sh -c 'for zone in /sys/class/thermal/thermal_zone*; do ztype=$(cat "$zone/type" 2>/dev/null || true); [ "$ztype" = "x86_pkg_temp" ] || continue; for i in 0 1; do ttype=$(cat "$zone/trip_point_${i}_type" 2>/dev/null || true); ttemp="$zone/trip_point_${i}_temp"; [ "$ttype" = "passive" ] || continue; [ -w "$ttemp" ] && printf 100000 > "$ttemp" 2>/dev/null && echo "thermal: $ttemp=100000" || true; done; done; true'

[Install]
WantedBy=multi-user.target
POWER_SVC

systemctl daemon-reload
systemctl enable nuc16pro-servermax-power.service || true
# restart, not just enable: RemainAfterExit=yes means an already-active oneshot
# won't re-run ExecStart just because the unit file changed underneath it.
# This is what actually pushes a wattage/Tau change live on a machine that's
# already on the target kernel (no kernel change -> no reboot -> service never re-fires).
systemctl restart nuc16pro-servermax-power.service || true

msg "installing sched_ext schedulers"

install_scx_from_source() {
  echo "building sched-ext/scx from source..."
  apt-get update -qq
  apt-get install -y \
    git curl ca-certificates build-essential pkg-config \
    clang llvm libelf-dev zlib1g-dev libzstd-dev libseccomp-dev \
    protobuf-compiler rustc cargo make cmake ninja-build bpftool || true

  rm -rf /opt/scx
  git clone --depth=1 https://github.com/sched-ext/scx.git /opt/scx

  (
    cd /opt/scx
    cargo build --release --locked || cargo build --release
    find target/release -maxdepth 1 -type f -executable -name 'scx_*' \
      -exec install -Dm755 {} /usr/local/bin/ \; || true
    find target/release -maxdepth 1 -type f -executable -name 'scxctl' \
      -exec install -Dm755 {} /usr/local/bin/ \; || true
    find target/release -maxdepth 1 -type f -executable -name 'scx_loader' \
      -exec install -Dm755 {} /usr/local/bin/ \; || true
  )
}

# update if already managed; install if missing
if dpkg -l scx-scheds 2>/dev/null | grep -q '^ii'; then
  apt-get install --only-upgrade -y scx-scheds scx-tools 2>/dev/null || true
elif dpkg -l scx 2>/dev/null | grep -q '^ii'; then
  apt-get install --only-upgrade -y scx 2>/dev/null || true
elif [ -d /opt/scx/.git ]; then
  REMOTE_HEAD="$(git -C /opt/scx ls-remote origin HEAD 2>/dev/null | cut -f1 || true)"
  LOCAL_HEAD="$(git -C /opt/scx rev-parse HEAD 2>/dev/null || true)"
  if [ -n "$REMOTE_HEAD" ] && [ "$REMOTE_HEAD" != "$LOCAL_HEAD" ]; then
    echo "scx upstream changed ($LOCAL_HEAD -> $REMOTE_HEAD), rebuilding..."
    install_scx_from_source || echo "warn: scx rebuild failed, keeping existing binaries"
  else
    echo "scx source up-to-date ($LOCAL_HEAD)"
  fi
fi

if ! command -v scx_bpfland >/dev/null 2>&1; then
  echo "scx_bpfland not found, trying apt..."
  # scx-scheds provides scx_bpfland, scx_rusty, scx_lavd, scx_p2dq, etc.
  apt-get install -y scx-scheds scx-tools 2>/dev/null || \
  apt-get install -y scx           2>/dev/null || \
  install_scx_from_source || true
fi

if ! command -v scx_bpfland >/dev/null 2>&1; then
  echo "warn: scx_bpfland missing after install, falling back to source build"
  install_scx_from_source || echo "warn: source build failed, kernel EEVDF remains active"
fi

msg "scx binaries"
for b in scx_bpfland scx_p2dq scx_rusty scx_beerland scx_lavd scx_loader scxctl; do
  if command -v "$b" >/dev/null 2>&1; then
    echo "  found:   $b -> $(command -v "$b")"
  else
    echo "  missing: $b"
  fi
done

msg "configuring sched_ext server mode"
# Primary: scx_bpfland -s 20000 -S (20ms slice, strict-affinity server tasks)
# Fallback chain: p2dq -> bpfland (no args) -> rusty -> beerland -> lavd
#
# scx_lavd is topology-aware for Panther Lake P/E/LP-E but has a documented
# E-core over-prioritization issue (observed on Lunar Lake, sibling arch).
# Keep lavd at end of fallback chain until upstream resolves it.

install -Dm755 /dev/stdin /usr/local/sbin/scx-servermax-start.sh <<'SCX_WRAPPER'
#!/bin/sh
set -eu

for pair in \
  "scx_bpfland:-s 20000 -S" \
  "scx_p2dq:--keep-running" \
  "scx_bpfland:" \
  "scx_rusty:" \
  "scx_beerland:" \
  "scx_lavd:"; do
  sched="${pair%%:*}"
  args="${pair#*:}"
  if command -v "$sched" >/dev/null 2>&1; then
    echo "starting $sched $args"
    exec "$sched" $args
  fi
done

echo "no scx scheduler found, kernel EEVDF remains active"
exit 0
SCX_WRAPPER

install -Dm644 /dev/stdin /etc/systemd/system/nuc16pro-scx-server.service <<'SCX_SVC'
[Unit]
Description=sched_ext server scheduler - ASUS NUC 16 Pro (Panther Lake)
Documentation=https://github.com/sched-ext/scx
After=multi-user.target
ConditionPathIsDirectory=/sys/kernel/sched_ext

[Service]
Type=simple
Restart=on-failure
RestartSec=10
ExecStart=/usr/local/sbin/scx-servermax-start.sh

[Install]
WantedBy=multi-user.target
SCX_SVC

# prefer scx_loader when available (handles kernel upgrades without service restart)
systemctl daemon-reload
if systemctl cat scx_loader.service >/dev/null 2>&1; then
  mkdir -p /etc/scx_loader
  cat > /etc/scx_loader/config.toml <<'SCX_CFG'
default_sched = "scx_bpfland"
default_mode  = "Server"
SCX_CFG
  systemctl daemon-reload
  systemctl enable --now scx_loader.service || true
  systemctl disable nuc16pro-scx-server.service 2>/dev/null || true
else
  systemctl enable --now nuc16pro-scx-server.service || true
fi

if [ "$NEED_REBOOT_ONLY" -eq 2 ]; then
  SCX_ACTIVE=0
  systemctl is-active --quiet nuc16pro-scx-server.service 2>/dev/null && SCX_ACTIVE=1 || true
  systemctl is-active --quiet scx_loader.service          2>/dev/null && SCX_ACTIVE=1 || true
  if [ "$SCX_ACTIVE" -eq 0 ]; then
    echo "SCX not active, attempting restart..."
    systemctl restart nuc16pro-scx-server.service 2>/dev/null || \
      systemctl restart scx_loader.service 2>/dev/null || true
  else
    echo "SCX active"
  fi
fi

msg "applying sysctl and udev"
sysctl --system       || true
udevadm control --reload-rules || true
udevadm trigger       || true
udevadm settle --timeout=30 || true

msg "configuring grub"

if grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
  sed -i 's|^GRUB_DEFAULT=.*|GRUB_DEFAULT=saved|' /etc/default/grub
else
  echo 'GRUB_DEFAULT=saved' >> /etc/default/grub
fi

if grep -q '^GRUB_SAVEDEFAULT=' /etc/default/grub; then
  sed -i 's|^GRUB_SAVEDEFAULT=.*|GRUB_SAVEDEFAULT=false|' /etc/default/grub
else
  echo 'GRUB_SAVEDEFAULT=false' >> /etc/default/grub
fi

# direct boot, no menu (hold Shift at power-on to show GRUB when needed)
for kv in "GRUB_TIMEOUT=0" "GRUB_TIMEOUT_STYLE=hidden"; do
  key="${kv%%=*}"
  if grep -q "^${key}=" /etc/default/grub; then
    sed -i "s|^${key}=.*|${kv}|" /etc/default/grub
  else
    echo "$kv" >> /etc/default/grub
  fi
done

# threadirqs: spread interrupts across P/E/LP-E cores for better I/O latency
# nvme_core.default_ps_max_latency_us=0: disable NVMe power states (Gen4/Gen5 max throughput)
# No i915.enable_guc=3: Panther Lake iGPU uses xe driver, not i915
GRUB_CMDLINE_ADD="threadirqs usbcore.autosuspend=-1 nvme_core.default_ps_max_latency_us=0 zswap.enabled=1 zswap.shrinker_enabled=1 zswap.compressor=zstd zswap.max_pool_percent=20 zswap.zpool=z3fold mitigations=auto intel_pstate=active"

if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
  CURRENT="$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub | \
    sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"/\1/')"

  # Remove stale Lenovo/Tiger Lake params and any we're about to re-add
  for param in i915.enable_guc threadirqs usbcore.autosuspend nvme_core.default_ps_max_latency_us \
               zswap.enabled zswap.shrinker_enabled zswap.compressor \
               zswap.max_pool_percent zswap.zpool rcutree.enable_rcu_lazy \
               mitigations intel_pstate; do
    CURRENT="$(echo "$CURRENT" | sed -E "s/(^| )${param}=[^ ]+//g; s/(^| )${param}( |$)/ /g")"
  done

  NEW="$(echo "$CURRENT $GRUB_CMDLINE_ADD" | xargs)"
  sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$NEW\"|" \
    /etc/default/grub
else
  echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$GRUB_CMDLINE_ADD\"" >> /etc/default/grub
fi

if [ -f /etc/initramfs-tools/modules ]; then
  grep -qxF "lz4" /etc/initramfs-tools/modules || echo "lz4" >> /etc/initramfs-tools/modules
  grep -qxF "asus_wmi" /etc/initramfs-tools/modules || echo "asus_wmi" >> /etc/initramfs-tools/modules
fi

purge_old_custom_kernels "$TAG_KVER"

msg "updating initramfs and grub"
update-initramfs -u -k all
update-grub

msg "setting grub default"

TARGET_KERNEL="$(
  ls /boot/vmlinuz-*cachyos*nuc16pro*servermax* 2>/dev/null |
    sed 's|/boot/vmlinuz-||' |
    sort -V |
    tail -n1
)"

if [ -z "${TARGET_KERNEL:-}" ]; then
  echo "error: CachyOS kernel not found in /boot"
  ls -lh /boot/vmlinuz-* || true
  exit 1
fi

echo "target: $TARGET_KERNEL"

SUBMENU="$(awk -F"'" '/submenu / {print $2; exit}' /boot/grub/grub.cfg || true)"

# index() for fixed-string match - version dots are regex wildcards
ENTRY="$(awk -F"'" -v k="$TARGET_KERNEL" \
  '/menuentry / && index($0, k) {print $2; exit}' /boot/grub/grub.cfg || true)"

if [ -z "${ENTRY:-}" ]; then
  echo "error: GRUB entry not found for $TARGET_KERNEL"
  awk -F"'" '/menuentry / {print $2}' /boot/grub/grub.cfg || true
  exit 1
fi

GRUB_ENTRY="${ENTRY}"
[ -n "${SUBMENU:-}" ] && GRUB_ENTRY="${SUBMENU}>${ENTRY}"

grub-set-default "$GRUB_ENTRY"
echo "grub default: $GRUB_ENTRY"
grub-editenv list || true

echo "$TAG" > "$LAST_TAG_FILE"

msg "status"
dpkg -l | grep -iE 'cachyos|linux-image|linux-headers' || true
ls -lh /boot | grep -E 'cachyos|vmlinuz|initrd' || true

systemctl status nuc16pro-scx-server.service --no-pager -l | head -60 || true
systemctl status scx_loader.service --no-pager -l | head -30 2>/dev/null || true
[ -r /sys/kernel/sched_ext/state ] && echo "sched_ext: $(cat /sys/kernel/sched_ext/state)"

# RAPL power limits readback: confirm BIOS didn't lock/override our writes
if [ -d /sys/class/powercap/intel-rapl/intel-rapl:0 ]; then
  p=/sys/class/powercap/intel-rapl/intel-rapl:0
  echo "rapl pl1:   $(cat "$p/constraint_0_power_limit_uw")uW"
  echo "rapl pl2:   $(cat "$p/constraint_1_power_limit_uw")uW"
  echo "rapl tau1:  $(cat "$p/constraint_0_time_window_us")us"
  echo "rapl tau2:  $(cat "$p/constraint_1_time_window_us")us"
else
  echo "rapl:       sysfs not available (CONFIG_POWERCAP/INTEL_RAPL_CORE not loaded?)"
fi
[ -r /sys/firmware/acpi/platform_profile ] && echo "platform:   $(cat /sys/firmware/acpi/platform_profile)" || true

echo "installed:  $TAG"
echo "kernel:     $TARGET_KERNEL"
echo "backup:     $BACKUP_DIR"
echo "log:        $LOG"

if [ "$NEED_REBOOT_ONLY" -eq 2 ]; then
  echo "already on target kernel, tuning applied, no reboot"
else
  sync
  systemctl reboot
fi
