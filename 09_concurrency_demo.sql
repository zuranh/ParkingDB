-- =====================================================================
-- 09_concurrency_demo.sql
-- ---------------------------------------------------------------------
-- WHAT : Live demonstrations of transactions and concurrency:
--          Demo A (UNSAFE)  two cars, same moment, procedure WITHOUT lock
--                           hints -> both choose the same space; the
--                           second fails on the filtered unique index.
--          Demo B (SAFE)    same thing with usp_VehicleEntry -> each car
--                           gets a different space, nobody waits,
--                           nobody fails.
--          Demo C (ROLLBACK) an error in the middle of the work:
--                           C1 without a transaction leaves a "ghost"
--                           occupied space; C2 with the procedure leaves
--                           the space free - all or nothing.
-- WHY  : Shows the two layers of protection from the plan (5.2):
--          Layer 1 - locking (UPDLOCK, READPAST, ROWLOCK) PREVENTS the
--                    conflict;
--          Layer 2 - the filtered unique indexes make a double booking
--                    IMPOSSIBLE even when the code is wrong (Demo A).
--
-- HOW TO USE THIS FILE
--   1. Run the WHOLE file once (F5). It only runs PART 0 (setup):
--      creates usp_VehicleEntry_Unsafe and two demo cars DEMO-1 and
--      DEMO-2. Everything below PART 0 is skipped on purpose
--      (SET NOEXEC ON) because it must be run by hand.
--   2. Open TWO NEW query windows (Ctrl+N twice), both on ParkingDB.
--      Put them side by side (drag one tab to the right edge).
--   3. For each demo: copy the WINDOW 1 block into the left window and
--      the WINDOW 2 block into the right window. Press F5 in the left
--      window, then within 10 seconds press F5 in the right window.
--   4. Run the RESULT block, then the CLEANUP block (in either window).
--
-- ISOLATION LEVEL
--   Everything runs at the default READ COMMITTED. We do NOT raise it to
--   SERIALIZABLE. The only race in "find a free space, then take it" is
--   that two transactions READ the same free row before either one
--   WRITES it. UPDLOCK closes exactly that gap: the read itself takes an
--   update lock that is held until COMMIT, so only one transaction can
--   own the row. READPAST lets the other one skip the locked row instead
--   of waiting. SERIALIZABLE would also prevent the race, but with range
--   locks that make every other entry WAIT (and can cause deadlocks);
--   SNAPSHOT would not prevent it at all (both read the old version and
--   the second one fails with an update conflict). The hints protect
--   precisely the one row that matters and nothing else.
--   (To see the database's setting: SELECT is_read_committed_snapshot_on
--    FROM sys.databases WHERE name = 'ParkingDB'; the demos work either way.)
--
-- usp_VehicleEntry_Unsafe is FOR DEMONSTRATION ONLY. It is never granted
-- to the application role (script 07).
-- =====================================================================

USE ParkingDB;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- =====================================================================
-- PART 0 - SETUP (runs when you press F5 on the whole file)
-- =====================================================================

-- ---------------------------------------------------------------------
-- usp_VehicleEntry_Unsafe - FOR DEMONSTRATION ONLY.
-- Exactly the logic of usp_VehicleEntry, but:
--   * the space is chosen with a PLAIN SELECT (no UPDLOCK / READPAST /
--     ROWLOCK): its shared lock is released as soon as the row is read,
--     so a second transaction can read the same "free" space;
--   * errors are NOT translated, so you see the raw 2601 error from the
--     filtered unique index - the database defending itself.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_VehicleEntry_Unsafe
    @LicensePlate      NVARCHAR(50),
    @SpaceTypeID       TINYINT     = NULL,
    @DebugDelaySeconds INT         = 0,
    @SessionID         INT         OUTPUT,
    @SpaceCode         VARCHAR(10) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Plate VARCHAR(50), @VehicleID INT, @SpaceID INT, @Delay CHAR(8);
    SET @SessionID = NULL;
    SET @SpaceCode = NULL;
    SET @Plate = UPPER(LTRIM(RTRIM(@LicensePlate)));

    IF @DebugDelaySeconds IS NULL OR @DebugDelaySeconds NOT BETWEEN 0 AND 30
        THROW 50008, N'Invalid input: debug delay must be between 0 and 30 seconds.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @VehicleID = VehicleID
        FROM dbo.Vehicles
        WHERE LicensePlate = @Plate AND IsActive = 1;

        IF @VehicleID IS NULL
            THROW 50001, N'Vehicle is not registered or is inactive.', 1;

        IF EXISTS (SELECT 1 FROM dbo.ParkingSessions WHERE VehicleID = @VehicleID AND Status = 'Active')
            THROW 50002, N'Vehicle is already parked.', 1;

        -- THE DIFFERENCE: no lock hints. Two transactions can both read
        -- "this space is free" before either of them marks it occupied.
        SELECT TOP (1)
               @SpaceID   = SpaceID,
               @SpaceCode = SpaceCode
        FROM dbo.ParkingSpaces
        WHERE IsOccupied = 0
          AND IsActive   = 1
          AND (@SpaceTypeID IS NULL OR SpaceTypeID = @SpaceTypeID)
        ORDER BY SpaceID;

        IF @SpaceID IS NULL
            THROW 50003, N'No free space available.', 1;

        IF @DebugDelaySeconds > 0
        BEGIN
            SET @Delay = CONVERT(CHAR(8), DATEADD(SECOND, @DebugDelaySeconds, 0), 108);
            WAITFOR DELAY @Delay;
        END;

        UPDATE dbo.ParkingSpaces SET IsOccupied = 1 WHERE SpaceID = @SpaceID;

        INSERT dbo.ParkingSessions (VehicleID, SpaceID, Status)
        VALUES (@VehicleID, @SpaceID, 'Active');       -- the 2nd window fails HERE (error 2601)

        SET @SessionID = SCOPE_IDENTITY();

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @SessionID = NULL;
        SET @SpaceCode = NULL;
        THROW;                                          -- raw error, on purpose
    END CATCH;
END;
GO

-- Demo cars (registered only if missing, so setup can be run again).
DECLARE @v INT;
IF NOT EXISTS (SELECT 1 FROM dbo.Vehicles WHERE LicensePlate = 'DEMO-1')
    EXEC dbo.usp_RegisterVehicle @LicensePlate = N'DEMO-1', @OwnerName = N'Demo Driver One', @VehicleType = 'Car', @VehicleID = @v OUTPUT;
IF NOT EXISTS (SELECT 1 FROM dbo.Vehicles WHERE LicensePlate = 'DEMO-2')
    EXEC dbo.usp_RegisterVehicle @LicensePlate = N'DEMO-2', @OwnerName = N'Demo Driver Two', @VehicleType = 'Car', @VehicleID = @v OUTPUT;

-- Leftovers from an earlier, interrupted demo run.
ALTER TABLE dbo.ParkingSessions DROP CONSTRAINT IF EXISTS CK_Demo_C_RefuseVehicle;

DECLARE @sid INT;
SELECT @sid = ps.SessionID FROM dbo.ParkingSessions AS ps JOIN dbo.Vehicles AS v ON v.VehicleID = ps.VehicleID
WHERE v.LicensePlate = 'DEMO-1' AND ps.Status = 'Active';
IF @sid IS NOT NULL EXEC dbo.usp_CancelSession @SessionID = @sid;
SET @sid = NULL;
SELECT @sid = ps.SessionID FROM dbo.ParkingSessions AS ps JOIN dbo.Vehicles AS v ON v.VehicleID = ps.VehicleID
WHERE v.LicensePlate = 'DEMO-2' AND ps.Status = 'Active';
IF @sid IS NOT NULL EXEC dbo.usp_CancelSession @SessionID = @sid;

SELECT 'Setup done' AS Status, LicensePlate, VehicleID
FROM dbo.Vehicles WHERE LicensePlate IN ('DEMO-1', 'DEMO-2');

PRINT 'Setup done. Now open two NEW query windows and copy the demo blocks into them (see HOW TO USE at the top).';
PRINT 'The rest of this file is skipped when you run it as a whole.';
GO

-- Everything after this line is compiled but NOT executed when the whole
-- file is run. The demo blocks are meant to be copied into new windows.
SET NOEXEC ON;
GO


-- =====================================================================
-- DEMO A - UNSAFE procedure: both windows pick the SAME space
-- Expected:
--   WINDOW 1: succeeds after ~10 s, gets the lowest free space (say F1-003).
--   WINDOW 2: after ~10 s fails with
--     Msg 2601 ... Cannot insert duplicate key row in object
--     'dbo.ParkingSessions' with unique index 'UX_Sessions_OneActivePerSpace'.
-- Lesson: without locking, both transactions read "F1-003 is free".
-- The filtered unique index (Layer 2) saved the data - no double booking
-- was stored - but one driver got an error. That is why we need Layer 1.
-- =====================================================================

-- ---------- DEMO A - WINDOW 1 (copy into the LEFT window) ----------
USE ParkingDB;
DECLARE @t0 DATETIME2(3) = SYSDATETIME(), @S INT, @C VARCHAR(10);
EXEC dbo.usp_VehicleEntry_Unsafe @LicensePlate = N'DEMO-1', @DebugDelaySeconds = 10,
     @SessionID = @S OUTPUT, @SpaceCode = @C OUTPUT;
SELECT 'Window 1 (unsafe)' AS Who, @S AS SessionID, @C AS SpaceCode,
       DATEDIFF(MILLISECOND, @t0, SYSDATETIME()) / 1000.0 AS Seconds;

GO

-- ---------- DEMO A - WINDOW 2 (copy into the RIGHT window, run within 10 s) ----------
USE ParkingDB;
DECLARE @t0 DATETIME2(3) = SYSDATETIME(), @S INT, @C VARCHAR(10);
EXEC dbo.usp_VehicleEntry_Unsafe @LicensePlate = N'DEMO-2', @DebugDelaySeconds = 10,
     @SessionID = @S OUTPUT, @SpaceCode = @C OUTPUT;
SELECT 'Window 2 (unsafe)' AS Who, @S AS SessionID, @C AS SpaceCode,
       DATEDIFF(MILLISECOND, @t0, SYSDATETIME()) / 1000.0 AS Seconds;
-- (If the error happens, this SELECT does not run - the error message IS the result.)
GO


-- =====================================================================
-- DEMO B - SAFE procedure: each window gets a DIFFERENT space
-- Expected:
--   WINDOW 1: ~10 s, lowest free space (say F1-003).
--   WINDOW 2: ~10 s (its OWN delay only - it did not wait for window 1),
--             the NEXT free space (say F1-004).
-- Lesson: UPDLOCK made window 1 the owner of F1-003 the moment it read
-- it; READPAST made window 2 skip that locked row immediately.
-- If window 2 had WAITED for window 1, its time would be about
-- (window 1's remaining seconds + 10), not just 10.
-- Run the CLEANUP block first if DEMO-1 / DEMO-2 are still parked.
-- =====================================================================

-- ---------- DEMO B - WINDOW 1 (LEFT) ----------
USE ParkingDB;
DECLARE @t0 DATETIME2(3) = SYSDATETIME(), @S INT, @C VARCHAR(10);
EXEC dbo.usp_VehicleEntry @LicensePlate = N'DEMO-1', @DebugDelaySeconds = 10,
     @SessionID = @S OUTPUT, @SpaceCode = @C OUTPUT;
SELECT 'Window 1 (safe)' AS Who, @S AS SessionID, @C AS SpaceCode,
       DATEDIFF(MILLISECOND, @t0, SYSDATETIME()) / 1000.0 AS Seconds;

GO

-- ---------- DEMO B - WINDOW 2 (RIGHT, within 10 s) ----------
USE ParkingDB;
DECLARE @t0 DATETIME2(3) = SYSDATETIME(), @S INT, @C VARCHAR(10);
EXEC dbo.usp_VehicleEntry @LicensePlate = N'DEMO-2', @DebugDelaySeconds = 10,
     @SessionID = @S OUTPUT, @SpaceCode = @C OUTPUT;
SELECT 'Window 2 (safe)' AS Who, @S AS SessionID, @C AS SpaceCode,
       DATEDIFF(MILLISECOND, @t0, SYSDATETIME()) / 1000.0 AS Seconds;


GO

-- =====================================================================
-- RESULT block for demos A and B (either window, after both finished)
-- =====================================================================
USE ParkingDB;
-- Where are the demo cars now?
SELECT LicensePlate, SessionID, SpaceCode, EntryTime
FROM dbo.vw_ActiveSessions
WHERE LicensePlate IN ('DEMO-1', 'DEMO-2')
ORDER BY SessionID;

-- Is any space held by two active sessions? (always 0 rows - Layer 2)
SELECT SpaceID, COUNT(*) AS ActiveSessions
FROM dbo.ParkingSessions
WHERE Status = 'Active'
GROUP BY SpaceID
HAVING COUNT(*) > 1;

-- Does the IsOccupied flag agree with the sessions? (expect 0 rows)
-- In Demo A the failed window's UPDATE of IsOccupied was rolled back
-- together with its failed INSERT - nothing half-done remains.
SELECT sp.SpaceCode, sp.IsOccupied,
       CASE WHEN EXISTS (SELECT 1 FROM dbo.ParkingSessions AS ps
                         WHERE ps.SpaceID = sp.SpaceID AND ps.Status = 'Active') THEN 1 ELSE 0 END AS HasActiveSession
FROM dbo.ParkingSpaces AS sp
WHERE sp.IsOccupied <> CASE WHEN EXISTS (SELECT 1 FROM dbo.ParkingSessions AS ps
                                         WHERE ps.SpaceID = sp.SpaceID AND ps.Status = 'Active') THEN 1 ELSE 0 END;


GO

-- =====================================================================
-- CLEANUP block for demos A and B - cancels the demo cars' sessions so
-- the demo can be run again. (Cancelling, not deleting: history stays,
-- and the audit log records the cancellation.)
-- =====================================================================
USE ParkingDB;
DECLARE @sid INT;
SELECT @sid = ps.SessionID FROM dbo.ParkingSessions AS ps JOIN dbo.Vehicles AS v ON v.VehicleID = ps.VehicleID
WHERE v.LicensePlate = 'DEMO-1' AND ps.Status = 'Active';
IF @sid IS NOT NULL EXEC dbo.usp_CancelSession @SessionID = @sid;
SET @sid = NULL;
SELECT @sid = ps.SessionID FROM dbo.ParkingSessions AS ps JOIN dbo.Vehicles AS v ON v.VehicleID = ps.VehicleID
WHERE v.LicensePlate = 'DEMO-2' AND ps.Status = 'Active';
IF @sid IS NOT NULL EXEC dbo.usp_CancelSession @SessionID = @sid;
SELECT 'Demo cars parked now (expect 0)' AS CheckName, COUNT(*) AS Cnt
FROM dbo.vw_ActiveSessions WHERE LicensePlate IN ('DEMO-1', 'DEMO-2');


GO

-- =====================================================================
-- DEMO C - ROLLBACK: an error in the middle of the work
-- ONE window is enough. Run C1 and C2 separately (select the block, F5).
-- =====================================================================

-- ---------- DEMO C1 - WITHOUT a transaction (the problem) ----------
-- Two separate statements, each committed on its own (autocommit):
--   step 1 marks a space occupied           -> succeeds, committed at once
--   step 2 inserts an INVALID session       -> refused by
--          CK_Sessions_StatusMatchesExit (an Active session with a fee)
-- Result: a "ghost" - a space marked occupied with no car in it.
-- Nobody would ever be sent to that space again.
USE ParkingDB;
DECLARE @VehID INT, @Space INT;
SELECT @VehID = VehicleID FROM dbo.Vehicles WHERE LicensePlate = 'DEMO-1';
SELECT @Space = MIN(SpaceID) FROM dbo.ParkingSpaces WHERE IsOccupied = 0 AND IsActive = 1;

UPDATE dbo.ParkingSpaces SET IsOccupied = 1 WHERE SpaceID = @Space;           -- step 1

BEGIN TRY
    INSERT dbo.ParkingSessions (VehicleID, SpaceID, Status, Fee)
    VALUES (@VehID, @Space, 'Active', 5.00);                                  -- step 2 fails
END TRY
BEGIN CATCH
    PRINT CONCAT('Step 2 failed: ', ERROR_MESSAGE());
END CATCH;

SELECT 'C1 without transaction' AS Demo, sp.SpaceCode,
       sp.IsOccupied AS MarkedOccupied,
       (SELECT COUNT(*) FROM dbo.ParkingSessions AS ps
         WHERE ps.SpaceID = sp.SpaceID AND ps.Status = 'Active') AS ActiveSessions,
       'GHOST: occupied but empty' AS Verdict
FROM dbo.ParkingSpaces AS sp WHERE sp.SpaceID = @Space;

-- Repair the ghost by hand (this is the work a transaction saves you from).
UPDATE dbo.ParkingSpaces SET IsOccupied = 0 WHERE SpaceID = @Space;


GO

-- ---------- DEMO C2 - WITH the procedure (the solution) ----------
-- We make the procedure's session INSERT fail on purpose by adding a
-- temporary CHECK constraint that refuses DEMO-1. The procedure has
-- already marked the space occupied when the INSERT fails; XACT_ABORT +
-- ROLLBACK undo that UPDATE as well. The space stays free.
-- (WITH NOCHECK: do not test the 120,000 existing rows, only new ones.
--  Dynamic SQL is needed because a constraint cannot contain a variable.)
USE ParkingDB;
DECLARE @VehID INT, @Space INT, @Code VARCHAR(10), @S INT, @C VARCHAR(10), @Err NVARCHAR(4000), @Sql NVARCHAR(400);
SELECT @VehID = VehicleID FROM dbo.Vehicles WHERE LicensePlate = 'DEMO-1';
SELECT @Space = MIN(SpaceID) FROM dbo.ParkingSpaces WHERE IsOccupied = 0 AND IsActive = 1;
SELECT @Code = SpaceCode FROM dbo.ParkingSpaces WHERE SpaceID = @Space;      -- the space the procedure will choose

SET @Sql = N'ALTER TABLE dbo.ParkingSessions WITH NOCHECK ADD CONSTRAINT CK_Demo_C_RefuseVehicle CHECK (VehicleID <> '
         + CAST(@VehID AS NVARCHAR(10)) + N');';
EXEC (@Sql);

BEGIN TRY
    EXEC dbo.usp_VehicleEntry @LicensePlate = N'DEMO-1', @SessionID = @S OUTPUT, @SpaceCode = @C OUTPUT;
    SET @Err = N'no error (unexpected)';
END TRY
BEGIN CATCH
    SET @Err = CONCAT(ERROR_NUMBER(), N': ', ERROR_MESSAGE());
END CATCH;

ALTER TABLE dbo.ParkingSessions DROP CONSTRAINT IF EXISTS CK_Demo_C_RefuseVehicle;   -- remove the trap

SELECT 'C2 with procedure' AS Demo, sp.SpaceCode,
       sp.IsOccupied AS MarkedOccupied,
       (SELECT COUNT(*) FROM dbo.ParkingSessions AS ps
         WHERE ps.SpaceID = sp.SpaceID AND ps.Status = 'Active') AS ActiveSessions,
       CASE WHEN sp.IsOccupied = 0 THEN 'CLEAN: rolled back, space still free'
            ELSE 'PROBLEM: space left occupied' END AS Verdict,
       @Err AS ErrorTheProcedureRaised
FROM dbo.ParkingSpaces AS sp WHERE sp.SpaceID = @Space;


GO

-- ---------- CLEANUP for demo C (only needed if C2 was interrupted) ----------
USE ParkingDB;
ALTER TABLE dbo.ParkingSessions DROP CONSTRAINT IF EXISTS CK_Demo_C_RefuseVehicle;
SELECT 'Ghost spaces (expect 0)' AS CheckName, COUNT(*) AS Cnt
FROM dbo.ParkingSpaces AS sp
WHERE sp.IsOccupied = 1
  AND NOT EXISTS (SELECT 1 FROM dbo.ParkingSessions AS ps
                  WHERE ps.SpaceID = sp.SpaceID AND ps.Status = 'Active');
GO

-- Back to normal execution for this window.
SET NOEXEC OFF;
GO
