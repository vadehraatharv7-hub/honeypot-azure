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

# Dedicated Monitoring subnet
resource "azurerm_subnet" "subnet_monitoring" {
  name                 = "subnet-monitoring"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]
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

  # --- NEW OUTBOUND RULES (LATERAL MOVEMENT PREVENTION) ---

  # 1. ALLOW Honeypot to send logs to the Monitoring VM
  security_rule {
    name                       = "Allow-Outbound-To-Monitoring"
    priority                   = 200
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"
    source_address_prefix      = "10.0.1.0/24" # Honeypot Subnet
    destination_address_prefix = "10.0.2.4"    # Monitoring VM Private IP
  }

  # 2. DENY Honeypot from talking to anything else on the internal network
  security_rule {
    name                       = "Deny-Outbound-VNet"
    priority                   = 210
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "10.0.1.0/24"
    destination_address_prefix = "10.0.0.0/16" # Blocks the rest of the VNet
  }

  
}

resource "azurerm_network_security_group" "nsg_monitoring" {
  name                = "nsg-monitoring-firewall"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  # Allow Honeypot to push logs directly to the Go Backend
  security_rule {
    name                       = "Allow-Backend-Ingestion"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "10.0.1.0/24"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "8080"
  }

  security_rule {
    name                       = "Allow-Admin-SSH"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = var.admin_public_ip
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "22222"
  }

  security_rule {
    name                       = "Allow-HTTP-Web"
    priority                   = 140
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = var.admin_public_ip               # var.admin_public_ip # Keeps it locked to your IP
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "80"
  }

}

# 4. Public IP and Network Interface (NIC)
resource "azurerm_public_ip" "pip" {
  name                = "pip-honeypot-vm"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard" 
}

resource "azurerm_public_ip" "pip_monitoring" {
  name                = "pip-monitoring-vm"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
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

resource "azurerm_network_interface" "nic_monitoring" {
  name                = "nic-monitoring"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet_monitoring.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.2.4"
    public_ip_address_id          = azurerm_public_ip.pip_monitoring.id
  }
}

# Associate the NSG to the NIC
resource "azurerm_network_interface_security_group_association" "nsg_asso" {
  network_interface_id      = azurerm_network_interface.nic.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "azurerm_network_interface_security_group_association" "nsg_asso_monitoring" {
  network_interface_id      = azurerm_network_interface.nic_monitoring.id
  network_security_group_id = azurerm_network_security_group.nsg_monitoring.id
}

# Ubuntu B1S Virtual Machine (Honeypot)
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
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  custom_data = base64encode(<<-EOF
    #!/bin/bash
    set -e

    sed -i 's/#Port 22/Port 22222/' /etc/ssh/sshd_config
    systemctl restart sshd

    # Use dd for 1GB swap creation to prevent Azure kernel issues
    if [ ! -f /swapfile ]; then
      dd if=/dev/zero of=/swapfile bs=1M count=1024
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile
      echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y software-properties-common iptables-persistent wget curl gpg \
      python3 python3-venv python3-dev git libssl-dev libffi-dev build-essential

    id -u cowrie &>/dev/null || useradd -m -s /bin/bash cowrie
    su - cowrie -c "git clone https://github.com/cowrie/cowrie.git /home/cowrie/cowrie"

    su - cowrie -c "python3 -m venv /home/cowrie/cowrie/cowrie-env"
    su - cowrie -c "/home/cowrie/cowrie/cowrie-env/bin/pip install --upgrade pip setuptools wheel"
    su - cowrie -c "/home/cowrie/cowrie/cowrie-env/bin/pip install -r /home/cowrie/cowrie/requirements.txt"
    su - cowrie -c "/home/cowrie/cowrie/cowrie-env/bin/pip install /home/cowrie/cowrie"
    su - cowrie -c "cd /home/cowrie/cowrie && source cowrie-env/bin/activate && cowrie init && cowrie start"

    iptables -t nat -A PREROUTING -p tcp --dport 22 -j REDIRECT --to-port 2222
    netfilter-persistent save

    # Deploy Native JSON Forwarder instead of Grafana Alloy
    cat << 'SCRIPT' > /usr/local/bin/cowrie-forwarder.sh
    #!/bin/bash
    tail -n 0 -F /home/cowrie/cowrie/var/log/cowrie/cowrie.json | while read line; do
      curl -s -X POST http://10.0.2.4:8080/api/ingest/cowrie \
           -H "Content-Type: application/json" \
           -d "$line" > /dev/null
    done
    SCRIPT

    chmod +x /usr/local/bin/cowrie-forwarder.sh

    cat << 'SERVICE' > /etc/systemd/system/cowrie-forwarder.service
    [Unit]
    Description=Cowrie Native JSON Forwarder
    After=network.target

    [Service]
    Type=simple
    User=root
    ExecStart=/usr/local/bin/cowrie-forwarder.sh
    Restart=always
    RestartSec=3

    [Install]
    WantedBy=multi-user.target
    SERVICE

    systemctl daemon-reload
    systemctl enable --now cowrie-forwarder
  EOF
  )
}

# 6. Monitoring VM with PM2 and Nginx
resource "azurerm_linux_virtual_machine" "vm_monitoring" {
  name                = "vm-monitoring"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  size                = "Standard_B1s"
  admin_username      = "azureuser"
  network_interface_ids = [
    azurerm_network_interface.nic_monitoring.id
  ]

  admin_ssh_key {
    username   = "azureuser"
    public_key = file("~/.ssh/id_rsa_azure.pub")
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  custom_data = base64encode(<<-EOF
    #!/bin/bash
    set -e

    sed -i 's/#Port 22/Port 22222/' /etc/ssh/sshd_config
    systemctl restart sshd

    # Use dd for 3GB swap to completely eliminate Vite OOM risks
    if [ ! -f /swapfile ]; then
      dd if=/dev/zero of=/swapfile bs=1M count=3072
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile
      echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl gnupg lsb-release git nginx wget

    # Install Go via official tarball (Bypasses unstable Snap daemon in cloud-init)
    GO_VERSION="1.22.0"
    wget https://golang.org/dl/go$GO_VERSION.linux-amd64.tar.gz
    rm -rf /usr/local/go && tar -C /usr/local -xzf go$GO_VERSION.linux-amd64.tar.gz
    rm go$GO_VERSION.linux-amd64.tar.gz
    export PATH=$PATH:/usr/local/go/bin

    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get update
    apt-get install -y nodejs
    
    npm install -g pm2

    APP_DIR="/home/azureuser/app"
    REPO_URL="https://github.com/vadehraatharv7-hub/sec_dash.git"

    sudo -u azureuser git clone $REPO_URL $APP_DIR

    cd $APP_DIR/backend
    sudo -u azureuser env PATH=$PATH:/usr/local/go/bin go build -o api-server ./cmd/server
    chmod +x api-server

    cd $APP_DIR/frontend
    sudo -u azureuser npm install
    
    # Enforce memory cap on Node.js to stop Vite from consuming system memory limits
    sudo -u azureuser env NODE_OPTIONS="--max-old-space-size=1024" npm run build

    BUILD_DIR="$APP_DIR/frontend/dist"
    [ ! -d "$BUILD_DIR" ] && BUILD_DIR="$APP_DIR/frontend/build"

    sudo -u azureuser pm2 start $APP_DIR/backend/api-server --name "go-backend"
    sudo -u azureuser pm2 serve $BUILD_DIR 3000 --name "react-frontend" --spa
    sudo -u azureuser pm2 save

    env PATH=$PATH:/usr/bin pm2 startup systemd -u azureuser --hp /home/azureuser
    systemctl enable pm2-azureuser

    # Configure Nginx Reverse Proxy
    cat << 'NGINX_CONF' > /etc/nginx/sites-available/default
    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        server_name _;

        # React UI
        location / {
            proxy_pass http://127.0.0.1:3000;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection 'upgrade';
            proxy_set_header Host $host;
            proxy_cache_bypass $http_upgrade;
        }

        # WebSocket Live Stream
        location /ws {
            proxy_pass http://127.0.0.1:8080;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host $host;
            proxy_read_timeout 86400;
        }

        # REST API Endpoints
        location /api {
            proxy_pass http://127.0.0.1:8080;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }
    }
    NGINX_CONF

    nginx -t
    systemctl restart nginx
    systemctl enable nginx
  EOF
  )
}
