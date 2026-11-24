# P7 · Scaling to hundreds of tables: setup and demo (optional, draft)

> **Status: optional draft process.** Not part of the agreed scope. Details will be worked out later with the Data Owners.

Four features, added on top of the working lab. Nothing in P3 is dropped or changed, and **P3 must not be rerun**.
Without a row in `sec.ObjectPattern` the sync behaves exactly as before.

| Feature | What it means | Where |
| --- | --- | --- |
| 1. Catalogue harvest | Every table and column of each secured lakehouse is read into the register. Nobody types table names. | `NB_SEC_Catalog` → `sec.TableCatalog`, `sec.ColumnCatalog` |
| 2. Pattern rules | One row gives a role a group of tables, for example every `dim_*` table. | `sec.ObjectPattern` |
| 3. Classification | Columns get a class (BANK, TAX, PERSONAL, PRICE). It is suggested from the column name and confirmed by a steward. Pattern rules deny classes, not column names. | `sec.ClassRule`, `ColumnCatalog.ColumnClass` |
| 4. Closed by default | A new table is reached by no pattern rule until a steward marks it `Reviewed = 1`. | `TableCatalog.Reviewed` |

## Setup (once, about 15 minutes)

1. **Cloud Shell** (after the usual restore if Cloud Shell was reset):
   ```bash
   cd ~/fabric-onelake-security-mvp && git pull
   python P0_2_fabric_deploy.py notebooks
   ```
   This updates NB_SEC_Sync and adds NB_SEC_Catalog and NB_SEC_DemoNewTable to WS-SEC-Control.
2. **SQLDB_SecMeta** (SQL database editor): run `P7_scale.sql`.
3. **WS-SEC-Control**: open `NB_SEC_Catalog` and choose Run all. Expect one line per lakehouse (`LH_PRC_Gold: n tables, m columns`).
4. **SQLDB_SecMeta**: add the demo pattern rule:
   ```sql
   INSERT INTO sec.ObjectPattern (RoleTemplateId, ItemKey, TablePattern, RowFilterColumn, DeniedClasses, Description)
   VALUES (1, 3, N'/Tables/gold/dim_*', N'org_id', N'["BANK","TAX"]', N'Buyer: all reviewed Procurement dimensions');
   ```
5. **Safety check:** open `NB_SEC_Sync`, set `DRY_RUN = True` and choose Run all. It should print `no change` for every lakehouse, which means the validated personas are untouched. Set `DRY_RUN` back to `False`.

## Demo (about 10 minutes)

**A · Nobody types table names** (SQLDB_SecMeta)
```sql
SELECT i.ItemName, COUNT(*) AS tables FROM sec.TableCatalog t JOIN sec.Item i ON i.ItemKey = t.ItemKey GROUP BY i.ItemName;
SELECT TablePath, ColumnName, SuggestedClass FROM sec.ColumnCatalog WHERE SuggestedClass IS NOT NULL ORDER BY TablePath;
```
*"The platform found every table and flagged bank, tax and personal columns by itself."*

**B · A new table lands.** Run `NB_SEC_DemoNewTable` (creates `gold.dim_supplier_contact`, fictional data with VAT numbers), then run `NB_SEC_Catalog`.
```sql
SELECT * FROM sec.vw_ClassificationQueue WHERE TablePath LIKE '%supplier_contact%';
```
*"It is in the register and in the steward's queue, with VAT flagged as TAX."*

**C · Closed by default.** Run `NB_SEC_Sync`. As the **Saudi buyer** (LH_PRC_Gold SQL endpoint):
```sql
SELECT * FROM gold.dim_supplier_contact;   -- refused: no role reaches it yet
```
```sql
SELECT RoleCode, TablePath, Source FROM sec.vw_PatternCoverage WHERE TablePath LIKE '%supplier_contact%';  -- Closed: not reviewed
```
*"A new table is invisible to business users until a steward has looked at it."*

**D · The steward reviews** (two statements, in KDD a button in Power Apps):
```sql
UPDATE sec.ColumnCatalog SET ColumnClass = COALESCE(SuggestedClass, 'NONE'), ClassifiedBy = N'maryam', ClassifiedAt = SYSUTCDATETIME()
WHERE TablePath = N'/Tables/gold/dim_supplier_contact';
UPDATE sec.TableCatalog SET Reviewed = 1, ReviewedBy = N'maryam', ReviewedAt = SYSUTCDATETIME()
WHERE TablePath = N'/Tables/gold/dim_supplier_contact';
```

**E · One rule covers it.** Run `NB_SEC_Sync`. As the **Saudi buyer**:
```sql
SELECT supplier_name, contact_name, org_id FROM gold.dim_supplier_contact;  -- 2 rows, org 102 only
SELECT * FROM gold.dim_supplier_contact;                                     -- refused: VAT is hidden
```
*"No one wrote a rule for this table. The existing pattern rule picked it up, applied the organisation filter and hid the tax column."*

## Clean up after the demo
Run `NB_SEC_DemoNewTable` with `DROP = True`, then `NB_SEC_Catalog` (the table is marked `IsPresent = 0`), then `NB_SEC_Sync`.
To switch the feature off: `UPDATE sec.ObjectPattern SET IsActive = 0;` and run the sync.

## Notes
- The SQL endpoint can take a minute or two to show a new table. Wait before step C if the table is missing for the admin too.
- NB_SEC_Catalog runs under the identity of whoever runs it (Uma, workspace Admin), because it reads the lakehouse files.
- The daily pipeline is unchanged. For KDD, add NB_SEC_Catalog as the first activity of PL_SEC_Lifecycle.
