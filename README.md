# KDD OneLake Security · Execution runbook, Phases 0 to 6

Run everything as **Uma** (Global admin in Entra, owner of the Azure subscription, Fabric administrator).
Each step ends with a **Check**. Do not start the next step until the check passes.

| File | Phase | Runs where |
|---|---|---|
| `P0_1_entra_azure.sh` | P0 | Azure Cloud Shell (bash) or local Azure CLI |
| `P0_2_fabric_deploy.py` | P0, P1–P5 deploy | Same shell, Python 3.9+ with `requests` |
| `P3_metamodel.sql` | P3 | Fabric query editor of `SQLDB_SecMeta` |
| `P6_audit_reporting.sql` | P6 | Fabric query editor of `SQLDB_SecMeta` |
| `notebooks/*.ipynb` | P1, P2, P4, P5 | Imported into Fabric by the deploy script |
| `KDD_Access_Request_Form.json`, `KDD_Access_Request_Choices.csv` | P5 | Power Apps form build |

Upload the whole folder to Cloud Shell (Manage files → Upload, then `unzip`), and keep it together: the scripts read and write `kdd_ids.env` and `kdd_fabric_ids.json` next to themselves.

---

## Phase 0 · Foundations (milestone M1)

**0.1 Edit and run the Entra/Azure script**
1. Open `P0_1_entra_azure.sh` and set the block marked `EDIT THESE`: tenant domain, region, `CREATE_CAPACITY="yes"` if you want the script to create the F2 capacity.
2. Run `bash P0_1_entra_azure.sh`.
   It creates groups `grp-sec-admins`, `grp-data-eng`, `grp-bi-dev`, `sg-fabric-automation`, the 13 test users, the app `spn-fabric-secops` with Graph permissions `Group.Create`, `GroupMember.ReadWrite.All`, `User.Read.All`, `Mail.Send` (admin consent granted), a Key Vault holding the app secret, and `kdd_ids.env`.
3. **Check:** `cat kdd_ids.env` shows every value; in Entra ID → App registrations → spn-fabric-secops → API permissions, all four show "Granted".

**0.2 Tenant setting (manual, one minute)**
Fabric → Settings → Admin portal → Tenant settings → Developer settings → **Service principals can call Fabric public APIs** → Enabled → Specific security groups → `sg-fabric-automation` → Apply. Allow up to 15 minutes to take effect.

**0.3 Fabric foundation**
```bash
pip install requests
python P0_2_fabric_deploy.py foundation
```
Creates the 7 workspaces on the capacity, the Procurement and Payables domains with their workspaces assigned, the workspace roles from design section 4.5, six schema-enabled lakehouses and the `SQLDB_SecMeta` database. Writes `kdd_fabric_ids.json`.
**Check:** the 7 workspaces appear under their domains in the OneLake catalog; `kdd_fabric_ids.json` has a `sql.server` and `sql.database` value.

## Phase 3 · Security metamodel (run now, before the notebooks)

1. Open WS-SEC-Control → SQLDB_SecMeta → New query.
2. Paste `P3_metamodel.sql`. Check the line `DECLARE @Tenant ... = N'hiteshtaneja307gmail380.onmicrosoft.com'` matches your tenant. Run.
3. Paste and run `P6_audit_reporting.sql` (views used later).
4. **Check:** `SELECT * FROM sec.vw_EffectiveAccess;` returns the active sample grants.
5. Domain owners and Internal Audit review `sec.RoleTemplate`, `sec.ObjectRule`, `sec.RowRule`, `sec.ColumnRule`, `sec.RoleConflict` (SEC-02, GOV-02). The build can continue while they review.

## Deploy the notebooks (P1–P5 code)
```bash
export KDD_MAIL_SENDER="umapragada@<tenant-domain>"      # mailbox with an Exchange licence
export KDD_SECURITY_MAIL="umapragada@<tenant-domain>"    # copied on revocations
python P0_2_fabric_deploy.py notebooks
```
Imports 11 notebooks into the right workspaces with workspace/lakehouse IDs, the SQL connection and the app details filled in.
**Check:** each workspace shows its notebooks: NB_PRC_Load, NB_AP_Load, NB_PRC_Conform, NB_AP_Conform, NB_PRC_Gold, NB_AP_Gold and, in WS-SEC-Control, NB_SEC_Common, NB_SEC_Lifecycle, NB_SEC_Sync, NB_SEC_Notify, NB_SEC_Run.

## Phase 1 · Bronze data
Run **NB_PRC_Load** (WS-PRC-Bronze) and **NB_AP_Load** (WS-AP-Bronze). Each writes the simulated EBS extract to `Files/ebs_landing/` and loads schema `ebs`.
**Check (row counts):** Procurement: hr_operating_units 3, mtl_categories_b 6, mtl_system_items_b 30, po_requisition_headers_all 40, po_requisition_lines_all 90, po_headers_all 60, po_lines_all 180, po_distributions_all 180, rcv_shipment_headers 50, rcv_transactions 150. Payables: hr_operating_units 3, ap_suppliers 15, ap_supplier_sites_all 25, ap_terms 4, iby_ext_bank_accounts 15, ap_invoices_all 120, ap_invoice_lines_all 240, ap_invoice_distributions_all 240, ap_payment_schedules_all 120, ap_checks_all 70, ap_invoice_payments_all 90.

## Phase 2 · Silver and Gold (milestone M2)
Run in this order:
1. **NB_AP_Conform** (WS-AP-Silver)
2. `python P0_2_fabric_deploy.py shortcut` (creates `LH_PRC_Silver/Tables/silver/supplier` → `LH_AP_Silver`)
3. **NB_PRC_Conform** (WS-PRC-Silver)
4. **NB_AP_Gold** (WS-AP-Gold) and **NB_PRC_Gold** (WS-PRC-Gold)

**Check:** both Gold notebooks end with "Reconciled". Expected Gold row counts: fact_purchase_order 180, fact_receipt 150, fact_invoice 120, fact_payment 90, dim_supplier 15, dim_bank_account 15, dim_date 1095. Purchase order lines by unit: Kuwait 75, Saudi Arabia 60, UAE 45.

## Phase 4 · Sync engine (milestone M3)
**4.1 Manual switches (UI only)**
- For each of LH_PRC_Silver, LH_PRC_Gold, LH_AP_Silver, LH_AP_Gold: open the lakehouse → **Manage OneLake security** → turn it on (TEN-05).
- For the same four: open the **SQL analytics endpoint** → Security → set access mode to **User's identity** (TEN-06).

**4.2 Dry run, then apply**
1. Open **NB_SEC_Sync**, set `DRY_RUN = True`, Run all. Read the printed plan: groups to create, members to add, roles per lakehouse. No changes are made.
2. Set `DRY_RUN = False`, Run all.
3. **Check:**
   - Entra ID shows groups `grp-ol-PrcBuyerOU102`, `grp-ol-ApClerkOU103`, `grp-ol-ApTreasuryAll`, … with the expected members.
   - LH_PRC_Gold → Manage OneLake security lists PrcBuyerOU102, PrcPlannerOU101, PrcAuditorAll and **no DefaultReader** (SEC-03).
   - WS-PRC-Gold → Manage access shows the grp-ol-* groups as Viewer.
   - `SELECT * FROM sec.vw_SyncHealth ORDER BY RunId DESC;` shows Healthy.
4. Run NB_SEC_Sync again: it must print "no change" for every lakehouse and 0 changes (NFR-02).
5. Drift test (TST-03): edit any role by hand in the UI, run NB_SEC_Sync: it reports DRIFT_DETECTED and leaves that lakehouse alone. To overwrite deliberately, set `FORCE_ITEMS = "LH_PRC_Gold"`.

## Phase 5 · Lifecycle, mail and request intake (milestone M4)
**5.1 Pipeline and schedule**
```bash
python P0_2_fabric_deploy.py pipeline
```
Creates **PL_SEC_Lifecycle** (Lifecycle → Sync → Notify) and a daily 06:00 Kuwait-time schedule. If the API refuses the schedule, the script says so: open the pipeline → Schedule → Daily, 06:00, (UTC+03:00) Kuwait, Riyadh. If the pipeline itself cannot be created, schedule notebook **NB_SEC_Run** instead (same order).
**Check:** `python P0_2_fabric_deploy.py run`, then in the Monitoring hub the run succeeds; `SELECT * FROM sec.vw_NotificationStatus ORDER BY ScheduledFor DESC;` shows ENABLED mails as Sent.

**5.2 Limit who the app can send mail as (recommended)**
`Mail.Send` as an application permission can send as any mailbox. Restrict it to the sender mailbox with Exchange Online **RBAC for Applications** (management scope on that one mailbox).

**5.3 Request form (Power Apps + Power Automate)**
1. Power Apps → Create → Canvas app (tablet). Add a connection to **SQL Server** (premium) pointing at the server and database in `kdd_fabric_ids.json`, authentication Microsoft Entra ID.
2. Build the fields from `KDD_Access_Request_Form.json`. Load dropdowns from `sec.RoleTemplate`, `sec.ScopeValue`, `sec.Domain` (or import `KDD_Access_Request_Choices.csv`). Person field: Office 365 Users connector, not free text.
3. On Submit: insert into `sec.AccessRequest` with Status = 'Pending' and the request fields; run checks V1–V6 first.
4. Power Automate flow "When an item is created in sec.AccessRequest" (or triggered from the app): **Start and wait for an approval** to the domain owner (`sec.Domain.OwnerUPN`) → if approved, update the row to Status = 'Approved', ApproverUPN, ApprovedAt; if rejected, Status = 'Rejected' with the comment.
5. After approval, an **HTTP** action with Microsoft Entra ID OAuth (client credentials of spn-fabric-secops, audience `https://api.fabric.microsoft.com`) calls
   `POST https://api.fabric.microsoft.com/v1/workspaces/<WS-SEC-Control id>/items/<PL_SEC_Lifecycle id>/jobs/instances?jobType=Pipeline`
   so access arrives in minutes instead of at 06:00.
**Check (M4):** submit a request for emma.clarke, PrcBuyer, OU 101 starting today; approve it; within one run she is in `grp-ol-PrcBuyerOU101` and receives the "Access enabled" mail.

## Phase 6 · Audit and admin report (milestone M5)
1. `P6_audit_reporting.sql` already created `vw_AuditTrail`, `vw_SyncHealth`, `vw_AccessSummary`, `vw_NotificationStatus`, `vw_AccessReview` and `usp_PurgeEvidence`.
2. Power BI Desktop → Get data → **SQL Server** → server and database from `kdd_fabric_ids.json` → Microsoft account sign-in as Uma → import the views above plus `sec.vw_EffectiveAccess` and `sec.vw_ExpiringSoon`.
3. Pages: **Effective access** (who, role, unit, ends), **Expiring this week**, **Audit trail** (filter by person, request, action group), **Sync health**, **Notifications**. Publish to WS-SEC-Control as **RPT_SEC_Admin**.
4. Share RPT_SEC_Admin with Internal Audit as an item share (no workspace role), so WS-SEC-Control stays hidden from them (AUD-03).
5. Retention: run `EXEC sec.usp_PurgeEvidence @MonthsToKeep = 13;` monthly once decision D-05 confirms the period (AUD-02).
6. Platform evidence: Microsoft Purview portal → Audit → search, workload Microsoft Fabric / Power BI, for the OneLake data access role and workspace role changes made by spn-fabric-secops (TEN-07).
**Check (M5):** pick any row in `vw_EffectiveAccess` and trace it in the report to its request, approver, ticket, group change and role change.

---

### What was tested before handover
- The EBS generator: all 21 tables produce the planned row counts and valid keys.
- Silver and Gold notebooks: run end to end on local Spark 3.5 against the generated data; both reconcile, and Gold column names match `sec.ColumnRule`.
- The sync notebook's role compiler: output identical to the compiled roles in design section 4.3.
- Not run against a live tenant: the Graph, Fabric and SQL calls follow Microsoft Learn's documented request shapes. Points to watch on first run: the pipeline activity type `TridentNotebook` and schedule `jobType` (fallbacks built in), and the JDBC `accessToken` connection to SQLDB_SecMeta.

### Troubleshooting
| Symptom | Likely cause | Fix |
|---|---|---|
| `401/403` from Fabric API as the app | Tenant setting not on or not propagated | Step 0.2, wait 15 minutes |
| `403` from Graph | Admin consent missing | Re-run `az ad app permission admin-consent --id <APP_ID>` |
| `PrincipalNotFound` adding the SPN to a workspace | Wrong object ID | `SP_OID` must be the **service principal** object ID, not the app ID |
| `ROLE_APPLY_FAILED` on a lakehouse | OneLake security not turned on for it | Step 4.1 |
| `Login failed` / token error in NB_SEC_Common | SPN not Admin on WS-SEC-Control, or wrong SQL host | Re-run `foundation`; check `kdd_fabric_ids.json` |
| Persona sees everything | Persona has a workspace role above Viewer, or SQL endpoint still in delegated mode | Remove the role; step 4.1 |
| `DRIFT_DETECTED` on first live run | Sample `sec.RoleBinding` rows still present | The tail of `P3_metamodel.sql` clears them; re-run that block |

## Documentation
- `REPLICATE.md`: step-by-step checklist to deploy in a new tenant.
- `docs/FMCG_OneLake_Security_Blueprint.html`: the design document (open in a browser).
- `docs/SECURITY_METADATA_DICTIONARY.md`: every register table and column, with examples and who maintains it.
  Regenerate with `python tools/render.py docs/SECURITY_METADATA_DICTIONARY.md /tmp/dict.html` after editing `tools/dictionary.py`.
- `sec.vw_UserAccessDetail` (in `P6_audit_reporting.sql` and `P6_endpoint_views.sql`): person → request → role → table → row filter → columns → Fabric role.
