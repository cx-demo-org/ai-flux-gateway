resource "azurerm_public_ip" "appgw" {
  for_each            = local.edge_stage ? { public = true } : {}
  name                = "${local.prefix}-appgw-pip"
  location            = var.location
  resource_group_name = local.rg
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.edge.zones
  domain_name_label   = var.edge.dns_label
  tags                = local.tags
  lifecycle {
    # Azure stamps immutable FirstPartyUsage ip_tags; removing them replaces the IP.
    ignore_changes = [ip_tags]
  }
  depends_on = [terraform_data.approval]
}

resource "azurerm_web_application_firewall_policy" "appgw" {
  for_each            = local.edge_stage ? { public = true } : {}
  name                = "${local.prefix}-appgw-waf"
  location            = var.location
  resource_group_name = local.rg
  tags                = local.tags
  policy_settings {
    enabled                          = true
    mode                             = "Prevention"
    request_body_check               = true
    max_request_body_size_in_kb      = var.edge.waf_body_limit_kb
    request_body_inspect_limit_in_kb = var.edge.waf_inspection_limit_kb
    file_upload_enforcement          = true
    request_body_enforcement         = true
    log_scrubbing {
      enabled = true
      dynamic "rule" {
        for_each = toset(["RequestHeaderNames", "RequestCookieNames", "RequestArgNames", "RequestPostArgNames", "RequestJSONArgNames"])
        content {
          enabled                 = true
          match_variable          = rule.value
          selector_match_operator = "EqualsAny"
        }
      }
      rule {
        enabled                 = true
        match_variable          = "RequestIPAddress"
        selector_match_operator = "EqualsAny"
      }
    }
  }
  # Inference never reaches an origin, even during operator acceptance.
  custom_rules {
    name      = "InferenceDisabled"
    priority  = 1
    rule_type = "MatchRule"
    action    = "Block"
    match_conditions {
      match_variables {
        variable_name = "RequestUri"
      }
      operator     = "Regex"
      match_values = ["^/v1(/|[?]|$)"]
      transforms   = ["UrlDecode", "Lowercase"]
    }
  }
  dynamic "custom_rules" {
    for_each = local.public_edge_stage ? [] : [1]
    content {
      name      = "ChallengeOnlyUntilAccepted"
      priority  = 2
      rule_type = "MatchRule"
      action    = "Block"
      match_conditions {
        match_variables {
          variable_name = "RequestUri"
        }
        operator           = "Regex"
        match_values       = ["^/\\.well-known/acme-challenge/[A-Za-z0-9_-]{20,128}$"]
        negation_condition = true
      }
      dynamic "match_conditions" {
        for_each = local.edge_tls_stage ? [1] : []
        content {
          match_variables {
            variable_name = "RemoteAddr"
          }
          operator           = "IPMatch"
          match_values       = ["${var.operator_ip}/32"]
          negation_condition = true
        }
      }
    }
  }
  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
    }
  }
  depends_on = [terraform_data.approval]
}

locals {
  appgw_backends = local.edge_stage ? merge(
    {
      deny = { fqdn = azurerm_linux_web_app.main["api"].default_hostname, health = "/health" }
      api  = { fqdn = azurerm_linux_web_app.main["api"].default_hostname, health = "/health" }
    },
    local.edge_tls_stage ? { for k, app in azurerm_linux_web_app.main : k => {
      fqdn = app.default_hostname, health = var.apps[k].health_path
    } } : {},
  ) : {}
}

resource "azurerm_application_gateway" "main" {
  for_each            = local.edge_stage ? { public = true } : {}
  name                = "${local.prefix}-appgw"
  location            = var.location
  resource_group_name = local.rg
  zones               = var.edge.zones
  firewall_policy_id  = azurerm_web_application_firewall_policy.appgw[each.key].id
  tags                = local.tags
  sku {
    name = "WAF_v2"
    tier = "WAF_v2"
  }
  autoscale_configuration {
    min_capacity = 2
    max_capacity = 4
  }
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.identity["edge"].id]
  }
  gateway_ip_configuration {
    name      = "gateway"
    subnet_id = azapi_resource.subnet_main["appgw"].id
  }
  frontend_ip_configuration {
    name                 = "public"
    public_ip_address_id = azurerm_public_ip.appgw[each.key].id
  }
  frontend_port {
    name = "http"
    port = 80
  }
  dynamic "frontend_port" {
    for_each = local.edge_tls_stage ? [1] : []
    content {
      name = "https"
      port = 443
    }
  }
  dynamic "ssl_certificate" {
    for_each = local.edge_tls_stage ? [1] : []
    content {
      name                = "origin"
      key_vault_secret_id = var.edge.certificate_secret_id
    }
  }
  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101S"
  }
  http_listener {
    name                           = "challenge-http"
    frontend_ip_configuration_name = "public"
    frontend_port_name             = "http"
    protocol                       = "Http"
    host_name                      = var.edge.origin_hostname
  }
  dynamic "http_listener" {
    for_each = local.edge_tls_stage ? [1] : []
    content {
      name                           = "public-https"
      frontend_ip_configuration_name = "public"
      frontend_port_name             = "https"
      protocol                       = "Https"
      host_name                      = var.edge.origin_hostname
      require_sni                    = true
      ssl_certificate_name           = "origin"
    }
  }
  global {
    request_buffering_enabled  = true
    response_buffering_enabled = false
  }
  dynamic "backend_address_pool" {
    for_each = local.appgw_backends
    content {
      name  = backend_address_pool.key
      fqdns = [backend_address_pool.value.fqdn]
    }
  }
  dynamic "backend_http_settings" {
    for_each = local.appgw_backends
    content {
      name                                = backend_http_settings.key
      cookie_based_affinity               = "Disabled"
      port                                = 443
      protocol                            = "Https"
      pick_host_name_from_backend_address = true
      probe_name                          = backend_http_settings.key
      path                                = backend_http_settings.key == "deny" ? "/_edge-denied/" : null
      request_timeout                     = var.edge.app_gateway_timeout_seconds
    }
  }
  dynamic "probe" {
    for_each = local.appgw_backends
    content {
      name                                      = probe.key
      protocol                                  = "Https"
      path                                      = probe.value.health
      pick_host_name_from_backend_http_settings = true
      interval                                  = 30
      timeout                                   = 30
      unhealthy_threshold                       = 3
      match {
        status_code = ["200"]
      }
    }
  }
  request_routing_rule {
    name               = "challenge"
    priority           = 90
    rule_type          = "PathBasedRouting"
    http_listener_name = "challenge-http"
    url_path_map_name  = "challenge"
  }
  url_path_map {
    name                               = "challenge"
    default_backend_address_pool_name  = "deny"
    default_backend_http_settings_name = "deny"
    path_rule {
      name                       = "acme"
      paths                      = ["/.well-known/acme-challenge/*"]
      backend_address_pool_name  = "api"
      backend_http_settings_name = "api"
    }
  }
  dynamic "request_routing_rule" {
    for_each = local.edge_tls_stage ? [1] : []
    content {
      name               = "routes"
      priority           = 100
      rule_type          = "PathBasedRouting"
      http_listener_name = "public-https"
      url_path_map_name  = "routes"
    }
  }
  dynamic "url_path_map" {
    for_each = local.edge_tls_stage ? [1] : []
    content {
      name                               = "routes"
      default_backend_address_pool_name  = "customer"
      default_backend_http_settings_name = "customer"
      path_rule {
        name                       = "inference"
        paths                      = ["/v1", "/v1/*"]
        backend_address_pool_name  = "deny"
        backend_http_settings_name = "deny"
      }
      path_rule {
        name                       = "control-plane"
        paths                      = ["/api", "/api/*", "/health", "/ready", "/.well-known/acme-challenge/*"]
        backend_address_pool_name  = "api"
        backend_http_settings_name = "api"
      }
      path_rule {
        name                       = "admin"
        paths                      = ["/admin", "/admin/*"]
        backend_address_pool_name  = "admin"
        backend_http_settings_name = "admin"
      }
    }
  }
  depends_on = [
    terraform_data.approval,
    azurerm_role_assignment.edge_certificate,
    terraform_data.sql_firewall_gate,
    azurerm_subnet_network_security_group_association.appgw,
    azurerm_network_security_rule.appgw_platform,
  ]
}
