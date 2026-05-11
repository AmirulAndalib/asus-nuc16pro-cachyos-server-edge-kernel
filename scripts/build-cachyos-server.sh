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

echo "========== CONTAINER INFO =========="
date
uname -a
dpkg --print-architecture
dpkg --print-foreign-architectures || true
df -h
free -h

echo "========== TOOLCHAIN INFO =========="
clang --version       || true
ld.lld --version      || true
x86_64-linux-gnu-gcc --version | head -2 || true
pahole --version      || true
ccache --version      || true
make --version | head -2 || true

echo "========== CCACHE SETUP =========="
export CCACHE_DIR="${CCACHE_DIR:-/ccache}"
export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-30G}"
export CCACHE_COMPILERCHECK=content
ccache --zero-stats || true
ccache -s           || true

echo "========== FETCH CACHYOS PKGBUILD + CONFIG =========="
rm -rf "$BUILD"
mkdir -p "$CACHY_PKG"
git clone --depth=1 https://github.com/CachyOS/linux-cachyos.git "$CACHY_PKG"

CACHY_COMMIT="$(git -C "$CACHY_PKG" rev-parse --short HEAD)"
PKGBUILD_DIR="$CACHY_PKG/$CACHY_VARIANT"

if [ ! -d "$PKGBUILD_DIR" ]; then
  echo "ERROR: variant directory not found: $PKGBUILD_DIR"
  echo "Available variants:"
  find "$CACHY_PKG" -maxdepth 1 -type d -name 'linux-cachyos*' -printf '  %f\n' | sort
  exit 1
fi

echo "linux-cachyos commit: $CACHY_COMMIT"
echo "Using variant:        $CACHY_VARIANT"

echo "========== PARSE PKGBUILD =========="
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
  echo "ERROR: pkgver could not be expanded - check PKGBUILD"
  head -50 "$PKGBUILD_DIR/PKGBUILD"
  exit 1
fi

echo "CachyOS kernel: ${KVER}-${PKGREL}"

mapfile -t SOURCE_ITEMS < <(
  _pkgbuild_subshell 'printf "%s\n" "${source[@]+${source[@]}}"'
)

echo "Expanded PKGBUILD source items:"
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
  echo "ERROR: no tarball URL in PKGBUILD source array"
  printf '%s\n' "${SOURCE_ITEMS[@]}"
  exit 1
fi

echo "Tarball URL: $TARBALL_URL"
echo "Patch URLs (${#PATCH_URLS[@]}):"
printf '  %s\n' "${PATCH_URLS[@]+"${PATCH_URLS[@]}"}"

echo "========== DOWNLOAD KERNEL =========="
cd "$BUILD"
TARBALL_FILE="$(basename "$TARBALL_URL" | sed 's/[?#].*//')"
wget -q --show-progress -O "$TARBALL_FILE" "$TARBALL_URL"
echo "Extracting $TARBALL_FILE ..."
tar -xf "$TARBALL_FILE"
rm -f "$TARBALL_FILE"

echo "========== DETECT KERNEL SOURCE TREE =========="
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
  echo "ERROR: kernel source directory not found after extraction"
  ls -la "$BUILD"
  find "$BUILD" -maxdepth 5 -type f -path '*/scripts/config' -print
  exit 1
fi

echo "Source tree: $LINUX_SRC"
cd "$LINUX_SRC"

echo "========== APPLY CACHYOS PATCHES =========="
PATCH_FAIL=0
if [ "${#PATCH_URLS[@]}" -eq 0 ]; then
  echo "No patch URLs found in PKGBUILD."
else
  for url in "${PATCH_URLS[@]}"; do
    name="$(basename "$url" | sed 's/[?#].*//')"
    echo "  -> $name"
    if ! curl -fsSL -o "/tmp/${name}" "$url"; then
      echo "WARN: download failed: $url"; PATCH_FAIL=1; continue
    fi
    if ! patch -p1 --forward --fuzz=3 -r /dev/null < "/tmp/${name}"; then
      echo "WARN: patch failed or already applied: $name"; PATCH_FAIL=1
    fi
  done
fi
[ "$PATCH_FAIL" -ne 0 ] && echo "WARN: partial patchset - continuing."

echo "========== SETUP BASE CONFIG =========="
if [ ! -f "$PKGBUILD_DIR/config" ]; then
  echo "ERROR: base config missing: $PKGBUILD_DIR/config"
  find "$PKGBUILD_DIR" -maxdepth 2 -type f | sort
  exit 1
fi
cp "$PKGBUILD_DIR/config" .config
chmod +x ./scripts/config

echo "========== APPLY LENOVO V15 G2 ITL SERVERMAX TWEAKS =========="

# LOCALVERSION must be set via scripts/config (string, not boolean)
./scripts/config --set-str LOCALVERSION "-cachyos-edge-lenovov15g2-servermax"

# Use a config fragment + merge_config.sh for everything else.
# scripts/config writes raw .config but does NOT understand Kconfig choice
# semantics correctly - olddefconfig can revert choice transitions.
# merge_config.sh is the kernel's official fragment merger - it processes
# the fragment through Kconfig and resolves choice blocks properly.

cat > /tmp/servermax.config << 'FRAGMENT'
# ---- Timer frequency: 100 Hz (lowest overhead server) ----
CONFIG_HZ_100=y
CONFIG_HZ=100
# CONFIG_HZ_250 is not set
# CONFIG_HZ_300 is not set
# CONFIG_HZ_500 is not set
# CONFIG_HZ_600 is not set
# CONFIG_HZ_750 is not set
# CONFIG_HZ_1000 is not set

# ---- LTO: ThinLTO ----
CONFIG_LTO=y
CONFIG_LTO_CLANG=y
CONFIG_LTO_CLANG_THIN=y
# CONFIG_LTO_NONE is not set
# CONFIG_LTO_CLANG_FULL is not set

# ---- Transparent Huge Pages: always ----
CONFIG_TRANSPARENT_HUGEPAGE=y
CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS=y
# CONFIG_TRANSPARENT_HUGEPAGE_MADVISE is not set
# CONFIG_TRANSPARENT_HUGEPAGE_NEVER is not set

# ---- IKCONFIG: expose running config via /proc/config.gz ----
CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y

# ---- BPF + sched_ext (requires DWARF debug info for BTF generation) ----
# CRITICAL: DEBUG_INFO_BTF requires DWARF. Disabling DWARF kills BTF
# which kills SCHED_CLASS_EXT which kills every scx_* scheduler.
CONFIG_BPF=y
CONFIG_BPF_SYSCALL=y
CONFIG_BPF_JIT=y
CONFIG_BPF_JIT_ALWAYS_ON=y
CONFIG_BPF_JIT_DEFAULT_ON=y
CONFIG_BPF_EVENTS=y
CONFIG_BPF_LSM=y
CONFIG_BPF_STREAM_PARSER=y
CONFIG_DEBUG_INFO=y
CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT=y
CONFIG_DEBUG_INFO_BTF=y
CONFIG_DEBUG_INFO_BTF_MODULES=y
CONFIG_SCHED_CLASS_EXT=y

# ---- AC-powered: no RCU lazy power-saving bias ----
# CONFIG_RCU_LAZY is not set

# ---- Network: BBR + FQ + io_uring + TLS + XDP ----
CONFIG_TCP_CONG_BBR=y
CONFIG_DEFAULT_TCP_CONG="bbr"
CONFIG_NET_SCH_FQ=m
CONFIG_NET_SCH_FQ_CODEL=y
CONFIG_IO_URING=y
CONFIG_TLS=m
CONFIG_TLS_DEVICE=y
CONFIG_XDP_SOCKETS=y
CONFIG_XDP_SOCKETS_DIAG=m

# ---- Full cgroup v2 stack (Docker / Podman / systemd) ----
CONFIG_CGROUPS=y
CONFIG_MEMCG=y
CONFIG_BLK_CGROUP=y
CONFIG_CGROUP_SCHED=y
CONFIG_FAIR_GROUP_SCHED=y
CONFIG_CFS_BANDWIDTH=y
CONFIG_RT_GROUP_SCHED=y
CONFIG_CGROUP_PIDS=y
CONFIG_CGROUP_RDMA=y
CONFIG_CGROUP_FREEZER=y
CONFIG_CGROUP_HUGETLB=y
CONFIG_CGROUP_DEVICE=y
CONFIG_CGROUP_CPUACCT=y
CONFIG_CGROUP_PERF=y
CONFIG_CGROUP_BPF=y
CONFIG_CGROUP_MISC=y
CONFIG_BLK_CGROUP_IOLATENCY=y
CONFIG_BLK_CGROUP_IOCOST=y
CONFIG_NETFILTER_XT_MATCH_CGROUP=m

# ---- Container namespaces ----
CONFIG_NAMESPACES=y
CONFIG_NET_NS=y
CONFIG_PID_NS=y
CONFIG_IPC_NS=y
CONFIG_UTS_NS=y
CONFIG_USER_NS=y
CONFIG_TIME_NS=y
CONFIG_CHECKPOINT_RESTORE=y
CONFIG_USERFAULTFD=y

# ---- Container networking ----
CONFIG_OVERLAY_FS=m
CONFIG_VETH=m
CONFIG_BRIDGE=m
CONFIG_BRIDGE_NETFILTER=m
CONFIG_VXLAN=m
CONFIG_IPVLAN=m
CONFIG_MACVLAN=m
CONFIG_NET_IPVTI=m

# ---- Firewall / NAT / nftables ----
CONFIG_NF_TABLES=m
CONFIG_NFT_CHAIN_NAT=m
CONFIG_NFT_MASQ=m
CONFIG_NFT_REDIR=m
CONFIG_NF_NAT=m
CONFIG_IP_NF_NAT=m
CONFIG_IP_NF_FILTER=m

# ---- Server/network filesystems ----
CONFIG_NFS_FS=m
CONFIG_NFSD=m
CONFIG_CIFS=m
CONFIG_BTRFS_FS=m
CONFIG_F2FS_FS=m
CONFIG_XFS_FS=m
CONFIG_EROFS_FS=m

# ---- Block I/O performance ----
CONFIG_BLK_WBT=y
CONFIG_BLK_WBT_MQ=y
CONFIG_BLK_INLINE_ENCRYPTION=y
CONFIG_NVME_MULTIPATH=y
CONFIG_IOSCHED_BFQ=m
CONFIG_MQ_IOSCHED_DEADLINE=y
CONFIG_IOSCHED_ADIOS=m
CONFIG_MQ_IOSCHED_ADIOS=m

# ---- Zswap: zstd (faster than lz4 for most workloads, kernel default) ----
CONFIG_ZSWAP=y
CONFIG_ZSWAP_DEFAULT_ON=y
CONFIG_ZSWAP_SHRINKER_DEFAULT_ON=y
CONFIG_ZSWAP_COMPRESSOR_DEFAULT_ZSTD=y
CONFIG_ZSWAP_COMPRESSOR_DEFAULT="zstd"
CONFIG_CRYPTO_ZSTD=y
CONFIG_ZSTD_COMPRESS=y
CONFIG_ZSTD_DECOMPRESS=y
CONFIG_CRYPTO_LZ4=y
CONFIG_LZ4_COMPRESS=y
CONFIG_LZ4_DECOMPRESS=y
CONFIG_Z3FOLD=y
CONFIG_ZSMALLOC=y

# ---- Intel Tiger Lake iGPU / Iris Xe / Quick Sync ----
CONFIG_DRM_I915=m
CONFIG_DRM_I915_GVT_KVMGT=m

# ---- Intel CPU power management ----
CONFIG_X86_INTEL_PSTATE=y
CONFIG_INTEL_IDLE=y
CONFIG_THERMAL=y
CONFIG_THERMAL_GOV_POWER_ALLOCATOR=y
CONFIG_INTEL_HFI_THERMAL=y
CONFIG_INTEL_RAPL=m

# ---- Wi-Fi: Intel AX201 ----
CONFIG_IWLWIFI=m
CONFIG_IWLMVM=m

# ---- Sound: Intel SOF / SoundWire / HDA ----
CONFIG_SND_SOC_SOF=m
CONFIG_SND_SOC_SOF_INTEL_SOUNDWIRE_LINK=y
CONFIG_SND_SOC_SOF_TIGERLAKE=m
CONFIG_SND_HDA_INTEL=m

# ---- Thunderbolt / USB4 ----
CONFIG_THUNDERBOLT=m
CONFIG_USB4=m

# ---- Intel PMT telemetry ----
CONFIG_INTEL_PMT_TELEMETRY=m
CONFIG_INTEL_PMT_CRASHLOG=m

# ---- PCIe performance ----
CONFIG_PCIEASPM=y
CONFIG_PCIEASPM_PERFORMANCE=y
CONFIG_PCIE_PTM=y

# ---- Misc performance ----
CONFIG_SCHED_AUTOGROUP=y
FRAGMENT

echo "Merging servermax fragment via scripts/kconfig/merge_config.sh ..."
chmod +x ./scripts/kconfig/merge_config.sh
./scripts/kconfig/merge_config.sh -m .config /tmp/servermax.config

echo "========== OLDDEFCONFIG =========="
make ARCH=x86_64 LLVM=1 LLVM_IAS=1 olddefconfig

echo "========== VERIFY CRITICAL CONFIG OPTIONS =========="
FAILED=0

_check_eq() {
  if ! grep -qE "^${1}=${2}$" .config; then
    echo "CRITICAL: ${1}=${2} not found - got: $(grep "^${1}=" .config 2>/dev/null || echo '(not set)')"
    FAILED=1
  fi
}
_check_ym() {
  if ! grep -qE "^${1}=[ym]$" .config; then
    echo "CRITICAL: ${1} not =y or =m - got: $(grep "^${1}=" .config 2>/dev/null || echo '(not set)')"
    FAILED=1
  fi
}
_warn_ym() {
  grep -qE "^${1}=[ym]$" .config || \
    echo "WARN: ${1} absent - $(grep "^${1}=" .config 2>/dev/null || echo '(not set)')"
}

_check_eq  CONFIG_HZ_100                      y
_check_eq  CONFIG_HZ                          100
_check_eq  CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS y
_check_eq  CONFIG_LTO_CLANG_THIN              y

_check_ym  CONFIG_DRM_I915
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
  echo "CRITICAL: PREEMPT_RT enabled - incompatible with server throughput"
  grep -E '^CONFIG_PREEMPT' .config || true
  FAILED=1
else
  PREEMPT_STATE="$(grep -E '^CONFIG_PREEMPT' .config | tr '\n' ' ' || echo '(none)')"
  echo "INFO: preemption model: $PREEMPT_STATE"
  echo "INFO: scx_bpfland --server provides server scheduling regardless."
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

if [ "$FAILED" -ne 0 ]; then
  echo "Aborting: critical config failure."
  grep -E \
    'CONFIG_HZ=|CONFIG_PREEMPT|CONFIG_LTO|CONFIG_TRANSPARENT_HUGEPAGE|CONFIG_DRM_I915|CONFIG_BBR|CONFIG_IWLWIFI|CONFIG_BPF|CONFIG_DEBUG_INFO_BTF|CONFIG_SCHED_CLASS_EXT|CONFIG_ZSWAP|CONFIG_IOSCHED_ADIOS' \
    .config || true
  exit 1
fi
echo "Critical config verified."

echo "========== CONFIG SUMMARY =========="
grep -E \
  'CONFIG_HZ=|CONFIG_HZ_100|CONFIG_PREEMPT|CONFIG_CC_IS_CLANG|CONFIG_LTO_CLANG_THIN|CONFIG_TRANSPARENT_HUGEPAGE=|CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS|CONFIG_DEFAULT_TCP_CONG|CONFIG_TCP_CONG_BBR=|CONFIG_DRM_I915=|CONFIG_IWLWIFI=|CONFIG_IWLMVM=|CONFIG_NET_SCH_FQ=|CONFIG_LOCALVERSION|CONFIG_OVERLAY_FS=|CONFIG_VETH=|CONFIG_BRIDGE=|CONFIG_BPF=|CONFIG_BPF_JIT=|CONFIG_DEBUG_INFO_BTF=|CONFIG_SCHED_CLASS_EXT=|CONFIG_ZSWAP=|CONFIG_IOSCHED_ADIOS=|CONFIG_RCU_LAZY=' \
  .config || true

echo "========== BUILD =========="
# ARCH=x86_64         - cross-target (container is ARM64)
# LLVM=1 LLVM_IAS=1   - full LLVM toolchain
# CROSS_COMPILE       - GNU prefix for any non-LLVM packaging tools
# CC                  - explicit x86_64 target in clang; ccache wraps transparently
# KCFLAGS             - march=x86-64-v3 even if GENERIC_CPU3 is absent from Kconfig
# KBUILD_DEBARCH=amd64 - prevent arm64-tagged debs from cross-build host
make ARCH=x86_64 LLVM=1 LLVM_IAS=1 \
  CROSS_COMPILE=x86_64-linux-gnu- \
  CC="ccache clang --target=x86_64-linux-gnu" \
  HOSTCC=gcc \
  KCFLAGS="-march=x86-64-v3 -mtune=generic" \
  KBUILD_DEBARCH=amd64 \
  KDEB_PKGVERSION="${KVER}-${PKGREL}-cachyos" \
  KBUILD_BUILD_USER=github \
  KBUILD_BUILD_HOST=actions \
  -j"$(nproc)" bindeb-pkg

echo "========== COLLECT RELEASE ASSETS =========="
rm -rf "$DIST"
mkdir -p "$DIST"
find "$BUILD" -maxdepth 3 -type f -name "*.deb" ! -name "*-dbg_*" -exec cp -v {} "$DIST/" \;

cd "$DIST"
ls linux-image-*.deb   >/dev/null 2>&1 || { echo "ERROR: no linux-image deb"; exit 1; }
ls linux-headers-*.deb >/dev/null 2>&1 || { echo "ERROR: no linux-headers deb"; exit 1; }
sha256sum *.deb > SHA256SUMS

echo "========== BUILD MANIFEST =========="
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
KERNEL_LOCALVERSION=-cachyos-edge-lenovov15g2-servermax
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
MANIFEST

cat BUILD_MANIFEST

echo "========== CCACHE STATS =========="
ccache -s || true

echo "========== FINAL ASSETS =========="
ls -lh
cat SHA256SUMS

echo "========== FIX OWNERSHIP =========="
if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
  chown -R "${HOST_UID}:${HOST_GID}" /work || true
fi
