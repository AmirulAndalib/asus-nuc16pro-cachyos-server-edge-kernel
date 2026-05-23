#!/usr/bin/env bash
set -euo pipefail

OWNER_REPO="${OWNER_REPO:-AmirulAndalib/lenovo-v15g2-itl-cachyos-server-edge-kernel}"

STATE_DIR="/var/lib/lenovo-kernel-updater"
LOG_DIR="/var/log/lenovo-kernel-updater"
WORK_DIR="/tmp/lenovo-kernel-install"
LOCK_FILE="/run/lenovo-kernel-updater.lock"

mkdir -p "$STATE_DIR" "$LOG_DIR" "$WORK_DIR"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "another instance is already running"
  exit 0
fi

LOG="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

msg() { echo ":: $*"; }

# Keep newest installed cachyos-lenovov15g2 kernel + currently running kernel.
# Purge all other cachyos-lenovov15g2 image and header packages.
# Must run before update-initramfs to avoid regenerating for kernels about to be removed.
purge_old_custom_kernels() {
  msg "purging old custom kernels"

  mapfile -t ALL_CUSTOM_IMG < <(
    dpkg -l | awk '/^ii/ && /linux-image-.*cachyos.*lenovov15g2/ {print $2}' | sort -V
  )

  if [ "${#ALL_CUSTOM_IMG[@]}" -le 1 ]; then
    echo "  only ${#ALL_CUSTOM_IMG[@]} custom kernel installed, nothing to purge"
    return 0
  fi

  KEEP_NEWEST="${ALL_CUSTOM_IMG[-1]}"
  RUNNING_PKG="linux-image-$(uname -r)"

  PKGS_TO_PURGE=()
  for pkg in "${ALL_CUSTOM_IMG[@]}"; do
    if [ "$pkg" = "$KEEP_NEWEST" ]; then
      echo "  keep (newest):  $pkg"
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
  apt-get autoremove -y || true
}

msg "lenovo kernel updater"
date
uname -a

msg "ensuring tools"
apt-get update -qq
apt-get install -y curl jq ca-certificates

msg "fetching latest release"
# Use list endpoint, not /releases/latest, so RC prereleases are included
curl -fsSL "https://api.github.com/repos/${OWNER_REPO}/releases" | \
  jq '.[0]' > "$WORK_DIR/latest-release.json"

TAG="$(jq -r '.tag_name' "$WORK_DIR/latest-release.json")"

if [ -z "$TAG" ] || [ "$TAG" = "null" ]; then
  echo "error: no release tag found"
  exit 1
fi

echo "latest release: $TAG"

LAST_TAG_FILE="$STATE_DIR/last-installed-tag"

CURRENT_KERNEL="$(uname -r)"
echo "running: $CURRENT_KERNEL"

NEED_REBOOT_ONLY=0

if [ -f "$LAST_TAG_FILE" ] && [ "$(cat "$LAST_TAG_FILE")" = "$TAG" ]; then
  echo "$TAG already recorded as installed"

  if echo "$CURRENT_KERNEL" | grep -q 'cachyos.*lenovov15g2'; then
    echo "already running custom kernel, re-applying tuning and checking SCX"
    NEED_REBOOT_ONLY=2
  elif dpkg -l | grep -qE '^ii[[:space:]]+linux-image-.*cachyos.*lenovov15g2'; then
    echo "custom kernel installed but not running, will set GRUB default and reboot"
    NEED_REBOOT_ONLY=1
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

# Intel Tiger Lake Iris Xe - hardware GuC submission + HuC media firmware
install -Dm644 /dev/stdin /etc/modprobe.d/i915-guc.conf <<'MODPROBE'
options i915 enable_guc=3
MODPROBE

# server sysctl tuning
install -Dm644 /dev/stdin /etc/sysctl.d/99-lenovo-v15g2-servermax.conf <<'SYSCTL'
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

# Intel GPU perf monitoring
dev.i915.perf_stream_paranoid      = 0
SYSCTL

# I/O scheduler: ADIOS for SSDs/NVMe, BFQ for spinning disks
install -Dm644 /dev/stdin /etc/udev/rules.d/60-lenovo-v15g2-ioschedulers.rules <<'UDEV'
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
ACTION=="add|change", KERNEL=="sd[a-z]|mmcblk[0-9]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="adios"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="adios"
UDEV

# CPU performance governor + EPP via systemd oneshot
install -Dm644 /dev/stdin /etc/systemd/system/lenovo-v15g2-servermax-cpupower.service <<'SERVICE'
[Unit]
Description=Lenovo V15 G2 ITL ServerMax CPU full performance policy
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
systemctl enable lenovo-v15g2-servermax-cpupower.service || true

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

if command -v scx_bpfland >/dev/null 2>&1; then
  echo "scx_bpfland: $(command -v scx_bpfland)"
else
  echo "scx_bpfland not found, trying apt..."
  # scx-scheds provides scx_bpfland, scx_rusty, scx_lavd, scx_p2dq, etc.
  apt-get install -y scx-scheds scx-tools 2>/dev/null || \
  apt-get install -y scx           2>/dev/null || \
  install_scx_from_source || true
fi

if ! command -v scx_bpfland >/dev/null 2>&1; then
  echo "warn: scx_bpfland missing after apt install, falling back to source build"
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
# scx_bpfland -s 20000 -S: 20ms slice for throughput, -S for strict-affinity server tasks
# fallback chain: bpfland -> p2dq -> bpfland (no args) -> rusty -> beerland -> lavd

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

install -Dm644 /dev/stdin /etc/systemd/system/lenovo-v15g2-scx-server.service <<'SCX_SVC'
[Unit]
Description=sched_ext server scheduler - Lenovo V15 G2 ITL
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
if systemctl list-unit-files scx_loader.service >/dev/null 2>&1; then
  mkdir -p /etc/scx_loader
  cat > /etc/scx_loader/config.toml <<'SCX_CFG'
default_sched = "scx_bpfland"
default_mode  = "Server"
SCX_CFG
  systemctl daemon-reload
  systemctl enable --now scx_loader.service || true
  systemctl disable lenovo-v15g2-scx-server.service 2>/dev/null || true
else
  systemctl enable --now lenovo-v15g2-scx-server.service || true
fi

if [ "$NEED_REBOOT_ONLY" -eq 2 ]; then
  SCX_ACTIVE=0
  systemctl is-active --quiet lenovo-v15g2-scx-server.service 2>/dev/null && SCX_ACTIVE=1 || true
  systemctl is-active --quiet scx_loader.service              2>/dev/null && SCX_ACTIVE=1 || true
  if [ "$SCX_ACTIVE" -eq 0 ]; then
    echo "SCX not active, attempting restart..."
    systemctl restart lenovo-v15g2-scx-server.service 2>/dev/null || \
      systemctl restart scx_loader.service 2>/dev/null || true
  else
    echo "SCX active"
  fi
fi

msg "applying sysctl and udev"
sysctl --system       || true
udevadm control --reload-rules || true
udevadm trigger       || true

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

# deduplicate existing params then append ours
GRUB_CMDLINE_ADD="i915.enable_guc=3 zswap.enabled=1 zswap.shrinker_enabled=1 zswap.compressor=zstd zswap.max_pool_percent=20 zswap.zpool=z3fold mitigations=auto intel_pstate=active"

if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
  CURRENT="$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub | \
    sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"/\1/')"

  for param in i915.enable_guc zswap.enabled zswap.shrinker_enabled \
               zswap.compressor zswap.max_pool_percent zswap.zpool \
               rcutree.enable_rcu_lazy mitigations intel_pstate; do
    CURRENT="$(echo "$CURRENT" | sed -E "s/(^| )${param}=[^ ]+//g")"
  done

  NEW="$(echo "$CURRENT $GRUB_CMDLINE_ADD" | xargs)"
  sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$NEW\"|" \
    /etc/default/grub
else
  echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$GRUB_CMDLINE_ADD\"" >> /etc/default/grub
fi

if [ -f /etc/initramfs-tools/modules ]; then
  grep -qxF "lz4" /etc/initramfs-tools/modules || echo "lz4" >> /etc/initramfs-tools/modules
fi

purge_old_custom_kernels

msg "updating initramfs and grub"
update-initramfs -u -k all
update-grub

msg "setting grub default"

TARGET_KERNEL="$(
  ls /boot/vmlinuz-*cachyos*lenovov15g2* 2>/dev/null |
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

systemctl status lenovo-v15g2-scx-server.service --no-pager -l | head -60 || true
systemctl status scx_loader.service --no-pager -l | head -30 2>/dev/null || true
[ -r /sys/kernel/sched_ext/state ] && echo "sched_ext: $(cat /sys/kernel/sched_ext/state)"

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
