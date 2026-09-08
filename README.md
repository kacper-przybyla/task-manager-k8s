# task-manager-k8s

A Kubernetes portfolio project with two complete, working deployment paths for the same web application: hand-written raw manifests and a parameterized Helm chart, the latter backed by a full Prometheus/Loki observability stack.

## Authorship and scope

Everything in this repository — the Kubernetes manifests, the Helm chart and all its templates, the CI/CD pipeline, and the deployment tooling — is my work (Kacper). The application images (`ghcr.io/kacper-przybyla/task-manager-backend`, `task-manager-frontend`, `task-manager-proxy`) were generated and serve as a realistic deployment target. Writing the application code is not part of this portfolio's scope.

## Repository layout

```
task-manager-k8s/
├── kubernetes/ # Deployment path 1: raw manifests
│ ├── namespace.yaml
│ ├── cert-manager/
│ │ └── issuer.yaml
│ └── app/
│ ├── postgres-statefulset.yaml
│ ├── postgres-service.yaml
│ ├── postgres-secret.example.yaml
│ ├── backend-deployment.yaml
│ ├── backend-service.yaml
│ ├── backend-configmap.yaml
│ ├── backend-secret.example.yaml
│ ├── frontend-deployment.yaml
│ ├── frontend-service.yaml
│ ├── proxy-deployment.yaml
│ ├── proxy-service.yaml
│ ├── proxy-configmap.yaml
│ ├── ingress-backend.yaml
│ └── ingress-frontend.yaml
├── helm/task-manager/ # Deployment path 2: Helm chart
│ ├── Chart.yaml # version: 0.1.1, appVersion: 1.3.1
│ ├── values.yaml
│ ├── values-dev.yaml
│ ├── values-prod.yaml
│ └── templates/
│ ├── _helpers.tpl
│ ├── postgres-statefulset.yaml
│ ├── postgres-service.yaml
│ ├── backend-deployment.yaml
│ ├── backend-service.yaml
│ ├── backend-configmap.yaml
│ ├── backend-servicemonitor.yaml
│ ├── backend-prometheus-rule.yaml
│ ├── frontend-deployment.yaml
│ ├── frontend-service.yaml
│ ├── ingress-backend.yaml
│ ├── ingress-frontend.yaml
│ ├── pre-upgrade-hook.yaml
│ ├── backend-health-test.yaml
│ └── NOTES.txt
└── monitoring/ # Observability stack (path 2 only)
  ├── kube-prometheus-stack-values.yaml
  ├── postgres-exporter-values.yaml
  ├── loki-values.yaml
  ├── alloy-values.yaml
  └── dashboards/
    └── task-manager.json
```


## Why two deployment paths

The `kubernetes/` directory and the `helm/task-manager/` chart deploy the same application. This is intentional, not duplication.

Writing raw manifests requires understanding every field explicitly: what `clusterIP: None` does to DNS, why a StatefulSet needs `volumeClaimTemplates` instead of a plain volume, what annotation scope means for an Ingress resource. There is no abstraction layer to fill in the gaps.

The Helm chart then shows how to take those working manifests and make them environment-aware: what belongs in `values.yaml`, how overlay files compose, what to protect with lifecycle hooks, and how to structure templates so that a name change to the Helm release propagates correctly through all resources. The observability stack (`monitoring/`) builds on top of the Helm chart path specifically — the raw-manifest path has no `ServiceMonitor` or `PrometheusRule` equivalent.

## Architecture

### Workloads

The raw manifests deploy four workloads into the `app` namespace:

| Workload | Kind | Replicas | Image |
|---|---|---|---|
| postgres | StatefulSet | 1 | `postgres:14` |
| backend | Deployment | 2 | `ghcr.io/kacper-przybyla/task-manager-backend:latest` |
| frontend | Deployment | 2 | `ghcr.io/kacper-przybyla/task-manager-frontend:latest` |
| proxy | Deployment | 1 | `ghcr.io/kacper-przybyla/task-manager-proxy:latest` |

The Helm chart deploys three workloads into the `taskmngr` namespace. The proxy is absent — the chart routes all traffic through the Ingress controller directly:

| Workload | Kind | Default replicas |
|---|---|---|
| postgres | StatefulSet | 1 |
| backend | Deployment | 2 |
| frontend | Deployment | 2 |

### Why Postgres is a StatefulSet with a headless Service

Postgres requires stable, predictable storage and network identity across restarts.

A StatefulSet provides a `volumeClaimTemplates` block, which provisions a dedicated PVC per pod (`ReadWriteOnce`, 1 Gi). The data volume follows the pod through rescheduling — a plain Deployment with a `volumes:` reference to a PVC would not guarantee the same pod lands on the same volume.

The postgres Service sets `clusterIP: None` (headless). The StatefulSet controller requires a headless Service as its `serviceName` in order to create per-pod DNS records of the form `postgres-0.postgres.<namespace>.svc.cluster.local`. With `clusterIP: None`, the Service does not proxy or load-balance; it resolves directly to the pod IP. This is correct for a single-replica database where traffic must go to the specific pod, not an arbitrary endpoint chosen by kube-proxy. It also means that if the pod goes away entirely, the hostname fails DNS resolution outright rather than returning a stale or refused connection — the failure mode we deliberately reproduced to verify metric/log correlation (see Monitoring below).

### Why backend and frontend are Deployments with ClusterIP Services

Backend and frontend are stateless. A Deployment allows rolling updates and places no constraints on pod scheduling. `ClusterIP` is the appropriate Service type for workloads that are not accessed directly from outside the cluster — the Ingress controller handles inbound traffic and forwards to these Services internally.

The backend Deployment also includes an init container (`pg-ready-init`) that polls `pg_isready -h postgres -p 5432` in a loop until Postgres accepts connections. This prevents the backend pod from starting before the database is ready.

### Proxy (raw manifests only)

The raw manifests include an nginx reverse proxy Deployment that routes `/api/` requests to `backend-service:8000` and all other requests to `frontend-service:80`. Its nginx configuration lives in a ConfigMap (`proxy-config`) that is mounted into the container. The proxy Service is type `NodePort`, which exposes it on a port assigned by Kubernetes on every node, providing access independent of the Ingress controller.

The Helm chart does not include this proxy.

### Ingress and TLS

Both deployment paths use two separate Ingress resources rather than one. The backend Ingress matches the path `/api(/|$)(.*)` with `pathType: ImplementationSpecific` and carries this annotation:

```yaml
nginx.ingress.kubernetes.io/rewrite-target: /$2
```

This strips the `/api` prefix before forwarding to the backend. The backend's own routes do not include `/api`. The frontend Ingress uses a simple `Prefix` match on `/` with no rewrite.

Ingress annotations apply to every rule within the same resource. Putting both routes in a single Ingress would apply `rewrite-target: /$2` to the frontend path as well, which is incorrect. Two resources give each route independent annotation control.

TLS is handled by cert-manager. Both Ingress resources carry:

```yaml
cert-manager.io/cluster-issuer: issuer
```

cert-manager sees this annotation, requests a certificate from the named ClusterIssuer, and stores the resulting certificate and key in the Secret named `taskmanager-tls`. The nginx Ingress controller then serves HTTPS using that Secret.

The `issuer` ClusterIssuer (`kubernetes/cert-manager/issuer.yaml`) uses `selfSigned: {}`. Self-signed certificates are appropriate for a local dev cluster. A production setup would replace this with an ACME (Let's Encrypt) or internal CA configuration.

## Prerequisites

Both deployment paths require:

- A running Kubernetes cluster. The commands below assume [minikube](https://minikube.sigs.k8s.io/).
- The nginx Ingress controller:
```bash
  minikube addons enable ingress
```
- cert-manager (v1.x):
```bash
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
```
- A `/etc/hosts` entry so `taskmanager.local` resolves to the minikube node:
```bash
  echo "$(minikube ip) taskmanager.local" | sudo tee -a /etc/hosts
```

## Required Secrets

Both paths require two Secrets to exist in the target namespace before anything will work. No Secret values appear in any committed file; only the Secret names are referenced.

**For the raw manifests** (namespace `app`):

```bash
kubectl create secret generic postgres-secret \
  --from-literal=POSTGRES_USER=<user> \
  --from-literal=POSTGRES_PASSWORD=<password> \
  --from-literal=POSTGRES_DB=<database-name> \
  -n app

kubectl create secret generic backend-secret \
  --from-literal=DATABASE_URL="postgresql+psycopg2://<user>:<password>@postgres:5432/<database-name>" \
  -n app
```

**For the Helm chart** (namespace `taskmngr`):

```bash
kubectl create secret generic postgres-secret \
  --from-literal=POSTGRES_USER=<user> \
  --from-literal=POSTGRES_PASSWORD=<password> \
  --from-literal=POSTGRES_DB=<database-name> \
  -n taskmngr

kubectl create secret generic backend-secret \
  --from-literal=DATABASE_URL="postgresql+psycopg2://<user>:<password>@taskmngr-postgres:5432/<database-name>" \
  -n taskmngr
```

In the Helm chart the postgres Service is named `{{ .Release.Name }}-postgres`. With the release name `taskmngr` (used throughout this README), the hostname is `taskmngr-postgres`.

## Deployment path 1: raw Kubernetes manifests

```bash
# 1. Create the namespace
kubectl apply -f kubernetes/namespace.yaml

# 2. Apply the ClusterIssuer
kubectl apply -f kubernetes/cert-manager/issuer.yaml

# 3. Create Secrets (see Required Secrets above)

# 4. Apply all app manifests, skipping the .example files
find kubernetes/app -name "*.yaml" ! -name "*secret*" | xargs kubectl apply -f

# 5. Verify
kubectl get all -n app
kubectl get ingress -n app
```

The app is available at `https://taskmanager.local`. The TLS certificate is self-signed; expect a browser warning.

The proxy is also reachable directly via its NodePort:

```bash
kubectl get svc proxy -n app        # note the NodePort value
curl http://$(minikube ip):<nodePort>/
```

This path has no observability stack — Prometheus/Loki are wired into the Helm chart's own `ServiceMonitor`/`PrometheusRule` templates, which the raw manifests don't have an equivalent for.

## Deployment path 2: Helm chart + observability stack

### What the chart adds over the raw manifests

**Per-environment values overlays**

`values.yaml` provides production-like defaults. Two overlay files override only what changes per environment:

- `values-dev.yaml`: reduces backend CPU and memory requests, sets frontend to 1 replica, disables TLS (`ingress.tls.enabled: false`).
- `values-prod.yaml`: pins both image tags to a specific commit SHA (`8c4260c`) and sets both backend and frontend to 2 replicas.

The overlays are applied with `-f` and merge on top of the base `values.yaml`.

**Pre-upgrade hook**

`pre-upgrade-hook.yaml` is a `batch/v1 Job` with the annotation `helm.sh/hook: pre-upgrade`. Before any `helm upgrade` proceeds, Helm runs this Job, which calls `pg_isready` against the postgres Service. With `backoffLimit: 5`, it retries up to five times. If postgres is unreachable, the Job fails and the upgrade is blocked — preventing new application pods from starting against an unavailable database.

The hook is cleaned up automatically (`hook-delete-policy: before-hook-creation,hook-succeeded`).

**Test hook**

`backend-health-test.yaml` is a Pod with the annotation `helm.sh/hook: test`. Running `helm test taskmngr` starts this Pod, which uses `curl` to call the backend's `/health` endpoint from inside the cluster. A zero exit code confirms the backend is reachable after installation.

**External-secrets pattern**

No secret values appear anywhere in the chart. `values.yaml` contains only the names of the Secrets:

```yaml
postgres:
  secretName: postgres-secret

backend:
  secretName: backend-secret
```

The templates reference these names. The Secrets themselves must be created externally before installation, as shown in the Required Secrets section above. The same pattern governs every credential in `monitoring/` below — Grafana's admin login, the Postgres exporter's connection string — none of them are committed in plaintext.

### What the observability stack adds

- **kube-prometheus-stack** (Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics) via the community Helm chart, values in `monitoring/kube-prometheus-stack-values.yaml`. Grafana's admin credentials come from an externally-created Secret (`grafana-admin-secret`).
- **Custom scraping of the application** via a `ServiceMonitor` in the app chart itself (`helm/task-manager/templates/backend-servicemonitor.yaml`) — the backend exposes `/metrics` through `prometheus-fastapi-instrumentator`.
- **PostgreSQL metrics** via `prometheus-postgres-exporter`, connecting as a dedicated `monitoring_user` role (`pg_monitor` grant, read-only) rather than the application's own read/write credentials.
- **Alerting**: two `PrometheusRule` alerts (`backend-prometheus-rule.yaml`: `PodDown`, `HighMemoryUsage`) evaluated by Prometheus and routed through Alertmanager, with a dedicated child route for `severity: critical` alerts. No real Slack workspace is wired in for this portfolio — routing and grouping were verified directly in Alertmanager's own UI.
- **Log aggregation** via Loki (`monitoring/loki-values.yaml`, single-binary mode, filesystem storage) and Grafana Alloy (`monitoring/alloy-values.yaml`) as the collector — Alloy rather than Promtail, which is now in Grafana's maintenance mode. Loki runs with multi-tenancy enabled; both Alloy's writes and Grafana's reads use the tenant `fake` via the `X-Scope-OrgID` header.
- **A custom Grafana dashboard** (`monitoring/dashboards/task-manager.json`) covering backend pod status, CPU, memory, Postgres status/connections/size, pod restarts, and live backend logs — provisioned as code via Helm values (`grafana.dashboardProviders` + `--set-file`). Mounted via `subPath`, so it does not auto-update from a ConfigMap edit; changes require re-running the `--set-file` upgrade.
- **Verified metric-log correlation**: the database was deliberately taken offline (`kubectl scale statefulset taskmngr-postgres --replicas=0`) with the dashboard open, confirming `pg_up`/`PostgreSQL Status` drop and backend DNS-resolution error logs appear in the same window.

### Install order matters

The app chart's `ServiceMonitor` and `PrometheusRule` objects depend on CRDs that `kube-prometheus-stack` installs. **The observability stack must go in before the app chart** — installing the app chart first fails outright (`no matches for kind "ServiceMonitor"`), by design: this is a hard dependency, not a feature that silently degrades. The sequence below reflects that.

### Full install sequence

```bash
# 1. Cluster-level prerequisites (see Prerequisites above), then:
kubectl apply -f kubernetes/cert-manager/issuer.yaml
kubectl create namespace taskmngr
kubectl create namespace monitoring

# 2. Application Secrets (see Required Secrets above)
kubectl create secret generic postgres-secret \
  --from-literal=POSTGRES_USER=<user> \
  --from-literal=POSTGRES_PASSWORD=<password> \
  --from-literal=POSTGRES_DB=<database-name> \
  -n taskmngr

kubectl create secret generic backend-secret \
  --from-literal=DATABASE_URL="postgresql+psycopg2://<user>:<password>@taskmngr-postgres:5432/<database-name>" \
  -n taskmngr

# 3. Grafana's admin credentials
kubectl create secret generic grafana-admin-secret \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='<pick-something>' \
  -n monitoring

# 4. Add chart repos
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# 5. Install the observability stack — MUST come before step 8
helm install monitoring prometheus-community/kube-prometheus-stack \
  --version 88.5.0 \
  -n monitoring \
  -f monitoring/kube-prometheus-stack-values.yaml \
  --set-file grafana.dashboards.default.task-manager-overview.json=monitoring/dashboards/task-manager.json

helm install loki grafana/loki -n monitoring -f monitoring/loki-values.yaml
helm install alloy grafana/alloy -n monitoring -f monitoring/alloy-values.yaml

# 6. Install the app chart first (so Postgres exists before step 7 needs it)
helm install taskmngr ./helm/task-manager --namespace taskmngr
# Or with an overlay:
#   -f helm/task-manager/values-dev.yaml   (no TLS, lower resources, 1 frontend replica)
#   -f helm/task-manager/values-prod.yaml  (pinned image tags, 2 replicas each)

# 7. Create the dedicated read-only monitoring role in Postgres
kubectl exec -it taskmngr-postgres-0 -n taskmngr -- psql -U postgres -d <database-name>
   CREATE USER monitoring_user WITH PASSWORD '<password>';
   GRANT pg_monitor TO monitoring_user;
   GRANT CONNECT ON DATABASE <database-name> TO monitoring_user;
   \q

# 8. Create the exporter's connection secret and install it
kubectl create secret generic postgres-exporter-secret \
  --from-literal=DATA_SOURCE_NAME="postgresql://monitoring_user:<password>@taskmngr-postgres.taskmngr.svc.cluster.local:5432/<database-name>?sslmode=disable" \
  -n monitoring

helm install postgres-exporter prometheus-community/prometheus-postgres-exporter \
  -n monitoring -f monitoring/postgres-exporter-values.yaml

# 9. Verify
kubectl get all -n taskmngr
kubectl get all -n monitoring
helm status taskmngr --namespace taskmngr
helm test taskmngr --namespace taskmngr
```

With the default or prod values, TLS is enabled and the app is available at `https://taskmanager.local`. With the dev overlay, TLS is disabled — use `http://taskmanager.local`.

**Upgrading** the app chart (the pre-upgrade hook runs automatically before new pods are scheduled):
```bash
helm upgrade taskmngr ./helm/task-manager --namespace taskmngr \
  -f helm/task-manager/values-prod.yaml
```

### Access

```bash
kubectl port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 -n monitoring    # Prometheus
kubectl port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093 -n monitoring  # Alertmanager
kubectl port-forward svc/monitoring-grafana 3001:80 -n monitoring                          # Grafana
```
Logs are queried through Grafana's Explore view (Loki datasource) or directly on the dashboard's "Backend logs" panel — there is no separate Loki UI to expose.

### Status

Metrics, alerting, dashboard-as-code, and log aggregation are complete and verified end-to-end, including a deliberate outage used to confirm metric/log correlation.