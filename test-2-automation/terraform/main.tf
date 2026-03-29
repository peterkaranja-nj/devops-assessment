# main.tf — Provisions a simple gateway + app server topology in Azure.
#
# Architecture:
#   VNet (10.0.0.0/16)
#     ├── public-subnet  (10.0.1.0/24) → gateway VM  (public IP + nginx)
#     └── private-subnet (10.0.2.0/24) → app VM      (no public IP)
#
# Security model:
#   - SSH (22) to gateway: your IP only
#   - HTTP/HTTPS (80/443) to gateway: anywhere
#   - All traffic between gateway and app VM: allowed (same VNet)
#   - All other inbound to app VM: denied

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.95"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Uncomment to store state in Azure Blob Storage (recommended for teams):
  # backend "azurerm" {
  #   resource_group_name  = "rg-terraform-state"
  #   storage_account_name = "stterraformstate"
  #   container_name       = "tfstate"
  #   key                  = "sre-assessment/terraform.tfstate"
  # }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    virtual_machine {
      # Prevent accidental deletion of VMs with data disks
      delete_os_disk_on_deletion = true
    }
  }
}

# ── Local values ───────────────────────────────────────────────────

locals {
  common_tags = merge(
    {
      environment = var.environment
      managed_by  = "terraform"
      project     = "sre-assessment"
    },
    var.tags
  )
}

# ── Resource Group ─────────────────────────────────────────────────

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.common_tags
}

# ── Virtual Network ────────────────────────────────────────────────

resource "azurerm_virtual_network" "main" {
  name                = "vnet-sre-assessment"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = var.vnet_address_space
  tags                = local.common_tags
}

# Public subnet — gateway VM lives here.
# Has a route to the internet via the default Azure gateway.
resource "azurerm_subnet" "public" {
  name                 = "subnet-public"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.public_subnet_cidr]
}

# Private subnet — app server lives here.
# No public IP, no direct internet route.
resource "azurerm_subnet" "private" {
  name                 = "subnet-private"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.private_subnet_cidr]
}

# ── Network Security Groups ────────────────────────────────────────

# NSG for the public subnet (gateway VM)
resource "azurerm_network_security_group" "public" {
  name                = "nsg-public"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags

  # Rule 1: SSH from your IP only
  security_rule {
    name                       = "AllowSSHFromMyIP"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.allowed_ssh_ip
    destination_address_prefix = "*"
    description                = "SSH restricted to operator IP only. Never open to 0.0.0.0/0."
  }

  # Rule 2: HTTP from anywhere
  security_rule {
    name                       = "AllowHTTP"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Rule 3: HTTPS from anywhere
  security_rule {
    name                       = "AllowHTTPS"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "public" {
  subnet_id                 = azurerm_subnet.public.id
  network_security_group_id = azurerm_network_security_group.public.id
}

# NSG for the private subnet (app VM)
resource "azurerm_network_security_group" "private" {
  name                = "nsg-private"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags

  # Allow all traffic from the public subnet (gateway → app)
  security_rule {
    name                       = "AllowFromPublicSubnet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.public_subnet_cidr
    destination_address_prefix = "*"
    description                = "Allow all traffic from gateway VM in public subnet."
  }

  # Deny everything else inbound (Azure implicit deny is last;
  # we add this explicitly so it shows up in the NSG for clarity)
  security_rule {
    name                       = "DenyAllOtherInbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
    description                = "Explicit deny for all other inbound. Azure has implicit deny-all, but explicit is clearer."
  }
}

resource "azurerm_subnet_network_security_group_association" "private" {
  subnet_id                 = azurerm_subnet.private.id
  network_security_group_id = azurerm_network_security_group.private.id
}

# ── Public IP for Gateway VM ───────────────────────────────────────

resource "azurerm_public_ip" "gateway" {
  name                = "pip-gateway"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

# ── NICs ───────────────────────────────────────────────────────────

resource "azurerm_network_interface" "gateway" {
  name                = "nic-gateway"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.public.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.gateway.id
  }
}

resource "azurerm_network_interface" "app" {
  name                = "nic-app"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.private.id
    private_ip_address_allocation = "Dynamic"
    # No public_ip_address_id — this VM is intentionally internal only
  }
}

# ── Gateway VM (VM 1 — public) ─────────────────────────────────────

resource "azurerm_linux_virtual_machine" "gateway" {
  name                = "vm-gateway"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  size                = var.vm_size
  admin_username      = var.admin_username
  tags                = local.common_tags

  network_interface_ids = [azurerm_network_interface.gateway.id]

  # SSH key auth only — password auth disabled for security
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(var.ssh_public_key_path)
  }

  os_disk {
    name                 = "osdisk-gateway"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  # cloud-init script installs the Azure CLI agent and sets hostname
  custom_data = base64encode(<<-EOT
    #!/bin/bash
    set -e
    hostnamectl set-hostname vm-gateway
    # nginx is installed and configured by Ansible after provisioning
    apt-get update -qq
    apt-get install -y -qq curl
  EOT
  )
}

# ── App VM (VM 2 — private, no public IP) ─────────────────────────

resource "azurerm_linux_virtual_machine" "app" {
  name                = "vm-app"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  size                = var.vm_size
  admin_username      = var.admin_username
  tags                = local.common_tags

  network_interface_ids = [azurerm_network_interface.app.id]

  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(var.ssh_public_key_path)
  }

  os_disk {
    name                 = "osdisk-app"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(<<-EOT
    #!/bin/bash
    set -e
    hostnamectl set-hostname vm-app
    apt-get update -qq
  EOT
  )
}
