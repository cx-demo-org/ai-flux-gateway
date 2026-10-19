mock_provider "azurerm" {
  override_during = plan
  mock_data "azurerm_resource_group" {
    defaults = {
      id   = "/subscriptions/aa28274d-fea0-46d4-b9c8-30f3ef0a0e52/resourceGroups/IDS-TOKEN-EXCHANGE-POC"
      name = "IDS-TOKEN-EXCHANGE-POC"
    }
  }
  mock_data "azurerm_client_config" {
    defaults = {
      subscription_id = "aa28274d-fea0-46d4-b9c8-30f3ef0a0e52"
      tenant_id       = "00000000-0000-0000-0000-000000000001"
    }
  }
  mock_resource "azurerm_api_management" {
    defaults = {
      id = "/subscriptions/aa28274d-fea0-46d4-b9c8-30f3ef0a0e52/resourceGroups/IDS-TOKEN-EXCHANGE-POC/providers/Microsoft.ApiManagement/service/proj-ids-poc-apim"
    }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/aa28274d-fea0-46d4-b9c8-30f3ef0a0e52/resourceGroups/IDS-TOKEN-EXCHANGE-POC/providers/Microsoft.ManagedIdentity/userAssignedIdentities/gateway"
      client_id    = "00000000-0000-0000-0000-000000000002"
      principal_id = "00000000-0000-0000-0000-000000000003"
    }
  }
}

mock_provider "azapi" {}

run "foundation_only" {
  command = plan
  variables {
    deployment_approved = true
  }

  assert {
    condition     = azurerm_api_management.main.sku_name == "Developer_1" && length(azurerm_container_registry.main) == 1
    error_message = "Customer foundation must provision Developer APIM and one dedicated registry."
  }
  assert {
    condition     = !azurerm_key_vault.main.public_network_access_enabled && !var.sql_public_network_access_enabled && !var.function_storage_public_network_access_enabled
    error_message = "Customer private-data intent must not be weakened."
  }
  assert {
    condition     = length(azurerm_linux_web_app.main) == 0 && length(azurerm_linux_function_app.ingestion) == 0 && length(azurerm_mssql_server.main) == 0 && length(azurerm_virtual_network.main) == 0 && length(azurerm_private_endpoint.data) == 0
    error_message = "Application, SQL and networking must remain deferred without identity prerequisites."
  }
  assert {
    condition     = !var.dev_openai_inference_enabled && !var.dev_unified_inference_enabled && !var.dev_direct_portals_enabled && !var.dev_catalog_accepted && var.entra == null && var.sql_admin == null
    error_message = "Foundation must not require manual app registrations or attest runtime acceptance."
  }
}