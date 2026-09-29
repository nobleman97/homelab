# Proxmox host NIC mitigations

For the Intel I219 / `e1000e` transmit-ring hang affecting **both** Proxmox hosts:

| | `david` (192.168.100.21) | `proxmox` (192.168.100.20) |
|---|---|---|
| Hardware | LENOVO 11DT006GAU ThinkCentre Tiny | HP EliteDesk 800 G6 Mini |
| Kernel / PVE | 7.0.14-14-pve / 9.2.11 | 7.0.14-14-pve / 9.2.11 |
| NIC | e1000e I219 @ `00:1f.6` | e1000e I219 @ `00:1f.6` |

Background: `docs/worker-2-nic-failure.md`, `docs/pihole-dns-outage-nic-hang.md`.

The kernel detects the wedge (`Detected Hardware Unit Hang`, every 2s) but never
resets the adapter — zero `Reset adapter unexpectedly` and zero `NETDEV WATCHDOG`
events across a full day. So the host keeps running with a dead network until it is
power-cycled by hand. These two units close that gap.

---

## 1. `nic-mitigations.service` — make the ethtool settings survive reboot

Disables Energy Efficient Ethernet (the most common I219 hang trigger) and the
segmentation/receive offloads, at every boot.

**This is the urgent one.** `ethtool` changes are runtime-only, so the settings are
lost on the next reboot — which, for this fault, is the power cycle you perform to
recover from a wedge. Without persistence, each recovery silently reverts the
mitigation and the next interval tests nothing.

Your existing runbook persists these via `post-up` lines in
`/etc/network/interfaces`. Either approach works; use **one**, not both. The unit is
preferred if you use `ifupdown2` (Proxmox default), where `post-up` ordering around
bridge enslavement is fiddly.

## 2. `nic-watchdog.timer` — recover automatically instead of by hand

Every minute, counts `Detected Hardware Unit Hang` messages in the last 2 minutes.
On 3 or more it bounces the link, and if that does not clear it, reloads `e1000e`
and re-enslaves the interface to `vmbr0`. Re-applies the mitigations afterwards,
since a module reload drops them.

Rate-limited to 6 recoveries per hour. Past that it logs and stops, on the grounds
that a NIC needing more than that needs replacing, not restarting.

**Risk is bounded:** if recovery fails, the host has no network — exactly where it
was already — and a power cycle still fixes it. Set `ESCALATE=0` in the service file
to bounce the link only and never touch the driver.

This is a band-aid over failing hardware. It converts a multi-hour outage into a
~20-second blip; it does not make the NIC healthy. Step 3 of the runbook (a USB 3.0
adapter with an RTL8153 or AX88179A chipset) remains the real fix.

---

## Install

Run on **each** host, as root. The Proxmox web console (Datacenter → *node* → Shell)
is the easiest route.

```bash
install -m 0755 nic-watchdog.sh        /usr/local/sbin/nic-watchdog.sh
install -m 0644 nic-watchdog.service   /etc/systemd/system/
install -m 0644 nic-watchdog.timer     /etc/systemd/system/
install -m 0644 nic-mitigations.service /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now nic-mitigations.service
systemctl enable --now nic-watchdog.timer
```

Confirm the interface name first — it is `nic0` on both hosts today, but it is a
renamed `eno2`/`eth0`, so check before assuming:

```bash
ip -br link show | grep -v '^lo\|^vmbr\|^tap\|^veth'
```

If it differs, set `Environment=IFACE=<name>` in both service files.

## Verify

```bash
# Mitigations actually applied
ethtool --show-eee nic0 | grep -i 'EEE status'      # want: disabled
ethtool -k nic0 | grep -E 'tcp-segmentation|generic-(segmentation|receive)'  # want: off

# Timer is live
systemctl list-timers nic-watchdog.timer

# Watchdog activity (nothing logged = nothing wedged, which is the goal)
journalctl -t nic-watchdog --no-pager

# Dry-run the detection logic without waiting for a wedge
THRESHOLD=1 WINDOW=24h /usr/local/sbin/nic-watchdog.sh
```

The last one will trigger a real recovery if the host has hung in the past 24h —
run it when a short network blip is acceptable.

## Success criterion

Per `worker-2-nic-failure.md`: gigabit link, zero adapter resets over 24 hours, and
`k3s-worker-2` continuously `Ready`. Judge the mitigations against that, not against
a quiet hour — the clean interval has already been 52 min and 142 min today, and
both ended in a wedge.
