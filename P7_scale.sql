/* =====================================================================
   KDD OneLake security · P7 · scaling to hundreds of tables
   Target : Fabric SQL database SQLDB_SecMeta (SQL database editor, not the endpoint)
   Safe   : ADDITIVE. Creates new tables and views only; never drops or changes P3 data.
            Re-runnable. Without rows in sec.ObjectPattern the sync behaves exactly as before.

   Four features
   1. Catalogue harvest   sec.TableCatalog, sec.ColumnCatalog   (filled by NB_SEC_Catalog)
   2. Pattern rules       sec.ObjectPattern                     (one row covers many tables)
   3. Classification      sec.ClassRule suggests a class per column name; a steward confirms
                          ColumnCatalog.ColumnClass; pattern rules deny classes, not columns
   4. Closed by default   a pattern rule only reaches tables a steward has marked Reviewed = 1
   ===================================================================== */

IF OBJECT_ID('sec.TableCatalog') IS NULL
CREATE TABLE sec.TableCatalog (
  ItemKey     INT           NOT NULL REFERENCES sec.Item(ItemKey),
  TablePath   NVARCHAR(200) NOT NULL,                 -- same format as ObjectRule: /Tables/<schema>/<table>
  SchemaName  NVARCHAR(100) NOT NULL,
  TableName   NVARCHAR(200) NOT NULL,
  FirstSeenAt DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
  LastSeenAt  DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
  IsPresent   BIT           NOT NULL DEFAULT 1,       -- 0 when the table disappeared from the lakehouse
  Reviewed    BIT           NOT NULL DEFAULT 0,       -- closed by default: 0 = no pattern rule reaches it
  ReviewedBy  NVARCHAR(256) NULL,
  ReviewedAt  DATETIME2(0)  NULL,
  CONSTRAINT PK_TableCatalog PRIMARY KEY (ItemKey, TablePath));
GO
IF OBJECT_ID('sec.ColumnCatalog') IS NULL
CREATE TABLE sec.ColumnCatalog (
  ItemKey        INT           NOT NULL,
  TablePath      NVARCHAR(200) NOT NULL,
  ColumnName     NVARCHAR(128) NOT NULL,              -- exact case; OneLake column rules are case-sensitive
  DataType       NVARCHAR(100) NULL,
  Ordinal        INT           NULL,
  SuggestedClass VARCHAR(20)   NULL,                  -- from sec.ClassRule, by column name
  ColumnClass    VARCHAR(20)   NULL,                  -- confirmed by a steward; 'NONE' = checked, not sensitive
  ClassifiedBy   NVARCHAR(256) NULL,
  ClassifiedAt   DATETIME2(0)  NULL,
  IsPresent      BIT           NOT NULL DEFAULT 1,
  CONSTRAINT PK_ColumnCatalog PRIMARY KEY (ItemKey, TablePath, ColumnName),
  CONSTRAINT FK_ColumnCatalog_Table FOREIGN KEY (ItemKey, TablePath) REFERENCES sec.TableCatalog(ItemKey, TablePath));
GO
IF OBJECT_ID('sec.ClassRule') IS NULL
CREATE TABLE sec.ClassRule (
  NamePattern NVARCHAR(100) NOT NULL PRIMARY KEY,     -- SQL LIKE pattern on the column name, lower case
  ColumnClass VARCHAR(20)   NOT NULL,
  Priority    INT           NOT NULL DEFAULT 100);    -- lower wins when several match
GO
IF OBJECT_ID('sec.ObjectPattern') IS NULL
CREATE TABLE sec.ObjectPattern (
  PatternId       INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
  RoleTemplateId  INT           NOT NULL REFERENCES sec.RoleTemplate(RoleTemplateId),
  ItemKey         INT           NOT NULL REFERENCES sec.Item(ItemKey),
  TablePattern    NVARCHAR(200) NOT NULL,             -- glob on TablePath, * = any text, e.g. /Tables/gold/dim_*
  RowFilterColumn SYSNAME       NULL,                 -- applied to matched tables that have this column (OU-scoped roles)
  DeniedClasses   NVARCHAR(400) NOT NULL DEFAULT '[]' CHECK (ISJSON(DeniedClasses) = 1),  -- e.g. ["BANK","TAX"]
  IsActive        BIT           NOT NULL DEFAULT 1,
  Description     NVARCHAR(200) NULL);
GO

-- Name-based suggestions. Stewards confirm; nothing here hides a column on its own.
MERGE sec.ClassRule AS t
USING (VALUES
  (N'%iban%','BANK',10), (N'%swift%','BANK',10), (N'%bank%','BANK',20), (N'%account_num%','BANK',20),
  (N'%vat%','TAX',10), (N'%tax_reg%','TAX',10), (N'%tax_id%','TAX',10),
  (N'%email%','PERSONAL',30), (N'%phone%','PERSONAL',30), (N'%mobile%','PERSONAL',30), (N'%contact_name%','PERSONAL',30), (N'%civil_id%','PERSONAL',10),
  (N'unit_price','PRICE',40), (N'%_price','PRICE',50)
) AS s (NamePattern, ColumnClass, Priority) ON t.NamePattern = s.NamePattern
WHEN NOT MATCHED THEN INSERT (NamePattern, ColumnClass, Priority) VALUES (s.NamePattern, s.ColumnClass, s.Priority);
GO

-- Which tables each role reaches, and why (Explicit rule, Pattern rule, or Closed: not reviewed yet)
CREATE OR ALTER VIEW sec.vw_PatternCoverage AS
SELECT t.RoleCode, i.ItemName, c.TablePath, 'Explicit' AS Source, CAST(NULL AS NVARCHAR(200)) AS TablePattern, c.Reviewed
FROM sec.TableCatalog c
JOIN sec.ObjectRule o ON o.ItemKey = c.ItemKey AND o.TablePath = c.TablePath
JOIN sec.RoleTemplate t ON t.RoleTemplateId = o.RoleTemplateId
JOIN sec.Item i ON i.ItemKey = c.ItemKey
WHERE c.IsPresent = 1
UNION ALL
SELECT t.RoleCode, i.ItemName, c.TablePath,
       CASE WHEN c.Reviewed = 1 THEN 'Pattern' ELSE 'Closed: not reviewed' END, p.TablePattern, c.Reviewed
FROM sec.ObjectPattern p
JOIN sec.TableCatalog c ON c.ItemKey = p.ItemKey AND c.IsPresent = 1
     AND c.TablePath LIKE REPLACE(REPLACE(p.TablePattern, '_', '[_]'), '*', '%')
JOIN sec.RoleTemplate t ON t.RoleTemplateId = p.RoleTemplateId
JOIN sec.Item i ON i.ItemKey = c.ItemKey
WHERE p.IsActive = 1
  AND NOT EXISTS (SELECT 1 FROM sec.ObjectRule o WHERE o.RoleTemplateId = p.RoleTemplateId AND o.ItemKey = c.ItemKey AND o.TablePath = c.TablePath);
GO

-- The steward's work queue: new tables and columns that still need a decision
CREATE OR ALTER VIEW sec.vw_ClassificationQueue AS
SELECT i.ItemName, c.TablePath, c.ColumnName, c.SuggestedClass, c.ColumnClass, tc.Reviewed, tc.FirstSeenAt
FROM sec.ColumnCatalog c
JOIN sec.TableCatalog tc ON tc.ItemKey = c.ItemKey AND tc.TablePath = c.TablePath
JOIN sec.Item i ON i.ItemKey = c.ItemKey
WHERE c.IsPresent = 1 AND (tc.Reviewed = 0 OR (c.SuggestedClass IS NOT NULL AND c.ColumnClass IS NULL));
GO

-- Optional demo rule (run separately when you want it):
-- one row gives every reviewed dim_* table in LH_PRC_Gold to the Procurement buyer, filtered by org_id
-- where the table has it, with bank and tax columns hidden.
-- INSERT INTO sec.ObjectPattern (RoleTemplateId, ItemKey, TablePattern, RowFilterColumn, DeniedClasses, Description)
-- VALUES (1, 3, N'/Tables/gold/dim_*', N'org_id', N'["BANK","TAX"]', N'Buyer: all reviewed Procurement dimensions');
