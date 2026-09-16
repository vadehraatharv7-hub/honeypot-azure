output "vm_public_ip" {
  value       = azurerm_public_ip.pip.ip_address
  description = "The public IP address of the honeypot VM."
}

output "monitoring_vm_public_ip" {
  value       = azurerm_public_ip.pip_monitoring.ip_address
  description = "Use this to access Grafana at :3000 and SSH at :22222"
}