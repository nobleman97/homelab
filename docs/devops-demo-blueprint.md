# DevOps Demo Platform — Execution Blueprint

A production-grade traffic and reliability platform built on bare VMs (no Kubernetes) to demonstrate
NGINX mastery, zero-downtime deployments, database performance engineering, full observability, and
chaos/incident response. Designed as a portfolio project targeting the Betternship DevOps role.

---

## Architecture Overview

```
Internet
   │
   └── Cloudflare Tunnel (better.osose.xyz)
              │
              ▼
   ┌─────────────────────────┐
   │   traffic-proxy-01      │  192.168.100.31
   │                         │
   │  NGINX (reverse proxy)  │  :80 / :443
   │  nginx-prometheus-exp.  │  :9113  ← scraped by K8s VictoriaMetrics
   │  node_exporter          │  :9100  ← scraped by K8s VictoriaMetrics
   └────────────┬────────────┘
                │  upstream: blue (:8001) / green (:8002)
                ▼
   ┌─────────────────────────┐
   │   app-server-01         │  192.168.100.32
   │                         │
   │  FastAPI (blue)         │  :8001
   │  FastAPI (green)        │  :8002
   │  node_exporter          │  :9100  ← scraped by K8s VictoriaMetrics
   └────────────┬────────────┘
                │  SQL (port 5432)
                ▼
   ┌─────────────────────────┐
   │   postgres-01           │  192.168.100.33
   │                         │
   │  PostgreSQL             │  :5432  (accessible from .32 only)
   │  postgres_exporter      │  :9187  ← scraped by K8s VictoriaMetrics
   │  node_exporter          │  :9100  ← scraped by K8s VictoriaMetrics
   └─────────────────────────┘
              ↑
   ┌──────────────────────────────┐
   │  Kubernetes cluster          │
   │  (existing, k8s-worker .26)  │
   │                              │
   │  VictoriaMetrics (scrapes)   │
   │  Grafana     (dashboards)    │
   │  Loki        (logs)          │
   │  Alertmanager                │
   └──────────────────────────────┘
```

**Public entry point:** `better.osose.xyz` → Cloudflare tunnel → `traffic-proxy-01:443`

> **Monitoring note:** The observability stack (VictoriaMetrics, Grafana, Loki, Alertmanager) will be
> deployed to the existing Kubernetes cluster in a later phase. The VM exporters expose metrics
> endpoints that K8s VictoriaMetrics scrapes remotely.

---

## VM Specs

| VM | Hostname | IP | Cores | RAM | Disk | Role |
|---|---|---|---|---|---|---|
| `traffic_proxy` | traffic-proxy-01 | 192.168.100.31 | 2 | 4 GB | 60 GB | NGINX reverse proxy |
| `app_server` | app-server-01 | 192.168.100.32 | 2 | 4 GB | 60 GB | FastAPI blue/green instances |
| `postgres_01` | postgres-01 | 192.168.100.33 | 2 | 4 GB | 60 GB | PostgreSQL + postgres_exporter |

All cloned from `debian-12-template-worker`, provisioned via Terraform, target node `david`.

---

## Phase 1 — Infrastructure Provisioning (Terraform)

**Files:** `terraform/proxmox/terraform.tfvars`

Three new entries added to the `vms` map: `traffic_proxy`, `app_server`, `postgres_01`.

**Apply command (targeted — does not touch k8s VMs):**
```bash
cd terraform/proxmox
terraform plan  -target=module.vms[\"traffic_proxy\"] -target=module.vms[\"app_server\"] -target=module.vms[\"postgres_01\"]
terraform apply -target=module.vms[\"traffic_proxy\"] -target=module.vms[\"app_server\"] -target=module.vms[\"postgres_01\"]
```

---

## Phase 2 — VM Bootstrap (Ansible)

Playbook: `ansible/playbooks/bootstrap-demo.yml`

Thin orchestrator that assigns roles to host groups. Roles live in `ansible/roles/`.

| Host group | Roles applied | What gets configured |
|---|---|---|
| `demo_proxy` | `common`, `nginx` | Base packages, node_exporter, ufw; NGINX + stub_status, nginx-prometheus-exporter |
| `demo_app` | `common`, `app` | Base packages, node_exporter, ufw; Python 3 + venv, app ports 8001/8002 opened |
| `demo_db` | `common`, `postgres` | Base packages, node_exporter, ufw; PostgreSQL 15, `pg_stat_statements`, slow query log (500ms threshold), port 5432 restricted to `.32` only, SSH allowed, postgres_exporter |

Ansible inventory (`ansible/inventory/static.ini`):
```ini
[devops_demo]
traffic-proxy-01  ansible_host=192.168.100.31
app-server-01     ansible_host=192.168.100.32
postgres-01       ansible_host=192.168.100.33

[demo_proxy]
traffic-proxy-01  ansible_host=192.168.100.31

[demo_app]
app-server-01     ansible_host=192.168.100.32

[demo_db]
postgres-01       ansible_host=192.168.100.33
```

---

## Phase 3 — Application Layer

### FastAPI App (`app/`)

A realistic e-commerce-style API with three endpoints:

| Endpoint | Description |
|---|---|
| `GET /health` | Health check (used by NGINX upstream probe + deployment script) |
| `GET /products` | List products — queries PostgreSQL, intentionally slow without index |
| `POST /orders` | Create order — INSERT with realistic latency |

Environment variable `APP_VERSION` (`blue` / `green`) — returned in every response header
(`X-App-Version`) so traffic shifting is visually verifiable.

### PostgreSQL Schema

```sql
-- products: 1M rows seeded via pgbench-style script
CREATE TABLE products (
  id          SERIAL PRIMARY KEY,
  name        TEXT NOT NULL,
  category    TEXT NOT NULL,
  price       NUMERIC(10,2),
  stock       INT,
  created_at  TIMESTAMPTZ DEFAULT now()
);

-- orders: written by POST /orders
CREATE TABLE orders (
  id          SERIAL PRIMARY KEY,
  product_id  INT REFERENCES products(id),
  quantity    INT,
  total       NUMERIC(10,2),
  created_at  TIMESTAMPTZ DEFAULT now()
);
```

`pg_stat_statements` enabled in `postgresql.conf`.
Slow query log threshold: `log_min_duration_statement = 500` (ms).

---

## Phase 4 — NGINX Configuration

**On `traffic-proxy-01`:** `/etc/nginx/sites-available/demo`

Key features demonstrated:

```nginx
upstream app_backend {
    server 192.168.100.36:8001 weight=10;  # blue (active)
    server 192.168.100.36:8002 weight=0;   # green (standby)
    keepalive 32;
}

server {
    listen 443 ssl;
    server_name better.osose.xyz;

    # SSL termination
    ssl_certificate     /etc/ssl/demo/fullchain.pem;
    ssl_certificate_key /etc/ssl/demo/privkey.pem;

    # Rate limiting
    limit_req zone=api_limit burst=20 nodelay;

    # JSON access log (piped to Loki via Promtail)
    access_log /var/log/nginx/access.log json_combined;

    location /api/ {
        proxy_pass         http://app_backend;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_next_upstream error timeout http_502 http_503;
        proxy_connect_timeout 2s;
        proxy_read_timeout    30s;
    }

    location / {
        return 200 '{"status":"ok","service":"demo-platform"}';
        add_header Content-Type application/json;
    }
}
```

Custom 502/503 error pages served as JSON (demonstrates API-first error handling).

---

## Phase 5 — Blue-Green Deployment Script

**File:** `scripts/deploy.sh`

Full flow (no Kubernetes, pure NGINX upstream manipulation):

```
1. Pull new image / code to staging port (green = :8002)
2. Start green instance
3. Poll GET /health on green until 200 OK (max 30s, bail on failure)
4. Gradually shift NGINX weights: 80/20 → 50/50 → 20/80 → 0/100
   (each step: nginx -s reload + 5s wait + verify error rate via VictoriaMetrics API)
5. If error rate > 1% at any step → auto-rollback (revert weights, stop green)
6. Drain old blue connections (wait for active connections to drop to 0)
7. Stop blue instance
8. Rename: green becomes blue (port swap for next deploy)
```

Key implementation details:
- Weight patching done via `sed` on the upstream block + `nginx -t && nginx -s reload`
- Health check uses `curl -sf --max-time 2`
- Rollback is automatic and logged with timestamp + reason
- Script is idempotent — safe to re-run after partial failure

---

## Phase 6 — Observability Stack (Kubernetes — deferred)

The full observability stack will be deployed to the existing K8s cluster as a separate phase.

### What gets installed on the VMs (now)

Exporters only — lightweight, no UI:

| VM | Exporter | Port |
|---|---|---|
| traffic-proxy-01 | nginx-prometheus-exporter | :9113 |
| traffic-proxy-01 | node_exporter | :9100 |
| app-server-01 | postgres_exporter | :9187 |
| app-server-01 | node_exporter | :9100 |

### What gets deployed to K8s (later)

- **VictoriaMetrics** (single-node) — drop-in Prometheus replacement; same scrape config format,
  full PromQL compatibility, lower memory footprint than Prometheus
- **VMAgent** — lightweight scraper that forwards metrics to VictoriaMetrics remote write endpoint
- **VMAlert** — evaluates alerting rules against VictoriaMetrics, fires to Alertmanager
- **Grafana** — four dashboards (Traffic/RED, Database, Deployment, System); datasource type
  `Prometheus` pointing at the VictoriaMetrics query endpoint (fully compatible)
- **Loki + Promtail** — Promtail daemonset ships VM logs
- **Alertmanager** — receives alerts from VMAlert; routes for error rate, slow queries, backend down

### VMAgent scrape config (to be added to K8s)

```yaml
scrape_configs:
  - job_name: nginx
    static_configs:
      - targets: ['192.168.100.31:9113']

  - job_name: node_proxy
    static_configs:
      - targets: ['192.168.100.31:9100']

  - job_name: postgres
    static_configs:
      - targets: ['192.168.100.33:9187']

  - job_name: node_app
    static_configs:
      - targets: ['192.168.100.32:9100']

  - job_name: node_db
    static_configs:
      - targets: ['192.168.100.33:9100']
```

---

## Phase 7 — Database Performance Case Study

This is the "before and after indexing" demo — one of the rarest things a DevOps engineer can show.

### Setup

Seed `products` with 1 million rows, then run this query (slow):
```sql
SELECT * FROM products WHERE category = 'electronics' ORDER BY created_at DESC LIMIT 20;
```

Show in Grafana: query takes ~800ms, shows up in `pg_stat_statements`.

### Add the index
```sql
CREATE INDEX CONCURRENTLY idx_products_category_created
  ON products (category, created_at DESC);
```

`CONCURRENTLY` — zero downtime, no table lock. Demonstrate this runs while traffic flows.

After index: same query drops to < 5ms. Before/after screenshot in Grafana captures the improvement.

Document in a runbook with:
- How to identify the slow query via `pg_stat_statements`
- How to confirm the index is being used (`EXPLAIN ANALYZE`)
- How to monitor index bloat over time

---

## Phase 8 — Chaos Engineering & Incident Simulation

**File:** `scripts/chaos.sh`

Three scenarios, each with a runbook:

### Scenario 1 — Backend Instance Failure
```bash
# Kill the blue backend
ssh app-server-01 "pkill -f 'uvicorn.*8001'"
```
**Observable:** Grafana error rate spikes → NGINX `proxy_next_upstream` kicks in → traffic moves to green → alert fires → runbook says restart blue.

### Scenario 2 — Slow Query Injection
```bash
# Run a query that holds a lock for 10 seconds
ssh app-server-01 "psql -c \"SELECT pg_sleep(10), count(*) FROM products;\""
```
**Observable:** `SlowQuery` alert fires in Alertmanager → Grafana DB dashboard shows spike → runbook says use `pg_cancel_backend()` or `pg_terminate_backend()`.

### Scenario 3 — Traffic Spike / Rate Limiting
```bash
# 500 concurrent requests
ab -n 5000 -c 500 http://better.osose.xyz/api/products
```
**Observable:** NGINX rate limiting kicks in (429s appear in access log) → Grafana request rate panel spikes → error rate stays below threshold because rate limiting protected the backend.

---

## Phase 9 — Public Exposure (Cloudflare Tunnel)

Add `better.osose.xyz` to the existing Cloudflare tunnel config in `env/cfd_config.yaml`:

```yaml
ingress:
  - hostname: better.osose.xyz
    service: http://192.168.100.35:80
  # ... existing rules
```

Grafana accessible at `grafana.osose.xyz` (or behind Authentik ForwardAuth using existing setup).

---

## Deliverables Checklist

- [ ] Phase 1: Terraform — VMs provisioned
- [ ] Phase 2: Ansible — VMs bootstrapped
- [ ] Phase 3: FastAPI app + PostgreSQL seeded (1M rows)
- [ ] Phase 4: NGINX configured (upstream, SSL, rate limiting, JSON logs)
- [ ] Phase 5: Blue-green deploy script working end-to-end
- [ ] Phase 6: Observability stack live (VictoriaMetrics + Grafana + Loki + Alertmanager)
- [ ] Phase 7: DB indexing case study documented + captured in Grafana
- [ ] Phase 8: All three chaos scenarios runnable with runbooks
- [ ] Phase 9: better.osose.xyz publicly accessible
- [ ] README with architecture diagram
- [ ] Postmortem document for one chaos scenario

---

## File Layout (target repo structure)

```
homelab/
├── proxmox/
│   └── terraform.tfvars          # updated — traffic_proxy + app_server entries
├── ansible/
│   ├── inventory/static.ini      # updated — devops_demo group
│   └── playbooks/
│       └── bootstrap-demo.yml    # new
├── demo/                         # new top-level dir for this project
│   ├── app/
│   │   ├── main.py               # FastAPI app
│   │   ├── requirements.txt
│   │   └── seed.sql              # 1M row seed script
│   ├── nginx/
│   │   ├── nginx.conf
│   │   └── sites/demo.conf
│   ├── victoriametrics/
│   │   ├── scrape-config.yml
│   │   └── alerts.yml
│   ├── grafana/
│   │   └── dashboards/           # JSON dashboard exports
│   ├── loki/
│   │   └── loki-config.yml
│   ├── promtail/
│   │   └── promtail-config.yml
│   ├── scripts/
│   │   ├── deploy.sh             # blue-green deployment
│   │   ├── chaos.sh              # incident simulation
│   │   └── seed-db.sh            # PostgreSQL seeding
│   └── runbooks/
│       ├── backend-failure.md
│       ├── slow-query.md
│       └── traffic-spike.md
└── docs/
    └── devops-demo-blueprint.md  # this file
```

---

## Build Order

1. `terraform apply` — provision VMs
2. `ansible-playbook bootstrap-demo.yml` — install all dependencies
3. Deploy FastAPI app to both ports, seed PostgreSQL
4. Configure and reload NGINX
5. Start observability stack
6. Run deployment script against green — verify blue-green works
7. Run each chaos scenario — verify alerts fire and dashboards light up
8. Add Cloudflare tunnel entry — verify public access
9. Record walkthrough video + write postmortem
