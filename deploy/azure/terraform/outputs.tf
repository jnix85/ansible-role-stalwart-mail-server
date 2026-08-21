output "mx_public_ips" {
  description = "Point your MX records at these."
  value       = { for name in local.mx_names : name => azurerm_public_ip.vm[name].ip_address }
}

output "mailbox_public_ip" {
  description = "A record for the mailbox server (IMAP/submission/web admin)."
  value       = { for name in local.mailbox_names : name => azurerm_public_ip.vm[name].ip_address }
}

output "ansible_inventory_path" {
  description = "Generated inventory consumed by ../ansible."
  value       = local_file.ansible_inventory.filename
}

# Render the Ansible inventory so the two stages chain without manual
# copying of IPs.
resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory/hosts.yml"
  file_permission = "0644"

  content = templatefile("${path.module}/templates/hosts.yml.tftpl", {
    domain         = var.domain
    admin_username = var.admin_username
    mx_hosts = {
      for name in local.mx_names : name => {
        public_ip  = azurerm_public_ip.vm[name].ip_address
        private_ip = azurerm_network_interface.vm[name].private_ip_address
      }
    }
    mailbox_hosts = {
      for name in local.mailbox_names : name => {
        public_ip  = azurerm_public_ip.vm[name].ip_address
        private_ip = azurerm_network_interface.vm[name].private_ip_address
      }
    }
  })
}
