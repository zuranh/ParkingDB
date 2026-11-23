-- =====================================================================
-- 05_triggers.sql
-- ---------------------------------------------------------------------
-- WHAT : Audit-history triggers + one protection trigger:
--          trg_ParkingSessions_Audit  AFTER INSERT, UPDATE, DELETE
--          trg_Payments_Audit         AFTER INSERT, UPDATE, DELETE
--          trg_Vehicles_Audit         AFTER UPDATE, DELETE
--          trg_ParkingSpaces_Audit    AFTER UPDATE (only IsActive / SpaceTypeID changes)
--          trg_Payments_Protect       INSTEAD OF DELETE (payments are permanent)
-- WHY  : Every important change leaves a trace in dbo.AuditLog: which
--        table, which row, what it looked like before and after (JSON),
--        who did it and when. Because the triggers live on the TABLES,
--        the trace is written no matter who changes the data - a
--        procedure, the app, or someone typing SQL in SSMS.
-- CHECK: The test block at the bottom prints PASS on every line and
--        shows the audit rows it produced. It runs in a transaction
--        that is ROLLED BACK, so the AuditLog is still empty afterwards.
--
-- ORDER: Created AFTER the seed data (script 02) on purpose: the 120,000
--        generated rows are not "changes", so the AuditLog starts empty
--        and only records real activity.
--
-- KEY IDEAS (likely exam questions)
--  * inserted / deleted: inside a trigger SQL Server provides two
--    temporary tables. INSERT -> rows in "inserted"; DELETE -> rows in
--    "deleted"; UPDATE -> old version in "deleted", new in "inserted".
--  * SET-BASED: a trigger fires ONCE PER STATEMENT, not once per row.
--    "UPDATE ... WHERE VehicleID <= 5" fires the trigger once with 5 rows
--    in inserted/deleted. So we never read "the" row into a variable;
--    we INSERT ... SELECT over all rows. Test T7 below proves it.
--  * FULL OUTER JOIN inserted/deleted on the primary key gives one line
--    per changed row: both sides present = U, only inserted = I,
--    only deleted = D. Identity primary keys can never be updated, so
--    the join key is reliable.
--  * IF @@ROWCOUNT = 0 RETURN must be the FIRST statement: a statement
--    that touched 0 rows still fires the trigger; we exit immediately.
--    (Any earlier statement, even SET NOCOUNT ON, would reset @@ROWCOUNT.)
--  * SCOPE_IDENTITY() in the procedures (not @@IDENTITY): the audit
--    INSERT inside the trigger creates a NEW identity value in AuditLog.
--    @@IDENTITY would return that one; SCOPE_IDENTITY() returns the value
--    from the procedure's own INSERT. This is why we used it in script 04.
-- =====================================================================

USE ParkingDB;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ---------------------------------------------------------------------
-- trg_ParkingSessions_Audit
-- Old/new values are built with FOR JSON PATH, WITHOUT_ARRAY_WRAPPER for
-- EACH row (a sub-query per row, listing that row's columns), so every
-- AuditLog row holds one JSON object like
--   {"SessionID":5,"VehicleID":12,...,"Status":"Active","Fee":null}
-- INCLUDE_NULL_VALUES keeps columns that are NULL (e.g. ExitTime while
-- Active) so "before" and "after" always show the same keys.
-- The CASE returns NULL instead of an empty object when there is no
-- old row (insert) or no new row (delete).
-- ---------------------------------------------------------------------
CREATE OR ALTER TRIGGER dbo.trg_ParkingSessions_Audit
ON dbo.ParkingSessions
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    IF @@ROWCOUNT = 0 RETURN;
    SET NOCOUNT ON;

    INSERT dbo.AuditLog (TableName, ActionType, KeyValue, OldValues, NewValues)
    SELECT  N'ParkingSessions',
            CASE WHEN i.SessionID IS NOT NULL AND d.SessionID IS NOT NULL THEN 'U'
                 WHEN i.SessionID IS NOT NULL                             THEN 'I'
                 ELSE                                                          'D' END,
            COALESCE(i.SessionID, d.SessionID),
            CASE WHEN d.SessionID IS NULL THEN NULL ELSE
                (SELECT d.SessionID, d.VehicleID, d.SpaceID, d.EntryTime, d.ExitTime, d.Status, d.Fee
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES) END,
            CASE WHEN i.SessionID IS NULL THEN NULL ELSE
                (SELECT i.SessionID, i.VehicleID, i.SpaceID, i.EntryTime, i.ExitTime, i.Status, i.Fee
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES) END
    FROM inserted AS i
    FULL OUTER JOIN deleted AS d ON d.SessionID = i.SessionID;
END;
GO

-- ---------------------------------------------------------------------
-- trg_Payments_Audit - same pattern.
-- Note: because trg_Payments_Protect (below) replaces every DELETE on
-- Payments, the 'D' branch here never fires in practice. It is kept so
-- the audit stays complete if an administrator ever disables the
-- protection trigger on purpose.
-- ---------------------------------------------------------------------
CREATE OR ALTER TRIGGER dbo.trg_Payments_Audit
ON dbo.Payments
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    IF @@ROWCOUNT = 0 RETURN;
    SET NOCOUNT ON;

    INSERT dbo.AuditLog (TableName, ActionType, KeyValue, OldValues, NewValues)
    SELECT  N'Payments',
            CASE WHEN i.PaymentID IS NOT NULL AND d.PaymentID IS NOT NULL THEN 'U'
                 WHEN i.PaymentID IS NOT NULL                             THEN 'I'
                 ELSE                                                          'D' END,
            COALESCE(i.PaymentID, d.PaymentID),
            CASE WHEN d.PaymentID IS NULL THEN NULL ELSE
                (SELECT d.PaymentID, d.SessionID, d.Amount, d.Method, d.PaidAt
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES) END,
            CASE WHEN i.PaymentID IS NULL THEN NULL ELSE
                (SELECT i.PaymentID, i.SessionID, i.Amount, i.Method, i.PaidAt
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES) END
    FROM inserted AS i
    FULL OUTER JOIN deleted AS d ON d.PaymentID = i.PaymentID;
END;
GO

-- ---------------------------------------------------------------------
-- trg_Vehicles_Audit - UPDATE and DELETE only.
-- Registration (INSERT) is not audited: the Vehicles row itself, with
-- its RegisteredAt column, already records it. What matters is when an
-- owner name / phone / status was CHANGED afterwards, and what it was.
-- (A DELETE of a vehicle that has sessions is refused by the foreign key
-- before the trigger runs, so a 'D' row only appears for vehicles that
-- never parked.)
-- ---------------------------------------------------------------------
CREATE OR ALTER TRIGGER dbo.trg_Vehicles_Audit
ON dbo.Vehicles
AFTER UPDATE, DELETE
AS
BEGIN
    IF @@ROWCOUNT = 0 RETURN;
    SET NOCOUNT ON;

    INSERT dbo.AuditLog (TableName, ActionType, KeyValue, OldValues, NewValues)
    SELECT  N'Vehicles',
            CASE WHEN i.VehicleID IS NOT NULL THEN 'U' ELSE 'D' END,   -- no INSERT case: trigger is not AFTER INSERT
            COALESCE(i.VehicleID, d.VehicleID),
            (SELECT d.VehicleID, d.LicensePlate, d.OwnerName, d.Phone, d.VehicleType, d.RegisteredAt, d.IsActive
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES),
            CASE WHEN i.VehicleID IS NULL THEN NULL ELSE
                (SELECT i.VehicleID, i.LicensePlate, i.OwnerName, i.Phone, i.VehicleType, i.RegisteredAt, i.IsActive
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES) END
    FROM deleted AS d                                   -- UPDATE and DELETE always have a "deleted" row
    LEFT JOIN inserted AS i ON i.VehicleID = d.VehicleID;
END;
GO

-- ---------------------------------------------------------------------
-- trg_ParkingSpaces_Audit - UPDATE, but only real configuration changes.
-- IsOccupied flips on every entry and exit; logging them would double
-- the audit volume and add nothing, because the session audit rows
-- already show every entry and exit. So we log a space only when it was
-- put in / out of service (IsActive) or changed type (SpaceTypeID).
--   UPDATE(col) is TRUE when the column appears in the SET list of the
--   statement -> cheap early exit for the entry/exit procedures.
--   The WHERE then keeps only the rows whose value REALLY changed.
-- ---------------------------------------------------------------------
CREATE OR ALTER TRIGGER dbo.trg_ParkingSpaces_Audit
ON dbo.ParkingSpaces
AFTER UPDATE
AS
BEGIN
    IF @@ROWCOUNT = 0 RETURN;
    SET NOCOUNT ON;

    IF NOT (UPDATE(IsActive) OR UPDATE(SpaceTypeID)) RETURN;

    INSERT dbo.AuditLog (TableName, ActionType, KeyValue, OldValues, NewValues)
    SELECT  N'ParkingSpaces',
            'U',
            i.SpaceID,
            (SELECT d.SpaceID, d.SpaceCode, d.FloorNo, d.SpaceTypeID, d.IsOccupied, d.IsActive
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES),
            (SELECT i.SpaceID, i.SpaceCode, i.FloorNo, i.SpaceTypeID, i.IsOccupied, i.IsActive
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES)
    FROM inserted AS i
    JOIN deleted  AS d ON d.SpaceID = i.SpaceID
    WHERE i.IsActive    <> d.IsActive
       OR i.SpaceTypeID <> d.SpaceTypeID;               -- both columns are NOT NULL, so <> is safe
END;
GO

-- ---------------------------------------------------------------------
-- trg_Payments_Protect - INSTEAD OF DELETE.
-- An INSTEAD OF trigger runs INSTEAD of the statement: the DELETE never
-- happens. We raise an error so the caller knows it was refused.
-- An error inside a trigger rolls back the WHOLE transaction of the
-- caller (triggers run as if XACT_ABORT were ON), so nothing is logged
-- and nothing else in that transaction survives either.
-- Error 50009 is not in the plan's list (50001-50008 are business errors
-- for the app); it is the database refusing a forbidden operation.
-- Corrections are made by an administrator with a documented procedure,
-- never by deleting history.
-- ---------------------------------------------------------------------
CREATE OR ALTER TRIGGER dbo.trg_Payments_Protect
ON dbo.Payments
INSTEAD OF DELETE
AS
BEGIN
    IF @@ROWCOUNT = 0 RETURN;
    SET NOCOUNT ON;

    THROW 50009, N'Payments are permanent records and cannot be deleted.', 1;
END;
GO

-- =====================================================================
-- TEST BLOCK - every line of the first grid must say PASS.
-- T1-T7 run inside one transaction that is ROLLED BACK at the end, so
-- the AuditLog and the data are unchanged afterwards. The audit rows
-- they produced are copied into a table variable first - table variables
-- are NOT affected by ROLLBACK - and shown in the second grid.
-- =====================================================================
SET NOCOUNT ON;

DECLARE @Results TABLE (TestNo INT, Test NVARCHAR(200), Expected NVARCHAR(200), Actual NVARCHAR(200));
DECLARE @Seen    TABLE (AuditID BIGINT, TableName SYSNAME, ActionType CHAR(1), KeyValue INT,
                        OldValues NVARCHAR(MAX), NewValues NVARCHAR(MAX), ChangedBy SYSNAME, ChangedAt DATETIME2(3));

DECLARE @Start BIGINT, @Last BIGINT;
DECLARE @Plate VARCHAR(15), @SessionID INT, @SpaceCode VARCHAR(10),
        @Fee DECIMAL(8,2), @PaymentID INT, @PayID INT, @Err NVARCHAR(200), @AuditBefore INT,
        @CountStart INT;

SELECT @Start = ISNULL(MAX(AuditID), 0), @CountStart = COUNT(*) FROM dbo.AuditLog;
SET @Last = @Start;

BEGIN TRANSACTION;

-- A registered vehicle that is not parked right now.
SELECT TOP (1) @Plate = v.LicensePlate
FROM dbo.Vehicles AS v
WHERE v.IsActive = 1
  AND NOT EXISTS (SELECT 1 FROM dbo.ParkingSessions AS ps
                  WHERE ps.VehicleID = v.VehicleID AND ps.Status = 'Active')
ORDER BY v.VehicleID;

-- T1 entry: 1 session INSERT; the IsOccupied flip of the space is NOT logged
EXEC dbo.usp_VehicleEntry @LicensePlate = @Plate, @SessionID = @SessionID OUTPUT, @SpaceCode = @SpaceCode OUTPUT;
INSERT @Results
SELECT 1, N'Entry: session insert logged, space occupancy flip not logged',
       N'1 row(s): ParkingSessions I',
       CONCAT(COUNT(*), N' row(s)', CASE WHEN COUNT(*) > 0 THEN CONCAT(N': ', MIN(TableName), N' ', MIN(ActionType)) END)
FROM dbo.AuditLog WHERE AuditID > @Last;
SELECT @Last = ISNULL(MAX(AuditID), @Last) FROM dbo.AuditLog;

-- T2 exit: 1 session UPDATE, JSON shows Active -> Completed
EXEC dbo.usp_VehicleExit @LicensePlate = @Plate, @SessionID = @SessionID OUTPUT, @Fee = @Fee OUTPUT;
INSERT @Results
SELECT 2, N'Exit: session update logged',
       N'1 row(s): ParkingSessions U',
       CONCAT(COUNT(*), N' row(s)', CASE WHEN COUNT(*) > 0 THEN CONCAT(N': ', MIN(TableName), N' ', MIN(ActionType)) END)
FROM dbo.AuditLog WHERE AuditID > @Last;
INSERT @Results
SELECT 3, N'Exit: old/new JSON show the status change',
       N'Active -> Completed',
       CONCAT(JSON_VALUE(OldValues, '$.Status'), N' -> ', JSON_VALUE(NewValues, '$.Status'))
FROM dbo.AuditLog WHERE AuditID > @Last AND TableName = N'ParkingSessions';
SELECT @Last = ISNULL(MAX(AuditID), @Last) FROM dbo.AuditLog;

-- T4 payment: 1 payment INSERT
EXEC dbo.usp_RecordPayment @SessionID = @SessionID, @Method = 'Cash', @PaymentID = @PaymentID OUTPUT;
INSERT @Results
SELECT 4, N'Payment: insert logged',
       N'1 row(s): Payments I',
       CONCAT(COUNT(*), N' row(s)', CASE WHEN COUNT(*) > 0 THEN CONCAT(N': ', MIN(TableName), N' ', MIN(ActionType)) END)
FROM dbo.AuditLog WHERE AuditID > @Last;
SELECT @Last = ISNULL(MAX(AuditID), @Last) FROM dbo.AuditLog;

-- T5 vehicle phone change: 1 vehicle UPDATE
UPDATE dbo.Vehicles SET Phone = '+961 70000000' WHERE LicensePlate = @Plate;
INSERT @Results
SELECT 5, N'Vehicle phone change logged',
       N'1 row(s): Vehicles U',
       CONCAT(COUNT(*), N' row(s)', CASE WHEN COUNT(*) > 0 THEN CONCAT(N': ', MIN(TableName), N' ', MIN(ActionType)) END)
FROM dbo.AuditLog WHERE AuditID > @Last;
SELECT @Last = ISNULL(MAX(AuditID), @Last) FROM dbo.AuditLog;

-- T6a space taken out of service: logged
UPDATE dbo.ParkingSpaces SET IsActive = 0 WHERE SpaceCode = @SpaceCode;
INSERT @Results
SELECT 6, N'Space out of service (IsActive change) logged',
       N'1 row(s): ParkingSpaces U',
       CONCAT(COUNT(*), N' row(s)', CASE WHEN COUNT(*) > 0 THEN CONCAT(N': ', MIN(TableName), N' ', MIN(ActionType)) END)
FROM dbo.AuditLog WHERE AuditID > @Last;
SELECT @Last = ISNULL(MAX(AuditID), @Last) FROM dbo.AuditLog;

-- T6b occupancy-only change: NOT logged
UPDATE dbo.ParkingSpaces SET IsOccupied = 1 - IsOccupied WHERE SpaceCode = @SpaceCode;
INSERT @Results
SELECT 7, N'Occupancy-only change of a space NOT logged',
       N'0 row(s)',
       CONCAT(COUNT(*), N' row(s)', CASE WHEN COUNT(*) > 0 THEN CONCAT(N': ', MIN(TableName), N' ', MIN(ActionType)) END)
FROM dbo.AuditLog WHERE AuditID > @Last;
SELECT @Last = ISNULL(MAX(AuditID), @Last) FROM dbo.AuditLog;

-- T7 ONE statement changing 5 rows -> 5 audit rows (set-based trigger)
UPDATE dbo.Vehicles SET OwnerName = OwnerName + N' (checked)' WHERE VehicleID BETWEEN 1 AND 5;
INSERT @Results
SELECT 8, N'One UPDATE of 5 vehicles -> 5 audit rows (set-based)',
       N'5 row(s): Vehicles U',
       CONCAT(COUNT(*), N' row(s)', CASE WHEN COUNT(*) > 0 THEN CONCAT(N': ', MIN(TableName), N' ', MIN(ActionType)) END)
FROM dbo.AuditLog WHERE AuditID > @Last;
SELECT @Last = ISNULL(MAX(AuditID), @Last) FROM dbo.AuditLog;

-- Keep a copy of what the triggers wrote, then undo everything.
INSERT @Seen SELECT * FROM dbo.AuditLog WHERE AuditID > @Start;
ROLLBACK TRANSACTION;

-- T8 payments cannot be deleted (outside the test transaction:
--    the trigger's error rolls back the DELETE's own transaction).
SELECT @PayID = MIN(PaymentID) FROM dbo.Payments;
SELECT @AuditBefore = COUNT(*) FROM dbo.AuditLog;

BEGIN TRY
    DELETE FROM dbo.Payments WHERE PaymentID = @PayID;
    SET @Err = N'no error - the delete was allowed!';
END TRY
BEGIN CATCH
    SET @Err = CONCAT(ERROR_NUMBER(), N': ', ERROR_MESSAGE());
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
END CATCH;

INSERT @Results VALUES
 (9,  N'DELETE of a payment refused by trg_Payments_Protect',
      N'50009: Payments are permanent records and cannot be deleted.', @Err),
 (10, N'The payment still exists after the refused delete',
      N'yes', CASE WHEN EXISTS (SELECT 1 FROM dbo.Payments WHERE PaymentID = @PayID) THEN N'yes' ELSE N'no' END),
 (11, N'The refused delete logged nothing',
      N'0', CAST((SELECT COUNT(*) FROM dbo.AuditLog) - @AuditBefore AS NVARCHAR(20))),
 (12, N'AuditLog back to its starting row count (tests rolled back)',
      CAST(@CountStart AS NVARCHAR(20)), CAST((SELECT COUNT(*) FROM dbo.AuditLog) AS NVARCHAR(20)));

SELECT TestNo, Test, Expected, Actual,
       CASE WHEN Expected = Actual THEN 'PASS' ELSE 'FAIL' END AS Result
FROM @Results
ORDER BY TestNo;

-- What the triggers wrote during T1-T7 (copied before the rollback).
SELECT AuditID, TableName, ActionType, KeyValue, OldValues, NewValues, ChangedBy, ChangedAt
FROM @Seen
ORDER BY AuditID;
GO
