resource "azurerm_api_management" "main" {
  name                          = local.apim_name
  location                      = var.location
  resource_group_name           = local.rg
  publisher_name                = "Singtel IDS"
  publisher_email               = var.publisher_email
  sku_name                      = "${var.apim_sku}_${var.apim_capacity}"
  virtual_network_type          = "None"
  public_network_access_enabled = true
  tags                          = local.tags
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.identity["gateway"].id]
  }
  depends_on = [terraform_data.approval]
}

resource "azurerm_api_management_product" "main" {
  product_id            = "aiflux"
  api_management_name   = azurerm_api_management.main.name
  resource_group_name   = local.rg
  display_name          = "AIFLUX (native validation pending)"
  subscription_required = true
  approval_required     = true
  subscriptions_limit   = 1000
  published             = false
}

resource "azurerm_api_management_api" "blocked" {
  name                  = "aiflux-native-validation-pending"
  resource_group_name   = local.rg
  api_management_name   = azurerm_api_management.main.name
  revision              = "1"
  display_name          = "AIFLUX - disabled"
  path                  = "v1"
  protocols             = ["https"]
  subscription_required = true
}

resource "azurerm_api_management_api_operation" "blocked" {
  for_each            = { models = { method = "GET", path = "/models" }, chat = { method = "POST", path = "/chat/completions" } }
  operation_id        = each.key
  api_name            = azurerm_api_management_api.blocked.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = local.rg
  display_name        = each.key
  method              = each.value.method
  url_template        = each.value.path
}

resource "azurerm_api_management_product_api" "blocked" {
  api_name            = azurerm_api_management_api.blocked.name
  product_id          = azurerm_api_management_product.main.product_id
  api_management_name = azurerm_api_management.main.name
  resource_group_name = local.rg
}

locals {
  dev_aliases = toset(["gpt-5-nano"])
  dev_model_backends = {
    "gpt-5-nano-${var.location}" = {
      alias    = "gpt-5-nano"
      region   = var.location
      endpoint = "https://${local.prefix}-foundry.openai.azure.com"
    }
  }
  dev_model_pools = {
    for alias in local.dev_aliases : alias => {
      backends = {
        for key, backend in local.dev_model_backends : key => backend
        if backend.alias == alias
      }
    }
  }
}

data "azapi_resource" "dev_nano" {
  count                  = var.dev_openai_inference_enabled ? 1 : 0
  type                   = "Microsoft.CognitiveServices/accounts/deployments@2025-06-01"
  parent_id              = azapi_resource.ai["language"].id
  name                   = "gpt-5-nano"
  response_export_values = ["properties"]
}

resource "terraform_data" "dev_openai_gate" {
  count = var.dev_openai_inference_enabled ? 1 : 0

  input = {
    aliases       = sort(tolist(local.dev_aliases))
    backend_count = length(local.dev_model_backends)
  }

  lifecycle {
    precondition {
      condition = (
        data.azapi_resource.dev_nano[0].output.properties.provisioningState == "Succeeded" &&
        data.azapi_resource.dev_nano[0].output.properties.model.name == "gpt-5-nano" &&
        var.dev_openai_content_safety_threshold != null
      )
      error_message = "The guarded API requires a succeeded gpt-5-nano deployment in the gateway Foundry account and an explicitly configured content-safety threshold."
    }
  }
}

resource "azurerm_api_management_api" "dev_openai" {
  name                  = "aiflux-dev-openai"
  resource_group_name   = local.rg
  api_management_name   = azurerm_api_management.main.name
  revision              = "1"
  display_name          = "AIFLUX guarded development OpenAI API"
  description           = "Subscriber-required text-only development API. Production catalog and product remain disabled."
  path                  = "dev/v1"
  service_url           = "https://aiflux-disabled.invalid"
  protocols             = ["https"]
  subscription_required = true
  subscription_key_parameter_names {
    header = "Ocp-Apim-Subscription-Key"
    query  = "subscription-key"
  }
  import {
    content_format = "openapi+json"
    content_value  = file("${path.module}/../../gateway/openapi-dev.json")
  }
}

resource "azapi_resource" "dev_openai_policy" {
  type      = "Microsoft.ApiManagement/service/apis/policies@2022-08-01"
  parent_id = replace(azurerm_api_management_api.dev_openai.id, ";rev=1", "")
  name      = "policy"
  body = {
    properties = {
      format = "rawxml"
      value = var.dev_openai_inference_enabled ? templatefile("${path.module}/../../gateway/policies/dev-openai.xml.tftpl", {
        language_endpoint       = trimsuffix(azapi_resource.ai["language"].output.properties.endpoint, "/")
        gateway_identity_client = azurerm_user_assigned_identity.identity["gateway"].client_id
        tpm_limit               = var.dev_openai_tpm_limit
        rpm_limit               = var.dev_openai_rpm_limit
        completion_token_limit  = var.dev_openai_max_completion_tokens
        safety_threshold        = var.dev_openai_content_safety_threshold
        safety_backend_id       = azapi_resource.dev_content_safety_backend[0].name
        unified                 = false
        product_id              = azurerm_api_management_product.dev_openai[0].product_id
        cors_origins            = []
        model_list              = jsonencode({ object = "list", data = [for alias in sort(tolist(local.dev_aliases)) : { id = alias, object = "model", owned_by = "aiflux" }] })
      }) : file("${path.module}/../../gateway/policies/disabled.xml")
    }
  }
  depends_on = [
    terraform_data.dev_openai_gate,
    azapi_resource.dev_model_pool,
    azapi_resource.dev_content_safety_backend,
    azurerm_role_assignment.ai_user
  ]
}

resource "azapi_resource" "closed_policy" {
  type      = "Microsoft.ApiManagement/service/policies@2022-08-01"
  parent_id = azurerm_api_management.main.id
  name      = "policy"
  body = {
    properties = {
      format = "rawxml"
      value = templatefile("${path.module}/../../gateway/policies/global-dev-gate.xml.tftpl", {
        dev_api_id      = azurerm_api_management_api.dev_openai.name
        enabled         = var.dev_openai_inference_enabled
        unified_enabled = var.dev_unified_inference_enabled
      })
    }
  }
  depends_on = [azapi_resource.dev_openai_policy, azapi_resource.dev_unified_policy]
}

resource "azapi_resource" "blocked_api_policy" {
  type      = "Microsoft.ApiManagement/service/apis/policies@2022-08-01"
  parent_id = replace(azurerm_api_management_api.blocked.id, ";rev=1", "")
  name      = "policy"
  body = {
    properties = {
      format = "rawxml"
      value  = file("${path.module}/../../gateway/policies/disabled.xml")
    }
  }
}

resource "azurerm_api_management_product" "dev_openai" {
  count                 = var.dev_openai_inference_enabled ? 1 : 0
  product_id            = "aiflux-dev-openai"
  api_management_name   = azurerm_api_management.main.name
  resource_group_name   = local.rg
  display_name          = "AIFLUX single-subscriber development text API"
  description           = "Approved subscriptions only; text-only OpenAI chat; strict request, token, and content-safety gates."
  subscription_required = true
  approval_required     = true
  subscriptions_limit   = 1
  published             = true
  depends_on            = [terraform_data.dev_openai_gate]
}

resource "azurerm_api_management_product_api" "dev_openai" {
  count               = var.dev_openai_inference_enabled ? 1 : 0
  api_name            = azurerm_api_management_api.dev_openai.name
  product_id          = azurerm_api_management_product.dev_openai[0].product_id
  api_management_name = azurerm_api_management.main.name
  resource_group_name = local.rg
}

resource "azapi_resource" "dev_model_backend" {
  for_each  = var.dev_openai_inference_enabled ? local.dev_model_backends : {}
  type      = "Microsoft.ApiManagement/service/backends@2024-05-01"
  parent_id = azurerm_api_management.main.id
  name      = "dev-${replace(each.key, ".", "-")}"
  body = {
    properties = {
      protocol    = "http"
      url         = "${trimsuffix(each.value.endpoint, "/")}/openai/v1"
      description = "Verified ${each.value.alias} ${each.value.region} Azure OpenAI v1 endpoint."
      tls = {
        validateCertificateChain = true
        validateCertificateName  = true
      }
      circuitBreaker = {
        rules = [{
          name = "server-errors"
          failureCondition = {
            count    = 3
            interval = "PT1M"
            statusCodeRanges = [{
              min = 500
              max = 599
            }]
          }
          tripDuration     = "PT1M"
          acceptRetryAfter = true
        }]
      }
    }
  }
  depends_on = [terraform_data.dev_openai_gate]
}

resource "azapi_resource" "dev_model_pool" {
  for_each  = var.dev_openai_inference_enabled ? local.dev_model_pools : {}
  type      = "Microsoft.ApiManagement/service/backends@2024-05-01"
  parent_id = azurerm_api_management.main.id
  name      = "dev-${replace(each.key, ".", "-")}-pool"
  body = {
    properties = {
      type = "Pool"
      pool = {
        services = [
          for backend_key in sort(keys(each.value.backends)) : {
            id       = azapi_resource.dev_model_backend[backend_key].id
            priority = 1
            weight   = 1
          }
        ]
      }
    }
  }
  depends_on = [azapi_resource.dev_model_backend]
}

resource "azapi_resource" "dev_content_safety_backend" {
  count                     = var.dev_openai_inference_enabled ? 1 : 0
  type                      = "Microsoft.ApiManagement/service/backends@2024-06-01-preview"
  parent_id                 = azurerm_api_management.main.id
  name                      = "aiflux-dev-content-safety"
  schema_validation_enabled = false
  body = {
    properties = {
      protocol    = "http"
      url         = trimsuffix(azapi_resource.ai["safety"].output.properties.endpoint, "/")
      description = "Azure AI Content Safety backend for original, redacted, and completion policy checks."
      tls = {
        validateCertificateChain = true
        validateCertificateName  = true
      }
      credentials = {
        managedIdentity = {
          resource = "https://cognitiveservices.azure.com"
          clientId = azurerm_user_assigned_identity.identity["gateway"].client_id
        }
      }
    }
  }
}

resource "azapi_resource" "monitor_logger" {
  type      = "Microsoft.ApiManagement/service/loggers@2024-05-01"
  parent_id = azurerm_api_management.main.id
  name      = "azuremonitor"
  body = {
    properties = {
      loggerType  = "azureMonitor"
      description = "Metadata only; no prompts, completions or sensitive headers."
      isBuffered  = false
    }
  }
}

resource "azapi_resource" "monitor_diagnostic" {
  type      = "Microsoft.ApiManagement/service/diagnostics@2025-09-01-preview"
  parent_id = azurerm_api_management.main.id
  name      = "azuremonitor"
  body = {
    properties = {
      loggerId           = azapi_resource.monitor_logger.id
      alwaysLog          = "allErrors"
      sampling           = { samplingType = "fixed", percentage = 100 }
      logClientIp        = false
      verbosity          = "information"
      largeLanguageModel = { logs = "enabled" }
      frontend = {
        request = {
          headers = []
          body    = { bytes = 0 }
          dataMasking = {
            queryParams = [
              { mode = "Hide", value = "*" },
            ]
          }
        }
        response = { headers = ["x-aiflux-model", "x-aiflux-provider", "x-aiflux-region"], body = { bytes = 0 } }
      }
      backend = {
        request = {
          headers = []
          body    = { bytes = 0 }
          dataMasking = {
            queryParams = [{ mode = "Hide", value = "*" }]
          }
        }
        response = { headers = [], body = { bytes = 0 } }
      }
    }
  }
}

resource "azurerm_monitor_diagnostic_setting" "apim" {
  name                           = "${local.prefix}-apim-metadata"
  target_resource_id             = azurerm_api_management.main.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.main.id
  log_analytics_destination_type = "Dedicated"
  enabled_log {
    category = "GatewayLogs"
  }
  enabled_log {
    category = "GatewayLlmLogs"
  }
}
