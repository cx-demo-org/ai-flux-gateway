# AIFLUX deployment from Azure Cloud Shell

This guide describes the modified single-tenant, single-model **development** deployment in this repository. It is not a production deployment certification. Read the limitations and acceptance checks before provisioning customer resources.

## Scope and current limitations

- Main Terraform root: `infra/terraform`. Stages progress from `apim` to `platform`. Edge stages are outside this guide.
- The gateway is configured for `gpt-5-nano`, deployed in the stack's own `${name_prefix}-foundry` account. The separate `infra/models` root still describes the older model layout; do not apply it for this deployment.
- APIM Developer has no SLA and is for non-production only. Use an explicitly reviewed production architecture for customer production use.
- Direct development portals expose the portal/API App Service endpoints publicly. API authentication and tenant/member authorization remain enforced. This mode has no Application Gateway/WAF front end.
- The public-data lab route below uses exact SQL firewall addresses, not private endpoints. Obtain customer security approval; do not change an approved private-data architecture into public mode to get around a deployment problem.
- A previous chat smoke test succeeded, but subsequent product-subscription-key tests returned 401. Browser login, team subscription provisioning and chat must all pass in the customer environment before calling the deployment usable.
- The latest recorded Python test run had 204 passes and 6 failures in configuration/authentication tests. These failures have not been established as pre-existing. Investigate them before production release. Terraform mocked tests also need review against the changed networking and model layout.
- Some documentation, scripts, tests and branding retain original environment/model assumptions. Review them before reuse. Model prices in the development catalog are estimates, not verified customer billing rates.

## 1. Prerequisites and source

Use Azure Cloud Shell **Bash** and an authorized identity in the customer tenant. Required access includes creating the selected resources, custom roles and role assignments, creating Entra applications/service principals, and initializing SQL as the configured Entra SQL administrator. Directory permissions and subscription RBAC are separate.

```bash
git clone https://github.com/cx-demo-org/ai-flux-gateway.git
cd ai-flux-gateway
export REPO="$PWD"
export TF_DIR="$REPO/infra/terraform"

export SUB="<customer-subscription-id>"
export RG="rg-aiflux-dev"
export LOCATION="southeastasia"
export PREFIX="<unique-lowercase-prefix>"
export PUBLISHER_EMAIL="<customer-contact-email>"
az account set --subscription "$SUB"
az account show --query '{subscription:id,tenant:tenantId,user:user.name,state:state}' -o json
az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB?api-version=2022-12-01" \
  --query '{name:displayName,state:state}' -o json
az group create --subscription "$SUB" --name "$RG" --location "$LOCATION"
```

The prefix must satisfy `variables.tf` (3–19 lowercase letters/digits/hyphens, starting with a letter). Derived ACR, storage and Key Vault names must also be globally available. Review CIDRs for conflicts.

If Azure returns `ReadOnlyDisabledSubscription`, resolve the subscription warning/disablement before proceeding. The CLI account cache can disagree with the live ARM state. Do not repeatedly retry resource creation or bypass customer governance.

## 2. Files to customize

| File | Customer-specific change |
| --- | --- |
| `infra/scripts/bootstrap-entra.py` | On Linux change the subprocess executable `az.cmd` to `az`; supply the environment variables in section 5. |
| `infra/terraform/environments/customer.tfvars` | Create a new ignored input file; never reuse another environment's identity IDs, image digests, IPs or approval attestations. |
| `infra/terraform/backend.hcl` | Create a separate ignored backend configuration for the new customer state. |
| `infra/terraform/versions.tf` | Only if selecting a different backend type; do not lower provider/Terraform requirements as a workaround. |
| `gateway/catalog/dev-models.json` | Replace the existing lab backend URL, backend ID and region before building the API image. Keep the supported model alias `gpt-5-nano`. |
| `gateway/catalog/dev-prices.json` | Set the customer region, a reviewed effective date and verified applicable prices. |

Do not change `variables.tf` defaults for every customer. The repository's Terraform/policy code already contains changes for Developer tier, single-model routing and NSG-at-subnet-creation. Different models, external model accounts, edge networking or private-data designs need additional review and possibly code changes.

## 3. Terraform version and state

`versions.tf` currently requires Terraform **1.16.x**, AzureRM **5.9.0**, and AzAPI **2.13.0**. Use a verified Linux Terraform binary satisfying that requirement if Cloud Shell's installed version differs. Keep the committed provider lock file.

```bash
terraform version
```

The default backend type is `local`. For a temporary approved lab, store the repository/state on confirmed persistent, access-controlled Cloud Shell storage, back it up securely, and allow only one writer. Do not keep the sole state copy in an ephemeral session or `/tmp`.

Create `infra/terraform/backend.hcl` with a customer-specific absolute path, for example:

```hcl
path = "/home/<cloud-shell-user>/clouddrive/<customer>/aiflux.tfstate"
```

Confirm that the actual mount exists and persists before using that example. Terraform local state is not encrypted by Terraform and can contain sensitive resource data.

For sustained/customer use, prefer a separately reviewed Azure Storage backend with Entra authentication, encryption and locking. That requires changing `backend "local" {}` to `backend "azurerm" {}` in `versions.tf` and supplying the correct storage settings. `backend.hcl` cannot change backend type on its own. Migration of existing state requires a reviewed migration, not copying another customer's state or casually reinitializing it.

Never upload `.terraform`, state, plans, tfvars, environment files, tokens, certificate private keys or generated identity/evidence files to Git. Application/client IDs are identifiers, not secrets, but generated environment details should still remain outside source control.

## 4. Foundation: APIM, monitoring, protection and registry

Create `infra/terraform/environments/customer.tfvars` with reviewed values. Replace all placeholders before planning:

```hcl
subscription_id     = "<customer-subscription-id>"
resource_group_name = "rg-aiflux-dev"
location            = "southeastasia"
sql_location        = "southeastasia"
name_prefix         = "<unique-prefix>"
publisher_email     = "<customer-contact-email>"

deployment_stage         = "apim"
deployment_approved      = true
apim_sku                 = "Developer"
apim_capacity            = 1
log_retention_days       = 30
create_container_registry = true

network = {
  address_space      = "10.240.0.0/16"
  app_gateway_subnet = "10.240.1.0/24"
}

dev_openai_inference_enabled  = false
dev_unified_inference_enabled = false
dev_direct_portals_enabled    = false
dev_catalog_accepted          = false
dev_price_bootstrap_enabled   = false
ingestion_enabled             = false
```

Setting `deployment_approved` requires actual cost/configuration approval. It does not attest that inference or authentication has been tested.

```bash
terraform -chdir="$TF_DIR" init -backend-config=backend.hcl
terraform -chdir="$TF_DIR" validate
terraform -chdir="$TF_DIR" plan -input=false \
  -var-file=environments/customer.tfvars -out=foundation.tfplan
# Review the complete plan, then:
terraform -chdir="$TF_DIR" apply foundation.tfplan
```

### Existing default APIM global policy

APIM normally creates its default global policy automatically. If the first apply fails because `azapi_resource.closed_policy` already exists, preserve the partial state and import that exact policy after APIM has been created:

```bash
terraform -chdir="$TF_DIR" import \
  -var-file=environments/customer.tfvars azapi_resource.closed_policy \
  "/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$PREFIX-apim/policies/policy?api-version=2022-08-01"
```

Generate/review a new plan and apply the remainder. Do not apply the stale plan or recreate APIM. Cloud Shell Bash does not need the Git-for-Windows `MSYS_NO_PATHCONV` workaround.

## 5. Bootstrap customer Entra applications

In `infra/scripts/bootstrap-entra.py`, replace `"az.cmd"` with `"az"` for Cloud Shell. Run from the repository root. Set **all** overrides; the fallback values are for the original environment.

```bash
cd "$REPO"
export AIFLUX_PREFIX="$PREFIX"
export AIFLUX_TENANT_ID="$(az account show --subscription "$SUB" --query tenantId -o tsv)"
export AIFLUX_BOOTSTRAP_OBJECT_ID="$(az ad signed-in-user show --query id -o tsv)"
export AIFLUX_HOST="https://<approved-candidate-gateway-hostname>"
python3 infra/scripts/bootstrap-entra.py

export API_ID="$(jq -r '.applications.api.client_id' infra/terraform/live-identity.json)"
export CUSTOMER_ID="$(jq -r '.applications.customer.client_id' infra/terraform/live-identity.json)"
export ADMIN_ID="$(jq -r '.applications.admin.client_id' infra/terraform/live-identity.json)"
```

The script creates single-tenant API/customer/admin registrations and service principals, exposes `access_as_user`, configures SPA redirects/preauthorization, and assigns the bootstrap user's admin app role. It creates no client secrets. Database approval is a separate later step. Service-principal CLI sessions cannot use `az ad signed-in-user show`; review the operator/ownership workflow separately if not using an interactive user.

App Service's Authentication blade may be empty: this application uses browser MSAL and API token validation, not Easy Auth. Do not add a second authentication layer as a workaround. Sign in with an approved account in the customer tenant.

## 6. Update catalogs and build immutable images

Before building, edit `gateway/catalog/dev-models.json` so its nano backend uses:

- URL: `https://<prefix>-foundry.openai.azure.com/openai/v1`
- Region: the approved deployment region.
- Backend ID: a matching unique customer backend identifier.

Review prices separately. Updating a local catalog after the API image is built does not update the running API; rebuild it.

Use ACR remote builds; no Cloud Shell Docker daemon is required. Build arguments below are public configuration, never secrets.

```bash
cd "$REPO"
export ACR="$(terraform -chdir="$TF_DIR" output -json container_registry | jq -r '.name')"
export REGISTRY="$(terraform -chdir="$TF_DIR" output -json container_registry | jq -r '.login_server')"
export AUTH="https://login.microsoftonline.com/$AIFLUX_TENANT_ID"
export SCOPE="api://$API_ID/access_as_user"
export CONTROL="https://$PREFIX-api.azurewebsites.net/api"
export GATEWAY="https://$PREFIX-apim.azure-api.net/dev/llm/v1"
export TAG="customer-v1"

az acr build --subscription "$SUB" --registry "$ACR" \
  --image "aiflux/api:$TAG" --file services/control-plane/Dockerfile .

for COMPONENT in customer admin; do
  if [[ "$COMPONENT" == customer ]]; then CLIENT_ID="$CUSTOMER_ID"; else CLIENT_ID="$ADMIN_ID"; fi
  az acr build --subscription "$SUB" --registry "$ACR" \
    --image "aiflux/$COMPONENT:$TAG" --file "apps/$COMPONENT-portal/Dockerfile" \
    --build-arg "VITE_ENTRA_CLIENT_ID=$CLIENT_ID" \
    --build-arg "VITE_ENTRA_AUTHORITY=$AUTH" \
    --build-arg "VITE_API_SCOPE=$SCOPE" \
    --build-arg "VITE_CONTROL_API_URL=$CONTROL" \
    --build-arg "VITE_GATEWAY_URL=$GATEWAY" . || break
done

for COMPONENT in api customer admin; do
  echo "$COMPONENT"
  az acr repository show --subscription "$SUB" --name "$ACR" \
    --image "aiflux/$COMPONENT:$TAG" --query digest -o tsv
done
```

Check that **each build succeeded** before continuing. Pin the returned digest in `apps`; do not use mutable tags for deployment. `VITE_CONTROL_API_URL` must end in **`/api`**, and authority must target the customer tenant. Changing App Service environment variables does not replace these compiled Vite values.

## 7. Platform inputs and deployment

Change the existing `deployment_stage` assignment to `"platform"` in customer tfvars and add the following, replacing placeholders:

```hcl
gateway_origin_hostname = "<approved-candidate-gateway-hostname>"
operator_ip             = "<reviewed-current-public-ipv4>"
app_service_sku         = "B1"
sql_sku                 = "S0"

# Public-data development route only; obtain customer approval.
hybrid_private_data_enabled                    = false
sql_public_network_access_enabled              = true
key_vault_public_network_access_enabled        = true
function_storage_public_network_access_enabled = true

entra = {
  audience            = "<api-client-id>"
  client_id           = "<api-client-id>"
  home_tenant_id      = "<customer-tenant-id>"
  bootstrap_object_id = "<approved-admin-object-id>"
}
sql_admin = {
  login     = "<approved-entra-sql-admin-login>"
  object_id = "<sql-admin-object-id>"
  tenant_id = "<customer-tenant-id>"
}
apps = {
  api = {
    image = "aiflux/api@sha256:<api-digest>"
    registry_url = "https://<acr-login-server>"
    port = 8000
    health_path = "/health"
  }
  customer = {
    image = "aiflux/customer@sha256:<customer-digest>"
    registry_url = "https://<acr-login-server>"
    port = 8080
    health_path = "/"
  }
  admin = {
    image = "aiflux/admin@sha256:<admin-digest>"
    registry_url = "https://<acr-login-server>"
    port = 8080
    health_path = "/admin/"
  }
}
```

Use approved SKUs rather than copying lab sizing into production. The candidate gateway hostname is required by the current validation even though this guide does not deploy the edge. Do not advertise it as a live endpoint.

The image value deliberately omits the registry hostname: `registry_url` supplies it. Including the hostname twice caused container image-pull failures in the lab.

```bash
terraform -chdir="$TF_DIR" plan -input=false \
  -var-file=environments/customer.tfvars -out=platform.tfplan
# Review before applying.
terraform -chdir="$TF_DIR" apply platform.tfplan
terraform -chdir="$TF_DIR" output -json sql_required_outbound_ipv4s
```

Add the returned exact addresses to `sql_firewall_ipv4s` as a map in customer tfvars, then re-plan/re-apply. No `0.0.0.0`, broad ranges or Allow Azure Services rule is needed. Until direct-portal mode is enabled, App Service access is operator-restricted and portal-to-API integration is not yet ready.

For private data, stop and design the private execution route, endpoint DNS, NSGs and integration before proceeding; this repository's modified edge subnet does not make all other subnets policy-compliant automatically.

## 8. SQL schema, identities and initial administrator

Run migrations as the configured Entra SQL administrator from an approved SQL-connected environment with Python, `pyodbc` and ODBC Driver 18. Cloud Shell may lack the driver, package-install privileges or private network connectivity. If so use an approved runner; ACR image builds alone do not require the driver locally.

The API image includes Driver 18, but running migrations inside the API with its normal runtime identity will fail by design: runtime identities must not have schema/DDL permissions. `infra/sql/init-managed-identity.py` is a specialized private App Service initializer, not a generic Cloud Shell migration command.

On an approved operator runner, from the repo root:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install .
export AIFLUX_ENVIRONMENT=production
export AIFLUX_DATABASE_URL="mssql+pyodbc://@$PREFIX-sql.database.windows.net:1433/aiflux?driver=ODBC+Driver+18+for+SQL+Server&Encrypt=yes&TrustServerCertificate=no"
export AIFLUX_ENTRA_AUDIENCE="$API_ID"
export AIFLUX_ENTRA_CLIENT_ID="$API_ID"
export AIFLUX_HOME_TENANT_ID="$AIFLUX_TENANT_ID"
export AIFLUX_BOOTSTRAP_OBJECT_ID

alembic -c services/control-plane/alembic.ini upgrade head
```

Execute `infra/sql/bootstrap-identities.sql` as the SQL administrator with SQLCMD variables `API_CLIENT_ID` and `INGESTION_CLIENT_ID` set to the user-assigned managed identities' **client IDs**, not ARM principal object IDs. Retrieve these with `az identity show --subscription "$SUB" -g "$RG" -n "$PREFIX-api-identity" --query clientId -o tsv` and the corresponding ingestion identity. The SQL grants are DML-only for runtime.

Then run `aiflux-bootstrap` on the same operator runner. Confirm `alembic_version` is `0001`, both external users have the expected SIDs and restricted permissions, and the home organization/admin membership exists.

Temporary operator firewall rules must be exact-IP, tracked, and removed after migrations on both success and failure. HTTPS IP detection can differ from SQL TCP egress; diagnose the actual denied IP, never broaden the firewall to compensate.

## 9. Deploy and integrate gpt-5-nano

Check availability/quota in the selected region and customer subscription before creating the model. Review model/version availability rather than assuming the lab's choices are available everywhere.

```bash
az cognitiveservices usage list --subscription "$SUB" --location "$LOCATION" \
  --query "[?contains(name.value, 'gpt-5-nano')].{name:name.value,used:currentValue,limit:limit}" -o table

az cognitiveservices account deployment create --subscription "$SUB" \
  --resource-group "$RG" --name "$PREFIX-foundry" \
  --deployment-name gpt-5-nano --model-name gpt-5-nano \
  --model-version 2025-08-07 --model-format OpenAI \
  --sku-name GlobalStandard --sku-capacity <approved-capacity>
```

The model deployment above is CLI-managed; the main Terraform root reads it as a prerequisite, not as a managed deployment resource. Record its ownership and teardown responsibility. Do not run the old `infra/models` root as a substitute.

Enable the following in customer tfvars only after reviewing the exposure, safety threshold and limits:

```hcl
dev_openai_inference_enabled        = true
dev_unified_inference_enabled       = true
dev_direct_portals_enabled          = true
dev_catalog_accepted                = false
dev_price_bootstrap_enabled         = false
dev_openai_content_safety_threshold = 4
dev_unified_max_completion_tokens   = 2000
dev_unified_tpm_limit               = 20000
dev_portal_origins = [
  "https://<prefix>-customer.azurewebsites.net",
  "https://<prefix>-admin.azurewebsites.net",
]
```

Threshold 4 and these token limits are lab examples requiring customer approval. Nano needs a sufficient completion budget for reasoning as well as visible output; 64 may produce no visible answer. PII inspection and Content Safety remain required. Do not bypass checks merely to pass a smoke test.

Plan/review/apply again. Ensure the gateway identity actually has the required OpenAI inference data-plane permissions, and verify a guarded completion using an approved product subscription. The generic AI-service role alone must not be treated as proof that inference is authorized.

After live model, safety and subscription checks pass, set `dev_catalog_accepted = true` and re-apply. To seed reviewed prices, temporarily enable `dev_price_bootstrap_enabled`, verify the import, then disable it and re-apply so startup no longer imports prices repeatedly. Do not attest acceptance before successful tests.

## 10. Browser endpoints and acceptance

- Customer: `https://<prefix>-customer.azurewebsites.net/`
- Administrator: `https://<prefix>-admin.azurewebsites.net/admin/`
- API liveness: `https://<prefix>-api.azurewebsites.net/health`
- API SQL readiness: `https://<prefix>-api.azurewebsites.net/ready`
- Gateway: `https://<prefix>-apim.azure-api.net/dev/llm/v1`

Verify all of the following before handover:

1. Subscription accepts writes; APIM is `Succeeded`, not Stopped/Activating; all required applications are running.
2. API health and readiness return 200. Anonymous `/api/me` returns 401.
3. Hard-refresh and sign in using an approved customer-tenant account. Confirm authenticated `/api/me` returns JSON with the correct tenant, organization and role.
4. API CORS permits exactly the approved portal origins. Browser requests target `/api/me`, not `/me` and not the portal's HTML fallback.
5. Models page exposes nano only after acceptance; placeholder models remain uncallable.
6. Create a team subscription and verify APIM provisioning, reveal/rotate semantics and product scope. Do not print its key or place it in Git, tickets or documentation.
7. Use its valid key for gateway `/models` and `/chat/completions`; confirm a successful nano answer. Anonymous 401 alone proves only reachability, not usability. Allow configuration propagation, then investigate persistent valid-key 401 failures.
8. Test bounded-request rejection, PII/safety behavior, quota limits, tenant/member denials and absence of prompts/secrets in logs.
9. Remove temporary tests/subscriptions/firewall rules on success or failure. Disable one-off price bootstrap after verification.
10. Run Terraform validation, relevant mocked tests, Python unit/contracts and portal tests. Investigate failures rather than marking the deployment complete because resource provisioning succeeded.

## Troubleshooting and operational notes

- `AADSTS500011`: check the tenant-specific authority, API identifier URI, API service principal and delegated scope. Do not reuse the lab's app IDs or log in through the wrong home tenant.
- Generic sign-in failure / Not Found: inspect the browser Network tab for `/api/me`. Verify the deployed Vite bundle contains the API URL **including `/api`**; an old image needs rebuilding and a new digest applied.
- Container image pull failure: ensure image is `repository@sha256:digest`, registry URL is separate, and the app's managed identity has `AcrPull`.
- Policy-denied subnet: the main App Gateway subnet uses AzAPI to attach its NSG on initial creation. No policy exemption is part of this guide. The edge-stage App Service subnet restriction still needs a compatible networking design; do not assume the current no-service-endpoint subnet supports it.
- Repeated policy XML differences: APIM reformats/encodes policies, producing recurring Terraform diffs. Do not blindly suppress all policy-body changes with `ignore_changes`; that would hide security-policy drift.
- SQL 503/readiness: check DNS, exact egress IP rules, contained-user SID and permission grants, migration state and managed identity selection.
- Cloud Shell DNS/ACR authentication failures: restore connectivity to Entra/ARM/ACR, verify tenant context and build status; do not assume an image exists because a pipeline printed the next step.
- The ingestion Function is provisioned but disabled unless separately configured and accepted. Usage ingestion, production TLS/edge, private-data migration, renewal and production hardening are separate workstreams.
- Manage cost and backup state. A Terraform destroy cannot remove the externally owned resource group, script-created Entra registrations or CLI-created model unless explicitly handled by the appropriate owner. Never delete unrelated customer resources.

## Source provenance

This repository carries the original AIFLUX Git history from `https://github.com/ajanakiraman_microsoft/ai-flux-gateway` plus local development changes for this deployment. Retain authorship and obtain the necessary permissions/licensing review before redistribution or production use. This guide does not grant a software license.