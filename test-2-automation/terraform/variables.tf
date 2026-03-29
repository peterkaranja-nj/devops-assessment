# variables.tf — Input variables for the Azure infrastructure module.
# All sensitive values are marked sensitive = true and should be
# supplied via environment variables (TF_VAR_*) or a .tfvars file
# that is NOT committed to version control.

variable "location" {
  description = "Azure region to deploy resources into"
  type        = string
  default     = "uksouth"
}

variable "resource_group_name" {
  description = "Name of the Azure resource group"
  type        = string
  default     = "rg-sre-assessment"
}

variable "environment" {
  description = "Environment tag applied to all resources"
  type        = string
  default     = "dev"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

# ── Network ────────────────────────────────────────────────────────

variable "vnet_address_space" {
  description = "CIDR block for the Virtual Network"
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet (gateway VM lives here)"
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private subnet (app server lives here)"
  type        = string
  default     = "10.0.2.0/24"
}

# ── VMs ────────────────────────────────────────────────────────────

variable "vm_size" {
  description = "Azure VM SKU. Standard_B1s is the cheapest option suitable for testing."
  type        = string
  default     = "Standard_B1s"
}

variable "admin_username" {
  description = "Admin username for both VMs"
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key file used for VM authentication"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

# ── Security ───────────────────────────────────────────────────────

variable "allowed_ssh_ip" {
  description = <<EOT
Your public IP address in CIDR notation (e.g. "203.0.113.42/32").
SSH access to the gateway VM is restricted to this IP only.

Find your IP: curl https://ifconfig.me
NEVER set this to 0.0.0.0/0 in production.
EOT
  type        = string
  # No default — must be supplied by the operator.
  # Example: TF_VAR_allowed_ssh_ip="203.0.113.42/32"
}

# ── Tags ───────────────────────────────────────────────────────────

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
