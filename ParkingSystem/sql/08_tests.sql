-- =====================================================================
-- 08_tests.sql
-- ---------------------------------------------------------------------
-- WHAT : One test per rule. Every test states what SHOULD happen and
--        records what DID happen; the result grid shows PASS or FAIL.
--          1xx  every CHECK constraint (+ the foreign keys)
--          2xx  every UNIQUE rule (constraints + filtered unique indexes)
--          3xx  every custom error number 50001-50009
--          4xx  the fee function at its edges (10, 11, 60, 61 min ...)
--          5xx  procedures doing real work + trigger (audit) output
--          6xx  consistency checks on the whole database
--          7xx  the test run itself left nothing behind
-- WHY  : "The database protects itself" is a claim; this script is the
--        proof. Run it after every change - if all lines say PASS,
--        nothing is broken.
-- CHECK: The LAST grid is a one-line summary: Failed = 0, Overall PASS.
--        The grid above it lists every test.
--
-- HOW THE TESTS WORK
--  * Tests that SHOULD fail (1xx-3xx) run with no transaction open. The
--    statement is refused, so nothing changes; we catch the error and
--    compare its number and message with what we expected.
--  * Tests that SHOULD succeed (5xx) run inside ONE transaction that is
--    ROLLED BACK at the end, so the data and the AuditLog are unchanged.
--  * PASS rule for an error test: same error number AND the message
--    contains the expected key text (e.g. the constraint name).
--
-- Re-runnable: yes, as often as you like.
-- =====================================================================

USE ParkingDB;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

DROP TABLE IF EXISTS #R;
CREATE TABLE #R
(
    TestNo INT            NOT NULL,
    Area   NVARCHAR(20)   NOT NULL,
    Test   NVARCHAR(200)  NOT NULL,
    ExpNum INT            NOT NULL,   -- expected error number, 0 = "no error, compare values"
    ExpKey NVARCHAR(400)  NULL,       -- error: text the message must contain / value: expected value
    GotNum INT            NULL,       -- error number that really happened (NULL = none)
    GotMsg NVARCHAR(4000) NULL        -- error message / actual value
);

-- Variables used by every error test.
DECLARE @No INT, @Area NVARCHAR(20), @Test NVARCHAR(200), @ExpNum INT, @Key NVARCHAR(400),
        @GotNum INT, @GotMsg NVARCHAR(4000);

-- Dummy variables for procedure OUTPUT parameters.
DECLARE @oSession INT, @oCode VARCHAR(10), @oFee DECIMAL(8,2), @oPay INT, @oVeh INT;

-- ---------------------------------------------------------------------
-- Test data, looked up from the database (no hard-coded IDs).
-- ---------------------------------------------------------------------
DECLARE @ParkedPlate VARCHAR(15), @ParkedVehicleID INT, @ParkedSpaceID INT, @ActiveSessionID INT,
        @FreePlate VARCHAR(15), @FreeVehicleID INT, @FreeSpaceID INT,
        @PaidSessionID INT, @CancelledSessionID INT, @StandardTypeID TINYINT,
        @AuditCountStart INT, @PaymentCountStart INT, @SessionCountStart INT;

SELECT TOP (1) @ParkedPlate = v.LicensePlate, @ParkedVehicleID = v.VehicleID,
               @ParkedSpaceID = ps.SpaceID, @ActiveSessionID = ps.SessionID
FROM dbo.ParkingSessions AS ps JOIN dbo.Vehicles AS v ON v.VehicleID = ps.VehicleID
WHERE ps.Status = 'Active'
ORDER BY ps.SessionID;

SELECT TOP (1) @FreePlate = v.LicensePlate, @FreeVehicleID = v.VehicleID
FROM dbo.Vehicles AS v
WHERE v.IsActive = 1
  AND NOT EXISTS (SELECT 1 FROM dbo.ParkingSessions AS ps WHERE ps.VehicleID = v.VehicleID AND ps.Status = 'Active')
ORDER BY v.VehicleID;

SELECT @FreeSpaceID = MIN(SpaceID) FROM dbo.ParkingSpaces WHERE IsOccupied = 0 AND IsActive = 1;

SELECT TOP (1) @PaidSessionID = SessionID FROM dbo.Payments ORDER BY PaymentID;
SELECT TOP (1) @CancelledSessionID = SessionID FROM dbo.ParkingSessions WHERE Status = 'Cancelled' ORDER BY SessionID;
SELECT @StandardTypeID = SpaceTypeID FROM dbo.SpaceTypes WHERE TypeName = 'Standard';

SELECT @AuditCountStart   = COUNT(*) FROM dbo.AuditLog;
SELECT @PaymentCountStart = COUNT(*) FROM dbo.Payments;
SELECT @SessionCountStart = COUNT(*) FROM dbo.ParkingSessions;


-- =====================================================================
-- 1xx  CHECK constraints and foreign keys  (expected error 547)
--      Each statement breaks exactly ONE rule, so the message must name
--      exactly that constraint.
-- =====================================================================
SELECT @No = 101, @Area = N'CHECK', @Test = N'Hourly rate 0 is refused', @ExpNum = 547, @Key = N'CK_SpaceTypes_HourlyRate', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY INSERT dbo.SpaceTypes (TypeName, HourlyRate) VALUES ('ZZ Rate', 0); END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 102, @Area = N'CHECK', @Test = N'Lower-case plate ''ab 12'' is refused', @ExpNum = 547, @Key = N'CK_Vehicles_PlateChars', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY INSERT dbo.Vehicles (LicensePlate, OwnerName, VehicleType) VALUES ('ab 12', N'Test', 'Car'); END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 103, @Area = N'CHECK', @Test = N'Plate with symbols ''AB;12'' is refused', @ExpNum = 547, @Key = N'CK_Vehicles_PlateChars', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY INSERT dbo.Vehicles (LicensePlate, OwnerName, VehicleType) VALUES ('AB;12', N'Test', 'Car'); END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 104, @Area = N'CHECK', @Test = N'1-character plate is refused', @ExpNum = 547, @Key = N'CK_Vehicles_PlateLength', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY INSERT dbo.Vehicles (LicensePlate, OwnerName, VehicleType) VALUES ('A', N'Test', 'Car'); END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 105, @Area = N'CHECK', @Test = N'Vehicle type ''Truck'' is refused', @ExpNum = 547, @Key = N'CK_Vehicles_VehicleType', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY INSERT dbo.Vehicles (LicensePlate, OwnerName, VehicleType) VALUES ('ZZ 1', N'Test', 'Truck'); END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 106, @Area = N'CHECK', @Test = N'Session status ''Parked'' is refused', @ExpNum = 547, @Key = N'CK_ParkingSessions_Status', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY INSERT dbo.ParkingSessions (VehicleID, SpaceID, EntryTime, ExitTime, Status, Fee)
          VALUES (@FreeVehicleID, @FreeSpaceID, '2020-01-01 10:00', '2020-01-01 11:00', 'Parked', 2.00); END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 107, @Area = N'CHECK', @Test = N'Negative session fee is refused', @ExpNum = 547, @Key = N'CK_ParkingSessions_Fee', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY INSERT dbo.ParkingSessions (VehicleID, SpaceID, EntryTime, ExitTime, Status, Fee)
          VALUES (@FreeVehicleID, @FreeSpaceID, '2020-01-01 10:00', '2020-01-01 11:00', 'Completed', -1.00); END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 108, @Area = N'CHECK', @Test = N'Exit before entry is refused', @ExpNum = 547, @Key = N'CK_Sessions_ExitAfterEntry', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY INSERT dbo.ParkingSessions (VehicleID, SpaceID, EntryTime, ExitTime, Status, Fee)
          VALUES (@FreeVehicleID, @FreeSpaceID, '2020-01-01 10:00', '2020-01-01 09:00', 'Completed', 0); END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 109, @Area = N'CHECK', @Test = N'Active session WITH an exit time is refused', @ExpNum = 547, @Key = N'CK_Sessions_StatusMatchesExit', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY INSERT dbo.ParkingSessions (VehicleID, SpaceID, EntryTime, ExitTime, Status, Fee)
          VALUES (@FreeVehicleID, @FreeSpaceID, '2020-01-01 10:00', '2020-01-01 11:00', 'Active', NULL); END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 110, @Area = N'CHECK', @Test = N'Active session WITH a fee is refused', @ExpNum = 547, @Key = N'CK_Sessions_StatusMatchesExit', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY INSERT dbo.ParkingSessions (VehicleID, SpaceID, EntryTime, ExitTime, Status, Fee)
          VALUES (@FreeVehicleID, @FreeSpaceID, '2020-01-01 10:00', NULL, 'Active', 2.00); END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 111, @Area = N'CHECK', @Test = N'Completed session WITHOUT an exit time is refused', @ExpNum = 547, @Key = N'CK_Sessions_StatusMatchesExit', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY INSERT dbo.ParkingSessions (VehicleID, SpaceID, EntryTime, ExitTime, Status, Fee)
          VALUES (@FreeVehicleID, @FreeSpaceID, '2020-01-01 10:00', NULL, 'Completed', 2.00); END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 112, @Area = N'CHECK', @Test = N'Negative payment amount is refused', @ExpNum = 547, @Key = N'CK_Payments_Amount', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY INSERT dbo.Payments (SessionID, Amount, Method) VALUES (@CancelledSessionID, -1.00, 'Cash'); END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 113, @Area = N'CHECK', @Test = N'Payment method ''Bitcoin'' is refused', @ExpNum = 547, @Key = N'CK_Payments_Method', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY INSERT dbo.Payments (SessionID, Amount, Method) VALUES (@CancelledSessionID, 1.00, 'Bitcoin'); END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 114, @Area = N'CHECK', @Test = N'Audit action ''X'' is refused', @ExpNum = 547, @Key = N'CK_AuditLog_ActionType', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY INSERT dbo.AuditLog (TableName, ActionType, KeyValue) VALUES (N'Test', 'X', 1); END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 115, @Area = N'FK', @Test = N'Session for a vehicle that does not exist is refused', @ExpNum = 547, @Key = N'FK_ParkingSessions_Vehicles', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY INSERT dbo.ParkingSessions (VehicleID, SpaceID, EntryTime, ExitTime, Status, Fee)
          VALUES (999999, @FreeSpaceID, '2020-01-01 10:00', '2020-01-01 11:00', 'Completed', 2.00); END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 116, @Area = N'FK', @Test = N'Space with a type that does not exist is refused', @ExpNum = 547, @Key = N'FK_ParkingSpaces_SpaceTypes', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY INSERT dbo.ParkingSpaces (SpaceCode, FloorNo, SpaceTypeID) VALUES ('ZZ-1', 1, 99); END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 118, @Area = N'CHECK', @Test = N'Phone ''bozik'' is refused', @ExpNum = 547, @Key = N'CK_Vehicles_Phone', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY INSERT dbo.Vehicles (LicensePlate, OwnerName, Phone, VehicleType) VALUES ('ZZ 3', N'Test', 'bozik', 'Car'); END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 119, @Area = N'CHECK', @Test = N'Owner name ''12345'' is refused', @ExpNum = 547, @Key = N'CK_Vehicles_OwnerName', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY INSERT dbo.Vehicles (LicensePlate, OwnerName, VehicleType) VALUES ('ZZ 4', N'12345', 'Car'); END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 117, @Area = N'FK', @Test = N'Deleting a vehicle that has history is refused (no cascade)', @ExpNum = 547, @Key = N'FK_ParkingSessions_Vehicles', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY DELETE FROM dbo.Vehicles WHERE VehicleID = @ParkedVehicleID; END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);


-- =====================================================================
-- 2xx  UNIQUE rules
--      2627 = UNIQUE / PRIMARY KEY constraint, 2601 = unique INDEX
-- =====================================================================
SELECT @No = 201, @Area = N'UNIQUE', @Test = N'Duplicate space type name is refused', @ExpNum = 2627, @Key = N'UQ_SpaceTypes_TypeName', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY INSERT dbo.SpaceTypes (TypeName, HourlyRate) VALUES ('Standard', 5.00); END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 202, @Area = N'UNIQUE', @Test = N'Duplicate license plate is refused', @ExpNum = 2627, @Key = N'UQ_Vehicles_LicensePlate', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY INSERT dbo.Vehicles (LicensePlate, OwnerName, VehicleType) VALUES (@FreePlate, N'Copy', 'Car'); END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 203, @Area = N'UNIQUE', @Test = N'Duplicate space code F1-001 is refused', @ExpNum = 2627, @Key = N'UQ_ParkingSpaces_SpaceCode', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY INSERT dbo.ParkingSpaces (SpaceCode, FloorNo, SpaceTypeID) VALUES ('F1-001', 1, @StandardTypeID); END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 204, @Area = N'UNIQUE', @Test = N'Second payment for the same session is refused', @ExpNum = 2627, @Key = N'UQ_Payments_SessionID', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY INSERT dbo.Payments (SessionID, Amount, Method) VALUES (@PaidSessionID, 1.00, 'Cash'); END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 205, @Area = N'UNIQUE', @Test = N'Second ACTIVE session on an occupied space is refused', @ExpNum = 2601, @Key = N'UX_Sessions_OneActivePerSpace', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY INSERT dbo.ParkingSessions (VehicleID, SpaceID, Status) VALUES (@FreeVehicleID, @ParkedSpaceID, 'Active'); END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 206, @Area = N'UNIQUE', @Test = N'Second ACTIVE session for a parked vehicle is refused', @ExpNum = 2601, @Key = N'UX_Sessions_OneActivePerVehicle', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY INSERT dbo.ParkingSessions (VehicleID, SpaceID, Status) VALUES (@ParkedVehicleID, @FreeSpaceID, 'Active'); END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

-- The filtered indexes only cover ACTIVE rows: history may repeat freely.
INSERT #R
SELECT 207, N'UNIQUE', N'Filtered index allows many COMPLETED sessions per space (400 each)', 0, N'yes', NULL,
       CASE WHEN (SELECT MAX(c) FROM (SELECT COUNT(*) AS c FROM dbo.ParkingSessions
                                      WHERE Status <> 'Active' GROUP BY SpaceID) AS x) > 1
            THEN N'yes' ELSE N'no' END;


-- =====================================================================
-- 3xx  Custom error numbers raised by the procedures
-- =====================================================================
SELECT @No = 301, @Area = N'ERROR', @Test = N'Entry of an unregistered plate', @ExpNum = 50001, @Key = N'not registered', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY EXEC dbo.usp_VehicleEntry @LicensePlate = N'ZZ 999999', @SessionID = @oSession OUTPUT, @SpaceCode = @oCode OUTPUT; END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 302, @Area = N'ERROR', @Test = N'Entry of a car that is already parked', @ExpNum = 50002, @Key = N'already parked', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY EXEC dbo.usp_VehicleEntry @LicensePlate = @ParkedPlate, @SessionID = @oSession OUTPUT, @SpaceCode = @oCode OUTPUT; END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

-- 50003: a temporary space type that has NO spaces -> no free space of that type.
DECLARE @EmptyTypeID TINYINT;
INSERT dbo.SpaceTypes (TypeName, HourlyRate) VALUES ('ZZ Test Type', 1.00);
SET @EmptyTypeID = SCOPE_IDENTITY();

SELECT @No = 303, @Area = N'ERROR', @Test = N'Entry when no space of the requested type is free', @ExpNum = 50003, @Key = N'No free space', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY EXEC dbo.usp_VehicleEntry @LicensePlate = @FreePlate, @SpaceTypeID = @EmptyTypeID, @SessionID = @oSession OUTPUT, @SpaceCode = @oCode OUTPUT; END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

DELETE FROM dbo.SpaceTypes WHERE SpaceTypeID = @EmptyTypeID;   -- clean up

SELECT @No = 304, @Area = N'ERROR', @Test = N'Exit of a car that is not parked', @ExpNum = 50004, @Key = N'no active session', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY EXEC dbo.usp_VehicleExit @LicensePlate = @FreePlate, @SessionID = @oSession OUTPUT, @Fee = @oFee OUTPUT; END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 305, @Area = N'ERROR', @Test = N'Cancel of a session that is already completed', @ExpNum = 50004, @Key = N'not active', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY EXEC dbo.usp_CancelSession @SessionID = @PaidSessionID; END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 306, @Area = N'ERROR', @Test = N'Payment for a session that is still ACTIVE', @ExpNum = 50005, @Key = N'cannot be paid', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY EXEC dbo.usp_RecordPayment @SessionID = @ActiveSessionID, @Method = 'Cash', @PaymentID = @oPay OUTPUT; END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 307, @Area = N'ERROR', @Test = N'Payment for a CANCELLED session', @ExpNum = 50005, @Key = N'cannot be paid', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY EXEC dbo.usp_RecordPayment @SessionID = @CancelledSessionID, @Method = 'Cash', @PaymentID = @oPay OUTPUT; END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 308, @Area = N'ERROR', @Test = N'Second payment for a paid session', @ExpNum = 50006, @Key = N'already has a payment', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY EXEC dbo.usp_RecordPayment @SessionID = @PaidSessionID, @Method = 'Card', @PaymentID = @oPay OUTPUT; END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

-- Typed in lower case with extra spaces: normalisation makes it the SAME plate.
SELECT @No = 309, @Area = N'ERROR', @Test = N'Registering an existing plate (typed lower-case, with spaces)', @ExpNum = 50007, @Key = N'already registered', @GotNum = NULL, @GotMsg = NULL;
DECLARE @MessyPlate NVARCHAR(50) = N'  ' + LOWER(@FreePlate) + N' ';
BEGIN TRY EXEC dbo.usp_RegisterVehicle @LicensePlate = @MessyPlate, @OwnerName = N'Copy', @VehicleType = 'Car', @VehicleID = @oVeh OUTPUT; END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 310, @Area = N'ERROR', @Test = N'Register with an empty plate', @ExpNum = 50008, @Key = N'license plate is required', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY EXEC dbo.usp_RegisterVehicle @LicensePlate = N'   ', @OwnerName = N'Test', @VehicleType = 'Car', @VehicleID = @oVeh OUTPUT; END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 311, @Area = N'ERROR', @Test = N'Register a plate with symbols (table CHECK -> friendly 50008)', @ExpNum = 50008, @Key = N'may contain only', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY EXEC dbo.usp_RegisterVehicle @LicensePlate = N'AB;12', @OwnerName = N'Test', @VehicleType = 'Car', @VehicleID = @oVeh OUTPUT; END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 312, @Area = N'ERROR', @Test = N'Register a plate longer than 15 characters', @ExpNum = 50008, @Key = N'at most 15', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY EXEC dbo.usp_RegisterVehicle @LicensePlate = N'ABCDEFGHIJ123456', @OwnerName = N'Test', @VehicleType = 'Car', @VehicleID = @oVeh OUTPUT; END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 313, @Area = N'ERROR', @Test = N'Register with vehicle type ''Truck''', @ExpNum = 50008, @Key = N'vehicle type', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY EXEC dbo.usp_RegisterVehicle @LicensePlate = N'ZZ 2', @OwnerName = N'Test', @VehicleType = 'Truck', @VehicleID = @oVeh OUTPUT; END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 314, @Area = N'ERROR', @Test = N'Register without an owner name', @ExpNum = 50008, @Key = N'owner name', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY EXEC dbo.usp_RegisterVehicle @LicensePlate = N'ZZ 2', @OwnerName = N'', @VehicleType = 'Car', @VehicleID = @oVeh OUTPUT; END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 315, @Area = N'ERROR', @Test = N'Payment method ''Bitcoin''', @ExpNum = 50008, @Key = N'payment method', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY EXEC dbo.usp_RecordPayment @SessionID = @CancelledSessionID, @Method = 'Bitcoin', @PaymentID = @oPay OUTPUT; END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 316, @Area = N'ERROR', @Test = N'Payment for a session that does not exist', @ExpNum = 50008, @Key = N'does not exist', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY EXEC dbo.usp_RecordPayment @SessionID = -1, @Method = 'Cash', @PaymentID = @oPay OUTPUT; END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 317, @Area = N'ERROR', @Test = N'Entry with debug delay 31 s (max is 30)', @ExpNum = 50008, @Key = N'debug delay', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY EXEC dbo.usp_VehicleEntry @LicensePlate = @FreePlate, @DebugDelaySeconds = 31, @SessionID = @oSession OUTPUT, @SpaceCode = @oCode OUTPUT; END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 318, @Area = N'ERROR', @Test = N'Entry with a space type that does not exist', @ExpNum = 50008, @Key = N'unknown space type', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY EXEC dbo.usp_VehicleEntry @LicensePlate = @FreePlate, @SpaceTypeID = 99, @SessionID = @oSession OUTPUT, @SpaceCode = @oCode OUTPUT; END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 319, @Area = N'ERROR', @Test = N'Search with page size 0', @ExpNum = 50008, @Key = N'page size', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY EXEC dbo.usp_SearchSessions @PageSize = 0; END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 320, @Area = N'ERROR', @Test = N'Search with status ''Parked''', @ExpNum = 50008, @Key = N'status must be', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY EXEC dbo.usp_SearchSessions @Status = 'Parked'; END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 321, @Area = N'ERROR', @Test = N'Search with a wildcard in the plate filter', @ExpNum = 50008, @Key = N'plate filter', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY EXEC dbo.usp_SearchSessions @LicensePlate = N'%'; END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 322, @Area = N'ERROR', @Test = N'DELETE of a payment refused by trg_Payments_Protect', @ExpNum = 50009, @Key = N'permanent records', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY DELETE FROM dbo.Payments WHERE SessionID = @PaidSessionID; END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

INSERT #R
SELECT 323, N'ERROR', N'... and the payment is still there', 0, N'yes', NULL,
       CASE WHEN EXISTS (SELECT 1 FROM dbo.Payments WHERE SessionID = @PaidSessionID) THEN N'yes' ELSE N'no' END;

SELECT @No = 324, @Area = N'ERROR', @Test = N'Register with phone ''bozik'' (CHECK -> friendly 50008)', @ExpNum = 50008, @Key = N'phone may contain', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY EXEC dbo.usp_RegisterVehicle @LicensePlate = N'ZZ 5', @OwnerName = N'Test', @Phone = 'bozik', @VehicleType = 'Car', @VehicleID = @oVeh OUTPUT; END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

SELECT @No = 325, @Area = N'ERROR', @Test = N'Register with owner name ''R2D2'' (CHECK -> friendly 50008)', @ExpNum = 50008, @Key = N'owner name needs', @GotNum = NULL, @GotMsg = NULL;
BEGIN TRY EXEC dbo.usp_RegisterVehicle @LicensePlate = N'ZZ 6', @OwnerName = N'R2D2', @VehicleType = 'Car', @VehicleID = @oVeh OUTPUT; END TRY
BEGIN CATCH SELECT @GotNum = ERROR_NUMBER(), @GotMsg = ERROR_MESSAGE(); END CATCH;
INSERT #R VALUES (@No, @Area, @Test, @ExpNum, @Key, @GotNum, @GotMsg);

-- Resetting the identity counter of SpaceTypes.
-- Every INSERT attempt (even a refused one, and the temporary type of
-- test 303) uses up an identity value, and identity values are never
-- given back. SpaceTypeID is a TINYINT (max 255), so after many test runs
-- the counter could run out. RESEED sets it back to the highest ID in use.
DECLARE @MaxType INT = (SELECT MAX(SpaceTypeID) FROM dbo.SpaceTypes);
DBCC CHECKIDENT ('dbo.SpaceTypes', RESEED, @MaxType) WITH NO_INFOMSGS;


-- =====================================================================
-- 4xx  Fee function at its edges (rate 2.00)
-- =====================================================================
DECLARE @t0 DATETIME2(0) = '2026-01-01 10:00:00';

INSERT #R
SELECT No, N'FEE', Test, 0, CAST(Expected AS NVARCHAR(20)), NULL, ISNULL(CAST(Actual AS NVARCHAR(20)), N'NULL')
FROM (VALUES
    (401, N'10 min exactly -> free',    N'0.00', dbo.fn_CalculateFee(@t0, DATEADD(MINUTE, 10, @t0),  2.00)),
    (402, N'10 min 1 s -> 1 hour',      N'2.00', dbo.fn_CalculateFee(@t0, DATEADD(SECOND, 601, @t0), 2.00)),
    (403, N'11 min -> 1 hour',          N'2.00', dbo.fn_CalculateFee(@t0, DATEADD(MINUTE, 11, @t0),  2.00)),
    (404, N'60 min -> 1 hour',          N'2.00', dbo.fn_CalculateFee(@t0, DATEADD(MINUTE, 60, @t0),  2.00)),
    (405, N'61 min -> 2 hours',         N'4.00', dbo.fn_CalculateFee(@t0, DATEADD(MINUTE, 61, @t0),  2.00)),
    (406, N'0 min -> free',             N'0.00', dbo.fn_CalculateFee(@t0, @t0,                       2.00)),
    (407, N'exit before entry -> NULL', N'NULL', dbo.fn_CalculateFee(@t0, DATEADD(MINUTE, -1, @t0), 2.00))
) AS x(No, Test, Expected, Actual);


-- =====================================================================
-- 5xx  Procedures doing real work + trigger output
--      All inside ONE transaction that is rolled back at the end.
--      XACT_ABORT ON + TRY/CATCH: if anything fails unexpectedly, the
--      whole block is undone and recorded as test 599 = FAIL, so a broken
--      test can never leave changes behind.
-- =====================================================================
-- Results of this block go into a TABLE VARIABLE, not into #R:
-- a temp table is part of the transaction, so the ROLLBACK at the end
-- would erase the results too. Table variables ignore ROLLBACK.
DECLARE @R5 TABLE (TestNo INT, Area NVARCHAR(20), Test NVARCHAR(200), ExpNum INT,
                   ExpKey NVARCHAR(400), GotNum INT, GotMsg NVARCHAR(4000));

DECLARE @P1 VARCHAR(15), @P2 VARCHAR(15), @P3 VARCHAR(15),
        @S1 INT, @S2 INT, @S3 INT, @C1 VARCHAR(10), @C2 VARCHAR(10), @C3 VARCHAR(10),
        @ExpCode VARCHAR(10), @NextFree INT, @EvTypeID TINYINT, @Rate DECIMAL(6,2),
        @Fee DECIMAL(8,2), @PayID INT, @AuditMark BIGINT, @Actual NVARCHAR(400);

-- Three vehicles that are not parked.
SELECT @P1 = MAX(CASE WHEN rn = 1 THEN LicensePlate END),
       @P2 = MAX(CASE WHEN rn = 2 THEN LicensePlate END),
       @P3 = MAX(CASE WHEN rn = 3 THEN LicensePlate END)
FROM (SELECT TOP (3) v.LicensePlate, ROW_NUMBER() OVER (ORDER BY v.VehicleID) AS rn
      FROM dbo.Vehicles AS v
      WHERE v.IsActive = 1
        AND NOT EXISTS (SELECT 1 FROM dbo.ParkingSessions AS ps
                        WHERE ps.VehicleID = v.VehicleID AND ps.Status = 'Active')
      ORDER BY v.VehicleID) AS x;

SELECT @EvTypeID = SpaceTypeID FROM dbo.SpaceTypes WHERE TypeName = 'EV';

SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;
    SELECT @AuditMark = ISNULL(MAX(AuditID), 0) FROM dbo.AuditLog;

    -- 501 lowest free in-service space
    SELECT @ExpCode = SpaceCode FROM dbo.ParkingSpaces
    WHERE SpaceID = (SELECT MIN(SpaceID) FROM dbo.ParkingSpaces WHERE IsOccupied = 0 AND IsActive = 1);
    EXEC dbo.usp_VehicleEntry @LicensePlate = @P1, @SessionID = @S1 OUTPUT, @SpaceCode = @C1 OUTPUT;
    INSERT @R5 VALUES (501, N'PROC', N'Entry gets the lowest-numbered free in-service space', 0, @ExpCode, NULL, @C1);

    -- 502 out-of-service space is skipped
    SELECT @NextFree = MIN(SpaceID) FROM dbo.ParkingSpaces WHERE IsOccupied = 0 AND IsActive = 1;
    UPDATE dbo.ParkingSpaces SET IsActive = 0 WHERE SpaceID = @NextFree;
    SELECT @ExpCode = SpaceCode FROM dbo.ParkingSpaces
    WHERE SpaceID = (SELECT MIN(SpaceID) FROM dbo.ParkingSpaces WHERE IsOccupied = 0 AND IsActive = 1);
    EXEC dbo.usp_VehicleEntry @LicensePlate = @P2, @SessionID = @S2 OUTPUT, @SpaceCode = @C2 OUTPUT;
    INSERT @R5 VALUES (502, N'PROC', N'Entry skips a space that is out of service', 0, @ExpCode, NULL, @C2);

    -- 503 space type filter
    EXEC dbo.usp_VehicleEntry @LicensePlate = @P3, @SpaceTypeID = @EvTypeID, @SessionID = @S3 OUTPUT, @SpaceCode = @C3 OUTPUT;
    SELECT @Actual = st.TypeName FROM dbo.ParkingSpaces AS sp JOIN dbo.SpaceTypes AS st ON st.SpaceTypeID = sp.SpaceTypeID
    WHERE sp.SpaceCode = @C3;
    INSERT @R5 VALUES (503, N'PROC', N'Entry with type filter EV gets an EV space', 0, N'EV', NULL, @Actual);

    -- 504 a 61-minute stay costs 2 hours (pretend car 1 arrived 61 minutes ago)
    UPDATE dbo.ParkingSessions
    SET EntryTime = DATEADD(MINUTE, -61, CAST(SYSDATETIME() AS DATETIME2(0)))
    WHERE SessionID = @S1;
    SELECT @Rate = st.HourlyRate FROM dbo.ParkingSpaces AS sp JOIN dbo.SpaceTypes AS st ON st.SpaceTypeID = sp.SpaceTypeID
    WHERE sp.SpaceCode = @C1;
    EXEC dbo.usp_VehicleExit @LicensePlate = @P1, @SessionID = @S1 OUTPUT, @Fee = @Fee OUTPUT;
    INSERT @R5 VALUES (504, N'PROC', N'Exit after 61 minutes charges 2 x hourly rate', 0,
                      CAST(CAST(@Rate * 2 AS DECIMAL(8,2)) AS NVARCHAR(20)), NULL, CAST(@Fee AS NVARCHAR(20)));

    -- 505 exit frees the space and completes the session
    SELECT @Actual = CONCAT(ps.Status, N' / space occupied = ', sp.IsOccupied)
    FROM dbo.ParkingSessions AS ps JOIN dbo.ParkingSpaces AS sp ON sp.SpaceID = ps.SpaceID
    WHERE ps.SessionID = @S1;
    INSERT @R5 VALUES (505, N'PROC', N'Exit completes the session and frees the space', 0, N'Completed / space occupied = 0', NULL, @Actual);

    -- 506 payment amount is taken from the session, method normalised
    EXEC dbo.usp_RecordPayment @SessionID = @S1, @Method = 'mobile', @PaymentID = @PayID OUTPUT;
    SELECT @Actual = CONCAT(Amount, N' / ', Method) FROM dbo.Payments WHERE PaymentID = @PayID;
    INSERT @R5 VALUES (506, N'PROC', N'Payment amount = session fee; method stored as Mobile', 0,
                      CONCAT(@Fee, N' / Mobile'), NULL, @Actual);

    -- 507 cancel
    EXEC dbo.usp_CancelSession @SessionID = @S3;
    SELECT @Actual = CONCAT(ps.Status, N' / fee ', ps.Fee, N' / space occupied = ', sp.IsOccupied)
    FROM dbo.ParkingSessions AS ps JOIN dbo.ParkingSpaces AS sp ON sp.SpaceID = ps.SpaceID
    WHERE ps.SessionID = @S3;
    INSERT @R5 VALUES (507, N'PROC', N'Cancel: status Cancelled, fee 0, space freed', 0,
                      N'Cancelled / fee 0.00 / space occupied = 0', NULL, @Actual);

    -- 508 one statement, three rows -> three audit rows
    UPDATE dbo.Vehicles SET Phone = Phone WHERE VehicleID IN (1, 2, 3);

    -- 509 trigger output for everything above:
    --   ParkingSessions I = 3 entries
    --   ParkingSessions U = 3 (the 61-min EntryTime change, the exit, the cancel)
    --   ParkingSpaces   U = 1 (out of service; the 6 occupancy flips are NOT logged)
    --   Payments        I = 1
    --   Vehicles        U = 3 (one statement, three rows)
    SELECT @Actual = CONCAT(
        N'Sessions I=', SUM(CASE WHEN TableName = N'ParkingSessions' AND ActionType = 'I' THEN 1 ELSE 0 END),
        N' U=',         SUM(CASE WHEN TableName = N'ParkingSessions' AND ActionType = 'U' THEN 1 ELSE 0 END),
        N' | Spaces U=',   SUM(CASE WHEN TableName = N'ParkingSpaces' THEN 1 ELSE 0 END),
        N' | Payments I=', SUM(CASE WHEN TableName = N'Payments'      THEN 1 ELSE 0 END),
        N' | Vehicles U=', SUM(CASE WHEN TableName = N'Vehicles'      THEN 1 ELSE 0 END))
    FROM dbo.AuditLog WHERE AuditID > @AuditMark;
    INSERT @R5 VALUES (508, N'TRIGGER', N'One audit row per changed row, per table and action', 0,
                      N'Sessions I=3 U=3 | Spaces U=1 | Payments I=1 | Vehicles U=3', NULL, @Actual);

    SELECT @Actual = CONCAT(JSON_VALUE(OldValues, '$.Status'), N' -> ', JSON_VALUE(NewValues, '$.Status'),
                            N', fee ', JSON_VALUE(NewValues, '$.Fee'))
    FROM dbo.AuditLog
    WHERE AuditID > @AuditMark AND TableName = N'ParkingSessions' AND KeyValue = @S1
      AND JSON_VALUE(NewValues, '$.Status') = 'Completed';
    INSERT @R5 VALUES (509, N'TRIGGER', N'Exit audit row: old/new JSON show the change and the fee', 0,
                      CONCAT(N'Active -> Completed, fee ', @Fee), NULL, @Actual);

    SELECT @Actual = CASE WHEN COUNT(*) > 0 AND MIN(ChangedBy) = ORIGINAL_LOGIN() AND MAX(ChangedBy) = ORIGINAL_LOGIN()
                          THEN N'yes' ELSE N'no' END
    FROM dbo.AuditLog WHERE AuditID > @AuditMark;
    INSERT @R5 VALUES (510, N'TRIGGER', N'Audit rows record who made the change (ORIGINAL_LOGIN)', 0, N'yes', NULL, @Actual);

    -- 511 the IsOccupied flag still matches the sessions after all this work
    SELECT @Actual = CAST(COUNT(*) AS NVARCHAR(20))
    FROM dbo.ParkingSpaces AS sp
    WHERE sp.IsOccupied <> CASE WHEN EXISTS (SELECT 1 FROM dbo.ParkingSessions AS ps
                                             WHERE ps.SpaceID = sp.SpaceID AND ps.Status = 'Active')
                                THEN 1 ELSE 0 END;
    INSERT @R5 VALUES (511, N'PROC', N'IsOccupied agrees with sessions after entries/exit/cancel', 0, N'0', NULL, @Actual);

    ROLLBACK TRANSACTION;   -- undo all 5xx work; @R5 keeps the results
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    INSERT @R5 VALUES (599, N'PROC', N'Unexpected error in the 5xx block', 0, N'no error', ERROR_NUMBER(), ERROR_MESSAGE());
END CATCH;
SET XACT_ABORT OFF;

INSERT #R SELECT * FROM @R5;

-- =====================================================================
-- 7xx  The test run left nothing behind: every refused statement
--      changed nothing, and the 5xx work was rolled back.
-- =====================================================================
INSERT #R
SELECT No, N'CLEAN', Test, 0, CAST(Expected AS NVARCHAR(20)), NULL, CAST(Actual AS NVARCHAR(20))
FROM (VALUES
    (701, N'AuditLog row count unchanged',        @AuditCountStart,   (SELECT COUNT(*) FROM dbo.AuditLog)),
    (702, N'Payments row count unchanged',        @PaymentCountStart, (SELECT COUNT(*) FROM dbo.Payments)),
    (703, N'ParkingSessions row count unchanged', @SessionCountStart, (SELECT COUNT(*) FROM dbo.ParkingSessions)),
    (704, N'Only the 4 real space types remain',  4,                  (SELECT COUNT(*) FROM dbo.SpaceTypes))
) AS x(No, Test, Expected, Actual);
GO


-- =====================================================================
-- 6xx  Consistency checks on the whole database (each expects 0 rows)
-- =====================================================================
INSERT #R
SELECT TestNo, N'CONSIST', Test, 0, N'0', NULL, CAST(BadRows AS NVARCHAR(20))
FROM
(
    SELECT 601 AS TestNo, N'Spaces marked occupied without an active session' AS Test,
           (SELECT COUNT(*) FROM dbo.ParkingSpaces AS sp
             WHERE sp.IsOccupied = 1
               AND NOT EXISTS (SELECT 1 FROM dbo.ParkingSessions AS ps
                                WHERE ps.SpaceID = sp.SpaceID AND ps.Status = 'Active')) AS BadRows
    UNION ALL
    SELECT 602, N'Active sessions whose space is not marked occupied',
           (SELECT COUNT(*) FROM dbo.ParkingSessions AS ps
              JOIN dbo.ParkingSpaces AS sp ON sp.SpaceID = ps.SpaceID
             WHERE ps.Status = 'Active' AND sp.IsOccupied = 0)
    UNION ALL
    SELECT 603, N'Completed sessions with Fee > 0 and no payment (seeded data)',
           (SELECT COUNT(*) FROM dbo.ParkingSessions AS ps
             WHERE ps.Status = 'Completed' AND ps.Fee > 0
               AND ps.ExitTime < CAST(CAST(SYSDATETIME() AS DATE) AS DATETIME2(0))   -- seeded history = before today
               AND NOT EXISTS (SELECT 1 FROM dbo.Payments AS p WHERE p.SessionID = ps.SessionID))
    UNION ALL
    SELECT 604, N'Payments whose amount differs from the session fee',
           (SELECT COUNT(*) FROM dbo.Payments AS p
              JOIN dbo.ParkingSessions AS ps ON ps.SessionID = p.SessionID
             WHERE p.Amount <> ps.Fee)
    UNION ALL
    SELECT 605, N'Payments for sessions that are not Completed',
           (SELECT COUNT(*) FROM dbo.Payments AS p
              JOIN dbo.ParkingSessions AS ps ON ps.SessionID = p.SessionID
             WHERE ps.Status <> 'Completed')
    UNION ALL
    SELECT 606, N'Space used by two cars at the same time',
           (SELECT COUNT(*) FROM
               (SELECT EntryTime, LAG(ExitTime) OVER (PARTITION BY SpaceID ORDER BY EntryTime) AS PrevExit
                  FROM dbo.ParkingSessions) AS x
             WHERE x.PrevExit > x.EntryTime)
    UNION ALL
    SELECT 607, N'Car in two places at the same time',
           (SELECT COUNT(*) FROM
               (SELECT EntryTime, LAG(ExitTime) OVER (PARTITION BY VehicleID ORDER BY EntryTime) AS PrevExit
                  FROM dbo.ParkingSessions) AS x
             WHERE x.PrevExit > x.EntryTime)
    UNION ALL
    SELECT 608, N'Active sessions on out-of-service spaces',
           (SELECT COUNT(*) FROM dbo.ParkingSessions AS ps
              JOIN dbo.ParkingSpaces AS sp ON sp.SpaceID = ps.SpaceID
             WHERE ps.Status = 'Active' AND sp.IsActive = 0)
) AS c;
GO

-- =====================================================================
-- RESULTS
-- =====================================================================
SELECT TestNo,
       Area,
       Test,
       CASE WHEN ExpNum = 0 THEN ExpKey
            ELSE CONCAT(N'error ', ExpNum, N' (', ExpKey, N')') END            AS Expected,
       CASE WHEN GotNum IS NULL THEN ISNULL(GotMsg, N'no error')
            ELSE CONCAT(N'error ', GotNum, N': ', GotMsg) END                   AS Actual,
       CASE WHEN ExpNum = 0     AND GotNum IS NULL   AND GotMsg = ExpKey                 THEN 'PASS'
            WHEN ExpNum <> 0    AND GotNum = ExpNum  AND GotMsg LIKE N'%' + ExpKey + N'%' THEN 'PASS'
            ELSE 'FAIL' END                                                       AS Result
FROM #R
ORDER BY TestNo;

SELECT COUNT(*)                                                         AS TotalTests,
       SUM(CASE WHEN r.Result = 'PASS' THEN 1 ELSE 0 END)               AS Passed,
       SUM(CASE WHEN r.Result = 'FAIL' THEN 1 ELSE 0 END)               AS Failed,
       CASE WHEN SUM(CASE WHEN r.Result = 'FAIL' THEN 1 ELSE 0 END) = 0
            THEN 'PASS' ELSE 'FAIL' END                                 AS Overall
FROM (SELECT CASE WHEN ExpNum = 0  AND GotNum IS NULL  AND GotMsg = ExpKey                 THEN 'PASS'
                  WHEN ExpNum <> 0 AND GotNum = ExpNum AND GotMsg LIKE N'%' + ExpKey + N'%' THEN 'PASS'
                  ELSE 'FAIL' END AS Result
      FROM #R) AS r;
GO
