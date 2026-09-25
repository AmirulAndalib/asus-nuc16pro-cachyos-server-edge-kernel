#!/usr/bin/env bash
# repo-audit.sh - mechanical consistency checks for this repository.
#
# WHY THIS IS A TRACKED SCRIPT
# ----------------------------
# These checks were first written ad hoc in a session scratchpad, passed cleanly, and were
# then lost when that session ended. The next session had to rebuild them from memory. A
# check that only exists inside one conversation is not a guard rail, so it lives here now
# and runs in CI alongside actionlint and shellcheck.
#
# WHAT IT IS NOT
# It is mechanical only: syntax, wiring, and consistency. It does not read code for logic
# defects and it cannot tell you whether a tuning value is correct. Passing this is a floor,
# not evidence of quality. Anything about performance still has to go through
# scripts/nuc16pro-bench.sh and the rule in docs/TUNING-FINDINGS.md section 12.
#
# USAGE
#   ./scripts/repo-audit.sh          run every check, non-zero exit if any fail
#   ./scripts/repo-audit.sh -v       also print each passing check's detail

set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || dirname "$(dirname "$0")")" || exit 1

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
detail() { [ "$VERBOSE" = 1 ] && printf '        %s\n' "$1"; return 0; }

hdr() { printf '\n== %s ==\n' "$1"; }

# ---------------------------------------------------------------- 1. shell syntax
hdr "shell syntax"
bad=""
while IFS= read -r f; do
  bash -n "$f" 2>/dev/null || bad="$bad $f"
done < <(find scripts -type f \( -name '*.sh' -o -name '*.sh.in' \) | sort)
if [ -z "$bad" ]; then pass "every scripts/*.sh and *.sh.in parses"; else fail "shell parse errors:$bad"; fi

# ---------------------------------------------------------------- 2. YAML syntax
hdr "yaml syntax"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  if python3 - <<'PY'
import glob, sys, yaml
bad = []
for f in sorted(glob.glob('.github/workflows/*.yml')) + \
         ['.github/dependabot.yml', '.github/actionlint.yaml', 'netplan/99-nuc16pro-bond.yaml']:
    try:
        yaml.safe_load(open(f))
    except Exception as e:
        bad.append(f'{f}: {e}')
print('\n'.join(bad))
sys.exit(1 if bad else 0)
PY
  then pass "every tracked YAML file parses"; else fail "YAML parse error (see above)"; fi
else
  printf 'SKIP  yaml syntax (python3 + PyYAML not available)\n'
fi

# ---------------------------------------------------------------- 3. embedded workflow shell
hdr "embedded workflow shell"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  if python3 - <<'PY'
import glob, os, re, subprocess, sys, tempfile, yaml
bad = []
for f in sorted(glob.glob('.github/workflows/*.yml')):
    d = yaml.safe_load(open(f)) or {}
    for jname, job in (d.get('jobs') or {}).items():
        for i, step in enumerate(job.get('steps') or []):
            run = step.get('run')
            if not run:
                continue
            # GHA expressions are not shell; substitute a placeholder before parsing.
            cleaned = re.sub(r'\$\{\{[^}]*\}\}', 'GHA_EXPR', run)
            fd, path = tempfile.mkstemp(suffix='.sh')
            os.write(fd, cleaned.encode()); os.close(fd)
            p = subprocess.run(['bash', '-n', path], capture_output=True, text=True)
            os.unlink(path)
            if p.returncode:
                bad.append(f"{f} :: {jname} step {i} ({step.get('name','?')}): "
                           f"{p.stderr.strip().splitlines()[-1] if p.stderr.strip() else 'parse error'}")
print('\n'.join(bad))
sys.exit(1 if bad else 0)
PY
  then pass "every workflow run: block is valid bash"; else fail "invalid shell in a workflow run: block"; fi
else
  printf 'SKIP  embedded workflow shell (python3 + PyYAML not available)\n'
fi

# ---------------------------------------------------------------- 4. updater in sync
hdr "generated updater in sync with its sources"
if [ -x scripts/assemble-kernel-updater.sh ] || [ -f scripts/assemble-kernel-updater.sh ]; then
  before="$(md5sum scripts/nuc16pro-kernel-updater.sh 2>/dev/null | cut -d' ' -f1)"
  bash scripts/assemble-kernel-updater.sh >/dev/null 2>&1
  after="$(md5sum scripts/nuc16pro-kernel-updater.sh 2>/dev/null | cut -d' ' -f1)"
  if [ "$before" = "$after" ]; then
    pass "committed updater matches its spliced sources"
    detail "md5=$after"
  else
    fail "updater is stale: re-run scripts/assemble-kernel-updater.sh and commit ($before -> $after)"
  fi
fi

# ---------------------------------------------------------------- 5. splice markers resolve
hdr "splice markers resolve to real files"
missing=""
while IFS= read -r m; do
  [ -f "$m" ] || missing="$missing $m"
done < <(grep -oE '@@FILE:[^@]+@@' scripts/nuc16pro-kernel-updater.sh.in 2>/dev/null \
         | sed 's/@@FILE://; s/@@$//' | sort -u)
if [ -z "$missing" ]; then pass "every @@FILE:...@@ marker points at a tracked file"; else fail "marker targets missing:$missing"; fi

# ---------------------------------------------------------------- 6. no host-specific data
hdr "no host-specific data committed"
# The standing rule is that no LAN/WAN IP, MAC, SSID, hostname or credential may be committed;
# automation must auto-detect host values at runtime. Loopback, any-address, broadcast and
# documentation ranges are allowed, as are the netmask-shaped constants in netplan.
hits="$(git ls-files -z 2>/dev/null | xargs -0 grep -nEo \
        '([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' 2>/dev/null \
      | grep -vE '0\.0\.0\.0|127\.0\.0\.1|255\.255|/[0-9]+$|x\.x\.x|1\.1\.1\.1|8\.8\.8\.8' || true)"
if [ -z "$hits" ]; then
  pass "no IP or MAC literals in tracked files"
else
  fail "possible host data committed:"
  printf '%s\n' "$hits" | sed 's/^/        /'
fi

# ---------------------------------------------------------------- 7. writing style
hdr "writing style"
em="$(git ls-files -z '*.md' 2>/dev/null | xargs -0 grep -l $'—' 2>/dev/null || true)"
if [ -z "$em" ]; then pass "no em dashes in tracked markdown"; else fail "em dashes present in:$em"; fi

# ---------------------------------------------------------------- 8. actions pinned to SHA
hdr "supply chain"
unpinned="$(grep -rhoE 'uses: [^ ]+' .github/workflows/*.yml 2>/dev/null \
            | grep -vE '@[0-9a-f]{40}' | sort -u || true)"
if [ -z "$unpinned" ]; then
  pass "every third-party action is pinned to a full SHA"
else
  fail "unpinned actions:"
  printf '%s\n' "$unpinned" | sed 's/^/        /'
fi

# ---------------------------------------------------------------- 9. workflow_run names resolve
hdr "workflow_run targets resolve"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  if python3 - <<'PY'
import glob, sys, yaml
names = set()
for f in glob.glob('.github/workflows/*.yml'):
    d = yaml.safe_load(open(f)) or {}
    if d.get('name'):
        names.add(d['name'])
bad = []
for f in glob.glob('.github/workflows/*.yml'):
    d = yaml.safe_load(open(f)) or {}
    # PyYAML parses a bare `on:` key as the boolean True (the YAML 1.1 "Norway problem").
    trig = d.get(True) or d.get('on') or {}
    if not isinstance(trig, dict):
        continue
    wr = trig.get('workflow_run') or {}
    for w in (wr.get('workflows') or []):
        if w not in names:
            bad.append(f'{f}: workflow_run references unknown workflow {w!r}')
print('\n'.join(bad))
sys.exit(1 if bad else 0)
PY
  then pass "every workflow_run names a workflow that exists"
  else fail "a workflow_run trigger names a workflow that does not exist (it would silently never fire)"; fi
fi

# ---------------------------------------------------------------- 10. markdown links
hdr "markdown links and anchors"
if command -v python3 >/dev/null 2>&1; then
  if python3 - <<'PY'
import os, re, sys

def anchors(path):
    out = set()
    for line in open(path, encoding='utf-8', errors='replace'):
        m = re.match(r'^(#{1,6})\s+(.*?)\s*$', line)
        if not m:
            continue
        t = m.group(2)
        t = re.sub(r'`([^`]*)`', r'\1', t)
        t = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', t)
        t = t.replace('*', '')          # keep underscores: GitHub does
        s = re.sub(r'[^\w\s-]', '', t.lower())
        out.add(re.sub(r'\s+', '-', s.strip()))
    return out

cache, bad, checked = {}, [], 0
targets = [p for p in ('README.md', 'docs/TUNING-FINDINGS.md', 'patches/README.md') if os.path.exists(p)]
for f in targets:
    src = open(f, encoding='utf-8', errors='replace').read()
    base = os.path.dirname(f)
    for m in re.finditer(r'\[([^\]]*)\]\(([^)\s]+)\)', src):
        tgt = m.group(2)
        if tgt.startswith(('http://', 'https://', 'mailto:')):
            continue
        checked += 1
        path, _, frag = tgt.partition('#')
        res = os.path.normpath(os.path.join(base, path)) if path else f
        if path and not os.path.exists(res):
            bad.append(f'{f}: missing file -> {tgt}'); continue
        if frag:
            if res not in cache:
                cache[res] = anchors(res)
            if frag not in cache[res]:
                bad.append(f'{f}: dead anchor -> {tgt}')
print('\n'.join(bad) or f'checked {checked} internal links')
sys.exit(1 if bad else 0)
PY
  then pass "every internal markdown link and anchor resolves"; else fail "broken markdown link or anchor"; fi
fi

# ---------------------------------------------------------------- summary
printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'ALL CHECKS PASSED\n'
  exit 0
fi
printf '%d CHECK(S) FAILED\n' "$fails"
exit 1
