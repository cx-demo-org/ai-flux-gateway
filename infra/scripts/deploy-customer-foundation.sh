#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="$ROOT/infra/terraform"
INPUTS="$TF_DIR/environments/customer-foundation.tfvars.example"
SUB="aa28274d-fea0-46d4-b9c8-30f3ef0a0e52"
RG="IDS-TOKEN-EXCHANGE-POC"
PREFIX="proj-ids-poc"
TF="${TERRAFORM_BIN:-terraform}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
confirm() {
  local answer
  read -r -p "$1 [yes/no]: " answer
  [[ "$answer" == yes ]] || die "Cancelled; no further changes made."
}

for cmd in az jq "$TF"; do
  command -v "$cmd" >/dev/null || die "Required executable not found: $cmd"
done
[[ -t 0 ]] || die "Run this script interactively so the plan and approvals can be reviewed."
version="$("$TF" version -json | jq -r '.terraform_version')"
[[ "$version" =~ ^1\.16\.[0-9]+$ ]] || die "Terraform 1.16.x is required; found $version. Set TERRAFORM_BIN to an approved binary."

account="$(az account show --subscription "$SUB" -o json)"
tenant="$(jq -r '.tenantId' <<< "$account")"
[[ "$(jq -r '.id' <<< "$account")" == "$SUB" ]] || die "Subscription mismatch."
state="$(az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB?api-version=2022-12-01" \
  --query state -o tsv)"
[[ "$state" == Enabled ]] || die "Live ARM subscription state is $state; resolve this before deployment."
az group show --subscription "$SUB" --name "$RG" --query '{name:name,location:location}' -o table
printf 'Subscription: %s\nTenant: %s\nResource group: %s\nPrefix: %s\n' "$SUB" "$tenant" "$RG" "$PREFIX"

for namespace in Microsoft.ApiManagement Microsoft.OperationalInsights Microsoft.Insights Microsoft.ManagedIdentity Microsoft.KeyVault Microsoft.CognitiveServices Microsoft.ContainerRegistry; do
  registration="$(az provider show --subscription "$SUB" --namespace "$namespace" --query registrationState -o tsv)"
  [[ "$registration" == Registered ]] || die "$namespace is $registration. Ask the subscription administrator to register the required provider, then retry."
done

export ARM_SUBSCRIPTION_ID="$SUB"
export ARM_TENANT_ID="$tenant"
umask 077
STATE_DIR="${AIFLUX_STATE_DIR:-$HOME/clouddrive/aiflux/$PREFIX}"
if [[ -z "${AIFLUX_STATE_DIR:-}" ]]; then
  [[ -d "$HOME/clouddrive" ]] || die "Persistent clouddrive not found. Mount protected persistent storage, or set AIFLUX_STATE_DIR to a verified persistent directory."
fi
[[ "$STATE_DIR" == /* ]] || die "AIFLUX_STATE_DIR must be an absolute path."
case "$STATE_DIR" in /tmp|/tmp/*|/var/tmp|/var/tmp/*) die "Do not store Terraform state in a temporary directory." ;; esac
printf '\nState directory: %s\n' "$STATE_DIR"
printf 'This uses LOCAL state, not projpoctokenex. That existing storage account is unchanged.\n'
confirm "Is this directory persistent, access-controlled, backed up, and the only state location for this NEW customer deployment?"
mkdir -p -- "$STATE_DIR"
STATE_DIR="$(cd -- "$STATE_DIR" && pwd)"
if [[ ! -f "$STATE_DIR/terraform.tfstate" ]]; then
  confirm "No state exists here. Confirm no existing AIFLUX deployment/state uses the prefix $PREFIX"
fi

BACKEND="$STATE_DIR/backend.hcl"
PLAN="$STATE_DIR/foundation.tfplan"
printf 'path = %s\n' "$(jq -Rn --arg path "$STATE_DIR/terraform.tfstate" '$path')" > "$BACKEND"
printf '\nThis deploys paid APIM Developer, ACR, monitoring and protection services.\n'
printf 'No application, SQL, VNet, private endpoints, model deployment or authentication integration is deployed in this stage.\n'
printf 'Key Vault public access stays disabled; private connectivity is deferred.\n'
confirm "Approve foundation costs and configuration, and confirm the selected tenant is the customer tenant?"

"$TF" -chdir="$TF_DIR" init -input=false -backend-config="$BACKEND"
"$TF" -chdir="$TF_DIR" validate

tf() {
  local action="$1"
  shift
  "$TF" -chdir="$TF_DIR" "$action" -input=false \
    -var-file="$INPUTS" -var=deployment_approved=true "$@"
}

POLICY="/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$PREFIX-apim/policies/policy?api-version=2022-08-01"
adopt_default_policy() {
  local addresses
  [[ -f "$STATE_DIR/terraform.tfstate" ]] || return 0
  addresses="$("$TF" -chdir="$TF_DIR" state list)"
  if grep -Fxq 'azurerm_api_management.main' <<< "$addresses" && \
      ! grep -Fxq 'azapi_resource.closed_policy' <<< "$addresses"; then
    if az rest --method get --url "https://management.azure.com$POLICY" --query name -o tsv >/dev/null; then
      confirm "Import the default global policy of THIS state-managed APIM so Terraform can manage the closed policy?"
      tf import azapi_resource.closed_policy "$POLICY"
    fi
  fi
}

adopt_default_policy
tf plan -out="$PLAN"
confirm "Apply the reviewed foundation plan?"
if ! "$TF" -chdir="$TF_DIR" apply -input=false "$PLAN"; then
  printf '\nPartial apply retained in state. Checking for the known default APIM policy conflict.\n'
  adopt_default_policy
  die "Review the error, then rerun this script with the SAME state directory. It will re-plan; it will not reuse the failed plan."
fi
"$TF" -chdir="$TF_DIR" output
printf '\nFoundation apply completed. This is NOT a usable portal deployment.\n'
printf 'Next: manual Entra registrations, SQL administrator, approved private runner/network, image builds and platform deployment.\n'