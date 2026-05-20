# Monitoring & Alerting Stack — Implementation Plan

## Context

The homelab currently has no observability layer. This plan adds a monitoring and alerting stack using VictoriaMetrics (instead of Prometheus), Grafana (behind Authentik OIDC SSO), and Alertmanager (email alerts to davidstone097@gmail.com). The stack is deployed and managed by ArgoCD, consistent with how cloudflared and trilium-notes are managed.

---

## Stack Components

| Component | Role |
|---|---|
| `victoria-metrics-k8s-stack` | Helm chart bundling all components below — deployed as a single ArgoCD Application |
| VMSingle | Time-series database (VictoriaMetrics single-node, suitable for homelab) |
| VMAgent | Prometheus-compatible scrape agent — collects metrics from nodes, pods, k8s API |
| VMAlert | Evaluates alerting rules against VMSingle |
| Alertmanager | Routes alerts → email (davidstone097@gmail.com via Gmail SMTP) |
| Grafana | Bundled subchart within `victoria-metrics-k8s-stack`; enabled via `grafana.enabled: true` in values — **no separate install step required**. OIDC login wired to Authentik. |

> All components are installed in one shot when ArgoCD syncs the `monitoring` Application. There is no separate Grafana installation.

---

## Files to Create / Modify

### New files

| File | Purpose |
|---|---|
| `k8s/argo-apps/monitoring.yaml` | ArgoCD Application CRD (multi-source: chart from VM registry + values from this repo) |
| `k8s/charts/values/victoria-metrics-stack/values.yaml` | All Helm value overrides for the stack |

### Modified files

| File | Change |
|---|---|
| `k8s/charts/values/cloudflared/values.yaml` | Add `grafana.osose.xyz` ingress rule pointing to Grafana service |

---

## ArgoCD Application (`k8s/argo-apps/monitoring.yaml`)

Follows the multi-source pattern from `cloudflared.yaml`: Helm chart pulled from the VictoriaMetrics registry, values pulled from this Git repo.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: monitoring
  namespace: argocd
spec:
  destination:
    namespace: monitoring
    server: https://kubernetes.default.svc
  sources:
    - repoURL: https://victoriametrics.github.io/helm-charts
      chart: victoria-metrics-k8s-stack
      targetRevision: 0.35.0   # verify latest at https://github.com/VictoriaMetrics/helm-charts/releases
      helm:
        valueFiles:
          - $values/k8s/charts/values/victoria-metrics-stack/values.yaml
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

## Helm Values (`k8s/charts/values/victoria-metrics-stack/values.yaml`)

### Node scheduling — dedicated monitoring node
A second worker node exists with label `use=monitoring`. All monitoring components use `preferredDuringSchedulingIgnoredDuringExecution` affinity (soft preference) so pods can still schedule elsewhere if the node is unavailable.

Each component in the values file gets:
```yaml
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
```

This is applied to: `vmsingle.spec`, `vmagent.spec`, `vmalert.spec`, `alertmanager.spec`, and `grafana` (which uses the standard Grafana chart's top-level `affinity` key).

### VMSingle — storage
- 20Gi on `longhorn-retain` (persists across pod restarts)
- 30-day retention

### VMAgent
- Enabled with defaults; scrapes nodes, pods, kube-state-metrics, cadvisor

### VMAlert
- Enabled; evaluates rules against VMSingle

### Alertmanager — email routing
- SMTP: `smtp.gmail.com:587`
- From/to: `davidstone097@gmail.com`
- **SMTP password is not stored in Git.** It is injected via a Kubernetes secret (`alertmanager-config` in `monitoring` namespace — see Pre-requisites below).
- The full alertmanager config (including password) lives in that secret under key `alertmanager.yaml`; VMAlertmanager reads it via `spec.configSecret`.

### Grafana — OIDC SSO
- Grafana has native OIDC support (same approach as ArgoCD, not ForwardAuth proxy).
- OIDC endpoints point to `https://auth.osose.xyz/application/o/grafana/`
- Client ID and secret injected via secret `grafana-oidc-secret` in `monitoring` namespace (see Pre-requisites).
- Role mapping: members of `grafana-admins` Authentik group → Grafana `Admin`; everyone else → `Viewer`.
- Persistence: 2Gi on `longhorn-retain`.
- Ingress disabled in chart values (`ingress.enabled: false`); Cloudflare tunnel routes directly to the Grafana service — no Traefik IngressRoute needed since there is no ForwardAuth middleware to apply.

---

## Cloudflare Tunnel update (`k8s/charts/values/cloudflared/values.yaml`)

Add one entry to the `ingress` list (before the catch-all):

```yaml
- hostname: grafana.osose.xyz
  service: http://monitoring-grafana.monitoring.svc.cluster.local:80
```

---

## Pre-requisites (manual steps before ArgoCD sync)

These secrets must exist in the `monitoring` namespace before the stack deploys:

### 1. Alertmanager config secret

```bash
kubectl create namespace monitoring

kubectl create secret generic alertmanager-config \
  --namespace monitoring \
  --from-literal=alertmanager.yaml='
global:
  smtp_smarthost: smtp.gmail.com:587
  smtp_from: davidstone097@gmail.com
  smtp_auth_username: davidstone097@gmail.com
  smtp_auth_password: "<gmail-app-password>"
route:
  group_by: [alertname, namespace]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h
  receiver: email
receivers:
  - name: email
    email_configs:
      - to: davidstone097@gmail.com
        send_resolved: true
'
```

Use a [Gmail App Password](https://myaccount.google.com/apppasswords) (not your account password).

### 2. Grafana OIDC secret

First, create an OAuth2/OpenID application in Authentik:
- **Name**: grafana
- **Redirect URI**: `https://grafana.osose.xyz/login/generic_oauth`
- **Scopes**: openid, profile, email, groups
- Note the generated **Client ID** and **Client Secret**

Then create the secret:

```bash
kubectl create secret generic grafana-oidc-secret \
  --namespace monitoring \
  --from-literal=GF_AUTH_GENERIC_OAUTH_CLIENT_ID="<client-id>" \
  --from-literal=GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET="<client-secret>"
```

Also create a `grafana-admins` group in Authentik and assign it to the grafana provider to get Admin role in Grafana.

---

## Verification

1. **ArgoCD** — `monitoring` Application appears healthy and synced at `argo.osose.xyz`
2. **VMSingle** — pod running in `monitoring` namespace: `kubectl get pods -n monitoring`
3. **Grafana** — `https://grafana.osose.xyz` redirects to Authentik login; after auth, lands in Grafana
4. **Alertmanager** — port-forward and fire a test alert:
   ```bash
   kubectl port-forward svc/monitoring-alertmanager 9093:9093 -n monitoring
   # POST to localhost:9093/api/v1/alerts with a test payload
   ```
5. **Metrics** — in Grafana, add VictoriaMetrics datasource (`http://monitoring-victoria-metrics-single-server:8428`) and confirm node metrics appear
