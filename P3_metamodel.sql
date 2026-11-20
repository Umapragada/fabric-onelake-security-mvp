/* =====================================================================
   KDD OneLake security · Phase 3 · metamodel DDL + sample data
   Target : Fabric SQL database SQLDB_SecMeta in WS-SEC-Control
   Run as : Uma (workspace Admin). Re-runnable: drops and recreates schema sec objects.
   Notes  : Fabric GUIDs and Entra object IDs are NULL until Phase 0/4 fill them.
            UPNs are built from @Tenant; change it if your tenant differs.
   Illustrative lab scenario; people, OUs and figures are fictional.
   ===================================================================== */

IF SCHEMA_ID('sec') IS NULL EXEC('CREATE SCHEMA sec');
GO

DROP VIEW IF EXISTS sec.vw_RequestViolations;
DROP VIEW IF EXISTS sec.vw_ExpiringSoon;
DROP VIEW IF EXISTS sec.vw_EffectiveAccess;
DROP TABLE IF EXISTS sec.NotificationLog;
DROP TABLE IF EXISTS sec.AuditLog;
DROP TABLE IF EXISTS sec.SyncRun;
DROP TABLE IF EXISTS sec.RoleBinding;
DROP TABLE IF EXISTS sec.ColumnRule;
DROP TABLE IF EXISTS sec.RowRule;
DROP TABLE IF EXISTS sec.ObjectRule;
DROP TABLE IF EXISTS sec.RoleConflict;
DROP TABLE IF EXISTS sec.AccessRequest;
DROP TABLE IF EXISTS sec.RoleTemplate;
DROP TABLE IF EXISTS sec.ScopeValue;
DROP TABLE IF EXISTS sec.Item;
DROP TABLE IF EXISTS sec.Workspace;
DROP TABLE IF EXISTS sec.Domain;
DROP TABLE IF EXISTS sec.UserProfile;
GO

-- ===== WHO =====
CREATE TABLE sec.UserProfile (
  UserId           INT           NOT NULL PRIMARY KEY,
  UPN              NVARCHAR(256) NOT NULL UNIQUE,
  EntraObjectId    UNIQUEIDENTIFIER NULL,
  DisplayName      NVARCHAR(120) NOT NULL,
  JobTitle         NVARCHAR(120) NULL,
  Department       NVARCHAR(80)  NOT NULL,
  CostCentre       VARCHAR(20)   NULL,
  Country          NVARCHAR(60)  NULL,
  HomeOrgId        VARCHAR(10)   NULL,
  ManagerUPN       NVARCHAR(256) NULL,
  EmploymentStatus VARCHAR(10)   NOT NULL CONSTRAINT CK_User_Status CHECK (EmploymentStatus IN ('Active','Leaver')),
  LeaverDate       DATE          NULL,
  ExistsInTenant   BIT           NOT NULL DEFAULT 0
);

-- ===== WHAT =====
CREATE TABLE sec.Domain (
  DomainId INT NOT NULL PRIMARY KEY, DomainName NVARCHAR(60) NOT NULL UNIQUE,
  FabricDomainId UNIQUEIDENTIFIER NULL, OwnerUPN NVARCHAR(256) NOT NULL, Description NVARCHAR(200) NULL);
CREATE TABLE sec.Workspace (
  WorkspaceKey INT NOT NULL PRIMARY KEY, DomainId INT NULL REFERENCES sec.Domain(DomainId),
  WorkspaceName NVARCHAR(100) NOT NULL UNIQUE, FabricWorkspaceId UNIQUEIDENTIFIER NULL,
  Layer VARCHAR(10) NOT NULL CHECK (Layer IN ('Bronze','Silver','Gold','Control')), IsHidden BIT NOT NULL DEFAULT 0);
CREATE TABLE sec.Item (
  ItemKey INT NOT NULL PRIMARY KEY, WorkspaceKey INT NOT NULL REFERENCES sec.Workspace(WorkspaceKey),
  ItemName NVARCHAR(100) NOT NULL, ItemType VARCHAR(30) NOT NULL, FabricItemId UNIQUEIDENTIFIER NULL,
  OneLakeSecured BIT NOT NULL DEFAULT 0);
CREATE TABLE sec.ScopeValue (
  ScopeType VARCHAR(10) NOT NULL, ScopeValue VARCHAR(10) NOT NULL, Label NVARCHAR(60) NOT NULL, CurrencyCode CHAR(3) NULL,
  CONSTRAINT PK_ScopeValue PRIMARY KEY (ScopeType, ScopeValue));

-- ===== HOW =====
CREATE TABLE sec.RoleTemplate (
  RoleTemplateId INT NOT NULL PRIMARY KEY, RoleCode VARCHAR(40) NOT NULL UNIQUE, DisplayName NVARCHAR(80) NOT NULL,
  DomainId INT NOT NULL REFERENCES sec.Domain(DomainId),
  ScopeType VARCHAR(10) NOT NULL CHECK (ScopeType IN ('ORG_ID','ALL')),
  Layers VARCHAR(30) NOT NULL, WorkspaceRole VARCHAR(20) NOT NULL DEFAULT 'Viewer',
  MaxDays INT NOT NULL CHECK (MaxDays BETWEEN 1 AND 365), RequiresDepartment NVARCHAR(80) NULL,
  IsActive BIT NOT NULL DEFAULT 1, Description NVARCHAR(200) NULL);
CREATE TABLE sec.RoleConflict (
  ConflictId INT NOT NULL PRIMARY KEY, RoleCodeA VARCHAR(40) NOT NULL, RoleCodeB VARCHAR(40) NOT NULL,
  ConflictScope VARCHAR(10) NOT NULL CHECK (ConflictScope IN ('Any','SameScope')), Reason NVARCHAR(200) NOT NULL,
  CONSTRAINT FK_Conflict_A FOREIGN KEY (RoleCodeA) REFERENCES sec.RoleTemplate(RoleCode),
  CONSTRAINT FK_Conflict_B FOREIGN KEY (RoleCodeB) REFERENCES sec.RoleTemplate(RoleCode));
CREATE TABLE sec.ObjectRule (
  RoleTemplateId INT NOT NULL REFERENCES sec.RoleTemplate(RoleTemplateId), ItemKey INT NOT NULL REFERENCES sec.Item(ItemKey),
  TablePath NVARCHAR(200) NOT NULL, CONSTRAINT PK_ObjectRule PRIMARY KEY (RoleTemplateId, ItemKey, TablePath));
CREATE TABLE sec.RowRule (
  RoleTemplateId INT NOT NULL REFERENCES sec.RoleTemplate(RoleTemplateId), ItemKey INT NOT NULL REFERENCES sec.Item(ItemKey),
  TablePath NVARCHAR(200) NOT NULL, FilterColumn SYSNAME NOT NULL,
  CONSTRAINT PK_RowRule PRIMARY KEY (RoleTemplateId, ItemKey, TablePath));
CREATE TABLE sec.ColumnRule (
  RoleTemplateId INT NOT NULL REFERENCES sec.RoleTemplate(RoleTemplateId), ItemKey INT NOT NULL REFERENCES sec.Item(ItemKey),
  TablePath NVARCHAR(200) NOT NULL, AllowedColumns NVARCHAR(MAX) NOT NULL CHECK (ISJSON(AllowedColumns) = 1),
  CONSTRAINT PK_ColumnRule PRIMARY KEY (RoleTemplateId, ItemKey, TablePath));

-- ===== WHO (requests) =====
CREATE TABLE sec.AccessRequest (
  RequestId INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
  RequestNumber AS ('ACC-' + RIGHT('00000' + CAST(RequestId AS VARCHAR(10)), 5)) PERSISTED,
  TicketRef VARCHAR(30) NULL, RequestType VARCHAR(10) NOT NULL CHECK (RequestType IN ('New','Extend','Remove')),
  UserId INT NOT NULL REFERENCES sec.UserProfile(UserId),
  RoleTemplateId INT NOT NULL REFERENCES sec.RoleTemplate(RoleTemplateId),
  ScopeValue VARCHAR(10) NOT NULL,
  ScopeType AS (CAST(CASE WHEN ScopeValue = 'ALL' THEN 'ALL' ELSE 'ORG_ID' END AS VARCHAR(10))) PERSISTED NOT NULL,
  StartDate DATE NOT NULL, EndDate DATE NOT NULL,
  ReasonCategory VARCHAR(30) NOT NULL, Justification NVARCHAR(500) NOT NULL,
  RequestedByUPN NVARCHAR(256) NOT NULL, ApproverUPN NVARCHAR(256) NULL, ApprovedAt DATETIME2(0) NULL,
  Status VARCHAR(10) NOT NULL CHECK (Status IN ('Pending','Approved','Active','Rejected','Expired','Revoked')),
  StatusReason NVARCHAR(200) NULL, CreatedAt DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
  CONSTRAINT CK_Req_Dates CHECK (EndDate > StartDate),
  CONSTRAINT FK_Req_Scope FOREIGN KEY (ScopeType, ScopeValue) REFERENCES sec.ScopeValue(ScopeType, ScopeValue));

-- ===== GENERATED =====
CREATE TABLE sec.RoleBinding (
  RoleName VARCHAR(80) NOT NULL, ItemKey INT NOT NULL REFERENCES sec.Item(ItemKey),
  RoleTemplateId INT NOT NULL REFERENCES sec.RoleTemplate(RoleTemplateId), ScopeValue VARCHAR(10) NOT NULL,
  EntraGroupName NVARCHAR(120) NOT NULL, EntraGroupId UNIQUEIDENTIFIER NULL, MemberCount INT NOT NULL DEFAULT 0,
  RoleJson NVARCHAR(MAX) NOT NULL CHECK (ISJSON(RoleJson) = 1), RoleHash AS CONVERT(CHAR(64), HASHBYTES('SHA2_256', RoleJson), 2) PERSISTED,
  Status VARCHAR(10) NOT NULL CHECK (Status IN ('Planned','Applied','Removed')), AppliedAt DATETIME2(0) NULL,
  CONSTRAINT PK_RoleBinding PRIMARY KEY (RoleName, ItemKey));

-- ===== EVIDENCE =====
CREATE TABLE sec.SyncRun (
  RunId INT NOT NULL PRIMARY KEY, StartedAt DATETIME2(0) NOT NULL, EndedAt DATETIME2(0) NULL,
  TriggerType VARCHAR(10) NOT NULL, DryRun BIT NOT NULL, RolesChanged INT NOT NULL, MembersAdded INT NOT NULL,
  MembersRemoved INT NOT NULL, Errors INT NOT NULL);
CREATE TABLE sec.AuditLog (
  AuditId INT IDENTITY(1,1) NOT NULL PRIMARY KEY, EventTime DATETIME2(0) NOT NULL,
  RunId INT NULL REFERENCES sec.SyncRun(RunId), RequestId INT NULL REFERENCES sec.AccessRequest(RequestId),
  Action VARCHAR(30) NOT NULL, Target NVARCHAR(200) NOT NULL, BeforeJson NVARCHAR(MAX) NULL, AfterJson NVARCHAR(MAX) NULL,
  Actor NVARCHAR(256) NOT NULL, Outcome VARCHAR(10) NOT NULL);
CREATE TABLE sec.NotificationLog (
  NotificationId INT IDENTITY(1,1) NOT NULL PRIMARY KEY, RequestId INT NOT NULL REFERENCES sec.AccessRequest(RequestId),
  NotificationType VARCHAR(20) NOT NULL CHECK (NotificationType IN ('APPROVAL_REQUEST','APPROVED','REJECTED','ENABLED','EXPIRY_T7','EXPIRY_T1','EXTENDED','REVOKED')),
  SentTo NVARCHAR(256) NOT NULL, Cc NVARCHAR(500) NULL, ScheduledFor DATETIME2(0) NOT NULL,
  Status VARCHAR(10) NOT NULL CHECK (Status IN ('Queued','Sent','Failed')), Error NVARCHAR(300) NULL);
GO

DECLARE @Tenant NVARCHAR(100) = N'hiteshtaneja307gmail380.onmicrosoft.com';  -- change if needed

-- UserProfile
INSERT INTO sec.UserProfile (UserId,UPN,EntraObjectId,DisplayName,JobTitle,Department,CostCentre,Country,HomeOrgId,ManagerUPN,EmploymentStatus,LeaverDate,ExistsInTenant) VALUES
(1,N'umapragada@' + @Tenant,NULL,N'Uma Pragada',N'Data Security Lead',N'Data Governance',N'CC-IT-410',N'Kuwait',N'101',N'hamad.alfahad@' + @Tenant,N'Active',NULL,1),
(2,N'datasteward@' + @Tenant,NULL,N'Data Steward',N'Buyer, Dairy Raw Materials',N'Procurement',N'CC-PRC-220',N'Saudi Arabia',N'102',N'omar.alrashidi@' + @Tenant,N'Active',NULL,1),
(3,N'emma.clarke@' + @Tenant,NULL,N'Emma Clarke',N'Demand Planner',N'Procurement',N'CC-PRC-210',N'Kuwait',N'101',N'omar.alrashidi@' + @Tenant,N'Active',NULL,0),
(4,N'lukas.weber@' + @Tenant,NULL,N'Lukas Weber',N'AP Clerk',N'Finance - Accounts Payable',N'CC-FIN-310',N'UAE',N'103',N'fatima.alenezi@' + @Tenant,N'Active',NULL,0),
(5,N'priya.nair@' + @Tenant,NULL,N'Priya Nair',N'Treasury Analyst',N'Finance - Treasury',N'CC-FIN-330',N'Kuwait',N'101',N'fatima.alenezi@' + @Tenant,N'Active',NULL,0),
(6,N'sam.patel@' + @Tenant,NULL,N'Sam Patel',N'Internal Auditor',N'Internal Audit',N'CC-AUD-510',N'Kuwait',N'101',N'yousef.alhajri@' + @Tenant,N'Active',NULL,0),
(7,N'maryam.alajmi@' + @Tenant,NULL,N'Maryam Al-Ajmi',N'Data Steward, Finance Data',N'Data Governance',N'CC-IT-420',N'Kuwait',N'101',N'umapragada@' + @Tenant,N'Active',NULL,0),
(8,N'noura.almutairi@' + @Tenant,NULL,N'Noura Al-Mutairi',N'Buyer, Packaging',N'Procurement',N'CC-PRC-220',N'Kuwait',N'101',N'omar.alrashidi@' + @Tenant,N'Active',NULL,0),
(9,N'khalid.alazmi@' + @Tenant,NULL,N'Khalid Al-Azmi',N'AP Clerk',N'Finance - Accounts Payable',N'CC-FIN-310',N'Kuwait',N'101',N'fatima.alenezi@' + @Tenant,N'Leaver',N'2026-11-09',0),
(10,N'reem.alkandari@' + @Tenant,NULL,N'Reem Al-Kandari',N'Demand Planner',N'Procurement',N'CC-PRC-210',N'Saudi Arabia',N'102',N'omar.alrashidi@' + @Tenant,N'Active',NULL,0),
(11,N'ahmed.hassan@' + @Tenant,NULL,N'Ahmed Hassan',N'AP Clerk',N'Finance - Accounts Payable',N'CC-FIN-310',N'UAE',N'103',N'fatima.alenezi@' + @Tenant,N'Active',NULL,0),
(12,N'omar.alrashidi@' + @Tenant,NULL,N'Omar Al-Rashidi',N'Head of Procurement',N'Procurement',N'CC-PRC-200',N'Kuwait',N'101',N'hamad.alfahad@' + @Tenant,N'Active',NULL,0),
(13,N'fatima.alenezi@' + @Tenant,NULL,N'Fatima Al-Enezi',N'Finance Controller',N'Finance',N'CC-FIN-300',N'Kuwait',N'101',N'hamad.alfahad@' + @Tenant,N'Active',NULL,0),
(14,N'yousef.alhajri@' + @Tenant,NULL,N'Yousef Al-Hajri',N'Head of Internal Audit',N'Internal Audit',N'CC-AUD-500',N'Kuwait',N'101',N'hamad.alfahad@' + @Tenant,N'Active',NULL,0),
(15,N'hamad.alfahad@' + @Tenant,NULL,N'Hamad Al-Fahad',N'Chief Digital Officer',N'IT',N'CC-IT-400',N'Kuwait',N'101',NULL,N'Active',NULL,0);

INSERT INTO sec.Domain (DomainId,DomainName,FabricDomainId,OwnerUPN,Description) VALUES
(1,N'Procurement',NULL,N'omar.alrashidi@' + @Tenant,N'Purchasing, receipts, items and categories'),
(2,N'Payables',NULL,N'fatima.alenezi@' + @Tenant,N'Suppliers, invoices, payments and bank accounts');

INSERT INTO sec.Workspace (WorkspaceKey,DomainId,WorkspaceName,FabricWorkspaceId,Layer,IsHidden) VALUES
(1,1,N'WS-PRC-Bronze',NULL,N'Bronze',0),
(2,1,N'WS-PRC-Silver',NULL,N'Silver',0),
(3,1,N'WS-PRC-Gold',NULL,N'Gold',0),
(4,2,N'WS-AP-Bronze',NULL,N'Bronze',0),
(5,2,N'WS-AP-Silver',NULL,N'Silver',0),
(6,2,N'WS-AP-Gold',NULL,N'Gold',0),
(7,NULL,N'WS-SEC-Control',NULL,N'Control',1);

INSERT INTO sec.Item (ItemKey,WorkspaceKey,ItemName,ItemType,FabricItemId,OneLakeSecured) VALUES
(1,1,N'LH_PRC_Bronze',N'Lakehouse',NULL,0),
(2,2,N'LH_PRC_Silver',N'Lakehouse',NULL,1),
(3,3,N'LH_PRC_Gold',N'Lakehouse',NULL,1),
(4,3,N'SM_Procurement',N'SemanticModel',NULL,0),
(5,3,N'DA_Procurement',N'DataAgent',NULL,0),
(6,4,N'LH_AP_Bronze',N'Lakehouse',NULL,0),
(7,5,N'LH_AP_Silver',N'Lakehouse',NULL,1),
(8,6,N'LH_AP_Gold',N'Lakehouse',NULL,1),
(9,6,N'SM_Payables',N'SemanticModel',NULL,0),
(10,6,N'DA_Payables',N'DataAgent',NULL,0),
(11,7,N'SQLDB_SecMeta',N'SQLDatabase',NULL,0),
(12,7,N'NB_SEC_Sync',N'Notebook',NULL,0),
(13,7,N'PL_SEC_Lifecycle',N'DataPipeline',NULL,0),
(14,7,N'RPT_SEC_Admin',N'Report',NULL,0);

INSERT INTO sec.ScopeValue (ScopeType,ScopeValue,Label,CurrencyCode) VALUES
(N'ORG_ID',N'101',N'KDD Kuwait',N'KWD'),
(N'ORG_ID',N'102',N'KDD Saudi Arabia',N'SAR'),
(N'ORG_ID',N'103',N'KDD UAE',N'AED'),
(N'ALL',N'ALL',N'All operating units',NULL);

INSERT INTO sec.RoleTemplate (RoleTemplateId,RoleCode,DisplayName,DomainId,ScopeType,Layers,WorkspaceRole,MaxDays,RequiresDepartment,IsActive,Description) VALUES
(1,N'PrcBuyer',N'Procurement buyer',1,N'ORG_ID',N'Gold','Viewer',180,NULL,1,N'POs, receipts and supplier names for one operating unit'),
(2,N'PrcPlanner',N'Demand planner',1,N'ORG_ID',N'Gold','Viewer',180,NULL,1,N'PO quantities and dates for one operating unit, no prices'),
(3,N'PrcSteward',N'Procurement data steward',1,N'ALL',N'Silver','Viewer',365,N'Data Governance',1,N'All Procurement Silver tables, all operating units'),
(4,N'PrcAuditor',N'Procurement auditor',1,N'ALL',N'Silver, Gold','Viewer',30,N'Internal Audit',1,N'Procurement Silver and Gold, all OUs, no VAT number'),
(5,N'ApClerk',N'AP clerk',2,N'ORG_ID',N'Gold','Viewer',180,NULL,1,N'Invoices and payment status for one operating unit, no bank accounts'),
(6,N'ApTreasury',N'Treasury analyst',2,N'ALL',N'Gold','Viewer',90,N'Finance - Treasury',1,N'Payments and supplier bank accounts, all operating units'),
(7,N'ApSteward',N'Payables data steward',2,N'ALL',N'Silver','Viewer',365,N'Data Governance',1,N'All Payables Silver tables except bank accounts'),
(8,N'ApAuditor',N'Payables auditor',2,N'ALL',N'Silver, Gold','Viewer',30,N'Internal Audit',1,N'Payables Silver and Gold, all OUs, no bank or VAT data');

INSERT INTO sec.RoleConflict (ConflictId,RoleCodeA,RoleCodeB,ConflictScope,Reason) VALUES
(1,N'PrcBuyer',N'ApClerk',N'SameScope',N'A buyer may not process invoices for POs in the same operating unit'),
(2,N'ApClerk',N'ApTreasury',N'Any',N'Invoice entry and payment release must be done by different people');

-- ObjectRule (OLS): tables each role may read. silver.supplier in LH_PRC_Silver is a shortcut to LH_AP_Silver, so it is secured there.
INSERT INTO sec.ObjectRule (RoleTemplateId,ItemKey,TablePath) VALUES
(1,3,N'/Tables/gold/fact_purchase_order'),
(1,3,N'/Tables/gold/fact_receipt'),
(1,3,N'/Tables/gold/dim_supplier'),
(1,3,N'/Tables/gold/dim_item'),
(1,3,N'/Tables/gold/dim_org'),
(1,3,N'/Tables/gold/dim_date'),
(2,3,N'/Tables/gold/fact_purchase_order'),
(2,3,N'/Tables/gold/fact_receipt'),
(2,3,N'/Tables/gold/dim_item'),
(2,3,N'/Tables/gold/dim_org'),
(2,3,N'/Tables/gold/dim_date'),
(3,2,N'/Tables/silver/po_header'),
(3,2,N'/Tables/silver/po_line'),
(3,2,N'/Tables/silver/receipt'),
(3,2,N'/Tables/silver/item'),
(3,2,N'/Tables/silver/requisition'),
(4,2,N'/Tables/silver/po_header'),
(4,2,N'/Tables/silver/po_line'),
(4,2,N'/Tables/silver/receipt'),
(4,2,N'/Tables/silver/item'),
(4,2,N'/Tables/silver/requisition'),
(4,3,N'/Tables/gold/fact_purchase_order'),
(4,3,N'/Tables/gold/fact_receipt'),
(4,3,N'/Tables/gold/dim_supplier'),
(4,3,N'/Tables/gold/dim_item'),
(4,3,N'/Tables/gold/dim_org'),
(4,3,N'/Tables/gold/dim_date'),
(5,8,N'/Tables/gold/fact_invoice'),
(5,8,N'/Tables/gold/fact_payment'),
(5,8,N'/Tables/gold/dim_supplier'),
(5,8,N'/Tables/gold/dim_org'),
(5,8,N'/Tables/gold/dim_date'),
(6,8,N'/Tables/gold/fact_payment'),
(6,8,N'/Tables/gold/dim_bank_account'),
(6,8,N'/Tables/gold/dim_supplier'),
(6,8,N'/Tables/gold/dim_org'),
(6,8,N'/Tables/gold/dim_date'),
(7,7,N'/Tables/silver/supplier'),
(7,7,N'/Tables/silver/supplier_site'),
(7,7,N'/Tables/silver/invoice'),
(7,7,N'/Tables/silver/invoice_line'),
(7,7,N'/Tables/silver/payment'),
(8,7,N'/Tables/silver/supplier'),
(8,7,N'/Tables/silver/supplier_site'),
(8,7,N'/Tables/silver/invoice'),
(8,7,N'/Tables/silver/invoice_line'),
(8,7,N'/Tables/silver/payment'),
(8,8,N'/Tables/gold/fact_invoice'),
(8,8,N'/Tables/gold/fact_payment'),
(8,8,N'/Tables/gold/dim_supplier'),
(8,8,N'/Tables/gold/dim_org'),
(8,8,N'/Tables/gold/dim_date');

-- RowRule (RLS): the value comes from AccessRequest.ScopeValue at compile time
INSERT INTO sec.RowRule (RoleTemplateId,ItemKey,TablePath,FilterColumn) VALUES
(1,3,N'/Tables/gold/fact_purchase_order',N'org_id'),
(1,3,N'/Tables/gold/fact_receipt',N'org_id'),
(2,3,N'/Tables/gold/fact_purchase_order',N'org_id'),
(2,3,N'/Tables/gold/fact_receipt',N'org_id'),
(5,8,N'/Tables/gold/fact_invoice',N'org_id'),
(5,8,N'/Tables/gold/fact_payment',N'org_id');

-- ColumnRule (CLS): allowed columns, case-sensitive; anything not listed is hidden
INSERT INTO sec.ColumnRule (RoleTemplateId,ItemKey,TablePath,AllowedColumns) VALUES
(1,3,N'/Tables/gold/dim_supplier',N'["supplier_key", "supplier_id", "supplier_name", "category", "country", "payment_terms", "is_current"]'),
(2,3,N'/Tables/gold/fact_purchase_order',N'["po_line_key", "po_number", "line_number", "org_id", "supplier_key", "item_key", "order_date_key", "need_by_date_key", "quantity", "uom", "currency_code", "status"]'),
(4,3,N'/Tables/gold/dim_supplier',N'["supplier_key", "supplier_id", "supplier_name", "category", "country", "payment_terms", "is_current", "valid_from", "valid_to"]'),
(5,8,N'/Tables/gold/dim_supplier',N'["supplier_key", "supplier_id", "supplier_name", "category", "country", "payment_terms", "is_current", "valid_from", "valid_to"]'),
(8,7,N'/Tables/silver/supplier',N'["supplier_id", "supplier_name", "country", "category", "payment_terms", "is_current", "valid_from", "valid_to"]'),
(8,8,N'/Tables/gold/dim_supplier',N'["supplier_key", "supplier_id", "supplier_name", "category", "country", "payment_terms", "is_current", "valid_from", "valid_to"]');

SET IDENTITY_INSERT sec.AccessRequest ON;
INSERT INTO sec.AccessRequest (RequestId,TicketRef,RequestType,UserId,RoleTemplateId,ScopeValue,StartDate,EndDate,ReasonCategory,Justification,RequestedByUPN,ApproverUPN,ApprovedAt,Status,StatusReason,CreatedAt) VALUES
(1,N'RITM0010481',N'New',2,1,N'102',N'2026-11-18',N'2027-02-15',N'New joiner',N'Joined KSA buying team for dairy raw materials; needs PO and receipt history for OU 102',N'omar.alrashidi@' + @Tenant,N'omar.alrashidi@' + @Tenant,N'2026-11-16 14:40:00',N'Active',NULL,N'2026-11-16 10:12:00'),
(2,N'RITM0010482',N'New',3,2,N'101',N'2026-11-18',N'2026-12-31',N'Project',N'Q1 2027 Ramadan demand plan for Kuwait juices and dairy lines',N'emma.clarke@' + @Tenant,N'omar.alrashidi@' + @Tenant,N'2026-11-16 14:41:00',N'Active',NULL,N'2026-11-16 11:05:00'),
(3,N'RITM0010483',N'New',4,5,N'103',N'2026-11-18',N'2027-02-15',N'Role change',N'Moved from AR to AP for the UAE operating unit',N'fatima.alenezi@' + @Tenant,N'fatima.alenezi@' + @Tenant,N'2026-11-17 09:02:00',N'Active',NULL,N'2026-11-16 12:30:00'),
(4,N'RITM0010377',N'New',4,5,N'101',N'2026-11-01',N'2026-12-15',N'Cover for colleague',N'Covering Kuwait AP backlog until replacement for Khalid joins',N'fatima.alenezi@' + @Tenant,N'fatima.alenezi@' + @Tenant,N'2026-10-29 13:10:00',N'Active',NULL,N'2026-10-29 08:44:00'),
(5,N'RITM0010484',N'New',5,6,N'ALL',N'2026-11-18',N'2027-02-15',N'New joiner',N'Treasury analyst responsible for GCC supplier payment runs',N'fatima.alenezi@' + @Tenant,N'fatima.alenezi@' + @Tenant,N'2026-11-17 09:05:00',N'Active',NULL,N'2026-11-16 13:00:00'),
(6,N'RITM0010490',N'New',6,4,N'ALL',N'2026-11-18',N'2026-11-21',N'Audit',N'IA-2026-14 procure-to-pay controls review, fieldwork week',N'yousef.alhajri@' + @Tenant,N'omar.alrashidi@' + @Tenant,N'2026-11-17 10:15:00',N'Active',NULL,N'2026-11-17 08:20:00'),
(7,N'RITM0010491',N'New',6,8,N'ALL',N'2026-11-18',N'2026-11-21',N'Audit',N'IA-2026-14 procure-to-pay controls review, fieldwork week',N'yousef.alhajri@' + @Tenant,N'fatima.alenezi@' + @Tenant,N'2026-11-17 10:16:00',N'Active',NULL,N'2026-11-17 08:21:00'),
(8,N'RITM0009920',N'New',7,3,N'ALL',N'2026-09-01',N'2027-08-31',N'Role change',N'Owns data quality rules for Procurement Silver',N'umapragada@' + @Tenant,N'omar.alrashidi@' + @Tenant,N'2026-08-26 11:30:00',N'Active',NULL,N'2026-08-25 09:00:00'),
(9,N'RITM0009921',N'New',7,7,N'ALL',N'2026-09-01',N'2027-08-31',N'Role change',N'Owns data quality rules for Payables Silver',N'umapragada@' + @Tenant,N'fatima.alenezi@' + @Tenant,N'2026-08-26 11:31:00',N'Active',NULL,N'2026-08-25 09:02:00'),
(10,N'RITM0009512',N'New',8,1,N'101',N'2026-08-01',N'2026-10-31',N'Project',N'Packaging tender for 2026 ice cream season',N'omar.alrashidi@' + @Tenant,N'omar.alrashidi@' + @Tenant,N'2026-07-28 15:20:00',N'Expired',N'End date reached',N'2026-07-28 10:00:00'),
(11,N'RITM0009104',N'New',9,5,N'101',N'2026-06-01',N'2026-11-30',N'New joiner',N'Kuwait AP processing',N'fatima.alenezi@' + @Tenant,N'fatima.alenezi@' + @Tenant,N'2026-05-27 10:00:00',N'Revoked',N'Leaver on 2026-11-09',N'2026-05-26 09:30:00'),
(12,N'RITM0010495',N'New',10,2,N'102',N'2026-11-20',N'2027-05-18',N'New joiner',N'KSA demand planning for laban and fresh milk',N'omar.alrashidi@' + @Tenant,NULL,NULL,N'Pending',NULL,N'2026-11-18 09:40:00'),
(13,N'RITM0010486',N'New',3,1,N'101',N'2027-01-01',N'2027-03-31',N'Role change',N'Moves to Kuwait buying team from January',N'omar.alrashidi@' + @Tenant,N'omar.alrashidi@' + @Tenant,N'2026-11-17 09:30:00',N'Approved',NULL,N'2026-11-16 15:10:00'),
(14,N'RITM0010022',N'New',11,5,N'103',N'2026-10-01',N'2027-03-29',N'New joiner',N'UAE AP processing',N'fatima.alenezi@' + @Tenant,N'fatima.alenezi@' + @Tenant,N'2026-09-28 16:00:00',N'Active',NULL,N'2026-09-28 10:00:00'),
(15,N'RITM0010492',N'New',11,1,N'103',N'2026-11-20',N'2027-02-15',N'Project',N'Help UAE buying during peak',N'ahmed.hassan@' + @Tenant,N'omar.alrashidi@' + @Tenant,NULL,N'Rejected',N'Segregation of duties: already holds ApClerk for OU 103',N'2026-11-17 11:00:00'),
(16,N'RITM0010496',N'Extend',6,4,N'ALL',N'2026-11-18',N'2026-11-28',N'Audit',N'Fieldwork extended by one week',N'yousef.alhajri@' + @Tenant,NULL,NULL,N'Pending',NULL,N'2026-11-18 16:45:00');
SET IDENTITY_INSERT sec.AccessRequest OFF;

-- RoleBinding: what NB_SEC_Sync compiled. {{TenantId}} and {{EntraGroupId}} are filled at apply time.
INSERT INTO sec.RoleBinding (RoleName,ItemKey,RoleTemplateId,ScopeValue,EntraGroupName,EntraGroupId,MemberCount,RoleJson,Status,AppliedAt) VALUES
(N'PrcBuyerOU102',3,1,N'102',N'grp-ol-PrcBuyerOU102',NULL,1,N'{"name":"PrcBuyerOU102","decisionRules":[{"effect":"Permit","permission":[{"attributeName":"Path","attributeValueIncludedIn":["/Tables/gold/fact_purchase_order","/Tables/gold/fact_receipt","/Tables/gold/dim_supplier","/Tables/gold/dim_item","/Tables/gold/dim_org","/Tables/gold/dim_date"]},{"attributeName":"Action","attributeValueIncludedIn":["Read"]}],"constraints":{"rows":[{"tablePath":"/Tables/gold/fact_purchase_order","value":"SELECT * FROM gold.fact_purchase_order WHERE org_id = 102"},{"tablePath":"/Tables/gold/fact_receipt","value":"SELECT * FROM gold.fact_receipt WHERE org_id = 102"}],"columns":[{"tablePath":"/Tables/gold/dim_supplier","columnNames":["supplier_key","supplier_id","supplier_name","category","country","payment_terms","is_current"],"columnEffect":"Permit","columnAction":"Read"}]}}],"members":{"microsoftEntraMembers":[{"tenantId":"{{TenantId}}","objectId":"{{EntraGroupId}}","objectType":"Group"}]}}',N'Applied',N'2026-11-18 06:06:00'),
(N'PrcPlannerOU101',3,2,N'101',N'grp-ol-PrcPlannerOU101',NULL,1,N'{"name":"PrcPlannerOU101","decisionRules":[{"effect":"Permit","permission":[{"attributeName":"Path","attributeValueIncludedIn":["/Tables/gold/fact_purchase_order","/Tables/gold/fact_receipt","/Tables/gold/dim_item","/Tables/gold/dim_org","/Tables/gold/dim_date"]},{"attributeName":"Action","attributeValueIncludedIn":["Read"]}],"constraints":{"rows":[{"tablePath":"/Tables/gold/fact_purchase_order","value":"SELECT * FROM gold.fact_purchase_order WHERE org_id = 101"},{"tablePath":"/Tables/gold/fact_receipt","value":"SELECT * FROM gold.fact_receipt WHERE org_id = 101"}],"columns":[{"tablePath":"/Tables/gold/fact_purchase_order","columnNames":["po_line_key","po_number","line_number","org_id","supplier_key","item_key","order_date_key","need_by_date_key","quantity","uom","currency_code","status"],"columnEffect":"Permit","columnAction":"Read"}]}}],"members":{"microsoftEntraMembers":[{"tenantId":"{{TenantId}}","objectId":"{{EntraGroupId}}","objectType":"Group"}]}}',N'Applied',N'2026-11-18 06:06:00'),
(N'ApClerkOU103',8,5,N'103',N'grp-ol-ApClerkOU103',NULL,2,N'{"name":"ApClerkOU103","decisionRules":[{"effect":"Permit","permission":[{"attributeName":"Path","attributeValueIncludedIn":["/Tables/gold/fact_invoice","/Tables/gold/fact_payment","/Tables/gold/dim_supplier","/Tables/gold/dim_org","/Tables/gold/dim_date"]},{"attributeName":"Action","attributeValueIncludedIn":["Read"]}],"constraints":{"rows":[{"tablePath":"/Tables/gold/fact_invoice","value":"SELECT * FROM gold.fact_invoice WHERE org_id = 103"},{"tablePath":"/Tables/gold/fact_payment","value":"SELECT * FROM gold.fact_payment WHERE org_id = 103"}],"columns":[{"tablePath":"/Tables/gold/dim_supplier","columnNames":["supplier_key","supplier_id","supplier_name","category","country","payment_terms","is_current","valid_from","valid_to"],"columnEffect":"Permit","columnAction":"Read"}]}}],"members":{"microsoftEntraMembers":[{"tenantId":"{{TenantId}}","objectId":"{{EntraGroupId}}","objectType":"Group"}]}}',N'Applied',N'2026-11-18 06:06:00'),
(N'ApClerkOU101',8,5,N'101',N'grp-ol-ApClerkOU101',NULL,1,N'{"name":"ApClerkOU101","decisionRules":[{"effect":"Permit","permission":[{"attributeName":"Path","attributeValueIncludedIn":["/Tables/gold/fact_invoice","/Tables/gold/fact_payment","/Tables/gold/dim_supplier","/Tables/gold/dim_org","/Tables/gold/dim_date"]},{"attributeName":"Action","attributeValueIncludedIn":["Read"]}],"constraints":{"rows":[{"tablePath":"/Tables/gold/fact_invoice","value":"SELECT * FROM gold.fact_invoice WHERE org_id = 101"},{"tablePath":"/Tables/gold/fact_payment","value":"SELECT * FROM gold.fact_payment WHERE org_id = 101"}],"columns":[{"tablePath":"/Tables/gold/dim_supplier","columnNames":["supplier_key","supplier_id","supplier_name","category","country","payment_terms","is_current","valid_from","valid_to"],"columnEffect":"Permit","columnAction":"Read"}]}}],"members":{"microsoftEntraMembers":[{"tenantId":"{{TenantId}}","objectId":"{{EntraGroupId}}","objectType":"Group"}]}}',N'Applied',N'2026-11-18 06:06:00'),
(N'ApTreasuryAll',8,6,N'ALL',N'grp-ol-ApTreasuryAll',NULL,1,N'{"name":"ApTreasuryAll","decisionRules":[{"effect":"Permit","permission":[{"attributeName":"Path","attributeValueIncludedIn":["/Tables/gold/fact_payment","/Tables/gold/dim_bank_account","/Tables/gold/dim_supplier","/Tables/gold/dim_org","/Tables/gold/dim_date"]},{"attributeName":"Action","attributeValueIncludedIn":["Read"]}]}],"members":{"microsoftEntraMembers":[{"tenantId":"{{TenantId}}","objectId":"{{EntraGroupId}}","objectType":"Group"}]}}',N'Applied',N'2026-11-18 06:06:00'),
(N'PrcAuditorAll',2,4,N'ALL',N'grp-ol-PrcAuditorAll',NULL,1,N'{"name":"PrcAuditorAll","decisionRules":[{"effect":"Permit","permission":[{"attributeName":"Path","attributeValueIncludedIn":["/Tables/silver/po_header","/Tables/silver/po_line","/Tables/silver/receipt","/Tables/silver/item","/Tables/silver/requisition"]},{"attributeName":"Action","attributeValueIncludedIn":["Read"]}]}],"members":{"microsoftEntraMembers":[{"tenantId":"{{TenantId}}","objectId":"{{EntraGroupId}}","objectType":"Group"}]}}',N'Applied',N'2026-11-18 06:06:00'),
(N'PrcAuditorAll',3,4,N'ALL',N'grp-ol-PrcAuditorAll',NULL,1,N'{"name":"PrcAuditorAll","decisionRules":[{"effect":"Permit","permission":[{"attributeName":"Path","attributeValueIncludedIn":["/Tables/gold/fact_purchase_order","/Tables/gold/fact_receipt","/Tables/gold/dim_supplier","/Tables/gold/dim_item","/Tables/gold/dim_org","/Tables/gold/dim_date"]},{"attributeName":"Action","attributeValueIncludedIn":["Read"]}],"constraints":{"columns":[{"tablePath":"/Tables/gold/dim_supplier","columnNames":["supplier_key","supplier_id","supplier_name","category","country","payment_terms","is_current","valid_from","valid_to"],"columnEffect":"Permit","columnAction":"Read"}]}}],"members":{"microsoftEntraMembers":[{"tenantId":"{{TenantId}}","objectId":"{{EntraGroupId}}","objectType":"Group"}]}}',N'Applied',N'2026-11-18 06:06:00'),
(N'ApAuditorAll',7,8,N'ALL',N'grp-ol-ApAuditorAll',NULL,1,N'{"name":"ApAuditorAll","decisionRules":[{"effect":"Permit","permission":[{"attributeName":"Path","attributeValueIncludedIn":["/Tables/silver/supplier","/Tables/silver/supplier_site","/Tables/silver/invoice","/Tables/silver/invoice_line","/Tables/silver/payment"]},{"attributeName":"Action","attributeValueIncludedIn":["Read"]}],"constraints":{"columns":[{"tablePath":"/Tables/silver/supplier","columnNames":["supplier_id","supplier_name","country","category","payment_terms","is_current","valid_from","valid_to"],"columnEffect":"Permit","columnAction":"Read"}]}}],"members":{"microsoftEntraMembers":[{"tenantId":"{{TenantId}}","objectId":"{{EntraGroupId}}","objectType":"Group"}]}}',N'Applied',N'2026-11-18 06:06:00'),
(N'ApAuditorAll',8,8,N'ALL',N'grp-ol-ApAuditorAll',NULL,1,N'{"name":"ApAuditorAll","decisionRules":[{"effect":"Permit","permission":[{"attributeName":"Path","attributeValueIncludedIn":["/Tables/gold/fact_invoice","/Tables/gold/fact_payment","/Tables/gold/dim_supplier","/Tables/gold/dim_org","/Tables/gold/dim_date"]},{"attributeName":"Action","attributeValueIncludedIn":["Read"]}],"constraints":{"columns":[{"tablePath":"/Tables/gold/dim_supplier","columnNames":["supplier_key","supplier_id","supplier_name","category","country","payment_terms","is_current","valid_from","valid_to"],"columnEffect":"Permit","columnAction":"Read"}]}}],"members":{"microsoftEntraMembers":[{"tenantId":"{{TenantId}}","objectId":"{{EntraGroupId}}","objectType":"Group"}]}}',N'Applied',N'2026-11-18 06:06:00'),
(N'PrcStewardAll',2,3,N'ALL',N'grp-ol-PrcStewardAll',NULL,1,N'{"name":"PrcStewardAll","decisionRules":[{"effect":"Permit","permission":[{"attributeName":"Path","attributeValueIncludedIn":["/Tables/silver/po_header","/Tables/silver/po_line","/Tables/silver/receipt","/Tables/silver/item","/Tables/silver/requisition"]},{"attributeName":"Action","attributeValueIncludedIn":["Read"]}]}],"members":{"microsoftEntraMembers":[{"tenantId":"{{TenantId}}","objectId":"{{EntraGroupId}}","objectType":"Group"}]}}',N'Applied',N'2026-11-18 06:06:00'),
(N'ApStewardAll',7,7,N'ALL',N'grp-ol-ApStewardAll',NULL,1,N'{"name":"ApStewardAll","decisionRules":[{"effect":"Permit","permission":[{"attributeName":"Path","attributeValueIncludedIn":["/Tables/silver/supplier","/Tables/silver/supplier_site","/Tables/silver/invoice","/Tables/silver/invoice_line","/Tables/silver/payment"]},{"attributeName":"Action","attributeValueIncludedIn":["Read"]}]}],"members":{"microsoftEntraMembers":[{"tenantId":"{{TenantId}}","objectId":"{{EntraGroupId}}","objectType":"Group"}]}}',N'Applied',N'2026-11-18 06:06:00'),
(N'PrcBuyerOU101',3,1,N'101',N'grp-ol-PrcBuyerOU101',NULL,0,N'{"name":"PrcBuyerOU101","decisionRules":[{"effect":"Permit","permission":[{"attributeName":"Path","attributeValueIncludedIn":["/Tables/gold/fact_purchase_order","/Tables/gold/fact_receipt","/Tables/gold/dim_supplier","/Tables/gold/dim_item","/Tables/gold/dim_org","/Tables/gold/dim_date"]},{"attributeName":"Action","attributeValueIncludedIn":["Read"]}],"constraints":{"rows":[{"tablePath":"/Tables/gold/fact_purchase_order","value":"SELECT * FROM gold.fact_purchase_order WHERE org_id = 101"},{"tablePath":"/Tables/gold/fact_receipt","value":"SELECT * FROM gold.fact_receipt WHERE org_id = 101"}],"columns":[{"tablePath":"/Tables/gold/dim_supplier","columnNames":["supplier_key","supplier_id","supplier_name","category","country","payment_terms","is_current"],"columnEffect":"Permit","columnAction":"Read"}]}}],"members":{"microsoftEntraMembers":[{"tenantId":"{{TenantId}}","objectId":"{{EntraGroupId}}","objectType":"Group"}]}}',N'Planned',NULL);

INSERT INTO sec.SyncRun (RunId,StartedAt,EndedAt,TriggerType,DryRun,RolesChanged,MembersAdded,MembersRemoved,Errors) VALUES
(1,N'2026-11-01 06:00:00',N'2026-11-01 06:03:41',N'Scheduled',0,1,1,1,0),
(2,N'2026-11-10 06:00:00',N'2026-11-10 06:02:12',N'Scheduled',0,0,0,1,0),
(3,N'2026-11-17 06:00:00',N'2026-11-17 06:01:58',N'Scheduled',0,0,0,0,0),
(4,N'2026-11-18 06:00:00',N'2026-11-18 06:07:25',N'Scheduled',0,5,6,0,0),
(5,N'2026-11-18 18:20:00',N'2026-11-18 18:21:04',N'OnDemand',1,0,0,0,0);

INSERT INTO sec.AuditLog (EventTime,RunId,RequestId,Action,Target,BeforeJson,AfterJson,Actor,Outcome) VALUES
(N'2026-05-26 09:30:00',NULL,11,N'REQUEST_SUBMITTED',N'khalid.alazmi → ApClerkOU101',NULL,N'{"start": "2026-06-01", "end": "2026-11-30"}',N'fatima.alenezi@' + @Tenant,N'Success'),
(N'2026-05-27 10:00:00',NULL,11,N'REQUEST_APPROVED',N'khalid.alazmi → ApClerkOU101',N'{"status":"Pending"}',N'{"status":"Approved"}',N'fatima.alenezi@' + @Tenant,N'Success'),
(N'2026-07-28 10:00:00',NULL,10,N'REQUEST_SUBMITTED',N'noura.almutairi → PrcBuyerOU101',NULL,N'{"start": "2026-08-01", "end": "2026-10-31"}',N'omar.alrashidi@' + @Tenant,N'Success'),
(N'2026-07-28 15:20:00',NULL,10,N'REQUEST_APPROVED',N'noura.almutairi → PrcBuyerOU101',N'{"status":"Pending"}',N'{"status":"Approved"}',N'omar.alrashidi@' + @Tenant,N'Success'),
(N'2026-08-25 09:00:00',NULL,8,N'REQUEST_SUBMITTED',N'maryam.alajmi → PrcStewardAll',NULL,N'{"start": "2026-09-01", "end": "2027-08-31"}',N'umapragada@' + @Tenant,N'Success'),
(N'2026-08-25 09:02:00',NULL,9,N'REQUEST_SUBMITTED',N'maryam.alajmi → ApStewardAll',NULL,N'{"start": "2026-09-01", "end": "2027-08-31"}',N'umapragada@' + @Tenant,N'Success'),
(N'2026-08-26 11:30:00',NULL,8,N'REQUEST_APPROVED',N'maryam.alajmi → PrcStewardAll',N'{"status":"Pending"}',N'{"status":"Approved"}',N'omar.alrashidi@' + @Tenant,N'Success'),
(N'2026-08-26 11:31:00',NULL,9,N'REQUEST_APPROVED',N'maryam.alajmi → ApStewardAll',N'{"status":"Pending"}',N'{"status":"Approved"}',N'fatima.alenezi@' + @Tenant,N'Success'),
(N'2026-09-28 10:00:00',NULL,14,N'REQUEST_SUBMITTED',N'ahmed.hassan → ApClerkOU103',NULL,N'{"start": "2026-10-01", "end": "2027-03-29"}',N'fatima.alenezi@' + @Tenant,N'Success'),
(N'2026-09-28 16:00:00',NULL,14,N'REQUEST_APPROVED',N'ahmed.hassan → ApClerkOU103',N'{"status":"Pending"}',N'{"status":"Approved"}',N'fatima.alenezi@' + @Tenant,N'Success'),
(N'2026-10-29 08:44:00',NULL,4,N'REQUEST_SUBMITTED',N'lukas.weber → ApClerkOU101',NULL,N'{"start": "2026-11-01", "end": "2026-12-15"}',N'fatima.alenezi@' + @Tenant,N'Success'),
(N'2026-10-29 13:10:00',NULL,4,N'REQUEST_APPROVED',N'lukas.weber → ApClerkOU101',N'{"status":"Pending"}',N'{"status":"Approved"}',N'fatima.alenezi@' + @Tenant,N'Success'),
(N'2026-11-01 06:01:10',1,10,N'GROUP_MEMBER_REMOVE',N'grp-ol-PrcBuyerOU101',N'{"members":["noura.almutairi"]}',N'{"members":[]}',N'spn-fabric-secops',N'Success'),
(N'2026-11-01 06:01:12',1,4,N'GROUP_CREATE',N'grp-ol-ApClerkOU101',NULL,N'{"created":true}',N'spn-fabric-secops',N'Success'),
(N'2026-11-01 06:01:15',1,4,N'GROUP_MEMBER_ADD',N'grp-ol-ApClerkOU101',N'{"members":["khalid.alazmi"]}',N'{"members":["khalid.alazmi","lukas.weber"]}',N'spn-fabric-secops',N'Success'),
(N'2026-11-01 06:02:30',1,4,N'WORKSPACE_ROLE_ADD',N'WS-AP-Gold',NULL,N'{"principal":"grp-ol-ApClerkOU101","role":"Viewer"}',N'spn-fabric-secops',N'Success'),
(N'2026-11-10 06:01:05',2,11,N'GROUP_MEMBER_REMOVE',N'grp-ol-ApClerkOU101',N'{"members":["khalid.alazmi","lukas.weber"]}',N'{"members":["lukas.weber"],"reason":"Leaver"}',N'spn-fabric-secops',N'Success'),
(N'2026-11-16 10:12:00',NULL,1,N'REQUEST_SUBMITTED',N'datasteward → PrcBuyerOU102',NULL,N'{"start": "2026-11-18", "end": "2027-02-15"}',N'omar.alrashidi@' + @Tenant,N'Success'),
(N'2026-11-16 11:05:00',NULL,2,N'REQUEST_SUBMITTED',N'emma.clarke → PrcPlannerOU101',NULL,N'{"start": "2026-11-18", "end": "2026-12-31"}',N'emma.clarke@' + @Tenant,N'Success'),
(N'2026-11-16 12:30:00',NULL,3,N'REQUEST_SUBMITTED',N'lukas.weber → ApClerkOU103',NULL,N'{"start": "2026-11-18", "end": "2027-02-15"}',N'fatima.alenezi@' + @Tenant,N'Success'),
(N'2026-11-16 13:00:00',NULL,5,N'REQUEST_SUBMITTED',N'priya.nair → ApTreasuryAll',NULL,N'{"start": "2026-11-18", "end": "2027-02-15"}',N'fatima.alenezi@' + @Tenant,N'Success'),
(N'2026-11-16 14:40:00',NULL,1,N'REQUEST_APPROVED',N'datasteward → PrcBuyerOU102',N'{"status":"Pending"}',N'{"status":"Approved"}',N'omar.alrashidi@' + @Tenant,N'Success'),
(N'2026-11-16 14:41:00',NULL,2,N'REQUEST_APPROVED',N'emma.clarke → PrcPlannerOU101',N'{"status":"Pending"}',N'{"status":"Approved"}',N'omar.alrashidi@' + @Tenant,N'Success'),
(N'2026-11-16 15:10:00',NULL,13,N'REQUEST_SUBMITTED',N'emma.clarke → PrcBuyerOU101',NULL,N'{"start": "2027-01-01", "end": "2027-03-31"}',N'omar.alrashidi@' + @Tenant,N'Success'),
(N'2026-11-17 08:20:00',NULL,6,N'REQUEST_SUBMITTED',N'sam.patel → PrcAuditorAll',NULL,N'{"start": "2026-11-18", "end": "2026-11-21"}',N'yousef.alhajri@' + @Tenant,N'Success'),
(N'2026-11-17 08:21:00',NULL,7,N'REQUEST_SUBMITTED',N'sam.patel → ApAuditorAll',NULL,N'{"start": "2026-11-18", "end": "2026-11-21"}',N'yousef.alhajri@' + @Tenant,N'Success'),
(N'2026-11-17 09:02:00',NULL,3,N'REQUEST_APPROVED',N'lukas.weber → ApClerkOU103',N'{"status":"Pending"}',N'{"status":"Approved"}',N'fatima.alenezi@' + @Tenant,N'Success'),
(N'2026-11-17 09:05:00',NULL,5,N'REQUEST_APPROVED',N'priya.nair → ApTreasuryAll',N'{"status":"Pending"}',N'{"status":"Approved"}',N'fatima.alenezi@' + @Tenant,N'Success'),
(N'2026-11-17 09:30:00',NULL,13,N'REQUEST_APPROVED',N'emma.clarke → PrcBuyerOU101',N'{"status":"Pending"}',N'{"status":"Approved"}',N'omar.alrashidi@' + @Tenant,N'Success'),
(N'2026-11-17 10:15:00',NULL,6,N'REQUEST_APPROVED',N'sam.patel → PrcAuditorAll',N'{"status":"Pending"}',N'{"status":"Approved"}',N'omar.alrashidi@' + @Tenant,N'Success'),
(N'2026-11-17 10:16:00',NULL,7,N'REQUEST_APPROVED',N'sam.patel → ApAuditorAll',N'{"status":"Pending"}',N'{"status":"Approved"}',N'fatima.alenezi@' + @Tenant,N'Success'),
(N'2026-11-17 11:00:00',NULL,15,N'REQUEST_SUBMITTED',N'ahmed.hassan → PrcBuyerOU103',NULL,N'{"start": "2026-11-20", "end": "2027-02-15"}',N'ahmed.hassan@' + @Tenant,N'Success'),
(N'2026-11-17 14:02:00',NULL,15,N'REQUEST_REJECTED',N'ahmed.hassan → PrcBuyerOU103',N'{"status":"Pending"}',N'{"status":"Rejected"}',N'omar.alrashidi@' + @Tenant,N'Success'),
(N'2026-11-18 06:00:30',4,1,N'GROUP_CREATE',N'grp-ol-PrcBuyerOU102',NULL,N'{"created":true}',N'spn-fabric-secops',N'Success'),
(N'2026-11-18 06:00:37',4,1,N'GROUP_MEMBER_ADD',N'grp-ol-PrcBuyerOU102',N'{"members":[]}',N'{"members": ["datasteward"]}',N'spn-fabric-secops',N'Success'),
(N'2026-11-18 06:00:46',4,1,N'ROLE_UPSERT',N'LH_PRC_Gold/PrcBuyerOU102',NULL,N'{"etag":"5a5f3e5fca58"}',N'spn-fabric-secops',N'Success'),
(N'2026-11-18 06:01:00',4,1,N'WORKSPACE_ROLE_ADD',N'WS-PRC-Gold',NULL,N'{"principal": "grp-ol-PrcBuyerOU102", "role": "Viewer"}',N'spn-fabric-secops',N'Success'),
(N'2026-11-18 06:01:05',4,2,N'GROUP_CREATE',N'grp-ol-PrcPlannerOU101',NULL,N'{"created":true}',N'spn-fabric-secops',N'Success'),
(N'2026-11-18 06:01:12',4,2,N'GROUP_MEMBER_ADD',N'grp-ol-PrcPlannerOU101',N'{"members":[]}',N'{"members": ["emma.clarke"]}',N'spn-fabric-secops',N'Success'),
(N'2026-11-18 06:01:21',4,2,N'ROLE_UPSERT',N'LH_PRC_Gold/PrcPlannerOU101',NULL,N'{"etag":"c5460c70965f"}',N'spn-fabric-secops',N'Success'),
(N'2026-11-18 06:01:35',4,2,N'WORKSPACE_ROLE_ADD',N'WS-PRC-Gold',NULL,N'{"principal": "grp-ol-PrcPlannerOU101", "role": "Viewer"}',N'spn-fabric-secops',N'Success'),
(N'2026-11-18 06:01:40',4,3,N'GROUP_MEMBER_ADD',N'grp-ol-ApClerkOU103',N'{"members":["ahmed.hassan"]}',N'{"members":["ahmed.hassan","lukas.weber"]}',N'spn-fabric-secops',N'Success'),
(N'2026-11-18 06:01:49',4,5,N'GROUP_CREATE',N'grp-ol-ApTreasuryAll',NULL,N'{"created":true}',N'spn-fabric-secops',N'Success'),
(N'2026-11-18 06:01:56',4,5,N'GROUP_MEMBER_ADD',N'grp-ol-ApTreasuryAll',N'{"members":[]}',N'{"members": ["priya.nair"]}',N'spn-fabric-secops',N'Success'),
(N'2026-11-18 06:02:05',4,5,N'ROLE_UPSERT',N'LH_AP_Gold/ApTreasuryAll',NULL,N'{"etag":"2c2263b8edff"}',N'spn-fabric-secops',N'Success'),
(N'2026-11-18 06:02:19',4,5,N'WORKSPACE_ROLE_ADD',N'WS-AP-Gold',NULL,N'{"principal": "grp-ol-ApTreasuryAll", "role": "Viewer"}',N'spn-fabric-secops',N'Success'),
(N'2026-11-18 06:02:24',4,6,N'GROUP_CREATE',N'grp-ol-PrcAuditorAll',NULL,N'{"created":true}',N'spn-fabric-secops',N'Success'),
(N'2026-11-18 06:02:31',4,6,N'GROUP_MEMBER_ADD',N'grp-ol-PrcAuditorAll',N'{"members":[]}',N'{"members": ["sam.patel"]}',N'spn-fabric-secops',N'Success'),
(N'2026-11-18 06:02:40',4,6,N'ROLE_UPSERT',N'LH_PRC_Silver/PrcAuditorAll',NULL,N'{"etag":"ab78ba1f8f7e"}',N'spn-fabric-secops',N'Success'),
(N'2026-11-18 06:02:54',4,6,N'WORKSPACE_ROLE_ADD',N'WS-PRC-Silver',NULL,N'{"principal": "grp-ol-PrcAuditorAll", "role": "Viewer"}',N'spn-fabric-secops',N'Success'),
(N'2026-11-18 06:02:59',4,6,N'ROLE_UPSERT',N'LH_PRC_Gold/PrcAuditorAll',NULL,N'{"etag":"0e3254b7f203"}',N'spn-fabric-secops',N'Success'),
(N'2026-11-18 06:03:13',4,6,N'WORKSPACE_ROLE_ADD',N'WS-PRC-Gold',NULL,N'{"principal": "grp-ol-PrcAuditorAll", "role": "Viewer"}',N'spn-fabric-secops',N'Success'),
(N'2026-11-18 06:03:18',4,7,N'GROUP_CREATE',N'grp-ol-ApAuditorAll',NULL,N'{"created":true}',N'spn-fabric-secops',N'Success'),
(N'2026-11-18 06:03:25',4,7,N'GROUP_MEMBER_ADD',N'grp-ol-ApAuditorAll',N'{"members":[]}',N'{"members": ["sam.patel"]}',N'spn-fabric-secops',N'Success'),
(N'2026-11-18 06:03:34',4,7,N'ROLE_UPSERT',N'LH_AP_Silver/ApAuditorAll',NULL,N'{"etag":"d77d785b5f2b"}',N'spn-fabric-secops',N'Success'),
(N'2026-11-18 06:03:48',4,7,N'WORKSPACE_ROLE_ADD',N'WS-AP-Silver',NULL,N'{"principal": "grp-ol-ApAuditorAll", "role": "Viewer"}',N'spn-fabric-secops',N'Success'),
(N'2026-11-18 06:03:53',4,7,N'ROLE_UPSERT',N'LH_AP_Gold/ApAuditorAll',NULL,N'{"etag":"6ffba0fef5c7"}',N'spn-fabric-secops',N'Success'),
(N'2026-11-18 06:04:07',4,7,N'WORKSPACE_ROLE_ADD',N'WS-AP-Gold',NULL,N'{"principal": "grp-ol-ApAuditorAll", "role": "Viewer"}',N'spn-fabric-secops',N'Success'),
(N'2026-11-18 09:40:00',NULL,12,N'REQUEST_SUBMITTED',N'reem.alkandari → PrcPlannerOU102',NULL,N'{"start": "2026-11-20", "end": "2027-05-18"}',N'omar.alrashidi@' + @Tenant,N'Success'),
(N'2026-11-18 16:45:00',NULL,16,N'REQUEST_SUBMITTED',N'sam.patel → PrcAuditorAll',NULL,N'{"start": "2026-11-18", "end": "2026-11-28"}',N'yousef.alhajri@' + @Tenant,N'Success'),
(N'2026-11-18 18:20:40',5,NULL,N'DRY_RUN',N'all secured lakehouses',NULL,N'{"rolesChanged":0,"note":"no drift"}',N'spn-fabric-secops',N'Success');

INSERT INTO sec.NotificationLog (RequestId,NotificationType,SentTo,Cc,ScheduledFor,Status,Error) VALUES
(10,N'EXPIRY_T7',N'noura.almutairi@' + @Tenant,N'omar.alrashidi@' + @Tenant,N'2026-10-24 06:05:00',N'Sent',NULL),
(10,N'EXPIRY_T1',N'noura.almutairi@' + @Tenant,N'omar.alrashidi@' + @Tenant,N'2026-10-30 06:05:00',N'Sent',NULL),
(10,N'REVOKED',N'noura.almutairi@' + @Tenant,N'omar.alrashidi@' + @Tenant,N'2026-11-01 06:04:02',N'Sent',NULL),
(4,N'ENABLED',N'lukas.weber@' + @Tenant,N'fatima.alenezi@' + @Tenant,N'2026-11-01 06:04:05',N'Sent',NULL),
(11,N'REVOKED',N'khalid.alazmi@' + @Tenant,N'fatima.alenezi@' + @Tenant + N';' + N'umapragada@' + @Tenant,N'2026-11-10 06:02:30',N'Failed',N'Recipient mailbox disabled (leaver); manager copy delivered'),
(13,N'APPROVED',N'emma.clarke@' + @Tenant,N'omar.alrashidi@' + @Tenant,N'2026-11-17 09:31:00',N'Sent',NULL),
(15,N'REJECTED',N'ahmed.hassan@' + @Tenant,N'fatima.alenezi@' + @Tenant,N'2026-11-17 14:02:20',N'Sent',NULL),
(1,N'ENABLED',N'datasteward@' + @Tenant,N'omar.alrashidi@' + @Tenant,N'2026-11-18 06:07:40',N'Sent',NULL),
(2,N'ENABLED',N'emma.clarke@' + @Tenant,N'omar.alrashidi@' + @Tenant,N'2026-11-18 06:07:40',N'Sent',NULL),
(3,N'ENABLED',N'lukas.weber@' + @Tenant,N'fatima.alenezi@' + @Tenant,N'2026-11-18 06:07:40',N'Sent',NULL),
(5,N'ENABLED',N'priya.nair@' + @Tenant,N'fatima.alenezi@' + @Tenant,N'2026-11-18 06:07:40',N'Sent',NULL),
(6,N'ENABLED',N'sam.patel@' + @Tenant,N'yousef.alhajri@' + @Tenant,N'2026-11-18 06:07:40',N'Sent',NULL),
(7,N'ENABLED',N'sam.patel@' + @Tenant,N'yousef.alhajri@' + @Tenant,N'2026-11-18 06:07:40',N'Sent',NULL),
(12,N'APPROVAL_REQUEST',N'omar.alrashidi@' + @Tenant,NULL,N'2026-11-18 09:40:30',N'Sent',NULL),
(16,N'APPROVAL_REQUEST',N'omar.alrashidi@' + @Tenant,N'yousef.alhajri@' + @Tenant,N'2026-11-18 16:45:20',N'Sent',NULL),
(6,N'EXPIRY_T1',N'sam.patel@' + @Tenant,N'yousef.alhajri@' + @Tenant,N'2026-11-20 06:05:00',N'Queued',NULL),
(7,N'EXPIRY_T1',N'sam.patel@' + @Tenant,N'yousef.alhajri@' + @Tenant,N'2026-11-20 06:05:00',N'Queued',NULL);
GO

-- ===== ADMIN VIEWS =====
CREATE VIEW sec.vw_EffectiveAccess AS
SELECT u.DisplayName, u.UPN, u.Department, d.DomainName, rt.RoleCode, rt.DisplayName AS RoleName,
       r.ScopeValue, sv.Label AS ScopeLabel,
       rt.RoleCode + CASE WHEN r.ScopeValue = 'ALL' THEN 'All' ELSE 'OU' + r.ScopeValue END AS OneLakeRole,
       r.StartDate, r.EndDate, DATEDIFF(DAY, CAST(GETDATE() AS DATE), r.EndDate) AS DaysLeft,
       r.RequestNumber, r.TicketRef, r.ApproverUPN
FROM sec.AccessRequest r
JOIN sec.UserProfile  u  ON u.UserId = r.UserId
JOIN sec.RoleTemplate rt ON rt.RoleTemplateId = r.RoleTemplateId
JOIN sec.Domain       d  ON d.DomainId = rt.DomainId
JOIN sec.ScopeValue   sv ON sv.ScopeValue = r.ScopeValue
WHERE r.Status = 'Active' AND u.EmploymentStatus = 'Active';
GO
CREATE VIEW sec.vw_ExpiringSoon AS
SELECT e.*,
       CASE WHEN e.DaysLeft <= 1 THEN 'EXPIRY_T1' ELSE 'EXPIRY_T7' END AS AlertDue
FROM sec.vw_EffectiveAccess e
WHERE e.DaysLeft BETWEEN 0 AND 7;
GO
-- Requests that break a role rule. NB_SEC_Lifecycle rejects every row listed here.
CREATE VIEW sec.vw_RequestViolations AS
SELECT r.RequestId, 'MAX_DAYS' AS RuleBroken,
       CONCAT('Asked ', DATEDIFF(DAY, r.StartDate, r.EndDate), ' days, role allows ', rt.MaxDays) AS Detail
FROM sec.AccessRequest r
JOIN sec.RoleTemplate rt ON rt.RoleTemplateId = r.RoleTemplateId
WHERE r.Status IN ('Pending','Approved') AND DATEDIFF(DAY, r.StartDate, r.EndDate) > rt.MaxDays
UNION ALL
SELECT r.RequestId, 'SCOPE_TYPE', CONCAT('Role ', rt.RoleCode, ' needs scope type ', rt.ScopeType, ', request has ', r.ScopeValue)
FROM sec.AccessRequest r
JOIN sec.RoleTemplate rt ON rt.RoleTemplateId = r.RoleTemplateId
WHERE r.Status IN ('Pending','Approved') AND r.ScopeType <> rt.ScopeType
UNION ALL
SELECT r.RequestId, 'ROLE_CONFLICT', CONCAT(c.Reason, ' (holds ', h.RequestNumber, ')')
FROM sec.AccessRequest r
JOIN sec.RoleTemplate rt ON rt.RoleTemplateId = r.RoleTemplateId
JOIN sec.RoleConflict c ON rt.RoleCode IN (c.RoleCodeA, c.RoleCodeB)
JOIN sec.AccessRequest h ON h.UserId = r.UserId AND h.RequestId <> r.RequestId AND h.Status IN ('Approved','Active')
JOIN sec.RoleTemplate ht ON ht.RoleTemplateId = h.RoleTemplateId
 AND ht.RoleCode = CASE WHEN rt.RoleCode = c.RoleCodeA THEN c.RoleCodeB ELSE c.RoleCodeA END
WHERE r.Status IN ('Pending','Approved') AND (c.ConflictScope = 'Any' OR h.ScopeValue = r.ScopeValue);
GO

-- ===== QUICK CHECKS (run one at a time) =====
-- SELECT * FROM sec.vw_EffectiveAccess ORDER BY DomainName, OneLakeRole;
-- SELECT * FROM sec.vw_ExpiringSoon;
-- SELECT * FROM sec.vw_RequestViolations;   -- empty for the sample data
-- SELECT Status, COUNT(*) FROM sec.AccessRequest GROUP BY Status;
-- SELECT RoleName, i.ItemName, MemberCount, Status, RoleHash FROM sec.RoleBinding b JOIN sec.Item i ON i.ItemKey = b.ItemKey;
-- SELECT TOP 20 EventTime, Action, Target, Actor FROM sec.AuditLog ORDER BY EventTime DESC;

-- =====================================================================
-- P3 · Prepare the sample for a live run
-- RoleBinding is generated state: clear it so the first NB_SEC_Sync run starts clean (otherwise it reports drift).
-- Sample mails that were never sent are marked as such so NB_SEC_Notify does not send them.
-- =====================================================================
DELETE FROM sec.RoleBinding;
UPDATE sec.NotificationLog SET Status = 'Failed', Error = N'Sample data: not sent' WHERE Status = 'Queued';
GO
