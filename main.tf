locals {
  app_private_fqdn = "${azurerm_windows_web_app.backend.name}.azurewebsites.net"
}

# resource group
resource "azurerm_resource_group" "rg" {
  location = var.resource_group_location
  name     = var.base_name
}

# vnet
resource "azurerm_virtual_network" "vnet" {
  name                = "${var.base_name}-vnet"
  address_space       = ["10.0.0.0/22"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

# subnet(agw)
resource "azurerm_subnet" "subnet-agw" {
  name                 = "agw"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]

  delegation {
    name = "applicationGateways"

    service_delegation {
      name = "Microsoft.Network/applicationGateways"
      actions = [
        "Microsoft.Network/networkinterfaces/*"
      ]
    }
  }
}

# pip
resource "azurerm_public_ip" "pip" {
  name                = "${var.base_name}-pip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# waf
resource "azurerm_web_application_firewall_policy" "waf" {
  name                = "${var.base_name}-waf-policy"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  # Configure the policy settings
  policy_settings {
    enabled                                   = true
    file_upload_limit_in_mb                   = 100
    js_challenge_cookie_expiration_in_minutes = 5
    max_request_body_size_in_kb               = 128
    mode                                      = "Detection"
    request_body_check                        = true
    request_body_inspect_limit_in_kb          = 128
  }

  # Define managed rules for the WAF policy
  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
    }
  }

  # Define a custom rule to block traffic from a specific IP address
  custom_rules {
    name      = "BlockSpecificIP"
    priority  = 1
    rule_type = "MatchRule"

    match_conditions {
      match_variables {
        variable_name = "RemoteAddr"
      }
      operator           = "IPMatch"
      negation_condition = false
      match_values       = ["192.168.1.1"] # Replace with the IP address to block
    }

    action = "Block"
  }
}

# application gateway
resource "azurerm_application_gateway" "agw" {
  name                = "${var.base_name}-agw"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  firewall_policy_id = azurerm_web_application_firewall_policy.waf.id

  # Configure the SKU and capacity
  sku {
    name = "WAF_v2"
    tier = "WAF_v2"
  }

  # Enable autoscaling (optional)
  autoscale_configuration {
    min_capacity = 2
    max_capacity = 10
  }

  # Configure the gateway's IP settings
  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = azurerm_subnet.subnet-agw.id
  }

  # Configure the frontend IP
  frontend_ip_configuration {
    name                 = "appgw-frontend-ip"
    public_ip_address_id = azurerm_public_ip.pip.id
  }

  # Define the frontend port
  frontend_port {
    name = "appgw-frontend-port"
    port = 80
  }

  # Define the backend address pool with IP addresses
  backend_address_pool {
    name         = "appgw-backend-pool"
    fqdns = [local.app_private_fqdn]
  }

  # Configure backend HTTP settings
  backend_http_settings {
    name                  = "appgw-backend-http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 20
    pick_host_name_from_backend_address = true
  }

  # Define the HTTP listener
  http_listener {
    name                           = "appgw-http-listener"
    frontend_ip_configuration_name = "appgw-frontend-ip"
    frontend_port_name             = "appgw-frontend-port"
    protocol                       = "Http"
  }

  # Define the request routing rule
  request_routing_rule {
    name                       = "appgw-routing-rule"
    priority                   = 9
    rule_type                  = "Basic"
    http_listener_name         = "appgw-http-listener"
    backend_address_pool_name  = "appgw-backend-pool"
    backend_http_settings_name = "appgw-backend-http-settings"
  }
}

#
# ----------------- vnet統合 -----------------
#

# subnet(app)
resource "azurerm_subnet" "subnet-app" {
  name                 = "app"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/26"]

  delegation {
    name = "delegation"
    service_delegation {
      name = "Microsoft.Web/serverFarms"
    }
  }
}

resource "azurerm_service_plan" "app-plan" {
  name                = "${var.base_name}-plan"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Windows"
  sku_name            = "B1"
}

resource "azurerm_windows_web_app" "backend" {
  name                = "${var.base_name}-app"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  service_plan_id = azurerm_service_plan.app-plan.id
  virtual_network_subnet_id = azurerm_subnet.subnet-app.id

  site_config {
    ip_restriction {
      name       = "Allow-AppGW-Subnet"
      priority   = 100
      action     = "Allow"
      ip_address = azurerm_subnet.subnet-agw.address_prefixes[0]
    }

    ip_restriction {
      name     = "Deny-All"
      priority = 65500
      action   = "Deny"
      ip_address = "0.0.0.0/0"
    }
  }
  app_settings = {
    "WEBSITE_DNS_SERVER": "168.63.129.16",
  }
}

#
# ----------------- private endpoint -----------------
#

# subnet(pep)
resource "azurerm_subnet" "subnet-pep" {
  name                 = "pep"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.64/26"]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_private_dns_zone" "dnsprivatezone" {
  name                = "privatelink.azurewebsites.net"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "dnszonelink" {
  name = "dnszonelink"
  resource_group_name = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.dnsprivatezone.name
  virtual_network_id = azurerm_virtual_network.vnet.id
}

resource "azurerm_private_endpoint" "pep" {
  name                = "${var.base_name}-pep"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.subnet-pep.id

  private_dns_zone_group {
    name = "privatednszonegroup"
    private_dns_zone_ids = [azurerm_private_dns_zone.dnsprivatezone.id]
  }

  private_service_connection {
    name = "privateendpointconnection"
    private_connection_resource_id = azurerm_windows_web_app.backend.id
    subresource_names = ["sites"]
    is_manual_connection = false
  }
}
