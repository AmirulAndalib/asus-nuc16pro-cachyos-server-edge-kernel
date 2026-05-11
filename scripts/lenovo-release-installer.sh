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
  echo "Another lenovo-kernel-updater instance is already running."
  exit 0
fi

LOG="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

echo "========== LENOVO KERNEL UPDATER START =========="
date
uname -a

echo "========== ENSURE TOOLS =========="
apt-get update -qq
apt-get install -y curl jq ca-certificates

echo "========== FETCH LATEST RELEASE METADATA =========="
# Use list endpoint (not /releases/latest) so prereleases (RC builds) are included.
# jq '.[0]' extracts the most recent release as a single object - 
# all downstream .tag_name / .assets[] queries work unchanged.
curl -fsSL "https://api.github.com/repos/${OWNER_REPO}/releases" | \
  jq '.[0]' > "$WORK_DIR/latest-release.json"

TAG="$(jq -r '.tag_name' "$WORK_DIR/latest-release.json")"

if [ -z "$TAG" ] || [ "$TAG" = "null" ]; then
  echo "ERROR: no release tag found."
  exit 1
fi

echo "Latest release tag: $TAG"

LAST_TAG_FILE="$STATE_DIR/last-installed-tag"

echo "========== DUPLICATE CHECK =========="
CURRENT_KERNEL="$(uname -r)"
echo "Current running kernel: $CURRENT_KERNEL"

NEED_REBOOT_ONLY=0

if [ -f "$LAST_TAG_FILE" ] && [ "$(cat "$LAST_TAG_FILE")" = "$TAG" ]; then
  echo "State file says release $TAG is already installed."

  if echo "$CURRENT_KERNEL" | grep -q 'cachyos-edge-lenovov15g2-servermax'; then
    echo "Already running ServerMax kernel. Nothing to do."
    exit 0
  fi

  if dpkg -l | grep -qE '^ii[[:space:]]+linux-image-.*cachyos-edge-lenovov15g2-servermax'; then
    echo "ServerMax kernel installed but not running - will set GRUB default and reboot."
    NEED_REBOOT_ONLY=1
  fi
fi

if [ "$NEED_REBOOT_ONLY" -eq 0 ]; then
  echo "========== DOWNLOAD ASSETS =========="
  rm -rf "$WORK_DIR/assets"
  mkdir -p "$WORK_DIR/assets"

  jq -r '.assets[] | select(.name | test("^(linux-(image|headers).*\\.deb|linux-libc-dev_.*\\.deb|SHA256SUMS|BUILD_MANIFEST)$")) | .browser_download_url' \
    "$WORK_DIR/latest-release.json" > "$WORK_DIR/urls.txt"

  cat "$WORK_DIR/urls.txt"

  grep -q 'linux-image'   "$WORK_DIR/urls.txt" || { echo "ERROR: no linux-image asset";   exit 1; }
  grep -q 'linux-headers' "$WORK_DIR/urls.txt" || { echo "ERROR: no linux-headers asset"; exit 1; }
  grep -q 'SHA256SUMS'    "$WORK_DIR/urls.txt" || { echo "ERROR: no SHA256SUMS asset";    exit 1; }

  cd "$WORK_DIR/assets"
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    echo "Downloading: $url"
    curl -fLJO "$url"
  done < "$WORK_DIR/urls.txt"

  ls -lh

  echo "========== BUILD MANIFEST =========="
  cat BUILD_MANIFEST 2>/dev/null || true

  echo "========== VERIFY CHECKSUMS =========="
  sha256sum -c SHA256SUMS

  echo "========== VERIFY PACKAGE ARCHITECTURE =========="
  for deb in *.deb; do
    echo "Checking $deb"
    dpkg --info "$deb" | grep -E 'Package:|Version:|Architecture:'
    ARCH="$(dpkg --info "$deb" | awk '/Architecture:/ {print $2}')"
    if [ "$ARCH" != "amd64" ] && [ "$ARCH" != "all" ]; then
      echo "ERROR: unexpected package architecture for $deb: $ARCH"
      exit 1
    fi
  done

  echo "========== ENSURE FALLBACK KERNELS =========="
  apt-get install -y linux-image-generic linux-headers-generic || true

  echo "========== INSTALL KERNEL PACKAGES =========="
  mapfile -t DEBS < <(
    find . -maxdepth 1 -type f \
      \( -name 'linux-headers-*.deb' -o -name 'linux-image-*.deb' -o -name 'linux-libc-dev_*.deb' \) |
      sort
  )

  if [ "${#DEBS[@]}" -eq 0 ]; then
    echo "ERROR: no .deb kernel packages found"; exit 1
  fi

  dpkg -i "${DEBS[@]}"
  apt-get -f install -y
fi

echo "========== APPLY LENOVO SERVERMAX SYSTEM TUNING =========="

BACKUP_DIR="$STATE_DIR/backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -a /etc/default/grub "$BACKUP_DIR/grub.bak" 2>/dev/null || true

# Intel Tiger Lake Iris Xe - hardware GuC submission + HuC media firmware
install -Dm644 /dev/stdin /etc/modprobe.d/i915-guc.conf << 'MODPROBE'
options i915 enable_guc=3
MODPROBE

# Server-max sysctl tuning
install -Dm644 /dev/stdin /etc/sysctl.d/99-lenovo-v15g2-servermax.conf << 'SYSCTL'
# TCP: BBR + FQ
net.core.default_qdisc             = fq
net.ipv4.tcp_congestion_control    = bbr
net.ipv4.tcp_fastopen              = 3

# Large socket buffers: Plex, LAN transfers, Docker
net.core.rmem_max                  = 134217728
net.core.wmem_max                  = 134217728
net.ipv4.tcp_rmem                  = 4096 87380 134217728
net.ipv4.tcp_wmem                  = 4096 65536 134217728

# Docker/container inotify limits
fs.inotify.max_user_watches        = 1048576
fs.inotify.max_user_instances      = 1024

# Server memory bias
vm.swappiness                      = 10
vm.vfs_cache_pressure              = 50
vm.dirty_background_ratio          = 5
vm.dirty_ratio                     = 20

# General high-load limits
fs.file-max                        = 2097152
net.core.netdev_max_backlog        = 16384

# Intel GPU perf monitoring
dev.i915.perf_stream_paranoid      = 0
SYSCTL

# I/O scheduler: ADIOS for SSDs/NVMe, BFQ for spinning disks
install -Dm644 /dev/stdin /etc/udev/rules.d/60-lenovo-v15g2-ioschedulers.rules << 'UDEV'
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
ACTION=="add|change", KERNEL=="sd[a-z]|mmcblk[0-9]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="adios"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="adios"
UDEV

# CPU performance governor + EPP performance via systemd oneshot
install -Dm644 /dev/stdin /etc/systemd/system/lenovo-v15g2-servermax-cpupower.service << 'SERVICE'
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

echo "========== INSTALL SCHED_EXT USERSPACE SCHEDULERS =========="
# Try Ubuntu package first, then fallback message.
# scx-scheds provides scx_bpfland, scx_rusty, scx_lavd, scx_p2dq, etc.
apt-get install -y scx-scheds scx-tools 2>/dev/null || \
  apt-get install -y scx           2>/dev/null || \
  echo "INFO: scx packages not in repos - install from https://github.com/sched-ext/scx/releases"

echo "========== CONFIGURE SCHED_EXT SERVER MODE =========="
# Server-optimal scheduler: scx_bpfland -s 20000 -S
#   -s 20000  : slice 20ms (better throughput)
#   -S        : prioritize strict-affinity tasks (server workloads)
# Fallback chain: bpfland -> p2dq -> rusty -> beerland

install -Dm755 /dev/stdin /usr/local/sbin/scx-servermax-start.sh << 'SCX_WRAPPER'
#!/bin/sh
set -e
for pair in \
  "scx_bpfland:-s 20000 -S" \
  "scx_p2dq:--keep-running" \
  "scx_bpfland:" \
  "scx_rusty:" \
  "scx_beerland:"; do
  sched="${pair%%:*}"
  args="${pair#*:}"
  if command -v "$sched" >/dev/null 2>&1; then
    echo "Starting $sched $args"
    exec "$sched" $args
  fi
done
echo "No scx scheduler found. Kernel EEVDF remains active."
exit 0
SCX_WRAPPER

install -Dm644 /dev/stdin /etc/systemd/system/lenovo-v15g2-scx-server.service << 'SCX_SVC'
[Unit]
Description=sched_ext server scheduler - Lenovo V15 G2 ITL ServerMax
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

# Use scx_loader if available (preferred - handles kernel upgrades cleanly),
# otherwise use our direct service.
if systemctl list-unit-files scx_loader.service &>/dev/null 2>&1; then
  mkdir -p /etc/scx_loader
  cat > /etc/scx_loader/config.toml << 'SCX_CFG'
default_sched = "scx_bpfland"
default_mode  = "Server"
SCX_CFG
  systemctl daemon-reload
  systemctl enable --now scx_loader.service || true
  systemctl disable lenovo-v15g2-scx-server.service 2>/dev/null || true
else
  systemctl daemon-reload
  systemctl enable --now lenovo-v15g2-scx-server.service || true
fi

echo "========== APPLY SYSCTL + UDEV =========="
sysctl --system       || true
udevadm control --reload-rules || true
udevadm trigger       || true

echo "========== CONFIGURE GRUB =========="

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

# GRUB cmdline: deduplicate existing params then append ours
GRUB_CMDLINE_ADD="i915.enable_guc=3 zswap.enabled=1 zswap.shrinker_enabled=1 zswap.compressor=zstd zswap.max_pool_percent=20 zswap.zpool=z3fold mitigations=auto intel_pstate=active"

if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
  CURRENT="$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub | \
    sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"/\1/')"

  # Strip any previous copies of each param we're about to add
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

echo "========== ENSURE LZ4 IN INITRAMFS =========="
if [ -f /etc/initramfs-tools/modules ]; then
  grep -qxF "lz4" /etc/initramfs-tools/modules || echo "lz4" >> /etc/initramfs-tools/modules
fi

echo "========== UPDATE INITRAMFS + GRUB =========="
update-initramfs -u -k all
update-grub

echo "========== SET SERVERMAX KERNEL AS GRUB DEFAULT =========="

TARGET_KERNEL="$(
  ls /boot/vmlinuz-*cachyos-edge-lenovov15g2-servermax* 2>/dev/null |
    sed 's|/boot/vmlinuz-||' |
    sort -V |
    tail -n1
)"

if [ -z "${TARGET_KERNEL:-}" ]; then
  echo "ERROR: ServerMax CachyOS kernel not found in /boot"
  ls -lh /boot/vmlinuz-* || true
  exit 1
fi

echo "Target kernel: $TARGET_KERNEL"

SUBMENU="$(awk -F"'" '/submenu / {print $2; exit}' /boot/grub/grub.cfg || true)"

# Use index() for fixed-string matching - kernel version contains dots which
# are regex wildcards and would produce wrong matches with $0 ~ k
ENTRY="$(awk -F"'" -v k="$TARGET_KERNEL" \
  '/menuentry / && index($0, k) {print $2; exit}' /boot/grub/grub.cfg || true)"

if [ -z "${ENTRY:-}" ]; then
  echo "ERROR: GRUB menuentry not found for $TARGET_KERNEL"
  awk -F"'" '/menuentry / {print $2}' /boot/grub/grub.cfg || true
  exit 1
fi

if [ -n "${SUBMENU:-}" ]; then
  GRUB_ENTRY="${SUBMENU}>${ENTRY}"
else
  GRUB_ENTRY="${ENTRY}"
fi

echo "Setting GRUB default: $GRUB_ENTRY"
grub-set-default "$GRUB_ENTRY"

echo "========== VERIFY GRUB SAVED ENTRY =========="
grub-editenv list || true

echo "========== RECORD INSTALLED TAG =========="
echo "$TAG" > "$LAST_TAG_FILE"

echo "========== FINAL PACKAGE STATE =========="
dpkg -l | grep -iE 'cachyos|linux-image|linux-headers' || true
ls -lh /boot | grep -E 'cachyos|vmlinuz|initrd' || true

echo "========== FINAL NOTES =========="
echo "Installed:   $TAG"
echo "GRUB target: $TARGET_KERNEL"
echo "Backup dir:  $BACKUP_DIR"
echo "Rebooting..."

echo "========== REBOOT =========="
sync
systemctl reboot
