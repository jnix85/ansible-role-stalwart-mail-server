# Static public IPs: mail servers need stable addresses for DNS/PTR
# and sender reputation.
resource "azurerm_public_ip" "vm" {
  for_each = local.vms

  name                = "pip-mail-${each.key}"
  location            = azurerm_resource_group.mail.location
  resource_group_name = azurerm_resource_group.mail.name
  allocation_method   = "Static"
  sku                 = "Standard"
  # Label makes Azure give the IP a resolvable name, a prerequisite for
  # setting a PTR (reverse_fqdn) later.
  domain_name_label = "mail-${each.key}-${substr(md5(azurerm_resource_group.mail.id), 0, 8)}"
  tags              = var.tags
}

resource "azurerm_network_interface" "vm" {
  for_each = local.vms

  name                = "nic-mail-${each.key}"
  location            = azurerm_resource_group.mail.location
  resource_group_name = azurerm_resource_group.mail.name
  tags                = var.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.mail.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm[each.key].id
  }
}

resource "azurerm_linux_virtual_machine" "vm" {
  for_each = local.vms

  name                = "vm-mail-${each.key}"
  computer_name       = each.key
  location            = azurerm_resource_group.mail.location
  resource_group_name = azurerm_resource_group.mail.name
  size                = each.value.size
  admin_username      = var.admin_username
  tags                = merge(var.tags, { tier = each.value.tier })

  network_interface_ids = [azurerm_network_interface.vm[each.key].id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  # Minimum viable OS disk on both tiers — the mail store is a separate
  # managed disk (see disks.tf), so nothing here needs to grow.
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = local.image_sku
    version   = "latest"
  }
}
