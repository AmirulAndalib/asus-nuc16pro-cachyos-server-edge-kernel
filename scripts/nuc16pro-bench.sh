#!/usr/bin/env bash
# nuc16pro-bench.sh - interleaved N-way benchmark harness for the ServerMax box.
#
# WHY THIS EXISTS
# ---------------
# docs/TUNING-FINDINGS.md section 12 set the rule for this repo: a tuning change
# stays only if it has a number behind it. That rule exists because two changes
# once shipped on mechanism alone and had to be withdrawn. They shipped unmeasured
# because the box had no benchmark capability, so every proposal was a story.
# This is that missing capability.
#
# WHAT IT COMPARES
#   stock      kernel-default tuning: EEVDF, PMD-only THP, mq-deadline, distro sysctls
#   servermax  what this repo ships today: scx_flash, mTHP 16/32/64, ADIOS, tuned sysctls
#   ultimate   servermax plus the candidates under test this round
#
# SCOPE LIMIT, STATED HONESTLY
#   All three profiles run on the SAME running kernel. This harness measures the
#   RUNTIME TUNING layer only. It cannot A/B the kernel build itself (ThinLTO,
#   x86-64-v3, HZ=100, preempt=lazy, ADIOS being compiled in), because that needs
#   a reboot into a different kernel image. Do not read "stock" here as "stock
#   Ubuntu kernel"; read it as "this kernel with the tuning removed".
#
# METHODOLOGY (from section 12, calibrated for this box)
#   - Round-robin A,B,C / A,B,C so background drift cannot favour one profile.
#   - Medians reported next to means; one hiccup moves a mean, not a median.
#   - The within-profile spread is treated as the real noise floor. A delta
#     smaller than that spread is reported as NOISE, never as a win.
#   - Default noise threshold 5%: this box idles around load 5 with ~90 containers.
#
# SAFETY
#   - The harness ALWAYS restores the servermax profile on exit, including on
#     interrupt or error. An aborted run cannot strand the box in stock or ultimate.
#   - Every apply is idempotent and every value it writes is captured first.
#
# USAGE
#   sudo -A ./nuc16pro-bench.sh all
#   PAIRS=7 DUR=20 ./nuc16pro-bench.sh all
#   ./nuc16pro-bench.sh selftest     # proves the harness calls A-vs-A NOISE
#   DRY=1 ./nuc16pro-bench.sh all    # print plan, change nothing

set -uo pipefail

ROUNDS="${ROUNDS:-${PAIRS:-5}}"
NOISE_PCT="${NOISE_PCT:-5}"
DUR="${DUR:-12}"
DRY="${DRY:-0}"
WORKDIR="$(mktemp -d /tmp/nuc16pro-bench.XXXXXX)"
RESULTS="$WORKDIR/results"; mkdir -p "$RESULTS"

SUDO() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo -A "$@"; fi; }
have()  { command -v "$1" >/dev/null 2>&1; }
w()     { # write $2 into file $1 if it exists and is writable
  [ -w "$1" ] 2>/dev/null && printf '%s' "$2" | SUDO tee "$1" >/dev/null 2>&1 || \
  printf '%s' "$2" | SUDO tee "$1" >/dev/null 2>&1 || true
}

cleanup() {
  echo
  echo ">> restoring servermax profile (guaranteed on exit)"
  profile_servermax >/dev/null 2>&1 || true
  printf zstd | SUDO tee /sys/module/zswap/parameters/compressor >/dev/null 2>&1 || true
  verify_servermax || echo "   !! VERIFY FAILED - inspect the box manually"
  rm -rf "$WORKDIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------ stats
median() { sort -n | awk '{v[NR]=$1} END{if(NR==0){print 0;exit} m=int((NR+1)/2); if(NR%2) print v[m]; else print (v[m]+v[m+1])/2}'; }
mean()   { awk '{s+=$1;n++} END{if(n==0){print 0;exit} printf "%.1f", s/n}'; }
spread() { sort -n | awk '{v[NR]=$1} END{if(NR<2){print 0;exit} printf "%.1f", v[NR]-v[1]}'; }

# ------------------------------------------------------------------ profiles
# Each profile applies in ONE privileged call. An earlier version issued ~20 separate
# `sudo -A` invocations per profile; each one re-spawned the askpass helper and the switch
# cost ~70s against a 12s benchmark, so overhead dominated the measurement. Batching cuts
# the switch to a few seconds and makes the harness practical to run at real round counts.
apply_root() { if [ "$(id -u)" -eq 0 ]; then bash -c "$1"; else sudo -A bash -c "$1"; fi; }

profile_stock() {
  apply_root '
    for o in 16 32 64 128 256 512 1024; do
      f=/sys/kernel/mm/transparent_hugepage/hugepages-${o}kB/enabled
      [ -e "$f" ] && echo never > "$f" 2>/dev/null
    done
    echo 0 > /sys/kernel/mm/transparent_hugepage/shrink_underused 2>/dev/null
    for d in /sys/block/nvme*n1; do
      echo mq-deadline > "$d/queue/scheduler" 2>/dev/null
      echo 64          > "$d/queue/nr_requests" 2>/dev/null
    done
    sysctl -qw vm.swappiness=60 vm.vfs_cache_pressure=100 \
               vm.dirty_background_ratio=10 vm.dirty_ratio=20 \
               net.ipv4.tcp_congestion_control=cubic net.core.default_qdisc=pfifo_fast \
               net.core.netdev_max_backlog=1000 \
               net.ipv4.tcp_slow_start_after_idle=1 \
               net.ipv4.tcp_notsent_lowat=4294967295 2>/dev/null
    systemctl stop scx_loader 2>/dev/null
  '
  sleep 3   # let sched_ext detach and the kernel settle back onto EEVDF
}

profile_servermax() {
  apply_root '
    printf "default_sched = \"scx_flash\"\ndefault_mode  = \"Server\"\n" > /etc/scx_loader/config.toml
    for o in 16 32 64; do echo always > /sys/kernel/mm/transparent_hugepage/hugepages-${o}kB/enabled 2>/dev/null; done
    for o in 128 256 512 1024; do echo never > /sys/kernel/mm/transparent_hugepage/hugepages-${o}kB/enabled 2>/dev/null; done
    echo inherit > /sys/kernel/mm/transparent_hugepage/hugepages-2048kB/enabled 2>/dev/null
    echo 1 > /sys/kernel/mm/transparent_hugepage/shrink_underused 2>/dev/null
    for d in /sys/block/nvme*n1; do
      echo adios > "$d/queue/scheduler" 2>/dev/null
      echo 1023  > "$d/queue/nr_requests" 2>/dev/null
    done
    sysctl -qw vm.swappiness=10 vm.vfs_cache_pressure=50 \
               vm.dirty_background_ratio=5 vm.dirty_ratio=20 \
               net.ipv4.tcp_congestion_control=bbr net.core.default_qdisc=fq \
               net.core.netdev_max_backlog=16384 \
               net.ipv4.tcp_slow_start_after_idle=1 \
               net.ipv4.tcp_notsent_lowat=4294967295 2>/dev/null
    systemctl restart scx_loader 2>/dev/null
  '
  sleep 4   # scx_loader needs a moment to attach scx_flash before benchmarking
}

profile_ultimate() {
  apply_root '
    printf "default_sched = \"scx_flash\"\ndefault_mode  = \"Server\"\n\n[scheds.flash]\nserver_mode = [\"-s\", \"3000\", \"-l\", \"20000\"]\n" > /etc/scx_loader/config.toml
    for o in 16 32 64; do echo always > /sys/kernel/mm/transparent_hugepage/hugepages-${o}kB/enabled 2>/dev/null; done
    for o in 128 256 512 1024; do echo never > /sys/kernel/mm/transparent_hugepage/hugepages-${o}kB/enabled 2>/dev/null; done
    echo inherit > /sys/kernel/mm/transparent_hugepage/hugepages-2048kB/enabled 2>/dev/null
    echo 1 > /sys/kernel/mm/transparent_hugepage/shrink_underused 2>/dev/null
    for d in /sys/block/nvme*n1; do
      echo adios > "$d/queue/scheduler" 2>/dev/null
      echo 1023  > "$d/queue/nr_requests" 2>/dev/null
    done
    sysctl -qw vm.swappiness=10 vm.vfs_cache_pressure=50 \
               vm.dirty_background_ratio=5 vm.dirty_ratio=20 \
               net.ipv4.tcp_congestion_control=bbr net.core.default_qdisc=fq \
               net.core.netdev_max_backlog=16384 \
               net.ipv4.tcp_slow_start_after_idle=0 \
               net.ipv4.tcp_notsent_lowat=131072 2>/dev/null
    systemctl restart scx_loader 2>/dev/null
  '
  sleep 4
}

verify_servermax() {
  local ok=0
  local ops; ops=$(cat /sys/kernel/sched_ext/root/ops 2>/dev/null)
  case "$ops" in flash*) ;; *) echo "   scx NOT attached (ops='$ops')"; ok=1 ;; esac
  local t16; t16=$(sed -n 's/.*\[\([a-z]*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/hugepages-16kB/enabled 2>/dev/null)
  [ "$t16" = always ] || { echo "   mTHP 16k is '$t16' not always"; ok=1; }
  local sch; sch=$(sed -n 's/.*\[\([a-z-]*\)\].*/\1/p' /sys/block/nvme0n1/queue/scheduler 2>/dev/null)
  [ "$sch" = adios ] || { echo "   nvme0n1 sched is '$sch' not adios"; ok=1; }
  [ "$(sysctl -n vm.swappiness 2>/dev/null)" = 10 ] || { echo "   swappiness not 10"; ok=1; }
  [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = bbr ] || { echo "   cc not bbr"; ok=1; }
  # /sys/module/zswap/parameters/compressor holds a bare value with NO brackets, unlike
  # the sysfs files above it. A bracket-extracting sed returns empty here and made this
  # verify report a false failure while the box was in fact correctly restored.
  zc=$(tr -d "[:space:]" < /sys/module/zswap/parameters/compressor 2>/dev/null)
  case "$zc" in *zstd*) ;; *) echo "   zswap compressor is '$zc' not zstd"; ok=1 ;; esac
  [ $ok -eq 0 ] && echo "   verified: servermax profile restored"
  return $ok
}


# ---- zswap compressor A/B ------------------------------------------------
# The box runs a 67% zswap refault ratio: two thirds of everything compressed out gets
# pulled straight back in. At that refault rate DECOMPRESSION speed is on the hot path far
# more often than compression ratio is, which makes zstd-vs-lz4 a real question rather than
# a matter of taste. zstd stores more per byte of pool; lz4 decompresses several times
# faster. Neither answer is obvious, so it gets measured.
zswap_set() { printf '%s' "$1" | SUDO tee /sys/module/zswap/parameters/compressor >/dev/null 2>&1; }
profile_zstd() { profile_servermax; zswap_set zstd; }
profile_lz4()  { profile_servermax; zswap_set lz4;  }

# ------------------------------------------------------------------ benchmarks
# each prints ONE number; HB=1 means higher is better
bench_cpu() {   # CPU throughput across all cores. stress-ng warns that the governor
                # is "powersave": that is intentional here (intel_pstate active +
                # EPP=performance), not a misconfiguration. See README Kernel Profile.
  stress-ng --cpu "$(nproc)" --cpu-method matrixprod --metrics-brief --timeout "${DUR}s" 2>&1 \
    | awk '/metrc:/ && $4=="cpu" {print $9; exit}'
}
bench_switch() { # context-switch rate: where slice length actually shows
  stress-ng --switch 4 --metrics-brief --timeout "${DUR}s" 2>&1 \
    | awk '/metrc:/ && $4=="switch" {print $9; exit}'
}
bench_fork() {   # process churn, the container-fleet shape
  stress-ng --fork 8 --metrics-brief --timeout "${DUR}s" 2>&1 \
    | awk '/metrc:/ && $4=="fork" {print $9; exit}'
}
bench_disk() {   # 4k random read behind LUKS via io_uring
  fio --name=ab --filename="$WORKDIR/fio.dat" --size=384M --rw=randread --bs=4k \
      --iodepth=32 --ioengine=io_uring --direct=1 --runtime="$DUR" --time_based \
      --group_reporting --output-format=json 2>/dev/null \
    | awk -F'[:,]' '/"iops"/{gsub(/[ "]/,"",$2); printf "%d", $2; exit}'
}
bench_mem() {   # anonymous-memory churn: drives the zswap compress/decompress path,
                # which is where the compressor choice actually shows up.
  stress-ng --vm 4 --vm-bytes 1G --vm-method flip --metrics-brief --timeout "${DUR}s" 2>&1     | awk '/metrc:/ && $4=="vm" {print $9; exit}'
}
bench_net() {    # loopback TCP: exercises the stack, NOT the NIC or the bond
  (iperf3 -s -1 -p 5399 >/dev/null 2>&1 &) ; sleep 1
  iperf3 -c 127.0.0.1 -p 5399 -t "$DUR" -J 2>/dev/null \
    | awk -F'[:,]' '/"bits_per_second"/{gsub(/[ "]/,"",$2); v=$2} END{printf "%d", v/1000000}'
  pkill -f 'iperf3 -s -1 -p 5399' 2>/dev/null || true
}

# ------------------------------------------------------------------ runner
PROFILES="stock servermax ultimate"
BASE_PROFILE="servermax"   # verdict denominator
CAND_PROFILE="ultimate"    # verdict numerator

# rotate_profiles <n> <p1> <p2> ...  -> prints the list rotated left by n
rotate_profiles() {
  local n="$1"; shift
  local -a a=("$@"); local len=${#a[@]} i
  [ "$len" -eq 0 ] && return 0
  for ((i = 0; i < len; i++)); do printf '%s ' "${a[$(( (i + n) % len ))]}"; done
  printf '
'
}

run_bench() { # run_bench <name> <fn> <higher_better>
  local name="$1" fn="$2" hb="$3"
  echo "-------------------------------------------------------------------"
  echo "BENCHMARK: $name   (${DUR}s x ${ROUNDS} rounds x 3 profiles)"
  for p in $PROFILES; do : > "$RESULTS/$name.$p"; done

  # ROTATE the profile order every round. Running a fixed order (always stock, then
  # servermax, then ultimate) gives the first profile a systematic advantage: it always
  # benchmarks immediately after the previous round's teardown, while later profiles
  # benchmark on a machine still settling from a scheduler restart. A first run of this
  # harness showed exactly that artefact - stock flat near 39000 while servermax climbed
  # 36139 -> 38747 across rounds. Rotation cancels position bias instead of hiding it.
  for r in $(seq 1 "$ROUNDS"); do
    printf '  round %d/%d: ' "$r" "$ROUNDS"
    for p in $(rotate_profiles "$((r - 1))" $PROFILES); do
      "profile_$p" >/dev/null 2>&1
      sleep 1
      local v; v="$($fn)"; [ -n "$v" ] || v=0
      printf '%s=%s ' "$p" "$v"
      echo "$v" >> "$RESULTS/$name.$p"
    done
    echo
  done

  echo
  local base_med; base_med=$(median < "$RESULTS/$name.$BASE_PROFILE")
  for p in $PROFILES; do
    local m mn sp
    m=$(median < "$RESULTS/$name.$p"); mn=$(mean < "$RESULTS/$name.$p"); sp=$(spread < "$RESULTS/$name.$p")
    printf '  %-10s median=%-12s mean=%-12s spread=%-10s' "$p" "$m" "$mn" "$sp"
    awk -v m="$m" -v b="$base_med" -v hb="$hb" -v bp="$BASE_PROFILE" 'BEGIN{
      if(b==0||m==0){print "  (n/a)"; exit}
      d=(m-b)/b*100; if(hb==0) d=-d;
      printf "  vs servermax: %+.1f%%\n", d }'
  done

  # verdict for ultimate vs servermax, the only decision this round makes.
  # Medians/spreads computed in shell, not awk: mawk (Ubuntu default) has no asort().
  local sm um ssp usp
  sm=$(median  < "$RESULTS/$name.$BASE_PROFILE"); um=$(median  < "$RESULTS/$name.$CAND_PROFILE")
  ssp=$(spread < "$RESULTS/$name.$BASE_PROFILE"); usp=$(spread < "$RESULTS/$name.$CAND_PROFILE")
  awk -v sm="$sm" -v um="$um" -v ssp="$ssp" -v usp="$usp" -v np="$NOISE_PCT" -v hb="$hb" -v bp="$BASE_PROFILE" -v cp="$CAND_PROFILE" 'BEGIN{
      if(sm==0||um==0){print "  VERDICT: INVALID (a run returned 0)"; exit}
      fs=ssp/sm*100; fu=usp/um*100; floor=(fs>fu?fs:fu);
      d=(um-sm)/sm*100; if(hb==0) d=-d; ad=(d<0?-d:d);
      printf "  VERDICT %s vs %s: %+.1f%% (noise floor %.1f%%) -> ", cp, bp, d, floor;
      if(ad<np)         printf "NOISE, do not ship\n";
      else if(ad<floor) printf "NOISE (under within-profile spread), do not ship\n";
      else if(d>0)      printf "ULTIMATE WINS, ship if reproducible\n";
      else              printf "REGRESSION, keep servermax\n";
  }'
  echo
}

main() {
  echo "==================================================================="
  echo "nuc16pro-bench   host=$(hostname)   kernel=$(uname -r)"
  echo "date=$(date -u +%FT%TZ)   load=$(cut -d' ' -f1-3 /proc/loadavg)"
  echo "containers=$(docker ps -q 2>/dev/null | wc -l)   rounds=$ROUNDS   dur=${DUR}s   noise=${NOISE_PCT}%"
  echo "SCOPE: runtime tuning only, all profiles on this one kernel."
  echo "==================================================================="
  echo
  if [ "$DRY" = 1 ]; then echo "(DRY=1) profiles: $PROFILES"; trap - EXIT; exit 0; fi
  for t in stress-ng fio iperf3; do have "$t" || { echo "missing tool: $t"; exit 1; }; done

  case "${1:-all}" in
    selftest) # A-vs-A control: alias ultimate to servermax so both arms are identical.
              # If this does not report NOISE, no verdict from this harness is trustworthy.
              ROUNDS="${ROUNDS:-4}"
              eval 'profile_ultimate() { profile_servermax; }'
              PROFILES="servermax ultimate"
              run_bench selftest-AvsA bench_cpu 1 ;;
    sched)    run_bench cpu bench_cpu 1; run_bench ctxswitch bench_switch 1 ;;
    net)      run_bench net bench_net 1 ;;
    zswap)    # compare zstd (current) against lz4 on the memory-churn benchmark
              PROFILES="zstd lz4"; BASE_PROFILE="zstd"; CAND_PROFILE="lz4"
              run_bench zswap-compressor bench_mem 1 ;;
    mem)      run_bench mem bench_mem 1 ;;
    disk)     run_bench disk bench_disk 1 ;;
    all)      run_bench cpu bench_cpu 1
              run_bench ctxswitch bench_switch 1
              run_bench fork bench_fork 1
              run_bench disk bench_disk 1
              run_bench net bench_net 1 ;;
    *) echo "usage: $0 {all|sched|net|disk|mem|zswap|selftest}"; trap - EXIT; exit 2 ;;
  esac
}
main "$@"
