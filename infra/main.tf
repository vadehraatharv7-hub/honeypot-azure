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
#Dedicated Monitoring subnet
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
}

resource "azurerm_network_security_group" "nsg_monitoring" {
  name                = "nsg-monitoring-firewall"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "Allow-Loki-Ingestion-From-Honeypot"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "10.0.1.0/24"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "3100"
  }

  # Admin SSH Access only
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

  # Admin Grafana Web UI Access only
  security_rule {
    name                       = "Allow-Admin-Grafana"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = var.admin_public_ip
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "3000"
  }

  # Drop all other inbound traffic
  security_rule {
    name                       = "Deny-All-Other-Inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_address_prefix      = "*"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "*"
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

# 3. Public IP and NIC for Monitoring VM
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
  # Updated to Ubuntu 22.04 LTS (Jammy) for native Python 3.10 support
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }


  # Cloud-init script injected as custom_data for Honeypot VM
  custom_data = base64encode(<<-EOF
    #!/bin/bash
    set -e

    # Step A: Rebind Real SSH to 22222
    sed -i 's/#Port 22/Port 22222/' /etc/ssh/sshd_config
    systemctl restart sshd

    # Step B: Add 1GB Swap (Crucial for B1s to prevent OOM kills during pip builds)
    if [ ! -f /swapfile ]; then
      fallocate -l 1G /swapfile
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile
      echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    # Step C: Install System Dependencies & Add Grafana Repo for Alloy
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y software-properties-common iptables-persistent wget curl gpg \
      python3 python3-venv python3-dev git libssl-dev libffi-dev build-essential

    mkdir -p /etc/apt/keyrings/
    wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | tee /etc/apt/keyrings/grafana.gpg > /dev/null
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | tee /etc/apt/sources.list.d/grafana.list
    apt-get update
    apt-get install -y alloy

    # Step D: Setup Cowrie User & Clone Repository
    id -u cowrie &>/dev/null || useradd -m -s /bin/bash cowrie
    su - cowrie -c "git clone https://github.com/cowrie/cowrie.git /home/cowrie/cowrie"

    # Step E: Setup venv, install packages, initialize, and start Cowrie
    su - cowrie -c "python3 -m venv /home/cowrie/cowrie/cowrie-env"
    su - cowrie -c "/home/cowrie/cowrie/cowrie-env/bin/pip install --upgrade pip setuptools wheel"
    su - cowrie -c "/home/cowrie/cowrie/cowrie-env/bin/pip install -r /home/cowrie/cowrie/requirements.txt"
    su - cowrie -c "/home/cowrie/cowrie/cowrie-env/bin/pip install /home/cowrie/cowrie"
    su - cowrie -c "cd /home/cowrie/cowrie && source cowrie-env/bin/activate && cowrie init && cowrie start"

    # Step F: Configure iptables Decoy Routing (Port 22 -> 2222)
    iptables -t nat -A PREROUTING -p tcp --dport 22 -j REDIRECT --to-port 2222
    netfilter-persistent save

    # Step G: Configure Grafana Alloy Pipeline
    cat << 'ALLOY_CONFIG' > /etc/alloy/config.alloy
    local.file_match "cowrie_logs" {
      path_targets = [{
        __path__ = "/home/cowrie/cowrie/var/log/cowrie/cowrie.json*",
        job      = "cowrie",
      }]
    }

    loki.source.file "cowrie_scraper" {
      targets    = local.file_match.cowrie_logs.targets
      forward_to = [loki.process.cowrie_parser.receiver]
    }

    loki.process "cowrie_parser" {
      stage.json {
        expressions = {
          eventid   = "eventid",
          src_ip    = "src_ip",
          username  = "username",
          password  = "password",
          input     = "input",
          system    = "system",
          timestamp = "timestamp",
        }
      }

      stage.labels {
        values = {
          eventid = "eventid",
        }
      }

      forward_to = [loki.write.internal_loki.receiver]
    }

    loki.write "internal_loki" {
      endpoint {
        url = "http://10.0.2.4:3100/loki/api/v1/push"
      }
    }
    ALLOY_CONFIG

    # Step H: File Permissions & Start Alloy Service
    usermod -aG cowrie alloy
    chmod 750 /home/cowrie
    chmod -R 755 /home/cowrie/cowrie/var/log

    alloy fmt /etc/alloy/config.alloy
    systemctl enable --now alloy
  EOF
  )
}

# 4. Monitoring VM with Automated Docker Install
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

    # 1. Rebind real SSH port to 22222
    sed -i 's/#Port 22/Port 22222/' /etc/ssh/sshd_config
    systemctl restart sshd

    # 2. Install Docker & Compose plugin non-interactively
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl gnupg lsb-release

    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    usermod -aG docker azureuser

    # 3. Create Monitoring Directories
    WORKDIR="/home/azureuser/monitoring"
    mkdir -p $WORKDIR/grafana/provisioning/datasources
    mkdir -p $WORKDIR/grafana/provisioning/dashboards
    mkdir -p $WORKDIR/grafana/dashboards

    # 4. Provision Loki Data Source
    cat << 'DS' > $WORKDIR/grafana/provisioning/datasources/loki.yml
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        access: proxy
        url: http://loki:3100
        isDefault: true
    DS

    # 5. Provision Dashboard Provider
    cat << 'PROVIDER' > $WORKDIR/grafana/provisioning/dashboards/default.yml
    apiVersion: 1
    providers:
      - name: 'Default'
        orgId: 1
        folder: ''
        type: file
        disableDeletion: false
        updateIntervalSeconds: 10
        options:
          path: /etc/grafana/dashboards
    PROVIDER

    # 6. Write Dashboard JSON
    cat << 'DASHBOARD' > $WORKDIR/grafana/dashboards/honeypot.json
    {
      "uid": "cowrie-threat-intel",
      "title": "Cowrie Honeypot Threat Intel",
      "tags": ["honeypot", "cowrie", "security"],
      "timezone": "browser",
      "schemaVersion": 39,
      "refresh": "5s",
      "time": {
        "from": "now-1h",
        "to": "now"
      },
      "timepicker": {
        "refresh_intervals": ["5s", "10s", "30s", "1m", "5m"]
      },
      "templating": {
        "list": [
          {
            "current": {
              "selected": true,
              "text": "Loki",
              "value": "Loki"
            },
            "hide": 0,
            "includeAll": false,
            "multi": false,
            "name": "DS_LOKI",
            "options": [],
            "query": "loki",
            "queryValue": "",
            "refresh": 1,
            "regex": "",
            "skipUrlSync": false,
            "type": "datasource"
          }
        ]
      },
      "panels": [
        {
          "collapsed": false,
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 0 },
          "id": 100,
          "title": "Honeypot Telemetry & Attack Velocity",
          "type": "row"
        },
        {
          "datasource": { "type": "loki", "uid": "$${DS_LOKI}" },
          "fieldConfig": {
            "defaults": {
              "custom": {
                "drawStyle": "line",
                "fillOpacity": 15,
                "gradientMode": "opacity",
                "lineInterpolation": "smooth",
                "lineWidth": 2,
                "showPoints": "never"
              },
              "unit": "short"
            },
            "overrides": []
          },
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 1 },
          "id": 1,
          "options": {
            "legend": { "calcs": ["sum", "lastNotNull"], "displayMode": "table", "placement": "bottom", "showLegend": true },
            "tooltip": { "mode": "multi", "sort": "desc" }
          },
          "targets": [
            {
              "datasource": { "type": "loki", "uid": "$${DS_LOKI}" },
              "editorMode": "code",
              "expr": "sum by (eventid) (rate({job=\"cowrie\"} [$__interval]))",
              "queryType": "range",
              "refId": "A"
            }
          ],
          "title": "Attack Velocity by Event Type",
          "type": "timeseries"
        },
        {
          "datasource": { "type": "loki", "uid": "$${DS_LOKI}" },
          "fieldConfig": {
            "defaults": {
              "color": { "mode": "thresholds" },
              "mappings": [],
              "thresholds": {
                "mode": "absolute",
                "steps": [
                  { "color": "green", "value": null },
                  { "color": "orange", "value": 5 },
                  { "color": "red", "value": 20 }
                ]
              }
            },
            "overrides": []
          },
          "gridPos": { "h": 8, "w": 4, "x": 12, "y": 1 },
          "id": 6,
          "options": {
            "colorMode": "value",
            "graphMode": "none",
            "justifyMode": "auto",
            "orientation": "auto",
            "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false },
            "textMode": "auto"
          },
          "targets": [
            {
              "datasource": { "type": "loki", "uid": "$${DS_LOKI}" },
              "editorMode": "code",
              "expr": "count(sum by (src_ip) (count_over_time({job=\"cowrie\"} | json | src_ip != \"\" [$__range])))",
              "queryType": "range",
              "refId": "A"
            }
          ],
          "title": "Distinct Attacker IPs",
          "type": "stat"
        },
        {
          "datasource": { "type": "loki", "uid": "$${DS_LOKI}" },
          "fieldConfig": {
            "defaults": {
              "color": { "mode": "thresholds" },
              "mappings": [],
              "thresholds": {
                "mode": "absolute",
                "steps": [
                  { "color": "green", "value": null },
                  { "color": "#EAB839", "value": 20 },
                  { "color": "red", "value": 50 }
                ]
              },
              "unit": "short"
            },
            "overrides": []
          },
          "gridPos": { "h": 8, "w": 8, "x": 16, "y": 1 },
          "id": 2,
          "options": {
            "displayMode": "gradient",
            "minVizHeight": 10,
            "minVizWidth": 0,
            "namePlacement": "auto",
            "orientation": "horizontal",
            "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false },
            "showUnfilled": true,
            "valueMode": "color"
          },
          "targets": [
            {
              "datasource": { "type": "loki", "uid": "$${DS_LOKI}" },
              "editorMode": "code",
              "expr": "topk(10, sum by (src_ip) (count_over_time({job=\"cowrie\"} | json | src_ip != \"\" [$__range])))",
              "queryType": "instant",
              "refId": "A"
            }
          ],
          "title": "Top 10 Attacker IPs",
          "type": "bargauge"
        },
        {
          "collapsed": false,
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 9 },
          "id": 101,
          "title": "Credential Harvest Analytics",
          "type": "row"
        },
        {
          "datasource": { "type": "loki", "uid": "$${DS_LOKI}" },
          "fieldConfig": {
            "defaults": {
              "custom": { "align": "auto", "cellOptions": { "type": "auto" }, "inspect": false },
              "mappings": [],
              "thresholds": { "mode": "absolute", "steps": [{ "color": "blue", "value": null }] }
            },
            "overrides": []
          },
          "gridPos": { "h": 7, "w": 12, "x": 0, "y": 10 },
          "id": 3,
          "options": {
            "cellHeight": "sm",
            "footer": { "countRows": false, "fields": "", "reducer": ["sum"], "show": false },
            "showHeader": true
          },
          "targets": [
            {
              "datasource": { "type": "loki", "uid": "$${DS_LOKI}" },
              "editorMode": "code",
              "expr": "topk(15, sum by (password) (count_over_time({job=\"cowrie\"} | json | password != \"\" [$__range])))",
              "queryType": "instant",
              "refId": "A"
            }
          ],
          "title": "Top Sprayed Passwords",
          "transformations": [
            {
              "id": "sortBy",
              "options": { "fields": {}, "sort": [{ "desc": true, "field": "Value" }] }
            },
            {
              "id": "organize",
              "options": {
                "excludeByName": { "Time": true },
                "indexByName": {},
                "renameByName": { "Value": "Attempt Count", "password": "Password" }
              }
            }
          ],
          "type": "table"
        },
        {
          "datasource": { "type": "loki", "uid": "$${DS_LOKI}" },
          "fieldConfig": {
            "defaults": { "color": { "mode": "palette-classic" }, "mappings": [] },
            "overrides": []
          },
          "gridPos": { "h": 7, "w": 12, "x": 12, "y": 10 },
          "id": 4,
          "options": {
            "displayLabels": ["name", "percent"],
            "legend": { "displayMode": "table", "placement": "right", "showLegend": true, "values": ["value"] },
            "pieType": "donut",
            "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false },
            "tooltip": { "mode": "single", "sort": "desc" }
          },
          "targets": [
            {
              "datasource": { "type": "loki", "uid": "$${DS_LOKI}" },
              "editorMode": "code",
              "expr": "topk(8, sum by (username) (count_over_time({job=\"cowrie\"} | json | username != \"\" [$__range])))",
              "queryType": "instant",
              "refId": "A"
            }
          ],
          "title": "Targeted Usernames",
          "type": "piechart"
        },
        {
          "collapsed": false,
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 17 },
          "id": 102,
          "title": "Interactive Shell Audit",
          "type": "row"
        },
        {
          "datasource": { "type": "loki", "uid": "$${DS_LOKI}" },
          "gridPos": { "h": 10, "w": 24, "x": 0, "y": 18 },
          "id": 5,
          "options": {
            "dedupStrategy": "none",
            "enableLogDetails": true,
            "prettifyLogMessage": false,
            "showCommonLabels": false,
            "showLabels": false,
            "showTime": true,
            "sortOrder": "Descending",
            "wrapLogMessage": true
          },
          "targets": [
            {
              "datasource": { "type": "loki", "uid": "$${DS_LOKI}" },
              "editorMode": "code",
              "expr": "{job=\"cowrie\"} | json | eventid =~ \"cowrie.command.*\" | line_format \"src={{.src_ip}} | user={{.username}} | cmd='{{.input}}'\"",
              "queryType": "range",
              "refId": "A"
            }
          ],
          "title": "Adversary Executed Commands Stream",
          "type": "logs"
        }
      ]
    }
    DASHBOARD

    # 7. Write Docker Compose File
    cat << 'COMPOSE' > $WORKDIR/docker-compose.yml
    services:
      loki:
        image: grafana/loki:latest
        container_name: loki
        restart: unless-stopped
        ports:
          - "10.0.2.4:3100:3100"
        command: -config.file=/etc/loki/local-config.yaml
        volumes:
          - loki-data:/loki

      grafana:
        image: grafana/grafana:latest
        container_name: grafana
        restart: unless-stopped
        ports:
          - "3000:3000"
        environment:
          - GF_SECURITY_ADMIN_USER=admin
          - GF_SECURITY_ADMIN_PASSWORD=${var.grafana_admin_password}
          - GF_USERS_ALLOW_SIGN_UP=false
        volumes:
          - grafana-data:/var/lib/grafana
          - ./grafana/provisioning:/etc/grafana/provisioning
          - ./grafana/dashboards:/etc/grafana/dashboards

    volumes:
      loki-data:
      grafana-data:
    COMPOSE

    chown -R azureuser:azureuser $WORKDIR
    sudo fallocate -l 2G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    # 8. Pull and launch the stack
    cd $WORKDIR
    docker compose up -d
  EOF
  )
}

