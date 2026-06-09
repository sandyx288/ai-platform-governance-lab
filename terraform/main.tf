terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}

  subscription_id                 = var.subscription_id
  resource_provider_registrations = "none"
}

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "admin_username" {
  description = "Admin username for the Linux VM"
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key" {
  description = "SSH public key for VM authentication"
  type        = string
}

variable "location" {
  description = "Azure region for lab resources"
  type        = string
  default     = "malaysiawest"
}

variable "vm_size" {
  description = "Azure VM size"
  type        = string
  default     = "Standard_D2as_v4"
}

resource "azurerm_resource_group" "lab" {
  name     = "rg-ai-platform-lab"
  location = var.location
}

resource "azurerm_virtual_network" "lab" {
  name                = "vnet-ai-platform-lab"
  address_space       = ["10.1.0.0/16"]
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
}

resource "azurerm_subnet" "lab" {
  name                 = "snet-default"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = ["10.1.1.0/24"]
}

resource "azurerm_network_security_group" "lab" {
  name                = "nsg-ai-platform-lab"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
}

resource "azurerm_network_security_rule" "allow_ssh" {
  name                        = "AllowSSH"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.lab.name
}

resource "azurerm_subnet_network_security_group_association" "lab" {
  subnet_id                 = azurerm_subnet.lab.id
  network_security_group_id = azurerm_network_security_group.lab.id
}

resource "azurerm_public_ip" "lab" {
  name                = "pip-ai-platform-lab"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "lab" {
  name                = "nic-ai-platform-lab"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.lab.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.lab.id
  }
}

resource "azurerm_linux_virtual_machine" "lab" {
  name                = "vm-ai-platform-lab"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  size                = var.vm_size
  admin_username      = var.admin_username

  network_interface_ids = [
    azurerm_network_interface.lab.id,
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  disable_password_authentication = true

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

output "virtual_network_id" {
  value = azurerm_virtual_network.lab.id
}

output "subnet_id" {
  value = azurerm_subnet.lab.id
}

output "network_security_group_id" {
  value = azurerm_network_security_group.lab.id
}

output "public_ip_address" {
  value = azurerm_public_ip.lab.ip_address
}

output "vm_name" {
  value = azurerm_linux_virtual_machine.lab.name
}

output "resource_group" {
  value = azurerm_resource_group.lab.name
}

output "ssh_command" {
  value = "ssh ${var.admin_username}@${azurerm_public_ip.lab.ip_address}"
}

