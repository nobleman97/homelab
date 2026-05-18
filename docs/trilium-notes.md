# Deploying Trilium Notes

## What It Is

Trilium Notes is a self-hosted, hierarchical note-taking application. All data — notes, attachments, revision history — is stored in a single SQLite database file on disk. There is no external database dependency. The persistent volume exists solely to keep that file alive across pod restarts.

---

## How It Works

Trilium runs as a single container (`ghcr.io/zadam/trilium`) with one stateful component: the SQLite database at `/home/node/trilium-data`. The TrueCharts chart mounts the persistent volume at `/home/node` and exposes the app on port `10156` (which maps to container port `8080`).

External access is handled by Cloudflare Tunnel. Cloudflared routes `notes.osose.xyz` to Traefik, which applies the Authentik `forwardAuth` middleware before passing the request to the Trilium service. Unauthenticated requests are redirected to `auth.osose.xyz`.

ArgoCD manages the deployment from a single source: the TrueCharts chart is vendored into this repo at `k8s/charts/trilium-notes`, and the values file is referenced with a relative path from within that chart directory. Both chart and values travel together in Git.

```
Internet → Cloudflare → cloudflared → Traefik → authentik-forward-auth middleware
                                                        ↓ unauthenticated
                                                 auth.osose.xyz login
                                                        ↓ authenticated
                                                 trilium-notes service :10156
```

---

## Prerequisites

- ArgoCD running in the cluster (`argocd` namespace) with access to this Git repo
- Cloudflared deployed and tunnel active
- Traefik running in the cluster
- Authentik deployed at `auth.osose.xyz` with the proxy outpost running in the `apps` namespace
- `longhorn-retain` storage class available
- A CNAME record for `notes.osose.xyz` in the Cloudflare dashboard pointing to the tunnel

---

## Step 1 — ArgoCD Application Manifest

Create `k8s/argo-apps/trilium-notes.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: trilium-notes
  namespace: argocd
spec:
  destination:
    namespace: apps
    server: https://kubernetes.default.svc
  project: default
  source:
    repoURL: https://github.com/nobleman97/homelab.git
    path: k8s/charts/trilium-notes
    targetRevision: HEAD
    helm:
      valueFiles:
        - ../values/trilium-notes/values.yaml
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

The `path` points ArgoCD at the vendored chart directory. The values file path is relative to the chart — `../values/trilium-notes/values.yaml` resolves to `k8s/charts/values/trilium-notes/values.yaml`.

Apply it:

```bash
kubectl apply -f k8s/argo-apps/trilium-notes.yaml
```

ArgoCD will render the chart with the values file and deploy into the `apps` namespace.

---

## Step 2 — Verify the Deployment

```bash
# Watch the pod come up
kubectl get pods -n apps -l app.kubernetes.io/name=trilium-notes -w

# Confirm the PVC was provisioned on the correct storage class
kubectl get pvc -n apps
```

The PVC should show `longhorn-retain` as the storage class. If it shows the cluster default instead, see [Troubleshooting](#troubleshooting).

---

## Step 3 — Add DNS in Cloudflare

In the Cloudflare dashboard, add a CNAME record:

| Field | Value |
|---|---|
| Name | `notes` |
| Target | your tunnel's `.cfargotunnel.com` address |
| Proxy status | Proxied |

This is the same pattern used for all other subdomains (`n8n`, `auth`, `argo`, etc.).

---

## Step 4 — Secure with Authentik and Traefik

Access is protected by Authentik's proxy outpost via Traefik's `forwardAuth` middleware — the same pattern used for n8n.

### 4a — Create a Provider in Authentik

Go to `https://auth.osose.xyz` → **Admin Interface** → **Applications → Providers → Create**

- **Type:** Proxy Provider
- **Name:** `trilium-notes`
- **Authorization flow:** `default-provider-authorization-implicit-consent`
- **Mode:** Forward auth (single application)
- **External host:** `https://notes.osose.xyz`

Save it.

### 4b — Create an Application in Authentik

**Applications → Applications → Create**

- **Name:** `Trilium Notes`
- **Slug:** `trilium-notes`
- **Provider:** select `trilium-notes` from the previous step
- **Launch URL:** `https://notes.osose.xyz`

Save it.

### 4c — Create the Outpost in Authentik

The outpost is the proxy component that actually enforces authentication. It runs as a separate deployment in the cluster, holds a persistent connection back to Authentik, and is what Traefik's `forwardAuth` middleware talks to when deciding whether a request is authenticated. Authentik generates a token for the outpost at creation time — that token is what allows the outpost pod to identify itself and receive its configuration.

**Applications → Outposts → Create**

- **Name:** `homelab-proxy`
- **Type:** Proxy
- **Integration:** leave blank (this is a manually deployed outpost, not one Authentik manages directly)
- **Applications:** select `Trilium Notes`

Save. Authentik will display the outpost token — **copy it now**, it is only shown once.

### 4d — Deploy the Outpost to Kubernetes

The outpost manifest is at `k8s/manifest/auth/authentik-outpost.yaml`. It defines the Secret, Deployment, and Service. Before applying, put the token from the previous step into the Secret:

```bash
kubectl create secret generic authentik-outpost-token \
  --from-literal=token=<paste-token-here> \
  -n apps
```

Then apply the Deployment and Service:

```bash
kubectl apply -f k8s/manifest/auth/authentik-outpost.yaml
```

Verify the pod comes up and connects:

```bash
kubectl get pods -n apps -l app=authentik-outpost
kubectl logs -n apps deployment/authentik-outpost
```

A successful connection shows a line like `connecting to Authentik` followed by no further errors. Back in the Authentik UI under **Applications → Outposts**, the outpost should show a green health indicator within a few seconds.

### 4e — Apply the ForwardAuth Middleware

The `authentik-forward-auth` Traefik Middleware is what tells Traefik to check every request against the outpost before forwarding it. It must exist in the same namespace as the IngressRoute (`apps`) before the IngressRoute is applied.

The manifest lives at `k8s/manifest/auth/forward-auth-middleware.yaml`:

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: authentik-forward-auth
  namespace: apps
spec:
  forwardAuth:
    address: http://authentik-outpost.apps.svc.cluster.local:9000/outpost.goauthentik.io/auth/traefik
    trustForwardHeader: true
    authResponseHeaders:
      - X-authentik-username
      - X-authentik-groups
      - X-authentik-email
      - X-authentik-name
      - X-authentik-uid
      - X-authentik-jwt
      - X-authentik-meta-jwks
      - X-authentik-meta-outpost
      - X-authentik-meta-provider
      - X-authentik-meta-app
      - X-authentik-meta-version
```

The `address` points to the outpost service deployed in step 4d. The `authResponseHeaders` are headers the outpost sets after a successful auth check — Traefik forwards them to the upstream app so it knows who the user is.

```bash
kubectl apply -f k8s/manifest/auth/forward-auth-middleware.yaml
```

This middleware is shared — any other app protected by Authentik in the `apps` namespace reuses it.

### 4f — Create the Traefik IngressRoute

With the middleware in place, create `k8s/manifest/trilium-authentik-auth.yaml`:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: trilium-notes
  namespace: apps
spec:
  entryPoints:
    - web
    - websecure
  routes:
    - match: Host(`notes.osose.xyz`)
      kind: Rule
      middlewares:
        - name: authentik-forward-auth
      services:
        - name: trilium-notes
          port: 10156
```

```bash
kubectl apply -f k8s/manifest/trilium-authentik-auth.yaml
```

### 4g — Route Cloudflared Through Traefik

Cloudflared must target Traefik rather than the Trilium service directly, so the IngressRoute and auth middleware actually run. Verify your Traefik service name first:

```bash
kubectl get svc -A | grep traefik
```

Then update `k8s/charts/values/cloudflared/values.yaml`:

```yaml
- hostname: notes.osose.xyz
  service: http://traefik.<namespace>.svc.cluster.local:80
```

Redeploy cloudflared:

```bash
helm upgrade --install cloudflared community-charts/cloudflared \
  -f k8s/charts/values/cloudflared/values.yaml \
  -n cloudflare
```

---

## Step 5 — Verify Auth

Visit `https://notes.osose.xyz` in an incognito window. You should be redirected to `https://auth.osose.xyz`. After logging in, you land on Trilium.

Trilium's own password screen will no longer appear — Authentik gates access before the request reaches the app.

---

## Values Reference

`k8s/charts/values/trilium-notes/values.yaml`:

```yaml
image:
  repository: ghcr.io/zadam/trilium
  pullPolicy: IfNotPresent
  tag: 0.63.7@sha256:a0b5a6a5fd7a64391ae6039bbcd5493151a77a1d5470ef5911923c64d0c232c0

service:
  main:
    ports:
      main:
        protocol: http
        targetPort: 8080
        port: 10156

persistence:
  config:
    enabled: true
    mountPath: /home/node
    storageClass: longhorn-retain
    accessMode: ReadWriteOnce
    size: 5Gi

securityContext:
  container:
    runAsNonRoot: false
    runAsUser: 0
    runAsGroup: 0
    fsGroup: 1000

ingress:
  main:
    enabled: false
```

Notable decisions:
- **`storageClass: longhorn-retain`** — matches all other stateful workloads in this cluster; PV survives accidental PVC deletion.
- **Port `10156`** — TrueCharts' convention for this chart; Traefik must target this port, not `8080`.
- **`runAsUser: 0`** — required by the upstream image; the container runs as root.
- **Ingress disabled** — access is via Cloudflare Tunnel through Traefik, consistent with all other apps in this cluster.

---

## Initial Approach Considered

The first chart evaluated was `nicholaswilde/trilium`. It is simpler — minimal dependencies, straightforward values — but it uses the `zadam/trilium` image from Docker Hub rather than GHCR, has less active maintenance, and its conventions differ from the TrueCharts charts already in use for other apps in this cluster (`authentik`, etc.).

TrueCharts was chosen because:
- It uses the same common chart library as the other TrueCharts apps, so values conventions are consistent.
- The image is pinned to a digest, not just a tag.
- The port convention (`10156`) is predictable and documented.

The tradeoff is that TrueCharts' common chart adds complexity to the values schema — fields like `service.main.ports.main` instead of a flat `service.port`. This is worth it for consistency with the rest of the cluster.

The chart is vendored into the repo (at `k8s/charts/trilium-notes`) rather than pulled remotely at sync time. This means ArgoCD uses a single `source` block pointing at the repo path, with the values file referenced by relative path — simpler than the multi-source pattern and keeps the exact chart version locked in Git.

---

## Troubleshooting

### Pod stuck in `Pending` — PVC not bound

**Symptom:**
```
kubectl get pods -n apps
NAME                             READY   STATUS    RESTARTS
trilium-notes-xxx                0/1     Pending   0
```

**Cause:** The PVC was created on the wrong storage class or Longhorn has no schedulable volume on the node.

**Diagnosis:**
```bash
kubectl describe pvc -n apps | grep -A5 "StorageClass\|Events"
kubectl get pvc -n apps -o wide
```

**Fix:** If the storage class is wrong, delete the PVC and redeploy. ArgoCD will recreate it with the values-specified class:
```bash
kubectl delete pvc -n apps <pvc-name>
# ArgoCD self-heal or manual sync will recreate it
```

---

### Cloudflared returns 502 for notes.osose.xyz

**Symptom:** The tunnel is up but the app returns a 502 or "Bad Gateway".

**Cause:** Cloudflared is targeting the Trilium service directly instead of Traefik, or the Traefik service name/namespace is wrong.

**Diagnosis:**
```bash
# Confirm Traefik service name and namespace
kubectl get svc -A | grep traefik

# Confirm Traefik can reach Trilium
kubectl get svc -n apps | grep trilium
```

The Trilium service should be named `trilium-notes` and expose port `10156`. Cloudflared should target the Traefik service, not `trilium-notes` directly.

---

### CSRF errors and broken sessions after adding Authentik

**Symptom:** After putting Trilium behind the Authentik proxy outpost, the pod logs show:

```
Trusted reverse proxy: false
Generated CSRF token <token> with secret undefined
```

Requests succeed initially but session handling is broken — CSRF validation fails intermittently and sessions don't persist correctly through the proxy.

**Cause:** Trilium's Express.js server defaults to `trustedReverseProxy=false` in `config.ini`. With this setting it ignores `X-Forwarded-*` headers, so it can't correctly identify client sessions when requests arrive through Traefik and the Authentik outpost. The `secret undefined` log is a symptom — Express can't bind the CSRF secret to a session it doesn't trust the origin of.

**Fix:** Set `trustedReverseProxy=uniquelocal` in Trilium's `config.ini`. The `uniquelocal` value is an Express shorthand that trusts any RFC-1918 private IP (10.x, 172.16.x, 192.168.x), which covers Traefik's pod IP.

This is enforced via an initContainer in the chart values so it survives pod restarts and redeployments. In `k8s/charts/values/trilium-notes/values.yaml`:

```yaml
persistence:
  config:
    ...
    targetSelector:
      main:
        main: {}
        patch-config:
          mountPath: /home/node

workload:
  main:
    podSpec:
      initContainers:
        patch-config:
          type: init
          enabled: true
          imageSelector: image
          command:
            - /bin/sh
            - -c
            - sed -i 's/trustedReverseProxy=false/trustedReverseProxy=uniquelocal/' /home/node/trilium-data/config.ini || true
```

The `targetSelector` is required because the TrueCharts common chart only auto-mounts persistence volumes to the primary container. The initContainer uses the same Trilium image (`imageSelector: image`) so no additional image pull is needed. The `|| true` prevents the initContainer from failing on the very first boot before Trilium has written `config.ini` — on that first start Trilium creates the file with defaults, and on the next restart the initContainer patches it.

---

### Authentik redirects loop or return 404 after login

**Symptom:** After authenticating at `auth.osose.xyz`, the browser loops back to the login page or gets a 404.

**Cause:** The Authentik provider's **External host** does not exactly match the hostname cloudflared is routing. They must be identical.

**Fix:** In the Authentik admin UI, edit the `trilium-notes` provider and confirm **External host** is set to `https://notes.osose.xyz`. No trailing slash.

---

### ArgoCD sync fails — values file not found

**Symptom:** ArgoCD shows `Error` with a message like `no such file or directory` or `failed to load values file`.

**Cause:** The `valueFiles` path is relative to the chart directory (`path: k8s/charts/trilium-notes`), not the repo root. A path like `k8s/charts/values/trilium-notes/values.yaml` will fail — it must be the relative form.

**Fix:** Ensure the Application manifest uses:
```yaml
helm:
  valueFiles:
    - ../values/trilium-notes/values.yaml
```
This resolves to `k8s/charts/values/trilium-notes/values.yaml` from the repo root.

---

## References

- [TrueCharts trilium-notes on ArtifactHub](https://staging.artifacthub.io/packages/helm/truecharts/trilium-notes)
- [Trilium GitHub](https://github.com/zadam/trilium)
- [ArgoCD Multiple Sources](https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/)
- [n8n Authentik auth manifest](../k8s/manifest/n8n-authentik-auth.yaml)
- [Cloudflared values](../k8s/charts/values/cloudflared/values.yaml)
- [Trilium values](../k8s/charts/values/trilium-notes/values.yaml)
