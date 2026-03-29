# Scenario 1 — Pods Running But Application is Unreachable

**Situation:** Pods show `Running` in `kubectl get pods`. External URL returns connection timeout. No recent code changes.

---

## 1. First 3 kubectl Commands

```bash
# Command 1 — Get a full picture of pod health and readiness
# Running ≠ Ready. A pod can be Running but failing its readiness probe,
# which means the Service will not route traffic to it.
kubectl get pods -n <namespace> -o wide

# Command 2 — Check the Service: does it have endpoints?
# If ENDPOINTS shows <none>, no pods matched the selector — traffic has nowhere to go.
kubectl get endpoints -n <namespace>

# Command 3 — Check the Ingress: does it have an address assigned?
# A missing ADDRESS means the ingress controller hasn't picked it up.
kubectl get ingress -n <namespace>
```

**Why these three first?** They cover the three most common failure layers in order — pod readiness, service routing, and ingress, without generating noise. They're also read-only and fast.

---

## 2. Which Kubernetes Resources to Check First and Why

**Recommended order: Service -> Ingress -> Deployment -> NSG**

### Service (check first)

The Service is the bridge between the Ingress and the pods. Even if the Ingress looks healthy, if the Service has no endpoints the request dies here.

```bash
kubectl describe svc <service-name> -n <namespace>
```

Look for:
- `Selector` — does it match the pod labels? A mismatched selector (e.g. `app: myapp` vs pod label `app: my-app`) gives zero endpoints.
- `Endpoints` — must list pod IPs. If empty, traffic cannot reach any pod.
- `Port` and `TargetPort` — TargetPort must match the port the container is actually listening on.

### Ingress (check second)

```bash
kubectl describe ingress <ingress-name> -n <namespace>
```

Look for:
- `Address` — the load balancer IP/hostname. If empty, the ingress controller hasn't reconciled it yet (or the controller itself is down).
- `Rules` — does the host and path match what you're trying to reach?
- `Backend` — does it point to the correct Service name and port?

Also check the ingress controller pods are healthy:

```bash
kubectl get pods -n ingress-nginx   # or kube-system, depending on the controller
kubectl logs -n ingress-nginx <controller-pod> --tail=50
```

### Deployment (check third)

Pods show `Running` but that doesn't mean they're passing their readiness probe. A container can be alive but returning 503 on `/health`.

```bash
kubectl describe pod <pod-name> -n <namespace>
# Look at: Readiness probe, Events, Container state
```

If the readiness probe is failing, the pod is excluded from the Service endpoints — you'll see 0 endpoints even with Running pods.

### NSG (check last — Azure-specific)

After verifying Kubernetes resources look correct, the issue may be external to Kubernetes entirely. The Azure NSG on the AKS node pool's subnet or the load balancer could be blocking traffic before it reaches the cluster.

---

## 3. How to Test at Each Layer

### Layer 1 — Pod level (is the app working at all?)

```bash
# Port-forward directly to a single pod, bypassing Service and Ingress entirely
kubectl port-forward pod/<pod-name> 8080:80 -n <namespace>
curl -v http://localhost:8080

# If this works - pod is healthy. Problem is in Service, Ingress, or Azure networking.
# If this fails - the application itself is broken despite showing Running.
```

### Layer 2 — Service level (is routing working within the cluster?)

```bash
# First confirm endpoints exist
kubectl get endpoints <service-name> -n <namespace>

# Then test via the Service ClusterIP from inside the cluster
kubectl run debug --image=curlimages/curl --rm -it --restart=Never -- \
  curl -v http://<service-name>.<namespace>.svc.cluster.local

# If this works - Service routing is fine. Problem is in Ingress or Azure networking.
# If this fails and endpoints exist - possible port mismatch or network policy blocking.
```

### Layer 3 — Ingress/network level (is external access working?)

```bash
# Check the external IP assigned to the LoadBalancer service
kubectl get svc -n ingress-nginx

# Curl the external IP directly with the Host header (bypasses DNS)
curl -v -H "Host: myapp.example.com" http://<external-ip>

# Check ingress controller logs for 404/502 responses to this host
kubectl logs -n ingress-nginx <controller-pod> | grep "myapp.example.com"
```
---

## 4. Two Azure-Specific Root Causes (When Kubernetes Looks Correct)

### Cause 1: NSG blocking inbound traffic to the AKS node pool

AKS creates a managed resource group (typically `MC_*`) containing the node pool's Virtual Machine Scale Set and its NIC/subnet. Azure NSG rules on this subnet (or on the load balancer's public IP) can block traffic before it reaches the ingress controller.

**How to check:**
```bash
az network nsg list --resource-group MC_<rg>_<cluster>_<region> -o table
az network nsg rule list --nsg-name <nsg-name> --resource-group MC_* -o table
```

Look for rules that deny port 80/443 inbound from the internet, or rules with lower priority numbers that match before your allow rules.

**Common cause:** A security team adds a blanket "DenyAll" rule at priority 100 without realising port 443 wasn't already allowed at a lower number.

---

### Cause 2: Azure Load Balancer not forwarding traffic / health probe failing

When AKS creates an external `LoadBalancer` Service, it provisions an Azure Load Balancer with a backend pool pointing to the node pool VMs. If the Load Balancer's health probe is failing (e.g. probing a node port that no longer exists after a config change), Azure silently marks all backends as unhealthy and drops all inbound traffic — even though the pods and the Service look healthy in Kubernetes.

**How to check:**
```bash
az network lb show --resource-group MC_* --name kubernetes -o json | \
  jq '.loadBalancingRules[] | {name: .name, frontendPort: .frontendPort, backendPort: .backendPort}'

az network lb probe show --resource-group MC_* --lb-name kubernetes --name <probe-name>
```

Check the health probe port: it must match an open `hostPort` or `nodePort` on the cluster nodes. If the nodePort was changed or deleted (e.g. during a Service update), the probe fails silently.

**Also check:** Azure's activity log and the AKS diagnostics in the Azure Portal → Monitor → Metrics for the load balancer `DipAvailability` metric (shows backend health probe status). A value of 0% means all backends are unhealthy from Azure's perspective.
