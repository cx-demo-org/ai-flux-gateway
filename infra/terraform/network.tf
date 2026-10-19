resource "azurerm_virtual_network" "main" {
  count               = local.prerequisites_stage ? 1 : 0
  name                = "${local.prefix}-vnet"
  location            = var.location
  resource_group_name = local.rg
  address_space       = [var.network.address_space]
  tags                = local.tags
  depends_on          = [terraform_data.approval]
}

resource "azapi_resource" "subnet_main" {
  for_each  = local.prerequisites_stage ? { appgw = var.network.app_gateway_subnet } : {}
  type      = "Microsoft.Network/virtualNetworks/subnets@2024-05-01"
  name      = "${local.prefix}-${each.key}"
  parent_id = azurerm_virtual_network.main[0].id
  # Governance denies subnets created without an NSG and non-storage service endpoints.
  body = {
    properties = {
      addressPrefix        = each.value
      networkSecurityGroup = { id = azurerm_network_security_group.appgw["public"].id }
    }
  }
}

resource "azurerm_network_security_group" "appgw" {
  for_each            = local.prerequisites_stage ? { public = true } : {}
  name                = "${local.prefix}-appgw-nsg"
  location            = var.location
  resource_group_name = local.rg
  tags                = local.tags
  security_rule {
    name                       = "AcmeHttp"
    priority                   = 115
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "PlatformHealth"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "PublicHttps"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "PlatformManagement"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "65200-65535"
    source_address_prefix      = "GatewayManager"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "appgw" {
  for_each                  = local.edge_stage && var.app_gateway_existing_nsg_name != null ? { public = true } : {}
  subnet_id                 = azapi_resource.subnet_main["appgw"].id
  network_security_group_id = data.azurerm_network_security_group.appgw_platform[0].id
}

data "azurerm_network_security_group" "appgw_platform" {
  count               = local.edge_stage && var.app_gateway_existing_nsg_name != null ? 1 : 0
  name                = var.app_gateway_existing_nsg_name
  resource_group_name = local.rg
}

resource "azurerm_network_security_rule" "appgw_platform" {
  for_each = local.edge_stage && var.app_gateway_existing_nsg_name != null ? {
    PlatformHealth     = { priority = 100, source = "AzureLoadBalancer", port = "*", protocol = "*" }
    PublicHttps        = { priority = 110, source = "Internet", port = "443", protocol = "Tcp" }
    AcmeHttp           = { priority = 115, source = "Internet", port = "80", protocol = "Tcp" }
    PlatformManagement = { priority = 120, source = "GatewayManager", port = "65200-65535", protocol = "Tcp" }
  } : {}
  name                        = "AIFLUX${each.key}"
  resource_group_name         = local.rg
  network_security_group_name = data.azurerm_network_security_group.appgw_platform[0].name
  priority                    = each.value.priority
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = each.value.protocol
  source_port_range           = "*"
  destination_port_range      = each.value.port
  source_address_prefix       = each.value.source
  destination_address_prefix  = "*"
}
