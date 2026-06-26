#!/bin/bash
# nuc16pro NIC bond apply - auto-detects everything, NO host-specific values hardcoded.
#
# Bonds the box's two Intel igc 2.5GbE ports. Default mode balance-xor (matches a STATIC
# switch LAG, e.g. Grandstream GWN7721 which has no LACP); pass "802.3ad" as arg 1 if your
# switch does LACP. Clones the current primary NIC's MAC onto the bond so the existing DHCP
# lease / IP (and any router port-forwards) are preserved. Generates
# /etc/netplan/99-nuc16pro-bond.yaml on the box from runtime detection.
#
# RUN FROM THE PHYSICAL CONSOLE. Applying briefly drops SSH while the IP moves to bond0.
# SELF-REVERTING: if the box cannot reach its gateway within ~180s it auto-restores the old
# network config, so it is safe to run even before the switch LAG exists (it just reverts).
# PREREQ: a matching LAG on the switch ports (static trunk for balance-xor, LACP for 802.3ad).
set -u
[ "$(id -u)" = 0 ] || { echo "run with sudo: sudo bash $0 [balance-xor|802.3ad]"; exit 1; }

MODE="${1:-balance-xor}"
REVERT_AFTER=180

# --- auto-detect: two igc NICs, primary NIC's MAC (to clone), gateway, current IP ---
mapfile -t NICS < <(for n in /sys/class/net/*; do
  [ -e "$n/device/driver" ] || continue
  [ "$(basename "$(readlink -f "$n/device/driver")")" = igc ] || continue
  basename "$n"
done | sort)
[ "${#NICS[@]}" -ge 2 ] || { echo "need >=2 igc NICs, found: ${NICS[*]:-none}"; exit 1; }

PRIMARY="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
GW="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"
[ -n "${PRIMARY:-}" ] && [ -e "/sys/class/net/$PRIMARY/address" ] || { echo "no default route to detect MAC/IP"; exit 1; }
MAC="$(cat "/sys/class/net/$PRIMARY/address")"
WANT_IP="$(ip -4 -o addr show "$PRIMARY" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
[ -n "${MAC:-}" ] && [ -n "${WANT_IP:-}" ] && [ -n "${GW:-}" ] || { echo "could not detect MAC/IP/GW"; exit 1; }

echo "detected: nics='${NICS[*]}' primary=$PRIMARY mode=$MODE (cloning primary MAC, preserving IP/gateway)"

BK=/root/netplan-bak-$(date +%s)
echo "== backup /etc/netplan -> $BK =="; mkdir -p "$BK"; cp -a /etc/netplan/. "$BK"/

cat > /usr/local/sbin/nuc16pro-bond-revert.sh <<REV
#!/bin/bash
rm -f /etc/netplan/99-nuc16pro-bond.yaml
cp -a "$BK"/. /etc/netplan/
chmod 600 /etc/netplan/*.yaml 2>/dev/null
netplan apply
logger -t nuc16pro-bond "network ROLLED BACK to pre-bond config"
REV
chmod +x /usr/local/sbin/nuc16pro-bond-revert.sh

echo "== arm independent auto-revert in ${REVERT_AFTER}s (survives SSH drop, owned by PID1) =="
systemctl stop nuc16pro-bond-revert.timer 2>/dev/null
systemd-run --on-active=${REVERT_AFTER} --unit=nuc16pro-bond-revert \
  --timer-property=AccuracySec=1s /usr/local/sbin/nuc16pro-bond-revert.sh >/dev/null 2>&1 \
  && echo "  armed (cancel: systemctl stop nuc16pro-bond-revert.timer)" || echo "  WARN: timer not armed"

echo "== remove conflicting standalone stanzas (backed up; wifi profiles kept) =="
rm -f /etc/netplan/00-installer-config.yaml
for f in /etc/netplan/90-NM-*.yaml; do
  [ -e "$f" ] || continue
  grep -qiE "wifi|wireless" "$f" && continue
  grep -qiE "ethernet|set-name" "$f" && rm -f "$f"
done

echo "== generate bond config from detection =="
{
  echo "network:"
  echo "  version: 2"
  echo "  renderer: NetworkManager"
  echo "  bonds:"
  echo "    bond0:"
  echo "      interfaces: [${NICS[0]}, ${NICS[1]}]"
  echo "      macaddress: \"$MAC\""
  echo "      dhcp4: true"
  echo "      dhcp6: true"
  echo "      parameters:"
  echo "        mode: $MODE"
  [ "$MODE" = "802.3ad" ] && echo "        lacp-rate: fast"
  echo "        mii-monitor-interval: 100"
  echo "        transmit-hash-policy: layer3+4"
} > /etc/netplan/99-nuc16pro-bond.yaml
chmod 600 /etc/netplan/99-nuc16pro-bond.yaml

echo "== validate =="
if ! netplan generate 2>/tmp/np.err; then
  echo "!! netplan generate FAILED; restoring now:"; cat /tmp/np.err
  systemctl stop nuc16pro-bond-revert.timer 2>/dev/null
  /usr/local/sbin/nuc16pro-bond-revert.sh
  exit 1
fi

echo "== apply (SSH may drop here) =="; netplan apply; sleep 20
IP_OK=0; ip -4 addr show bond0 2>/dev/null | grep -qw "$WANT_IP" && IP_OK=1
PING_OK=0; ping -c3 -W2 "$GW" >/dev/null 2>&1 && PING_OK=1
echo "== result: bond0_kept_ip=$IP_OK gateway_ping=$PING_OK =="
grep -iE "Bonding Mode|MII Status|Link Failure|Slave Interface" /proc/net/bonding/bond0 2>/dev/null | head -20
for n in "${NICS[@]}"; do echo "tx_$n=$(cat /sys/class/net/$n/statistics/tx_packets 2>/dev/null)"; done

if [ "$IP_OK" = 1 ] && [ "$PING_OK" = 1 ]; then
  systemctl stop nuc16pro-bond-revert.timer 2>/dev/null
  echo
  echo "== BOND LIVE ($MODE). rollback cancelled. =="
  echo "   Aggregating when both tx_ counters climb under multi-flow load and both slaves show MII up."
else
  echo
  echo "!! NO connectivity -> auto-revert restores the old config within ${REVERT_AFTER}s."
  echo "   Check the switch LAG exists on those ports and its type matches MODE ($MODE)."
fi
