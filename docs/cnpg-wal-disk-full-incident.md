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

**Backups of the corrupt originals** remain at `/victoria-metrics-data/parts.json.corrupt.bak` and `/victoria-metrics-data/corrupt-parts.bak/`; delete them once you're satisfied.

### 1b. `k3s-worker-2` is unstable — the likely common cause

Both VictoriaMetrics defects trace to an ungraceful shutdown of this node, and it failed again *during* this remediation:

| Event | Time |
|---|---|
| Kubelet restart (corrupted the VM partition) | 2026-08-06 06:54 UTC |
| Node went `NotReady`, kubelet stopped posting status | 2026-08-10 05:03 UTC |
| Node recovered on its own | ~2026-08-10 07:15 UTC |

The second outage took `master-db-1` down with it (8 pods stuck `Terminating`) until the node returned. VictoriaMetrics survived it by rescheduling to `k3s-worker-1`, since Longhorn keeps 2 replicas.

This node is also the newest and on a different k3s version to the others (`v1.35.4+k3s1` vs `v1.34.5+k3s1`). **Treat repeat corruption here as a node/storage problem, not an application bug** — check its disk health, Longhorn replica status, memory pressure, and whether the underlying Proxmox VM is being starved or restarted. Until it is trusted, it is a poor home for the single-instance database.

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
