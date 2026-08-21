# Mail store lives on its own managed disk so the mailbox VM can be
# rebuilt, resized or re-imaged without touching the messages, and so the
# store can grow independently of the (deliberately minimal) OS disk.
# for_each over mailbox_names keeps this off the MX tier, which is stateless.
resource "azurerm_managed_disk" "data" {
  for_each = toset(local.mailbox_names)

  name                 = "disk-mail-${each.key}-data"
  location             = azurerm_resource_group.mail.location
  resource_group_name  = azurerm_resource_group.mail.name
  storage_account_type = var.data_disk_type
  create_option        = "Empty"
  disk_size_gb         = var.data_disk_gb
  tags                 = merge(var.tags, { role = "mail-store" })
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  for_each = toset(local.mailbox_names)

  managed_disk_id    = azurerm_managed_disk.data[each.key].id
  virtual_machine_id = azurerm_linux_virtual_machine.vm[each.key].id
  # Fixed LUN: Ansible partitions/mounts by /dev/disk/azure/scsi1/lun0
  # rather than guessing at /dev/sd* ordering.
  lun     = local.data_disk_lun
  caching = "ReadWrite"
}
