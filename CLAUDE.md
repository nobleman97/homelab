# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Structure

This homelab repo has four subsystems:

- `terraform/` — Terraform IaC for provisioning VMs on the Proxmox hosts (`proxmox/` root module, `modules/k8s-vm/` shared VM module)
- `ansible/` — Playbooks for k3s node dependencies, joining workers and upgrading k3s
- `k8s/` — Kubernetes manifests, Helm value overrides, and ArgoCD app definitions
- `docs/` — Operational runbooks and incident write-ups (CNPG backups/migration, monitoring, logging, NIC/DNS outages). Runbooks for retired things carry a "Decommissioned" banner.

The domain for all public-facing services is **osose.xyz**, fronted by a Cloudflare tunnel.

## Proxmox / Terraform

All proxmox work is done from the `terraform/proxmox/` directory. See `terraform/proxmox/CLAUDE.md` for the full reference.

```bash
cd terraform/proxmox
terraform init          # initialize providers (Telmate/proxmox v3.0.2-rc07)
terraform validate
terraform plan
terraform apply
terraform apply -target='module.vms["<key>"]'   # target a single VM (key from terraform.tfvars, e.g. worker_node_2)
```

**Authentication**: The Proxmox API token secret is passed via env var — never hardcoded:
```bash
export TF_VAR_proxmox_api_token_secret="your-secret"
```
The token ID is `terraform-prov@pve!terraform` (set in `providers.tf`).

**State**: Remote state lives in S3 (`devopsroyale-state-files-ccsji365i`, key `homelab/proxmox/terraform.tfstate`) with DynamoDB locking (`terraform-locks` table). The S3 backend is active (not commented out).

### Current VMs

`main.tf` calls `../modules/k8s-vm` with `for_each = var.vms`; the VMs are defined in `terraform.tfvars` (tracked in git).

| tfvars key | VM name | Proxmox host | IP | k3s node | Specs |
|---|---|---|---|---|---|
| `control_plane` | k8s-control-plane-01 | `proxmox` | 192.168.100.25 | k3s-server | 4 cores, 6 GB RAM, 40 GB disk |
| `worker_node` | k8s-worker-node-01 | `proxmox` | 192.168.100.26 | k3s-worker-1 | 3 cores, 6 GB RAM, 60 GB disk |
| `worker_node_2` | k8s-worker-node-02 | `david` | 192.168.100.27 | k3s-worker-2 | 3 cores, 6 GB RAM, 90 GB disk |
| `worker_node_3` | k8s-worker-node-03 | `david` | 192.168.100.28 | k3s-worker-3 | 3 cores, 6 GB RAM, 90 GB disk |

All VMs clone from Debian 12 templates (`debian-12-template-server` / `-worker`), use cloud-init (`ciuser: debian`, SSH key at `~/.ssh/lab.pub`), and connect to bridge `vmbr0`. DNS is 192.168.100.30, gateway is 192.168.100.1. Proxmox tags (`k8s_nodes`, `k8s_control_plane`, `k8s_workers`) feed the Ansible dynamic inventory.

The cluster runs **k3s** (v1.36.5+k3s1). `k3s-server` is cordoned and tainted `reserved=true:PreferNoSchedule`; `k3s-worker-2` is labelled `use=monitoring`.

## Ansible

Bootstraps k3s node OS-level dependencies. Run from `ansible/` using the venv (`ansible.cfg` defaults to the static inventory, user `debian`, key `~/.ssh/lab`):

```bash
cd ansible
source .venv/bin/activate          # activate the Python venv
ansible-playbook playbooks/install-deps.yml
```

**Inventory**: `ansible/inventory/static.ini` — four hosts, each with a `k3s_node_name`: `k8s-control-plane-01` (`.25`, k3s-server), `k8s-worker-node-01..03` (`.26`–`.28`, k3s-worker-1..3). Groups `k8s_nodes`, `k8s_control_plane`, `k8s_workers`. `inventory/dynamic/proxmox.yml` builds the same groups from Proxmox tags.

**Playbooks**:
- `install-deps.yml` — installs `util-linux`, `curl`, `grep`, `gawk`, `open-iscsi` (required by Longhorn) and ensures `iscsid` is enabled and running
- `join-k3s-worker.yml` — runs `install-deps.yml`, then the `k3s-worker` role on `k8s_workers` (needs `k3s_token`)
- `upgrade-k3s.yml` — `k3s-upgrade` role, control plane first, then workers `serial: 1` (needs `-e k3s_version=... -e k3s_token=...`)

## Kubernetes

### Directory layout

```
k8s/
├── argo-apps/          # ArgoCD Application CRDs (one file per app)
├── charts/
│   └── values/         # Helm value overrides, one dir per release
│       ├── argocd/
│       ├── authentik/
│       ├── cert-manager/
│       ├── cloudflared/
│       ├── fluent-bit/
│       ├── longhorn/
│       ├── personal/              # empty, untracked
│       ├── victoria-logs/
│       └── victoria-metrics-stack/
└── manifest/
    ├── apps/
    │   ├── guide_1.yaml           # tech-noexp landing page (ns landing-pages)
    │   └── jellyfin/              # Jellyfin + sonarr/radarr/prowlarr/qbittorrent (ns jellyfin)
    ├── auth/           # Authentik outpost Deployment/Service, Traefik ForwardAuth middleware
    ├── cnpg/           # CloudNativePG Cluster + ObjectStores + ScheduledBackup
    ├── monitoring/     # VMAlertmanagerConfig routes, debug PV pod (datadog-agent.yaml is gitignored)
    ├── wordpress/      # cognitaid.com WordPress + MariaDB + Redis + its own cloudflared (ns wordpress)
    ├── clusterissuer.yaml
    └── storage-classes.yaml
```

Apply manifests with `kubectl apply -f <file>`. Everything under `k8s/manifest/` (including Jellyfin and WordPress) is applied manually — no ArgoCD app covers it.

### Helm releases

Per `helm list -A` and `kubectl get applications -n argocd`:

| Release | Chart | Namespace | How it's managed |
|---|---|---|---|
| argo | argo/argo-cd 9.5.4 | argocd | manual Helm, values in `k8s/charts/values/argocd/`. Release name is `argo` (the values file comment says `argocd`) |
| authentik | goauthentik/authentik 2026.2.3 | apps | manual Helm: `helm upgrade --install authentik goauthentik/authentik --version 2026.2.3 -f values.yaml -n apps` (in values dir) |
| cert-manager | cert-manager v1.20.2 | cert-manager | manual Helm, values in `k8s/charts/values/cert-manager/` |
| longhorn | longhorn 1.11.2 | longhorn-system | manual Helm, values in `k8s/charts/values/longhorn/` |
| traefik, traefik-crd | traefik 40.1.5+up40.1.0 | kube-system | bundled with k3s |
| cloudflared | community-charts/cloudflared 2.2.7 | cloudflare | ArgoCD (`k8s/argo-apps/cloudflared.yaml`) |
| monitoring | victoria-metrics-k8s-stack 0.79.1 | monitoring | ArgoCD (`k8s/argo-apps/monitoring.yaml`) |
| victoria-logs | victoria-logs-single 0.13.9 | monitoring | ArgoCD (`k8s/argo-apps/victoria-logs.yaml`) |
| fluent-bit | fluent/fluent-bit 0.57.9 | monitoring | ArgoCD (`k8s/argo-apps/fluent-bit.yaml`) |

Never `helm upgrade`/`helm uninstall` an ArgoCD-managed release by hand: ArgoCD owns those objects, so a manual upgrade fails with field-manager conflicts and an uninstall deletes the live resources. (A stale failed `cloudflared` Helm release was cleaned up on 2026-11-22 by deleting only its `sh.helm.release.v1.cloudflared.*` secrets.)

The Authentik outpost is the hand-applied `authentik-outpost` Deployment (`k8s/manifest/auth/`); it authenticates as the `homelab-proxy` outpost. Authentik-generated `ak-outpost-homelab-proxy` objects were orphans and were deleted on 2026-11-22.

### ArgoCD Apps

ArgoCD is exposed at **argo.osose.xyz** (Cloudflare tunnel → ArgoCD server).  
OIDC login is wired to Authentik (`auth.osose.xyz`); members of the `argocd-admins` group get `role:admin`, everyone else `role:readonly`.

All four apps use the multi-source pattern: chart from the upstream repo, values from `$values/k8s/charts/values/<dir>/values.yaml` in `github.com/nobleman97/homelab` at `targetRevision: HEAD`.

- `cloudflared.yaml` — `community-charts/cloudflared` 2.2.7 → ns `cloudflare` (auto-sync, no prune/self-heal)
- `monitoring.yaml` — `victoria-metrics-k8s-stack` 0.79.1 → ns `monitoring` (auto-sync, prune, self-heal, ServerSideApply)
- `victoria-logs.yaml` — `victoria-logs-single` 0.13.9 → ns `monitoring` (auto-sync, prune, self-heal)
- `fluent-bit.yaml` — `fluent-bit` 0.57.9 → ns `monitoring` (auto-sync, prune, self-heal)

### Networking & Ingress

- **Ingress controller**: Traefik (bundled with k3s)
- **TLS**: cert-manager with a `letsencrypt-cloudflare` ClusterIssuer (DNS-01 via Cloudflare API token)
- **External access**: Cloudflare tunnel (`cloudflared`) — no ports exposed directly from the cluster
- **Auth**: Authentik reverse-proxy outpost (`ghcr.io/goauthentik/proxy:2026.2.3`) in namespace `apps`; Traefik `ForwardAuth` middleware (`authentik-forward-auth`). No IngressRoute currently uses it.

#### Public hostnames (`k8s/charts/values/cloudflared/values.yaml`)

The tunnel routes straight to each Service (not through Traefik):

| Host | Service | Port |
|---|---|---|
| argo.osose.xyz | argo-argocd-server.argocd | 80 |
| auth.osose.xyz | authentik-server.apps | 80 |
| longhorn.osose.xyz | longhorn-frontend.longhorn-system | 80 |
| grafana.osose.xyz | monitoring-grafana.monitoring | 80 |
| techguide.osose.xyz | tech-noexp-svc.landing-pages | 80 |
| jellyfin.osose.xyz | jellyfin.jellyfin | 8096 |
| sonar.osose.xyz | sonarr.jellyfin | 8989 |

ArgoCD and Grafana log in via Authentik OIDC (Grafana: `grafana-admins` → Admin, else Viewer). WordPress (`cognitaid.com`) uses its own `cloudflared` Deployment in ns `wordpress`; image is `wordpress:php8.5-apache`.

### Monitoring & Logging

- **Metrics**: `victoria-metrics-k8s-stack` (VMSingle, VMAgent, VMAlert, Alertmanager, Grafana, kube-state-metrics, node-exporter) in ns `monitoring`. VMSingle: 15d retention, 20Gi on `longhorn-retain`. Pods prefer nodes labelled `use=monitoring`.
- **Query endpoint**: `svc/vmsingle-monitoring-victoria-metrics-k8s-stack` port **8428** in ns `monitoring` (e.g. `kubectl -n monitoring port-forward svc/vmsingle-monitoring-victoria-metrics-k8s-stack 8428`).
- **Double-counting caveat**: since commit a79dbc0 the kubelet `/metrics/resource` scrape is disabled because it duplicated cadvisor container metrics (every `sum()` read 2x). Data before 2026-11-22 ~18:37 UTC is still doubled — filter `metrics_path="/metrics/cadvisor"` for historical queries.
- **Logs**: `fluent-bit` DaemonSet tails container logs and ships them over HTTP to `victoria-logs-victoria-logs-single-server.monitoring:9428` (7d retention, 10Gi on `longhorn-retain`). Logs are queried through Grafana's VictoriaLogs datasource.
- Alertmanager config comes from the `alertmanager-config` secret; extra routes in `k8s/manifest/monitoring/alertmanager-routes.yaml`.

### Storage

Two Longhorn StorageClasses in `k8s/manifest/storage-classes.yaml`:

| Name | Reclaim Policy | Use for |
|---|---|---|
| `longhorn-delete` | Delete | Ephemeral / dev workloads |
| `longhorn-retain` | Retain | Stateful / production data |

Both use 2 replicas, `WaitForFirstConsumer`, and ext4.  
Longhorn requires `open-iscsi` + `iscsid` on every node (handled by the Ansible playbook).

### Database (CloudNativePG)

`k8s/manifest/cnpg/cluster.yaml` defines:

- **Cluster** `master-db` in namespace `database` — 1 instance, 20Gi on `longhorn-retain`, requests 200m/640Mi; prefers to avoid `k3s-worker-2` (see `docs/worker-2-nic-failure.md`)
- **Bootstrap**: recovers from `master-db-backup` → ObjectStore `master-db-store` (S3: `s3://objectstore-199174511003-us-east-1-an`)
- **WAL archival**: barman-cloud plugin writes to `master-db-store-v2` (`…/v2` path) after recovery; 14d retention
- **ScheduledBackup** `master-db-daily`: daily at `01:50` UTC

Authentik connects to `master-db-rw.database.svc.cluster.local`, database `authentik`; DB settings come from the `authentik` secret (`authentik.existingSecret`).

The CNPG operator and barman-cloud plugin (ns `cnpg-system`) must be installed before applying `cluster.yaml`.

### Authentik

Release `authentik` in ns `apps` (revision 2). Runs `AUTHENTIK_WEB__WORKERS=1`; requests only, no limits: server 75m/768Mi, worker 50m/640Mi. Measured usage was ~1Gi for the server with 2 gunicorn workers and ~600Mi for the worker. Past restarts were caused by `master-db` outages, not OOM.

### Sensitive files

`env/` is gitignored and holds:
- `cfd_cert.pem`, `cfd_config.yaml`, `cfd_credentials.json` — Cloudflare tunnel credentials
- `secret.json` — miscellaneous secrets
- `n8n_backup.sql` — n8n database backup

Never commit anything from `env/`.
