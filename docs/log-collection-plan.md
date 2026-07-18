# Log Collection Stack — Implementation Plan

## Context

The observability layer currently covers **metrics only** — VictoriaMetrics (VMSingle/VMAgent/VMAlert), Grafana, and Alertmanager, as described in `monitoring-stack-plan.md`. There is **no log aggregation**: `devops-demo-blueprint.md` names Loki as intended-but-not-deployed.

This plan adds centralized **log collection** using **VictoriaLogs** instead of Loki. VictoriaLogs is chosen for consistency with the existing VictoriaMetrics ecosystem and for its markedly lower memory footprint — the deciding factor on a RAM-constrained homelab, where Loki's label-cardinality sensitivity is a liability. Logs are shipped by a **Fluent Bit** DaemonSet, stored by a single-node VictoriaLogs instance, and **browsed inside Grafana** via a VictoriaLogs datasource — reusing Grafana's existing login, so there is **no public log endpoint and no separate auth layer for logs**. Everything is deployed and managed by ArgoCD, consistent with how `cloudflared`, `trilium-notes`, and the monitoring stack are managed.

It reuses the existing **`monitoring`** namespace so logs sit next to metrics — the VictoriaLogs store and Grafana are same-namespace, keeping the datasource wiring trivial and enabling cross-signal (metrics ↔ logs) correlation.

> **Collector note:** the `victoria-logs-single` chart bundles **Vector** (not Fluent Bit) as its optional collector subchart. To use Fluent Bit, the store is deployed **collector-less** (`vector.enabled: false`) and Fluent Bit is deployed **separately** from its own chart (`fluent/fluent-bit`), configured to push to VictoriaLogs' native ingestion endpoint. This is two components by design.

---

## Stack Components

| Component | Chart / Image | Role |
|---|---|---|
| VictoriaLogs store (`vlsingle`) | `vm/victoria-logs-single` **0.13.9** | Log store — single-node, single binary, disk-backed. ClusterIP only, never exposed publicly. Deployed with `vector.enabled: false` (store only) |
| Fluent Bit | `fluent/fluent-bit` **0.57.9** | Per-node log collector (DaemonSet) — tails container logs, enriches with k8s metadata, pushes to VictoriaLogs. Deployed as its **own** ArgoCD Application |
| Grafana (existing) | part of `victoria-metrics-k8s-stack` | Sole UI for logs — a VictoriaLogs datasource is added to the already-deployed monitoring-stack Grafana; access is gated by Grafana's existing login |

> No ingress, no Cloudflare route, and no Authentik proxy are created for logs.

---

## Files to Create / Modify

### New files

| File | Purpose |
|---|---|
| `k8s/argo-apps/victoria-logs.yaml` | ArgoCD Application — VictoriaLogs store (multi-source: chart + repo values) |
| `k8s/charts/values/victoria-logs/values.yaml` | Helm value overrides for the store (`vector.enabled: false`, storage, retention, affinity) |
| `k8s/argo-apps/fluent-bit.yaml` | ArgoCD Application — Fluent Bit collector (multi-source: chart + repo values) |
| `k8s/charts/values/fluent-bit/values.yaml` | Helm value overrides for Fluent Bit (VictoriaLogs output, namespace exclusion, control-plane toleration) |

### Modified files

| File | Change |
|---|---|
| `k8s/charts/values/victoria-metrics-stack/values.yaml` | Add the VictoriaLogs Grafana datasource + its plugin to the existing monitoring-stack Grafana |

> No changes to `cloudflared` values and no new auth manifests — the datasource-only access path needs neither.

---

## ArgoCD Application — store (`k8s/argo-apps/victoria-logs.yaml`)

Mirrors `monitoring.yaml` exactly (multi-source: chart from VM registry + values from this repo).

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: victoria-logs
  namespace: argocd
spec:
  destination:
    namespace: monitoring
    server: https://kubernetes.default.svc
  sources:
    - repoURL: https://victoriametrics.github.io/helm-charts
      chart: victoria-logs-single
      targetRevision: 0.13.9
      helm:
        valueFiles:
          - $values/k8s/charts/values/victoria-logs/values.yaml
    - repoURL: https://github.com/nobleman97/homelab.git
      targetRevision: HEAD
      ref: values
  project: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

---

## Store values (`k8s/charts/values/victoria-logs/values.yaml`)

- **Storage:** 20Gi on `longhorn-retain`. **Retention:** 7 days (`server.retentionPeriod: 7d`).
- **Soft affinity** onto the dedicated monitoring node (`use=monitoring`), matching every other monitoring component.
- **Collector disabled:** `vector.enabled: false` — Fluent Bit is deployed separately.
- **No ingress** — ClusterIP only, reached by the in-cluster Grafana datasource and Fluent Bit.

```yaml
server:
  retentionPeriod: 7d
  persistentVolume:
    enabled: true
    storageClassName: longhorn-retain
    size: 20Gi
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          preference:
            matchExpressions:
              - key: use
                operator: In
                values:
                  - monitoring

# The chart bundles Vector as an optional collector — we use Fluent Bit instead.
vector:
  enabled: false
```

Resulting Service (from `helm template`): **`victoria-logs-victoria-logs-single-server`**, port **9428**.

---

## ArgoCD Application — collector (`k8s/argo-apps/fluent-bit.yaml`)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: fluent-bit
  namespace: argocd
spec:
  destination:
    namespace: monitoring
    server: https://kubernetes.default.svc
  sources:
    - repoURL: https://fluent.github.io/helm-charts
      chart: fluent-bit
      targetRevision: 0.57.9
      helm:
        valueFiles:
          - $values/k8s/charts/values/fluent-bit/values.yaml
    - repoURL: https://github.com/nobleman97/homelab.git
      targetRevision: HEAD
      ref: values
  project: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

---

## Fluent Bit values (`k8s/charts/values/fluent-bit/values.yaml`)

DaemonSet on **every** node (incl. control-plane, via toleration). Tails container logs, drops noisy system namespaces at the input, enriches with the `kubernetes` filter, and ships to VictoriaLogs' `/insert/jsonline` endpoint. The output config is the VictoriaLogs-documented `http` plugin.

```yaml
tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule

config:
  inputs: |
    [INPUT]
        Name              tail
        Path              /var/log/containers/*.log
        Exclude_Path      /var/log/containers/*_kube-system_*.log,/var/log/containers/*_kube-public_*.log,/var/log/containers/*_kube-node-lease_*.log
        multiline.parser  docker, cri
        Tag               kube.*
        Mem_Buf_Limit     16MB
        Skip_Long_Lines   On

  filters: |
    [FILTER]
        Name                kubernetes
        Match               kube.*
        Merge_Log           On
        Keep_Log            Off
        K8S-Logging.Parser  On
        K8S-Logging.Exclude On

  # VictoriaLogs http output (per docs.victoriametrics.com/victorialogs/data-ingestion/fluentbit).
  # Stream fields use the k8s metadata added by the filter above.
  outputs: |
    [OUTPUT]
        Name             http
        Match            *
        host             victoria-logs-victoria-logs-single-server.monitoring.svc.cluster.local
        port             9428
        uri              /insert/jsonline?_stream_fields=stream,kubernetes_namespace_name,kubernetes_pod_name,kubernetes_container_name&_msg_field=log&_time_field=date
        format           json_lines
        json_date_format iso8601
        compress         gzip
```

> Excluding system namespaces at `Exclude_Path` is cheapest — those files are never read. `longhorn-system` is intentionally **kept** (useful for debugging storage). Stream-field names reflect how the Fluent Bit kubernetes filter flattens metadata; verify against a real ingested line during rollout and adjust if the keys differ.

---

## Grafana datasource (`k8s/charts/values/victoria-metrics-stack/values.yaml`)

Logs are queried **only** through Grafana. Append to the existing `grafana:` block:

```yaml
grafana:
  # ... existing keys unchanged ...
  plugins:
    - victoriametrics-logs-datasource
  additionalDataSources:
    - name: VictoriaLogs
      type: victoriametrics-logs-datasource
      access: proxy
      url: http://victoria-logs-victoria-logs-single-server.monitoring.svc.cluster.local:9428
      isDefault: false        # MUST stay false — the VM metrics datasource is the default
```

- `isDefault: false` is critical: per `monitoring-stack-plan.md`, a second `isDefault: true` datasource crashes Grafana on startup.
- Applying this is a re-sync of the existing `monitoring` ArgoCD Application.

---

## Log Collection Flow

```
Every k8s node:
  /var/log/containers/*.log ─(minus kube-system/public/node-lease)→ Fluent Bit (DaemonSet)
        └─http /insert/jsonline─► VictoriaLogs (vlsingle, ClusterIP :9428) ◄─query─ Grafana ─► you
```

---

## Pre-requisites

1. **`monitoring` namespace** — already present from the metrics stack. No secret is required.
2. **VictoriaLogs Grafana plugin** — `victoriametrics-logs-datasource` must be installable by Grafana (handled by `grafana.plugins`). If Grafana runs with a restricted allowlist or no egress, pre-provision it.

No Authentik application, no Cloudflare DNS/tunnel entry, no Traefik IngressRoute.

---

## Deployment order

```bash
# 1. Commit the new/changed files to the repo and push to the branch ArgoCD tracks (HEAD/main).
# 2. Apply the two ArgoCD Applications:
kubectl apply -f k8s/argo-apps/victoria-logs.yaml
kubectl apply -f k8s/argo-apps/fluent-bit.yaml
# 3. Re-sync the existing monitoring app so Grafana picks up the datasource
#    (auto-sync + selfHeal will do this once the values commit lands).
```

---

## Phase 2 (optional) — External VM logs

The demo VMs (`traffic-proxy-01`, `app-server-01`, `postgres-01`) run outside the cluster and produce the logs the demo cares about — NGINX JSON access/error logs and PostgreSQL slow-query logs (see `devops-demo-blueprint.md`). These are **not** collected by the in-cluster DaemonSet.

To ingest them later — mirroring how VM *metrics* are handled via `VMStaticScrape` — run a lightweight Fluent Bit agent on each VM (installed by its Ansible role) with the same `http /insert/jsonline` output, pointed at a **LAN-only** ingestion path to VictoriaLogs (e.g. a NodePort restricted to `192.168.100.0/24`, since the Service is ClusterIP-only). No auth concern to work around — there is no public log endpoint.

Left unspecified to keep Phase 1 focused; spec it as a follow-up once cluster-log collection is verified.

---

## Verification

1. **ArgoCD** — `victoria-logs` and `fluent-bit` Applications healthy and synced at `argo.osose.xyz`.
2. **Store** — `vlsingle` pod running: `kubectl get pods -n monitoring | grep victoria-logs`.
3. **Collector** — a Fluent Bit pod on **every** node: `kubectl get pods -n monitoring -o wide | grep fluent-bit` (count == node count, incl. control-plane).
4. **Ingestion + namespace exclusion** — port-forward the store and query with LogsQL:
   ```bash
   kubectl port-forward -n monitoring svc/victoria-logs-victoria-logs-single-server 9428:9428
   # should return lines:
   curl -s 'http://localhost:9428/select/logsql/query' \
     --data-urlencode 'query=kubernetes_namespace_name:apps' --data-urlencode 'limit=5'
   # should be EMPTY (excluded):
   curl -s 'http://localhost:9428/select/logsql/query' \
     --data-urlencode 'query=kubernetes_namespace_name:kube-system' --data-urlencode 'limit=1'
   ```
5. **Grafana datasource** — in Grafana (`grafana.osose.xyz`) under **Connections → Data sources**, the `VictoriaLogs` datasource is present, **Test** succeeds, and **Explore → VictoriaLogs** returns recent log lines.
6. **Retention/disk** — after a day, PVC bound on `longhorn-retain`, disk within the 20Gi/7-day budget: `kubectl get pvc -n monitoring`.
