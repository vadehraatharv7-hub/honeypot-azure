resource "azurerm_resource_group" "rg" {
  name     = "rg-honeypot-prod"
  location = "denmarkeast"
}

# 2. Virtual Network
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-honeypot"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

}
# Subnet inside the VNet
resource "azurerm_subnet" "subnet" {
  name                 = "subnet-internal"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]

}
# 3. Network Security Group (NSG) with Decoy Port 
resource "azurerm_network_security_group" "nsg" {
  name                = "nsg-honeypot-firewall"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "allow-decoy-port"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"

  }
  security_rule {
    name                       = "Allow-Admin-SSH"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22222"
    source_address_prefix      = var.admin_public_ip
    destination_address_prefix = "*"
  }
}

# 4. Public IP and Network Interface (NIC)
resource "azurerm_public_ip" "pip" {
  name                = "pip-honeypot-vm"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"   # Standard SKU requires Static allocation
  sku                 = "Standard" # Switch from Basic to Standard
}

resource "azurerm_network_interface" "nic" {
  name                = "nic-honeypot"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pip.id
  }

}

# Associate the NSG to the NIC

resource "azurerm_network_interface_security_group_association" "nsg_asso" {
  network_interface_id      = azurerm_network_interface.nic.id
  network_security_group_id = azurerm_network_security_group.nsg.id

}

# 5. Ubuntu B1S Virtual Machine

resource "azurerm_linux_virtual_machine" "vm" {
  name                = "vm-honeypot"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  size                = "Standard_B1s"
  admin_username      = "azureuser"
  network_interface_ids = [
    azurerm_network_interface.nic.id
  ]
  admin_ssh_key {
    username   = "azureuser"
    public_key = file("~/.ssh/id_rsa_azure.pub")
  }
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
  # Updated to Ubuntu 22.04 LTS (Jammy) for native Python 3.10 support
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }


  # 4. Cloud-init script injected as custom_data
custom_data = base64encode(<<-EOF
  #!/bin/bash
  # Step A: Rebind Real SSH to 22222
  sed -i 's/#Port 22/Port 22222/' /etc/ssh/sshd_config
  systemctl restart sshd

  # Step B: Install Dependencies natively without interactive prompts
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y software-properties-common iptables-persistent
  apt-get install -y python3 python3-venv python3-dev git libssl-dev libffi-dev build-essential

  # Step C: Setup Cowrie User & Clone Repository
  useradd -m -s /bin/bash cowrie
  su - cowrie -c "git clone https://github.com/cowrie/cowrie.git /home/cowrie/cowrie"

  # Step D: Setup venv, install packages, initialize, and start Cowrie
  su - cowrie -c "python3 -m venv /home/cowrie/cowrie/cowrie-env"
  su - cowrie -c "/home/cowrie/cowrie/cowrie-env/bin/pip install --upgrade pip setuptools wheel"
  su - cowrie -c "/home/cowrie/cowrie/cowrie-env/bin/pip install -r /home/cowrie/cowrie/requirements.txt"
  su - cowrie -c "/home/cowrie/cowrie/cowrie-env/bin/pip install /home/cowrie/cowrie"
  su - cowrie -c "cd /home/cowrie/cowrie && source cowrie-env/bin/activate && cowrie init && cowrie start"

  # Step E: Configure iptables and make it persistent
  iptables -t nat -A PREROUTING -p tcp --dport 22 -j REDIRECT --to-port 2222
  netfilter-persistent save
EOF
)
}