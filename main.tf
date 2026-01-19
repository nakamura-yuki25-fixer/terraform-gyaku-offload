#
# ----------------- ネットワーク -----------------
#

# resource group
resource "azurerm_resource_group" "rg" {
  location = var.resource_group_location
  name     = var.base_name
}

# vnet
resource "azurerm_virtual_network" "vnet" {
  name                = "${var.base_name}-vnet"
  # subnetが/24と/26と/26 => 256 + 64 + 64 => 余裕を持って/22(1024)
  address_space       = ["172.16.0.0/22"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

# subnet(agw)
resource "azurerm_subnet" "subnet-agw" {
  name                 = "agw"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  # agwデプロイに推奨されるサイズ
  address_prefixes     = ["172.16.1.0/24"]
}

# pip
resource "azurerm_public_ip" "pip" {
  name                = "${var.base_name}-pip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  # agwで使用するpipの要件
  allocation_method   = "Static"
  sku                 = "Standard"
}

# waf
resource "azurerm_web_application_firewall_policy" "waf" {
  name                = "${var.base_name}-waf-policy"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  # コピペ
  policy_settings {
    enabled                                   = true
    js_challenge_cookie_expiration_in_minutes = 5
    max_request_body_size_in_kb               = 128
    mode                                      = "Detection"
    request_body_check                        = true
    request_body_inspect_limit_in_kb          = 128
  }

  # コピペ
  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
    }
  }
}

# agwのbackend poolで指定するFQDN
locals {
  app_fqdn = "${azurerm_windows_web_app.backend.name}.azurewebsites.net"
}

# application gateway
resource "azurerm_application_gateway" "agw" {
  name                = "${var.base_name}-agw"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  # wafの関連付け
  firewall_policy_id = azurerm_web_application_firewall_policy.waf.id

  # wafと関連付け
  sku {
    name = "WAF_v2"
    tier = "WAF_v2"
  }

  # コピペ
  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = azurerm_subnet.subnet-agw.id
  }

  # コピペ
  frontend_ip_configuration {
    name                 = "appgw-frontend-ip"
    public_ip_address_id = azurerm_public_ip.pip.id
  }

  # コピペ
  frontend_port {
    name = "appgw-frontend-port"
    port = 80
  }

  # App Serviceの規定のドメインを指定
  backend_address_pool {
    name         = "appgw-backend-pool"
    fqdns = [local.app_fqdn]
  }

  # コピペ
  backend_http_settings {
    name                  = "appgw-backend-http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 20
  }

  # コピペ
  http_listener {
    name                           = "appgw-http-listener"
    frontend_ip_configuration_name = "appgw-frontend-ip"
    frontend_port_name             = "appgw-frontend-port"
    protocol                       = "Http"
  }

  # コピペ
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
  address_prefixes     = ["172.16.2.0/26"]

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
  address_prefixes     = ["172.16.2.64/26"]
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
