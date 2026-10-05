# Incident: Authentik worker crash loop — corrupt task-table indexes

**Date resolved:** 2026-10-05
**Database:** `authentik` on `master-db` (CloudNativePG) in namespace `database`
**Impact:** `authentik-worker` crash-looped its task consumer every ~107 s and held 2.2–2.6 Gi RAM and ~0.5 CPU, about 40% of a worker node. Task cleanup had been stalled since at least 2026-06-20, so the task tables grew to 68,690 tasks and 976,391 task-log rows. Logins (`authentik-server`) were not affected.
**Data loss:** None. The only rows deleted by hand were one finished housekeeping task and its 4 log rows.

---

## Summary

Btree indexes on two Authentik task tables were **corrupt**: they were missing entries for rows that exist in the table. Authentik's task cleanup deletes old tasks through Django's cascade. Django looked up each task's log rows through the corrupt `task_id` index, found none, and deleted only the task. At `COMMIT`, Postgres's deferred foreign-key check scans for references differently, finds the log rows, and rejects the transaction. The consumer thread treated that as a connection error and restarted, on the same task, every cycle.

`REINDEX` of the two tables fixed it. Cleanup then went through on its first try, pruning ~58k old tasks and ~910k log rows.

The real cause is **storage**. This is the **second** corruption in the `authentik` database: the August incident (`docs/cnpg-wal-disk-full-incident.md` §5) was corrupt TOAST on the cache table. See [Root cause](#root-cause-storage--under-investigation).

---

## Symptoms

- `authentik-worker` was by far the largest pod in the cluster: **2630 Mi**, with no requests or limits. One of its 5 processes (pid 89) held 2.1 GB, and the other four held ~260 MB each.
- 804 consumer restarts in 24 h, every one with the same error:

```
IntegrityError: update or delete on table "authentik_tasks_task" violates foreign key constraint
"authentik_tasks_task_task_id_a82f0835_fk_authentik" on table "authentik_tasks_tasklog"
DETAIL: Key (message_id)=(a71178d5-32bd-43a1-8377-e76f64e82ba0) is still referenced from table "authentik_tasks_tasklog".
→ Consumer encountered a connection error … → Restarting consumer in 3.00 seconds.
```

- The oldest `done` task was from 2026-06-20, so pruning had not finished since then.
- The pod was first noticed on 2026-10-05 because it had moved to `k3s-worker-3` during the 2026-10-03 k3s upgrade drains, which made the node imbalance visible.

## Investigation

### 1. Deleting the stuck row only moved the problem

The failing task (`a71178d5…`, a `clean_temporary_users` run from 2026-06-20) was deleted by hand together with its log rows. A count beforehand had shown **0** log rows for it, yet `DELETE` removed **4**. That mismatch turned out to be the key clue.

After a worker restart, the same loop came back on a **different** task (`2d93341f…`, `clear_failed_blueprints`, 2026-07-14). Memory climbed back to 2.2 Gi within 6 minutes. A loop that moves from row to row points at a systematic fault rather than one bad row.

### 2. Index scan and sequential scan disagree

```sql
SELECT count(*) FROM authentik_tasks_tasklog WHERE task_id = '2d93341f-…';           -- 0
SET enable_indexscan = off; SET enable_bitmapscan = off; SET enable_indexonlyscan = off;
SELECT count(*) FROM authentik_tasks_tasklog WHERE task_id = '2d93341f-…';           -- 3
```

The same query gives different answers depending on the access path. That is index corruption. It also explains both symptoms:
- **The constant failures.** Django's cascade looked up log rows through the index and found nothing, and the foreign-key check at commit found the rows that were really there.
- **The memory growth.** Each retry loaded the bloated task tables again.

### 3. amcheck across the whole database

After `REINDEX TABLE CONCURRENTLY authentik_tasks_tasklog`, `amcheck` (`bt_index_check(oid, heapallindexed => true)`) was run against all 742 btree indexes in the `authentik` database. **9 more were corrupt, all on `authentik_tasks_task`**, in two kinds of damage:

| Error | Indexes |
|---|---|
| `heap tuple (278,62) … lacks matching index tuple` | `authentik_tasks_task_pkey`, `authentik_t_message_74b8d7_idx`, `authentik_t_message_8ee59b_idx`, `authentik_t_message_affe69_idx`, `authentik_t_queue_n_7ff882_idx` |
| `posting list contains misplaced TID` | `authentik_t_queue_n_7b09fb_idx`, `authentik_t_rel_obj_3a177a_idx`, `authentik_tasks_task_rel_obj_content_type_id_2a021136`, `authentik_tasks_task_tenant_id_a04bb198` |

The other 733 indexes passed. Before rebuilding the primary key, a sequential scan confirmed there were **no duplicate `message_id`s**, so the `REINDEX` could not fail on uniqueness.

## What was done

All times are 2026-10-05 UTC. Each database write ran only after confirming that `master-db-daily-20261005015000` had completed and continuous WAL archiving was working, so point-in-time recovery was available throughout.

| Time | Action | Result |
|---|---|---|
| ~12:00 | Deleted task `a71178d5…` and its log rows | `DELETE 4`, `DELETE 1`. The loop moved to the next task. |
| 12:02 | `rollout restart deploy/authentik-worker` | The loop resumed within minutes. |
| ~12:20 | `REINDEX TABLE CONCURRENTLY authentik_tasks_tasklog;` | Last consumer error at **12:21:44**. Cleanup pruned the backlog: tasks 65,199 → 6,592, logs 976k → 67k. |
| ~12:20 | `CREATE EXTENSION amcheck;` and a full index check | 9 corrupt indexes on `authentik_tasks_task`, listed above. |
| ~12:35 | `REINDEX TABLE CONCURRENTLY authentik_tasks_task;` | — |
| ~12:36 | Full amcheck again | **742 / 742 OK**, 0 invalid indexes |
| ~12:37 | Worker restarted again to clear memory left over from the bug | At 12:42: 455 Mi, 35m CPU, 0 consumer restarts |

### Verified state

| | Before | After |
|---|---|---|
| Consumer restarts | every ~107 s | 0 |
| Worker CPU | ~520m | ~40m |
| Worker memory | 2.2–2.6 Gi | **455 Mi** after the final restart. Before that restart it was 1175 Mi, 909 MB of which was stale in one process. All 5 processes now sit at ~260 MB RSS, mostly shared. |
| Tasks / task logs | 68,690 / 976,391 | 6,592 / 66,919 |
| Corrupt indexes | 10 | 0 |

## Root cause: lost writes from repeated hard resets (storage layer)

Investigated read-only on 2026-10-05, using kubectl, the Longhorn CRs, and the node journals read through temporary `kubectl debug node` pods. Those pods were deleted afterwards. The Proxmox hosts were **not** examined, so the open questions are listed under [Still to check on the Proxmox hosts](#still-to-check-on-the-proxmox-hosts).

### Most likely: hard VM resets plus Longhorn acknowledging writes before they are durable — confidence: high

**1. The VMs hard-reset constantly, far more often than the five power cuts in the 2026-10-03 doc.**
- `journalctl --list-boots` on `k3s-worker-1` shows **110 boots since 2026-06-30, only 1 of which ended with a shutdown sequence**.
- `k3s-worker-2` shows **69 boots, 0 clean**, with its journal only reaching back to 2026-08-29.
- Many of these resets happen **in the same minute on both VMs**, even though they run on different Proxmox hosts. Examples: 09-01 06:17, 14:01, 15:36; 09-28 03:1x; 10-02 09:34, 11:53, 17:4x.

**2. Postgres has repeatedly had its filesystem fail underneath it.** The guest kernel logs show `Detected aborted journal`, `Remounting filesystem read-only`, `lost sync page write` and `Cannot read block bitmap`, all with `comm postgres` / `pg_ctl`:
- **`k3s-worker-2`:** 07-29, 08-02, 08-13, 08-17, 08-20, 08-28, 09-15, 09-20 and 09-28. The 09-28 episode also logged iSCSI `conn error` and `rejecting I/O to offline device`.
- **`k3s-worker-1`:** 7 episodes on 09-01.
- The 07-29 and 08-02 episodes come just before the August TOAST corruption.

**3. Longhorn v1 can acknowledge a write that a reset then loses.** This is inferred from the configuration below; it has not been confirmed in the Longhorn source.
- **No flush ever reaches Longhorn.** The guest sees Longhorn devices with the write cache disabled (`write through`, `fua=0`), so the guest kernel never sends a flush to them.
- **Replica writes are not synced.** The replica process opens its `volume-head-*.img` with `O_DIRECT` but without `O_DSYNC`.
- **The head files are sparse files on the VM's own ext4.** Block-allocation metadata for a newly written block only becomes durable at ext4's journal commit.
- **The VM root disk has a volatile cache:** `sda` reports `write back`.

  Put together, a write that Postgres has `fsync`ed can disappear after a hard reset. A later read then returns the older data from the parent snapshot. This is a **lost write**: the table and its index end up from different moments in time. That is exactly what amcheck reported ("heap tuple lacks matching index tuple", "misplaced TID"), and it also fits the missing TOAST chunks from August. **Postgres data checksums cannot catch this**, because a stale page still has a valid checksum. Checksums are `on` and `checksum_failures` is 0.

**4. The two replicas are not independent copies.**
- Both replicas record failures at crash times. `r-96d0aed2` on worker-1 last failed at 2026-09-29T09:20:59Z, and `r-f9378ab8` on worker-2 at 2026-10-02T17:46:24Z.
- The current replicas were created on 09-07 and 09-26, and 3 orphan replicas of earlier copies remain on worker-2.
- Two settings make recovery after a crash riskier:
  - **`disable-revision-counter` = `{"v1":"true"}`.** After a crash, auto-salvage chooses which replica to keep by modification time and size, not by which one holds the latest writes. A rebuild can then copy missing writes onto both replicas.
  - **`auto-salvage` = `true`.**

### Possible contributor: Longhorn I/O path dropping out — confidence: medium

The iSCSI connection errors on 09-28 and the 360+ restarts of `longhorn-manager` show the engine path dropping out repeatedly. An I/O error on its own just makes Postgres crash and replay WAL safely. It only leaves damage when it coincides with the lost-write problem above.

### Ruled out

- **The known Longhorn rebuild corruption bug.** It only affects ≤ 1.3.1, and the engine here is v1.11.2.
- **The volume attached on two nodes at once.** The engine shows one attachment with 2 RW replicas.
- **Postgres misconfiguration.** PG 18.3 has `fsync=on`, `full_page_writes=on`, `data_checksums=on`, and `wal_sync_method=fdatasync`, and the last restart (2026-10-03 19:10) was clean.
- **OOM kills of Postgres or instance-manager.** None were found.
- **A full filesystem.** The volume is ext4 and 7% used.
- **NIC hangs in the guest logs.** None were found, but the NIC sits on the Proxmox host.
- **Guest SMART data.** Not meaningful here: the disks are `QEMU HARDDISK` on `local-lvm`.

### Correction to the "power cut" explanation

Two separate hosts rebooting in the same minute ~100 times does not have to mean the power supply. **Proxmox HA watchdog fencing** looks identical in the host journals: neither shows a shutdown sequence. Self-fencing happens when a two-node cluster loses quorum, for example when the I219 NIC on host `david` hangs, and then both hosts reset. Rule this out before treating a UPS as the fix.

### Still to check on the Proxmox hosts

Run these on both `proxmox` and `david`. The VMs only expose the guest's side of the problem, so they can't be checked from kubectl.

```bash
# Why the host rebooted: power or HA fencing?
journalctl -b -1 -n 50
last -x | head
journalctl -u pve-ha-lrm -u pve-ha-crm -u watchdog-mux -u corosync --since 2026-09-01 \
  | grep -iE 'watchdog|fence|quorum|lost|expired'
ha-manager status; pvecm status

# VM disk cache mode. Terraform sets none (terraform/modules/k8s-vm/main.tf),
# but the template may differ. cache=unsafe alone would explain the lost writes.
qm config <vmid> | grep -E 'scsi|virtio|cache|aio'

# Physical disk health, and whether the SSD has power-loss protection
smartctl -a /dev/<disk>          # or: nvme smart-log /dev/nvme0
lvs -a -o+data_percent,metadata_percent pve   # a full thin pool also loses writes
dmesg | grep -iE 'I/O error|nvme|ata|reset'
```

## Follow-ups

1. **Stop the hard resets first.** Run the Proxmox checks above to find out whether the cause is power or HA fencing, then fix it accordingly: a UPS for power; for fencing, disable HA or add a QDevice for quorum. Nothing else on this list is reliable while the VMs reset almost daily.
2. **Run a second CNPG instance** (`instances: 2`, on the other worker). Postgres streaming replication then provides a copy that does not depend on Longhorn's write ordering, plus failover. It also removes the PDB that blocks every drain of `k3s-worker-1`.
3. **Put Postgres on storage that honours flushes.** With CNPG replicating, a single-replica local volume or a VM disk with `cache=none` is enough, and Longhorn's acknowledge-before-durable path is taken out of the database entirely.
4. **Re-enable the Longhorn revision counter** (`disable-revision-counter` v1 → `false`), so that auto-salvage keeps the replica that actually holds the latest writes after a crash.
5. **Clean up the 3 orphan replicas on `k3s-worker-2`,** once they are no longer wanted for forensics.
6. **Optionally, date the corruption.** Restore backups to points just before and after the bad episodes on 09-01 and 09-28, and run amcheck on each.
7. **Run amcheck regularly**, weekly and after every unclean reboot. The extension is now installed, so this one read-only query fails on the first corrupt index:
   ```
   kubectl -n database exec master-db-1 -c postgres -- psql -U postgres -d authentik -c "SELECT c.relname, bt_index_check(c.oid, true) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_am a ON a.oid = c.relam WHERE a.amname = 'btree' AND c.relnamespace = 'public'::regnamespace;"
   ```
   It is worth running against the other databases on `master-db` (n8n) as well.
8. **Fix the worker's resources.** `k8s/charts/values/authentik/values.yaml` sets requests, but it was **never applied**: the Helm release is still revision 1 from 2026-05-13, and the live pods have `resources: {}`. The "bursty, peaks at 2288 Mi" reasoning in that file was most likely this bug. After a day of clean running, size the requests and limits again from real numbers and apply them with `helm upgrade`.
9. **Upgrade Authentik** from 2026.2.3, now that the indexes are clean. Upgrade migrations should never run against a database with known corruption.

## Runbook: if a Django or Postgres app loops on an impossible FK or uniqueness error

1. Compare index and sequential-scan results for the key in the error (§2). If they disagree, it is index corruption, not an app bug.
2. Confirm a recent backup exists and WAL archiving is working.
3. `REINDEX TABLE CONCURRENTLY <table>;` For a unique index, first check for duplicates with a sequential scan.
4. Run amcheck over the whole database to find any other damage.
5. Don't delete rows by hand to get around it. That only moves the failure to the next row.
