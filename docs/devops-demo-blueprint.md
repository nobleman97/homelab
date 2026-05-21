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

### FastAPI App (`projects/better/app/`)

A realistic e-commerce-style API. All routes are prefixed with `/api/`.

| Endpoint | Description |
|---|---|
| `GET /health` | Health check — returns `{"status":"ok","version":"blue\|green"}`. Bypasses NGINX rate limit. |
| `GET /api/products` | Paginated list. Params: `?page=`, `?limit=` (max 100), `?category=`. Intentionally slow without index (seq scan on 1M rows). |
| `GET /api/products/{id}` | Single product by ID. Returns 404 if not found. |
| `POST /api/orders` | Create order `{product_id, quantity}`. Validates stock (409 if insufficient), decrements stock and inserts order atomically in a single transaction. |
| `GET /api/orders` | Recent 50 orders with product name (JOIN). |
| `GET /api/stats` | Aggregates: total products, orders today, orders/min (last 5min), avg order value, top 5 categories by order volume. |

Environment variable `APP_VERSION` (`blue` / `green`) — injected by the systemd unit, returned in every response as header `X-App-Version` so the active upstream is always visible.

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

**On `traffic-proxy-01`:**
- Site config: `/etc/nginx/sites-available/better.conf` (symlinked to `sites-enabled/`)
- Stub status: `/etc/nginx/conf.d/stub_status.conf`

SSL is terminated by Cloudflare — NGINX listens on port 80 only. The Cloudflare tunnel handles TLS end-to-end; no SSL certs on the VM.

Blue/green is controlled via the `down` flag in the NGINX upstream block. The active version is set by the `active_version` Ansible variable (default: `blue`) in `ansible/roles/nginx/defaults/main.yml`. Cutover is done by re-running the playbook with `-e active_version=green` — no manual SSH or file editing required. See **Phase 7** for the cutover command.

Both `demo-blue` (`:8001`) and `demo-green` (`:8002`) run at all times on `app-server-01`. NGINX's `down` flag keeps the standby out of rotation; the running process is ready to take traffic the instant nginx reloads.

The upstream block in `ansible/roles/nginx/templates/better.conf.j2` (Jinja2 source):

```nginx
upstream app_backend {
    server 192.168.100.32:8001{% if active_version != 'blue' %} down{% endif %};   # blue
    server 192.168.100.32:8002{% if active_version != 'green' %} down{% endif %};  # green
    keepalive 32;
}
```

Full site config:

```nginx
log_format json_combined escape=json
  '{'
    '"time":"$time_iso8601",'
    '"remote_addr":"$remote_addr",'
    '"method":"$request_method",'
    '"uri":"$request_uri",'
    '"status":$status,'
    '"bytes_sent":$bytes_sent,'
    '"request_time":$request_time,'
    '"upstream_addr":"$upstream_addr",'
    '"upstream_response_time":"$upstream_response_time",'
    '"http_user_agent":"$http_user_agent"'
  '}';

limit_req_zone $binary_remote_addr zone=api_limit:10m rate=30r/s;

upstream app_backend {
    server 192.168.100.32:8001;   # blue  (active when active_version=blue)
    server 192.168.100.32:8002 down;   # green (standby)
    keepalive 32;
}

server {
    listen 80;
    server_name better.osose.xyz;

    access_log /var/log/nginx/better_access.log json_combined;
    error_log  /var/log/nginx/better_error.log warn;

    # Health check — bypasses rate limit (used by blue-green deploy script)
    location = /health {
        proxy_pass        http://app_backend;
        proxy_set_header  Host $host;
        proxy_set_header  X-Real-IP $remote_addr;
        proxy_connect_timeout 2s;
        proxy_read_timeout    5s;
    }

    # API — rate limited, proxied to FastAPI
    location /api/ {
        limit_req zone=api_limit burst=50 nodelay;

        proxy_pass        http://app_backend;
        proxy_set_header  Host $host;
        proxy_set_header  X-Real-IP $remote_addr;
        proxy_set_header  X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_next_upstream error timeout http_502 http_503;
        proxy_connect_timeout 2s;
        proxy_read_timeout    30s;

        add_header X-Upstream $upstream_addr always;
    }

    # Frontend — static files served from /var/www/better
    location / {
        root  /var/www/better;
        index index.html;
        try_files $uri $uri/ /index.html;
        expires 1h;
        add_header Cache-Control "public";
    }

    # JSON error responses
    error_page 429 @rate_limited;
    error_page 502 503 @upstream_error;

    location @rate_limited {
        default_type application/json;
        return 429 '{"error":"rate_limited","message":"Too many requests"}';
    }

    location @upstream_error {
        default_type application/json;
        return 502 '{"error":"upstream_unavailable","message":"Backend temporarily unavailable"}';
    }
}
```

Stub status (scraped by nginx-prometheus-exporter on `:9113`):

```nginx
server {
    listen 8080;
    server_name 127.0.0.1;

    location /stub_status {
        stub_status;
        allow 127.0.0.1;
        deny all;
    }
}
```

---

## Phase 5 — Load Testing

Load tests live in `projects/better/load-tests/`. All scripts default to `http://192.168.100.31` — override with `BASE_URL` env var to target the public endpoint instead.

**Prerequisite:** k6 installed locally (`brew install k6` / `apt install k6`).

---

### Test 1 — Baseline (`load-normal.js`)

Steady 50 VUs for 5 minutes. Mixed traffic: 70% product browsing, 20% order placement, 10% stats.

```bash
k6 run projects/better/load-tests/load-normal.js
# or against the public endpoint:
BASE_URL=https://better.osose.xyz k6 run projects/better/load-tests/load-normal.js
```

**Thresholds:** p95 < 500ms, error rate < 1%.

**Watch in Grafana:** NGINX request rate and upstream response time (Node Exporter Full + NGINX dashboard). This establishes the healthy baseline to compare against.

---

### Test 2 — Spike (`load-spike.js`)

Ramps from 10 → 500 VUs over 30s, holds for 1 minute, then winds down.

```bash
k6 run projects/better/load-tests/load-spike.js
```

**What to expect:** 429s appear as soon as the rate limiter kicks in (NGINX `limit_req zone=api_limit rate=30r/s`). The k6 `rate_limited` counter tracks them separately — they are not counted as errors.

**Watch in Grafana:** NGINX dashboard → 4xx rate spike during the hold phase. Backend error rate should stay flat (rate limiting protected it).

---

### Test 3 — DB stress, before/after index (`load-db-stress.js`)

100 VUs hammering `GET /api/products?category=electronics` for 2 minutes. This hits a full sequential scan on 1M rows.

**Step 1 — Run before the index (captures the slow baseline):**
```bash
k6 run projects/better/load-tests/load-db-stress.js
```
Expected: p95 > 1000ms. Screenshot the Grafana PostgreSQL dashboard.

**Step 2 — Add the index (zero-downtime, `CONCURRENTLY` holds no table lock):**
```bash
ssh postgres-01 "psql -U postgres -d demo -c \"
  CREATE INDEX CONCURRENTLY idx_products_category_created
  ON products (category, created_at DESC);
\""
```

**Step 3 — Run after the index:**
```bash
k6 run projects/better/load-tests/load-db-stress.js
```
Expected: p95 drops to < 10ms. The before/after comparison in Grafana is the key deliverable for the DB performance case study.

**Verify the index is being used:**
```bash
ssh postgres-01 "psql -U postgres -d demo -c \"
  EXPLAIN ANALYZE
  SELECT * FROM products WHERE category = 'electronics'
  ORDER BY created_at DESC LIMIT 20;
\""
```
Look for `Index Scan using idx_products_category_created` in the output.

---

## Phase 7 — Blue-Green Cutover

Cutover is driven by the `active_version` Ansible variable. Both systemd services (`demo-blue` on `:8001`, `demo-green` on `:8002`) run continuously on `app-server-01`. NGINX's `down` flag controls which receives traffic.

**Switch to green:**
```bash
cd ansible
ansible-playbook playbooks/bootstrap-demo.yml --limit demo_proxy -e active_version=green
```

**Roll back to blue:**
```bash
ansible-playbook playbooks/bootstrap-demo.yml --limit demo_proxy -e active_version=blue
```

The playbook renders the NGINX upstream template with the new value and reloads nginx — zero downtime, no manual SSH required.

**Default:** `active_version: blue` is set in `ansible/roles/nginx/defaults/main.yml`. Running the playbook without `-e` always returns to blue.

**Verify the active version:**
```bash
curl -s https://better.osose.xyz/health
# → {"status":"ok","version":"green"}
```

The `version` field reflects which systemd unit handled the request (`APP_VERSION` env var injected by the unit file). The `X-Upstream` response header also shows the upstream IP:port that served the request.

> **Note:** `demo-green` crashed on first boot (2026-05-20) because PostgreSQL was not yet reachable when it tried to establish its startup connection pool. The Ansible `app` role has been updated to keep green in `state: started` so both instances are always warm. If green is found stopped, start it manually with `sudo systemctl start demo-green` on `app-server-01` before running a cutover.

---

## Phase 8 — Observability Stack (Kubernetes — deployed)

Deployed to the existing K8s cluster via ArgoCD (`k8s/argo-apps/monitoring.yaml`), using the `victoria-metrics-k8s-stack` Helm chart. See `docs/monitoring-stack-plan.md` for full setup details.

### Exporters on VMs

| VM | Exporter | Port |
|---|---|---|
| traffic-proxy-01 (.31) | node_exporter | :9100 |
| traffic-proxy-01 (.31) | nginx-prometheus-exporter | :9113 |
| app-server-01 (.32) | node_exporter | :9100 |
| postgres-01 (.33) | node_exporter | :9100 |
| postgres-01 (.33) | postgres_exporter | :9187 |

### K8s stack components

| Component | Status |
|---|---|
| VMSingle | Deployed — 20Gi on `longhorn-retain`, 15-day retention |
| VMAgent | Deployed — scrapes VMs via `VMStaticScrape` CRDs (`k8s/manifest/monitoring/vm-static-scrapes.yaml`) |
| VMAlert | Deployed |
| Alertmanager | Deployed — email routing via Gmail SMTP (config in `alertmanager-config` secret) |
| Grafana | Deployed at `grafana.osose.xyz` — OIDC via Authentik, dashboards: Node Exporter Full (1860), NGINX (12708), PostgreSQL (9628), k3s (15282) |
| Loki + Promtail | Not deployed |

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
k6 run projects/better/load-tests/load-spike.js
```
**Observable:** NGINX rate limiting kicks in (429s appear in access log) → Grafana NGINX dashboard shows 4xx spike → backend error rate stays flat because rate limiting absorbed the load.

---

## Phase 9 — Public Exposure (Cloudflare Tunnel)

The existing `cloudflared` tunnel runs in the K8s cluster (managed by ArgoCD). Hostnames are added via `k8s/charts/values/cloudflared/values.yaml`.

`better.osose.xyz` routes directly to NGINX on `traffic-proxy-01` — not through Traefik, since the app is a VM workload:

```yaml
- hostname: better.osose.xyz
  service: http://192.168.100.31:80
```

`grafana.osose.xyz` routes to the Grafana service in the `monitoring` namespace:

```yaml
- hostname: grafana.osose.xyz
  service: http://monitoring-grafana.monitoring.svc.cluster.local:80
```

Both entries are live. ArgoCD auto-syncs changes to this file.

---

## Deliverables Checklist

- [x] Phase 1: Terraform — VMs provisioned (traffic-proxy-01, app-server-01, postgres-01)
- [x] Phase 2: Ansible — VMs bootstrapped (`ansible/playbooks/bootstrap-demo.yml`)
- [x] Phase 3: FastAPI app + PostgreSQL seeded (1M products, 10K orders)
- [x] Phase 4: NGINX configured (upstream, rate limiting, JSON logs, static frontend)
- [x] Phase 5: Load tests written (`projects/better/load-tests/`) — not yet run against live stack
- [x] Phase 6: Blue-green cutover — Ansible `active_version` variable drives NGINX upstream; both services always running
- [x] Phase 7: DB indexing case study documented — Grafana capture pending (run load-db-stress.js)
- [x] Phase 8: Observability stack live (VictoriaMetrics + VMAgent + Grafana + Alertmanager; Loki not deployed)
- [ ] Phase 9: Chaos scenarios runnable with runbooks (`scripts/chaos.sh` — not yet implemented)
- [x] Phase 10: better.osose.xyz publicly accessible via Cloudflare tunnel
- [ ] README with architecture diagram
- [ ] Postmortem document for one chaos scenario

---

## File Layout (actual repo structure)

```
homelab/
├── terraform/proxmox/
│   └── terraform.tfvars          # traffic_proxy, app_server, postgres_1 VM definitions
├── ansible/
│   ├── inventory/static.ini      # devops_demo, demo_proxy, demo_app, demo_db groups
│   ├── playbooks/
│   │   └── bootstrap-demo.yml    # orchestrates common + nginx/app/postgres roles
│   └── roles/
│       ├── common/               # node_exporter, base packages, ufw
│       ├── nginx/                # NGINX, stub_status, nginx-prometheus-exporter; defaults/main.yml sets active_version
│       ├── app/                  # Python venv, FastAPI blue/green systemd units
│       └── postgres/             # PostgreSQL 15, pg_stat_statements, postgres_exporter
├── projects/better/
│   ├── app/
│   │   ├── main.py               # FastAPI app + version header middleware
│   │   ├── database.py           # asyncpg connection pool
│   │   ├── routers/
│   │   │   ├── products.py
│   │   │   ├── orders.py
│   │   │   └── stats.py
│   │   ├── requirements.txt
│   │   └── seed.sql              # 1M products + 10K orders
│   ├── frontend/
│   │   ├── index.html
│   │   ├── css/style.css
│   │   └── js/app.js
│   └── load-tests/
│       ├── load-normal.js        # 50 VUs, 5min baseline
│       ├── load-spike.js         # ramp to 500 VUs, triggers rate limiting
│       └── load-db-stress.js     # before/after index demo
├── k8s/
│   ├── argo-apps/monitoring.yaml # ArgoCD Application for victoria-metrics-k8s-stack
│   ├── charts/values/
│   │   ├── cloudflared/values.yaml   # better.osose.xyz + grafana.osose.xyz tunnel entries
│   │   └── victoria-metrics-stack/values.yaml
│   └── manifest/monitoring/
│       └── vm-static-scrapes.yaml    # VMStaticScrape for node/postgres exporters
└── docs/
    ├── devops-demo-blueprint.md  # this file
    └── monitoring-stack-plan.md  # observability stack setup details
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
