# Incident: `k3s-worker-2` repeated outages — failing NIC on Proxmox host `david`

**Date diagnosed:** 2026-08-28
**Affected node:** `k3s-worker-2` (VM `k8s-worker-node-02`, vmid 106, 192.168.100.27)
**Actual fault location:** Proxmox host **`david`** (192.168.100.21) — onboard Intel NIC
**Impact:** Repeated cluster-wide outages since at least 2026-08-06. Every occurrence takes down Authentik (`auth.osose.xyz`) and n8n, because the single-instance `master-db` keeps being scheduled onto this node.
**Status:** Root cause identified. **Step 1 (cable) applied 2026-09-29 — it fixed the link
speed but did NOT stop the outages.** The fault has changed shape; see
*[2026-09-29 update](#2026-09-29-update-cable-replaced-fault-persists)* at the end of this
document before acting on the fix steps below.

---

## Summary

`k3s-worker-2` was never the problem. It does not crash, and neither does the VM.

The **onboard NIC on its Proxmox host `david` is physically failing**. Every few minutes the transmit ring wedges, the driver resets the adapter, and the `vmbr0` bridge port is disabled — which removes *all* network from the only VM on that host. The kubelet stops posting status, Kubernetes marks the node `NotReady`, and anything depending on it fails.

The decisive detail: the link renegotiates at **100 Mbps Full Duplex on gigabit hardware, every single time — 10 out of 10 observed link-ups, never once at 1000 Mbps.** That is a physical-layer fault, not a software one.

---

## Why this was misdiagnosed for three weeks

The failure presents identically to a dead machine, which sent every previous investigation down the wrong path:

| Observation | Wrong conclusion drawn | What is actually happening |
|---|---|---|
| `No route to host` on all ports | Host is powered off / hung | Host is **running fine**; its bridge port is disabled |
| Node flaps `NotReady` | k3s / kubelet instability | Kubelet is healthy; it has no network |
| Pods strand `Terminating` | Longhorn or CNPG bug | Normal behaviour when a kubelet is unreachable |
| `sdf: Medium Error`, `EXT4 remounting read-only` | **Failing disk** | Longhorn replicas are on *other* nodes; every write crosses the network. The NIC died mid-write and the kernel surfaced it as SCSI errors |
| worker-2 runs k3s v1.35.4 vs v1.34.5 control plane | Version skew was causing it | Skew is real and unsupported, but **incidental** — not the cause |

The most expensive misread was the disk one. There is no disk fault on `david`.

---

## Evidence

From `david`'s kernel journal, repeating every 2–5 minutes:

```
10:55:20 david kernel: e1000e 0000:00:1f.6 nic0: NETDEV WATCHDOG: CPU: 6: transmit queue 0 timed out 5536 ms
10:55:20 david kernel: e1000e 0000:00:1f.6 nic0: Reset adapter unexpectedly
10:55:20 david kernel: vmbr0: port 1(nic0) entered disabled state
10:55:41 david kernel: e1000e 0000:00:1f.6 nic0: NIC Link is Up 100 Mbps Full Duplex, Flow Control: None
10:55:41 david kernel: vmbr0: port 1(nic0) entered forwarding state
10:58:45 david kernel: e1000e 0000:00:1f.6 nic0: NETDEV WATCHDOG: transmit queue 0 timed out 5608 ms
```

**The fault is accelerating:**

| Date | `Reset adapter unexpectedly` events |
|---|---|
| 2026-08-20 | 59 |
| 2026-08-27 | 1881 |
| 2026-08-28 (partial day) | 1386 |

In a single boot window: **8 adapter resets and 160 `Detected Hardware Unit Hang` events.**

**Link speed across every observed link-up:**

```
{'100': 10}     # ten link-ups, all at 100 Mbps. Zero at 1000 Mbps.
```

### Affected hardware

| Field | Value |
|---|---|
| System | `LENOVO 11DT006GAU/316E` (ThinkCentre "Tiny" 1-litre chassis) |
| BIOS | `M2WKT5AA` (2023-06-20) |
| NIC | Intel PRO/1000, PCI `0000:00:1f.6`, driver `e1000e` |
| PHY identifiers | `MAC: 13, PHY: 12` → **Intel I219-V**, PCH-integrated |
| Interface name | `eth0` at probe, renamed to `nic0`, enslaved to `vmbr0` |

### Confirmed causal chain

1. `10:38:18` — NIC TX ring wedges; `Reset adapter unexpectedly`; `vmbr0` port disabled
2. `10:38:32` — worker-2 kubelet: `Failed to update lease ... context deadline exceeded`
3. `10:38:40` — worker-2 kernel: `[sdf] Sense Key : Medium Error` → `EXT4-fs (sdf): Remounting filesystem read-only` *(network-induced, not disk)*
4. `10:39:04` — API server: `Kubelet stopped posting node status` → `NotReady`
5. `~10:44:04` — taint eviction sets `deletionTimestamp` on `master-db-1`; pod strands `Terminating`
6. — `master-db-rw` / `-ro` / `-r` endpoints all become `<none>`
7. — Authentik: `connection to server at "10.43.64.71", port 5432 failed: Connection refused` → gunicorn never boots → startup probe 502s → container killed on a ~10-minute cycle

Worker-2's boot times correlate **1:1** with `startall` / `qmstart 106` tasks on host `david`. The VM never crashes on its own; its host loses network and gets power-cycled.

---

## The hardware fix

Work through these in order. Stop when the link comes up at 1000 Mbps and stays there.

### Step 1 — Replace the cable and change switch port *(do this first)*

The 100 Mbps-only negotiation is the single strongest clue. Gigabit Ethernet (1000BASE-T) requires **all four twisted pairs**. 100BASE-TX needs only two. When a gigabit link consistently falls back to 100 Mbps, the near-universal cause is that **one or both of the other two pairs are not making a connection** — a damaged cable, a broken retention clip letting the plug sit loose, a bent or corroded pin in the jack, or a failing switch port.

Concretely:

1. **Replace the patch cable entirely** — do not just reseat it. Use a known-good **Cat5e or Cat6** cable. Cat5e is sufficient; gigabit does not need Cat6. Prefer a factory-moulded cable over a hand-crimped one — hand-crimped ends are a very common source of exactly this fault.
2. **Move to a different port on the switch.** If the switch has link-speed LEDs, confirm it now shows gigabit.
3. **Inspect the jack on the ThinkCentre** for bent pins or debris — a torch and a good look is enough.
4. **Verify** on `david`:
   ```bash
   ethtool nic0 | grep -E 'Speed|Duplex|Link detected'
   ```
   You want `Speed: 1000Mb/s`, `Duplex: Full`, `Link detected: yes`.
5. **Check the error counters**, which should stop climbing:
   ```bash
   watch -n5 "ethtool -S nic0 | grep -iE 'tx_timeout|error|dropped|discard'"
   ```

This step costs a few pounds and fixes the majority of cases with this signature.

### Step 2 — If it still resets, apply the driver mitigations

The Intel **I219** family has long-standing, well-documented `Hardware Unit Hang` bugs. If the physical layer is now clean (1000 Mbps, stable) but resets continue, disable the features known to trigger it. Test interactively first:

```bash
# Energy Efficient Ethernet — the most common I219 culprit
ethtool --set-eee nic0 eee off

# TCP/generic segmentation and receive offload
ethtool -K nic0 tso off gso off gro off

# Only if the above is insufficient — costs measurable CPU
ethtool -K nic0 tx off rx off
```

Watch for an hour. If stable, persist it in `/etc/network/interfaces` under the physical interface:

```
iface nic0 inet manual
    post-up /sbin/ethtool --set-eee nic0 eee off || true
    post-up /sbin/ethtool -K nic0 tso off gso off gro off || true
```

If resets persist, also try disabling PCIe Active State Power Management, a known aggravator on this chipset. Append to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, then `update-grub` and reboot:

```
pcie_aspm=off
```

A BIOS update is also worth considering — the installed BIOS `M2WKT5AA` dates from 2023-06-20, and Lenovo has shipped NIC-related fixes for this platform since.

### Step 3 — If it still resets, the NIC itself is dead: add a USB gigabit adapter

At 1881 resets in a day and climbing, replacement is the realistic endpoint. **Important constraint: the ThinkCentre Tiny is a 1-litre chassis with no usable PCIe slot** — a standard PCIe network card is not an option. Two routes:

**Option A — USB 3.0 gigabit adapter (recommended).** Cheap, immediate, no disassembly.

- **Insist on a good chipset.** The two reliable ones under Linux are **Realtek RTL8153** and **ASIX AX88179A**. Both are supported in-kernel (`r8152` and `ax88179_178a` respectively) with no driver installation.
- **Avoid unbranded adapters** that don't name their chipset — they are frequently RTL8152 (100 Mbps only, which would leave you exactly where you started) or counterfeit silicon with poor Linux support.
- **Plug into a USB 3.0 port** (blue, or marked SS). A USB 2.0 port caps throughput at ~280 Mbps.
- After plugging in, add it to the bridge in `/etc/network/interfaces` in place of `nic0`, and pin the interface name with a systemd `.link` file matched on MAC address so it survives reboots.

**Option B — Lenovo optional-port NIC module.** Some ThinkCentre Tiny models take a factory second-network-port module in the rear optional-port bay. Cleaner and internal, but check compatibility against the `11DT006GAU` machine type before ordering, as the bay is also used for serial and DisplayPort options.

Once the replacement NIC is carrying traffic, leave the onboard `nic0` unconfigured — do not leave it enslaved to `vmbr0`, or its resets will continue to disturb the bridge.

---

## Software mitigations — worth doing regardless

Even with a healthy NIC, this cluster amplified a single-host network fault into a total service outage. These reduce the blast radius:

1. **Keep `master-db` off `k3s-worker-2`.** The CNPG cluster is `instances: 1` with no failover. Node affinity for `k3s-server` / `k3s-worker-1` prevents the database following the flaky host. *(Belongs in `k8s/manifest/cnpg/cluster.yaml`.)*
2. **Raise `smaller-mariadb-pv` and `smaller-wordpress-pv` to 2 replicas.** Both currently have their **only** copy on worker-2, and **no Longhorn backup target is configured** — this is the highest data-loss exposure in the cluster, well above Authentik downtime.
3. **Enable persistent journald on `david`**, so evidence survives a power cycle. It currently retains only the live boot, which is why this went unexplained for weeks:
   ```bash
   mkdir -p /var/log/journal
   systemd-tmpfiles --create --prefix /var/log/journal
   systemctl restart systemd-journald
   ```
4. **Add alerting** (still open from the previous incident doc): node `NotReady`, and an `e1000e ... Reset adapter` log alert on the host. Either would have caught this on day one.

---

## Corrections to `cnpg-wal-disk-full-incident.md`

That document's **§1b "`k3s-worker-2` is unstable — the likely common cause"** correctly identified the node as the common factor but attributed it to the k3s version skew and advised checking "disk health, Longhorn replica status, memory pressure". Those are now ruled out:

- The **version skew is incidental**, not causal.
- There is **no disk fault** — the VictoriaMetrics `parts.json` corruption in §1 is explained by the same NIC failure, which cut I/O mid-write to network-hosted Longhorn replicas.
- Memory pressure on `david` is not implicated (4.6 / 15.4 GiB in use).

The advice to treat it as "a node/storage problem, not an application bug" was directionally right — it is a **host network** problem.

---

## How to confirm the fix worked

```bash
# On david — link must be gigabit and stable
ethtool nic0 | grep -E 'Speed|Duplex'

# No new resets accumulating
journalctl -k --since "1 hour ago" | grep -c 'Reset adapter unexpectedly'   # want 0

# Node stays Ready across a full day
kubectl get nodes -w

# No unexpected host boots
# (Proxmox -> david -> Task History: startall/qmstart entries should stop appearing)
```

Success criterion: **`Speed: 1000Mb/s`, zero adapter resets over 24 hours, and `k3s-worker-2` continuously `Ready`.**

---

## 2026-09-29 update: cable replaced, fault persists

**Verified from `david`'s own journal**, read via the Proxmox API
(`/api2/json/nodes/david/journal`) using the token in `TF_VAR_proxmox_api_token_secret`.
Note SSH to the host is *not* possible with `~/.ssh/lab` — that key is the VM cloud-init key
and both hosts reject it. All times below are host-local (UTC+1).

### Step 1 worked — the physical layer is fixed

The cable swap is visible in the journal, with no driver reload preceding it:

```
07:16:16  nic0: NIC Link is Down
07:17:19  nic0: NIC Link is Up 1000 Mbps Full Duplex, Flow Control: None
```

Every link-up since has been gigabit — **4 of 4 at 1000 Mbps** (07:17, 07:18, 07:27, 10:14),
against the 10-of-10 at 100 Mbps recorded on 2026-08-28. The 100 Mbps fallback that motivated
this document is gone, and the missing-pair diagnosis was correct.

### It did not stop the outages

`david` still wedges its transmit ring. On 2026-09-29 the journal holds **14,362
`Detected Hardware Unit Hang` messages**, thousands of them *after* the cable change:

| Window (local) | State |
|---|---|
| 01:12 → 07:16 | wedged, 30 msgs/min |
| **07:16** | **cable replaced; link now 1000 Mbps** |
| 07:25 → 07:27 | wedged again after ~7 min |
| 08:19 → 10:13 | **wedged solid ~114 min** — `k3s-worker-2` offline until the host was power-cycled |
| 10:14 → 10:49 | clean (35 min at time of writing) |

### The failure mode has changed — this is now the `proxmox` fault

On 2026-09-29 `david` logged **zero `Reset adapter unexpectedly` and zero `NETDEV WATCHDOG`**
events, against 1,881 resets in a single day in August. It no longer flaps and self-recovers;
it wedges and stays wedged until power-cycled.

That is the signature documented in `pihole-dns-outage-nic-hang.md` for host `proxmox`. The
two hosts have converged on the same fault, and that document's warning now applies here too:
**do not replace the cable again — that was the fix for the old symptom.**

The hosts are near-identical underneath, which points at the chipset and driver rather than at
either machine:

| | `david` | `proxmox` |
|---|---|---|
| Kernel | 7.0.14-14-pve | 7.0.14-14-pve |
| PVE | 9.2.11 | 9.2.11 |
| CPU | i5-10500T | i5-10400T |
| NIC | e1000e I219 @ `00:1f.6` | e1000e I219 @ `00:1f.6` |

Different chassis (Lenovo ThinkCentre vs HP EliteDesk), same silicon, same kernel, same bug.

### Next action

Proceed to **Step 2 (driver mitigations)** above, and apply it to **both hosts**, not just
`david`. Step 1 is complete and should not be repeated.

A 35-minute clean window is **not** yet evidence of a fix: the preceding boot ran clean for
52 minutes before wedging at 08:19. Judge it against that baseline, not against zero.

### Corrections to the "software mitigations" list above

- Item 4 (*"Add alerting: node `NotReady`"*) is **already done** and was mis-stated. The
  Helm stack ships `KubeNodeNotReady` (`for: 15m`, severity `warning`) in
  `monitoring-victoria-metrics-k8s-stack-kubernetes-system-kubelet`, and Alertmanager routes
  all alerts to email. What is genuinely missing is the *host*-side half: the Proxmox hosts are
  not in the cluster and ship no logs to VictoriaLogs, so there is still no alert on
  `e1000e ... Detected Hardware Unit Hang`.
- Item 1 (*keep `master-db` off `k3s-worker-2`*) is now implemented in
  `k8s/manifest/cnpg/cluster.yaml` via `spec.affinity.nodeAffinity`.
