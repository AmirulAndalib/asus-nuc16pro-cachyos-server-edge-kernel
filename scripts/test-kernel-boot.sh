#!/usr/bin/env bash
# Boot-smoke-test: boot the built kernel in QEMU/KVM with a minimal busybox initramfs.
# Exit 0 when the kernel boots to init and prints BOOT_TEST_SUCCESS; exit 1 otherwise.
#
# Usage: test-kernel-boot.sh [dist-dir]
# Requires: qemu-system-x86_64 (with KVM), busybox-static (for the initrd), dpkg
set -euo pipefail

DIST="${1:-/work/dist}"
TIMEOUT_SECS=180

# Find the linux-image .deb (exclude debug variant)
DEB="$(find "$DIST" -maxdepth 1 -name 'linux-image-*.deb' ! -name '*-dbg_*' | head -1)"
if [ -z "$DEB" ]; then
  echo "boot-test: error: no linux-image .deb in $DIST" >&2
  exit 1
fi
echo "boot-test: deb = $(basename "$DEB")"

# Extract vmlinuz without installing the package
EXTRACT_DIR="$(mktemp -d /tmp/boot-extract-XXXXXX)"
dpkg -x "$DEB" "$EXTRACT_DIR"
VMLINUZ="$(find "$EXTRACT_DIR/boot" -name 'vmlinuz-*' | head -1)"
if [ -z "$VMLINUZ" ]; then
  echo "boot-test: error: vmlinuz not found in $DEB" >&2
  ls -la "$EXTRACT_DIR/boot/" || true
  rm -rf "$EXTRACT_DIR"
  exit 1
fi
echo "boot-test: vmlinuz = $(basename "$VMLINUZ")"

# Build a minimal CPIO initramfs: busybox static + a 3-line init.
# init prints BOOT_TEST_SUCCESS (our success signal) then poweroffs.
# poweroff calls reboot(LINUX_REBOOT_CMD_POWER_OFF); QEMU exits with -no-reboot.
INITRD_DIR="$(mktemp -d /tmp/boot-initrd-XXXXXX)"
mkdir -p "$INITRD_DIR/bin"
cp /bin/busybox "$INITRD_DIR/bin/busybox"
"$INITRD_DIR/bin/busybox" --install "$INITRD_DIR/bin/"

cat > "$INITRD_DIR/init" <<'INIT'
#!/bin/sh
echo "BOOT_TEST_SUCCESS"
poweroff -f
INIT
chmod +x "$INITRD_DIR/init"

INITRD_IMG="$(mktemp /tmp/initrd-XXXXXX.cpio.gz)"
(cd "$INITRD_DIR" && find . | cpio -o -H newc 2>/dev/null | gzip -1 > "$INITRD_IMG")
rm -rf "$INITRD_DIR"
echo "boot-test: initrd = $(wc -c < "$INITRD_IMG") bytes"

# Boot kernel in QEMU/KVM.
# -cpu host      pass through host CPU features (kernel needs AVX2/BMI2 for x86-64-v3)
# -no-reboot     QEMU exits when guest poweroffs (clean) or panics+reboots (via panic=1)
# -display none  no graphics
# panic=1        kernel reboots 1 s after any panic so QEMU exits rather than hanging
BOOT_OUT="$(mktemp /tmp/boot-out-XXXXXX.txt)"

echo "boot-test: booting with QEMU/KVM (timeout ${TIMEOUT_SECS}s)..."
set +e
timeout "$TIMEOUT_SECS" \
  qemu-system-x86_64 \
    -enable-kvm \
    -cpu host \
    -m 1G \
    -kernel "$VMLINUZ" \
    -initrd "$INITRD_IMG" \
    -append "console=ttyS0,115200 earlyprintk=serial panic=1 quiet" \
    -serial stdio \
    -display none \
    -no-reboot \
  > "$BOOT_OUT" 2>&1
BOOT_RC=$?
set -e

echo "--- boot output (last 80 lines) ---"
tail -80 "$BOOT_OUT"
echo "--- end boot output ---"

rm -rf "$EXTRACT_DIR"
rm -f "$INITRD_IMG"

if grep -q "BOOT_TEST_SUCCESS" "$BOOT_OUT"; then
  echo "boot-test: PASSED"
  rm -f "$BOOT_OUT"
  exit 0
fi

if grep -q "Kernel panic" "$BOOT_OUT"; then
  echo "boot-test: FAILED - kernel panic" >&2
  rm -f "$BOOT_OUT"
  exit 1
fi

if [ "$BOOT_RC" -eq 124 ]; then
  echo "boot-test: FAILED - timeout after ${TIMEOUT_SECS}s (BOOT_TEST_SUCCESS not seen)" >&2
  rm -f "$BOOT_OUT"
  exit 1
fi

echo "boot-test: FAILED - BOOT_TEST_SUCCESS not seen (QEMU exit=$BOOT_RC)" >&2
rm -f "$BOOT_OUT"
exit 1
