-- =====================================================================
-- REBUILD_ALL.sql
-- ---------------------------------------------------------------------
-- ONE file that rebuilds the whole database from scratch:
--     01 tables  ->  02 data  ->  03 function + views
--     ->  04 procedures  ->  05 triggers
-- HOW: open this file in SSMS and press F5 ONE time. Wait ~20 seconds.
-- RESULT: scroll to the VERY LAST grid. It must say  READY  on every line.
-- (The grids above it are the self-checks of each part; they should all
--  say PASS, but the last grid is the one that matters.)
-- It deletes everything that was in the tables and starts clean.
-- =====================================================================



-- #####################################################################
-- #####  PART: 01_schema.sql
-- #####################################################################
/* =====================================================================
   01_schema.sql
   ---------------------------------------------------------------------
   WHAT : Creates the six tables of ParkingDB with all their keys,
          CHECK / UNIQUE / DEFAULT constraints, and the two filtered
          unique indexes that make double booking impossible:
              SpaceTypes, Vehicles, ParkingSpaces,
              ParkingSessions, Payments, AuditLog
   WHY  : "The database protects itself." Every rule that matters is a
          constraint here, so even a buggy procedure or a person typing
          SQL by hand cannot store invalid data.
   CHECK: The verification block at the end prints PASS/FAIL for every
          expected object (6 PK, 4 FK, 4 UQ, 13 CK, 9 DF, 2 UX).
          The script can be run twice in a row without error.

   WARNING: re-running this script DROPS the tables, i.e. deletes all
            data. Afterwards run 02 (data), 03, 04, 05 ... again.

   NOTE ON INDEXES: apart from primary keys, UNIQUE constraints and the
   two filtered unique indexes (which are integrity rules), NO index is
   created here. The performance indexes come in script 06, so the
   "before" measurements in that script are honest.
   ===================================================================== */

USE ParkingDB;
GO

/* Filtered indexes only work when these options are ON for the session
   that creates them AND for every session that later modifies the table.
   SSMS and Microsoft.Data.SqlClient both use ON by default; we set them
   explicitly so the script never depends on someone's settings. */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ---------------------------------------------------------------------
   1. Drop old tables (children before parents, because a parent that is
      still referenced by a foreign key cannot be dropped).
      Dropping a table also drops its triggers and indexes.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS dbo.Payments;
DROP TABLE IF EXISTS dbo.ParkingSessions;
DROP TABLE IF EXISTS dbo.ParkingSpaces;
DROP TABLE IF EXISTS dbo.Vehicles;
DROP TABLE IF EXISTS dbo.SpaceTypes;
DROP TABLE IF EXISTS dbo.AuditLog;
GO

/* ---------------------------------------------------------------------
   2.1 SpaceTypes - lookup table: the kind of space sets the hourly rate.
   --------------------------------------------------------------------- */
CREATE TABLE dbo.SpaceTypes
(
    SpaceTypeID TINYINT IDENTITY(1,1) NOT NULL,   -- TINYINT (0-255): we will only ever have a handful of types
    TypeName    VARCHAR(20)           NOT NULL,
    HourlyRate  DECIMAL(6,2)          NOT NULL,   -- DECIMAL, never FLOAT, for money: exact, no rounding surprises

    CONSTRAINT PK_SpaceTypes          PRIMARY KEY CLUSTERED (SpaceTypeID),
    CONSTRAINT UQ_SpaceTypes_TypeName UNIQUE (TypeName),
    CONSTRAINT CK_SpaceTypes_HourlyRate CHECK (HourlyRate > 0)
);
GO

/* ---------------------------------------------------------------------
   2.2 Vehicles - registered cars, motorcycles and vans.
   --------------------------------------------------------------------- */
CREATE TABLE dbo.Vehicles
(
    VehicleID    INT IDENTITY(1,1) NOT NULL,
    LicensePlate VARCHAR(15)       NOT NULL,       -- stored upper-case and trimmed by usp_RegisterVehicle
    OwnerName    NVARCHAR(100)     NOT NULL,       -- NVARCHAR: owner names may contain Arabic/accented letters
    Phone        VARCHAR(20)       NULL,
    VehicleType  VARCHAR(20)       NOT NULL,
    RegisteredAt DATETIME2(0)      NOT NULL CONSTRAINT DF_Vehicles_RegisteredAt DEFAULT SYSDATETIME(),
    IsActive     BIT               NOT NULL CONSTRAINT DF_Vehicles_IsActive     DEFAULT 1,

    CONSTRAINT PK_Vehicles              PRIMARY KEY CLUSTERED (VehicleID),
    CONSTRAINT UQ_Vehicles_LicensePlate UNIQUE (LicensePlate),

    /* Only A-Z, 0-9, space and hyphen.
       LIKE '%[^...]%' means "contains at least one character NOT in the list",
       so NOT LIKE means "every character is allowed".
       COLLATE Latin1_General_BIN: in the default case-insensitive collation
       the range [A-Z] would also accept lower-case and accented letters
       (a, é ...). A binary collation compares raw character codes, so
       [A-Z] really means only the 26 capital letters.
       The hyphen is placed last inside [ ] so it is a literal '-', not a range. */
    CONSTRAINT CK_Vehicles_PlateChars
        CHECK (LicensePlate COLLATE Latin1_General_BIN NOT LIKE '%[^A-Z0-9 -]%'),

    /* LEN ignores trailing spaces, so '  ' or 'A ' are rejected too. */
    CONSTRAINT CK_Vehicles_PlateLength CHECK (LEN(LicensePlate) >= 2),

    CONSTRAINT CK_Vehicles_VehicleType CHECK (VehicleType IN ('Car', 'Motorcycle', 'Van')),

    /* Phone is optional (NULL allowed). If given, it must look like a
       phone number: only digits, spaces, hyphens and ONE leading '+',
       with 7 to 15 digits in total (15 = the international maximum).
       'bozik' or '12' are refused.
       CHARINDEX('+', Phone, 2) = 0 means "no + after the first character".
       The digit count is the length after removing spaces, hyphens and +. */
    CONSTRAINT CK_Vehicles_Phone
        CHECK (   Phone IS NULL
               OR (    Phone COLLATE Latin1_General_BIN NOT LIKE '%[^0-9 +-]%'
                   AND CHARINDEX('+', Phone, 2) = 0
                   AND LEN(REPLACE(REPLACE(REPLACE(Phone, ' ', ''), '-', ''), '+', '')) BETWEEN 7 AND 15)),

    /* Owner name: at least 2 real characters, and no digits or symbols.
       We list what is FORBIDDEN instead of what is allowed, because names
       may use any alphabet (Arabic, French accents ...). Spaces, hyphens,
       apostrophes, dots and parentheses stay allowed (e.g. Jean-Paul,
       Jr.). Inside [ ] the characters % and _ are literal, not wildcards. */
    CONSTRAINT CK_Vehicles_OwnerName
        CHECK (    LEN(LTRIM(RTRIM(OwnerName))) >= 2
               AND OwnerName NOT LIKE N'%[0-9!@#$%^&*_+=<>?/\|{}~;:"]%')
);
GO

/* ---------------------------------------------------------------------
   2.3 ParkingSpaces - the 300 physical spaces.
   IsOccupied is a deliberate, documented redundancy (the proposal asks
   the table to store availability). It is changed ONLY inside
   usp_VehicleEntry / usp_VehicleExit / usp_CancelSession, in the same
   transaction as the session row. Script 08 proves it never disagrees
   with the ParkingSessions table.
   --------------------------------------------------------------------- */
CREATE TABLE dbo.ParkingSpaces
(
    SpaceID     INT IDENTITY(1,1) NOT NULL,
    SpaceCode   VARCHAR(10)       NOT NULL,        -- e.g. F1-042
    FloorNo     TINYINT           NOT NULL,
    SpaceTypeID TINYINT           NOT NULL,
    IsOccupied  BIT               NOT NULL CONSTRAINT DF_ParkingSpaces_IsOccupied DEFAULT 0,
    IsActive    BIT               NOT NULL CONSTRAINT DF_ParkingSpaces_IsActive   DEFAULT 1,  -- 0 = out of service

    CONSTRAINT PK_ParkingSpaces           PRIMARY KEY CLUSTERED (SpaceID),
    CONSTRAINT UQ_ParkingSpaces_SpaceCode UNIQUE (SpaceCode),

    /* No ON DELETE CASCADE anywhere: history must never disappear because
       a parent row was deleted. NO ACTION (the default) refuses the delete. */
    CONSTRAINT FK_ParkingSpaces_SpaceTypes
        FOREIGN KEY (SpaceTypeID) REFERENCES dbo.SpaceTypes (SpaceTypeID)
);
GO

/* ---------------------------------------------------------------------
   2.4 ParkingSessions - one row per visit. This is the large table
   (120,000+ rows after script 02).
   --------------------------------------------------------------------- */
CREATE TABLE dbo.ParkingSessions
(
    SessionID INT IDENTITY(1,1) NOT NULL,
    VehicleID INT               NOT NULL,
    SpaceID   INT               NOT NULL,
    EntryTime DATETIME2(0)      NOT NULL CONSTRAINT DF_ParkingSessions_EntryTime DEFAULT SYSDATETIME(),
    ExitTime  DATETIME2(0)      NULL,              -- NULL while the car is still inside
    Status    VARCHAR(10)       NOT NULL CONSTRAINT DF_ParkingSessions_Status    DEFAULT 'Active',
    Fee       DECIMAL(8,2)      NULL,              -- NULL while Active; set at exit

    CONSTRAINT PK_ParkingSessions PRIMARY KEY CLUSTERED (SessionID),

    CONSTRAINT FK_ParkingSessions_Vehicles
        FOREIGN KEY (VehicleID) REFERENCES dbo.Vehicles (VehicleID),
    CONSTRAINT FK_ParkingSessions_ParkingSpaces
        FOREIGN KEY (SpaceID)   REFERENCES dbo.ParkingSpaces (SpaceID),

    CONSTRAINT CK_ParkingSessions_Status
        CHECK (Status IN ('Active', 'Completed', 'Cancelled')),
    CONSTRAINT CK_ParkingSessions_Fee
        CHECK (Fee >= 0),                          -- a CHECK on NULL is "unknown" = passes, so NULL Fee is allowed

    /* Table-level rules (they compare several columns of the same row). */
    CONSTRAINT CK_Sessions_ExitAfterEntry
        CHECK (ExitTime IS NULL OR ExitTime >= EntryTime),

    /* An Active session has no exit time and no fee yet;
       a finished (Completed/Cancelled) session must have an exit time. */
    CONSTRAINT CK_Sessions_StatusMatchesExit
        CHECK (   (Status =  'Active' AND ExitTime IS NULL AND Fee IS NULL)
               OR (Status <> 'Active' AND ExitTime IS NOT NULL))
);
GO

/* The two NO-DOUBLE-BOOKING rules.
   A normal UNIQUE (SpaceID) would allow each space to be used only once
   in its whole life. A FILTERED unique index only covers the rows that
   match the WHERE clause, so it says:
       "among ACTIVE sessions, each SpaceID appears at most once".
   Completed/Cancelled history rows are not in the index and can repeat.
   These are integrity rules (Layer 2 of the concurrency design), which is
   why they live here and not in the performance script 06. */
CREATE UNIQUE NONCLUSTERED INDEX UX_Sessions_OneActivePerSpace
    ON dbo.ParkingSessions (SpaceID)
    WHERE Status = 'Active';

CREATE UNIQUE NONCLUSTERED INDEX UX_Sessions_OneActivePerVehicle
    ON dbo.ParkingSessions (VehicleID)
    WHERE Status = 'Active';
GO

/* ---------------------------------------------------------------------
   2.5 Payments - at most one payment per session (1 - 0..1).
   --------------------------------------------------------------------- */
CREATE TABLE dbo.Payments
(
    PaymentID INT IDENTITY(1,1) NOT NULL,
    SessionID INT               NOT NULL,
    Amount    DECIMAL(8,2)      NOT NULL,          -- copied from the session's Fee by usp_RecordPayment
    Method    VARCHAR(10)       NOT NULL,
    PaidAt    DATETIME2(0)      NOT NULL CONSTRAINT DF_Payments_PaidAt DEFAULT SYSDATETIME(),

    CONSTRAINT PK_Payments PRIMARY KEY CLUSTERED (PaymentID),

    /* FK + UNIQUE on the same column = "zero or one payment per session". */
    CONSTRAINT FK_Payments_ParkingSessions
        FOREIGN KEY (SessionID) REFERENCES dbo.ParkingSessions (SessionID),
    CONSTRAINT UQ_Payments_SessionID UNIQUE (SessionID),

    CONSTRAINT CK_Payments_Amount CHECK (Amount >= 0),
    CONSTRAINT CK_Payments_Method CHECK (Method IN ('Cash', 'Card', 'Mobile'))
);
GO

/* ---------------------------------------------------------------------
   2.6 AuditLog - history of changes, written ONLY by triggers (script 05).
   No foreign keys on purpose: an audit row must survive even if the row
   it describes is later deleted, and it may describe rows of any table.
   --------------------------------------------------------------------- */
CREATE TABLE dbo.AuditLog
(
    AuditID    BIGINT IDENTITY(1,1) NOT NULL,      -- BIGINT: an audit table grows forever
    TableName  SYSNAME              NOT NULL,      -- SYSNAME = NVARCHAR(128), the type SQL Server uses for object names
    ActionType CHAR(1)              NOT NULL,      -- I = insert, U = update, D = delete
    KeyValue   INT                  NOT NULL,      -- primary key of the changed row
    OldValues  NVARCHAR(MAX)        NULL,          -- JSON of the row before (NULL for inserts)
    NewValues  NVARCHAR(MAX)        NULL,          -- JSON of the row after  (NULL for deletes)

    /* ORIGINAL_LOGIN() returns the login that really connected, even when
       code runs under EXECUTE AS. So the log shows the true person/app. */
    ChangedBy  SYSNAME              NOT NULL CONSTRAINT DF_AuditLog_ChangedBy DEFAULT ORIGINAL_LOGIN(),
    ChangedAt  DATETIME2(3)         NOT NULL CONSTRAINT DF_AuditLog_ChangedAt DEFAULT SYSDATETIME(),

    CONSTRAINT PK_AuditLog PRIMARY KEY CLUSTERED (AuditID),
    CONSTRAINT CK_AuditLog_ActionType CHECK (ActionType IN ('I', 'U', 'D'))
);
GO

/* =====================================================================
   VERIFICATION - every line should say PASS.
   ===================================================================== */
SET NOCOUNT ON;

DECLARE @Expected TABLE (Kind VARCHAR(60), ExpectedCount INT, ActualCount INT);

INSERT @Expected (Kind, ExpectedCount, ActualCount)
SELECT 'Tables',               6,  (SELECT COUNT(*) FROM sys.tables WHERE schema_id = SCHEMA_ID('dbo')
                                      AND name IN ('SpaceTypes','Vehicles','ParkingSpaces',
                                                   'ParkingSessions','Payments','AuditLog'))
UNION ALL
SELECT 'Primary keys',         6,  (SELECT COUNT(*) FROM sys.key_constraints   WHERE type = 'PK' AND schema_id = SCHEMA_ID('dbo'))
UNION ALL
SELECT 'Foreign keys',         4,  (SELECT COUNT(*) FROM sys.foreign_keys      WHERE schema_id = SCHEMA_ID('dbo'))
UNION ALL
SELECT 'Unique constraints',   4,  (SELECT COUNT(*) FROM sys.key_constraints   WHERE type = 'UQ' AND schema_id = SCHEMA_ID('dbo'))
UNION ALL
SELECT 'Check constraints',    13, (SELECT COUNT(*) FROM sys.check_constraints WHERE schema_id = SCHEMA_ID('dbo'))
UNION ALL
SELECT 'Default constraints',  9,  (SELECT COUNT(*) FROM sys.default_constraints WHERE schema_id = SCHEMA_ID('dbo'))
UNION ALL
SELECT 'Filtered unique idx',  2,  (SELECT COUNT(*) FROM sys.indexes
                                     WHERE object_id = OBJECT_ID('dbo.ParkingSessions')
                                       AND is_unique = 1 AND has_filter = 1
                                       AND name IN ('UX_Sessions_OneActivePerSpace','UX_Sessions_OneActivePerVehicle'))
UNION ALL
/* Proves no performance index exists yet: on ParkingSessions only the PK
   and the two UX_ indexes may exist before script 06. */
SELECT 'Sessions indexes (no perf idx yet)', 3,
                                   (SELECT COUNT(*) FROM sys.indexes
                                     WHERE object_id = OBJECT_ID('dbo.ParkingSessions') AND index_id > 0)
UNION ALL
/* No foreign key may cascade: history must never be deleted by a cascade. */
SELECT 'FKs with cascade',     0,  (SELECT COUNT(*) FROM sys.foreign_keys
                                     WHERE schema_id = SCHEMA_ID('dbo')
                                       AND (delete_referential_action <> 0 OR update_referential_action <> 0));

SELECT Kind,
       ExpectedCount,
       ActualCount,
       CASE WHEN ExpectedCount = ActualCount THEN 'PASS' ELSE 'FAIL' END AS Result
FROM @Expected;

/* Full list of constraints, for the report / screenshot. */
SELECT OBJECT_NAME(parent_object_id) AS TableName, name AS ConstraintName, type_desc
FROM sys.objects
WHERE type IN ('PK','F','UQ','C','D') AND schema_id = SCHEMA_ID('dbo')
ORDER BY TableName, type_desc, ConstraintName;
GO


-- #####################################################################
-- #####  PART: 02_seed_data.sql
-- #####################################################################
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


-- #####################################################################
-- #####  PART: 03_functions_views.sql
-- #####################################################################
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


-- #####################################################################
-- #####  PART: 04_procedures.sql
-- #####################################################################
/* =====================================================================
   04_procedures.sql
   ---------------------------------------------------------------------
   WHAT : All stored procedures the application calls:
            writing : usp_RegisterVehicle, usp_VehicleEntry,
                      usp_VehicleExit, usp_RecordPayment, usp_CancelSession
            reading : usp_SearchSessions, usp_GetVehicleHistory,
                      usp_GetDashboard
          (usp_VehicleEntry_Unsafe lives in 09_concurrency_demo.sql,
           because it exists only for that demonstration.)
   WHY  : "All business logic lives in the database." The app never
          sends table SQL; it only calls these procedures.
   CHECK: Run the HAND TEST at the bottom: register -> entry -> exit ->
          payment -> history -> dashboard. Every result grid is labelled;
          the last grid says PASS. It runs inside a transaction that is
          ROLLED BACK, so it changes nothing and can be run again.

   ERRORS raised (THROW, the app shows the message text):
     50001 vehicle not registered / inactive    50005 session not completed / cancelled
     50002 vehicle already parked               50006 session already has a payment
     50003 no free space                        50007 plate already registered
     50004 no active session                    50008 invalid input (message says which)

   SKELETON of every writing procedure:
     SET NOCOUNT ON   - no "(1 row affected)" messages; the app does not
                        need them and they cost a network round trip.
     SET XACT_ABORT ON - if ANY error happens, SQL Server rolls back the
                        whole transaction. Without it, some errors (e.g.
                        a constraint violation) only cancel the single
                        statement and leave the transaction half-done.
     BEGIN TRY / BEGIN TRAN ... COMMIT / CATCH: ROLLBACK, THROW
                      - all or nothing; THROW re-raises the original error
                        (number + message) to the caller.
   Cheap input checks run BEFORE the transaction starts: there is no
   point opening a transaction for a call that is invalid anyway.
   ===================================================================== */

USE ParkingDB;
GO
/* IMPORTANT: a procedure REMEMBERS the ANSI_NULLS / QUOTED_IDENTIFIER
   settings it was created with. Tables with filtered indexes
   (ParkingSessions) can only be modified when both are ON, so these
   lines must stay at the top of this file. */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* =====================================================================
   usp_RegisterVehicle
   Normalises the plate (trim + upper case) and inserts the vehicle.
   The plate's character rule is enforced by CK_Vehicles_PlateChars on
   the TABLE; this procedure only translates that error into 50008.
   Duplicate plates are caught by UQ_Vehicles_LicensePlate -> 50007.
   (We do not "check first, then insert": two users registering the same
   plate at the same moment could both pass the check. The unique
   constraint cannot be fooled by timing.)
   ===================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_RegisterVehicle
    @LicensePlate NVARCHAR(50),        -- wider than the column on purpose: a too-long value is
                                       -- REJECTED with a message, never silently cut to 15 chars
    @OwnerName    NVARCHAR(100),
    @Phone        VARCHAR(20)  = NULL,
    @VehicleType  VARCHAR(20),
    @VehicleID    INT          OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Plate VARCHAR(50), @Type VARCHAR(20), @Msg NVARCHAR(2048);
    SET @VehicleID = NULL;

    /* ---- input checks ---- */
    SET @Plate = UPPER(LTRIM(RTRIM(@LicensePlate)));
    IF @Plate IS NULL OR @Plate = ''
        THROW 50008, N'Invalid input: license plate is required.', 1;
    IF LEN(@Plate) > 15
        THROW 50008, N'Invalid input: license plate can be at most 15 characters.', 1;

    IF NULLIF(LTRIM(RTRIM(@OwnerName)), N'') IS NULL
        THROW 50008, N'Invalid input: owner name is required.', 1;

    /* Turn 'car' / ' CAR ' into the canonical 'Car' (the default collation
       is case-insensitive, so the comparison matches any casing). */
    SELECT @Type = t.TypeName
    FROM (VALUES ('Car'), ('Motorcycle'), ('Van')) AS t(TypeName)
    WHERE t.TypeName = LTRIM(RTRIM(@VehicleType));
    IF @Type IS NULL
        THROW 50008, N'Invalid input: vehicle type must be Car, Motorcycle or Van.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT dbo.Vehicles (LicensePlate, OwnerName, Phone, VehicleType)
        VALUES (@Plate, LTRIM(RTRIM(@OwnerName)), NULLIF(LTRIM(RTRIM(@Phone)), ''), @Type);

        SET @VehicleID = SCOPE_IDENTITY();   -- the ID created by THIS insert (not by a trigger)

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        /* 2627 = unique constraint violated, 2601 = unique index violated */
        IF ERROR_NUMBER() IN (2601, 2627)
        BEGIN
            SET @Msg = CONCAT(N'License plate ', @Plate, N' is already registered.');
            THROW 50007, @Msg, 1;
        END;

        /* 547 = a CHECK (or FK) constraint refused the row */
        IF ERROR_NUMBER() = 547 AND ERROR_MESSAGE() LIKE N'%CK_Vehicles_Phone%'
            THROW 50008, N'Invalid input: phone may contain only digits, spaces, hyphens and one leading +, with 7 to 15 digits.', 1;

        IF ERROR_NUMBER() = 547 AND ERROR_MESSAGE() LIKE N'%CK_Vehicles_OwnerName%'
            THROW 50008, N'Invalid input: owner name needs at least 2 characters and may not contain digits or symbols.', 1;

        IF ERROR_NUMBER() = 547 AND ERROR_MESSAGE() LIKE N'%CK_Vehicles_Plate%'
            THROW 50008, N'Invalid input: license plate may contain only letters A-Z, digits 0-9, spaces and hyphens, and needs at least 2 characters.', 1;

        THROW;   -- anything else: re-raise unchanged
    END CATCH;
END;
GO

/* =====================================================================
   usp_VehicleEntry   (plan section 5.1)
   1. find the vehicle (missing / inactive -> 50001)
   2. refuse if it is already parked (-> 50002)
   3. choose AND lock a free space in ONE statement (none -> 50003)
   4. mark the space occupied, insert the Active session, commit.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_VehicleEntry
    @LicensePlate      NVARCHAR(50),
    @SpaceTypeID       TINYINT     = NULL,   -- NULL = any type
    @DebugDelaySeconds INT         = 0,      -- ONLY for the concurrency demo (script 09)
    @SessionID         INT         OUTPUT,
    @SpaceCode         VARCHAR(10) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Plate VARCHAR(50), @VehicleID INT, @SpaceID INT,
            @Delay CHAR(8), @Msg NVARCHAR(2048);
    SET @SessionID = NULL;
    SET @SpaceCode = NULL;

    /* ---- input checks ---- */
    SET @Plate = UPPER(LTRIM(RTRIM(@LicensePlate)));
    IF @Plate IS NULL OR @Plate = ''
        THROW 50008, N'Invalid input: license plate is required.', 1;

    IF @DebugDelaySeconds IS NULL OR @DebugDelaySeconds NOT BETWEEN 0 AND 30
        THROW 50008, N'Invalid input: debug delay must be between 0 and 30 seconds.', 1;

    IF @SpaceTypeID IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM dbo.SpaceTypes WHERE SpaceTypeID = @SpaceTypeID)
        THROW 50008, N'Invalid input: unknown space type.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        /* Step 1 - the vehicle.
           UPDLOCK on the VEHICLE row: if the same car is entered twice at the
           same moment (double click, two gates), the second call waits here
           until the first commits, then sees the active session in step 2
           and gets a clean 50002 instead of a race. */
        SELECT @VehicleID = VehicleID
        FROM dbo.Vehicles WITH (UPDLOCK, ROWLOCK)
        WHERE LicensePlate = @Plate
          AND IsActive = 1;

        IF @VehicleID IS NULL
        BEGIN
            SET @Msg = CONCAT(N'Vehicle ', @Plate, N' is not registered or is inactive.');
            THROW 50001, @Msg, 1;
        END;

        /* Step 2 - already parked? */
        IF EXISTS (SELECT 1 FROM dbo.ParkingSessions
                   WHERE VehicleID = @VehicleID AND Status = 'Active')
        BEGIN
            SET @Msg = CONCAT(N'Vehicle ', @Plate, N' is already parked.');
            THROW 50002, @Msg, 1;
        END;

        /* Step 3 - choose and lock a space in ONE statement.
           UPDLOCK : this transaction now owns the row until COMMIT; nobody
                     else can take it (an update lock is compatible with
                     plain readers, but not with another UPDLOCK / update).
           READPAST: a second car does not WAIT for a locked row, it SKIPS
                     it and immediately gets the NEXT free space.
           ROWLOCK : lock just this one row, not a whole page of spaces.
           Choosing and locking in the same statement is the key point:
           with a plain SELECT followed by an UPDATE, two transactions can
           both read "F1-001 is free" between the two statements. */
        SELECT TOP (1)
               @SpaceID   = SpaceID,
               @SpaceCode = SpaceCode
        FROM dbo.ParkingSpaces WITH (UPDLOCK, READPAST, ROWLOCK)
        WHERE IsOccupied = 0
          AND IsActive   = 1
          AND (@SpaceTypeID IS NULL OR SpaceTypeID = @SpaceTypeID)
        ORDER BY SpaceID;                    -- lowest-numbered free space

        IF @SpaceID IS NULL
            THROW 50003, N'No free space available.', 1;

        /* Demo only: hold the lock for a while so a second SSMS window can
           try at the same time. WAITFOR DELAY needs 'hh:mm:ss' text;
           DATEADD(SECOND, n, 0) + style 108 builds exactly that. */
        IF @DebugDelaySeconds > 0
        BEGIN
            SET @Delay = CONVERT(CHAR(8), DATEADD(SECOND, @DebugDelaySeconds, 0), 108);
            WAITFOR DELAY @Delay;
        END;

        /* Step 4 - occupy the space and open the session (same transaction,
           so the IsOccupied flag and the session can never disagree). */
        UPDATE dbo.ParkingSpaces
        SET IsOccupied = 1
        WHERE SpaceID = @SpaceID;

        INSERT dbo.ParkingSessions (VehicleID, SpaceID, Status)   -- EntryTime: DEFAULT SYSDATETIME()
        VALUES (@VehicleID, @SpaceID, 'Active');

        SET @SessionID = SCOPE_IDENTITY();

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @SessionID = NULL;
        SET @SpaceCode = NULL;

        /* Layer 2 (plan 5.2): if bad code or a manual change ever got past
           the locking, the filtered unique indexes refuse the second Active
           session. Translate the technical error into our business error. */
        IF ERROR_NUMBER() IN (2601, 2627)
        BEGIN
            IF ERROR_MESSAGE() LIKE N'%UX_Sessions_OneActivePerVehicle%'
                THROW 50002, N'Vehicle is already parked.', 1;
            IF ERROR_MESSAGE() LIKE N'%UX_Sessions_OneActivePerSpace%'
                THROW 50003, N'No free space available (the chosen space was just taken). Please try again.', 1;
        END;

        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   usp_VehicleExit
   Locks the vehicle's active session, computes the fee with the function,
   closes the session and frees the space - all in one transaction.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_VehicleExit
    @LicensePlate NVARCHAR(50),
    @SessionID    INT          OUTPUT,
    @Fee          DECIMAL(8,2) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Plate VARCHAR(50), @SpaceID INT, @EntryTime DATETIME2(0),
            @Rate DECIMAL(6,2), @ExitTime DATETIME2(0), @Msg NVARCHAR(2048);
    SET @SessionID = NULL;
    SET @Fee = NULL;

    SET @Plate = UPPER(LTRIM(RTRIM(@LicensePlate)));
    IF @Plate IS NULL OR @Plate = ''
        THROW 50008, N'Invalid input: license plate is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        /* UPDLOCK, ROWLOCK on the SESSION row: if the exit button is pressed
           twice (or exit and cancel happen together), the second call waits,
           then finds no Active session and gets 50004 - the fee can never be
           computed twice. The hint applies only to ParkingSessions (ps). */
        SELECT @SessionID = ps.SessionID,
               @SpaceID   = ps.SpaceID,
               @EntryTime = ps.EntryTime,
               @Rate      = st.HourlyRate
        FROM dbo.ParkingSessions AS ps WITH (UPDLOCK, ROWLOCK)
        JOIN dbo.Vehicles        AS v  ON v.VehicleID    = ps.VehicleID
        JOIN dbo.ParkingSpaces   AS sp ON sp.SpaceID     = ps.SpaceID
        JOIN dbo.SpaceTypes      AS st ON st.SpaceTypeID = sp.SpaceTypeID
        WHERE v.LicensePlate = @Plate
          AND ps.Status = 'Active';

        IF @SessionID IS NULL
        BEGIN
            SET @Msg = CONCAT(N'Vehicle ', @Plate, N' has no active session.');
            THROW 50004, @Msg, 1;
        END;

        SET @ExitTime = CAST(SYSDATETIME() AS DATETIME2(0));
        SET @Fee      = dbo.fn_CalculateFee(@EntryTime, @ExitTime, @Rate);

        UPDATE dbo.ParkingSessions
        SET ExitTime = @ExitTime,
            Status   = 'Completed',
            Fee      = @Fee
        WHERE SessionID = @SessionID;

        UPDATE dbo.ParkingSpaces
        SET IsOccupied = 0
        WHERE SpaceID = @SpaceID;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @SessionID = NULL;
        SET @Fee = NULL;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   usp_RecordPayment
   The amount is READ from the session's Fee - the caller cannot choose
   it, so nobody can "pay 0.50" for a 30.00 session.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_RecordPayment
    @SessionID INT,
    @Method    VARCHAR(10),
    @PaymentID INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @CanonMethod VARCHAR(10), @Status VARCHAR(10), @Fee DECIMAL(8,2), @Msg NVARCHAR(2048);
    SET @PaymentID = NULL;

    IF @SessionID IS NULL
        THROW 50008, N'Invalid input: session number is required.', 1;

    SELECT @CanonMethod = m.Method
    FROM (VALUES ('Cash'), ('Card'), ('Mobile')) AS m(Method)
    WHERE m.Method = LTRIM(RTRIM(@Method));
    IF @CanonMethod IS NULL
        THROW 50008, N'Invalid input: payment method must be Cash, Card or Mobile.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        /* Lock the session row so two cashiers cannot both pass the
           "no payment yet" check for the same session at the same time. */
        SELECT @Status = Status, @Fee = Fee
        FROM dbo.ParkingSessions WITH (UPDLOCK, ROWLOCK)
        WHERE SessionID = @SessionID;

        IF @Status IS NULL
        BEGIN
            SET @Msg = CONCAT(N'Invalid input: session ', @SessionID, N' does not exist.');
            THROW 50008, @Msg, 1;
        END;

        IF @Status <> 'Completed'
        BEGIN
            SET @Msg = CONCAT(N'Session ', @SessionID, N' cannot be paid: its status is ', @Status,
                              N' (only Completed sessions can be paid).');
            THROW 50005, @Msg, 1;
        END;

        IF EXISTS (SELECT 1 FROM dbo.Payments WHERE SessionID = @SessionID)
        BEGIN
            SET @Msg = CONCAT(N'Session ', @SessionID, N' already has a payment.');
            THROW 50006, @Msg, 1;
        END;

        INSERT dbo.Payments (SessionID, Amount, Method)     -- PaidAt: DEFAULT SYSDATETIME()
        VALUES (@SessionID, @Fee, @CanonMethod);

        SET @PaymentID = SCOPE_IDENTITY();

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @PaymentID = NULL;

        /* Layer 2: UQ_Payments_SessionID refuses a second payment even if
           the check above were somehow bypassed. */
        IF ERROR_NUMBER() IN (2601, 2627)
            THROW 50006, N'This session already has a payment.', 1;

        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   usp_CancelSession
   Active -> Cancelled, ExitTime = now, Fee = 0, space freed.
   (e.g. a car entered by mistake, or drove away without parking)
   ===================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_CancelSession
    @SessionID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status VARCHAR(10), @SpaceID INT, @Msg NVARCHAR(2048);

    IF @SessionID IS NULL
        THROW 50008, N'Invalid input: session number is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status, @SpaceID = SpaceID
        FROM dbo.ParkingSessions WITH (UPDLOCK, ROWLOCK)
        WHERE SessionID = @SessionID;

        IF @Status IS NULL
        BEGIN
            SET @Msg = CONCAT(N'Invalid input: session ', @SessionID, N' does not exist.');
            THROW 50008, @Msg, 1;
        END;

        IF @Status <> 'Active'
        BEGIN
            SET @Msg = CONCAT(N'Session ', @SessionID, N' is not active (status: ', @Status, N'); only an active session can be cancelled.');
            THROW 50004, @Msg, 1;
        END;

        UPDATE dbo.ParkingSessions
        SET Status   = 'Cancelled',
            ExitTime = CAST(SYSDATETIME() AS DATETIME2(0)),
            Fee      = 0
        WHERE SessionID = @SessionID;

        UPDATE dbo.ParkingSpaces
        SET IsOccupied = 0
        WHERE SpaceID = @SpaceID;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   usp_SearchSessions - the History screen.
   Every filter is optional (NULL = "don't filter"). Newest first, paged.
   - Plate filter is a PREFIX search ('B 10' finds 'B 100013', ...).
   - Dates are whole days, both inclusive: EntryTime >= @FromDate AND
     EntryTime < the day after @ToDate. Written this way (no function on
     the column) so an index on EntryTime can be used - see script 06.
   - TotalRows is returned on every row so the app can show "page 3 of 40".
   ===================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_SearchSessions
    @LicensePlate NVARCHAR(50) = NULL,
    @FromDate     DATE         = NULL,
    @ToDate       DATE         = NULL,
    @Status       VARCHAR(10)  = NULL,
    @PageNumber   INT          = 1,
    @PageSize     INT          = 50
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Plate VARCHAR(50) = NULLIF(UPPER(LTRIM(RTRIM(@LicensePlate))), '');
    DECLARE @CanonStatus VARCHAR(10);

    /* The plate is used in LIKE: refuse wildcard characters (% _ [ ]) so
       the search means exactly what the user typed. */
    IF @Plate COLLATE Latin1_General_BIN LIKE '%[^A-Z0-9 -]%'
        THROW 50008, N'Invalid input: plate filter may contain only letters, digits, spaces and hyphens.', 1;

    IF @Status IS NOT NULL AND LTRIM(RTRIM(@Status)) <> ''
    BEGIN
        SELECT @CanonStatus = s.Status
        FROM (VALUES ('Active'), ('Completed'), ('Cancelled')) AS s(Status)
        WHERE s.Status = LTRIM(RTRIM(@Status));
        IF @CanonStatus IS NULL
            THROW 50008, N'Invalid input: status must be Active, Completed or Cancelled.', 1;
    END;

    IF @FromDate IS NOT NULL AND @ToDate IS NOT NULL AND @FromDate > @ToDate
        THROW 50008, N'Invalid input: "from" date is after "to" date.', 1;

    IF @PageNumber IS NULL OR @PageNumber < 1
        THROW 50008, N'Invalid input: page number must be 1 or more.', 1;

    IF @PageSize IS NULL OR @PageSize NOT BETWEEN 1 AND 500
        THROW 50008, N'Invalid input: page size must be between 1 and 500.', 1;

    SELECT  ps.SessionID,
            v.LicensePlate,
            v.OwnerName,
            sp.SpaceCode,
            ps.EntryTime,
            ps.ExitTime,
            ps.Status,
            ps.Fee,
            p.Method        AS PaymentMethod,
            COUNT(*) OVER () AS TotalRows        -- rows matching the filters, before paging
    FROM dbo.ParkingSessions AS ps
    JOIN dbo.Vehicles        AS v  ON v.VehicleID = ps.VehicleID
    JOIN dbo.ParkingSpaces   AS sp ON sp.SpaceID  = ps.SpaceID
    LEFT JOIN dbo.Payments   AS p  ON p.SessionID = ps.SessionID
    WHERE (@Plate       IS NULL OR v.LicensePlate LIKE @Plate + '%')
      AND (@FromDate    IS NULL OR ps.EntryTime >= @FromDate)
      AND (@ToDate      IS NULL OR ps.EntryTime <  DATEADD(DAY, 1, CAST(@ToDate AS DATETIME2(0))))
      AND (@CanonStatus IS NULL OR ps.Status = @CanonStatus)
    ORDER BY ps.EntryTime DESC, ps.SessionID DESC          -- SessionID makes the order unique,
                                                           -- so rows never jump between pages
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY
    /* OPTION (RECOMPILE) - why:
       This is a "catch-all" query: (@x IS NULL OR col = @x) for every filter.
       Normally SQL Server compiles a plan ONCE and reuses it for every call.
       A plan built for "no filters" must read everything (scan) and would
       then be reused for "one plate" too - very slow. A plan built for
       "one plate" could be reused for "no filters" - also bad.
       RECOMPILE builds a fresh plan on every call using the ACTUAL values:
       the optimizer sees e.g. @Plate IS NULL is true, removes that whole
       condition, and can seek on the right index for the filters really
       used. The cost is a few milliseconds of compiling per call, which is
       nothing for a search screen clicked by a human. */
    OPTION (RECOMPILE);
END;
GO

/* =====================================================================
   usp_GetVehicleHistory - all sessions of one vehicle, newest first,
   with space code, fee and payment method.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_GetVehicleHistory
    @LicensePlate NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Plate VARCHAR(50) = UPPER(LTRIM(RTRIM(@LicensePlate)));
    DECLARE @VehicleID INT, @Msg NVARCHAR(2048);

    IF @Plate IS NULL OR @Plate = ''
        THROW 50008, N'Invalid input: license plate is required.', 1;

    SELECT @VehicleID = VehicleID FROM dbo.Vehicles WHERE LicensePlate = @Plate;

    IF @VehicleID IS NULL
    BEGIN
        SET @Msg = CONCAT(N'Vehicle ', @Plate, N' is not registered.');
        THROW 50001, @Msg, 1;
    END;

    SELECT  ps.SessionID,
            sp.SpaceCode,
            st.TypeName  AS SpaceType,
            ps.EntryTime,
            ps.ExitTime,
            ps.Status,
            ps.Fee,
            p.Method     AS PaymentMethod,
            p.PaidAt
    FROM dbo.ParkingSessions AS ps
    JOIN dbo.ParkingSpaces   AS sp ON sp.SpaceID     = ps.SpaceID
    JOIN dbo.SpaceTypes      AS st ON st.SpaceTypeID = sp.SpaceTypeID
    LEFT JOIN dbo.Payments   AS p  ON p.SessionID    = ps.SessionID
    WHERE ps.VehicleID = @VehicleID
    ORDER BY ps.EntryTime DESC, ps.SessionID DESC;
END;
GO

/* =====================================================================
   usp_GetDashboard - one row of headline numbers for the first screen.
   "Free" means in service AND not occupied: an out-of-service space
   cannot be given to a car, so it is not free.
   Revenue today uses a date RANGE on PaidAt (not CAST(PaidAt AS DATE) =
   today) so the IX_Payments_PaidAt index from script 06 can be used.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_GetDashboard
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today    DATETIME2(0) = CAST(CAST(SYSDATETIME() AS DATE) AS DATETIME2(0));
    DECLARE @Tomorrow DATETIME2(0) = DATEADD(DAY, 1, @Today);

    SELECT  s.TotalSpaces,
            s.InServiceSpaces,
            s.FreeSpaces,
            s.OccupiedSpaces,
            s.TotalSpaces - s.InServiceSpaces                                  AS OutOfServiceSpaces,
            (SELECT COUNT(*) FROM dbo.ParkingSessions WHERE Status = 'Active') AS ActiveSessions,
            r.PaymentsToday,
            r.RevenueToday
    FROM
    (
        SELECT  COUNT(*)                                                   AS TotalSpaces,
                SUM(CASE WHEN IsActive = 1 THEN 1 ELSE 0 END)              AS InServiceSpaces,
                SUM(CASE WHEN IsActive = 1 AND IsOccupied = 0 THEN 1 ELSE 0 END) AS FreeSpaces,
                SUM(CASE WHEN IsOccupied = 1 THEN 1 ELSE 0 END)            AS OccupiedSpaces
        FROM dbo.ParkingSpaces
    ) AS s
    CROSS JOIN
    (
        SELECT  COUNT(*)                                    AS PaymentsToday,
                ISNULL(SUM(Amount), 0.00)                   AS RevenueToday   -- 0, not NULL, when nothing paid yet
        FROM dbo.Payments
        WHERE PaidAt >= @Today AND PaidAt < @Tomorrow
    ) AS r;
END;
GO

/* =====================================================================
   HAND TEST (acceptance step 3): register -> entry -> exit -> payment.
   Everything runs inside ONE outer transaction that is ROLLED BACK at
   the end, so the database is unchanged and you can run this again.
   (A procedure's own BEGIN/COMMIT inside an outer transaction only
   changes the nesting count; the outer ROLLBACK still undoes it all.)
   ===================================================================== */
SET NOCOUNT ON;
BEGIN TRANSACTION;

DECLARE @VehicleID INT, @SessionID INT, @SpaceCode VARCHAR(10),
        @ExitSession INT, @Fee DECIMAL(8,2), @PaymentID INT, @OldCar VARCHAR(15);

/* 1. Register a new car. Messy input on purpose: spaces + lower case. */
EXEC dbo.usp_RegisterVehicle
     @LicensePlate = N'  test-001 ',
     @OwnerName    = N'Test Driver',
     @VehicleType  = 'car',
     @VehicleID    = @VehicleID OUTPUT;

SELECT '1. registered (plate must be TEST-001, type Car)' AS Step, VehicleID, LicensePlate, VehicleType
FROM dbo.Vehicles WHERE VehicleID = @VehicleID;

/* 2. The new car enters: it gets the lowest free space. */
EXEC dbo.usp_VehicleEntry
     @LicensePlate = N'test-001',
     @SessionID    = @SessionID OUTPUT,
     @SpaceCode    = @SpaceCode OUTPUT;

SELECT '2. entered' AS Step, @SessionID AS SessionID, @SpaceCode AS SpaceCode,
       sp.IsOccupied AS SpaceNowOccupied
FROM dbo.ParkingSpaces AS sp WHERE sp.SpaceCode = @SpaceCode;

/* 3. A seeded car that has been parked for hours leaves (so the fee is > 0;
      the new car would be free because it has been inside < 10 minutes). */
SELECT TOP (1) @OldCar = LicensePlate
FROM dbo.vw_ActiveSessions
WHERE SessionID <> @SessionID
ORDER BY EntryTime;

EXEC dbo.usp_VehicleExit
     @LicensePlate = @OldCar,
     @SessionID    = @ExitSession OUTPUT,
     @Fee          = @Fee OUTPUT;

SELECT '3. exited' AS Step, @OldCar AS Plate, @ExitSession AS SessionID, @Fee AS Fee;

/* 4. It pays. The amount comes from the session, not from us. */
EXEC dbo.usp_RecordPayment
     @SessionID = @ExitSession,
     @Method    = 'card',
     @PaymentID = @PaymentID OUTPUT;

SELECT '4. paid' AS Step, PaymentID, SessionID, Amount, Method, PaidAt
FROM dbo.Payments WHERE PaymentID = @PaymentID;

/* 5. Reading procedures. */
EXEC dbo.usp_GetVehicleHistory @LicensePlate = @OldCar;          -- top row = the session just paid
EXEC dbo.usp_GetDashboard;                                       -- revenue today = that payment
EXEC dbo.usp_SearchSessions @Status = 'Active', @PageSize = 5;   -- includes TEST-001

/* 6. Summary. */
SELECT CASE WHEN @VehicleID IS NOT NULL
             AND @SessionID IS NOT NULL
             AND @Fee > 0
             AND @PaymentID IS NOT NULL
             AND (SELECT Amount FROM dbo.Payments WHERE PaymentID = @PaymentID) = @Fee
             AND (SELECT Status FROM dbo.ParkingSessions WHERE SessionID = @ExitSession) = 'Completed'
            THEN 'PASS - entry -> exit -> payment works'
            ELSE 'FAIL' END AS HandTestResult;

/* Undo everything the test did. Change to COMMIT if you want to keep it. */
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
GO


-- #####################################################################
-- #####  PART: 05_triggers.sql
-- #####################################################################
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


-- #####################################################################
-- #####  FINAL CHECK - every line must say READY
-- #####################################################################
USE ParkingDB;
GO
SET NOEXEC OFF;
SELECT Item, Expected, Actual, CASE WHEN Ok = 1 THEN 'READY' ELSE 'PROBLEM' END AS Result
FROM (
    SELECT 'Parking spaces' AS Item, '300' AS Expected, CAST(COUNT(*) AS VARCHAR(20)) AS Actual,
           CASE WHEN COUNT(*) = 300 THEN 1 ELSE 0 END AS Ok FROM dbo.ParkingSpaces
    UNION ALL
    SELECT 'Vehicles', '5000+', CAST(COUNT(*) AS VARCHAR(20)), CASE WHEN COUNT(*) >= 5000 THEN 1 ELSE 0 END FROM dbo.Vehicles
    UNION ALL
    SELECT 'Sessions', '100000+', CAST(COUNT(*) AS VARCHAR(20)), CASE WHEN COUNT(*) > 100000 THEN 1 ELSE 0 END FROM dbo.ParkingSessions
    UNION ALL
    SELECT 'Cars parked now', 'about 40', CAST(COUNT(*) AS VARCHAR(20)), CASE WHEN COUNT(*) > 0 THEN 1 ELSE 0 END
    FROM dbo.ParkingSessions WHERE Status = 'Active'
    UNION ALL
    SELECT 'Free spaces', 'about 258', CAST(COUNT(*) AS VARCHAR(20)), CASE WHEN COUNT(*) > 0 THEN 1 ELSE 0 END
    FROM dbo.ParkingSpaces WHERE IsOccupied = 0 AND IsActive = 1
    UNION ALL
    SELECT 'Stored procedures', '8', CAST(COUNT(*) AS VARCHAR(20)), CASE WHEN COUNT(*) = 8 THEN 1 ELSE 0 END
    FROM sys.procedures WHERE name IN ('usp_RegisterVehicle','usp_VehicleEntry','usp_VehicleExit','usp_RecordPayment',
                                       'usp_CancelSession','usp_SearchSessions','usp_GetVehicleHistory','usp_GetDashboard')
    UNION ALL
    SELECT 'Views', '3', CAST(COUNT(*) AS VARCHAR(20)), CASE WHEN COUNT(*) = 3 THEN 1 ELSE 0 END
    FROM sys.views WHERE name IN ('vw_SpaceStatus','vw_ActiveSessions','vw_DailyRevenue')
    UNION ALL
    SELECT 'Triggers', '5', CAST(COUNT(*) AS VARCHAR(20)), CASE WHEN COUNT(*) = 5 THEN 1 ELSE 0 END
    FROM sys.triggers WHERE name LIKE 'trg[_]%'
    UNION ALL
    SELECT 'Audit log empty', '0', CAST(COUNT(*) AS VARCHAR(20)), CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END FROM dbo.AuditLog
) AS x;
GO
