-- =====================================================================
-- 07_security.sql
-- ---------------------------------------------------------------------
-- WHAT : The application's own, restricted identity:
--          login  parking_app_login   (SQL authentication, server level)
--          user   parking_app         (inside ParkingDB)
--          role   parking_app_role    (holds the permissions; user is a member)
--        The role may EXECUTE the 8 app procedures and SELECT the 3 views.
--        It has NO permission on any table, and NOT on
--        usp_VehicleEntry_Unsafe (demo only).
-- WHY  : Least privilege. Even if the app were hacked, the attacker could
--        only do what the procedures allow - never "DELETE FROM Payments"
--        or "SELECT * FROM Vehicles".
-- CHECK: The proof grid at the end: every line PASS
--        (tables denied, procedures/views allowed, unsafe proc denied,
--         SQL injection treated as data, Payments table still exists).
--
-- HOW TO RUN (the password is NOT stored in this file)
--   1. SSMS menu: Query -> SQLCMD Mode   (it turns grey-highlighted).
--   2. Type this as the FIRST line of the query window, with your own
--      strong password (8+ chars, upper, lower, digit, symbol):
--          :setvar AppPassword "Parking#2026app"
--      Do NOT save the file with that line in it.
--   3. Run the whole file (F5).
--   Alternative from a command prompt:
--      sqlcmd -S localhost -E -i 07_security.sql -v AppPassword="Parking#2026app"
--
-- SERVER SETTING NEEDED: SQL logins only work if the server allows
-- "SQL Server and Windows Authentication mode". The script checks this
-- and tells you if it must be changed:
--   Object Explorer -> right-click the server -> Properties -> Security
--   -> "SQL Server and Windows Authentication mode" -> OK, then restart
--   the service (right-click the server -> Restart).
--
-- OWNERSHIP CHAINING (the key idea - likely exam question)
--   parking_app has NO rights on the tables, yet it can register a car,
--   which INSERTs into dbo.Vehicles. How?
--   The procedure and the table have the SAME owner (dbo). When a
--   procedure touches an object with the same owner, SQL Server does NOT
--   check the caller's permissions on that object again - it only
--   checked EXECUTE on the procedure. This unbroken "chain" of ownership
--   lets the user do exactly what the procedure does, and nothing else.
--   (The chain breaks with dynamic SQL - EXEC('...') - which is one more
--   reason our procedures never build SQL from strings.)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Guards
-- ---------------------------------------------------------------------
-- If SQLCMD Mode is OFF, $(AppPassword) is not replaced and would become
-- the literal password "$(AppPassword)". Detect that and stop.
-- (The right-hand side is built from two pieces so SQLCMD never replaces it.)
IF N'$(AppPassword)' = N'$' + N'(AppPassword)'
BEGIN
    RAISERROR('SQLCMD Mode is OFF. Turn on Query -> SQLCMD Mode, add the line  :setvar AppPassword "YourStrongPassword"  at the top, and run again. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO

IF CAST(SERVERPROPERTY('IsIntegratedSecurityOnly') AS INT) = 1
    PRINT 'WARNING: the server accepts Windows logins only. The login is created, but the app cannot connect with it until you enable "SQL Server and Windows Authentication mode" and restart the service (see header).';
GO

-- ---------------------------------------------------------------------
-- 1. Login (server level, lives in master)
--    Re-runnable: created if missing, otherwise only the password is reset.
--    CHECK_POLICY = ON: Windows password rules apply (length, complexity).
-- ---------------------------------------------------------------------
USE master;
GO
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'parking_app_login')
    CREATE LOGIN parking_app_login
        WITH PASSWORD = N'$(AppPassword)',
             DEFAULT_DATABASE = ParkingDB,
             CHECK_POLICY = ON;
ELSE
    ALTER LOGIN parking_app_login WITH PASSWORD = N'$(AppPassword)';
GO

-- ---------------------------------------------------------------------
-- 2. User and role (database level)
-- ---------------------------------------------------------------------
USE ParkingDB;
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'parking_app')
    CREATE USER parking_app FOR LOGIN parking_app_login;   -- no DEFAULT_SCHEMA needed: everything is dbo
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'parking_app_role' AND type = 'R')
    CREATE ROLE parking_app_role;
GO

-- Permissions go to the ROLE, never directly to the user: a second app
-- or a new version gets the same rights by joining the role.
IF IS_ROLEMEMBER('parking_app_role', 'parking_app') = 0
    ALTER ROLE parking_app_role ADD MEMBER parking_app;
GO

-- ---------------------------------------------------------------------
-- 3. Permissions - one line per object, nothing on any table.
-- ---------------------------------------------------------------------
GRANT EXECUTE ON dbo.usp_RegisterVehicle   TO parking_app_role;
GRANT EXECUTE ON dbo.usp_VehicleEntry      TO parking_app_role;
GRANT EXECUTE ON dbo.usp_VehicleExit       TO parking_app_role;
GRANT EXECUTE ON dbo.usp_RecordPayment     TO parking_app_role;
GRANT EXECUTE ON dbo.usp_CancelSession     TO parking_app_role;
GRANT EXECUTE ON dbo.usp_SearchSessions    TO parking_app_role;
GRANT EXECUTE ON dbo.usp_GetVehicleHistory TO parking_app_role;
GRANT EXECUTE ON dbo.usp_GetDashboard      TO parking_app_role;

GRANT SELECT ON dbo.vw_SpaceStatus    TO parking_app_role;
GRANT SELECT ON dbo.vw_ActiveSessions TO parking_app_role;
GRANT SELECT ON dbo.vw_DailyRevenue   TO parking_app_role;

-- usp_VehicleEntry_Unsafe: deliberately NOT granted. If it was granted by
-- mistake earlier, take it back (REVOKE removes a GRANT; harmless if none).
IF OBJECT_ID(N'dbo.usp_VehicleEntry_Unsafe', N'P') IS NOT NULL
    REVOKE EXECUTE ON dbo.usp_VehicleEntry_Unsafe FROM parking_app_role;
GO

-- What the role can do (for the report / screenshot).
SELECT pr.name AS Principal, pe.permission_name, pe.state_desc,
       OBJECT_SCHEMA_NAME(pe.major_id) + '.' + OBJECT_NAME(pe.major_id) AS ObjectName
FROM sys.database_permissions AS pe
JOIN sys.database_principals  AS pr ON pr.principal_id = pe.grantee_principal_id
WHERE pr.name = N'parking_app_role'
ORDER BY pe.permission_name, ObjectName;
GO


-- =====================================================================
-- 4. PROOF - act as the app user with EXECUTE AS USER ... REVERT.
--    Every attempt is wrapped in TRY/CATCH so one refusal does not stop
--    the script; results go into a table variable.
--    229 = "The SELECT/DELETE/EXECUTE permission was denied ..."
-- =====================================================================
SET NOCOUNT ON;
DECLARE @R TABLE (No INT, Attempt NVARCHAR(200), Expected NVARCHAR(200), Actual NVARCHAR(400));
DECLARE @x INT, @s INT, @c VARCHAR(10), @Who SYSNAME;

EXECUTE AS USER = 'parking_app';          -- from here on we ARE the app user
SET @Who = USER_NAME();

BEGIN TRY
    SELECT TOP (1) @x = SessionID FROM dbo.ParkingSessions;
    INSERT @R VALUES (1, N'SELECT * FROM dbo.ParkingSessions', N'denied (229)', N'allowed!');
END TRY
BEGIN CATCH
    INSERT @R VALUES (1, N'SELECT * FROM dbo.ParkingSessions', N'denied (229)',
                      CASE WHEN ERROR_NUMBER() = 229 THEN N'denied (229)' ELSE CONCAT(ERROR_NUMBER(), N': ', ERROR_MESSAGE()) END);
END CATCH;

BEGIN TRY
    DELETE FROM dbo.Payments WHERE 1 = 0;   -- deletes nothing even if allowed; we only test the permission
    INSERT @R VALUES (2, N'DELETE FROM dbo.Payments', N'denied (229)', N'allowed!');
END TRY
BEGIN CATCH
    INSERT @R VALUES (2, N'DELETE FROM dbo.Payments', N'denied (229)',
                      CASE WHEN ERROR_NUMBER() = 229 THEN N'denied (229)' ELSE CONCAT(ERROR_NUMBER(), N': ', ERROR_MESSAGE()) END);
END CATCH;

BEGIN TRY
    UPDATE dbo.Vehicles SET OwnerName = OwnerName WHERE 1 = 0;
    INSERT @R VALUES (3, N'UPDATE dbo.Vehicles', N'denied (229)', N'allowed!');
END TRY
BEGIN CATCH
    INSERT @R VALUES (3, N'UPDATE dbo.Vehicles', N'denied (229)',
                      CASE WHEN ERROR_NUMBER() = 229 THEN N'denied (229)' ELSE CONCAT(ERROR_NUMBER(), N': ', ERROR_MESSAGE()) END);
END CATCH;

BEGIN TRY
    EXEC dbo.usp_GetDashboard;              -- its result grid appears above the proof grid
    INSERT @R VALUES (4, N'EXEC dbo.usp_GetDashboard', N'works', N'works');
END TRY
BEGIN CATCH
    INSERT @R VALUES (4, N'EXEC dbo.usp_GetDashboard', N'works', CONCAT(ERROR_NUMBER(), N': ', ERROR_MESSAGE()));
END CATCH;

BEGIN TRY
    SELECT @x = COUNT(*) FROM dbo.vw_SpaceStatus;
    INSERT @R VALUES (5, N'SELECT FROM dbo.vw_SpaceStatus (view)', N'works', N'works');
END TRY
BEGIN CATCH
    INSERT @R VALUES (5, N'SELECT FROM dbo.vw_SpaceStatus (view)', N'works', CONCAT(ERROR_NUMBER(), N': ', ERROR_MESSAGE()));
END CATCH;

BEGIN TRY
    EXEC dbo.usp_VehicleEntry_Unsafe @LicensePlate = N'NOPE', @SessionID = @s OUTPUT, @SpaceCode = @c OUTPUT;
    INSERT @R VALUES (6, N'EXEC dbo.usp_VehicleEntry_Unsafe (demo proc)', N'denied (229)', N'allowed!');
END TRY
BEGIN CATCH
    INSERT @R VALUES (6, N'EXEC dbo.usp_VehicleEntry_Unsafe (demo proc)', N'denied (229)',
                      CASE WHEN ERROR_NUMBER() = 229 THEN N'denied (229)' ELSE CONCAT(ERROR_NUMBER(), N': ', ERROR_MESSAGE()) END);
END CATCH;

-- SQL injection: the "plate" contains SQL. Because the procedure uses it
-- only as a parameter VALUE (never glued into a SQL string), it is just
-- text. It is refused as an invalid plate and nothing is executed.
-- 7: the long attack text from the plan (refused: longer than 15 characters)
BEGIN TRY
    EXEC dbo.usp_RegisterVehicle @LicensePlate = N'X''; DROP TABLE dbo.Payments;--',
         @OwnerName = N'Hacker', @VehicleType = 'Car', @VehicleID = @x OUTPUT;
    INSERT @R VALUES (7, N'Register plate  X''; DROP TABLE dbo.Payments;--', N'refused (50008)', N'accepted!');
END TRY
BEGIN CATCH
    INSERT @R VALUES (7, N'Register plate  X''; DROP TABLE dbo.Payments;--', N'refused (50008)',
                      CASE WHEN ERROR_NUMBER() = 50008 THEN N'refused (50008)' ELSE CONCAT(ERROR_NUMBER(), N': ', ERROR_MESSAGE()) END);
END CATCH;

-- 8: a short attack text (fits in 15 characters) - refused by the table's
--    CHECK constraint CK_Vehicles_PlateChars (quote and ; are not allowed)
BEGIN TRY
    EXEC dbo.usp_RegisterVehicle @LicensePlate = N'X'';DROP--',
         @OwnerName = N'Hacker', @VehicleType = 'Car', @VehicleID = @x OUTPUT;
    INSERT @R VALUES (8, N'Register plate  X'';DROP--  (short)', N'refused by CHECK (50008)', N'accepted!');
END TRY
BEGIN CATCH
    INSERT @R VALUES (8, N'Register plate  X'';DROP--  (short)', N'refused by CHECK (50008)',
                      CASE WHEN ERROR_NUMBER() = 50008 AND ERROR_MESSAGE() LIKE N'%may contain only%'
                           THEN N'refused by CHECK (50008)' ELSE CONCAT(ERROR_NUMBER(), N': ', ERROR_MESSAGE()) END);
END CATCH;

REVERT;                                   -- back to our own (admin) identity

INSERT @R VALUES
 (0, N'Proof ran as database user', N'parking_app', @Who),
 (9, N'dbo.Payments still exists after the injection attempts', N'yes',
     CASE WHEN OBJECT_ID(N'dbo.Payments', N'U') IS NOT NULL THEN N'yes' ELSE N'NO - table is gone!' END);

SELECT No, Attempt, Expected, Actual,
       CASE WHEN Expected = Actual THEN 'PASS' ELSE 'FAIL' END AS Result
FROM @R
ORDER BY No;
GO

-- Back to normal execution (in case the guard at the top stopped the script).
SET NOEXEC OFF;
GO
