terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "azurerm" {
  features {}
}

locals {
  # The three mail hosts. Keys become VM names and, combined with
  # var.domain, the FQDNs Ansible manages them under.
  vms = {
    mx1 = {
      tier = "mx"
      size = var.mx_vm_size
    }
    mx2 = {
      tier = "mx"
      size = var.mx_vm_size
    }
    mail = {
      tier = "mailbox"
      size = var.mail_vm_size
    }
  }

  mx_names      = [for name, vm in local.vms : name if vm.tier == "mx"]
  mailbox_names = [for name, vm in local.vms : name if vm.tier == "mailbox"]
}

resource "azurerm_resource_group" "mail" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}
