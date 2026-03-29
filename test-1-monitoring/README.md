# Test 1 — Monitoring Stack

## Tool Selection & Justification

### Logging Stack: Promtail + Loki + Grafana

| Consideration | Decision |
|---|---|
| **Log shipper** | Promtail (DaemonSet) |
| **Log aggregator** | Loki |
| **Visualisation** | Grafana |

**Why Promtail over Fluentd/Fluentbit?**
Promtail is purpose-built to ship logs to Loki. It understands the CRI log format that AKS nodes use (containerd), and its Kubernetes service discovery configuration is minimal compared to Fluentd's plugin ecosystem. For a team already using Grafana, the operational surface stays in one place. Fluentd/ELK would require managing Elasticsearch — a significantly heavier operational burden with more complex scaling, index management, and licensing cost.

**Why Loki over Elasticsearch?**
Loki indexes only metadata labels (namespace, pod, container) rather than full-text indexing log content. This makes it dramatically cheaper to operate — roughly 10x less storage and compute than ELK for the same log volume. The trade-off is that full-text search is done at query time via LogQL regex rather than pre-indexed. For a Kubernetes cluster where most searches are "show me logs from pod X in namespace Y with level=error", Loki is the right fit. Elasticsearch excels when you need complex full-text search across unstructured data.

**Azure-specific note:** In production I would configure Loki's object storage to use **Azure Blob Storage** (config: `object_store: azure`) rather than the filesystem. This gives durable, cheap long-term log retention without managing a persistent volume. For this assessment I use filesystem storage backed by an Azure Premium SSD PVC since Blob Storage requires a storage account credential.

---

### Metrics Stack: Prometheus + Grafana (+ kube-state-metrics + node-exporter)

| Component | Role |
|---|---|
| **Prometheus** | Scrape and store time-series metrics |
| **kube-state-metrics** | Expose Kubernetes object state (pod phase, replica counts, etc.) |
| **node-exporter** | Expose per-node hardware metrics (CPU, memory, disk, network) |
| **Grafana** | Unified visualisation for both metrics and logs |

**Why Prometheus over Azure Monitor?**
Azure Monitor works well for Azure-native resources (VMs, databases, the AKS control plane). However it has two drawbacks for application metrics: (1) the query language (KQL) is different from PromQL, meaning the team would need to context-switch between two query languages; (2) custom application metrics require the Azure Monitor agent and specific SDK integrations. Prometheus has a much larger ecosystem of exporters and is the de-facto standard for Kubernetes. A pragmatic production setup would use **both** — Prometheus for Kubernetes/application metrics and Azure Monitor for Azure infrastructure — with both feeding into Grafana via their respective datasource plugins.

**Why not Datadog?**
Datadog is excellent but costs $15–23/host/month plus per-custom-metric charges. For a team just starting monitoring, the open-source PLG stack (Prometheus + Loki + Grafana) provides equivalent capability at infrastructure cost only. I would revisit Datadog if the team grows and values the managed service overhead reduction.

---

## Environment

This stack is designed for **AKS** but all configs work equally on a local `kind` or `minikube` cluster. For local testing:

```bash
# Start a local cluster
kind create cluster --name monitoring-test

# Or with minikube
minikube start --memory=4096 --cpus=2
```

The only AKS-specific elements are:
- `storageClassName: managed-premium` (replace with `standard` on minikube or `hostpath` on kind)
- Grafana `LoadBalancer` service (replace with `NodePort` locally or use `kubectl port-forward`)

---

## Setup Steps

### 1. Create the monitoring namespace

```bash
kubectl create namespace monitoring
```

### 2. Deploy the metrics stack

```bash
# kube-state-metrics + node-exporter
kubectl apply -f config/kube-state-metrics.yaml

# Prometheus (with alert rules ConfigMap)
kubectl apply -f alerts/alert-rules.yaml
kubectl apply -f config/prometheus.yaml

# Alertmanager (edit the Slack webhook URL in the Secret first)
kubectl apply -f config/alertmanager.yaml
```

### 3. Deploy the logging stack

```bash
# Loki
kubectl apply -f config/loki-statefulset.yaml

# Promtail DaemonSet
kubectl apply -f config/promtail-daemonset.yaml
```

### 4. Deploy Grafana

```bash
# Before applying, update the admin password in grafana.yaml
# (or inject it via kubectl create secret)
kubectl apply -f config/grafana.yaml
```

### 5. Import dashboards

Dashboards are provisioned automatically from the `grafana-dashboard-jsons` ConfigMap. To create that ConfigMap from the JSON files:

```bash
kubectl create configmap grafana-dashboard-jsons \
  --from-file=dashboards/dashboard-1-cluster-health.json \
  --from-file=dashboards/dashboard-2-application-logs.json \
  --from-file=dashboards/dashboard-3-deployment-health.json \
  -n monitoring
```

### 6. Access Grafana

```bash
# If using LoadBalancer on AKS:
kubectl get svc grafana -n monitoring

# If port-forwarding locally:
kubectl port-forward svc/grafana 3000:3000 -n monitoring
# Then open http://localhost:3000
```

### Verify everything is running

```bash
kubectl get pods -n monitoring

---

## Dashboard Descriptions

### Dashboard 1 — Cluster Health Overview

**Purpose:** Entry point for on-call engineers. Answers "is the cluster healthy right now?" at a glance.

**Panels:**
- **Cluster CPU Usage (Gauge)** — Average CPU utilisation across all nodes. Red at 85%, yellow at 70%. Threshold lines match the alert rules.
- **Cluster Memory Usage (Gauge)** — Average memory utilisation. Red at 90%, yellow at 75%.
- **Running Pods (Stat)** — Count of pods in Running phase. Used to spot mass evictions or scaling events.
- **Failed Pods (Stat)** — Count of pods in Failed phase. Background turns red at ≥1 — should normally be 0.
- **Pods in CrashLoopBackOff (Stat)** — Separate from Failed; counts pods stuck in restart loops.
- **CPU Usage per Node (Timeseries)** — Per-node CPU breakdown over time. Reveals hot nodes vs idle ones.
- **Memory Usage per Node (Timeseries)** — Per-node memory breakdown.
- **Pod Phases Over Time (Timeseries)** — Stacked line chart of pod phases. A spike in Pending can indicate a scheduler or node pool issue.

### Dashboard 2 — Application Logs

**Purpose:** Live log exploration with namespace and pod filtering. Replaces `kubectl logs` for multi-pod investigations.

**Panels:**
- **Pod Logs (Logs panel)** — Real-time log stream from selected pods. Filterable by namespace, pod name, and free-text keyword search.
- **Error & Warning Log Count Over Time (Timeseries)** — Bar chart of error/warning log events per interval. Shows error spikes correlated with deployment times.
- **Total Errors (1h) / Total Warnings (1h) / Total Log Volume (1h) (Stats)** — Quick sanity check numbers.

**Template variables:** Namespace (dropdown), Pod (multi-select dropdown), Search keyword (text box).

### Dashboard 3 — Deployment & Rollout Health *(My Choice)*

**Why I chose this:**
The Cluster Health dashboard shows node-level resources. The Logs dashboard shows what's happening inside pods. The gap in between is *Kubernetes object state* — specifically whether Deployments are healthy. The most dangerous on-call scenario isn't a slow CPU — it's a silent failed rollout where 0/3 replicas are available and no alerts have fired yet (because the deployment is new and hasn't crossed the `for: 5m` threshold). This dashboard gives engineers the "Deployment view" they need immediately after being paged.

**Panels:**
- **Deployments with Unavailable Replicas (Stat)** — Count of Deployments where desired ≠ available. Red at ≥1.
- **Pods CrashLoopBackOff / Pending / OOMKilled (Stats)** — Three separate counters for common failure modes.
- **Deployment Replicas: Desired vs Available (Timeseries)** — Overlaid lines for spec vs status replicas per Deployment. A gap between desired and available lines indicates a problem.
- **Unavailable Replicas by Deployment (Table)** — Sortable table. Highlights worst offenders in red.

---

## Alert Descriptions

### Alert 1 — PodCrashLoopBackOff (Required)
- **Trigger:** `kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"} == 1` for 5 minutes
- **Severity:** critical
- **Why 5 minutes:** Kubernetes itself backs off restarts exponentially, so a 5-minute window filters out transient failures (OOM on startup, brief dependency unavailability) while catching genuine application crashes.
- **Response:** Check `kubectl logs <pod> -n <namespace> --previous` for the crash reason.

### Alert 2 — NodeHighCPU (Required)
- **Trigger:** Node CPU > 80% for 3 minutes (measured via `node_cpu_seconds_total{mode="idle"}`)
- **Severity:** warning
- **Why 3 minutes:** Short bursts (compilation, batch jobs) are normal. 3 minutes of sustained high CPU indicates the node is saturated and latency is being impacted.
- **Response:** Identify the high-CPU pod with `kubectl top pods -A`. Consider scaling the application HPA or adding a node to the pool.

### Alert 3 — DeploymentReplicasMismatch *(My Choice)*
- **Trigger:** `kube_deployment_spec_replicas - kube_deployment_status_replicas_available > 0` for 5 minutes
- **Severity:** critical
- **Why I chose this:** CrashLoopBackOff covers a pod that keeps crashing. But there are failure modes that don't cause CrashLoopBackOff yet leave a Deployment with zero healthy replicas — a bad image that crashes immediately (single restart, no loop yet), pods stuck in Pending due to resource exhaustion, or PodDisruptionBudget misconfiguration blocking a drain. This alert catches all of them generically.
- **Response:** `kubectl rollout status deployment/<name> -n <namespace>` and `kubectl describe deployment <name> -n <namespace>`.

**Bonus alerts included (not required but added for production completeness):**
- `PodOOMKilled` — immediate warning when any container is killed by OOM
- `PodNotReady` — pod not in Ready state for 10+ minutes
- `NodeHighMemory` — node memory > 85%
- `NodeDiskPressure` — root filesystem > 80%
- `HPAAtMaxReplicas` — HPA at max for 15m (autoscaler can't keep up)

---

## Screenshots

>Screenshots are included in the `screenshots/` folder. The monitoring stack was set up on a local `kind` cluster for this assessment. All config files are production-ready for AKS.

Expected screenshots:
- `screenshots/01-grafana-datasources.png` — Prometheus and Loki connected as datasources
- `screenshots/02-dashboard-cluster-health.png` — Dashboard 1 showing CPU/memory gauges and pod counts
- `screenshots/03-prometheus-alerts.png` — Alert rules loaded and evaluated in Prometheus UI

---
## Challenges Faced

### Challenge 1 — Loki datasource showing "Unable to connect" in Grafana

**What happened:**
After installing Loki with Helm, Grafana returned "Unable to connect with Loki" even though the Helm install had reported success.

**What I investigated:**
Running `kubectl get pods -n monitoring | grep loki` showed pods were still in `ContainerCreating` state — images were still downloading. I confirmed with:
```bash
kubectl exec -n monitoring <grafana-pod> -- wget -qO- http://loki:3100/ready
```
This returned `ready`, proving the connection worked at the network level — the issue was timing.

**What fixed it:**
Waiting for both `loki-0` and `loki-promtail` to show `1/1 Running`, then retrying. The datasource connected immediately.

**Lesson learned:**
`helm install` success means Kubernetes accepted the config — not that pods are running. Always verify with `kubectl get pods -w`.

---

### Challenge 2 — Grafana 12 UI differences

**What happened:**
Documentation referenced an HTTP Method setting inside Advanced HTTP Settings. Grafana 12.4.2 does not have this section — it was removed in a UI overhaul.

**What fixed it:**
Validated the connection through Explore instead of the Save & test button. Running `{namespace="monitoring"}` in Explore returned live logs, which is more reliable proof of connectivity anyway.

**Lesson learned:**
Always check tool versions. The real test of a datasource is querying data from it, not a UI button.

---

### Challenge 3 — Correct Loki service URL

**What fixed it:**
Using the full Kubernetes DNS name format:
```
http://[service-name].[namespace].svc.cluster.local:[port]
```
So: `http://loki.monitoring.svc.cluster.local:3100` — works from any pod in any namespace.

---
## What I Would Improve in Production

1. **Loki with Azure Blob Storage** — Replace the filesystem PVC with `object_store: azure` pointing to a storage account. This gives durable, cheap long-term retention and removes the need for a large PVC.

2. **Prometheus Operator / kube-prometheus-stack** — In production I would deploy Prometheus via the `kube-prometheus-stack` Helm chart. It manages Prometheus, Alertmanager, kube-state-metrics, node-exporter, and Grafana together, and uses `ServiceMonitor` CRDs for cleaner per-application scrape configuration.

3. **Loki in microservices mode** — The single-binary Loki works up to ~100GB/day. Beyond that, split into separate `ingester`, `querier`, `distributor`, and `compactor` components for independent scaling.

4. **Azure Monitor integration** — Add the Azure Monitor datasource to Grafana to correlate AKS cluster metrics (from Azure Monitor) with application metrics (from Prometheus) on the same dashboards.

5. **Grafana authentication via Azure AD** — Configure Grafana's OAuth to use Azure Active Directory so engineers log in with their corporate credentials rather than a shared admin password.

6. **Log sampling for high-volume services** — Add Promtail `pipeline_stages` sampling rules for services that emit thousands of log lines per second, to control Loki ingestion cost.

