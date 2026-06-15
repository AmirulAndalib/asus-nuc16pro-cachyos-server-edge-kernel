# Custom kernel patches

Source patches for the CachyOS ServerMax kernel that are applied *after* the
upstream CachyOS patchset but *before* the Kconfig fragment merge.

## Apply semantics

**Fail-hard.** Any patch in this directory that fails to apply causes the build
to abort immediately. This is intentional: a partially-patched kernel is worse
than no custom patch at all. The build script uses `patch -p1 --forward --fuzz=0`
with `set -euo pipefail`; no retries, no warn-and-continue.

This differs from the CachyOS patchset apply loop (which warns but continues)
because those patches come from upstream CachyOS and are validated against the
specific PKGBUILD version. Custom patches here are maintained independently.

## Naming convention

Patches are applied in `sort -V` order (version sort):

```
0001-description.patch
0002-description.patch
```

Each patch must apply cleanly with `fuzz=0` against the kernel tree *after*
CachyOS patches have been applied.

## When a patch breaks

CachyOS tracks `linux-cachyos` which rolls continuously. A patch that applied
against 6.14.3 may not apply against 6.14.4 if the context lines changed.
When the build breaks on a patch apply:

1. Check if the fix was already incorporated upstream (CachyOS or mainline)
2. Refresh the patch with `git format-patch` against the new base
3. If context is gone entirely, the kernel already has the fix; delete the patch

## Adding a new patch

```sh
# From the kernel source tree with CachyOS patches already applied:
git diff HEAD > patches/0001-my-fix.patch
# or
git format-patch -1 HEAD --stdout > patches/0001-my-fix.patch
```

Verify it applies cleanly before committing:
```sh
patch -p1 --forward --fuzz=0 --dry-run < patches/0001-my-fix.patch
```

## Current patches

None. The directory is intentionally empty at initial setup. Config-only tuning
lives in `config/servermax.config` and requires no source patches.
