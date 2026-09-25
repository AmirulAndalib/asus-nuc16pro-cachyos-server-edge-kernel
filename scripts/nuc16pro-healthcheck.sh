#!/usr/bin/env bash
# ASUS NUC 16 Pro ServerMax - post-boot health report (read-only).
# Run by nuc16pro-healthcheck.timer (~5 min post-boot + daily); output goes to the journal:
#   journalctl -u nuc16pro-healthcheck.service
# Manual run: sudo nuc16pro-healthcheck
# Never changes system state. Always exits 0 (a report, not a gate); [WARN] lines flag anything off.
set -u

warn=0
note() { printf '  %s\n' "$*"; }
flag() { printf '  [WARN] %s\n' "$*"; warn=$((warn + 1)); }
sec()  { printf '[%s]\n' "$1"; }

echo "==== nuc16pro health $(date -u +%Y-%m-%dT%H:%M:%SZ) ===="

sec kernel
note "running: $(uname -r)"
case "$(uname -r)" in
  *cachyos*nuc16pro*servermax*) note "custom servermax kernel: yes" ;;
  *) flag "not running the custom servermax kernel" ;;
esac
note "uptime:$(uptime -p 2>/dev/null | sed 's/^up//' || true)"

sec systemd
failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')
if [ -z "$failed" ]; then
  note "failed units: 0"
else
  flag "failed units: $(printf '%s\n' "$failed" | wc -l)"
  printf '%s\n' "$failed" | sed 's/^/         /'
fi

sec sched_ext
state=$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo n/a)
ops=$(cat /sys/kernel/sched_ext/root/ops 2>/dev/null || echo "")
note "state: $state   attached: ${ops:-<none>}"
if [ "$state" = enabled ] && [ -n "$ops" ]; then
  note "scheduler attached: ok"
else
  flag "no scx scheduler attached (kernel EEVDF is active)"
fi
nr=$(systemctl show nuc16pro-scx-server.service -p NRestarts --value 2>/dev/null || echo '?')
note "scx unit restarts this boot: $nr"
cg=$(journalctl -b -k 2>/dev/null | grep -ciE 'cgroup_init\(\) failed')
note "cgroup_init ENOMEM events this boot: $cg (boot-storm transient; absorbed by try_primary retry)"

sec gpu-xe
[ -d /sys/bus/pci/drivers/xe ] && note "xe driver bound: yes" || flag "xe driver not bound"
[ -e /dev/dri/renderD128 ] && note "render node: present" || flag "render node /dev/dri/renderD128 missing"
fw=$(journalctl -b -k 2>/dev/null | grep -oE 'GSC firmware from [^ ]+ version [0-9.]+' | tail -1)
[ -n "$fw" ] && note "$fw"
if journalctl -b -k 2>/dev/null | grep -q 'PXP requires PTL GSC build'; then
  note "PXP: unavailable (shipped GSC firmware below kernel's PXP minimum; VA-API transcode unaffected)"
fi

sec va-api
if [ -e /usr/lib/x86_64-linux-gnu/dri/iHD_drv_video.so ]; then
  note "host iHD driver: present"
  if command -v vainfo >/dev/null 2>&1; then
    p=$(vainfo 2>/dev/null | grep -c VAProfile)
    if [ "${p:-0}" -gt 0 ]; then note "vainfo profiles: $p"; else flag "vainfo returned no profiles"; fi
  fi
else
  flag "host iHD VA-API driver absent (host-side hardware transcode unavailable)"
fi

sec remote-desktop
if systemctl cat gnome-remote-desktop.service >/dev/null 2>&1; then
  note "gnome-remote-desktop: $(systemctl is-active gnome-remote-desktop.service 2>/dev/null)"
  # Xe3 workaround: RDP --handover daemon SIGSEGVs in the Intel Vulkan driver unless
  # pinned to software Vulkan (lavapipe). Flag if that pin ever disappears (regression).
  if grep -qs 'lvp_icd' /etc/environment /etc/systemd/system/gnome-remote-desktop.service.d/*.conf; then
    note "RDP software-Vulkan workaround: present"
  else
    flag "RDP software-Vulkan workaround missing (Xe3 RDP handover will SIGSEGV)"
  fi
  bt=$(date -d "$(uptime -s)" +%s 2>/dev/null || echo 0)
  nc=0
  for f in /var/crash/_usr_libexec_gnome-remote-desktop-daemon.*.crash; do
    [ -e "$f" ] || continue
    [ "$(stat -c %Y "$f" 2>/dev/null || echo 0)" -gt "$bt" ] && nc=$((nc + 1))
  done
  [ "$nc" -eq 0 ] && note "no RDP daemon crashes since boot" || flag "gnome-remote-desktop crashed $nc time(s) since boot"
else
  note "gnome-remote-desktop: not installed"
fi

sec network
if [ -d /sys/class/net/bond0 ]; then
  mode=$(cat /sys/class/net/bond0/bonding/mode 2>/dev/null)
  slaves=$(cat /sys/class/net/bond0/bonding/slaves 2>/dev/null)
  up=0; tot=0
  for s in $slaves; do
    tot=$((tot + 1))
    [ "$(cat /sys/class/net/"$s"/operstate 2>/dev/null)" = up ] && up=$((up + 1))
  done
  note "bond0: mode ${mode%% *}; slaves up: $up/$tot (${slaves:-none})"
  { [ "$tot" -gt 0 ] && [ "$up" -eq "$tot" ]; } || flag "bond0 has slaves down ($up/$tot up)"
else
  note "bond0: not configured"
fi

sec memory
free -h | awk '/^Mem:/{printf "  mem used %s / %s (avail %s)\n",$3,$2,$7} /^Swap:/{printf "  swap used %s / %s\n",$3,$2}'
oom=$(awk '/oom_kill/{print $2}' /proc/vmstat 2>/dev/null)
oom=${oom:-0}
if [ "$oom" -eq 0 ] 2>/dev/null; then note "oom kills since boot: $oom"; else flag "oom kills since boot: $oom"; fi

sec thermal
tt=0
for c in /sys/devices/system/cpu/cpu*/thermal_throttle/core_throttle_count; do
  [ -r "$c" ] && tt=$((tt + $(cat "$c" 2>/dev/null || echo 0)))
done
note "core throttle events (cumulative): $tt"

sec storage
if command -v nvme >/dev/null 2>&1; then
  for d in /dev/nvme[0-9]n[0-9]; do
    [ -e "$d" ] || continue
    s=$(nvme smart-log "$d" 2>/dev/null | awk -F: '
      /critical_warning/ {gsub(/[ \t]/,"",$2); cw=$2}
      /percentage_used/  {gsub(/[ \t]/,"",$2); pu=$2}
      /media_errors/     {gsub(/[ \t]/,"",$2); me=$2}
      END{printf "crit=%s used=%s media_err=%s", cw, pu, me}')
    note "$(basename "$d"): $s"
    case "$s" in *crit=0*) : ;; *) flag "$(basename "$d") SMART critical_warning nonzero or unread" ;; esac
  done
else
  note "nvme-cli absent (skip NVMe SMART)"
fi
if command -v smartctl >/dev/null 2>&1; then
  for d in /dev/sd[a-z]; do
    [ -e "$d" ] || continue
    h=$(smartctl -H "$d" 2>/dev/null | grep -iE 'overall-health|SMART Health Status|test result' | head -1 | sed 's/.*: *//')
    [ -z "$h" ] && h=$(smartctl -H -d sat "$d" 2>/dev/null | grep -iE 'overall-health|test result' | head -1 | sed 's/.*: *//')
    note "$(basename "$d"): SMART ${h:-n/a}"
    case "$h" in *FAIL*) flag "$(basename "$d") SMART: $h" ;; esac
  done
fi

sec docker
if command -v docker >/dev/null 2>&1; then
  r=$(docker ps -q 2>/dev/null | wc -l)
  u=$(docker ps --filter health=unhealthy -q 2>/dev/null | wc -l)
  note "containers running: $r   unhealthy: $u"
  [ "$u" -eq 0 ] || flag "$u unhealthy container(s)"
else
  note "docker not present"
fi

sec memory-tuning
# multi-size THP. The point of this section is the RATIO, not the absolute counters: if the
# mid orders regress to "never" the fallback rate climbs back toward the ~81% that was
# measured before they were enabled, and that is the signal worth catching.
mthp_on=""
for o in 16 32 64; do
  e="/sys/kernel/mm/transparent_hugepage/hugepages-${o}kB/enabled"
  [ -f "$e" ] || continue
  case "$(cat "$e")" in *"[always]"*|*"[inherit]"*) mthp_on="$mthp_on ${o}k" ;; esac
done
if [ -n "$mthp_on" ]; then
  note "mTHP orders enabled:$mthp_on"
else
  flag "mTHP mid orders (16k/32k/64k) all disabled - THP faults will fall back to 4k (nuc16pro-servermax-mm.service not applied?)"
fi
for o in 16 32 64 2048; do
  s="/sys/kernel/mm/transparent_hugepage/hugepages-${o}kB/stats"
  [ -d "$s" ] || continue
  a=$(cat "$s/anon_fault_alloc" 2>/dev/null || echo 0)
  f=$(cat "$s/anon_fault_fallback" 2>/dev/null || echo 0)
  t=$((a + f))
  if [ "$t" -gt 0 ]; then
    note "mTHP ${o}kB: alloc=$a fallback=$f ($((a * 100 / t))% success)"
  fi
done
# KSM is asserted off on purpose: measured general_profit was NEGATIVE on this box because
# Docker never opts memory in via MADV_MERGEABLE, so ksmd scans without merging.
if [ -f /sys/kernel/mm/ksm/run ]; then
  k=$(cat /sys/kernel/mm/ksm/run)
  if [ "$k" = "0" ]; then
    note "KSM: off (intended - measured negative general_profit on this workload)"
  else
    p=$(cat /sys/kernel/mm/ksm/general_profit 2>/dev/null || echo n/a)
    flag "KSM enabled (run=$k, general_profit=$p) - it merged ~15 pages at a net loss when last tested here"
  fi
fi
# DAMON proactive reclaim
if [ -f /sys/module/damon_reclaim/parameters/enabled ]; then
  de=$(cat /sys/module/damon_reclaim/parameters/enabled 2>/dev/null || echo '?')
  if [ "$de" = "Y" ]; then
    db=$(cat /sys/module/damon_reclaim/parameters/bytes_reclaimed_regions 2>/dev/null || echo 0)
    dq=$(cat /sys/module/damon_reclaim/parameters/nr_quota_exceeds 2>/dev/null || echo 0)
    note "DAMON reclaim: enabled, reclaimed=$((db / 1024 / 1024))MiB quota_exceeds=$dq"
  else
    note "DAMON reclaim: disabled (enabled=$de)"
  fi
fi
if [ -f /sys/module/zswap/parameters/max_pool_percent ]; then
  note "zswap pool: $(cat /sys/module/zswap/parameters/max_pool_percent)% compressor=$(cat /sys/module/zswap/parameters/compressor 2>/dev/null)"
fi
zo=$(awk '/^zswpout/{o=$2} /^zswpin/{i=$2} END{if (o>0) printf "%d", i*100/o; else printf "0"}' /proc/vmstat)
note "zswap refault ratio: ${zo}% of writeouts were read back (high = pool under-sized for the working set)"

sec block-perf
for d in /sys/block/nvme[0-9]n[0-9] /sys/block/sd[a-z]; do
  [ -d "$d" ] || continue
  [ "$(cat "$d/queue/rotational" 2>/dev/null)" = "0" ] || continue
  n=$(basename "$d")
  w=$(cat "$d/queue/wbt_lat_usec" 2>/dev/null || echo n/a)
  ra=$(cat "$d/queue/rq_affinity" 2>/dev/null || echo n/a)
  s=$(sed -n 's/.*\[\(.*\)\].*/\1/p' "$d/queue/scheduler" 2>/dev/null)
  # wbt_lat_usec and rq_affinity are REPORTED, not asserted. Both were set to 0/2 in an
  # earlier round on mechanism grounds, then benchmarked with fio over 5 interleaved pairs
  # against the kernel defaults: read 161358 vs 164477 KB/s mean, write 133294 vs 131533,
  # with per-config spread wider than the difference. No measurable win, so the udev rule
  # was withdrawn and the kernel defaults are back. Left visible here so a future change
  # to these values is noticed, but there is nothing to flag.
  note "$n: sched=$s wbt_lat_usec=$w rq_affinity=$ra nr_requests=$(cat "$d/queue/nr_requests" 2>/dev/null)"
done

sec crypt-perf
if command -v dmsetup >/dev/null 2>&1; then
  ct=$(dmsetup table --target crypt 2>/dev/null)
  if [ -n "$ct" ]; then
    # Count crypt targets that are missing the workqueue-bypass flags. Every LUKS device on
    # this box sits under either the root LV or the media disks, so all container I/O pays
    # the dm-crypt path and the flags are worth asserting.
    tot=$(printf '%s\n' "$ct" | grep -c 'crypt ')
    ok=$(printf '%s\n' "$ct" | grep -c 'no_read_workqueue')
    note "dm-crypt targets with workqueue bypass: $ok/$tot"
    [ "$ok" -eq "$tot" ] || flag "$((tot - ok)) dm-crypt target(s) still using the internal workqueues (pending reboot, or crypttab not updated)"
  fi
fi

sec boot-order
# The tuning oneshots must land before dockerd starts the container fleet. This regressed
# silently once already (After=multi-user.target fired at 42.8s while docker started at
# 19.5s), and nothing else in the system reports it, so it is checked explicitly.
# The assertion is on the DECLARED ordering, not on this boot's timestamps. Timestamps are
# reported too, but they cannot be the test: the updater restarts these oneshots on every run
# (RemainAfterExit means a changed unit file would otherwise never re-apply), and any manual
# `systemctl restart` also moves them, so a timestamp-based check reports "started after
# docker" every time the units are legitimately re-run mid-uptime. The declared ordering is
# the thing that actually determines behaviour at the next boot, and it is what regressed
# last time.
dstart=$(systemctl show -p InactiveExitTimestampMonotonic --value docker.service 2>/dev/null)
for u in nuc16pro-servermax-cpupower.service nuc16pro-servermax-power.service nuc16pro-servermax-mm.service scx_loader.service; do
  systemctl cat "$u" >/dev/null 2>&1 || continue
  before=$(systemctl show -p Before --value "$u" 2>/dev/null)
  case "$before" in
    *docker.service*) ordering="declares Before=docker.service" ;;
    *) ordering="" ;;
  esac
  if [ -z "$ordering" ]; then
    flag "$u does not declare Before=docker.service - at the next boot the container fleet will start untuned"
    continue
  fi
  us=$(systemctl show -p InactiveExitTimestampMonotonic --value "$u" 2>/dev/null)
  if [ -n "$us" ] && [ "$us" -gt 0 ] 2>/dev/null && [ -n "$dstart" ] && [ "$dstart" -gt 0 ] 2>/dev/null && [ "$us" -lt "$dstart" ]; then
    note "$u: $ordering, applied $(( (dstart - us) / 1000000 ))s before docker this boot"
  else
    note "$u: $ordering (re-run since boot, so this boot's timestamp is not the boot-order signal)"
  fi
done
# bluetooth is REPORTED ONLY, never flagged in either direction. It is used by Home Assistant
# for BLE (the container runs privileged with net=host and /run/dbus bind-mounted, reaching
# hci0 through BlueZ), so it should normally be on - but whether it is on is an operator
# decision, not a health defect, and this script is a report rather than a policy gate.
# History worth keeping: bluetoothd produces most of this box's journal error lines (9436 of
# 10182 in one boot) because it discovers unpairable neighbours. That noise is cosmetic. It was
# once disabled for that reason, which broke the HA use case, so neither state is warned about
# here now.
if systemctl cat bluetooth.service >/dev/null 2>&1; then
  note "bluetooth: $(systemctl is-enabled bluetooth.service 2>/dev/null) / $(systemctl is-active bluetooth.service 2>/dev/null) (used by Home Assistant BLE)"
fi

sec saturation
# Added after a 2026-09-26 audit had to hand-query all of this. These are the numbers that
# say whether the box is actually under stress, as opposed to merely looking busy.
#
# PSI is the honest signal and it is deliberately preferred over MemFree here. MemFree on this
# box reads ~300MB and looks alarming, but that is the page cache doing its job; MemAvailable
# is ~14GB and PSI memory pressure is ~0. Reporting MemFree as a health number would
# manufacture a problem that does not exist, which is exactly the failure mode section 12 of
# docs/TUNING-FINDINGS.md exists to prevent.
if [ -r /proc/pressure/cpu ]; then
  for res in cpu memory io; do
    line=$(head -1 "/proc/pressure/$res" 2>/dev/null)
    a10=$(printf '%s' "$line"  | sed -n 's/.*avg10=\([0-9.]*\).*/\1/p')
    a60=$(printf '%s' "$line"  | sed -n 's/.*avg60=\([0-9.]*\).*/\1/p')
    note "PSI $res: some avg10=${a10:-?} avg60=${a60:-?}"
    # Flag only sustained stall. A spike in avg10 is normal on a box running ~90 containers;
    # avg60 above 20% means real work is waiting on that resource for a full minute.
    case "$res" in
      memory|io)
        if [ -n "$a60" ] && awk -v v="$a60" 'BEGIN{exit !(v>20)}' 2>/dev/null; then
          flag "PSI $res stall avg60=${a60}% - sustained pressure, not a transient spike"
        fi ;;
    esac
  done
fi
mem_avail=$(awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
mem_total=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
[ -n "$mem_avail" ] && note "memory available: ${mem_avail}MB of ${mem_total}MB (MemFree alone is misleading here: most of RAM is page cache)"
# zswap refault: how much of what was compressed out had to be pulled straight back. High is a
# sign the pool is under-sized for the working set, which is a capacity fact, not a bug.
if [ -r /proc/vmstat ]; then
  zrf=$(awk '/^zswpout /{o=$2} /^zswpin /{i=$2} END{ if(o>0) printf "%d", 100*i/o }' /proc/vmstat 2>/dev/null)
  [ -n "$zrf" ] && note "zswap refault: ${zrf}% of writeouts were read back"
fi
# conntrack: ~90 containers plus a torrent client is the workload most likely to exhaust this
# table, and a full table silently drops new connections. Audited at 4426/262144 (2%), so this
# is headroom reporting, not a known problem.
ctmax=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
ctcnt=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
if [ -n "$ctmax" ] && [ -n "$ctcnt" ] && [ "$ctmax" -gt 0 ] 2>/dev/null; then
  ctpct=$(( 100 * ctcnt / ctmax ))
  note "conntrack: ${ctcnt}/${ctmax} (${ctpct}%)"
  [ "$ctpct" -ge 80 ] && flag "conntrack table ${ctpct}% full - new connections will start dropping"
fi
fdused=$(awk '{print $1}' /proc/sys/fs/file-nr 2>/dev/null)
fdmax=$(cat /proc/sys/fs/file-max 2>/dev/null)
[ -n "$fdused" ] && [ -n "$fdmax" ] && note "open file descriptors: ${fdused}/${fdmax}"

sec device-health
# NVMe wear and integrity. media_errors and critical_warning are genuine defects and are
# flagged; percentage_used is lifetime consumed and is only worth a warning near end of life.
# unsafe_shutdowns is deliberately NOT flagged: the Micron 2200 in this box reports a
# spuriously high count (a known firmware quirk), so warning on it would be crying wolf.
if command -v nvme >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
  for dev in /dev/nvme0n1 /dev/nvme1n1; do
    [ -e "$dev" ] || continue
    log=$(nvme smart-log "$dev" 2>/dev/null) || continue
    model=$(cat "/sys/block/$(basename "$dev")/device/model" 2>/dev/null | tr -s ' ')
    cw=$(printf '%s' "$log"  | awk -F: '/critical_warning/{gsub(/ /,"",$2); print $2; exit}')
    pu=$(printf '%s' "$log"  | awk -F: '/percentage_used/{gsub(/[ %]/,"",$2); print $2; exit}')
    me=$(printf '%s' "$log"  | awk -F: '/media_errors/{gsub(/ /,"",$2); print $2; exit}')
    # smart-log prints "temperature : 52 C (325 K, 125 F)"; take the FIRST number only,
    # otherwise every digit on the line concatenates into nonsense like 42315107.
    tp=$(printf '%s' "$log"  | awk -F: '/^temperature/{print $2; exit}' | grep -oE '[0-9]+' | head -1)
    note "$(basename "$dev") ${model}: wear=${pu:-?}% temp=${tp:-?}C media_errors=${me:-?}"
    [ "${cw:-0}" != "0" ] && flag "$(basename "$dev") SMART critical_warning=$cw"
    [ -n "$me" ] && [ "$me" != "0" ] && flag "$(basename "$dev") has $me media errors"
    [ -n "$pu" ] && [ "$pu" -ge 90 ] 2>/dev/null && flag "$(basename "$dev") is ${pu}% through its rated write life"
  done
fi
# Thermal throttling is REPORTED, never flagged. BIOS owns PL1/PL2 and the fan curve on this
# box, and the 356H is silicon-capped at 80W MTP, so brief TjMax excursions under burst are
# the designed behaviour rather than a fault the OS should complain about.
thr=$(cat /sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count 2>/dev/null)
[ -n "$thr" ] && note "package throttle events since boot: $thr (BIOS owns the power/thermal envelope)"

sec net-steering
# Receive-side steering state. RPS/RFS are currently UNSET and that is not asserted either
# way: spreading softirq work across the P/E/LP-E cores is a plausible win but was never
# measured on this box, and section 12 forbids shipping a tuning change on mechanism alone.
# This section exists so the state is visible the next time someone proposes it.
for i in $(ls /sys/class/net 2>/dev/null | grep -E '^en'); do
  rq=$(ls -d /sys/class/net/"$i"/queues/rx-* 2>/dev/null | wc -l)
  rps=$(cat /sys/class/net/"$i"/queues/rx-0/rps_cpus 2>/dev/null | tr -d ',0')
  if [ -z "$rps" ]; then rps_state="off"; else rps_state="on"; fi
  note "$i: rx queues=${rq} rps=${rps_state}"
  rxd=$(cat /sys/class/net/"$i"/statistics/rx_dropped 2>/dev/null)
  rxe=$(cat /sys/class/net/"$i"/statistics/rx_errors 2>/dev/null)
  [ -n "$rxe" ] && [ "$rxe" -gt 0 ] 2>/dev/null && flag "$i has $rxe rx errors"
  [ -n "$rxd" ] && [ "$rxd" -gt 1000 ] 2>/dev/null && flag "$i has $rxd rx drops"
done

# Which interface actually carries egress. A 2026-09-26 audit found the 2x2.5GbE bond holding
# an address, both slaves linked at 2500 Mbps, and carrying literally zero outbound bytes:
# every packet was leaving over WiFi because bond0 had no route in any table. Nothing in this
# report would have shown that, and the repo meanwhile described the bond as the primary path.
#
# Reported, not flagged. Which link the operator wants as primary is their decision, and on
# this deployment WiFi 7 MLO measures as the bond's equal. The only thing warned about is
# having no default route at all, which is unambiguously broken.
egress_dev="$(ip route show default 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
if [ -n "$egress_dev" ]; then
  note "egress interface: $egress_dev (carries the default route)"
else
  flag "no default route on this box - it cannot reach anything off-subnet"
fi
for i in bond0 wlo1; do
  [ -e "/sys/class/net/$i" ] || continue
  tx=$(cat "/sys/class/net/$i/statistics/tx_bytes" 2>/dev/null || echo 0)
  rx=$(cat "/sys/class/net/$i/statistics/rx_bytes" 2>/dev/null || echo 0)
  nroute=$(ip route show dev "$i" 2>/dev/null | grep -c . || true)
  note "$i: tx=$((tx / 1073741824))GB rx=$((rx / 1073741824))GB routes=$nroute"
  # An interface that is UP with an address but has no route is inert for outbound traffic.
  # Worth surfacing precisely because it looks healthy in every other view.
  if [ "$nroute" -eq 0 ] && ip -br addr show "$i" 2>/dev/null | grep -q '[0-9]\{1,3\}\.[0-9]\{1,3\}'; then
    note "$i holds an address but has no route: it cannot originate outbound traffic"
  fi
done

sec update-pipeline
# The repo's whole promise is "always latest, never pinned", and that promise rests entirely
# on the updater timer actually firing. Nothing surfaced when it stopped: a 2026-09-26 audit
# found the box still running the updater script from e8df4f1 (three commits behind master)
# with no signal anywhere. The kernel itself was current, so the pipeline was working, but a
# silently dead timer would have looked exactly the same from outside.
#
# This section answers the question that actually matters: is the update path still running?
# It deliberately does NOT fetch anything from the network. A health report should not depend
# on GitHub being reachable, and it must never execute remote code to decide it is healthy.
if systemctl cat nuc16pro-kernel-updater.timer >/dev/null 2>&1; then
  tstate="$(systemctl is-enabled nuc16pro-kernel-updater.timer 2>/dev/null)/$(systemctl is-active nuc16pro-kernel-updater.timer 2>/dev/null)"
  note "updater timer: $tstate"
  case "$tstate" in
    enabled/active) ;;
    *) flag "updater timer is $tstate - the box will silently stop tracking upstream" ;;
  esac
  res="$(systemctl show -p Result --value nuc16pro-kernel-updater.service 2>/dev/null)"
  [ -n "$res" ] && note "last updater run result: $res"
  [ -n "$res" ] && [ "$res" != "success" ] && flag "last updater run result was '$res'"
fi
# Age of the last successful install. A pipeline that has not installed anything for weeks is
# either genuinely up to date or quietly broken; the tag plus its age lets a human tell which.
for f in /var/lib/nuc16pro-kernel-updater/last-installed-tag /var/lib/nuc16pro-kernel-updater/last-installed-scx-tag; do
  [ -r "$f" ] || continue
  tag="$(cat "$f" 2>/dev/null)"
  mt="$(stat -c %Y "$f" 2>/dev/null)"
  if [ -n "$mt" ]; then
    age=$(( ( $(date +%s) - mt ) / 86400 ))
    note "$(basename "$f"): $tag (${age}d ago)"
    # Age is REPORTED, never flagged. A first draft of this check warned at 30 days and
    # immediately cried wolf: the scx tag was 36 days old because sched-ext/scx had not cut
    # a release in 36 days, not because anything was broken. Staleness relative to upstream
    # is a question only the drift check can answer, and version-drift-check.yml already
    # answers it against the real upstream every 4 hours. Duplicating that here with a
    # calendar heuristic would produce exactly the kind of warning people learn to ignore.
    :
  else
    note "$(basename "$f"): $tag"
  fi
done
# Deployed updater identity. Reported, not asserted: the healthcheck has no trustworthy local
# copy of what master currently holds, so comparing here would either need the network or a
# stamp that can itself go stale. Printing the checksum lets a human or CI compare it against
# `md5sum scripts/nuc16pro-kernel-updater.sh` in the repo in one step.
if [ -r /usr/local/sbin/nuc16pro-kernel-updater.sh ]; then
  note "deployed updater: md5=$(md5sum /usr/local/sbin/nuc16pro-kernel-updater.sh 2>/dev/null | cut -d' ' -f1) mtime=$(date -d "@$(stat -c %Y /usr/local/sbin/nuc16pro-kernel-updater.sh)" +%Y-%m-%d 2>/dev/null)"
fi

echo "==== summary: warnings=$warn ===="
exit 0
