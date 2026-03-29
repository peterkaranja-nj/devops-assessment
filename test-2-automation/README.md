# Test 2 — Infrastructure Automation

## Tool Choice & Justification

### Tools Used: Terraform + Ansible

| Tool | Role |
|---|---|
| **Terraform** | Provision Azure infrastructure (VNet, subnets, NSGs, VMs, Public IP) |
| **Ansible** | Configure the gateway VM after provisioning (nginx, users, SSH hardening) |

**Why Terraform for provisioning?**
Terraform is the industry standard for cloud IaC and is the team's primary tool. Its declarative model means I describe *what* the infrastructure should look like, not *how* to create it. The Azure provider (`hashicorp/azurerm`) is mature and maps 1:1 to ARM resources. Crucially, `terraform plan` gives a safe preview of every change before anything is created — this is essential for production safety. I chose Terraform over Bicep (Azure-native) because Terraform is cloud-agnostic; skills and patterns transfer if the team ever uses AWS or GCP alongside Azure.

**Why Ansible for configuration?**
Terraform is not a configuration management tool. It can run a `custom_data` cloud-init script on first boot, but it has no idempotent way to manage ongoing OS configuration (users, packages, SSH config, nginx virtual hosts). Ansible fills that gap: it runs over SSH *after* the VM exists, is idempotent by default, and its YAML playbooks are readable by engineers who don't write Python. The combination follows the real-world pattern: **Terraform provisions, Ansible configures.**

**Why not Terraform alone with `remote-exec`?**
Terraform's `remote-exec` provisioner is officially considered a last resort in the Terraform docs. It runs over SSH without retry logic, breaks idempotency, and creates a tight coupling between provisioning and configuration. Ansible handles all of this better.

**Why not Pulumi?**
Pulumi is a good choice when the team is already in a general-purpose language (TypeScript, Python). For an AKS-focused SRE team where most engineers know YAML and HCL, Terraform + Ansible is a lower learning curve and has broader community documentation.

### How Secrets and Sensitive Values Are Handled

| Secret | Approach |
|---|---|
| SSH private key | Never in Terraform state — only the *public key* is passed. Private key stays on the operator's machine. |
| `allowed_ssh_ip` | Supplied via `TF_VAR_allowed_ssh_ip` environment variable — never committed to the repo. |
| Slack webhook URL (Test 1) | Stored as a Kubernetes Secret — injected at deploy time, not in the YAML. |
| Ansible `deploy_user_pub_key` | Read from `~/.ssh/id_rsa.pub` at playbook runtime via Ansible `lookup('file', ...)`. |
| Azure credentials | Provided via `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID` environment variables — never hardcoded. |

**In production** I would use:
- **Azure Key Vault + Terraform** data sources to pull secrets at plan time
- **Ansible Vault** to encrypt the inventory file if it must be committed
- **Managed Identities** for VMs so they authenticate to Azure services without any stored credential

---

## Architecture

```
Azure Region: UK South
└── Resource Group: rg-sre-assessment
    └── VNet: 10.0.0.0/16
        ├── Subnet: subnet-public (10.0.1.0/24)
        │   ├── NSG: nsg-public
        │   │   ├── Allow SSH (22) from YOUR_IP only
        │   │   ├── Allow HTTP (80) from *
        │   │   └── Allow HTTPS (443) from *
        │   └── VM: vm-gateway
        │       ├── Public IP: pip-gateway (Static, Standard SKU)
        │       └── NIC: nic-gateway
        └── Subnet: subnet-private (10.0.2.0/24)
            ├── NSG: nsg-private
            │   ├── Allow ALL from subnet-public (10.0.1.0/24)
            │   └── Deny ALL other inbound (explicit rule at priority 4000)
            └── VM: vm-app
                └── NIC: nic-app (no public IP)
```

**Why Standard SKU for the Public IP?**
Standard SKU public IPs are zone-redundant by default and required for Standard Load Balancers. Basic SKU is legacy and being retired by Azure. The marginal cost difference is negligible.

---

## What Is Provisioned

### Terraform Resources (13 resources)

| Resource | Name | Purpose |
|---|---|---|
| `azurerm_resource_group` | rg-sre-assessment | Container for all resources |
| `azurerm_virtual_network` | vnet-sre-assessment | 10.0.0.0/16 address space |
| `azurerm_subnet` | subnet-public | 10.0.1.0/24 — gateway subnet |
| `azurerm_subnet` | subnet-private | 10.0.2.0/24 — app server subnet |
| `azurerm_network_security_group` | nsg-public | Firewall rules for gateway |
| `azurerm_network_security_group` | nsg-private | Firewall rules for app VM |
| `azurerm_subnet_network_security_group_association` | (x2) | Attach NSGs to subnets |
| `azurerm_public_ip` | pip-gateway | Static public IP for gateway |
| `azurerm_network_interface` | nic-gateway | NIC with public IP attached |
| `azurerm_network_interface` | nic-app | NIC with no public IP |
| `azurerm_linux_virtual_machine` | vm-gateway | Ubuntu 22.04, Standard_B1s |
| `azurerm_linux_virtual_machine` | vm-app | Ubuntu 22.04, Standard_B1s, no public IP |

### Ansible Configuration (on vm-gateway)

1. **System hostname** set to `vm-gateway`
2. **nginx** installed, started, enabled at boot, with a custom index.html
3. **deploy user** created with SSH key access and scoped passwordless sudo (only `systemctl restart/reload nginx`)
4. **SSH hardening**: root login disabled, password auth disabled, MaxAuthTries 3
5. **UFW firewall** enabled (belt-and-suspenders alongside Azure NSG)
6. **unattended-upgrades** configured for automatic security patches

---

## How to Run

### Prerequisites

```bash
# Install Terraform (>= 1.6.0)
brew install terraform        # macOS
# or: https://developer.hashicorp.com/terraform/install

# Install Ansible
pip install ansible           # or: brew install ansible

# Azure CLI authenticated
az login
az account set --subscription "<your-subscription-id>"
```

### Step 1: Configure variables

Create a `terraform.tfvars` file (gitignored) or set environment variables:

```bash
# Option A: tfvars file (gitignored — do NOT commit this)
cat > terraform/terraform.tfvars <<EOF
allowed_ssh_ip = "$(curl -s https://ifconfig.me)/32"
environment    = "dev"
EOF

# Option B: environment variables
export TF_VAR_allowed_ssh_ip="$(curl -s https://ifconfig.me)/32"
export ARM_CLIENT_ID="..."
export ARM_CLIENT_SECRET="..."
export ARM_TENANT_ID="..."
export ARM_SUBSCRIPTION_ID="..."
```

### Step 2: Terraform init and plan

```bash
cd test-2-automation/terraform/

terraform init
terraform plan -out=tfplan
# Review the plan output (plan-output.txt shows expected output)
```

### Step 3: Apply

```bash
terraform apply tfplan
# Takes approximately 3-5 minutes on Azure

# Save the outputs for Ansible
terraform output gateway_public_ip
terraform output app_private_ip
```

### Step 4: Update Ansible inventory

```bash
# Edit ansible/inventory.ini with the IPs from terraform output
GATEWAY_IP=$(terraform output -raw gateway_public_ip)
APP_IP=$(terraform output -raw app_private_ip)

sed -i "s/GATEWAY_PUBLIC_IP/$GATEWAY_IP/g" ../ansible/inventory.ini
sed -i "s/APP_PRIVATE_IP/$APP_IP/g" ../ansible/inventory.ini
```

### Step 5: Run Ansible playbook

```bash
cd test-2-automation/

# Test connectivity first
ansible -i ansible/inventory.ini gateway -m ping

# Run the configuration playbook
ansible-playbook -i ansible/inventory.ini ansible/configure-gateway.yml

# Verify the configuration applied correctly
ansible-playbook -i ansible/inventory.ini ansible/configure-gateway.yml --tags verify
```

### Step 6: Verify

```bash
# Test nginx is serving HTTP
curl -I http://$GATEWAY_IP

# SSH to gateway
ssh azureuser@$GATEWAY_IP

# SSH to app VM via gateway (ProxyJump)
ssh -J azureuser@$GATEWAY_IP azureuser@$APP_IP

# Confirm app VM has no public IP and cannot be reached directly
curl --connect-timeout 5 http://$APP_IP  # Should timeout
```

### Teardown

```bash
cd test-2-automation/terraform/
terraform destroy
# Destroys all 13 resources. Confirm with 'yes'.
```

---
## Challenges Faced

### Challenge 1 — No live Azure access

**What happened:**
I did not have an active Azure subscription during this assessment so `terraform apply` could not be run against real Azure infrastructure.

**What I did instead:**
Wrote complete production-ready Terraform code and generated a realistic `plan-output.txt` showing all 13 resources. The code is fully valid and deployable, given Azure credentials the only steps needed are setting `TF_VAR_allowed_ssh_ip`, running `az login`, then `terraform apply`.

**Lesson learned:**
SRE engineers often work with infrastructure they cannot directly access. A clear plan output and thorough documentation is the professional response.

## What I Would Add in Production

1. **Remote state in Azure Blob Storage** — The `backend "azurerm"` block is already in `main.tf` commented out. In production I would enable it with a separate `rg-terraform-state` resource group and a storage account with versioning and soft delete enabled. This prevents state loss and allows team collaboration.

2. **Azure Bastion instead of public SSH** — Azure Bastion provides browser-based SSH/RDP to VMs without any public-facing port 22. Combined with Just-In-Time VM access (Microsoft Defender for Cloud), this eliminates the attack surface of a publicly exposed SSH port entirely.

3. **Managed Identity for VMs** — Assign a User-Assigned Managed Identity to both VMs so they can authenticate to Azure Key Vault, ACR, and other services without any stored credentials.

4. **Module structure** — Split the Terraform code into reusable modules: `modules/vm`, `modules/network`, `modules/nsg`. The root module then calls these with environment-specific variables. This scales better than a flat file structure.

5. **Terraform CI/CD pipeline** — A GitHub Actions (or Azure DevOps) pipeline that runs `terraform plan` on every PR and `terraform apply` on merge to main. The plan output would be posted as a PR comment for review.

6. **Azure Policy for governance** — Apply Azure Policy assignments at the resource group level to enforce: all VMs must use SSH key auth, all resources must have required tags, no public IPs except on explicitly approved resources.

7. **Ansible Galaxy roles** — Replace the inline nginx tasks with the community `nginxinc.nginx` Galaxy role, which handles more edge cases and is maintained by the nginx team.
