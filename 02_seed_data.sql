/* =====================================================================
   02_seed_data.sql
   ---------------------------------------------------------------------
   WHAT : Fills ParkingDB with realistic test data:
            4 space types, 300 spaces (3 floors x 100),
            5,000 vehicles,
            120,000 historical sessions (300 spaces x 400 time slots),
            one payment per completed session with Fee > 0,
            about 40 current 'Active' sessions (cars parked right now).
   WHY  : The performance work in script 06 only means something on a
          large table. The history is generated so that it is PHYSICALLY
          POSSIBLE: no space holds two cars at once and no car is in two
          places at once. The checks at the end prove it.
   HOW  : Set-based only (no loops, no cursors). A numbers table built
          from a cross join of sys.all_objects gives us rows to work
          with; ABS(CHECKSUM(NEWID()) % N) gives a random number 0..N-1.
   CHECK: The last two result grids must show:
            - ParkingSessions > 100,000 rows  (PASS)
            - every consistency check = 0 rows (PASS)

   ORDER: Needs EMPTY tables, i.e. run 01_schema.sql right before this.
          If the tables already contain data the script stops with a
          clear message and changes nothing.
          This script runs BEFORE 03, so it creates dbo.fn_CalculateFee
          itself if it is missing (script 03 then replaces it with the
          identical definition via CREATE OR ALTER).
          Triggers (script 05) do not exist yet, on purpose: the seed
          rows are not "changes", so the AuditLog stays empty.
   ===================================================================== */

USE ParkingDB;
GO
SET ANSI_NULLS ON;          -- required for inserting into a table with filtered indexes
SET QUOTED_IDENTIFIER ON;   -- (same reason)
SET NOCOUNT ON;             -- hide the "(n rows affected)" noise
GO

/* ---------------------------------------------------------------------
   0. Guard: refuse to run on a database that already has data.
   SET NOEXEC ON makes SSMS compile but NOT execute every following
   batch, so nothing below runs. It is switched back OFF at the very end.
   --------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM dbo.SpaceTypes)
   OR EXISTS (SELECT 1 FROM dbo.Vehicles)
   OR EXISTS (SELECT 1 FROM dbo.ParkingSessions)
BEGIN
    RAISERROR('ParkingDB already contains data. Run 01_schema.sql first (it recreates empty tables), then run this script again. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ---------------------------------------------------------------------
   1. Fee function - created here only if missing (see ORDER above).
   CREATE FUNCTION must be the first statement of a batch, so to put it
   behind an IF we run it as dynamic SQL with EXEC.
   The rule (section 3 of the plan):
     - up to 10 minutes      -> free
     - otherwise             -> hours rounded UP x hourly rate
   We measure in SECONDS, not minutes: DATEDIFF(MINUTE, ...) counts how
   many minute BOUNDARIES are crossed, so 10:00:59 -> 10:11:00 would count
   as 11 minutes although only 10 min 1 s passed.
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'dbo.fn_CalculateFee', N'FN') IS NULL
    EXEC (N'
CREATE FUNCTION dbo.fn_CalculateFee
(
    @EntryTime  DATETIME2(0),
    @ExitTime   DATETIME2(0),
    @HourlyRate DECIMAL(6,2)
)
RETURNS DECIMAL(8,2)
WITH SCHEMABINDING   /* binds the function to its definition; required for it to be treated as deterministic and lets SQL Server inline/optimise it */
AS
BEGIN
    DECLARE @Seconds INT = DATEDIFF(SECOND, @EntryTime, @ExitTime);

    IF @Seconds IS NULL OR @Seconds < 0 OR @HourlyRate IS NULL
        RETURN NULL;                                   /* invalid input: no fee */

    IF @Seconds <= 600
        RETURN 0.00;                                   /* 10 minutes grace period */

    /* 3600.0 (not 3600) forces decimal division; CEILING rounds UP. */
    RETURN CAST(CEILING(@Seconds / 3600.0) * @HourlyRate AS DECIMAL(8,2));
END');
GO

/* ---------------------------------------------------------------------
   2. Generate everything in ONE batch (variables only live inside a
      batch) and ONE transaction (all or nothing).
   --------------------------------------------------------------------- */
SET XACT_ABORT ON;   -- any runtime error rolls back the whole transaction automatically

DECLARE @Now   DATETIME2(0) = SYSDATETIME();
DECLARE @Today DATETIME2(0) = CAST(CAST(@Now AS DATE) AS DATETIME2(0));   -- today 00:00

/* Slot n of every space starts at @Base + n*12 h + (0..59 min) and lasts
   5 min .. 10 h, so it ends at most 10 h 59 min after the slot start:
   it can never overlap slot n+1. 400 slots x 12 h = 4,800 h (200 days).
   The last slot (n = 399) starts at @Today - 12 h and ends at the latest
   at @Today - 1 min, i.e. the whole history is before today. */
DECLARE @Base  DATETIME2(0) = DATEADD(HOUR, -400 * 12, @Today);

/* ---- 2a. Numbers table 1..5000 -------------------------------------
   sys.all_objects has a few thousand rows in every database; crossing it
   with itself gives millions, and TOP keeps the first 5000. We only need
   the row count, never the content. */
DROP TABLE IF EXISTS #Numbers;
SELECT TOP (5000) CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS INT) AS n
INTO #Numbers
FROM sys.all_objects AS a
CROSS JOIN sys.all_objects AS b;

/* ---- 2b. Random values are STORED in temp tables first. -------------
   Why not use NEWID() directly where we need it?
     - NEWID() is re-evaluated every time it appears. CASE / CHOOSE with
       NEWID() inside re-rolls the dice for every WHEN branch and can end
       up matching NO branch (NULL). A join ON ... = NEWID()-expression
       can match 0 or 2 rows.
     - Storing the random number once in a column makes every later use
       see the SAME value.
   Why ABS(CHECKSUM(NEWID()) % N) and not ABS(CHECKSUM(NEWID())) % N?
     CHECKSUM can (rarely) return -2,147,483,648, and ABS of that number
     overflows an INT. Taking % N first keeps the value small. */

DECLARE @FirstNames TABLE (id INT PRIMARY KEY, name NVARCHAR(30));
INSERT @FirstNames VALUES
 (0,N'Ahmad'),(1,N'Maya'),(2,N'Karim'),(3,N'Rana'),(4,N'Elie'),(5,N'Nour'),(6,N'Omar'),
 (7,N'Lea'),(8,N'Hadi'),(9,N'Yasmine'),(10,N'Georges'),(11,N'Sara'),(12,N'Ali'),
 (13,N'Joelle'),(14,N'Fadi'),(15,N'Rita'),(16,N'Charbel'),(17,N'Lina'),(18,N'Hussein'),(19,N'Christelle');

DECLARE @LastNames TABLE (id INT PRIMARY KEY, name NVARCHAR(30));
INSERT @LastNames VALUES
 (0,N'Haddad'),(1,N'Khoury'),(2,N'Nassar'),(3,N'Saab'),(4,N'Fares'),(5,N'Hamdan'),(6,N'Aoun'),
 (7,N'Salameh'),(8,N'Mansour'),(9,N'Daher'),(10,N'Harb'),(11,N'Khalil'),(12,N'Rizk'),
 (13,N'Chahine'),(14,N'Itani'),(15,N'Ghanem'),(16,N'Sleiman'),(17,N'Barakat'),(18,N'Najjar'),(19,N'Zein');

DROP TABLE IF EXISTS #Veh;
SELECT n,
       ABS(CHECKSUM(NEWID()) % 26)       AS LetterRoll,   -- plate letter A..Z
       ABS(CHECKSUM(NEWID()) % 20)       AS FirstRoll,
       ABS(CHECKSUM(NEWID()) % 20)       AS LastRoll,
       ABS(CHECKSUM(NEWID()) % 100)      AS PhoneRoll,    -- < 10  -> no phone (10%)
       ABS(CHECKSUM(NEWID()) % 10000000) AS PhoneNum,
       ABS(CHECKSUM(NEWID()) % 100)      AS TypeRoll      -- 85% Car, 10% Motorcycle, 5% Van
INTO #Veh
FROM #Numbers;                                            -- 5000 rows

/* Sessions: 300 spaces x 400 slots = 120,000 rows. */
DROP TABLE IF EXISTS #Sess;
CREATE TABLE #Sess
(
    SessionID  INT          NULL,   -- numbered later, in time order
    SpaceID    INT          NOT NULL,
    Slot       INT          NOT NULL,
    VehicleID  INT          NOT NULL,
    StartMin   INT          NOT NULL,  -- 0..59   minutes after the slot start
    DurMin     INT          NOT NULL,  -- 5..600  minutes parked
    StatusRoll INT          NOT NULL,  -- 0 -> Cancelled (1%)
    MethodRoll INT          NOT NULL,  -- payment method
    EntryTime  DATETIME2(0) NULL,
    ExitTime   DATETIME2(0) NULL
);

INSERT #Sess (SpaceID, Slot, VehicleID, StartMin, DurMin, StatusRoll, MethodRoll)
SELECT sp.SpaceID,
       s.Slot,
       /* Vehicle formula from the plan. Inside one slot, SpaceID runs 1..300,
          so (Slot*300 + SpaceID) is 300 consecutive numbers. 7919 is prime and
          shares no factor with 5000, so multiplying by it and taking % 5000
          maps those 300 numbers to 300 DIFFERENT vehicles:
          no car is in two spaces during the same slot. */
       ((s.Slot * 300 + sp.SpaceID) * 7919) % 5000 + 1,
       ABS(CHECKSUM(NEWID()) % 60),
       5 + ABS(CHECKSUM(NEWID()) % 596),
       ABS(CHECKSUM(NEWID()) % 100),
       ABS(CHECKSUM(NEWID()) % 100)
FROM (SELECT n - 1 AS Slot FROM #Numbers WHERE n <= 400) AS s   -- slots 0..399
CROSS JOIN (SELECT n AS SpaceID FROM #Numbers WHERE n <= 300) AS sp;

/* Now that the random minutes are stored, compute the times from them. */
UPDATE #Sess
SET EntryTime = DATEADD(MINUTE, Slot * 720 + StartMin,          @Base),
    ExitTime  = DATEADD(MINUTE, Slot * 720 + StartMin + DurMin, @Base);

/* Give SessionIDs in chronological order, like a real system would. */
WITH Numbered AS
(
    SELECT SessionID, ROW_NUMBER() OVER (ORDER BY EntryTime, SpaceID) AS rn
    FROM #Sess
)
UPDATE Numbered SET SessionID = rn;

BEGIN TRY
    BEGIN TRANSACTION;

    /* ---- 3. Space types --------------------------------------------- */
    INSERT dbo.SpaceTypes (TypeName, HourlyRate)
    VALUES ('Standard', 2.00), ('Compact', 1.50), ('Accessible', 1.00), ('EV', 3.00);

    /* ---- 4. Spaces: F1-001 .. F3-100 --------------------------------
       IDENTITY_INSERT lets us choose the IDs ourselves (1..300), because the
       vehicle formula above relies on SpaceID being exactly 1..300.
       (An earlier failed run could have advanced the identity counter even
       though its rows were rolled back - identity values are never reused.)
       Per floor: 1-5 Accessible, 6-15 EV, 16-40 Compact, 41-100 Standard. */
    SET IDENTITY_INSERT dbo.ParkingSpaces ON;

    INSERT dbo.ParkingSpaces (SpaceID, SpaceCode, FloorNo, SpaceTypeID)
    SELECT (f.FloorNo - 1) * 100 + k.n,
           'F' + CAST(f.FloorNo AS VARCHAR(1)) + '-' + RIGHT('00' + CAST(k.n AS VARCHAR(3)), 3),
           f.FloorNo,
           st.SpaceTypeID
    FROM (VALUES (1), (2), (3)) AS f(FloorNo)
    CROSS JOIN (SELECT n FROM #Numbers WHERE n <= 100) AS k
    JOIN dbo.SpaceTypes AS st
      ON st.TypeName = CASE WHEN k.n <= 5  THEN 'Accessible'
                            WHEN k.n <= 15 THEN 'EV'
                            WHEN k.n <= 40 THEN 'Compact'
                            ELSE 'Standard' END          -- looked up by NAME, not by guessing IDs
    ORDER BY 1;

    SET IDENTITY_INSERT dbo.ParkingSpaces OFF;

    /* ---- 5. Vehicles 1..5000 ----------------------------------------
       Plate = letter + space + 6 digits, e.g. "B 100013".
       100000 + n*13 is different for every n, so plates are distinct
       whatever letter is drawn. Format passes CK_Vehicles_PlateChars. */
    SET IDENTITY_INSERT dbo.Vehicles ON;

    INSERT dbo.Vehicles (VehicleID, LicensePlate, OwnerName, Phone, VehicleType, RegisteredAt)
    SELECT v.n,
           CHAR(65 + v.LetterRoll) + ' ' + CAST(100000 + v.n * 13 AS VARCHAR(10)),
           fn.name + N' ' + ln.name,
           CASE WHEN v.PhoneRoll < 10 THEN NULL
                ELSE '+961 7' + RIGHT('0000000' + CAST(v.PhoneNum AS VARCHAR(7)), 7) END,
           CASE WHEN v.TypeRoll < 85 THEN 'Car'
                WHEN v.TypeRoll < 95 THEN 'Motorcycle'
                ELSE 'Van' END,
           DATEADD(DAY, -1, @Base)                        -- registered before their first visit
    FROM #Veh AS v
    JOIN @FirstNames AS fn ON fn.id = v.FirstRoll
    JOIN @LastNames  AS ln ON ln.id = v.LastRoll
    ORDER BY v.n;

    SET IDENTITY_INSERT dbo.Vehicles OFF;

    /* ---- 6. Historical sessions (120,000) ---------------------------
       ~1% Cancelled (Fee 0, no payment), the rest Completed with the fee
       computed by the same function the procedures will use. */
    SET IDENTITY_INSERT dbo.ParkingSessions ON;

    INSERT dbo.ParkingSessions (SessionID, VehicleID, SpaceID, EntryTime, ExitTime, Status, Fee)
    SELECT s.SessionID, s.VehicleID, s.SpaceID, s.EntryTime, s.ExitTime,
           CASE WHEN s.StatusRoll = 0 THEN 'Cancelled' ELSE 'Completed' END,
           CASE WHEN s.StatusRoll = 0 THEN 0.00
                ELSE dbo.fn_CalculateFee(s.EntryTime, s.ExitTime, st.HourlyRate) END
    FROM #Sess AS s
    JOIN dbo.ParkingSpaces AS sp ON sp.SpaceID     = s.SpaceID
    JOIN dbo.SpaceTypes    AS st ON st.SpaceTypeID = sp.SpaceTypeID
    ORDER BY s.SessionID;

    SET IDENTITY_INSERT dbo.ParkingSessions OFF;

    /* ---- 7. Payments: one per Completed session with Fee > 0 --------
       Sessions of 10 minutes or less are free (Fee 0) and get no payment.
       40% Card, 35% Cash, 25% Mobile. Paid at the moment of exit. */
    INSERT dbo.Payments (SessionID, Amount, Method, PaidAt)
    SELECT ps.SessionID,
           ps.Fee,                                         -- amount always equals the fee
           CASE WHEN s.MethodRoll < 40 THEN 'Card'
                WHEN s.MethodRoll < 75 THEN 'Cash'
                ELSE 'Mobile' END,
           ps.ExitTime
    FROM dbo.ParkingSessions AS ps
    JOIN #Sess AS s ON s.SessionID = ps.SessionID
    WHERE ps.Status = 'Completed' AND ps.Fee > 0
    ORDER BY ps.ExitTime, ps.SessionID;

    /* ---- 8. Two spaces out of service -------------------------------
       Not required by the plan, but it lets script 08 prove that the
       entry procedure never assigns an out-of-service space. */
    UPDATE dbo.ParkingSpaces SET IsActive = 0 WHERE SpaceCode IN ('F3-099', 'F3-100');

    /* ---- 9. About 40 cars parked right now --------------------------
       40 random in-service spaces paired with 40 random vehicles.
       Each pair entered 5..300 minutes ago, but never before today 00:00
       (the history ends before today, so no overlap is possible). */
    DROP TABLE IF EXISTS #ActSpace;
    DROP TABLE IF EXISTS #ActVeh;

    SELECT TOP (40) SpaceID
    INTO #ActSpace
    FROM dbo.ParkingSpaces
    WHERE IsActive = 1
    ORDER BY NEWID();                 -- ORDER BY NEWID() = random order

    SELECT TOP (40) VehicleID
    INTO #ActVeh
    FROM dbo.Vehicles
    ORDER BY NEWID();

    DROP TABLE IF EXISTS #Act;
    SELECT a.SpaceID, v.VehicleID, 5 + ABS(CHECKSUM(NEWID()) % 296) AS MinutesAgo
    INTO #Act
    FROM (SELECT SpaceID,   ROW_NUMBER() OVER (ORDER BY SpaceID)   AS rn FROM #ActSpace) AS a
    JOIN (SELECT VehicleID, ROW_NUMBER() OVER (ORDER BY VehicleID) AS rn FROM #ActVeh)   AS v
      ON v.rn = a.rn;

    INSERT dbo.ParkingSessions (VehicleID, SpaceID, EntryTime, ExitTime, Status, Fee)
    SELECT VehicleID, SpaceID,
           CASE WHEN DATEADD(MINUTE, -MinutesAgo, @Now) < @Today THEN @Today
                ELSE DATEADD(MINUTE, -MinutesAgo, @Now) END,
           NULL, 'Active', NULL
    FROM #Act;

    /* The documented redundancy: mark exactly those spaces as occupied. */
    UPDATE dbo.ParkingSpaces
    SET IsOccupied = 1
    WHERE SpaceID IN (SELECT SpaceID FROM dbo.ParkingSessions WHERE Status = 'Active');

    COMMIT TRANSACTION;
    PRINT 'Seed data committed.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    /* IDENTITY_INSERT is a session setting: switch it off so the next run
       does not fail with "IDENTITY_INSERT is already ON for table ...". */
    SET IDENTITY_INSERT dbo.ParkingSpaces   OFF;
    SET IDENTITY_INSERT dbo.Vehicles        OFF;
    SET IDENTITY_INSERT dbo.ParkingSessions OFF;
    THROW;   -- re-raise the original error so you see what went wrong
END CATCH;
GO

/* =====================================================================
   10. Row counts
   ===================================================================== */
SELECT 'SpaceTypes' AS TableName, COUNT(*) AS RowCnt, 4 AS Expected,
       CASE WHEN COUNT(*) = 4 THEN 'PASS' ELSE 'FAIL' END AS Result FROM dbo.SpaceTypes
UNION ALL
SELECT 'ParkingSpaces', COUNT(*), 300,
       CASE WHEN COUNT(*) = 300 THEN 'PASS' ELSE 'FAIL' END FROM dbo.ParkingSpaces
UNION ALL
SELECT 'Vehicles', COUNT(*), 5000,
       CASE WHEN COUNT(*) = 5000 THEN 'PASS' ELSE 'FAIL' END FROM dbo.Vehicles
UNION ALL
SELECT 'ParkingSessions (> 100,000)', COUNT(*), 120040,
       CASE WHEN COUNT(*) > 100000 THEN 'PASS' ELSE 'FAIL' END FROM dbo.ParkingSessions
UNION ALL
SELECT '  of which Active (about 40)', COUNT(*), 40,
       CASE WHEN COUNT(*) BETWEEN 1 AND 300 THEN 'PASS' ELSE 'FAIL' END
FROM dbo.ParkingSessions WHERE Status = 'Active'
UNION ALL
SELECT '  of which Cancelled (about 1%)', COUNT(*), 1200,
       CASE WHEN COUNT(*) BETWEEN 600 AND 2400 THEN 'PASS' ELSE 'FAIL' END
FROM dbo.ParkingSessions WHERE Status = 'Cancelled'
UNION ALL
SELECT 'Payments', COUNT(*), NULL,
       CASE WHEN COUNT(*) > 100000 THEN 'PASS' ELSE 'FAIL' END FROM dbo.Payments
UNION ALL
SELECT 'AuditLog (must be empty)', COUNT(*), 0,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END FROM dbo.AuditLog;
GO

/* =====================================================================
   11. Consistency checks - every one must find 0 rows.
   (The first three are repeated in 08_tests.sql.)
   ===================================================================== */
SELECT CheckName, BadRows, CASE WHEN BadRows = 0 THEN 'PASS' ELSE 'FAIL' END AS Result
FROM
(
    SELECT 'Spaces marked occupied without an active session' AS CheckName,
           (SELECT COUNT(*) FROM dbo.ParkingSpaces AS sp
             WHERE sp.IsOccupied = 1
               AND NOT EXISTS (SELECT 1 FROM dbo.ParkingSessions AS ps
                                WHERE ps.SpaceID = sp.SpaceID AND ps.Status = 'Active')) AS BadRows
    UNION ALL
    SELECT 'Active sessions whose space is not marked occupied',
           (SELECT COUNT(*) FROM dbo.ParkingSessions AS ps
              JOIN dbo.ParkingSpaces AS sp ON sp.SpaceID = ps.SpaceID
             WHERE ps.Status = 'Active' AND sp.IsOccupied = 0)
    UNION ALL
    SELECT 'Completed sessions with Fee > 0 and no payment',
           (SELECT COUNT(*) FROM dbo.ParkingSessions AS ps
             WHERE ps.Status = 'Completed' AND ps.Fee > 0
               AND NOT EXISTS (SELECT 1 FROM dbo.Payments AS p WHERE p.SessionID = ps.SessionID))
    UNION ALL
    SELECT 'Payments whose amount differs from the session fee',
           (SELECT COUNT(*) FROM dbo.Payments AS p
              JOIN dbo.ParkingSessions AS ps ON ps.SessionID = p.SessionID
             WHERE p.Amount <> ps.Fee)
    UNION ALL
    /* LAG looks at the previous session of the SAME space (by time).
       If that one ended after this one started, two cars shared the space. */
    SELECT 'Space used by two cars at the same time',
           (SELECT COUNT(*) FROM
               (SELECT EntryTime,
                       LAG(ExitTime) OVER (PARTITION BY SpaceID ORDER BY EntryTime) AS PrevExit
                  FROM dbo.ParkingSessions) AS x
             WHERE x.PrevExit > x.EntryTime)
    UNION ALL
    SELECT 'Car in two places at the same time',
           (SELECT COUNT(*) FROM
               (SELECT EntryTime,
                       LAG(ExitTime) OVER (PARTITION BY VehicleID ORDER BY EntryTime) AS PrevExit
                  FROM dbo.ParkingSessions) AS x
             WHERE x.PrevExit > x.EntryTime)
    UNION ALL
    SELECT 'Active session on an out-of-service space',
           (SELECT COUNT(*) FROM dbo.ParkingSessions AS ps
              JOIN dbo.ParkingSpaces AS sp ON sp.SpaceID = ps.SpaceID
             WHERE ps.Status = 'Active' AND sp.IsActive = 0)
    UNION ALL
    SELECT 'Historical sessions ending today or later',
           (SELECT COUNT(*) FROM dbo.ParkingSessions
             WHERE Status <> 'Active' AND ExitTime >= CAST(CAST(SYSDATETIME() AS DATE) AS DATETIME2(0)))
) AS c;
GO

/* Switch execution back on (in case the guard at the top switched it off). */
SET NOEXEC OFF;
GO
