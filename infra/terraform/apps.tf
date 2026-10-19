locals {
  ingestion_image_repository = var.ingestion_container_image != "" ? trimprefix(var.ingestion_container_image, "${split("/", var.ingestion_container_image)[0]}/") : ""
  database_url               = local.platform_stage ? "mssql+pyodbc://@${azurerm_mssql_server.main[0].fully_qualified_domain_name}:1433/${azurerm_mssql_database.main[0].name}?driver=ODBC+Driver+18+for+SQL+Server&Encrypt=yes&TrustServerCertificate=no" : ""
  gateway_url                = var.dev_direct_portals_enabled ? "https://${local.apim_name}.azure-api.net/dev/llm/v1" : (local.public_edge_stage ? "https://${var.edge.origin_hostname}/v1" : (local.platform_stage ? "https://${var.gateway_origin_hostname}/v1" : ""))
  control_settings = local.platform_stage ? merge({
    AIFLUX_ENVIRONMENT              = "production"
    AIFLUX_DATABASE_URL             = local.database_url
    AIFLUX_ENTRA_AUDIENCE           = var.entra.audience
    AIFLUX_ENTRA_CLIENT_ID          = var.entra.client_id
    AIFLUX_HOME_TENANT_ID           = var.entra.home_tenant_id
    AIFLUX_BOOTSTRAP_OBJECT_ID      = var.entra.bootstrap_object_id
    AIFLUX_GATEWAY_URL              = local.gateway_url
    AIFLUX_APIM_RESOURCE_ID         = azurerm_api_management.main.id
    AIFLUX_APIM_PRODUCT_ID          = var.dev_direct_portals_enabled ? azurerm_api_management_product.dev_unified[0].product_id : azurerm_api_management_product.main.product_id
    AIFLUX_LOG_WORKSPACE_ID         = azurerm_log_analytics_workspace.main.workspace_id
    AIFLUX_CATALOG_PATH             = var.dev_direct_portals_enabled ? "/app/gateway/catalog/dev-models.json" : var.catalog_container_path
    AIFLUX_CATALOG_CONFIGURED       = tostring(var.dev_catalog_accepted)
    AIFLUX_CORS_ORIGINS             = jsonencode(var.dev_direct_portals_enabled ? distinct(concat(var.dev_portal_origins, ["https://${var.gateway_origin_hostname}"])) : [])
    AIFLUX_ACME_CHALLENGE_ENABLED   = tostring(var.acme_http01_enabled)
    AIFLUX_MISE_VALIDATION_ENDPOINT = var.mise_sidecar_enabled ? "http://127.0.0.1:8081/Validate" : ""
    }, var.dev_direct_portals_enabled ? {
    AIFLUX_GATEWAY_MAX_COMPLETION_TOKENS = tostring(var.dev_unified_max_completion_tokens)
  } : {}) : {}
}

resource "azurerm_service_plan" "apps" {
  count               = local.prerequisites_stage ? 1 : 0
  name                = "${local.prefix}-apps-plan"
  resource_group_name = local.rg
  location            = var.location
  os_type             = "Linux"
  sku_name            = var.app_service_sku
  tags                = local.tags
  depends_on          = [terraform_data.approval]
}

resource "azurerm_linux_web_app" "main" {
  for_each                                       = local.platform_stage ? var.apps : {}
  name                                           = "${local.prefix}-${each.key}"
  resource_group_name                            = local.rg
  location                                       = var.location
  service_plan_id                                = azurerm_service_plan.apps[0].id
  https_only                                     = true
  public_network_access_enabled                  = true
  virtual_network_subnet_id                      = var.hybrid_private_data_enabled && each.key == "api" ? azurerm_subnet.app_service_integration[0].id : null
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false
  key_vault_reference_identity_id                = azurerm_user_assigned_identity.identity[each.key].id
  tags                                           = local.tags
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.identity[each.key].id]
  }
  app_settings = merge(each.key == "api" ? local.control_settings : {}, {
    AZURE_CLIENT_ID                           = azurerm_user_assigned_identity.identity[each.key].client_id
    WEBSITES_PORT                             = tostring(each.value.port)
    APPLICATIONINSIGHTS_CONNECTION_STRING     = azurerm_application_insights.main.connection_string
    APPLICATIONINSIGHTS_AUTHENTICATION_STRING = "Authorization=AAD;ClientId=${azurerm_user_assigned_identity.identity[each.key].client_id}"
    }, each.key != "api" ? {
    GATEWAY_ORIGIN = var.dev_direct_portals_enabled ? "https://${local.apim_name}.azure-api.net" : "https://${var.gateway_origin_hostname}"
    CONTROL_ORIGIN = var.dev_direct_portals_enabled ? "https://${local.prefix}-api.azurewebsites.net" : "https://${var.gateway_origin_hostname}"
  } : {})
  site_config {
    app_command_line                  = each.key == "api" && var.dev_price_bootstrap_enabled ? "python -m aiflux.price_bootstrap --file /app/gateway/catalog/dev-prices.json --actor-object-id ${azurerm_user_assigned_identity.identity["api"].principal_id} --serve" : null
    ip_restriction_default_action     = var.dev_direct_portals_enabled ? "Allow" : "Deny"
    scm_use_main_ip_restriction       = !var.dev_direct_portals_enabled
    scm_ip_restriction_default_action = "Deny"
    dynamic "scm_ip_restriction" {
      for_each = var.dev_direct_portals_enabled ? [var.operator_ip] : []
      content {
        name       = "reviewed-operator"
        priority   = 110
        action     = "Allow"
        ip_address = "${scm_ip_restriction.value}/32"
      }
    }
    dynamic "ip_restriction" {
      for_each = local.edge_stage ? [true] : []
      content {
        name                      = "application-gateway"
        priority                  = 100
        action                    = "Allow"
        virtual_network_subnet_id = azapi_resource.subnet_main["appgw"].id
      }
    }
    ip_restriction {
      name       = "reviewed-operator"
      priority   = 110
      action     = "Allow"
      ip_address = "${var.operator_ip}/32"
    }
    always_on                                     = true
    minimum_tls_version                           = "1.2"
    scm_minimum_tls_version                       = "1.2"
    ftps_state                                    = "Disabled"
    health_check_path                             = each.value.health_path
    health_check_eviction_time_in_min             = 10
    container_registry_use_managed_identity       = true
    container_registry_managed_identity_client_id = azurerm_user_assigned_identity.identity[each.key].client_id
    application_stack {
      docker_image_name   = each.value.image
      docker_registry_url = each.value.registry_url
    }
  }
  logs {
    detailed_error_messages = false
    failed_request_tracing  = false
  }
  depends_on = [azurerm_role_assignment.acr_pull]
}

resource "azapi_resource" "api_sidecar" {
  count     = local.platform_stage && var.mise_sidecar_enabled ? 1 : 0
  type      = "Microsoft.Web/sites/sitecontainers@2024-04-01"
  name      = "mise-auth-sidecar"
  parent_id = azurerm_linux_web_app.main["api"].id
  body = {
    properties = {
      image        = "mcr.microsoft.com/entra-sdk/auth-sidecar:latest"
      isMain       = false
      authType     = "Anonymous"
      targetPort   = "8081"
      volumeMounts = []
      environmentVariables = [
        {
          name  = "ClientId"
          value = var.entra.client_id
        },
        {
          name  = "Audience"
          value = var.entra.audience
        },
        {
          name  = "TenantId"
          value = var.entra.home_tenant_id
        }
      ]
    }
  }
}

resource "azurerm_linux_function_app" "ingestion" {
  count                                          = local.platform_stage ? 1 : 0
  name                                           = "${local.prefix}-ingestion"
  resource_group_name                            = local.rg
  location                                       = var.location
  service_plan_id                                = azurerm_service_plan.apps[0].id
  storage_account_name                           = azapi_resource.function_storage[0].name
  storage_uses_managed_identity                  = true
  content_share_force_disabled                   = true
  enabled                                        = var.ingestion_enabled
  https_only                                     = true
  public_network_access_enabled                  = true
  virtual_network_subnet_id                      = var.hybrid_private_data_enabled ? azurerm_subnet.app_service_integration[0].id : null
  builtin_logging_enabled                        = false
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false
  tags                                           = local.tags
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.identity["ingestion"].id]
  }
  app_settings = merge(local.control_settings, {
    AIFLUX_CATALOG_PATH                       = var.ingestion_container_image != "" ? "/home/site/wwwroot/gateway/catalog/dev-models.json" : "/home/site/wwwroot/gateway/catalog/models.json"
    AIFLUX_CATALOG_CONFIGURED                 = tostring(var.ingestion_enabled && var.dev_catalog_accepted)
    AIFLUX_INGESTION_START_AT                 = var.ingestion_start_at
    "AzureWebJobs.ingest_usage.Disabled"      = tostring(!var.ingestion_timer_enabled)
    WEBSITES_ENABLE_APP_SERVICE_STORAGE       = var.ingestion_container_image == "" ? "true" : "false"
    AZURE_CLIENT_ID                           = azurerm_user_assigned_identity.identity["ingestion"].client_id
    FUNCTIONS_WORKER_RUNTIME                  = "python"
    AzureWebJobsScriptRoot                    = "/home/site/wwwroot"
    AzureWebJobsStorage__credential           = "managedidentity"
    AzureWebJobsStorage__clientId             = azurerm_user_assigned_identity.identity["ingestion"].client_id
    AzureWebJobsStorage__blobServiceUri       = "https://${azapi_resource.function_storage[0].name}.blob.core.windows.net"
    AzureWebJobsStorage__queueServiceUri      = "https://${azapi_resource.function_storage[0].name}.queue.core.windows.net"
    AzureWebJobsStorage__tableServiceUri      = "https://${azapi_resource.function_storage[0].name}.table.core.windows.net"
    APPLICATIONINSIGHTS_AUTHENTICATION_STRING = "Authorization=AAD;ClientId=${azurerm_user_assigned_identity.identity["ingestion"].client_id}"
  })
  site_config {
    ip_restriction_default_action     = "Deny"
    scm_use_main_ip_restriction       = true
    scm_ip_restriction_default_action = "Deny"
    ip_restriction {
      name       = "reviewed-operator"
      priority   = 100
      action     = "Allow"
      ip_address = "${var.operator_ip}/32"
    }
    always_on                                     = true
    minimum_tls_version                           = "1.2"
    scm_minimum_tls_version                       = "1.2"
    ftps_state                                    = "Disabled"
    application_insights_connection_string        = azurerm_application_insights.main.connection_string
    container_registry_use_managed_identity       = var.ingestion_container_image != ""
    container_registry_managed_identity_client_id = var.ingestion_container_image != "" ? azurerm_user_assigned_identity.identity["ingestion"].client_id : null
    dynamic "application_stack" {
      for_each = var.ingestion_container_image == "" ? [true] : []
      content {
        python_version = "3.11"
      }
    }
    dynamic "application_stack" {
      for_each = var.ingestion_container_image != "" ? [true] : []
      content {
        docker {
          registry_url = "https://${split("/", var.ingestion_container_image)[0]}"
          image_name   = "${split("@sha256:", local.ingestion_image_repository)[0]}@sha256"
          image_tag    = split("@sha256:", var.ingestion_container_image)[1]
        }
      }
    }
  }
  lifecycle {
    precondition {
      condition     = !var.ingestion_timer_enabled || var.ingestion_enabled
      error_message = "The ingestion timer requires an enabled, verified Function."
    }
    precondition {
      condition     = !var.ingestion_enabled || (var.dev_catalog_accepted && var.ingestion_container_image != "" && var.ingestion_start_at != "")
      error_message = "Ingestion requires a verified immutable image, accepted dev catalog and explicit activation cutoff."
    }
  }
  depends_on = [azurerm_role_assignment.function_storage]
}
