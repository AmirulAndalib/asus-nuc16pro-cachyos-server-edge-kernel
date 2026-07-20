#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

WORK="/work"
BUILD="$WORK/build/scx"
DIST="$WORK/dist"

SCX_TAG="${SCX_TAG:?SCX_TAG env var required, e.g. v1.1.1}"

# These six schedulers come from sched-ext/scx. scx_loader/scxctl live in the separate
# sched-ext/scx-loader repo and are built in a dedicated step further down. The device's
# start script still runs a scheduler directly as a fallback if scx_loader is absent.
SCX_BINARIES=(scx_flash scx_bpfland scx_p2dq scx_rusty scx_beerland scx_lavd)

msg() { echo ":: $*"; }

msg "container info"
date
uname -a
clang --version || true

msg "installing rustup"
# Distro rustc lags crates.io MSRV (apt rustc 1.93 vs sysinfo crate in scx's
# own Cargo.lock requiring rustc 1.95+, observed 2026-06-21). rustup's stable
# channel is installed fresh here every run rather than baked into the image,
# so a Docker layer-cache hit can never serve a stale toolchain.
export RUSTUP_HOME="${RUSTUP_HOME:-/root/.rustup}"
export CARGO_HOME="${CARGO_HOME:-/root/.cargo}"
curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | \
  sh -s -- -y --profile minimal --default-toolchain stable
export PATH="$CARGO_HOME/bin:$PATH"
rustc --version
cargo --version

msg "cloning sched-ext/scx at $SCX_TAG"
mkdir -p "$WORK/build"
rm -rf "$BUILD"
git clone --depth=1 --branch "$SCX_TAG" https://github.com/sched-ext/scx.git "$BUILD"
SCX_COMMIT="$(git -C "$BUILD" rev-parse --short HEAD)"
echo "scx commit: $SCX_COMMIT"

msg "building: ${SCX_BINARIES[*]}"
cd "$BUILD"
PKG_ARGS=()
for b in "${SCX_BINARIES[@]}"; do
  PKG_ARGS+=(-p "$b")
done
cargo build --release --locked "${PKG_ARGS[@]}"

msg "building scx_loader + scxctl (sched-ext/scx-loader control plane)"
# scx_loader is the DBus on-demand scheduler loader; scxctl is its CLI. They live in a
# separate repo, version-aligned with scx. Build the matching tag; fall back to the
# default branch if that tag is absent.
LOADER_SRC="$WORK/build/scx-loader"
rm -rf "$LOADER_SRC"
if git clone --depth=1 --branch "$SCX_TAG" https://github.com/sched-ext/scx-loader.git "$LOADER_SRC" 2>/dev/null; then
  echo "scx-loader at tag $SCX_TAG"
else
  echo "scx-loader has no $SCX_TAG tag; using default branch"
  git clone --depth=1 https://github.com/sched-ext/scx-loader.git "$LOADER_SRC"
fi
LOADER_COMMIT="$(git -C "$LOADER_SRC" rev-parse --short HEAD)"
( cd "$LOADER_SRC" && cargo build --release --locked -p scx_loader -p scxctl )

msg "collecting binaries"
rm -rf "$DIST"
mkdir -p "$DIST"
MISSING=()
for b in "${SCX_BINARIES[@]}"; do
  if [ -x "target/release/$b" ]; then
    cp -v "target/release/$b" "$DIST/"
  else
    MISSING+=("$b")
  fi
done

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "error: missing expected binaries after build: ${MISSING[*]}"
  ls -la target/release/ 2>/dev/null | grep -E '^-..x' || true
  exit 1
fi

msg "collecting scx_loader + scxctl + service/dbus/polkit files"
install -m755 "$LOADER_SRC/target/release/scx_loader" "$DIST/scx_loader"
install -m755 "$LOADER_SRC/target/release/scxctl"     "$DIST/scxctl"
# Ship upstream's systemd unit + DBus activation/policy + polkit action, patched from
# /usr/bin -> /usr/local/bin to match where the updater installs the binaries.
sed 's#/usr/bin/scx_loader#/usr/local/bin/scx_loader#g' "$LOADER_SRC/services/scx_loader.service"     > "$DIST/scx_loader.service"
sed 's#/usr/bin/scx_loader#/usr/local/bin/scx_loader#g' "$LOADER_SRC/services/org.scx.Loader.service" > "$DIST/org.scx.Loader.service"
cp "$LOADER_SRC/configs/org.scx.Loader.conf"   "$DIST/org.scx.Loader.conf"
cp "$LOADER_SRC/configs/org.scx.Loader.policy" "$DIST/org.scx.Loader.policy"

msg "smoke test (does each binary even start)"
for b in "${SCX_BINARIES[@]}"; do
  "$DIST/$b" --help >/dev/null 2>&1 || "$DIST/$b" --version >/dev/null 2>&1 || {
    echo "error: $b did not respond to --help or --version"
    exit 1
  }
  echo "  ok: $b"
done
for b in scx_loader scxctl; do
  "$DIST/$b" --help >/dev/null 2>&1 || "$DIST/$b" --version >/dev/null 2>&1 || {
    echo "error: $b did not respond to --help or --version"
    exit 1
  }
  echo "  ok: $b"
done

cd "$DIST"
sha256sum -- * > SHA256SUMS

msg "build manifest"
RUST_VER="$(rustc --version)"
CLANG_VER="$(clang --version 2>/dev/null | head -1 || echo unknown)"
cat > BUILD_MANIFEST << MANIFEST
SCX_TAG="${SCX_TAG}"
SCX_COMMIT="${SCX_COMMIT}"
RUST_VERSION="${RUST_VER}"
CLANG_VERSION="${CLANG_VER}"
BUILD_DATE_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TARGET="x86_64-unknown-linux-gnu"
BASE_IMAGE="ubuntu:26.04"
BINARIES="${SCX_BINARIES[*]} scx_loader scxctl"
SCX_LOADER_COMMIT="${LOADER_COMMIT}"
MANIFEST

cat BUILD_MANIFEST

msg "final assets"
ls -lh
cat SHA256SUMS

msg "fixing ownership"
if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
  chown -R "${HOST_UID}:${HOST_GID}" "$WORK" || true
fi
