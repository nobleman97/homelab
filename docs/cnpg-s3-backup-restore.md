# CNPG PostgreSQL Backup & Restore with S3

## The Problem

You have a PostgreSQL database running in Kubernetes via CloudNativePG (CNPG). It holds live application data. Right now, if the PVC is deleted, the node dies permanently, or you fat-finger a `kubectl delete cluster`, your data is gone.

Even with Longhorn's `Retain` reclaim policy protecting the PV, you still have no:
- Offsite copy of your data
- Point-in-time recovery (what if corruption happened 3 days ago?)
- Clean restore path to a fresh cluster

**The solution:** CNPG integrates with Barman, a PostgreSQL backup manager, via the **Barman Cloud Plugin**. Barman continuously streams WAL (write-ahead log) files to S3 and takes periodic full base backups. This gives you both continuous protection and point-in-time recovery to any moment in the backup window.

---

## How It Works

CNPG's backup model has two layers:

1. **WAL archiving** — every transaction log segment is uploaded to S3 as it's written. This is continuous and happens automatically once configured.
2. **Base backups** — periodic full snapshots of the data directory, uploaded to S3. WAL files fill in the gaps between base backups.

Together, they let you restore to any point in time within your retention window.

### Plugin Architecture (CNPG >= 1.26)

From CNPG 1.26, the native `barmanObjectStore` field is deprecated and will be removed in 1.30. Backup configuration now lives outside the `Cluster` resource in a dedicated `ObjectStore` custom resource, managed by the Barman Cloud Plugin. This keeps the cluster spec clean and makes the backup store reusable across clusters.

---

## Prerequisites

- CNPG operator >= 1.26 installed in your cluster
- cert-manager installed (required by the plugin)
- An AWS account (or S3-compatible store like MinIO)
- `kubectl` access to your cluster
- Your existing `master-db` CNPG cluster running

Verify your CNPG version:
```bash
kubectl get deployment -n cnpg-system cnpg-controller-manager \
  -o jsonpath="{.spec.template.spec.containers[*].image}"
```

Verify cert-manager:
```bash
cmctl check api
```

---

## Step 1 — Create an S3 Bucket

Create a dedicated bucket for database backups. Keep it separate from your Terraform state bucket.

```bash
aws s3api create-bucket \
  --bucket homelab-db-backups \
  --region us-east-1
```

Enable versioning for an extra layer of protection:

```bash
aws s3api put-bucket-versioning \
  --bucket homelab-db-backups \
  --versioning-configuration Status=Enabled
```

---

## Step 2 — Create an IAM User with Scoped Permissions

Create a dedicated IAM user. Never reuse your Terraform credentials here — least privilege matters.

### IAM user vs role

On EKS you would use **IRSA** (IAM Roles for Service Accounts) — the pod assumes an IAM role via its service account and no static credentials are needed. Since this cluster runs on Proxmox VMs rather than EC2, the nodes have no AWS instance identity and IRSA isn't available. Attaching a policy directly to an IAM user with static access keys stored in a Kubernetes secret is the correct approach for self-hosted clusters.

Create a policy document:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::homelab-db-backups",
        "arn:aws:s3:::homelab-db-backups/*"
      ]
    }
  ]
}
```

```bash
# Create the user
aws iam create-user --user-name cnpg-backup

# Attach the policy inline (simplest for a single-use service account)
aws iam put-user-policy \
  --user-name cnpg-backup \
  --policy-name cnpg-s3-access \
  --policy-document file://policy.json

# Generate access keys
aws iam create-access-key --user-name cnpg-backup
```

Save the `AccessKeyId` and `SecretAccessKey` from the output — you won't see the secret again.

To verify the policy is attached:

```bash
aws iam list-user-policies --user-name cnpg-backup
```

---

## Step 3 — Create the Kubernetes Secret

Store the credentials as a Kubernetes secret in the same namespace as your CNPG cluster:

```bash
kubectl create secret generic s3-creds \
  --from-literal=ACCESS_KEY_ID=AKIA... \
  --from-literal=SECRET_ACCESS_KEY=... \
  -n <cnpg-namespace>
```

---

## Step 4 — Install the Barman Cloud Plugin

The plugin must be installed in the same namespace as the CNPG operator (`cnpg-system`):

```bash
kubectl apply -f \
  https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v0.12.0/manifest.yaml

# Wait for it to be ready
kubectl rollout status deployment -n cnpg-system barman-cloud
```

---

## Step 5 — Create the ObjectStore Resource

The `ObjectStore` replaces the inline `barmanObjectStore` config that used to live inside the `Cluster` spec. Create it in the same namespace as your cluster:

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: master-db-store
  namespace: <cnpg-namespace>
spec:
  retentionPolicy: "30d"
  configuration:
    destinationPath: "s3://homelab-db-backups/master-db"
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

```bash
kubectl apply -f k8s/manifest/cnpg-object-store.yaml
```

---

## Step 6 — Update the Cluster Manifest

Update `k8s/charts/values/cnpg/cluster.yaml` to remove the old `backup` block and add the plugin reference. Do this in a single apply to avoid a gap in WAL archiving:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: master-db
spec:
  instances: 1

  storage:
    size: 10Gi
    storageClass: longhorn-retain

  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: master-db-store
```

```bash
kubectl apply -f k8s/charts/values/cnpg/cluster.yaml
```

WAL archiving starts immediately via the plugin.

---

## Step 7 — Schedule Automated Base Backups

WAL archiving alone isn't enough — you also need base backups so CNPG has a full snapshot to restore from. Create a `ScheduledBackup` resource using the plugin method:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: master-db-daily
  namespace: <cnpg-namespace>
spec:
  schedule: "0 2 * * *"   # daily at 2am
  backupOwnerReference: self
  cluster:
    name: master-db
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
```

```bash
kubectl apply -f k8s/manifest/cnpg-scheduled-backup.yaml
```

Verify the first backup ran:

```bash
# NOTE: if Longhorn is installed, 'backup' is ambiguous — use the full resource group
kubectl get backup.postgresql.cnpg.io -n <cnpg-namespace>
```

---

## Step 8 — Verify Backups Are Reaching S3

```bash
aws s3 ls s3://homelab-db-backups/master-db/ --recursive | head -20
```

You should see a `base/` directory (base backups) and a `wals/` directory (WAL segments) populating over time.

---

## Restore: Full Cluster Recovery

Use this when you need to rebuild the cluster from scratch — node failure, accidental deletion, or migrating to new infrastructure.

Create a new cluster manifest that bootstraps from the `ObjectStore` instead of `initdb`:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: master-db
  namespace: <cnpg-namespace>
spec:
  instances: 1

  storage:
    size: 10Gi
    storageClass: longhorn-retain

  bootstrap:
    recovery:
      source: master-db-backup

  externalClusters:
    - name: master-db-backup
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: master-db-store

  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: master-db-store
```

CNPG will pull the latest base backup from S3, then replay WAL to bring the cluster up to the most recent consistent state.

---

## Restore: Point-in-Time Recovery (PITR)

Use this when data was corrupted or accidentally deleted and you need to roll back to a specific moment.

Add `recoveryTarget` to the bootstrap section:

```yaml
bootstrap:
  recovery:
    source: master-db-backup
    recoveryTarget:
      targetTime: "2026-05-14 03:00:00"   # UTC timestamp
```

CNPG will restore the nearest base backup before that timestamp, then replay WAL up to exactly that moment — and stop. Everything after that point is discarded.

**Important:** PITR only works within your retention window (`30d` in the `ObjectStore` spec). WAL files older than the retention period are deleted from S3.

---

## Initial Approach Considered

Before landing on this configuration, several approaches were evaluated:

**Option A: pg_dumpall / manual logical backup**
The simplest path — `pg_dumpall` inside the pod, pipe to a file, restore with `psql`. Works for a one-off migration (like switching storage classes) but gives you no continuous protection, no automation, and no PITR. You have to remember to run it, and you can only restore to when you last ran it.

**Option B: Longhorn snapshots only**
Longhorn can snapshot volumes on a schedule. Better than nothing and requires no application-level configuration. But Longhorn snapshots are block-level and tied to the node/cluster — they don't give you an offsite copy, and restoring from them is more manual. They also don't support PITR.

**Option C: Native `barmanObjectStore` in the Cluster spec**
This was the original CNPG approach — embedding the S3 config directly inside `spec.backup.barmanObjectStore`. It works, but CNPG deprecated it in 1.26 and will remove it in 1.30. Using it today triggers a deprecation warning and leaves you on a path to breakage.

**Why the Barman Cloud Plugin wins:**
- Continuous WAL streaming means near-zero RPO (recovery point objective)
- S3 is offsite — survives total cluster loss
- PITR lets you recover from logical corruption, not just hardware failure
- The `ObjectStore` resource is reusable across multiple clusters
- The restore path is declarative: swap `bootstrap.initdb` for `bootstrap.recovery` and apply
- Future-proof — this is the supported path going forward

The tradeoff is AWS cost (minimal for a homelab — WAL files for a small DB are a few MB/day), cert-manager as a dependency, and the setup overhead covered in this guide.

---

## Troubleshooting

Issues encountered during initial setup and how they were resolved.

---

### ScheduledBackup warns about wrong number of cron arguments

**Symptom:**
```
Warning: Schedule parameter may not have the right number of arguments
```

**Cause:** CNPG uses a **6-field cron format** (seconds first), not the standard 5-field format.

| Field | 5-field (standard) | 6-field (CNPG) |
|---|---|---|
| Position 1 | minute | **second** |
| Position 2 | hour | minute |
| Position 3 | day | hour |
| Position 4 | month | day |
| Position 5 | weekday | month |
| Position 6 | — | weekday |

**Fix:** Add a seconds field and quote the value.
```yaml
# Wrong
schedule: 0 2 * * *

# Correct
schedule: "0 0 2 * * *"
#          ^ seconds
```

---

### Backups stuck in `started` phase, no Backup objects appear

**Symptom:** `ScheduledBackup` shows `Last Schedule Time` set but `kubectl get backup.postgresql.cnpg.io` returns no resources (or the backup object exists but stays in `started` with `startedAt: nil`).

**Cause:** The Barman Cloud Plugin injects a sidecar container into the PostgreSQL pod via a mutating webhook. If the `master-db-1` pod was already running when the plugin was installed, the sidecar was never injected — the pod must be recreated for the webhook to fire.

**Diagnosis:**
```bash
# Check if the sidecar is present (should show 'plugin-barman-cloud')
kubectl get pod master-db-1 -n database -o jsonpath='{.spec.initContainers[*].name}'

# Pod should show 2/2 READY when sidecar is running
kubectl get pods -n database
```

**Fix:** Delete the pod — CNPG will recreate it and the webhook will inject the sidecar:
```bash
kubectl delete pod master-db-1 -n database
kubectl get pods -n database -w   # wait for 2/2 Running
```

---

### `kubectl get backup` returns Longhorn resources instead of CNPG backups

**Cause:** Both Longhorn and CNPG define a `backup` CRD. `kubectl get backup` is ambiguous when both are installed.

**Fix:** Always use the full resource group for CNPG backups:
```bash
kubectl get backup.postgresql.cnpg.io -n database
```

---

### WAL archiving fails with `AccessDenied`

**Symptom** (from sidecar logs):
```
AccessDenied: User: arn:aws:iam::<id>:user/cnpg-backup is not authorized
to perform: s3:PutObject on resource: "arn:aws:s3:::<bucket>/..."
```

**Cause:** The IAM user exists but the policy is not attached, or the policy ARN references the wrong bucket name.

**Diagnosis:**
```bash
aws iam list-user-policies --user-name cnpg-backup
aws iam list-attached-user-policies --user-name cnpg-backup
```

**Fix:** Attach an inline policy scoped to the correct bucket:
```bash
aws iam put-user-policy \
  --user-name cnpg-backup \
  --policy-name cnpg-s3-access \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::<your-bucket>",
        "arn:aws:s3:::<your-bucket>/*"
      ]
    }]
  }'
```

WAL archiving retries automatically once the policy is in place — no pod restart needed.

---

### Trigger a manual backup (without the kubectl CNPG plugin)

The `kubectl cnpg backup` command requires the CNPG kubectl plugin, which isn't installed by default. Create a `Backup` object directly instead:

```bash
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: master-db-manual-01
  namespace: database
spec:
  cluster:
    name: master-db
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF

kubectl get backup.postgresql.cnpg.io -n database -w
```

---

## References

- [Barman Cloud Plugin — Official Docs](https://cloudnative-pg.io/plugin-barman-cloud/docs/intro/)
- [Migration from Built-in Backup](https://cloudnative-pg.io/plugin-barman-cloud/docs/migration/)
- [Plugin Installation](https://cloudnative-pg.io/plugin-barman-cloud/docs/next/installation/)
- [plugin-barman-cloud GitHub](https://github.com/cloudnative-pg/plugin-barman-cloud)
