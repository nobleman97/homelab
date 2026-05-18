# Migrating a CNPG Cluster to a New Storage Class

## The Problem

When a CNPG cluster is created without specifying a `storageClassName`, it uses the cluster default. For a database, this is risky — the default storage class likely has `reclaimPolicy: Delete`, meaning if the PVC is ever deleted the volume and all data goes with it immediately.

The goal is to move the PostgreSQL data volume to a dedicated storage class (`longhorn-retain`) that uses `reclaimPolicy: Retain`, so the PV survives accidental PVC deletion.

---

## Why You Can't Migrate In-Place

Kubernetes does not allow changing the `storageClassName` of an existing PVC. The storage class is immutable after creation. The only path is:

1. Back up the data
2. Delete the cluster (which deletes the PVC)
3. Recreate the cluster with the new storage class
4. Restore the data

---

## Prerequisites

- Longhorn installed with the `longhorn-retain` storage class applied (see `k8s/manifest/storage-classes.yaml`)
- Any applications using the database scaled down before starting
- The CNPG cluster is healthy before beginning

---

## Storage Classes

Two storage classes are defined in `k8s/manifest/storage-classes.yaml`:

| Name | Reclaim Policy | Use For |
|---|---|---|
| `longhorn-delete` | Delete | Stateless workloads, scratch volumes |
| `longhorn-retain` | Retain | Databases, anything with durable state |

Always use `longhorn-retain` for CNPG.

---

## Migration Steps

### Step 1 — Scale Down Dependent Applications

Stop anything writing to the database to ensure a clean, consistent backup.

```bash
# Example: scale down n8n
kubectl scale deployment n8n --replicas=0 -n apps

# Verify no active connections
kubectl exec -n database master-db-1 -- psql -U postgres -c "SELECT count(*) FROM pg_stat_activity WHERE state = 'active';"
```

### Step 2 — Take a Logical Backup

Even if you have S3/Barman backups configured, take a fresh logical dump immediately before migrating as a safety net.

```bash
kubectl exec -n database master-db-1 -- pg_dumpall -U postgres > backup-pre-migration.sql
```

Verify the dump is non-empty:

```bash
wc -l backup-pre-migration.sql
```

### Step 3 — Trigger a Barman Base Backup (if configured)

If S3 backups are configured via the Barman Cloud Plugin, trigger a fresh base backup before proceeding:

```bash
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: master-db-pre-migration
  namespace: database
spec:
  cluster:
    name: master-db
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF

# Wait for it to complete
kubectl get backup.postgresql.cnpg.io -n database -w
```

### Step 4 — Update the Cluster Manifest

Add `storageClass: longhorn-retain` to the storage spec in `k8s/manifest/cnpg/cluster.yaml`:

```yaml
storage:
  size: 10Gi
  storageClass: longhorn-retain
```

Do not apply it yet — the cluster must be deleted first.

### Step 5 — Delete the Cluster

Deleting the `Cluster` resource also deletes the PVC. This is expected — the data is safe in your backup from Step 2 and 3.

```bash
kubectl delete cluster master-db -n database
```

Confirm the PVC is gone:

```bash
kubectl get pvc -n database
```

### Step 6 — Recreate the Cluster

Apply the updated manifest. CNPG will provision a new PVC using `longhorn-retain`:

```bash
kubectl apply -f k8s/manifest/cnpg/cluster.yaml
```

Wait for the pod to be ready:

```bash
kubectl get pods -n database -w
```

### Step 7 — Restore the Data

There are two restore paths. **Barman is strongly preferred** if S3 backups are configured and healthy.

#### Option A: Barman S3 Recovery (recommended)

Instead of bootstrapping a blank cluster in Step 6, update `cluster.yaml` to recover from S3 before applying.

**Important:** You must use **two separate ObjectStores** — one as the restore source and one as the post-recovery WAL archive destination. If you point both at the same S3 path, Barman will refuse to start because it runs a safety check (`barman-cloud-check-wal-archive`) that requires the archive destination to be empty before a recovered cluster starts writing WALs. Since your existing bucket already has WALs from the original cluster, this check fails. See the [Troubleshooting](#troubleshooting) section for the full explanation.

```yaml
bootstrap:
  recovery:
    source: master-db-backup

externalClusters:
  - name: master-db-backup
    plugin:
      name: barman-cloud.cloudnative-pg.io
      parameters:
        barmanObjectName: master-db-store       # reads from existing backup

storage:
  size: 10Gi
  storageClass: longhorn-retain

plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true
    parameters:
      barmanObjectName: master-db-store-v2      # archives to a fresh path

---
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: master-db-store                         # restore source
  namespace: database
spec:
  retentionPolicy: "14d"
  configuration:
    destinationPath: "s3://<your-bucket>"
    s3Credentials:
      accessKeyId:
        name: s3-creds
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: s3-creds
        key: SECRET_ACCESS_KEY
    wal:
      compression: gzip
    data:
      compression: gzip

---
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: master-db-store-v2                      # post-recovery archive destination
  namespace: database
spec:
  retentionPolicy: "14d"
  configuration:
    destinationPath: "s3://<your-bucket>/v2"    # different path — must be empty
    s3Credentials:
      accessKeyId:
        name: s3-creds
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: s3-creds
        key: SECRET_ACCESS_KEY
    wal:
      compression: gzip
    data:
      compression: gzip
```

Apply it:

```bash
kubectl apply -f k8s/manifest/cnpg/cluster.yaml
```

CNPG will pull the latest base backup from S3 and replay WAL automatically — no manual restore command needed. Once the pod reaches `Running`, the data is already there.

**Why this is better than pg_dumpall:**
- No manual restore command — CNPG handles it declaratively
- Supports PITR — add `recoveryTarget.targetTime` to restore to any point in the backup window
- WAL replay brings the cluster to the exact state it was in, not just the last dump
- The restore is consistent even for large databases where `pg_dumpall` would take a long time

#### Option B: Logical Restore (fallback)

Use this only if Barman backups are not configured or S3 is unavailable:

```bash
kubectl exec -i -n database master-db-1 -- psql -U postgres < backup-pre-migration.sql
```

### Step 8 — Verify

```bash
# Check databases exist
kubectl exec -n database master-db-1 -- psql -U postgres -c "\l"

# Check the PVC is now on the correct storage class
kubectl get pvc -n database -o wide
```

The `STORAGECLASS` column should show `longhorn-retain`.

### Step 9 — Scale Applications Back Up

```bash
kubectl scale deployment n8n --replicas=1 -n apps
```

---

## Initial Approach Considered

The first instinct was to use `pg_dumpall` as the sole backup and restore mechanism. It's simple — dump to a file, delete the cluster, recreate, pipe the file back in. It works, but it has limitations:

- No PITR — you can only restore to the exact moment the dump was taken
- Manual restore step — you have to remember to run the right command against the right pod
- Slow for large databases — `pg_dumpall` is a full logical export, not incremental
- Single point of failure — if the dump file is corrupt, there is no fallback

The better approach is to use Barman S3 recovery as the primary restore path. The restore is fully declarative — you change `bootstrap.initdb` to `bootstrap.recovery` in the cluster manifest, apply it, and CNPG does the rest. `pg_dumpall` is kept as a local safety net only.

---

## Troubleshooting

### Recovery pod fails with "Expected empty archive"

**Symptom:**
```
WAL archive check failed for server master-db: Expected empty archive
```

**Cause:** Before a recovered cluster starts archiving WALs, Barman runs `barman-cloud-check-wal-archive` to verify the destination S3 path is empty. This is a safety check to prevent a newly recovered cluster from mixing its WALs with those of the original cluster, which would corrupt the archive and make point-in-time recovery impossible.

If you point the recovered cluster's WAL archiver at the same `ObjectStore` used for the restore source, this check will always fail — the bucket already has WALs from the original cluster.

**Fix:** Use two separate `ObjectStore` resources with different `destinationPath` values:

| ObjectStore | Role | Path |
|---|---|---|
| `master-db-store` | Restore source | `s3://<bucket>` (existing data) |
| `master-db-store-v2` | WAL archive destination | `s3://<bucket>/v2` (empty) |

Wire them up in the cluster manifest:
```yaml
externalClusters:
  - name: master-db-backup
    plugin:
      name: barman-cloud.cloudnative-pg.io
      parameters:
        barmanObjectName: master-db-store      # restore FROM here

plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true
    parameters:
      barmanObjectName: master-db-store-v2    # archive TO here
```

After applying, delete the stuck recovery pod so CNPG creates a fresh one:
```bash
kubectl delete pod <recovery-pod-name> -n database
```

---

## References

- [CNPG S3 Backup & Restore Guide](./cnpg-s3-backup-restore.md)
- [Storage Classes manifest](../k8s/manifest/storage-classes.yaml)
- [CNPG Cluster manifest](../k8s/manifest/cnpg/cluster.yaml)
