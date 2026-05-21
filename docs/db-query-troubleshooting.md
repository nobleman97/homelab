# Database Query Troubleshooting — EXPLAIN ANALYZE Runbook

Demonstrates how to identify and fix a slow query using `pg_stat_statements` and `EXPLAIN ANALYZE`.
PostgreSQL runs on `postgres-01` (192.168.100.33). Connect from your local machine:

```bash
ssh -i ~/.ssh/lab debian@192.168.100.33
sudo -u postgres psql -d demo
```

---

## Step 1 — Identify the slow query

`pg_stat_statements` tracks cumulative execution stats for every query. Sort by mean execution time to find the worst offender:

```sql
SELECT query, calls, mean_exec_time, total_exec_time
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 10;
```

This is the realistic starting point — you spotted elevated p95 latency in Grafana, now you're finding the culprit without guessing.

---

## Step 2 — Reproduce and diagnose with EXPLAIN ANALYZE

```sql
EXPLAIN ANALYZE
SELECT * FROM products
WHERE category = 'electronics'
ORDER BY created_at DESC
LIMIT 20;
```

**Before the index**, the output shows a sequential scan:

```
Seq Scan on products  (cost=... rows=... width=...)
                      (actual time=820.341..834.102 rows=20 loops=1)
  Filter: (category = 'electronics')
  Rows Removed by Filter: 979841
Planning Time: 0.3 ms
Execution Time: 834.2 ms
```

`Seq Scan` means PostgreSQL read all 1M rows and filtered down to the 20 it needed. That is the root cause.

---

## Step 3 — Fix with a zero-downtime index

`CONCURRENTLY` builds the index without locking the table — traffic keeps flowing during the build:

```sql
CREATE INDEX CONCURRENTLY idx_products_category_created
ON products (category, created_at DESC);
```

Building takes 30–60s on 1M rows. You can run a load test simultaneously to prove there is no downtime.

---

## Step 4 — Confirm the index is used

```sql
EXPLAIN ANALYZE
SELECT * FROM products
WHERE category = 'electronics'
ORDER BY created_at DESC
LIMIT 20;
```

**After the index**, the plan changes:

```
Index Scan using idx_products_category_created on products
                      (actual time=0.081..0.213 rows=20 loops=1)
  Index Cond: (category = 'electronics')
Planning Time: 0.4 ms
Execution Time: 0.3 ms
```

`Index Scan using idx_products_category_created` confirms the index is being used. Execution time drops from ~834ms to <1ms.

---

## Step 5 — Verify in Grafana

The PostgreSQL dashboard (ID 9628) shows the before/after in:
- **Query duration** — p95 latency drop is visible as a cliff in the graph
- **pg_stat_statements** panel — mean_exec_time for the query drops immediately after index creation

Screenshot both states for the portfolio case study.

---

## Rollback

If the index causes unexpected issues (e.g., write amplification on a high-insert table):

```sql
DROP INDEX CONCURRENTLY idx_products_category_created;
```

Also non-blocking. Execution plan reverts to seq scan immediately.
