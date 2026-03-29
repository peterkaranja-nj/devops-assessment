# SRE / DevOps Assessment

> Submitted by: [Peter Karanja]
> GitHub Repo: [this repo]

---

## Overview

This repository contains my submission for all three tests in the SRE/DevOps intern assessment. Each test is self-contained in its own folder with a dedicated README.

---

## Repository Structure

```
.
├── README.md                          - This file
├── test-1-monitoring/
│   ├── README.md                      - Tool selection, setup guide, dashboard & alert docs
│   ├── config/
│   │   ├── promtail-daemonset.yaml    - Promtail DaemonSet + RBAC + ConfigMap
│   │   ├── loki-statefulset.yaml      - Loki StatefulSet + Service + PVC
│   │   ├── prometheus.yaml            - Prometheus Deployment + RBAC + Service + PVC
│   │   ├── kube-state-metrics.yaml    - kube-state-metrics + node-exporter DaemonSets
│   │   ├── grafana.yaml               - Grafana Deployment + datasource provisioning
│   │   └── alertmanager.yaml          - Alertmanager Deployment + Slack routing config
│   ├── dashboards/
│   │   ├── dashboard-1-cluster-health.json      - CPU, memory, pod counts
│   │   ├── dashboard-2-application-logs.json    - Loki log explorer with error trending
│   │   └── dashboard-3-deployment-health.json   - Deployment replica health (my choice)
│   ├── alerts/
│   │   └── alert-rules.yaml           - All Prometheus alert rules (3 required + bonus)
│   └── screenshots/                   - Screenshots of the running stack
│
├── test-2-automation/
│   ├── README.md                      - Tool choice, architecture, step-by-step guide
│   ├── terraform/
│   │   ├── main.tf                    - VNet, subnets, NSGs, VMs, Public IP
│   │   ├── variables.tf               - All input variables with descriptions
│   │   ├── outputs.tf                 - Useful outputs (IPs, SSH commands)
│   │   └── plan-output.txt            - terraform plan output (13 resources)
│   └── ansible/
│       ├── inventory.ini              - Inventory (populate IPs from terraform output)
│       └── configure-gateway.yml     - nginx, deploy user, SSH hardening, UFW
│
└── test-3-troubleshooting/
    └── scenario-1.md                  - Pods Running but app unreachable — full investigation
```

---

## Test Summaries

### Test 1 — Monitoring Stack

**Stack chosen:** Promtail + Loki + Prometheus + Grafana (PLG + P)

**Why:** Loki is 10x cheaper than Elasticsearch for Kubernetes log volumes. Prometheus is the de-facto Kubernetes metrics standard. Both feed into Grafana — a single UI for on-call engineers. No vendor lock-in.

**Delivered:**
- 6 Kubernetes manifest files covering the full stack
- 3 Grafana dashboards (Cluster Health, Application Logs, Deployment Health)
- 5 alert rules (3 required + 2 bonus: OOMKilled, HPAAtMaxReplicas)
- Alertmanager configured to route critical alerts to Slack with runbook links

**Azure note:** Loki config references Azure Blob Storage as the production object store. The assessment uses filesystem storage backed by an Azure Premium SSD PVC.

---

### Test 2 — Infrastructure Automation

**Stack chosen:** Terraform (provisioning) + Ansible (configuration)

**Why:** Terraform for declarative cloud infrastructure; Ansible for idempotent OS-level configuration. Together they follow the standard real-world pattern. Terraform's `remote-exec` was deliberately avoided (fragile, not idempotent).

**Delivered:**
- `main.tf` — VNet, 2 subnets, 2 NSGs, 2 VMs, 1 Public IP (13 resources total)
- `variables.tf` / `outputs.tf` — fully parameterised, no hardcoded values
- `plan-output.txt` — full `terraform plan` output
- Ansible playbook — nginx, deploy user, SSH hardening, UFW, unattended-upgrades

**Security:** SSH access restricted to operator IP only via NSG. No public IP on the app VM. SSH key auth only. Sensitive values supplied via `TF_VAR_*` environment variables — never committed.

---

### Test 3 — Troubleshooting

**Scenario:** Pods Running but external URL returns connection timeout.

**Approach:** Systematic layer-by-layer investigation — pod readiness -> Service endpoints -> Ingress controller -> Azure networking. Each layer has specific commands to confirm or rule it out before moving to the next.

**Key insight:** "Running" does not mean "Ready". A pod failing its readiness probe is excluded from Service endpoints even while showing Running in `kubectl get pods`. This is the most common root cause of this class of incident.

**Two Azure-specific causes documented:**
1. NSG rule on the AKS node pool subnet blocking inbound port 80/443
2. Azure Load Balancer health probe failing silently after a nodePort change

---

## No Secrets in This Repo

- All sensitive values (SSH IP, Azure credentials, Slack webhook) use placeholder strings or environment variables
- `terraform.tfvars` is gitignored
- Kubernetes Secrets use `stringData` with `REPLACE_WITH_*` placeholders
- SSH private keys are never referenced in any file

## Challenges & Honest Notes

### Environment
Completed on Windows 11 using WSL2 (Ubuntu) with a local `kind` cluster. All monitoring components were deployed and verified. Terraform targets Azure but was not applied live — a full `terraform plan` output is included.

### Key challenges

**Loki datasource (Test 1):** Grafana 12's test button reported failure even though `kubectl exec` confirmed the connection worked. Fixed by validating through Explore with a live LogQL query. Root cause was pods still starting when first tested.

**Grafana 12 UI changes (Test 1):** Advanced HTTP Settings section no longer exists in Grafana 12. Adapted by using Explore for validation instead.

**No Azure access (Test 2):** Terraform code is complete and production-ready. The plan-output.txt shows all 13 resources that would be created.

### What I would do differently with more time
- Set up a free Azure trial to run a live Terraform deployment
- Configure Alertmanager with a real Slack webhook for end-to-end alert testing
- Write a Makefile to automate the full setup with one command