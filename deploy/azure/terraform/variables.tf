variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus2"
}

variable "resource_group_name" {
  description = "Resource group to create."
  type        = string
  default     = "rg-mail"
}

variable "domain" {
  description = "Base DNS domain; VM keys become <name>.<domain> in the generated Ansible inventory (e.g. mx1.example.com)."
  type        = string
}

variable "admin_cidr" {
  description = "CIDR allowed to reach SSH (and the Stalwart admin UI on 443 if you tighten it later). Use your office/VPN range, not 0.0.0.0/0."
  type        = string
}

variable "admin_username" {
  description = "Admin login user on the VMs (Ansible connects as this user)."
  type        = string
  default     = "mailadmin"
}

variable "ssh_public_key" {
  description = "SSH public key content for the admin user."
  type        = string
}

variable "mx_vm_size" {
  description = "VM size for the MX edge nodes (postfix + rspamd)."
  type        = string
  default     = "Standard_B2s"
}

variable "mail_vm_size" {
  description = "VM size for the Stalwart mailbox server."
  type        = string
  default     = "Standard_B2ms"
}

variable "mail_os_disk_gb" {
  description = "OS disk size for the mailbox server (mail store lives on it under /opt/stalwart)."
  type        = number
  default     = 128
}

variable "vnet_cidr" {
  description = "Address space for the mail VNet."
  type        = string
  default     = "10.20.0.0/24"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    workload = "mail"
    managed  = "terraform"
  }
}
