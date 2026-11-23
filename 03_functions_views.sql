-- =====================================================================
-- 03_functions_views.sql
-- ---------------------------------------------------------------------
-- WHAT : The fee function and the three read-only views the app uses:
--          dbo.fn_CalculateFee   - the pricing rule, in ONE place
--          dbo.vw_SpaceStatus    - every space, its type/rate, who is in it
--          dbo.vw_ActiveSessions - cars parked right now, minutes so far
--          dbo.vw_DailyRevenue   - payments and money per day
-- WHY  : The fee rule is used by the exit procedure, by the seed script
--        and by vw_ActiveSessions. Writing it once in a function means
--        it can never be calculated two different ways.
--        Views give the app a stable, read-only window: it is granted
--        SELECT on the views only, never on the tables (script 07).
-- CHECK: The fee test grid at the end shows PASS on every line, and the
--        three view samples return rows.
-- NOTE : 02_seed_data.sql created the function already (if it was
--        missing). CREATE OR ALTER here replaces it with this identical
--        definition - THIS file is the official one.
-- =====================================================================

USE ParkingDB;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ---------------------------------------------------------------------
-- fn_CalculateFee
-- Rule: up to 10 minutes  -> free (0.00)
--       otherwise         -> hours rounded UP x hourly rate
--       e.g. 61 min at 2.00 -> 2 hours -> 4.00
-- We count SECONDS, not minutes: DATEDIFF(MINUTE, ...) counts minute
-- BOUNDARIES crossed, so 10:00:59 -> 10:11:00 would be "11 minutes"
-- although only 10 min 1 s passed.
-- WITH SCHEMABINDING: the function touches no table, and schemabinding
-- lets SQL Server mark it deterministic / precise and optimise it better.
-- ---------------------------------------------------------------------
CREATE OR ALTER FUNCTION dbo.fn_CalculateFee
(
    @EntryTime  DATETIME2(0),
    @ExitTime   DATETIME2(0),
    @HourlyRate DECIMAL(6,2)
)
RETURNS DECIMAL(8,2)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @Seconds INT = DATEDIFF(SECOND, @EntryTime, @ExitTime);

    IF @Seconds IS NULL OR @Seconds < 0 OR @HourlyRate IS NULL
        RETURN NULL;                                   -- invalid input: no fee

    IF @Seconds <= 600
        RETURN 0.00;                                   -- 10-minute grace period

    -- 3600.0 (not 3600) forces decimal division; CEILING rounds UP.
    RETURN CAST(CEILING(@Seconds / 3600.0) * @HourlyRate AS DECIMAL(8,2));
END;
GO

-- ---------------------------------------------------------------------
-- vw_SpaceStatus - one row per space (300 rows).
-- LEFT JOIN: spaces without a car must still appear, with NULL plate.
-- The join condition includes Status = 'Active', so only the CURRENT
-- session is matched, never the 400 old ones.
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_SpaceStatus
AS
SELECT  sp.SpaceID,
        sp.SpaceCode,
        sp.FloorNo,
        sp.SpaceTypeID,                  -- the app's Entry screen lists the types from here
        st.TypeName      AS SpaceType,
        st.HourlyRate,
        sp.IsOccupied,
        sp.IsActive      AS InService,
        ps.SessionID     AS CurrentSessionID,
        v.LicensePlate   AS CurrentPlate,
        ps.EntryTime     AS OccupiedSince
FROM dbo.ParkingSpaces        AS sp
JOIN dbo.SpaceTypes           AS st ON st.SpaceTypeID = sp.SpaceTypeID
LEFT JOIN dbo.ParkingSessions AS ps ON ps.SpaceID = sp.SpaceID
                                   AND ps.Status  = 'Active'
LEFT JOIN dbo.Vehicles        AS v  ON v.VehicleID = ps.VehicleID;
GO

-- ---------------------------------------------------------------------
-- vw_ActiveSessions - cars parked right now.
-- CurrentFee = what the driver would pay if leaving this second
-- (same function as the exit procedure, so the numbers always agree).
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_ActiveSessions
AS
SELECT  ps.SessionID,
        v.LicensePlate,
        v.OwnerName,
        v.VehicleType,
        sp.SpaceCode,
        sp.FloorNo,
        st.TypeName                                        AS SpaceType,
        ps.EntryTime,
        DATEDIFF(MINUTE, ps.EntryTime, SYSDATETIME())      AS MinutesParked,
        dbo.fn_CalculateFee(ps.EntryTime,
                            CAST(SYSDATETIME() AS DATETIME2(0)),
                            st.HourlyRate)                 AS CurrentFee
FROM dbo.ParkingSessions AS ps
JOIN dbo.Vehicles        AS v  ON v.VehicleID    = ps.VehicleID
JOIN dbo.ParkingSpaces   AS sp ON sp.SpaceID     = ps.SpaceID
JOIN dbo.SpaceTypes      AS st ON st.SpaceTypeID = sp.SpaceTypeID
WHERE ps.Status = 'Active';
GO

-- ---------------------------------------------------------------------
-- vw_DailyRevenue - one row per calendar day that had payments.
-- A view cannot have ORDER BY; the caller sorts (ORDER BY PayDate DESC).
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_DailyRevenue
AS
SELECT  CAST(p.PaidAt AS DATE) AS PayDate,
        COUNT(*)               AS PaymentCount,
        SUM(p.Amount)          AS TotalAmount
FROM dbo.Payments AS p
GROUP BY CAST(p.PaidAt AS DATE);
GO

-- =====================================================================
-- CHECK 1 - fee function at its edges (rate 2.00). Every line: PASS.
-- =====================================================================
DECLARE @t0 DATETIME2(0) = '2026-01-01 10:00:00';

SELECT Test, Expected, Actual,
       CASE WHEN (Actual = Expected) OR (Actual IS NULL AND Expected IS NULL)
            THEN 'PASS' ELSE 'FAIL' END AS Result
FROM (VALUES
    ('0 min',                         CAST(0.00 AS DECIMAL(8,2)), dbo.fn_CalculateFee(@t0, @t0,                              2.00)),
    ('10 min exactly -> free',        0.00,                       dbo.fn_CalculateFee(@t0, DATEADD(MINUTE, 10, @t0),         2.00)),
    ('10 min 1 s -> 1 h',             2.00,                       dbo.fn_CalculateFee(@t0, DATEADD(SECOND, 601, @t0),        2.00)),
    ('11 min -> 1 h',                 2.00,                       dbo.fn_CalculateFee(@t0, DATEADD(MINUTE, 11, @t0),         2.00)),
    ('60 min -> 1 h',                 2.00,                       dbo.fn_CalculateFee(@t0, DATEADD(MINUTE, 60, @t0),         2.00)),
    ('61 min -> 2 h',                 4.00,                       dbo.fn_CalculateFee(@t0, DATEADD(MINUTE, 61, @t0),         2.00)),
    ('10 h at EV rate 3.00',         30.00,                       dbo.fn_CalculateFee(@t0, DATEADD(HOUR, 10, @t0),           3.00)),
    ('exit before entry -> NULL',     NULL,                       dbo.fn_CalculateFee(@t0, DATEADD(MINUTE, -5, @t0),         2.00)),
    ('no exit time -> NULL',          NULL,                       dbo.fn_CalculateFee(@t0, NULL,                             2.00))
) AS x(Test, Expected, Actual);

--  CHECK 2 - the views return data.
SELECT TOP (10) * FROM dbo.vw_SpaceStatus    ORDER BY IsOccupied DESC, SpaceID;
SELECT TOP (10) * FROM dbo.vw_ActiveSessions ORDER BY EntryTime;
SELECT TOP (10) * FROM dbo.vw_DailyRevenue   ORDER BY PayDate DESC;
GO
