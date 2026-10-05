# Incident: `master-db` PV full — WAL archiving deadlock

**Date resolved:** 2026-08-09
**Cluster:** `master-db` (CloudNativePG) in namespace `database`
**Impact:** Postgres down from ~2026-08-05 18:29 UTC to 2026-08-09 22:42 UTC (~4 days). All dependent services affected — Authentik (`auth.osose.xyz`) and n8n both use this database.
**Data loss:** None.

---

## Summary

The volume filled with **unarchivable WAL**, not with data. WAL archiving to S3 stopped, Postgres could not recycle WAL segments, `pg_wal` grew to 6.0 G, and the 10Gi volume hit 100%. CNPG then refused to start Postgres, which created a deadlock: only a running Postgres can drive the archiver, so the volume could never drain on its own.

Restoring service took two steps:

1. **Broke the deadlock** — deleted 363 WAL segments not required for crash recovery, freeing 5.7 G. Archiving recovered immediately on restart with no further intervention.
2. **Removed the underlying driver** — the real culprit was a corrupt TOAST relation behind `django_postgres_cache_cacheentry`, Authentik's Postgres-backed Django cache. Autovacuum could never complete on it, so 3.3 GB of dead TOAST accumulated behind just 488 live rows, and the retry storm was generating **3.3 GB of WAL per hour**. Truncating the cache table dropped the `authentik` database from 3791 MB to 442 MB and the volume from 46% to **12%**.

Step 1 alone would have left the cluster refilling within hours. The disk exhaustion was a symptom; the corrupt cache table was the cause.

---

## What was actually wrong

The initial report was that "data has outgrown the PV." That was not the case. Breakdown of the 9.7 G volume at the time of investigation:

| Path | Size |
|---|---|
| `pg_wal` | **6.0 G** |
| `base` (real data) | 3.7 G |
| everything else | ~2 M |

### Causal chain

1. **WAL archiving stopped** on 2026-08-05 at 11:23:00 UTC, on segment `000000020000009500000004`.
   The S3 archive ends cleanly at `...9500000003` (uploaded 11:20:48) and local `pg_wal` began at `...0004` — the exact next segment. The final `Executing barman-cloud-wal-archive` log line has no matching `Archived WAL file` completion.

2. **Postgres cannot recycle a WAL segment until it has been archived.** Segments accumulated: 383 marked `.ready`, only 4 `.done`. 383 × 16 MB = 6.0 G, an exact match for `pg_wal`.

3. **Volume hit 100%** (3.7 M free). CNPG's low-disk safety check then refused to boot Postgres:
   ```
   Not enough WAL disk space, avoid starting PostgreSQL
   error: no free disk space for WALs
   ```

4. **Deadlock.** The archiver only runs as part of a live Postgres. Postgres would not start because the disk was full; the disk could not drain because Postgres would not start. This state was self-sustaining and would never have recovered without intervention.

### Ruled out during investigation

- **S3 credentials / bucket policy.** Tested with the cluster's own `s3-creds` secret (IAM user `cnpg-backup`): list, write, and delete against `s3://objectstore-199174511003-us-east-1-an/v2/master-db/wals/` all succeeded. Not an auth problem.
- **Replication slots** pinning WAL — `pg_replslot/` was empty.
- **Node disk pressure** — all three nodes reported `DiskPressure: False`. The exhaustion was confined to the Longhorn volume.
- **Overwrite conflict** — the failing segment `...9500000004` was not present in S3, so it was not barman refusing to overwrite.

### Not determined

The original trigger for the *first* archive failure. The pod died mid-archive and the barman stderr for that call was never logged. Aug 3–4 have zero `database`-namespace logs, so the incident likely began before the VictoriaLogs retention window.

Notably, **archiving resumed successfully the moment free space existed** (0 failures since restart). This is consistent with the archive failure being caused by, or entangled with, the disk-full condition itself rather than an independent fault.

---

## What was done

Chosen approach: reclaim space by deleting non-critical WAL, rather than expanding the PVC. Expansion was the alternative but is irreversible in Longhorn.

### 1. Established the crash-recovery boundary

```
pg_controldata -D /pgdata/pgdata
```

| Field | Value |
|---|---|
| Database cluster state | `in production` (i.e. unclean shutdown) |
| Latest checkpoint's REDO WAL file | `00000002000000960000006F` |
| Time of latest checkpoint | Wed Aug 5 18:20:23 2026 |

Everything **at or after** `...960000006F` is required to replay crash recovery. Everything **before** it is retained only because it was unarchived, and is safe to remove — this is exactly what `pg_archivecleanup` does.

Safety preconditions verified before deleting:
- No `backup_label` (no base backup in progress) — only a stale `backup_label.old`
- No `recovery.signal`, no `standby.signal`

### 2. Deleted the reclaimable segments

| Set | Count | Size | Action |
|---|---|---|---|
| `...9500000004` → `...960000006E` | 363 | ~5.7 G | **deleted** (+ matching `.ready` markers) |
| `...960000006F` → `...9600000082` | 20 | 320 M | kept — required for crash recovery |

Non-segment files left untouched: `00000002.history`, `000000020000009100000076.00000028.backup`, `summaries/`, `archive_status/`.

Result: `9.8G used / 3.7M avail (100%)` → `4.1G used / 5.7G avail (42%)`.

### 3. Restarted and verified

Deleting the pod stalled in `Terminating` because CNPG sets a 1800s termination grace period. Re-issuing the delete with `--grace-period=30` cleared it without resorting to `--force` (which risks a Longhorn multi-attach conflict on reattach). Postgres was already terminated at that point, so this was safe.

Post-restart verification:

```
ConsistentSystemID     True   A single, unique system ID was found
Ready                  True   Cluster is Ready
ContinuousArchiving    True   Continuous archiving is working
LastBackupSucceeded    True   Backup was successful
```

| Check | Result |
|---|---|
| Pod | `master-db-1  2/2  Running` |
| Disk | 4.2 G used / 5.7 G avail (43%) |
| `pg_wal` | 385 M, 24 segments |
| Pending `.ready` | **0** |
| `pg_stat_archiver` | 25 archived, **0 failed**, last `000000020000009600000086` |
| Postgres | 18.3, `pg_is_in_recovery() = f`, serving queries |

Crash recovery completed cleanly and the archiver drained the remaining backlog with no errors.

### 4. Re-established the backup chain

Deleting unarchived WAL leaves a deliberate gap in the S3 archive between `...9500000003` and `...960000006F`, which invalidates PITR across that window. A fresh base backup was therefore triggered to establish a new valid restore point:

```bash
kubectl apply -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: master-db-post-incident-20260809
  namespace: database
spec:
  cluster:
    name: master-db
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
```

**No manifest changes were made.** `k8s/manifest/cnpg/cluster.yaml` still specifies `storage.size: 10Gi`, which matches the actual volume — no GitOps drift was introduced.

---

### 5. Root cause: corrupt TOAST behind the Authentik cache table — FIXED

After the database was back up, the `XX001` error storm resumed immediately (25 occurrences in 15 minutes):

```
found xmin 2369926 from before relfrozenxid 2370187
missing chunk number 0 for toast value 2767699 in pg_toast_34268
```

Tracing `pg_toast_34268` to its owning relation identified the culprit:

| | Before | After |
|---|---|---|
| Table | `django_postgres_cache_cacheentry` (Authentik's Django cache) | |
| Live rows | 488 | 0 |
| Heap | 112 kB | — |
| **TOAST** | **3349 MB** | 32 kB |
| `authentik` database | 3791 MB | **442 MB** |
| Volume usage | 46% | **12%** |
| Measured WAL rate | **3336 MB/hour** | **1682 MB/hour** |
| `XX001` errors | 25 per 15 min | **0** |

`autovacuum_count` on that relation was **0** — it had never once vacuumed successfully. The corruption meant dead TOAST chunks could never be reclaimed, so 3.3 GB accumulated behind 488 cache entries, and the endless autovacuum retry loop generated WAL at 3.3 GB/hour. At that rate, the 5.3 GB free after step 1 was only ~1.6 hours of runway had archiving stalled again.

**Fix applied:**

```sql
-- in the authentik database
TRUNCATE TABLE django_postgres_cache_cacheentry;
```

`TRUNCATE` is the correct tool here: it allocates a new relfilenode instead of reading existing rows, so it discards the corrupt TOAST outright. `VACUUM FULL` would have failed trying to read it. The table is a cache, so Authentik simply repopulates it — the only user-visible effect is cleared cached sessions/lookups and slightly slower first requests.

Measurement method (WAL rate sampled over a fixed interval):

```bash
a=$(psql -U postgres -tAc "select pg_current_wal_lsn();"); sleep 180
b=$(psql -U postgres -tAc "select pg_current_wal_lsn();")
psql -U postgres -tAc "select pg_size_pretty(pg_wal_lsn_diff('$b','$a')*20) as wal_per_hour;"
```

### Follow-up worth considering

**WAL churn halved but is still high — 1682 MB/hour.** The corruption errors are gone (0 in a clean 3-minute window), so this residual rate is not corruption; it is Authentik's Postgres-backed cache doing ordinary writes, each of which generates WAL. Worth being aware of rather than alarmed by, but it does set the runway: at 1.68 GB/hour, the 8.6 G now free is roughly **5 hours** before a fresh archiving stall would refill the volume — up from ~1.6 hours before the truncate, but still a reason to get alerting in place (see open issue #2).

If it becomes a problem, options are a shorter TTL on Authentik's cache entries, or moving that cache off Postgres.

**The corruption's original cause was not determined** — it predates log retention. If it recurs on the same table, investigate the underlying storage rather than truncating again; repeat TOAST corruption confined to one relation can indicate a Longhorn replica or disk-level fault.

---

## Final verified state (2026-08-09 ~23:10 UTC)

| Check | Value |
|---|---|
| Pod | `master-db-1  2/2  Running` |
| Cluster conditions | `ConsistentSystemID`, `Ready`, `ContinuousArchiving`, `LastBackupSucceeded` — all `True` |
| Volume | **1.3 G used / 8.6 G available (13%)** — was 100% |
| `authentik` database | 442 MB — was 3791 MB |
| `pg_stat_archiver` | **82 archived, 0 failed** |
| Pending `.ready` segments | 0 |
| `XX001` errors | 0 |
| WAL rate | 1682 MB/hour |
| Latest restore point | `2026-08-09T22:55:02Z` (`master-db-post-incident-20260809`, LSN `96/92000028` → `96/A1B7AB08`) |

CNPG also caught up the scheduled backups it had missed while down (Aug 6 and Aug 7 both completed).

---

## Open issues found along the way

These were discovered during investigation and are **not fixed**.

### 1. VictoriaMetrics (`vmsingle`) was crashlooping — FIXED 2026-08-10

Two files were corrupted by an unclean shutdown on `k3s-worker-2` (kubelet restarted Aug 6 06:54). Both were in the `2026_08` small partition; the volume was only 5% full, so this was never a capacity issue.

**Defect 1 — partition index overwritten.**
```
FATAL: cannot parse "/victoria-metrics-data/data/small/2026_08/parts.json":
invalid character '\x00' after top-level value
```
The file contained a *part's* `metadata.json` payload (`{"RowsCount":10495,...}`) followed by 661 null bytes — a misdirected write, not merely truncation. Truncating the nulls would not have helped because the underlying content was the wrong structure entirely.

Repaired by reconstructing the index from the part directory names. The schema was confirmed against the healthy `small/2026_07/parts.json`:

```json
{"Small":["<part dir names>"],"Big":["<part dir names>"]}
```

Note that `data/small/<month>/parts.json` indexes **both** small and big parts — which is why `data/big/<month>/` legitimately has no `parts.json` of its own.

**Defect 2 — one corrupt part.** After the index was fixed, VM advanced and failed on:
```
FATAL: cannot parse ".../2026_08/18C7B5466049917C/metadata.json":
invalid character 'õ' looking for beginning of value
```
That part's `metadata.json` was 116 bytes of binary garbage. Its `timestamps.bin` and `values.bin` were both **0 bytes** — it was a part mid-creation when the node crashed and held no data. Moved to `/victoria-metrics-data/corrupt-parts.bak/` and dropped from the index.

A scan of all 164 `metadata.json` files found exactly one corrupt; all other `parts.json` files were clean.

**Result:** `VMSingle` CR went `failed` → `operational`, pod `1/1 Running`, health `OK`, zero panics, 23 targets up, 120 series with 30-day history — no metric data lost. `kubelet_volume_stats_*` metrics are flowing again, which unblocks the alerting below.

**Backups of the corrupt originals** were kept at `/victoria-metrics-data/parts.json.corrupt.bak` and `/victoria-metrics-data/corrupt-parts.bak/`; deleted after verification on 2026-10-03 (see the update at the end of this doc).

### 1b. `k3s-worker-2` is unstable — the likely common cause

> **[SUPERSEDED 2026-08-28]** The root cause is now known: a physically failing NIC on the
> Proxmox host `david`, which hosts this VM. The version-skew hypothesis below is **incidental,
> not causal**, and there is **no disk fault**. See [`worker-2-nic-failure.md`](worker-2-nic-failure.md).

Both VictoriaMetrics defects trace to an ungraceful shutdown of this node, and it failed again *during* this remediation:

| Event | Time |
|---|---|
| Kubelet restart (corrupted the VM partition) | 2026-08-06 06:54 UTC |
| Node went `NotReady`, kubelet stopped posting status | 2026-08-10 05:03 UTC |
| Node recovered on its own | ~2026-08-10 07:15 UTC |

The second outage took `master-db-1` down with it (8 pods stuck `Terminating`) until the node returned. VictoriaMetrics survived it by rescheduling to `k3s-worker-1`, since Longhorn keeps 2 replicas.

This node is also the newest and on a different k3s version to the others (`v1.35.4+k3s1` vs `v1.34.5+k3s1`). **Treat repeat corruption here as a node/storage problem, not an application bug** — check its disk health, Longhorn replica status, memory pressure, and whether the underlying Proxmox VM is being starved or restarted. Until it is trusted, it is a poor home for the single-instance database.

> **Later finding:** the node itself was not at fault. Its host `david` had an Intel I219 / `e1000e` NIC hanging its transmit ring (`docs/worker-2-nic-failure.md`), mitigated 2026-09-29. The October recurrence was power loss to both hosts — see the 2026-10-03 update at the end of this doc.

### 2. No alerting on either failure mode

Both the archiving failure and the disk fill ran unnoticed for four days. Worth adding alerts on:
- CNPG `ContinuousArchiving` condition going `False`
- `kubelet_volume_stats_available_bytes` below a threshold on `master-db-1`

VictoriaMetrics is serving again, so this is no longer blocked. Volume metrics are confirmed flowing for all six PVCs.

### 3. Consider a dedicated WAL volume

CNPG supports `walStorage`, placing `pg_wal` on its own PVC. That would mean a future archiving stall fills a separate volume instead of taking the data volume — and the database — down with it. This is the structural fix for the failure mode in this incident.

---

## Runbook: if this recurs

1. Confirm the shape of the problem — do not assume data growth:
   ```bash
   kubectl exec -n database master-db-1 -c postgres -- \
     du -sh /var/lib/postgresql/data/pgdata/pg_wal /var/lib/postgresql/data/pgdata/base
   ```
2. Check whether archiving is the cause:
   ```bash
   kubectl get cluster master-db -n database -o jsonpath='{.status.conditions}' | python3 -m json.tool
   # and, if Postgres is up:
   kubectl exec -n database master-db-1 -c postgres -- \
     psql -U postgres -tAc "select archived_count, failed_count, last_failed_wal from pg_stat_archiver;"
   ```
3. If Postgres is up, fix the archiver and let it drain on its own. **Only if Postgres cannot start** proceed to manual WAL removal.
4. Find the crash-recovery boundary — never delete at or after this segment:
   ```bash
   pg_controldata -D /pgdata/pgdata | grep "REDO WAL file"
   ```
5. Verify `backup_label`, `recovery.signal`, `standby.signal` are all absent.
6. Delete segments strictly below the REDO segment, plus their `.ready` markers.
7. Restart, verify `ContinuousArchiving: True` and `.ready` count 0.
8. **Take a fresh base backup** — the archive chain now has a gap.

### Preferred alternative

If time and upload bandwidth allow, archive the backlog to S3 first (gzip each segment to `<destination>/<server>/wals/<16-char prefix>/<segment>.gz`) and *then* delete. That preserves PITR continuity and avoids the gap entirely. The delete-outright path above is faster but trades away point-in-time recovery for the affected window.

---

## 2026-10-03 update: power loss corrupts VictoriaMetrics and VictoriaLogs

**Impact:** No metrics or logs stored for ~22–25 hours (table below). Dashboards and any alerting built on them were blind for the same window.
**Data loss:** The crashloop windows, plus two partially written parts holding seconds of data. No Postgres or WordPress data lost.

This is the **third** `parts.json` corruption on these volumes caused by an ungraceful shutdown (see §1 above for August). The repair procedure from §1 applied unchanged to VictoriaMetrics and, with the schema adjusted, to VictoriaLogs.

### Trigger: power loss, not the NIC

Both Proxmox hosts rebooted abruptly **five times, each time in the same minute as each other**:

| Host time (UTC+1) | UTC | Notes |
|---|---|---|
| Oct 01 10:17 | 09:17 | |
| Oct 02 12:18 | 11:18 | down ~31 min |
| Oct 02 12:52 | 11:52 | |
| Oct 02 17:32 | 16:32 | |
| Oct 02 18:38 | 17:38 | |

Verified from both hosts' own journals, read through the Proxmox API (`/api2/json/nodes/<node>/journal`): every boot is preceded by ordinary cron/pmxcfs lines and **no shutdown sequence**, on both hosts at once. Two independent machines losing power together is a supply event, not a host fault.

It is **not** the e1000e I219 fault (`docs/worker-2-nic-failure.md`, `docs/pihole-dns-outage-nic-hang.md`): both host journals show **zero** `Detected Hardware Unit Hang`, `Reset adapter`, or `NETDEV WATCHDOG` lines since 2026-09-29 14:00, when the ethtool mitigations went in.

### VictoriaMetrics — FIXED 2026-10-03

```
FATAL: cannot parse "/victoria-metrics-data/data/small/2026_10/parts.json":
invalid character '\x00' looking for beginning of value
```

Same two defects as August:

- **Index overwritten** — `data/small/2026_10/parts.json` (685 bytes) was garbage. Rebuilt from the part directory names as `{"Small":[34 parts],"Big":[]}`, schema confirmed against the healthy `2026_09/parts.json`; `data/big/2026_10` is empty. Written to a temp file, `fsync`ed, renamed into place.
- **One part mid-creation** — `18DAB482D733A947` had a garbage `metadata.json` and 0-byte `timestamps.bin` / `values.bin`. Moved aside and dropped from the index.

A scan of all 156 JSON files on the volume, including indexdb, found no further corruption.

**Result:** `VMSingle` CR `operational`, pod `1/1 Running` with 0 restarts, no panics, all 24 scrape targets up. Storage opened 93 parts / ~2.64 B rows; vmagent's ~30 MB on-disk buffer replayed fully; a 30-day range query returns data back to Sep 20.

### VictoriaLogs — FIXED 2026-10-03

```
FATAL: cannot parse /storage/partitions/20261002/datadb/parts.json:
invalid character '\x00' looking for beginning of value
```

- **Index overwritten** — `partitions/20261002/datadb/parts.json` was null bytes and garbage. Note VictoriaLogs' schema differs from VictoriaMetrics': it is a **compact JSON array of part names**, not a `Small`/`Big` object. Rebuilt from the 19 intact part directories, matching the healthy partitions.
- **One part mid-flush** — `18DAC3E62C02AA4B` had a garbage `metadata.json` (18-byte `timestamps.bin`, 910-byte `message_values.bin` — a final flush written 7 s after the previous part). Moved aside and dropped from the index.

All six partitions' `parts.json` and `metadata.json` files, including indexdb, were otherwise valid. Repair was done from a temporary busybox pod pinned to `k3s-worker-2` mounting the same PVC, so neither the StatefulSet nor the ArgoCD `victoria-logs` app was touched.

**Result:** storage opened 115 small parts / 2,223,923 rows in 0.23 s; pod `1/1 Running` with 0 restarts and 0 error lines; ArgoCD `victoria-logs` back to `Synced` / `Healthy`. A query over Oct 2 returns **411,647 rows — exactly the sum of the 19 parts' metadata row counts**, so everything that survived is readable. Ingest from fluent-bit resumed immediately.

**Assumption:** the index was rebuilt from *all* 19 on-disk parts, on the basis that the power cut interrupted a flush, not a merge. If a merge was in flight, some of those parts would be merge inputs that had already been superseded — the failure mode would be **a few duplicated log lines, not missing ones**.

### Data gaps

| Store | Gap (UTC) | Recoverable? |
|---|---|---|
| VictoriaMetrics | Oct 2 16:36 → Oct 3 14:55 (~22 h) | No — never scraped into storage; vmagent's buffer only covered the final hours |
| VictoriaLogs | Oct 2 ~17:44 → Oct 3 18:40 (~25 h) | No — fluent-bit did not replay it |

The gap start times are derived from the stores' last surviving data and line up with the final two power cuts above to within minutes; host clocks and file mtimes were not reconciled further.

The corrupt originals and moved-aside parts — from this repair **and** the August one in §1 — were **deleted after verification on 2026-10-03**.

### Side effects of the same power cuts

- **WordPress MariaDB** marked four tables crashed after each restart — Oct 1: `wpz7_options`, `wpz7_postmeta`, `wpz7_actionscheduler_logs`, `wpz7_actionscheduler_claims`; Oct 2: `wpz7_options`, `wpz7_actionscheduler_logs`, `wpz7_actionscheduler_claims`, `wpz7_loginizer_logs`. MariaDB's auto-recovery repaired them; `CHECK TABLE` over all 62 tables in `cognitaid_db` returns OK. The exposure is structural: **61 of 62 tables are MyISAM**, which has no crash recovery of its own.
- **`mariadb-0` stuck `ContainerCreating` ~100 min on Oct 1** — `smaller-mariadb-pv` held a stale `longhorn-ui` attachment ticket to `k3s-worker-2`, blocking the CSI attach to `k3s-worker-1` (`the volume is currently attached to different node`). Cleared by detaching in the Longhorn UI; the pod started immediately.

### Follow-ups

1. **Put both Proxmox hosts on a UPS.** Power is now the dominant outage cause, and every ungraceful shutdown risks exactly this corruption again. Software fixes downstream only shorten recovery.
2. **The VictoriaMetrics volume (`pvc-51b184ff`) is still `degraded`, single replica.** Longhorn cannot place a second copy: `k3s-worker-2` already holds one, `k3s-worker-1` has ~9 G schedulable against a 20 G volume (its 32 G is all live replicas — `master-db-1`, VictoriaLogs, Grafana — nothing reclaimable), and `k3s-server` is deliberately cordoned. Fix by growing `k3s-worker-1`'s VM disk in Terraform (a Proxmox disk resize, not a Longhorn volume expansion). Raising over-provisioning is not recommended — Longhorn shares worker-1's root filesystem and would approach kubelet eviction thresholds as the volume fills.
3. **The `master-db` node-affinity pin is committed but not applied.** `k8s/manifest/cnpg/cluster.yaml` excludes `k3s-worker-2` (commit `364cad1`), but the live Cluster has only `podAntiAffinityType: preferred`, and `master-db-1` is running on `k3s-worker-2`. Needs `kubectl apply` plus a pod delete to move it.
4. **Host NIC watchdog:** `nic0-unwedge.timer` is enabled on both hosts and survives reboot; the repo's `nic-watchdog` units are not deployed (`hosts/proxmox/README.md` is out of date on this).
5. **Convert the WordPress tables to InnoDB** (`ALTER TABLE … ENGINE=InnoDB`, after a backup) so the next power cut does not mark tables crashed.
