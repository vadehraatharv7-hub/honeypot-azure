variable "admin_public_ip" {
  type        = string
  description = "Enter your current public IP address (e.g., 203.0.113.45)"

  #Enforcing valid IPv4 format so typos don't break NSG provisioning
  validation {
    condition     = can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$", var.admin_public_ip))
    error_message = "The admin_public_ip must be a valid IPv4 address without CIDR (e.g. 203.0.113.45)."
  }
}


variable "grafana_admin_password" {
  type        = string
  description = "Initial admin password for Grafana UI"
  sensitive   = true

  validation {
    condition     = length(var.grafana_admin_password) >= 8
    error_message = "The Grafana admin password must be at least 8 characters long."
  }
}