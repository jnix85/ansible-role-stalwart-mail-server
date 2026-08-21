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
  # Cheapest B-series sizes that hit the required shapes (2 vCPU / 4 GiB for
  # MX, 2 vCPU / 8 GiB for the mailbox). Keyed by architecture so flipping
  # var.vm_architecture swaps sizes and image together:
  #   x86_64 -> Bsv2  (Intel):        B2ls_v2 4 GiB, B2s_v2 8 GiB
  #   arm64  -> Bpsv2 (Ampere Altra): B2pls_v2 4 GiB, B2ps_v2 8 GiB
  # arm64 lists cheaper than x86_64 at identical shapes and the Stalwart role
  # installs aarch64 builds, so arm64 is the no-compromise cost lever here.
  vm_sizes = {
    x86_64 = {
      mx      = "Standard_B2ls_v2"
      mailbox = "Standard_B2s_v2"
    }
    arm64 = {
      mx      = "Standard_B2pls_v2"
      mailbox = "Standard_B2ps_v2"
    }
  }

  # Canonical ships arm64 under a separate sku of the same offer.
  image_skus = {
    x86_64 = "server"
    arm64  = "server-arm64"
  }

  image_sku = local.image_skus[var.vm_architecture]

  # Explicit size vars stay as escape hatches; null means "track architecture".
  mx_size      = coalesce(var.mx_vm_size, local.vm_sizes[var.vm_architecture].mx)
  mailbox_size = coalesce(var.mail_vm_size, local.vm_sizes[var.vm_architecture].mailbox)

  # Pinned so the attachment, the output and the Ansible inventory can never
  # disagree about where the mail store shows up.
  data_disk_lun = 0

  # The three mail hosts. Keys become VM names and, combined with
  # var.domain, the FQDNs Ansible manages them under.
  vms = {
    mx1 = {
      tier = "mx"
      size = local.mx_size
    }
    mx2 = {
      tier = "mx"
      size = local.mx_size
    }
    mail = {
      tier = "mailbox"
      size = local.mailbox_size
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
