#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export TZ=Pacific/Auckland

WORK="/work"
BUILD="/work/build"
DIST="/work/dist"
CACHY_PKG="$BUILD/cachy-pkg"

# linux-cachyos-server = stable server variant with server-optimized base config (default)
# linux-cachyos-rc     = bleeding-edge RC/mainline (override via CACHY_VARIANT env)
CACHY_VARIANT="${CACHY_VARIANT:-linux-cachyos-server}"

msg() { echo ":: $*"; }

msg "container info"
date
uname -a
dpkg --print-architecture
df -h
free -h

msg "toolchain"
clang --version       || true
ld.lld --version      || true
pahole --version      || true
ccache --version      || true
make --version | head -2 || true

msg "ccache setup"
export CCACHE_DIR="${CCACHE_DIR:-/ccache}"
export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-8G}"
# Level 1: fastest compression; ccache objects are already zstd-compressed
# so outer compression gains little regardless of level.
export CCACHE_COMPRESSLEVEL="${CCACHE_COMPRESSLEVEL:-1}"
# time_macros: kernel uses KBUILD_BUILD_TIMESTAMP for reproducibility so
# __DATE__/__TIME__ macros are already neutralised.
# locale: no locale-dependent output from clang for kernel builds.
export CCACHE_SLOPPINESS="${CCACHE_SLOPPINESS:-time_macros,locale}"
export CCACHE_COMPILERCHECK=content
ccache --zero-stats || true
ccache -s           || true

msg "fetching cachyos pkgbuild"
rm -rf "$BUILD"
mkdir -p "$CACHY_PKG"
git clone --depth=1 https://github.com/CachyOS/linux-cachyos.git "$CACHY_PKG"

CACHY_COMMIT="$(git -C "$CACHY_PKG" rev-parse --short HEAD)"
PKGBUILD_DIR="$CACHY_PKG/$CACHY_VARIANT"

if [ ! -d "$PKGBUILD_DIR" ]; then
  echo "error: variant directory not found: $PKGBUILD_DIR"
  echo "available variants:"
  find "$CACHY_PKG" -maxdepth 1 -type d -name 'linux-cachyos*' -printf '  %f\n' | sort
  exit 1
fi

echo "commit:  $CACHY_COMMIT"
echo "variant: $CACHY_VARIANT"

msg "parsing pkgbuild"
# Source PKGBUILD in an isolated subshell so bash expands pkgver=${_major}.${_minor}
# and similar composed variables. Lifecycle functions are stubbed.
_pkgbuild_subshell() {
  bash -c "
    cd '$PKGBUILD_DIR'
    prepare() { true; }
    build()   { true; }
    package() { true; }
    source PKGBUILD 2>/dev/null || true
    $1
  " 2>/dev/null
}

KVER="$(   _pkgbuild_subshell 'printf "%s" "${pkgver:-}"' | tr -d $'\n')"
PKGREL="$( _pkgbuild_subshell 'printf "%s" "${pkgrel:-1}"' | tr -d $'\n')"
PKGREL="${PKGREL:-1}"

if [ -z "${KVER:-}" ]; then
  echo "error: pkgver could not be expanded - check PKGBUILD"
  head -50 "$PKGBUILD_DIR/PKGBUILD"
  exit 1
fi

echo "kernel: ${KVER}-${PKGREL}"

mapfile -t SOURCE_ITEMS < <(
  _pkgbuild_subshell 'printf "%s\n" "${source[@]+${source[@]}}"'
)

echo "pkgbuild source items:"
printf '  %s\n' "${SOURCE_ITEMS[@]}"

mapfile -t PATCH_URLS < <(
  printf '%s\n' "${SOURCE_ITEMS[@]}" |
    grep -oP 'https://[^\s"'"'"']+\.patch([?#][^\s"'"'"']*)?' || true
)

TARBALL_URL="$(
  printf '%s\n' "${SOURCE_ITEMS[@]}" |
    grep -oP 'https://[^\s"'"'"']+\.tar\.(xz|gz|bz2)([?#][^\s"'"'"']*)?' |
    head -1 || true
)"

if [ -z "${TARBALL_URL:-}" ]; then
  echo "error: no tarball URL in PKGBUILD source array"
  printf '%s\n' "${SOURCE_ITEMS[@]}"
  exit 1
fi

echo "tarball: $TARBALL_URL"
echo "patches (${#PATCH_URLS[@]}):"
printf '  %s\n' "${PATCH_URLS[@]+"${PATCH_URLS[@]}"}"

msg "downloading kernel source"
cd "$BUILD"
TARBALL_FILE="$(basename "$TARBALL_URL" | sed 's/[?#].*//')"
wget -q --show-progress -O "$TARBALL_FILE" "$TARBALL_URL"
echo "extracting $TARBALL_FILE..."
tar -xf "$TARBALL_FILE"
rm -f "$TARBALL_FILE"

msg "detecting kernel source tree"
LINUX_SRC="$(
  find "$BUILD" -mindepth 1 -maxdepth 2 -type f -name Makefile \
    ! -path "$CACHY_PKG/*" \
    -printf '%h\n' |
    while read -r candidate; do
      if [ -f "$candidate/scripts/config" ]; then
        printf '%s\n' "$candidate"
        break
      fi
    done
)"

if [ -z "${LINUX_SRC:-}" ]; then
  echo "error: kernel source directory not found after extraction"
  ls -la "$BUILD"
  find "$BUILD" -maxdepth 5 -type f -path '*/scripts/config' -print
  exit 1
fi

echo "source: $LINUX_SRC"
cd "$LINUX_SRC"
# Normalise the version-specific directory prefix out of ccache hash keys so
# objects from linux-7.0.11 are reused for linux-7.0.12 when source is identical.
# Without this every kernel version bump = 0% cache hits because the source path
# embeds the version (e.g. /work/build/linux-7.0.12/...).
export CCACHE_BASEDIR="$LINUX_SRC"

msg "applying cachyos patches"
PATCH_FAIL=0
if [ "${#PATCH_URLS[@]}" -eq 0 ]; then
  echo "no patch URLs in PKGBUILD"
else
  for url in "${PATCH_URLS[@]}"; do
    name="$(basename "$url" | sed 's/[?#].*//')"
    echo "  -> $name"
    if ! curl -fsSL -o "/tmp/${name}" "$url"; then
      echo "warn: download failed: $url"; PATCH_FAIL=1; continue
    fi
    if ! patch -p1 --forward --fuzz=3 -r /dev/null < "/tmp/${name}"; then
      echo "warn: patch failed or already applied: $name"; PATCH_FAIL=1
    fi
  done
fi
[ "$PATCH_FAIL" -ne 0 ] && echo "warn: partial patchset - continuing"

msg "applying custom patches"
# Fail-hard: any patch that does not apply cleanly aborts the build.
# patches/*.patch are applied in version-sort order after the CachyOS patchset.
while IFS= read -r -d '' patch_file; do
  name="$(basename "$patch_file")"
  echo "  -> $name"
  patch -p1 --forward --fuzz=0 < "$patch_file"
done < <(find /work/patches -maxdepth 1 -name '*.patch' -type f -print0 | sort -zV)
echo "custom patches: done"

msg "base config"
if [ ! -f "$PKGBUILD_DIR/config" ]; then
  echo "error: base config missing: $PKGBUILD_DIR/config"
  find "$PKGBUILD_DIR" -maxdepth 2 -type f | sort
  exit 1
fi
cp "$PKGBUILD_DIR/config" .config
chmod +x ./scripts/config

msg "applying servermax config tweaks"

# LOCALVERSION must be set via scripts/config (string, not boolean)
./scripts/config --set-str LOCALVERSION "-cachyos-edge-nuc16pro-servermax"

# Use merge_config.sh for everything else - it processes the fragment through
# Kconfig and resolves choice blocks properly. scripts/config does not understand
# Kconfig choice semantics; olddefconfig can revert choice transitions.
cp /work/config/servermax.config /tmp/servermax.config

echo "merging servermax fragment..."
chmod +x ./scripts/kconfig/merge_config.sh
./scripts/kconfig/merge_config.sh -m .config /tmp/servermax.config

msg "olddefconfig"
make ARCH=x86_64 LLVM=1 LLVM_IAS=1 olddefconfig

msg "verifying critical config options"
FAILED=0

_check_eq() {
  if ! grep -qE "^${1}=${2}$" .config; then
    echo "config fail: ${1}=${2} not found - got: $(grep "^${1}=" .config 2>/dev/null || echo '(not set)')"
    FAILED=1
  fi
}
_check_ym() {
  if ! grep -qE "^${1}=[ym]$" .config; then
    echo "config fail: ${1} not =y or =m - got: $(grep "^${1}=" .config 2>/dev/null || echo '(not set)')"
    FAILED=1
  fi
}
_warn_ym() {
  grep -qE "^${1}=[ym]$" .config || \
    echo "warn: ${1} absent - $(grep "^${1}=" .config 2>/dev/null || echo '(not set)')"
}

_check_eq  CONFIG_HZ_100                      y
_check_eq  CONFIG_HZ                          100
_check_eq  CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS y
_check_eq  CONFIG_LTO_CLANG_THIN              y

_check_ym  CONFIG_TCP_CONG_BBR
_check_ym  CONFIG_IWLWIFI
_check_ym  CONFIG_IWLMVM
_check_ym  CONFIG_OVERLAY_FS
_check_ym  CONFIG_VETH
_check_ym  CONFIG_BRIDGE
_check_ym  CONFIG_BPF
_check_ym  CONFIG_BPF_SYSCALL
_check_ym  CONFIG_BPF_JIT
_check_ym  CONFIG_DEBUG_INFO_BTF
_check_ym  CONFIG_SCHED_CLASS_EXT
_check_ym  CONFIG_IO_URING
_check_ym  CONFIG_MEMCG
_check_ym  CONFIG_CFS_BANDWIDTH
_check_ym  CONFIG_ZSWAP

# PREEMPT_RT is incompatible with server throughput - fail hard.
# PREEMPT_BUILD / PREEMPT_DYNAMIC are acceptable: scx_bpfland --server
# delivers server-optimized scheduling regardless of static preemption model.
# CachyOS server 7.x uses PREEMPT_BUILD as its base; PREEMPT_NONE_BUILD is
# not a valid Kconfig symbol in this kernel tree.
if grep -qE '^CONFIG_PREEMPT_RT=y' .config; then
  echo "config fail: PREEMPT_RT enabled - incompatible with server throughput"
  grep -E '^CONFIG_PREEMPT' .config || true
  FAILED=1
else
  PREEMPT_STATE="$(grep -E '^CONFIG_PREEMPT' .config | tr '\n' ' ' || echo '(none)')"
  echo "preemption: $PREEMPT_STATE"
  echo "info: scx_bpfland --server provides server scheduling regardless"
fi

_warn_ym CONFIG_NET_SCH_FQ
_warn_ym CONFIG_NF_TABLES
_warn_ym CONFIG_BRIDGE_NETFILTER
_warn_ym CONFIG_IOSCHED_ADIOS
_warn_ym CONFIG_MQ_IOSCHED_ADIOS
_warn_ym CONFIG_TLS
_warn_ym CONFIG_XDP_SOCKETS
_warn_ym CONFIG_NVME_MULTIPATH
_warn_ym CONFIG_BLK_WBT
_warn_ym CONFIG_CHECKPOINT_RESTORE
_warn_ym CONFIG_INTEL_RAPL
_warn_ym CONFIG_POWERCAP
_warn_ym CONFIG_INTEL_RAPL_CORE
_warn_ym CONFIG_ACPI_PLATFORM_PROFILE
_warn_ym CONFIG_ASUS_WMI
_warn_ym CONFIG_HWMON
_warn_ym CONFIG_SENSORS_CORETEMP
# NUC 16 Pro / Panther Lake specific, soft checks (CachyOS base config may vary)
_warn_ym CONFIG_DRM_XE
_warn_ym CONFIG_DRM_I915
_warn_ym CONFIG_IGC
_warn_ym CONFIG_DRM_ACCEL_IVPU
_warn_ym CONFIG_IWLMEI
_warn_ym CONFIG_INTEL_UNCORE_FREQ_CONTROL
_warn_ym CONFIG_INTEL_SPEED_SELECT_INTERFACE
_warn_ym CONFIG_NET_SCH_MULTIQ

if [ "$FAILED" -ne 0 ]; then
  echo "aborting: critical config failure"
  grep -E \
    'CONFIG_HZ=|CONFIG_PREEMPT|CONFIG_LTO|CONFIG_TRANSPARENT_HUGEPAGE|CONFIG_DRM_XE|CONFIG_DRM_I915|CONFIG_BBR|CONFIG_IWLWIFI|CONFIG_BPF|CONFIG_DEBUG_INFO_BTF|CONFIG_SCHED_CLASS_EXT|CONFIG_ZSWAP|CONFIG_IOSCHED_ADIOS|CONFIG_IGC' \
    .config || true
  exit 1
fi
echo "critical config ok"

msg "config summary"
grep -E \
  'CONFIG_HZ=|CONFIG_HZ_100|CONFIG_PREEMPT|CONFIG_CC_IS_CLANG|CONFIG_LTO_CLANG_THIN|CONFIG_TRANSPARENT_HUGEPAGE=|CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS|CONFIG_DEFAULT_TCP_CONG|CONFIG_TCP_CONG_BBR=|CONFIG_DRM_XE=|CONFIG_DRM_I915=|CONFIG_IGC=|CONFIG_DRM_ACCEL_IVPU=|CONFIG_IWLWIFI=|CONFIG_IWLMVM=|CONFIG_IWLMEI=|CONFIG_NET_SCH_FQ=|CONFIG_LOCALVERSION|CONFIG_OVERLAY_FS=|CONFIG_VETH=|CONFIG_BRIDGE=|CONFIG_BPF=|CONFIG_BPF_JIT=|CONFIG_DEBUG_INFO_BTF=|CONFIG_SCHED_CLASS_EXT=|CONFIG_ZSWAP=|CONFIG_IOSCHED_ADIOS=|CONFIG_RCU_LAZY=|CONFIG_INTEL_UNCORE_FREQ_CONTROL=' \
  .config || true

msg "build"
# Parallel jobs = nproc (4 vCPUs on GHA ubuntu-latest). The pahole/BTF peak is
# single-process; OOM comes from that spike, not from parallel compilation.
# BUILD_JOBS lets a caller dial down parallelism without editing this script.
JOBS="${BUILD_JOBS:-$(nproc)}"
echo "build jobs: ${JOBS} (nproc=$(nproc), BUILD_JOBS=${BUILD_JOBS:-unset})"

# ARCH=x86_64         - explicit target (matches KBUILD_DEBARCH, prevents ambiguity)
# LLVM=1 LLVM_IAS=1   - full LLVM toolchain (clang + lld + llvm-ar etc.)
# CC                  - ccache wraps clang transparently; no cross target needed
# KCFLAGS             - march=x86-64-v3 even if GENERIC_CPU3 is absent from Kconfig
# KBUILD_DEBARCH=amd64 - ensures amd64-tagged debs on the native x86-64 host
make ARCH=x86_64 LLVM=1 LLVM_IAS=1 \
  CC="ccache clang" \
  KCFLAGS="-march=x86-64-v3 -mtune=generic" \
  KBUILD_DEBARCH=amd64 \
  KDEB_PKGVERSION="${KVER}-${PKGREL}-cachyos" \
  KBUILD_BUILD_USER=github \
  KBUILD_BUILD_HOST=actions \
  -j"${JOBS}" bindeb-pkg

msg "collecting release assets"
rm -rf "$DIST"
mkdir -p "$DIST"
find "$BUILD" -maxdepth 3 -type f -name "*.deb" ! -name "*-dbg_*" -exec cp -v {} "$DIST/" \;

cd "$DIST"
ls linux-image-*.deb   >/dev/null 2>&1 || { echo "error: no linux-image deb"; exit 1; }
ls linux-headers-*.deb >/dev/null 2>&1 || { echo "error: no linux-headers deb"; exit 1; }
sha256sum *.deb > SHA256SUMS

msg "build manifest"
CLANG_VER="$(clang   --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")"
LLD_VER="$(  ld.lld  --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")"

cat > BUILD_MANIFEST << MANIFEST
CLANG_VERSION=${CLANG_VER}
LLD_VERSION=${LLD_VER}
KERNEL_VERSION=${KVER}
PKGREL=${PKGREL}
CACHY_COMMIT=${CACHY_COMMIT}
CACHY_VARIANT=${CACHY_VARIANT}
BUILD_DATE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
KERNEL_LOCALVERSION=-cachyos-edge-nuc16pro-servermax
SCHEDULER=eevdf-servermax
SCHED_EXT=compiled-in-scx_bpfland-server-auto-enabled
CPU_TARGET=x86-64-v3
TIMER_HZ=100
LTO=ThinLTO
THP=always
PREEMPT=preempt_build-scx_bpfland_server
ZSWAP=zstd-z3fold-20pct
IO_SCHEDULER=adios-best-effort
CPU_POLICY=performance-governor-epp-performance
IO_URING=enabled
TLS_OFFLOAD=enabled
XDP_SOCKETS=enabled
NVME_MULTIPATH=enabled
CGROUP_V2=full
RCU_LAZY=disabled
BASE=cachyos-server
GPU_DRIVER=xe-pantherlake-xe3lp
ETH_DRIVER=igc-i226v-2500mbps
NPU=ivpu-pantherlake-50tops
WIFI=iwlwifi-be211-wifi7
POWER_LIMITS=rapl-pl1-104w-pl2-104w-224s
PLATFORM_PROFILE=performance
USB_AUTOSUSPEND=disabled
MANIFEST

cat BUILD_MANIFEST

msg "ccache stats"
ccache -s || true

msg "final assets"
ls -lh
cat SHA256SUMS

msg "fixing ownership"
if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
  chown -R "${HOST_UID}:${HOST_GID}" /work || true
fi
