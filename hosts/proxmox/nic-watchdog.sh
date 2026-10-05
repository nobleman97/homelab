#!/bin/bash
# Recover an e1000e NIC whose transmit ring has wedged.
#
# Both Proxmox hosts (`david`, `proxmox`) run an Intel I219 on the e1000e
# driver that stops consuming its TX ring. The kernel notices and prints
# "Detected Hardware Unit Hang" every 2 seconds -- and then does nothing: no
# adapter reset, no NETDEV WATCHDOG. The host keeps running with a dead
# network until someone power-cycles it. See docs/worker-2-nic-failure.md.
#
# This closes that gap: detect the hang, bounce the interface, and if that is
# not enough, reload the driver.
#
# Worst case is the status quo. If recovery fails the host still has no
# network, which is exactly where it was -- and a power cycle still fixes it.

set -euo pipefail

IFACE="${IFACE:-nic0}"
BRIDGE="${BRIDGE:-vmbr0}"
WINDOW="${WINDOW:-2min}"      # how far back to look for hang messages
THRESHOLD="${THRESHOLD:-3}"   # hangs within WINDOW before we act (~6s of wedge)
MAX_PER_HOUR="${MAX_PER_HOUR:-6}"
STATE_DIR=/run/nic-watchdog
ESCALATE="${ESCALATE:-1}"     # 0 = link bounce only, never reload the module

mkdir -p "$STATE_DIR"
STAMPS="$STATE_DIR/actions"

log() { logger -t nic-watchdog -p daemon.warning -- "$*"; echo "nic-watchdog: $*"; }

# Re-apply the I219 mitigations. Both a module reload and (harmlessly) a link
# bounce can drop these, and they are runtime-only either way.
apply_mitigations() {
    ethtool --set-eee "$IFACE" eee off        2>/dev/null || true
    ethtool -K "$IFACE" tso off gso off gro off 2>/dev/null || true
}

hang_count() {
    journalctl -k --since "-${WINDOW}" --no-pager 2>/dev/null \
        | grep -c 'Detected Hardware Unit Hang' || true
}

# Rate limit: refuse to thrash if recovery is not working.
rate_limited() {
    local now cutoff recent
    now=$(date +%s); cutoff=$(( now - 3600 ))
    touch "$STAMPS"
    recent=$(awk -v c="$cutoff" '$1 > c' "$STAMPS" | wc -l)
    awk -v c="$cutoff" '$1 > c' "$STAMPS" > "$STAMPS.tmp" && mv "$STAMPS.tmp" "$STAMPS"
    [ "$recent" -ge "$MAX_PER_HOUR" ]
}

count=$(hang_count)
[ "$count" -lt "$THRESHOLD" ] && exit 0

if rate_limited; then
    log "wedge detected ($count hangs/${WINDOW}) but ${MAX_PER_HOUR} recoveries already this hour; not acting. The NIC likely needs replacing."
    exit 0
fi
date +%s >> "$STAMPS"

log "wedge detected: $count hang messages in ${WINDOW}. Bouncing $IFACE."
ip link set "$IFACE" down || true
sleep 3
ip link set "$IFACE" up || true
apply_mitigations
sleep 15

if [ "$(hang_count)" -lt "$THRESHOLD" ]; then
    log "link bounce cleared the wedge."
    exit 0
fi

if [ "$ESCALATE" != "1" ]; then
    log "still wedged after bounce; escalation disabled, leaving for manual recovery."
    exit 1
fi

log "still wedged after bounce. Reloading e1000e."
modprobe -r e1000e || true
sleep 2
modprobe e1000e || { log "FAILED to reload e1000e -- host needs a power cycle."; exit 1; }
sleep 5

# A reload recreates the interface; re-enslave it if the bridge lost the port.
if ! ip link show "$IFACE" 2>/dev/null | grep -q "master $BRIDGE"; then
    ip link set "$IFACE" master "$BRIDGE" 2>/dev/null || true
fi
ip link set "$IFACE" up || true
apply_mitigations

if [ "$(hang_count)" -lt "$THRESHOLD" ]; then
    log "driver reload cleared the wedge."
else
    log "still wedged after driver reload -- host needs a power cycle."
    exit 1
fi
