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
