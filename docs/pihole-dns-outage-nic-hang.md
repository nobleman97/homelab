# Incident: Pi-hole DNS outages — TX ring wedge on Proxmox host `proxmox`

**Date diagnosed:** 2026-08-28
**Affected service:** Pi-hole (CT `100`, hostname `pihole`, 192.168.100.30) — network-wide DNS
**Actual fault location:** Proxmox host **`proxmox`** (192.168.100.20) — onboard Intel NIC `nic0`
**Impact:** Whole-home DNS outage. Also takes down `k8s-control-plane-01` (102) and `k8s-worker-node-01` (103), which live on the same host.
**Status:** Root cause identified. **Fix not yet applied.**

---

## Summary

Pi-hole is not the problem. CT 100 has never crashed, never OOMed, and has never
been stopped except as part of a host boot.

The **onboard Intel I219 NIC on host `proxmox` wedges its transmit ring and never
recovers.** The kernel detects the hang, prints `Detected Hardware Unit Hang` every
two seconds — and then does nothing. The host keeps running with a completely dead
network until it is power-cycled, which is exactly the workaround being used.

Because `vmbr0` is bridged onto `nic0`, every guest on the host loses network at the
same instant. Pi-hole is simply the most visible casualty, because it is the DNS
server for the entire house.

---

## The distinguishing detail

This is **not** the same fault as `worker-2-nic-failure.md`, despite the same driver
and the same PCI address. The two hosts fail in opposite ways:

| | `david` (192.168.100.21) | `proxmox` (192.168.100.20) |
|---|---|---|
| Hardware | LENOVO 11DT006GAU ThinkCentre Tiny | HP EliteDesk 800 G6 Desktop Mini |
| Link speed at every link-up | **100 Mbps** (10/10) | **1000 Mbps** (35/35) |
| `NETDEV WATCHDOG` fires | 1158 today | **0, ever** |
| `Reset adapter unexpectedly` | 1243 today | **0, ever** |
| `Detected Hardware Unit Hang` | 160 today | 31,745 in the last month |
| Recovers on its own | Yes — seconds, repeatedly | **No — never** |
| Outage shape | Flapping, minutes at a time | **Permanent until power cycle** |

`david` has a **physical layer** fault: gigabit falls back to 100 Mbps because pairs
are missing, so the cable/port is the suspect there.

> **Superseded 2026-09-29.** The cable on `david` was replaced and its link now negotiates
> 1000 Mbps (4/4 link-ups). The comparison table above is therefore no longer current:
> `david` has stopped flapping and now wedges permanently with `Detected Hardware Unit Hang`
> and zero adapter resets — i.e. it has converged on the *same* fault as `proxmox` described
> here. Both hosts run kernel `7.0.14-14-pve` / PVE `9.2.11` on an Intel I219 at `00:1f.6`.
> Treat the driver mitigations below as applying to both. See
> `worker-2-nic-failure.md` § *2026-09-29 update*.

`proxmox` negotiates a clean 1000 Mbps Full Duplex on every single link-up and never
drops link. Its physical layer is fine. What fails is the **transmit ring inside the
controller**, and — critically — the driver never issues a reset, so nothing brings
it back. **Do not start by replacing the cable on this host; that is the fix for the
other one.**

---

## Evidence

### The wedge

```
Aug 28 13:09:30 proxmox kernel: e1000e 0000:00:1f.6 nic0: Detected Hardware Unit Hang:
  TDH                  <4>
  TDT                  <32>
  next_to_use          <32>
  next_to_clean        <3>
  next_to_watch.status <0>
MAC Status             <80083>
PHY Status             <796d>
PHY 1000BASE-T Status  <3800>
```

`TDH` (transmit descriptor head) is stuck at 4 while `TDT` (tail) sits at 32 — the
hardware has 28 packets queued and has stopped consuming them. Every subsequent
message reports the **identical** descriptor values. The ring never moves again.

The message repeats on a strict two-second cadence from the moment of the wedge
until the plug is pulled:

```
13:09:30  13:09:32  13:09:34  13:09:36  13:09:38  13:09:40  ...
```

### Confirmed causal chain

```
12:49:07  corosync: link: host: 2 link: 0 is down          <- network dies
12:49:08  kernel:   e1000e nic0: Detected Hardware Unit Hang
12:49:13  corosync: A new membership formed. Members left: 2
12:49:13  pmxcfs:   node lost quorum
12:50:10  pvescheduler: cfs-lock error: no quorum!
   ...    (15 minutes of nothing but hang messages — DNS is down house-wide)
13:04:44  last hang message
   --     Reboot --                                        <- hard power cycle
13:06:15  kernel: Linux version ... (boot)
13:06:27  startall -> vzstart 100, qmstart 102, qmstart 103
```

There is **no shutdown sequence** before any of these reboots — zero
`systemd-shutdown` / `Unmounting` records. Every one was a hard power cycle.

### Today's reboot pattern (host local time, UTC+1)

| Boot | First hang | Dead for | Hangs |
|---|---|---|---|
| 11:15:15 | 12:49:08 | 15 min | 469 |
| 13:06:15 | 13:09:30 | 9 min | 267 |
| 13:19:33 | 13:46:38 | 3 min | 82 |
| 13:50:50 | — | — | 0 |

Time-to-failure after boot was 1h34m, then 3m, then 27m. It is not on a timer and
it is not load-predictable — but once it hangs, it is over.

### It is not new, and it is episodic

`Detected Hardware Unit Hang` count per day, from the host journal:

| Date | Hangs | | Date | Hangs |
|---|---|---|---|---|
| Jul 26 | 2694 | | Aug 06 | 1936 |
| Jul 27 | 4577 | | Aug 12 | 154 |
| Jul 28 | 7657 | | Aug 13 | 915 |
| Jul 29 | 891 | | Aug 17 | 464 |
| Aug 01 | 2213 | | Aug 20 | 9807 |
| Aug 02 | 437 | | Aug 28 | 1022 (partial) |

Days not listed had zero. Aug 21–27 was a clean seven-day run, which is why this
feels intermittent. The host was booted on 18 separate days in the last month.

### Ruled out

- **Pi-hole / CT 100 itself** — 138 MB of its 512 MB in use, no OOM kills anywhere
  in a month of host journal, and `vzstart 100` only ever appears as part of
  `startall` at host boot. The container has never failed independently.
- **Cabling / switch port** — 35 of 35 link-ups at 1000 Mbps Full Duplex, only 2
  `NIC Link is Down` events in a month. The physical link is stable.
- **Host resource exhaustion** — 7.1 GB of 16 GB used, 0 swap, root filesystem 10% full.
- **A second NIC to fall back to** — `/etc/network/interfaces` lists a `nic1`, but no
  such device is ever probed by the kernel. It is a stale entry. The only other
  network hardware is the Wi-Fi AX201 (`wlp0s20f3`).

### Affected hardware

| Field | Value |
|---|---|
| System | `HP EliteDesk 800 G6 Desktop Mini PC/8710` |
| BIOS | `S21 Ver. 02.22.00` (2024-12-31) |
| CPU | Intel Core i5-10400T |
| NIC | Intel PRO/1000, PCI `0000:00:1f.6`, driver `e1000e`, MAC `50:81:40:97:31:11` |
| PHY identifiers | `MAC: 13, PHY: 12` → **Intel I219-V**, PCH-integrated |
| Interface | `eth0` → `eno1` → `nic0`, enslaved to `vmbr0` |
| Kernel | `6.17.9-1-pve` |

Note `proxmox` is on kernel `6.17.9-1-pve` while `david` runs `6.17.13-2-pve`.

---

## The fix

Work through in order. Stop when the host survives a full day with zero hangs.

### Step 0 — Make it self-heal *(do this first, it is the outage killer)*

Even before the underlying fault is fixed, the host should not need a human with a
power button. The driver detects the wedge but never resets, so add a watchdog that
does. Two decisions matter in how this is built.

**Bounce the link — do not reload the module.** `modprobe -r e1000e` destroys the
interface, and `nic0` is enslaved to `vmbr0`. Bridge membership does not survive the
device being removed: Proxmox applies `bridge-ports` at `ifup` time, not on hotplug,
so the NIC comes back **detached** and the host stays off the network until someone
walks over. On this host that would drop the control plane, worker-1 and the Proxmox
API simultaneously — including the web UI you would use to fix it. A link bounce
clears a wedged TX ring without touching bridge membership.

**Use a real unit — not `systemd-run`.** `systemd-run` creates a *transient* unit in
`/run/systemd/transient/`, which is tmpfs and is erased on reboot. That is precisely
when the watchdog is needed again, so a transient unit is guaranteed to be missing at
the worst moment. Confirm with `systemctl show <unit> -p Transient`.

The script:

```bash
cat >/usr/local/sbin/nic0-unwedge <<'SH'
#!/bin/bash
# e1000e I219 wedges its TX ring and never self-resets. Detect and bounce the link.
STAMP=/run/nic0-unwedge.last

# Cooldown. The detection window (70s) is wider than the timer interval (30s), so
# without this the same burst of hangs triggers a second and third bounce.
if [ -f "$STAMP" ] && [ $(( $(date +%s) - $(stat -c %Y "$STAMP") )) -lt 300 ]; then
  exit 0
fi

# No -n line cap: at a high hang rate a cap truncates the window and undercounts.
hangs=$(journalctl -k --since "70 seconds ago" --no-pager \
        | grep -c "Detected Hardware Unit Hang")
[ "$hangs" -ge 10 ] || exit 0

touch "$STAMP"
logger -t nic0-unwedge "TX ring wedged ($hangs hangs/70s) - bouncing link"
ip link set nic0 down
sleep 2
ip link set nic0 up

# Defensive re-enslave. A no-op when nic0 is still attached to the bridge.
sleep 3
ip link show nic0 | grep -q 'master vmbr0' || ip link set nic0 master vmbr0
SH
chmod +x /usr/local/sbin/nic0-unwedge
```

The units:

```bash
cat >/etc/systemd/system/nic0-unwedge.service <<'SH'
[Unit]
Description=Bounce nic0 when the e1000e TX ring wedges

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nic0-unwedge
SH

cat >/etc/systemd/system/nic0-unwedge.timer <<'SH'
[Unit]
Description=Check for a wedged nic0 every 30s

[Timer]
OnBootSec=60
OnUnitActiveSec=30
AccuracySec=1s

[Install]
WantedBy=timers.target
SH
```

`OnUnitActiveSec=30` measures from the end of the previous run rather than the wall
clock, so a slow check can never overlap itself — which `OnCalendar='*:*:0/30'` can.
`OnBootSec=60` gives the network a moment to settle before the first check.

Install, clearing any transient unit left over from an earlier attempt:

```bash
systemctl stop nic0-unwedge.timer 2>/dev/null   # removes a transient unit if present
systemctl daemon-reload
systemctl enable --now nic0-unwedge.timer
```

Verify it is persistent and scheduled:

```bash
systemctl show nic0-unwedge.timer -p Transient   # want Transient=no
systemctl list-timers nic0-unwedge.timer         # next elapse should be within 30s
journalctl -t nic0-unwedge -f                    # watch it act during a real wedge
```

This converts a "power-cycle the house DNS" event into a ~10-second blip.

If a link bounce ever proves insufficient and you do fall back to reloading the
module, keep the `ip link set nic0 master vmbr0` line after it. That single line is
what stops the cure being worse than the disease.

### Step 1 — Disable the offloads that trigger the I219 hang

The Intel I219 family has long-standing, well-documented `Hardware Unit Hang` errata
tied to TCP segmentation offload. With a clean physical layer, this is by far the most
likely cause here. Test interactively:

```bash
ethtool -K nic0 tso off gso off gro off
ethtool --set-eee nic0 eee off
```

Watch for several hours:

```bash
journalctl -kf | grep -i 'Hardware Unit Hang'
```

If stable, persist in `/etc/network/interfaces` under the physical interface:

```
iface nic0 inet manual
    post-up /sbin/ethtool -K nic0 tso off gso off gro off || true
    post-up /sbin/ethtool --set-eee nic0 eee off || true
```

#### Making the offloads survive device re-creation

The `post-up` lines above run on `ifup`, which covers a reboot. They do **not** run
when the netdev is destroyed and recreated — which is what the Step 0 `modprobe`
fallback does. The interface returns with driver defaults, so `tso`/`gso`/`gro` flip
back **on** and the workaround is silently lost.

A plain boot-time service would not catch that either. Bind the unit to the *device*
instead, so it re-runs every time `nic0` appears:

```bash
cat >/etc/systemd/system/nic0-offloads.service <<'SH'
[Unit]
Description=Apply e1000e I219 offload workarounds to nic0
BindsTo=sys-subsystem-net-devices-nic0.device
After=sys-subsystem-net-devices-nic0.device

[Service]
Type=oneshot
RemainAfterExit=yes
# '-' prefixes tolerate a NIC or driver that does not implement the knob.
ExecStart=-/sbin/ethtool -K nic0 tso off gso off gro off
ExecStart=-/sbin/ethtool --set-eee nic0 eee off

[Install]
WantedBy=sys-subsystem-net-devices-nic0.device
SH

systemctl daemon-reload
systemctl enable --now nic0-offloads.service
```

`WantedBy=sys-subsystem-net-devices-nic0.device` is the part that matters: systemd
synthesises a unit per network device, so this fires on boot *and* on any later
re-appearance of the interface. Verify:

```bash
systemctl status nic0-offloads.service
ethtool -k nic0 | grep -E 'tcp-segmentation|generic-segmentation|generic-receive'
```

All three should read `off`. Re-check after any module reload — that is the case this
unit exists to cover. If you adopt this unit you can drop the `post-up` lines, though
leaving both is harmless and belt-and-braces.

If it still hangs, add — this costs measurable CPU, so only if needed:

```bash
ethtool -K nic0 tx off rx off
```

And disable PCIe Active State Power Management, a known aggravator on this chipset.
Append to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, then `update-grub`
and reboot:

```
pcie_aspm=off
```

### Step 2 — Update the kernel

`proxmox` is on `6.17.9-1-pve`; `david` is already on `6.17.13-2-pve`. Bring it
forward and reboot — `e1000e` fixes land regularly:

```bash
apt update && apt full-upgrade
```

A BIOS update is worth a look too, though `S21 Ver. 02.22.00` (2024-12-31) is
reasonably current.

### Step 3 — If it still hangs, add a USB gigabit adapter

The EliteDesk 800 G6 Desktop Mini has no usable PCIe slot and its `nic1` entry is
stale, so a USB adapter is the practical replacement.

- **Insist on a known chipset**: **Realtek RTL8153** or **ASIX AX88179A**. Both are
  supported in-kernel (`r8152`, `ax88179_178a`) with no driver install.
- **Avoid unbranded adapters** that don't name a chipset — many are RTL8152, which is
  100 Mbps only.
- **Use a USB 3.0 port** (blue / marked SS); USB 2.0 caps throughput near 280 Mbps.
- Move `bridge_ports` on `vmbr0` from `nic0` to the new interface, and pin its name
  with a systemd `.link` file matched on MAC so it survives reboots.
- Leave `nic0` unconfigured and off the bridge afterwards.

---

## Reduce the blast radius regardless

1. **Run a second DNS resolver on a different physical host.** Right now the entire
   house has a single point of failure sitting on one flaky NIC. A second Pi-hole (or
   plain `unbound`/`dnsmasq`) as a container on `david`, handed out as the secondary
   DNS server by DHCP, turns this outage class into a non-event. This is the single
   highest-value change on this page.
2. **Set the router's secondary DNS to something external** (1.1.1.1) as a stopgap if
   a second resolver is not worth the effort yet. Ad blocking is lost during a
   failover, but the house stays online.
3. **Alert on it.** A log alert on `Detected Hardware Unit Hang` would have caught
   this in July. It is already in the journal on both hosts.
4. **Both Proxmox hosts now have NIC faults** (different faults, same blast radius).
   Neither host should be a single point of failure for the other's critical services.

---

## How to confirm the fix worked

```bash
# No new hangs accumulating
journalctl -k --since "24 hours ago" | grep -c 'Detected Hardware Unit Hang'   # want 0

# Link still gigabit
ethtool nic0 | grep -E 'Speed|Duplex|Link detected'

# Error counters not climbing
watch -n5 "ethtool -S nic0 | grep -iE 'tx_timeout|error|dropped|discard'"

# No unexpected host boots
# (Proxmox -> proxmox -> Task History: startall entries should stop appearing)
```

Success criterion: **zero `Detected Hardware Unit Hang` over 24 hours, and no
`startall` task on `proxmox` that you did not initiate.**
