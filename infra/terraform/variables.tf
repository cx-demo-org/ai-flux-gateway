variable "subscription_id" {
  type = string
}

variable "resource_group_name" {
  description = "Existing resource group; ownership stays outside this stack."
  type        = string
}

variable "location" {
  description = "Gateway region, not inferred from resource group metadata."
  type        = string
}

variable "sql_location" {
  description = "Azure SQL server/database region; defaults effectively to location when unset."
  type        = string
  default     = null
  nullable    = true
}

variable "name_prefix" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,18}$", var.name_prefix))
    error_message = "Use 3-19 lowercase letters/digits/hyphens starting with a letter."
  }
}

variable "deployment_approved" {
  description = "Explicit cost/config approval. Does NOT enable inference."
  type        = bool
  default     = false
}

variable "deployment_stage" {
  description = "APIM/protection, prerequisites, authenticated platform, HTTP-only edge-bootstrap, operator-only HTTPS edge-candidate, then public-edge after live gates."
  type        = string
  default     = "apim"
  validation {
    condition     = contains(["apim", "prerequisites", "platform", "edge-bootstrap", "edge-candidate", "public-edge"], var.deployment_stage)
    error_message = "deployment_stage must be apim, prerequisites, platform, edge-bootstrap, edge-candidate, or public-edge."
  }
}

variable "public_edge_live_gates_approved" {
  description = "Operator attestation that app access restrictions, Entra authorization, SQL connectivity, DNS, TLS, WAF and backend acceptance are recorded; does not enable inference."
  type        = bool
  default     = false
}

variable "acme_http01_enabled" {
  description = "Serve only exact public ACME key authorizations from /home; disabled unless performing issuance or an approved renewal job."
  type        = bool
  default     = false
}

variable "app_gateway_existing_nsg_name" {
  description = "Existing governance-attached AppGW subnet NSG; preserve its association/rules and add only named AIFLUX ingress rules."
  type        = string
  default     = null
}

variable "publisher_email" {
  type = string
}

variable "protection_language_enabled" {
  description = "Provision mandatory Language/PII dependency. Set false only to defer an Azure entitlement failure; inference and public-edge release remain blocked."
  type        = bool
  default     = true
}

variable "key_vault_public_network_access_enabled" {
  description = "Desired vault public access, subject to governance. Do not repeatedly enable a policy-disabled vault."
  type        = bool
  default     = true
}

variable "function_storage_public_network_access_enabled" {
  description = "Desired Function-storage public access, subject to governance. A policy-disabled endpoint blocks Function readiness."
  type        = bool
  default     = true
}

variable "create_container_registry" {
  description = "Create a dedicated authenticated Basic dev ACR in this state; adds registry and remote build costs."
  type        = bool
  default     = false
}

variable "sql_enabled" {
  description = "Provision approved SQL server/database. False explicitly defers regional entitlement failure in prerequisite stages only."
  type        = bool
  default     = true
  validation {
    condition     = var.sql_enabled || !contains(["platform", "edge-bootstrap", "edge-candidate", "public-edge"], var.deployment_stage)
    error_message = "Runtime platform/edge deployment requires SQL; a regional SQL blocker may only be deferred in prerequisite stages."
  }
}

variable "sql_public_network_access_enabled" {
  description = "Whether Azure SQL permits its public network interface. Leave false when platform governance keeps it disabled."
  type        = bool
  default     = true
}

variable "hybrid_private_data_enabled" {
  description = "Approved private endpoints for SQL, Key Vault and Function blob/queue/table storage only; public apps/APIM/Foundry remain unchanged."
  type        = bool
  default     = false
  validation {
    condition = !var.hybrid_private_data_enabled || (
      !var.sql_public_network_access_enabled &&
      !var.key_vault_public_network_access_enabled &&
      !var.function_storage_public_network_access_enabled &&
      var.sql_enabled &&
      can(cidrhost(var.network.private_endpoint_subnet, 0)) &&
      can(cidrhost(var.network.app_service_integration_subnet, 0))
    )
    error_message = "Hybrid data access requires SQL enabled, all three data services public-disabled, and valid private endpoint/integration subnet CIDRs."
  }
}

variable "private_sql_connectivity_accepted" {
  description = "Live API/Function SQL managed-identity access and database migrations accepted through the private endpoint; required for hybrid public-edge release."
  type        = bool
  default     = false
}

variable "gateway_origin_hostname" {
  description = "Candidate public HTTPS gateway hostname used to build/configure the platform before edge release; not a live endpoint or release attestation."
  type        = string
  default     = ""
  validation {
    condition     = !contains(["platform", "edge-bootstrap", "edge-candidate", "public-edge"], var.deployment_stage) || can(regex("^[a-z0-9][a-z0-9.-]+\\.[a-z]{2,}$", var.gateway_origin_hostname))
    error_message = "Platform configuration requires the candidate public gateway hostname (without scheme/path)."
  }
}

variable "entra" {
  description = "Existing registrations only; no Entra tenant/application is created."
  default     = null
  type = object({
    audience            = string
    client_id           = string
    home_tenant_id      = string
    bootstrap_object_id = string
  })
  validation {
    condition = contains(["platform", "edge-bootstrap", "edge-candidate", "public-edge"], var.deployment_stage) ? (
      var.entra == null ? false : (
        length(trimspace(var.entra.audience)) > 0 &&
        length(trimspace(var.entra.client_id)) > 0 &&
        length(trimspace(var.entra.home_tenant_id)) > 0 &&
        length(trimspace(var.entra.bootstrap_object_id)) > 0
      )
    ) : true
    error_message = "The platform stages require valid existing Entra audience, client, tenant, and bootstrap object IDs."
  }
}

variable "sql_admin" {
  description = "Existing Entra SQL administrator user/group/service principal; a user is suitable only for developer bootstrap."
  default     = null
  type = object({
    login     = string
    object_id = string
    tenant_id = string
  })
  validation {
    condition = contains(["prerequisites", "platform", "edge-bootstrap", "edge-candidate", "public-edge"], var.deployment_stage) && var.sql_enabled ? (
      var.sql_admin == null ? false : (
        length(trimspace(var.sql_admin.login)) > 0 &&
        length(trimspace(var.sql_admin.object_id)) > 0 &&
        length(trimspace(var.sql_admin.tenant_id)) > 0
      )
    ) : true
    error_message = "The platform stages require the existing Entra SQL administrator login, object ID, and tenant ID."
  }
}

variable "network" {
  description = "Existing unpeered VNet with a dedicated App Gateway subnet and optional hybrid private-data and App Service integration subnets."
  type = object({
    address_space                  = string
    app_gateway_subnet             = string
    private_endpoint_subnet        = optional(string)
    app_service_integration_subnet = optional(string)
  })
  validation {
    condition = alltrue([
      can(cidrhost(var.network.address_space, 0)),
      can(cidrhost(var.network.app_gateway_subnet, 0)),
    ])
    error_message = "Provide valid CIDR ranges for the isolated VNet and dedicated Application Gateway subnet."
  }
}

variable "operator_ip" {
  description = "Reviewed current public egress IPv4 for local migrations, deployment and health checks; exact /32 only, required for platform stages."
  type        = string
  default     = null
  validation {
    condition = var.operator_ip == null ? !contains(["prerequisites", "platform", "edge-bootstrap", "edge-candidate", "public-edge"], var.deployment_stage) : try(
      can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$", var.operator_ip)) &&
      cidrhost("${var.operator_ip}/32", 0) == var.operator_ip &&
      tonumber(split(".", var.operator_ip)[0]) > 0 &&
      tonumber(split(".", var.operator_ip)[0]) < 224 &&
      !can(regex("^(10\\.|127\\.|169\\.254\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)", var.operator_ip)),
      false,
    )
    error_message = "Platform requires a reviewed public operator IPv4, without CIDR; wildcard/0.0.0.0, private, loopback and IPv6 addresses are forbidden."
  }
}

variable "sql_firewall_ipv4s" {
  description = "Reviewed exact App Service/Function possible outbound IPv4 addresses, keyed by stable rule names; capture outputs after platform creation, then re-plan platform before readiness/public-edge."
  type        = map(string)
  default     = {}
  validation {
    condition = alltrue([for name, ip in var.sql_firewall_ipv4s : try(
      can(regex("^[a-z0-9-]{1,100}$", name)) &&
      can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$", ip)) &&
      cidrhost("${ip}/32", 0) == ip &&
      tonumber(split(".", ip)[0]) > 0 &&
      tonumber(split(".", ip)[0]) < 224 &&
      !can(regex("^(10\\.|127\\.|169\\.254\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)", ip)),
      false,
    )])
    error_message = "SQL firewall rules require stable lowercase names and exact reviewed public IPv4 addresses; no wildcard/Azure-wide/0.0.0.0/CIDR/private rules."
  }
}

variable "edge" {
  description = "Operator-owned public DNS/certificate inputs; certificate contents are never read by Terraform."
  default     = null
  type = object({
    origin_hostname             = string
    dns_label                   = string
    certificate_secret_id       = optional(string, "")
    certificate_vault_id        = optional(string, "")
    app_gateway_timeout_seconds = number
    waf_body_limit_kb           = number
    waf_inspection_limit_kb     = number
    zones                       = list(string)
  })
  validation {
    condition = contains(["edge-bootstrap", "edge-candidate", "public-edge"], var.deployment_stage) ? (
      var.edge == null ? false : (
        var.edge.app_gateway_timeout_seconds >= 1 &&
        var.edge.app_gateway_timeout_seconds <= 240 &&
        floor(var.edge.app_gateway_timeout_seconds) == var.edge.app_gateway_timeout_seconds &&
        var.edge.waf_body_limit_kb >= 1 &&
        var.edge.waf_body_limit_kb <= 128 &&
        var.edge.waf_inspection_limit_kb >= 8 &&
        var.edge.waf_inspection_limit_kb <= 128 &&
        length(var.edge.zones) >= 2 &&
        length(toset(var.edge.zones)) == length(var.edge.zones) &&
        alltrue([for zone in var.edge.zones : contains(["1", "2", "3"], zone)]) &&
        length(trimspace(var.edge.origin_hostname)) > 0 &&
        (var.deployment_stage == "edge-bootstrap" || (
          can(regex("^https://[^/]+/secrets/[^/]+/?$", var.edge.certificate_secret_id)) &&
          length(trimspace(var.edge.certificate_vault_id)) > 0
        )) &&
        can(regex("^[a-z0-9]([a-z0-9-]{0,78}[a-z0-9])?$", var.edge.dns_label)) &&
        lower(var.edge.origin_hostname) == "${var.edge.dns_label}.${lower(var.location)}.cloudapp.azure.com"
      )
    ) : true
    error_message = "Edge stages require matching regional DNS, integer timeout 1-240s, WAF limits, and at least two zones; HTTPS stages require a versionless certificate secret."
  }
}

variable "apps" {
  description = "Reviewed immutable container references, no registry passwords."
  default     = {}
  type = map(object({
    image        = string
    registry_url = string
    port         = number
    health_path  = string
  }))
  validation {
    condition = !contains(["platform", "edge-bootstrap", "edge-candidate", "public-edge"], var.deployment_stage) ? true : (
      toset(keys(var.apps)) == toset(["api", "customer", "admin"]) &&
      alltrue([for app in values(var.apps) : can(regex("@sha256:[0-9a-f]{64}$", app.image)) && length(trimspace(app.registry_url)) > 0])
    )
    error_message = "The platform stages require SHA-256-pinned images and registry URLs for api/customer/admin."
  }
}

variable "registry_resource_id" {
  description = "Existing publicly reachable authenticated ACR unless create_container_registry is selected; app identities get AcrPull."
  type        = string
  default     = ""
  validation {
    condition     = !contains(["platform", "edge-bootstrap", "edge-candidate", "public-edge"], var.deployment_stage) || var.create_container_registry || length(trimspace(var.registry_resource_id)) > 0
    error_message = "The platform stages require an existing reviewed ACR resource ID."
  }
}

variable "app_service_sku" {
  type    = string
  default = ""
  validation {
    condition     = !contains(["prerequisites", "platform", "edge-bootstrap", "edge-candidate", "public-edge"], var.deployment_stage) || length(trimspace(var.app_service_sku)) > 0
    error_message = "Select and review an App Service plan SKU before the platform stages."
  }
}

variable "sql_sku" {
  type    = string
  default = ""
  validation {
    condition     = !contains(["prerequisites", "platform", "edge-bootstrap", "edge-candidate", "public-edge"], var.deployment_stage) || length(trimspace(var.sql_sku)) > 0
    error_message = "Select and review an Azure SQL SKU before the platform stages."
  }
}

variable "sql_express_vulnerability_assessment_enabled" {
  description = "Preserve the reviewed SQL express vulnerability assessment posture."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  type = number
}

variable "apim_sku" {
  description = "APIM tier: BasicV2 (default) or Developer (non-production, no SLA, capacity must be 1)."
  type        = string
  default     = "BasicV2"
  validation {
    condition     = contains(["BasicV2", "Developer"], var.apim_sku)
    error_message = "apim_sku must be BasicV2 or Developer."
  }
}

variable "apim_capacity" {
  type = number
  validation {
    condition     = var.apim_capacity >= 1 && var.apim_capacity <= 10 && floor(var.apim_capacity) == var.apim_capacity
    error_message = "Capacity must be an integer from 1 to 10; Developer allows only 1. Quota/region still need validation."
  }
  validation {
    condition     = var.apim_sku != "Developer" || var.apim_capacity == 1
    error_message = "Developer tier supports capacity 1 only."
  }
}

variable "dev_openai_inference_enabled" {
  description = "Enable only the isolated, subscription-required text-only development API after verified deployment and policy prerequisites. Does not publish the production product."
  type        = bool
  default     = false
}

variable "dev_unified_inference_enabled" {
  description = "User-approved guarded text adapter, not the native unified API. Requires verified OpenAI prerequisites and deployed Haiku 5.5 in the primary Foundry account."
  type        = bool
  default     = false
}

variable "dev_direct_portals_enabled" {
  description = "Approved temporary public App Service origins with Entra authorization; SCM stays operator-restricted and private data stays private."
  type        = bool
  default     = false
  validation {
    condition     = !var.dev_direct_portals_enabled || (var.dev_unified_inference_enabled && var.deployment_stage != "public-edge")
    error_message = "Direct development portals require the guarded adapter and cannot be used as public-edge release acceptance."
  }
}

variable "dev_price_bootstrap_enabled" {
  description = "Explicit one-off import of reviewed dev prices using the API's existing private SQL identity; disable after verification."
  type        = bool
  default     = false
  validation {
    condition     = !var.dev_price_bootstrap_enabled || (var.dev_direct_portals_enabled && var.dev_catalog_accepted)
    error_message = "Development price bootstrap requires the accepted development catalog and direct development deployment."
  }
}

variable "dev_portal_origins" {
  description = "Exact HTTPS customer/admin App Service origins for development CORS; no wildcard."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for origin in var.dev_portal_origins : can(regex("^https://[a-z0-9-]+\\.azurewebsites\\.net$", origin))]) && length(distinct(var.dev_portal_origins)) == length(var.dev_portal_origins)
    error_message = "Development CORS origins must be distinct exact HTTPS App Service origins without paths."
  }

}

variable "dev_catalog_accepted" {
  description = "Enable the development catalog only after live guarded completions for both providers; does not enable production or ingestion."
  type        = bool
  default     = false
  validation {
    condition     = !var.dev_catalog_accepted || var.dev_direct_portals_enabled
    error_message = "Development catalog acceptance requires the direct-origin guarded development deployment."
  }
}

variable "ingestion_enabled" {
  description = "Enable the verified usage Function only with an immutable container, accepted catalog and explicit activation cutoff."
  type        = bool
  default     = false
}

variable "ingestion_timer_enabled" {
  description = "Enable timer only after Function runtime readiness is verified."
  type        = bool
  default     = false
}

variable "ingestion_container_image" {
  description = "Immutable ingestion Function container image, including SQL Server ODBC Driver 18."
  type        = string
  default     = ""
  validation {
    condition     = var.ingestion_container_image == "" || can(regex("^.+@sha256:[0-9a-f]{64}$", var.ingestion_container_image))
    error_message = "Ingestion container must use an immutable sha256 digest."
  }
}

variable "ingestion_start_at" {
  description = "Explicit UTC activation cutoff for new ingestion; historical replay is a separate operation."
  type        = string
  default     = ""
  validation {
    condition     = var.ingestion_start_at == "" || can(formatdate("YYYY", var.ingestion_start_at))
    error_message = "Ingestion cutoff must be an RFC3339 timestamp."
  }
}

variable "dev_openai_rpm_limit" {
  description = "Conservative per-subscription/per-model request ceiling for the single-subscriber development API."
  type        = number
  default     = 2
  validation {
    condition     = var.dev_openai_rpm_limit >= 1 && var.dev_openai_rpm_limit <= 2 && floor(var.dev_openai_rpm_limit) == var.dev_openai_rpm_limit
    error_message = "The guarded development API permits at most two requests per minute per subscription/model."
  }
}

variable "dev_openai_tpm_limit" {
  description = "Conservative APIM-estimated token-per-minute ceiling per subscription/model for the development API."
  type        = number
  default     = 2048
  validation {
    condition     = var.dev_openai_tpm_limit >= 1 && var.dev_openai_tpm_limit <= 2048 && floor(var.dev_openai_tpm_limit) == var.dev_openai_tpm_limit
    error_message = "The guarded development API permits at most 2048 estimated tokens per minute per subscription/model."
  }
}

variable "dev_openai_max_completion_tokens" {
  description = "Maximum max_completion_tokens accepted by the single-subscriber development API."
  type        = number
  default     = 64
  validation {
    condition     = var.dev_openai_max_completion_tokens >= 1 && var.dev_openai_max_completion_tokens <= 64 && floor(var.dev_openai_max_completion_tokens) == var.dev_openai_max_completion_tokens
    error_message = "The guarded development API permits at most 64 completion tokens per request."
  }
}

variable "dev_openai_content_safety_threshold" {
  description = "Explicit IDS-approved severity threshold used for each Content Safety harm category. Required before the development inference gate can be enabled."
  type        = number
  default     = null
  nullable    = true
  validation {
    condition     = var.dev_openai_content_safety_threshold == null || (var.dev_openai_content_safety_threshold >= 0 && var.dev_openai_content_safety_threshold <= 7 && floor(var.dev_openai_content_safety_threshold) == var.dev_openai_content_safety_threshold)
    error_message = "The explicit Content Safety threshold must be an integer from 0 (most restrictive) through 7 (least restrictive)."
  }
}

variable "dev_unified_tpm_limit" {
  description = "Approved token-per-minute ceiling per subscription/model for the guarded playground adapter."
  type        = number
  default     = 2048
  validation {
    condition     = var.dev_unified_tpm_limit >= 1 && var.dev_unified_tpm_limit <= 20000 && floor(var.dev_unified_tpm_limit) == var.dev_unified_tpm_limit
    error_message = "The guarded playground adapter permits at most 20000 tokens per minute per subscription/model."
  }
}

variable "dev_unified_max_completion_tokens" {
  description = "Approved completion-token ceiling for the guarded playground adapter; provider limits still apply."
  type        = number
  default     = 64
  validation {
    condition     = var.dev_unified_max_completion_tokens >= 1 && var.dev_unified_max_completion_tokens <= 100000 && floor(var.dev_unified_max_completion_tokens) == var.dev_unified_max_completion_tokens
    error_message = "The guarded playground adapter permits at most 100000 completion tokens per request."
  }
}

variable "catalog_container_path" {
  description = "Read-only catalog bundled in API/Function artifacts."
  type        = string
  default     = "/app/gateway/catalog/models.json"
}

variable "mise_sidecar_enabled" {
  description = "Enable Microsoft Entra ID MISE authentication sidecar container on the control plane API."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
