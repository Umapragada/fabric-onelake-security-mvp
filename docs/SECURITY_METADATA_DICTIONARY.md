# Security metadata dictionary

The register in `SQLDB_SecMeta` (schema `sec`) holds every access rule for OneLake. This dictionary defines each table and column, with a real example from the lab (datasteward, Procurement buyer, OU 102). Keep it next to `P3_metamodel.sql`; when a column changes, change both.

## Who prepares the rules

| Activity | Does the work | Accountable | Consulted | Informed |
|---|---|---|---|---|
| Define domains, owners and scope values | Data Owner | Data Owner | Security Admin, Data Steward | Internal Audit |
| Draft role templates, table, row and column rules | Data Steward | Data Owner | Domain SME, Security Admin | Internal Audit |
| Confirm column sensitivity (PII, bank, VAT) | Domain SME | Data Owner | Data Steward | Security Admin |
| Define conflicts (segregation of duties) | Data Owner | Data Owner | Internal Audit | Security Admin |
| Load rules into the register, dry run, publish | Security Admin | Security Admin | Data Steward | Data Owner |
| Request access | Requester or manager | Requester's manager | — | Data Owner |
| Approve or reject requests | Data Owner | Data Owner | — | Security Admin |
| Run sync, lifecycle and mail | System | Security Admin | — | Data Owner |
| Review access and evidence each quarter | Internal Audit | Data Owner | Security Admin | Data Steward |

Rule of thumb: the **Data Steward** writes the rules, the **domain SME** says which columns are sensitive, the **Data Owner** approves, the **Security Admin** loads them with a dry run, and **Internal Audit** reviews the evidence.

## What: assets

### `sec.Domain`

A business data domain with one accountable owner. **Maintained by:** Data Owner (via Security Admin).

| Column | Definition | Example |
|---|---|---|
| `DomainId` | Key of the domain. | `1` |
| `DomainName` | Business name, unique. | `Procurement` |
| `FabricDomainId` | Id of the matching Fabric domain, if used. | `NULL` |
| `OwnerUPN` | Data Owner; approves requests for this domain's roles. | `omar.alrashidi@…` |
| `Description` | What data the domain covers. | `Purchasing, receipts, items and categories` |

### `sec.Workspace`

A Fabric workspace that belongs to a domain and a layer. **Maintained by:** Security Admin.

| Column | Definition | Example |
|---|---|---|
| `WorkspaceKey` | Key of the workspace. | `3` |
| `DomainId` | Owning domain (NULL for the control workspace). | `1` |
| `WorkspaceName` | Exact Fabric display name; the sync finds the workspace by it. | `WS-PRC-Gold` |
| `FabricWorkspaceId` | Fabric GUID, optional. | `NULL` |
| `Layer` | Bronze, Silver, Gold or Control. | `Gold` |
| `IsHidden` | 1 = only the security team should see it. | `0` |

### `sec.Item`

A Fabric item (lakehouse, model, agent, report) inside a workspace. **Maintained by:** Security Admin.

| Column | Definition | Example |
|---|---|---|
| `ItemKey` | Key of the item; rules point at it. | `3` |
| `WorkspaceKey` | Workspace that holds the item. | `3` |
| `ItemName` | Exact Fabric item name. | `LH_PRC_Gold` |
| `ItemType` | Lakehouse, SemanticModel, DataAgent, Report, … | `Lakehouse` |
| `FabricItemId` | Fabric GUID, optional. | `NULL` |
| `OneLakeSecured` | 1 = the sync writes the full OneLake role set to this item every run. | `1` |

### `sec.ScopeValue`

The allowed values for row-level scope. **Maintained by:** Data Owner.

| Column | Definition | Example |
|---|---|---|
| `ScopeType` | Kind of scope: ORG_ID or ALL. | `ORG_ID` |
| `ScopeValue` | The value a row filter uses. | `102` |
| `Label` | Business label shown to requesters. | `KDD Saudi Arabia` |
| `CurrencyCode` | Currency of that unit, for reports. | `SAR` |

## How: rules

### `sec.RoleTemplate`

A business role written once per domain; requests pick one. **Maintained by:** Data Steward drafts, Data Owner approves.

| Column | Definition | Example |
|---|---|---|
| `RoleTemplateId` | Key of the role. | `1` |
| `RoleCode` | Short code; becomes part of the Fabric role and group name. | `PrcBuyer` |
| `DisplayName` | Name shown on the request form. | `Procurement buyer` |
| `DomainId` | Domain the role belongs to. | `1` |
| `ScopeType` | ORG_ID = one unit per request; ALL = no row filter. | `ORG_ID` |
| `Layers` | Layers the role reaches. | `Gold` |
| `WorkspaceRole` | Workspace role given to the group; always Viewer for consumers. | `Viewer` |
| `MaxDays` | Longest access a single request may ask for. | `180` |
| `RequiresDepartment` | Only people in this department may hold it; NULL = anyone. | `Internal Audit` |
| `IsActive` | 0 = no new requests. | `1` |
| `Description` | Plain-language summary of what the role sees. | `POs, receipts and supplier names for one operating unit` |

### `sec.ObjectRule`

Which tables a role may read in an item. A table not listed is invisible. **Maintained by:** Data Steward with SME.

| Column | Definition | Example |
|---|---|---|
| `RoleTemplateId` | The role. | `1` |
| `ItemKey` | The item (lakehouse). | `3 (LH_PRC_Gold)` |
| `TablePath` | OneLake path of the table. | `/Tables/gold/fact_purchase_order` |

### `sec.RowRule`

Row filter for a table: the column compared with the request's scope value. No row = all rows. **Maintained by:** Data Steward with SME.

| Column | Definition | Example |
|---|---|---|
| `RoleTemplateId` | The role. | `1` |
| `ItemKey` | The item. | `3` |
| `TablePath` | The table. | `/Tables/gold/fact_purchase_order` |
| `FilterColumn` | Column filtered by the scope; becomes org_id = '102' for an OU 102 request. | `org_id` |

### `sec.ColumnRule`

Allowed columns for a table. Anything not listed is hidden. No row = all columns. **Maintained by:** Data Steward with SME; Data Owner approves sensitive columns.

| Column | Definition | Example |
|---|---|---|
| `RoleTemplateId` | The role. | `1` |
| `ItemKey` | The item. | `3` |
| `TablePath` | The table. | `/Tables/gold/dim_supplier` |
| `AllowedColumns` | JSON list of visible columns, case-sensitive. | `["supplier_id","supplier_name","country",…]` |

### `sec.RoleConflict`

Pairs of roles one person may not hold together (segregation of duties). **Maintained by:** Data Owner with Internal Audit.

| Column | Definition | Example |
|---|---|---|
| `ConflictId` | Key. | `1` |
| `RoleCodeA` | First role. | `PrcBuyer` |
| `RoleCodeB` | Second role. | `ApClerk` |
| `ConflictScope` | Any = never together; SameScope = not on the same unit. | `SameScope` |
| `Reason` | Why, in business words. | `A buyer may not process invoices for POs in the same operating unit` |

## Who: people and requests

### `sec.UserProfile`

People who can hold access, with HR status. **Maintained by:** HR feed (MVP: Security Admin).

| Column | Definition | Example |
|---|---|---|
| `UserId` | Key. | `2` |
| `UPN` | Sign-in name; must exist in Entra. | `datasteward@…` |
| `EntraObjectId` | Filled by the sync. | `8c1e…` |
| `DisplayName` | Name. | `Data Steward` |
| `JobTitle` | Title. | `Buyer, Dairy Raw Materials` |
| `Department` | Checked against RequiresDepartment. | `Procurement` |
| `CostCentre` | For reporting. | `CC-PRC-220` |
| `Country` | For reporting. | `Saudi Arabia` |
| `HomeOrgId` | Home operating unit. | `102` |
| `ManagerUPN` | Copied on mails. | `omar.alrashidi@…` |
| `EmploymentStatus` | Active or Leaver; a Leaver loses everything on the next run. | `Active` |
| `LeaverDate` | Date of leaving. | `NULL` |
| `ExistsInTenant` | 1 once found in Entra. | `1` |

### `sec.AccessRequest`

One request for one person, one role, one scope, with dates. The only way access is granted. **Maintained by:** Requester fills; Data Owner approves; lifecycle moves the status.

| Column | Definition | Example |
|---|---|---|
| `RequestId / RequestNumber` | Key and readable number. | `1 / ACC-00001` |
| `TicketRef` | ServiceNow or other ticket. | `RITM0010481` |
| `RequestType` | New, Extend or Remove. | `New` |
| `UserId` | Who gets access. | `2` |
| `RoleTemplateId` | Which role. | `1` |
| `ScopeValue` | Which unit, or ALL. | `102` |
| `StartDate / EndDate` | Access window; EndDate − StartDate ≤ MaxDays. | `2026-11-18 / 2027-02-15` |
| `ReasonCategory / Justification` | Why. | `New joiner / Joined KSA buying team…` |
| `RequestedByUPN` | Who asked. | `omar.alrashidi@…` |
| `ApproverUPN / ApprovedAt` | Who approved and when. | `omar.alrashidi@… / 2026-11-16 14:40` |
| `Status` | Pending → Approved → Active → Expired or Revoked; or Rejected. | `Active` |
| `StatusReason` | Why the status changed. | `RoleConflict: …` |

## Generated by the sync

### `sec.RoleBinding`

What the sync built: one Fabric role per role + scope + item. Never edited by hand. **Maintained by:** System (NB_SEC_Sync).

| Column | Definition | Example |
|---|---|---|
| `RoleName` | Fabric role name. | `PrcBuyerOU102` |
| `ItemKey` | Item it lives on. | `3` |
| `RoleTemplateId / ScopeValue` | Source of the role. | `1 / 102` |
| `EntraGroupName / EntraGroupId` | Group that is the role's member. | `grp-ol-PrcBuyerOU102` |
| `MemberCount` | People in the group. | `1` |
| `RoleJson / RoleHash` | Exact role sent to Fabric, and its hash for change detection. | `{…}` |
| `Status / AppliedAt` | Planned, Applied or Removed, and when. | `Applied` |

## Evidence

### `sec.SyncRun`

One row per sync run. **Maintained by:** System.

| Column | Definition | Example |
|---|---|---|
| `RunId` | Key. | `42` |
| `StartedAt / EndedAt` | Run time. | `06:00 / 06:04` |
| `TriggerType` | Schedule or Manual. | `Schedule` |
| `DryRun` | 1 = validated only. | `0` |
| `RolesChanged / MembersAdded / MembersRemoved / Errors` | What the run changed. | `1 / 2 / 0 / 0` |

### `sec.AuditLog`

Every change with before and after, for audit. **Maintained by:** System.

| Column | Definition | Example |
|---|---|---|
| `AuditId` | Key. | `118` |
| `EventTime` | When. | `2026-11-22 03:00` |
| `RunId / RequestId` | Links to the run and the request. | `42 / 6` |
| `Action` | What happened. | `REQUEST_EXPIRED` |
| `Target` | What it happened to. | `sam.patel@… ACC-00006` |
| `BeforeJson / AfterJson` | State before and after. | `{"status":"Active"} / {"status":"Expired"}` |
| `Actor / Outcome` | Who did it and the result. | `spn-fabric-secops / Success` |

### `sec.NotificationLog`

Mails to users and approvers. **Maintained by:** System.

| Column | Definition | Example |
|---|---|---|
| `NotificationId` | Key. | `31` |
| `RequestId` | Request it is about. | `6` |
| `NotificationType` | ENABLED, EXPIRY_T7, EXPIRY_T1, REVOKED, … | `EXPIRY_T1` |
| `SentTo / Cc` | Recipient and copy (manager, owner). | `sam.patel@… / yousef.alhajri@…` |
| `ScheduledFor` | When to send. | `2026-11-20 06:00` |
| `Status / Error` | Queued, Sent or Failed. | `Queued` |

## How the pieces combine

`AccessRequest` (who + `RoleTemplate` + scope + dates) → the template's `ObjectRule`, `RowRule` and `ColumnRule` per `Item` → one `RoleBinding` per template + scope + item (for example `PrcBuyerOU102` on LH_PRC_Gold, filter `org_id = '102'`) → Entra group `grp-ol-PrcBuyerOU102` holding everyone with an Active request → `AuditLog` for every change. `sec.vw_UserAccessDetail` shows the whole chain for one person.
