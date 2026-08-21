resource "azurerm_virtual_network" "mail" {
  name                = "vnet-mail"
  location            = azurerm_resource_group.mail.location
  resource_group_name = azurerm_resource_group.mail.name
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "mail" {
  name                 = "snet-mail"
  resource_group_name  = azurerm_resource_group.mail.name
  virtual_network_name = azurerm_virtual_network.mail.name
  address_prefixes     = [var.vnet_cidr]
}

# --- MX edge nodes: public SMTP intake -------------------------------

resource "azurerm_network_security_group" "mx" {
  name                = "nsg-mail-mx"
  location            = azurerm_resource_group.mail.location
  resource_group_name = azurerm_resource_group.mail.name
  tags                = var.tags

  security_rule {
    name                       = "allow-ssh-admin"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.admin_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-smtp"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "25"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  # certbot --standalone (Let's Encrypt HTTP-01) for the MX TLS certs.
  security_rule {
    name                       = "allow-http-acme"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

# --- Mailbox server: client protocols public, SMTP only from the VNet

resource "azurerm_network_security_group" "mailbox" {
  name                = "nsg-mail-mailbox"
  location            = azurerm_resource_group.mail.location
  resource_group_name = azurerm_resource_group.mail.name
  tags                = var.tags

  security_rule {
    name                       = "allow-ssh-admin"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.admin_cidr
    destination_address_prefix = "*"
  }

  # Inbound mail arrives only via the MX edges over the VNet.
  security_rule {
    name                       = "allow-smtp-from-vnet"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "25"
    source_address_prefix      = var.vnet_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-mail-clients"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["443", "465", "587", "993"]
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface_security_group_association" "vm" {
  for_each = local.vms

  network_interface_id = azurerm_network_interface.vm[each.key].id
  network_security_group_id = (
    each.value.tier == "mx"
    ? azurerm_network_security_group.mx.id
    : azurerm_network_security_group.mailbox.id
  )
}
