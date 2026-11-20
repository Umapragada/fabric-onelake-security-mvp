#!/usr/bin/env bash
# =====================================================================================
# KDD OneLake security · Phase 0 · Step 1: Entra ID and Azure
# Creates groups, test users, the spn-fabric-secops app, Key Vault and (optionally) an F2 capacity.
# Run in Azure Cloud Shell (bash) or locally with Azure CLI 2.60+, signed in as Uma (Global admin + Azure owner).
# Re-runnable: existing objects are reused. Writes kdd_ids.env for P0_2_fabric_deploy.py.
# =====================================================================================
set -euo pipefail

# ---------- EDIT THESE ----------
TENANT_DOMAIN="hiteshtaneja307gmail380.onmicrosoft.com"
ADMIN_UPN="umapragada@${TENANT_DOMAIN}"           # Uma: security admin, Fabric admin, capacity admin
LOCATION="westeurope"                              # Azure region for Key Vault and capacity
RESOURCE_GROUP="rg-kdd-fabric-lab"
KEY_VAULT="kv-kdd-fabric-$RANDOM"                  # must be globally unique; reused if kdd_ids.env exists
CAPACITY_NAME="kddfabriclab"                       # lowercase letters/digits only
CREATE_CAPACITY="no"                               # "yes" to create an F2 capacity here (billed hourly; pause it when idle)
TEMP_PASSWORD="Kdd!Lab-$(date +%Y)-Change"         # first-sign-in password for test users
# --------------------------------

[ -f kdd_ids.env ] && source kdd_ids.env && echo "Reusing values from kdd_ids.env"
az account show >/dev/null 2>&1 || az login --tenant "$TENANT_DOMAIN"
TENANT_ID=$(az account show --query tenantId -o tsv)
ADMIN_OID=$(az ad user show --id "$ADMIN_UPN" --query id -o tsv)

group() {   # name -> object id (create if missing)
  local id; id=$(az ad group list --display-name "$1" --query "[0].id" -o tsv)
  [ -z "$id" ] && id=$(az ad group create --display-name "$1" --mail-nickname "${1//-/}" --description "$2" --query id -o tsv) && echo "Created group $1" >&2
  echo "$id"
}
echo "== Security groups"
GRP_SEC_ADMINS=$(group grp-sec-admins "Security team: Admin on all KDD Fabric workspaces")
GRP_DATA_ENG=$(group grp-data-eng "Data engineers: Contributor on Bronze and Silver")
GRP_BI_DEV=$(group grp-bi-dev "BI developers: Contributor on Gold")
SG_AUTOMATION=$(group sg-fabric-automation "Service principals allowed to call Fabric public APIs")
az ad group member check --group "$GRP_SEC_ADMINS" --member-id "$ADMIN_OID" --query value -o tsv | grep -q true || az ad group member add --group "$GRP_SEC_ADMINS" --member-id "$ADMIN_OID"

echo "== Test users (personas and approvers)"
while IFS='|' read -r upn name title dept; do
  [ -z "$upn" ] && continue
  if ! az ad user show --id "${upn}@${TENANT_DOMAIN}" >/dev/null 2>&1; then
    az ad user create --display-name "$name" --user-principal-name "${upn}@${TENANT_DOMAIN}" --password "$TEMP_PASSWORD" \
      --force-change-password-next-sign-in true --job-title "$title" --department "$dept" >/dev/null && echo "Created ${upn}"
  fi
done <<'USERS'
emma.clarke|Emma Clarke|Demand Planner|Procurement
lukas.weber|Lukas Weber|AP Clerk|Finance - Accounts Payable
priya.nair|Priya Nair|Treasury Analyst|Finance - Treasury
sam.patel|Sam Patel|Internal Auditor|Internal Audit
maryam.alajmi|Maryam Al-Ajmi|Data Steward, Finance Data|Data Governance
noura.almutairi|Noura Al-Mutairi|Buyer, Packaging|Procurement
khalid.alazmi|Khalid Al-Azmi|AP Clerk|Finance - Accounts Payable
reem.alkandari|Reem Al-Kandari|Demand Planner|Procurement
ahmed.hassan|Ahmed Hassan|AP Clerk|Finance - Accounts Payable
omar.alrashidi|Omar Al-Rashidi|Head of Procurement|Procurement
fatima.alenezi|Fatima Al-Enezi|Finance Controller|Finance
yousef.alhajri|Yousef Al-Hajri|Head of Internal Audit|Internal Audit
hamad.alfahad|Hamad Al-Fahad|Chief Digital Officer|IT
USERS
az ad user show --id "datasteward@${TENANT_DOMAIN}" >/dev/null 2>&1 || echo "WARNING: datasteward@${TENANT_DOMAIN} not found; create it or edit the metamodel."

echo "== App registration spn-fabric-secops"
APP_ID=$(az ad app list --display-name spn-fabric-secops --query "[0].appId" -o tsv)
if [ -z "$APP_ID" ]; then
  APP_ID=$(az ad app create --display-name spn-fabric-secops --sign-in-audience AzureADMyOrg --query appId -o tsv)
  az ad sp create --id "$APP_ID" >/dev/null
  echo "Created app $APP_ID"
fi
SP_OID=$(az ad sp show --id "$APP_ID" --query id -o tsv)
GRAPH_SP=00000003-0000-0000-c000-000000000000
for perm in Group.Create GroupMember.ReadWrite.All User.Read.All Mail.Send; do
  RID=$(az ad sp show --id $GRAPH_SP --query "appRoles[?value=='$perm'].id | [0]" -o tsv)
  az ad app permission add --id "$APP_ID" --api $GRAPH_SP --api-permissions "${RID}=Role" 2>/dev/null || true
done
sleep 20
az ad app permission admin-consent --id "$APP_ID"
az ad group member check --group "$SG_AUTOMATION" --member-id "$SP_OID" --query value -o tsv | grep -q true || az ad group member add --group "$SG_AUTOMATION" --member-id "$SP_OID"

echo "== Resource group and Key Vault"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" -o none
if ! az keyvault show --name "$KEY_VAULT" >/dev/null 2>&1; then
  az keyvault create --name "$KEY_VAULT" --resource-group "$RESOURCE_GROUP" --location "$LOCATION" --enable-rbac-authorization true -o none
fi
KV_ID=$(az keyvault show --name "$KEY_VAULT" --query id -o tsv)
for role in "Key Vault Secrets Officer" "Key Vault Secrets User"; do
  az role assignment create --assignee-object-id "$ADMIN_OID" --assignee-principal-type User --role "$role" --scope "$KV_ID" -o none 2>/dev/null || true
done
sleep 30   # RBAC propagation
if ! az keyvault secret show --vault-name "$KEY_VAULT" --name spn-fabric-secops-secret >/dev/null 2>&1; then
  SECRET=$(az ad app credential reset --id "$APP_ID" --display-name "kdd-secops" --years 1 --append --query password -o tsv)
  az keyvault secret set --vault-name "$KEY_VAULT" --name spn-fabric-secops-secret --value "$SECRET" -o none
  unset SECRET
  echo "Secret stored in Key Vault (never printed)"
fi

if [ "$CREATE_CAPACITY" = "yes" ]; then
  echo "== Fabric capacity F2"
  az extension add --name microsoft-fabric --upgrade -y >/dev/null 2>&1 || true
  az fabric capacity create --resource-group "$RESOURCE_GROUP" --capacity-name "$CAPACITY_NAME" --location "$LOCATION" \
    --sku "{name:F2,tier:Fabric}" --administration "{members:[$ADMIN_UPN]}" -o none \
    || echo "Capacity creation failed: create an F2 capacity named $CAPACITY_NAME in the Azure portal instead."
fi

cat > kdd_ids.env <<EOF
TENANT_ID=$TENANT_ID
TENANT_DOMAIN=$TENANT_DOMAIN
ADMIN_UPN=$ADMIN_UPN
APP_ID=$APP_ID
SP_OID=$SP_OID
KEY_VAULT=$KEY_VAULT
KEY_VAULT_URL=https://${KEY_VAULT}.vault.azure.net/
CAPACITY_NAME=$CAPACITY_NAME
GRP_SEC_ADMINS=$GRP_SEC_ADMINS
GRP_DATA_ENG=$GRP_DATA_ENG
GRP_BI_DEV=$GRP_BI_DEV
SG_AUTOMATION=$SG_AUTOMATION
EOF
echo
echo "Done. Values saved to kdd_ids.env."
echo "MANUAL STEP NOW: Fabric admin portal > Tenant settings > Developer settings >"
echo "  'Service principals can call Fabric public APIs' = Enabled, limited to security group sg-fabric-automation."
echo "RECOMMENDED: limit Mail.Send to the sender mailbox with Exchange Online RBAC for Applications."
