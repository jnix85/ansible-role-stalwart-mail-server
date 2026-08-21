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

variable "vm_architecture" {
  description = "CPU architecture for every VM: \"x86_64\" (Bsv2/Intel) or \"arm64\" (Bpsv2/Ampere Altra). arm64 is cheaper at the same vCPU/RAM shape and the Stalwart role installs aarch64 builds, so it is a safe flip. Selects both the VM sizes and the Ubuntu image sku."
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.vm_architecture)
    error_message = "vm_architecture must be either \"x86_64\" or \"arm64\"."
  }
}

variable "mx_vm_size" {
  description = "Override the MX edge node size (postfix + rspamd). Leave null to take the 2 vCPU / 4 GiB default for var.vm_architecture."
  type        = string
  default     = null
}

variable "mail_vm_size" {
  description = "Override the Stalwart mailbox server size. Leave null to take the 2 vCPU / 8 GiB default for var.vm_architecture."
  type        = string
  default     = null
}

variable "os_disk_gb" {
  description = "OS disk size for every VM. 30 is the floor: the Ubuntu 24.04 marketplace image will not deploy onto a smaller disk. Mail data lives on the separate data disk, not here."
  type        = number
  default     = 30
}

variable "os_disk_type" {
  description = "OS disk SKU. StandardSSD_LRS is the cheapest tier with predictable latency; Premium_LRS buys IOPS, Standard_LRS saves a little more."
  type        = string
  default     = "StandardSSD_LRS"
}

variable "data_disk_gb" {
  description = "Managed data disk for the Stalwart mail store, attached to the mailbox VM only. Growing this later is online; shrinking is not."
  type        = number
  default     = 64
}

variable "data_disk_type" {
  description = "Mail store disk SKU. Bump to Premium_LRS if IMAP search or delivery latency becomes IO-bound."
  type        = string
  default     = "StandardSSD_LRS"
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
