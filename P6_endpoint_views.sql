/* Phase 6 · report views for the SQL ANALYTICS ENDPOINT of SQLDB_SecMeta
   The endpoint mirrors tables but not views. Run this there (drop-down: SQL analytics endpoint),
   then use New semantic model on these views. Re-runnable.
   Computed columns (RequestNumber) are not mirrored, so they are rebuilt here. */

CREATE OR ALTER VIEW sec.vw_EffectiveAccess AS
SELECT u.DisplayName, u.UPN, u.Department, d.DomainName, rt.RoleCode, rt.DisplayName AS RoleName,
       r.ScopeValue, sv.Label AS ScopeLabel,
       rt.RoleCode + CASE WHEN r.ScopeValue = 'ALL' THEN 'All' ELSE 'OU' + r.ScopeValue END AS OneLakeRole,
       r.StartDate, r.EndDate, DATEDIFF(DAY, CAST(GETDATE() AS DATE), r.EndDate) AS DaysLeft,
       ('ACC-' + RIGHT('00000' + CAST(r.RequestId AS VARCHAR(10)), 5)) AS RequestNumber, r.TicketRef, r.ApproverUPN
FROM sec.AccessRequest r
JOIN sec.UserProfile  u  ON u.UserId = r.UserId
JOIN sec.RoleTemplate rt ON rt.RoleTemplateId = r.RoleTemplateId
JOIN sec.Domain       d  ON d.DomainId = rt.DomainId
JOIN sec.ScopeValue   sv ON sv.ScopeValue = r.ScopeValue
WHERE r.Status = 'Active' AND u.EmploymentStatus = 'Active';
GO

CREATE OR ALTER VIEW sec.vw_ExpiringSoon AS
SELECT e.*,
       CASE WHEN e.DaysLeft <= 1 THEN 'EXPIRY_T1' ELSE 'EXPIRY_T7' END AS AlertDue
FROM sec.vw_EffectiveAccess e
WHERE e.DaysLeft BETWEEN 0 AND 7;
GO

CREATE OR ALTER VIEW sec.vw_AuditTrail AS
SELECT a.AuditId, a.EventTime, CAST(a.EventTime AS DATE) AS EventDate, a.Action,
       CASE WHEN a.Action LIKE 'REQUEST_%' THEN 'Request' WHEN a.Action LIKE 'GROUP_%' THEN 'Entra group'
            WHEN a.Action LIKE 'ROLE_%' OR a.Action IN ('DRY_RUN','DRIFT_DETECTED') THEN 'OneLake role'
            WHEN a.Action LIKE 'WORKSPACE_%' THEN 'Workspace role' ELSE 'Other' END AS ActionGroup,
       a.Target, a.Actor, a.Outcome, a.RunId, ('ACC-' + RIGHT('00000' + CAST(r.RequestId AS VARCHAR(10)), 5)) AS RequestNumber, r.TicketRef, u.DisplayName AS PersonName, rt.RoleCode, d.DomainName,
       a.BeforeJson, a.AfterJson
FROM sec.AuditLog a
LEFT JOIN sec.AccessRequest r ON r.RequestId = a.RequestId
LEFT JOIN sec.UserProfile u ON u.UserId = r.UserId
LEFT JOIN sec.RoleTemplate rt ON rt.RoleTemplateId = r.RoleTemplateId
LEFT JOIN sec.Domain d ON d.DomainId = rt.DomainId;
GO

CREATE OR ALTER VIEW sec.vw_SyncHealth AS
SELECT RunId, StartedAt, EndedAt, TriggerType, DryRun, DATEDIFF(SECOND, StartedAt, EndedAt) AS DurationSeconds,
       RolesChanged, MembersAdded, MembersRemoved, Errors,
       CASE WHEN EndedAt IS NULL THEN 'Running or failed' WHEN Errors > 0 THEN 'Completed with errors'
            WHEN DATEDIFF(MINUTE, StartedAt, EndedAt) > 15 THEN 'Slow (NFR-01)' ELSE 'Healthy' END AS Health
FROM sec.SyncRun;
GO

CREATE OR ALTER VIEW sec.vw_AccessSummary AS
SELECT d.DomainName, rt.RoleCode, rt.DisplayName AS RoleName, r.ScopeValue, sv.Label AS ScopeLabel, r.Status, COUNT(*) AS Requests,
       SUM(CASE WHEN r.Status = 'Active' AND r.EndDate <= DATEADD(DAY, 7, CAST(GETDATE() AS DATE)) THEN 1 ELSE 0 END) AS EndingWithin7Days
FROM sec.AccessRequest r
JOIN sec.RoleTemplate rt ON rt.RoleTemplateId = r.RoleTemplateId
JOIN sec.Domain d ON d.DomainId = rt.DomainId
JOIN sec.ScopeValue sv ON sv.ScopeValue = r.ScopeValue
GROUP BY d.DomainName, rt.RoleCode, rt.DisplayName, r.ScopeValue, sv.Label, r.Status;
GO

CREATE OR ALTER VIEW sec.vw_NotificationStatus AS
SELECT n.NotificationId, n.NotificationType, n.SentTo, n.Cc, n.ScheduledFor, n.Status, n.Error, ('ACC-' + RIGHT('00000' + CAST(r.RequestId AS VARCHAR(10)), 5)) AS RequestNumber, u.DisplayName AS PersonName
FROM sec.NotificationLog n JOIN sec.AccessRequest r ON r.RequestId = n.RequestId JOIN sec.UserProfile u ON u.UserId = r.UserId;
GO

/* Quarterly recertification extract (AUD-04): one row per active grant, with a column for the owner's decision */
CREATE OR ALTER VIEW sec.vw_AccessReview AS
SELECT e.DomainName, d.OwnerUPN AS ReviewerUPN, e.DisplayName, e.UPN, e.Department, e.RoleCode, e.RoleName, e.ScopeLabel,
       e.StartDate, e.EndDate, e.DaysLeft, e.RequestNumber, e.TicketRef, CAST(NULL AS NVARCHAR(10)) AS ReviewDecision
FROM sec.vw_EffectiveAccess e JOIN sec.Domain d ON d.DomainName = e.DomainName;
GO


/* One row per person x request x table: who, which role, which table, row filter, columns, dates, and the
   Fabric role and Entra group the sync built. Works in the SQL database and in the SQL analytics endpoint. */
CREATE OR ALTER VIEW sec.vw_UserAccessDetail AS
SELECT u.DisplayName, u.UPN, u.Department, u.EmploymentStatus,
       ('ACC-' + RIGHT('00000' + CAST(r.RequestId AS VARCHAR(10)), 5)) AS RequestNumber,
       r.Status AS RequestStatus, r.StartDate, r.EndDate,
       DATEDIFF(DAY, CAST(GETDATE() AS DATE), r.EndDate) AS DaysLeft,
       r.ApproverUPN, r.ApprovedAt,
       (SELECT MAX(a.EventTime) FROM sec.AuditLog a
         WHERE a.RequestId = r.RequestId AND a.Action = 'REQUEST_ACTIVATED') AS ActivatedAt,
       d.DomainName, t.RoleCode, t.MaxDays, r.ScopeValue, sv.Label AS ScopeLabel,
       w.WorkspaceName, i.ItemName, o.TablePath,
       CASE WHEN rr.FilterColumn IS NULL THEN 'All rows'
            ELSE rr.FilterColumn + ' = ''' + r.ScopeValue + '''' END AS RowFilter,
       COALESCE(cr.AllowedColumns, 'All columns') AS AllowedColumns,
       rb.RoleName AS FabricRole, rb.EntraGroupName, rb.AppliedAt AS RoleAppliedAt
FROM sec.AccessRequest r
JOIN sec.UserProfile  u  ON u.UserId = r.UserId
JOIN sec.RoleTemplate t  ON t.RoleTemplateId = r.RoleTemplateId
JOIN sec.Domain       d  ON d.DomainId = t.DomainId
JOIN sec.ScopeValue   sv ON sv.ScopeValue = r.ScopeValue
JOIN sec.ObjectRule   o  ON o.RoleTemplateId = r.RoleTemplateId
JOIN sec.Item         i  ON i.ItemKey = o.ItemKey
JOIN sec.Workspace    w  ON w.WorkspaceKey = i.WorkspaceKey
LEFT JOIN sec.RowRule    rr ON rr.RoleTemplateId = o.RoleTemplateId AND rr.ItemKey = o.ItemKey AND rr.TablePath = o.TablePath
LEFT JOIN sec.ColumnRule cr ON cr.RoleTemplateId = o.RoleTemplateId AND cr.ItemKey = o.ItemKey AND cr.TablePath = o.TablePath
LEFT JOIN sec.RoleBinding rb ON rb.RoleTemplateId = r.RoleTemplateId AND rb.ItemKey = o.ItemKey
                            AND rb.ScopeValue = r.ScopeValue AND rb.Status = 'Applied';
GO
