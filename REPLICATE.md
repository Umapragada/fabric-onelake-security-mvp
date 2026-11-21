# Replicate in a new tenant (checklist)

Everything below was hit on the first run in the lab tenant. Follow it top to bottom; each step is re-runnable.

## Before you start (portal, 10 minutes)
1. Your account (`ADMIN_UPN`) is **Global Administrator** in Entra and **Owner** of the Azure subscription
   (Subscriptions → Access control (IAM) → Owner). Without Owner, Key Vault and Cloud Shell fail.
2. A Fabric capacity exists and you are its admin (trial or F-SKU). Note its **display name**
   (Fabric → Settings → Admin portal → Capacity settings).
3. Fabric admin portal → Tenant settings → Developer settings → **Service principals can call Fabric public APIs**
   → Enabled for group `sg-fabric-automation` (the group is created by step A; set this right after).
4. Real mail: the sender mailbox needs an Exchange Online licence. Without one, notifications stay `Queued`.

## A. Cloud Shell (Bash)
First time Cloud Shell opens: choose **Mount storage account** (not "No storage account"), so files survive
the ~20-minute idle reset. It costs a few cents a month. Type commands; don't up-arrow into `foundation` by accident.

```bash
gh auth status || gh auth login                       # repo is private
gh repo clone Umapragada/fabric-onelake-security-mvp && cd fabric-onelake-security-mvp
az login --use-device-code --tenant <tenant-domain>   # Cloud Shell's built-in login can't get Fabric tokens

export TENANT_DOMAIN=<tenant-domain>                  # e.g. contoso.onmicrosoft.com
export ADMIN_UPN=<your-upn>
export CAPACITY_NAME="<capacity display name>"
export LOCATION=westeurope                            # Key Vault falls back to other regions if refused
export RESOURCE_GROUP=rg-kdd-fabric

bash P0_1_entra_azure.sh                              # groups, 14 test users, app + Graph roles, Key Vault, secret
python P0_2_fabric_deploy.py foundation               # 7 workspaces, 6 lakehouses, SQLDB_SecMeta
```
`P0_1` also writes your tenant into `P3_metamodel.sql` (`@Tenant`).
If `ADMIN_UPN` is not `umapragada@<tenant>`, replace `umapragada@` in `P3_metamodel.sql` too.

## B. Security register (Fabric UI)
Open WS-SEC-Control → `SQLDB_SecMeta` (type **SQL database**, not "SQL analytics endpoint") → New query →
run `P3_metamodel.sql`, then `P6_audit_reporting.sql`. Check: `SELECT * FROM sec.vw_EffectiveAccess;` returns rows.

## C. Notebooks (Cloud Shell)
```bash
export KDD_MAIL_SENDER=$ADMIN_UPN KDD_SECURITY_MAIL=$ADMIN_UPN
python P0_2_fabric_deploy.py notebooks
```

## D. Data (Fabric UI, Run all in order)
NB_PRC_Load, NB_AP_Load → NB_AP_Conform → `python P0_2_fabric_deploy.py shortcut` → NB_PRC_Conform → NB_AP_Gold, NB_PRC_Gold.
Both Gold notebooks end with "Reconciled".

## E. Sync (Fabric UI)
1. For LH_PRC_Silver, LH_PRC_Gold, LH_AP_Silver, LH_AP_Gold: open the lakehouse → **Manage OneLake data access** → enable
   (roles list shows DefaultReader). SQL analytics endpoint → Settings → Data access mode = **User's identity** (usually already set).
2. NB_SEC_Sync: `DRY_RUN = True` → Run all → no `FAILED:` lines. Then `DRY_RUN = False` → Run all.

## F. Lifecycle and test request (Phase 5)
```bash
python P0_2_fabric_deploy.py pipeline    # PL_SEC_Lifecycle + daily 06:00 Kuwait schedule
python P0_2_fabric_deploy.py run
```
Test request (replaces the Power Apps form for the MVP), in SQLDB_SecMeta:
```sql
INSERT INTO sec.AccessRequest (RequestType,UserId,RoleTemplateId,ScopeValue,StartDate,EndDate,ReasonCategory,Justification,RequestedByUPN,ApproverUPN,ApprovedAt,Status)
SELECT 'New', 3, 1, '101', CAST(GETDATE() AS date), DATEADD(day,30,CAST(GETDATE() AS date)), 'Project', N'MVP test: buyer access OU 101',
       u.UPN, d.OwnerUPN, SYSUTCDATETIME(), 'Approved'
FROM sec.UserProfile u CROSS JOIN (SELECT TOP 1 OwnerUPN FROM sec.Domain) d WHERE u.UserId = 3;
```
Then `python P0_2_fabric_deploy.py run` → Emma Clarke appears in `grp-ol-PrcBuyerOU101`.

## Restore after a Cloud Shell reset
Nothing in Azure/Fabric is lost; only the local folder. Paste (all steps reuse what exists):
```bash
gh auth status || gh auth login
gh repo clone Umapragada/fabric-onelake-security-mvp; cd ~/fabric-onelake-security-mvp && git pull
az login --use-device-code --tenant $TENANT_DOMAIN
export TENANT_DOMAIN=... ADMIN_UPN=... CAPACITY_NAME="..."           # same values as section A
export KDD_MAIL_SENDER=$ADMIN_UPN KDD_SECURITY_MAIL=$ADMIN_UPN
bash P0_1_entra_azure.sh && python P0_2_fabric_deploy.py foundation   # regenerates kdd_ids.env and kdd_fabric_ids.json
```
Don't re-run `P3_metamodel.sql` after the first time: it resets the register.

## Known gotchas
| Symptom | Fix |
|---|---|
| Cloud Shell "No valid subscriptions" | You are not Owner on the subscription |
| `unrecognized arguments: --job-title` | Fixed in script (titles set via Graph) |
| `Audience ... not a supported MSI token audience` | Fixed in script; also run `az login --use-device-code` |
| Key Vault "region not accepting new customers" | Fixed in script (tries other regions) |
| `Capacity 'kddfabriclab' not found` | `export CAPACITY_NAME=...` and re-run P0_1, or edit `kdd_ids.env` |
| `PRIMARY KEY keyword is not supported` | You are in the SQL analytics endpoint; open the SQL database |
| JDBC certificate name error | Fixed in NB_SEC_Common (retries; validation stays on) |
| `ROLE_APPLY_FAILED` | OneLake security not enabled on that lakehouse (step E.1) |
| Cloud Shell lost files | See "Restore after a Cloud Shell reset"; mount storage to avoid it |
| `DRIFT_DETECTED` right after a successful apply | Fixed in NB_SEC_Sync (compares governed fields only) |
| Graph 404 on a group just created | Fixed in NB_SEC_Sync (waits for Entra replication) |
| `PolicyValidationError ... "Read"` | Fixed (columnAction is a list) |
