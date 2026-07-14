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

sec network
if [ -f /proc/net/bonding/bond0 ]; then
  mode=$(awk -F': ' '/Bonding Mode/{print $2; exit}' /proc/net/bonding/bond0)
  up=$(grep -c 'MII Status: up' /proc/net/bonding/bond0)
  note "bond0: ${mode:-?}; interfaces MII up: $up"
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
    h=$(smartctl -H "$d" 2>/dev/null | grep -iE 'overall-health|test result' | sed 's/.*: *//')
    note "$(basename "$d"): SMART ${h:-n/a}"
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

echo "==== summary: warnings=$warn ===="
exit 0
