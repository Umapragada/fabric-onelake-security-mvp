/* Phase 6 · report views for the SQL ANALYTICS ENDPOINT of SQLDB_SecMeta
   The endpoint mirrors tables but not views. Run this there (drop-down: SQL analytics endpoint),
   then use New semantic model on these views. Re-runnable. */

CREATE OR ALTER VIEW sec.vw_EffectiveAccess AS
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
       a.Target, a.Actor, a.Outcome, a.RunId, r.RequestNumber, r.TicketRef, u.DisplayName AS PersonName, rt.RoleCode, d.DomainName,
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
SELECT n.NotificationId, n.NotificationType, n.SentTo, n.Cc, n.ScheduledFor, n.Status, n.Error, r.RequestNumber, u.DisplayName AS PersonName
FROM sec.NotificationLog n JOIN sec.AccessRequest r ON r.RequestId = n.RequestId JOIN sec.UserProfile u ON u.UserId = r.UserId;
GO

/* Quarterly recertification extract (AUD-04): one row per active grant, with a column for the owner's decision */
CREATE OR ALTER VIEW sec.vw_AccessReview AS
SELECT e.DomainName, d.OwnerUPN AS ReviewerUPN, e.DisplayName, e.UPN, e.Department, e.RoleCode, e.RoleName, e.ScopeLabel,
       e.StartDate, e.EndDate, e.DaysLeft, e.RequestNumber, e.TicketRef, CAST(NULL AS NVARCHAR(10)) AS ReviewDecision
FROM sec.vw_EffectiveAccess e JOIN sec.Domain d ON d.DomainName = e.DomainName;
GO

