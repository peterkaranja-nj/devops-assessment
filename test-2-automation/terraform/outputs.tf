# outputs.tf — Values surfaced after terraform apply.
# These are used directly by the Ansible inventory (ansible/inventory.ini).

output "gateway_public_ip" {
  description = "Public IP address of the gateway VM. Use this to SSH and for HTTP/HTTPS access."
  value       = azurerm_public_ip.gateway.ip_address
}

output "gateway_private_ip" {
  description = "Private IP of the gateway VM within the VNet"
  value       = azurerm_network_interface.gateway.private_ip_address
}

output "app_private_ip" {
  description = "Private IP of the app VM. Only reachable from the gateway VM via the private subnet."
  value       = azurerm_network_interface.app.private_ip_address
}

output "ssh_gateway_command" {
  description = "Convenience SSH command to connect to the gateway VM"
  value       = "ssh -i ~/.ssh/id_rsa ${var.admin_username}@${azurerm_public_ip.gateway.ip_address}"
}

output "ssh_app_via_gateway_command" {
  description = "SSH command to reach the private app VM via the gateway (SSH ProxyJump)"
  value       = "ssh -J ${var.admin_username}@${azurerm_public_ip.gateway.ip_address} ${var.admin_username}@${azurerm_network_interface.app.private_ip_address}"
}

output "resource_group_name" {
  description = "The resource group all resources are deployed into"
  value       = azurerm_resource_group.main.name
}

output "vnet_id" {
  description = "ID of the Virtual Network"
  value       = azurerm_virtual_network.main.id
}
