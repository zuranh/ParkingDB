-- =====================================================================
-- 06_indexes_performance.sql
-- ---------------------------------------------------------------------
-- WHAT : Measures five typical queries BEFORE and AFTER adding five
--        indexes, plus two classic lessons:
--          - a function on a column (YEAR(EntryTime)) blocks an index seek
--          - a covering index (INCLUDE) avoids key lookups
-- WHY  : An index is a trade-off, not a free gift. We add one only for a
--        query we can name, and we prove with numbers that it helps.
-- CHECK: In the Messages tab, "logical reads" for ParkingSessions /
--        Payments drop from hundreds to a handful; in the Execution plan
--        tab, "Clustered Index Scan" becomes "Index Seek".
--
-- HOW TO RUN
--   1. Press Ctrl+M ("Include Actual Execution Plan") BEFORE running.
--   2. Run the whole file (F5). It is re-runnable: PART 0 drops the
--      performance indexes first, so the BEFORE numbers are always honest.
--   3. Read the numbers:
--        Messages tab   - one block per query, e.g.
--                         Table 'ParkingSessions'. Scan count 1, logical reads 742 ...
--                         SQL Server Execution Times: CPU time = 15 ms, elapsed time = 21 ms.
--        Execution plan - one plan per query; hover over the operator on
--                         the right to see its name (Scan / Seek / Key Lookup).
--   4. Copy the numbers into the RESULTS TABLE at the bottom.
--
-- WHAT TO MEASURE
--   LOGICAL READS are the important number: how many 8 KB pages SQL Server
--   had to read from memory. It is stable from run to run. Elapsed ms
--   jumps around (other programs, cache, a 120,000-row table is small for
--   a modern PC), so record it but trust the reads. If you see
--   "physical reads" > 0 the first time, run again: the data is now cached.
-- =====================================================================

USE ParkingDB;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

-- =====================================================================
-- PART 0 - start from "no performance indexes" (makes the file re-runnable)
-- The two filtered UNIQUE indexes from script 01 stay: they are integrity
-- rules, not performance indexes.
-- =====================================================================
DROP INDEX IF EXISTS IX_Sessions_Vehicle_Entry            ON dbo.ParkingSessions;
DROP INDEX IF EXISTS IX_Sessions_Vehicle_Entry_NoInclude  ON dbo.ParkingSessions;
DROP INDEX IF EXISTS IX_Sessions_EntryTime                ON dbo.ParkingSessions;
DROP INDEX IF EXISTS IX_Sessions_Space_Entry              ON dbo.ParkingSessions;
DROP INDEX IF EXISTS IX_Payments_PaidAt                   ON dbo.Payments;
DROP INDEX IF EXISTS IX_Spaces_Free                       ON dbo.ParkingSpaces;
GO

-- Show what exists now (expect only PKs, UQ_ constraints and the 2 UX_ indexes).
SELECT OBJECT_NAME(i.object_id) AS TableName, i.name AS IndexName, i.type_desc, i.has_filter
FROM sys.indexes AS i
WHERE i.object_id IN (OBJECT_ID('dbo.ParkingSessions'), OBJECT_ID('dbo.Payments'), OBJECT_ID('dbo.ParkingSpaces'))
  AND i.index_id > 0
ORDER BY TableName, i.index_id;
GO


-- =====================================================================
-- PART 1 - BEFORE (no performance indexes)
-- Expected plan operator for Q1-Q4: Clustered Index Scan (the whole
-- table is read, every time, whatever we look for).
-- =====================================================================
SET STATISTICS IO, TIME ON;     -- prints reads and times in the Messages tab

DECLARE @VehicleID   INT          = 1234;                                   -- any vehicle 1..5000 (~24 sessions each)
DECLARE @SpaceID     INT          = 150;                                    -- any space 1..300
DECLARE @Today       DATE         = CAST(SYSDATETIME() AS DATE);
DECLARE @WeekTo      DATETIME2(0) = DATEADD(DAY, -30, @Today);              -- a week of history
DECLARE @WeekFrom    DATETIME2(0) = DATEADD(DAY, -7, @WeekTo);
DECLARE @PeriodFrom  DATETIME2(0) = DATEADD(MONTH, -2, @Today);             -- a month of history
DECLARE @PeriodTo    DATETIME2(0) = DATEADD(MONTH, -1, @Today);
DECLARE @MonthStart  DATETIME2(0) = DATEFROMPARTS(YEAR(DATEADD(MONTH, -2, @Today)), MONTH(DATEADD(MONTH, -2, @Today)), 1);
DECLARE @MonthEnd    DATETIME2(0) = DATEADD(MONTH, 1, @MonthStart);
DECLARE @EvTypeID    TINYINT      = (SELECT SpaceTypeID FROM dbo.SpaceTypes WHERE TypeName = 'EV');

PRINT '===== BEFORE Q1: history of one vehicle, newest first =====';
SELECT SessionID, SpaceID, EntryTime, ExitTime, Status, Fee
FROM dbo.ParkingSessions
WHERE VehicleID = @VehicleID
ORDER BY EntryTime DESC;

PRINT '===== BEFORE Q2: sessions and revenue in a date range =====';
SELECT COUNT(*) AS Sessions, SUM(Fee) AS Revenue
FROM dbo.ParkingSessions
WHERE EntryTime >= @WeekFrom AND EntryTime < @WeekTo
  AND Status = 'Completed';

PRINT '===== BEFORE Q3: sessions of one space in a period =====';
SELECT SessionID, VehicleID, EntryTime, ExitTime
FROM dbo.ParkingSessions
WHERE SpaceID = @SpaceID
  AND EntryTime >= @PeriodFrom AND EntryTime < @PeriodTo
ORDER BY EntryTime;

PRINT '===== BEFORE Q4: payments per day and method in a month =====';
SELECT CAST(PaidAt AS DATE) AS PayDate, Method, COUNT(*) AS Payments, SUM(Amount) AS Total
FROM dbo.Payments
WHERE PaidAt >= @MonthStart AND PaidAt < @MonthEnd
GROUP BY CAST(PaidAt AS DATE), Method
ORDER BY PayDate, Method;

PRINT '===== BEFORE Q5: find a free EV space (the entry procedure''s query) =====';
SELECT TOP (1) SpaceID, SpaceCode
FROM dbo.ParkingSpaces
WHERE IsOccupied = 0 AND IsActive = 1     -- literals, exactly like in usp_VehicleEntry
  AND SpaceTypeID = @EvTypeID
ORDER BY SpaceID;

SET STATISTICS IO, TIME OFF;
GO


-- =====================================================================
-- PART 2 - CREATE THE INDEXES
-- Each index is designed for one named query:
--   key columns  = what the WHERE / ORDER BY searches on (in that order)
--   INCLUDE      = extra columns stored only in the leaf level, so the
--                  query finds EVERYTHING it needs in the index and never
--                  has to go back to the table ("covering index").
-- =====================================================================

-- Q1: VehicleID first (equality), then EntryTime DESC so the rows are
-- already in "newest first" order -> no sort needed.
CREATE NONCLUSTERED INDEX IX_Sessions_Vehicle_Entry
    ON dbo.ParkingSessions (VehicleID, EntryTime DESC)
    INCLUDE (SpaceID, ExitTime, Status, Fee);

-- Q2: a range on EntryTime; Status and Fee included so COUNT/SUM need
-- nothing else.
CREATE NONCLUSTERED INDEX IX_Sessions_EntryTime
    ON dbo.ParkingSessions (EntryTime)
    INCLUDE (Status, Fee);

-- Q3: equality on SpaceID, then range on EntryTime. NOT covering on
-- purpose: one space in one month is ~60 rows, and 60 key lookups are
-- cheap; including every column would make the index almost a second
-- copy of the table.
CREATE NONCLUSTERED INDEX IX_Sessions_Space_Entry
    ON dbo.ParkingSessions (SpaceID, EntryTime);

-- Q4: a range on PaidAt; Amount and Method included for the GROUP BY / SUM.
CREATE NONCLUSTERED INDEX IX_Payments_PaidAt
    ON dbo.Payments (PaidAt)
    INCLUDE (Amount, Method);

-- Q5: FILTERED index - it contains ONLY the free, in-service spaces.
-- The entry procedure's WHERE clause uses the same literals
-- (IsOccupied = 0 AND IsActive = 1), so SQL Server knows every row in
-- this index qualifies. Ordered by type, then SpaceID: "the lowest free
-- EV space" is simply the first row of the EV part of the index.
-- Honest note: ParkingSpaces has only 300 rows (2-3 pages), so the read
-- savings are tiny. The real benefit is in usp_VehicleEntry: its
-- UPDLOCK + READPAST search touches (and locks) only FREE rows instead of
-- walking past occupied ones. A filtered index can only be used when the
-- query's filter is written with literals, not variables - that is why
-- the procedure writes "IsOccupied = 0" and not "IsOccupied = @x".
CREATE NONCLUSTERED INDEX IX_Spaces_Free
    ON dbo.ParkingSpaces (SpaceTypeID, SpaceID)
    WHERE IsOccupied = 0 AND IsActive = 1;
GO


-- =====================================================================
-- PART 3 - AFTER: exactly the same queries
-- Expected plan operator: Index Seek (Q3: Index Seek + Key Lookup).
-- =====================================================================
SET STATISTICS IO, TIME ON;

DECLARE @VehicleID   INT          = 1234;
DECLARE @SpaceID     INT          = 150;
DECLARE @Today       DATE         = CAST(SYSDATETIME() AS DATE);
DECLARE @WeekTo      DATETIME2(0) = DATEADD(DAY, -30, @Today);
DECLARE @WeekFrom    DATETIME2(0) = DATEADD(DAY, -7, @WeekTo);
DECLARE @PeriodFrom  DATETIME2(0) = DATEADD(MONTH, -2, @Today);
DECLARE @PeriodTo    DATETIME2(0) = DATEADD(MONTH, -1, @Today);
DECLARE @MonthStart  DATETIME2(0) = DATEFROMPARTS(YEAR(DATEADD(MONTH, -2, @Today)), MONTH(DATEADD(MONTH, -2, @Today)), 1);
DECLARE @MonthEnd    DATETIME2(0) = DATEADD(MONTH, 1, @MonthStart);
DECLARE @EvTypeID    TINYINT      = (SELECT SpaceTypeID FROM dbo.SpaceTypes WHERE TypeName = 'EV');

PRINT '===== AFTER Q1: history of one vehicle, newest first =====';
SELECT SessionID, SpaceID, EntryTime, ExitTime, Status, Fee
FROM dbo.ParkingSessions
WHERE VehicleID = @VehicleID
ORDER BY EntryTime DESC;

PRINT '===== AFTER Q2: sessions and revenue in a date range =====';
SELECT COUNT(*) AS Sessions, SUM(Fee) AS Revenue
FROM dbo.ParkingSessions
WHERE EntryTime >= @WeekFrom AND EntryTime < @WeekTo
  AND Status = 'Completed';

PRINT '===== AFTER Q3: sessions of one space in a period =====';
SELECT SessionID, VehicleID, EntryTime, ExitTime
FROM dbo.ParkingSessions
WHERE SpaceID = @SpaceID
  AND EntryTime >= @PeriodFrom AND EntryTime < @PeriodTo
ORDER BY EntryTime;

PRINT '===== AFTER Q4: payments per day and method in a month =====';
SELECT CAST(PaidAt AS DATE) AS PayDate, Method, COUNT(*) AS Payments, SUM(Amount) AS Total
FROM dbo.Payments
WHERE PaidAt >= @MonthStart AND PaidAt < @MonthEnd
GROUP BY CAST(PaidAt AS DATE), Method
ORDER BY PayDate, Method;

PRINT '===== AFTER Q5: find a free EV space (the entry procedure''s query) =====';
SELECT TOP (1) SpaceID, SpaceCode
FROM dbo.ParkingSpaces
WHERE IsOccupied = 0 AND IsActive = 1
  AND SpaceTypeID = @EvTypeID
ORDER BY SpaceID;

SET STATISTICS IO, TIME OFF;
GO


-- =====================================================================
-- PART 4 - LESSON: a function on the column blocks a seek ("sargable")
-- Both queries return the SAME rows. The index IX_Sessions_EntryTime is
-- sorted by EntryTime, but it is NOT sorted by YEAR(EntryTime): to know
-- YEAR() of a row SQL Server must read the row, so it reads them ALL
-- (Index Scan). The range version tells SQL Server exactly where in the
-- sorted index to start and stop (Index Seek).
-- "Sargable" = Search ARGument ABLE: the column stands alone on one side
-- of the comparison.
-- =====================================================================
SET STATISTICS IO, TIME ON;

-- 4a - the pair from the plan: a whole year.
-- All seeded history lies in 2026, so both read nearly every row here -
-- compare the PLAN OPERATORS (Scan vs Seek), not the read counts.
PRINT '===== 4a NON-sargable: YEAR(EntryTime) = 2026 =====';
SELECT COUNT(*) AS Sessions FROM dbo.ParkingSessions WHERE YEAR(EntryTime) = 2026;

PRINT '===== 4a sargable: EntryTime in [2026-01-01, 2027-01-01) =====';
SELECT COUNT(*) AS Sessions FROM dbo.ParkingSessions
WHERE EntryTime >= '2026-01-01' AND EntryTime < '2027-01-01';

-- 4b - the same lesson on ONE month, where the read counts differ a lot.
DECLARE @M DATETIME2(0) = DATEFROMPARTS(YEAR(DATEADD(MONTH, -2, SYSDATETIME())), MONTH(DATEADD(MONTH, -2, SYSDATETIME())), 1);

PRINT '===== 4b NON-sargable: YEAR() = ... AND MONTH() = ... =====';
SELECT COUNT(*) AS Sessions FROM dbo.ParkingSessions
WHERE YEAR(EntryTime) = YEAR(@M) AND MONTH(EntryTime) = MONTH(@M);

PRINT '===== 4b sargable: EntryTime >= first day AND < first day of next month =====';
SELECT COUNT(*) AS Sessions FROM dbo.ParkingSessions
WHERE EntryTime >= @M AND EntryTime < DATEADD(MONTH, 1, @M);

SET STATISTICS IO, TIME OFF;
GO


-- =====================================================================
-- PART 5 - LESSON: covering index vs key lookup (Q1 with and without INCLUDE)
-- We build a second, temporary version of the Q1 index WITHOUT the
-- INCLUDE columns and force each version with an index hint.
--   No INCLUDE: Index Seek finds the ~24 SessionIDs, then a KEY LOOKUP
--               goes back to the clustered index for EACH row to fetch
--               SpaceID, ExitTime, Status, Fee (~3 reads per row).
--   INCLUDE   : everything is already in the index leaf -> Seek only.
-- (Index hints are used here ONLY to compare the two; real code should
--  let the optimizer choose.)
-- =====================================================================
CREATE NONCLUSTERED INDEX IX_Sessions_Vehicle_Entry_NoInclude
    ON dbo.ParkingSessions (VehicleID, EntryTime DESC);
GO

SET STATISTICS IO, TIME ON;
DECLARE @VehicleID INT = 1234;

PRINT '===== 5 WITHOUT INCLUDE (Seek + Key Lookup) =====';
SELECT SessionID, SpaceID, EntryTime, ExitTime, Status, Fee
FROM dbo.ParkingSessions WITH (INDEX (IX_Sessions_Vehicle_Entry_NoInclude))
WHERE VehicleID = @VehicleID
ORDER BY EntryTime DESC;

PRINT '===== 5 WITH INCLUDE (covering: Seek only) =====';
SELECT SessionID, SpaceID, EntryTime, ExitTime, Status, Fee
FROM dbo.ParkingSessions WITH (INDEX (IX_Sessions_Vehicle_Entry))
WHERE VehicleID = @VehicleID
ORDER BY EntryTime DESC;

SET STATISTICS IO, TIME OFF;
GO

DROP INDEX IF EXISTS IX_Sessions_Vehicle_Entry_NoInclude ON dbo.ParkingSessions;   -- demo only
GO


-- =====================================================================
-- PART 6 - THE COST OF INDEXES (why we did not index everything)
--  * Slower writes: every INSERT into ParkingSessions now also inserts
--    into 3 more index structures (+2 filtered ones when Active); every
--    exit UPDATE changes ExitTime/Status/Fee, which are INCLUDEd in two
--    indexes, so those must be updated too. Every entry/exit also moves a
--    row in or out of IX_Spaces_Free.
--  * More storage: each index is a sorted copy of some columns. The query
--    below shows how many pages each one uses next to the table itself.
--  * More to maintain: statistics, fragmentation, backup size.
-- For this system the trade is clearly worth it: a parking lot does a few
-- thousand writes a day, but the history / report screens read large
-- ranges constantly. Each index exists because a named query needs it -
-- we did NOT add indexes "just in case" (e.g. none on Fee or OwnerName).
-- =====================================================================
SELECT OBJECT_NAME(i.object_id)                 AS TableName,
       ISNULL(i.name, '(heap)')                 AS IndexName,
       i.type_desc                              AS IndexType,
       SUM(ps.used_page_count)                  AS UsedPages,
       CAST(SUM(ps.used_page_count) * 8 / 1024.0 AS DECIMAL(10,2)) AS UsedMB,
       SUM(ps.row_count)                        AS IndexRows
FROM sys.indexes AS i
JOIN sys.dm_db_partition_stats AS ps
  ON ps.object_id = i.object_id AND ps.index_id = i.index_id
WHERE i.object_id IN (OBJECT_ID('dbo.ParkingSessions'), OBJECT_ID('dbo.Payments'), OBJECT_ID('dbo.ParkingSpaces'))
GROUP BY i.object_id, i.name, i.type_desc, i.index_id
ORDER BY TableName, i.index_id;
GO

-- =====================================================================
-- RESULTS TABLE - fill in from the Messages tab / execution plans
-- (logical reads of the main table; elapsed ms; plan operator)
--
-- #   Query                              BEFORE                         AFTER
--                                        reads   ms    operator         reads   ms    operator
-- Q1  History of one vehicle             _____   ____  ______________   _____   ____  ______________
-- Q2  Sessions + revenue in a week       _____   ____  ______________   _____   ____  ______________
-- Q3  One space in one month             _____   ____  ______________   _____   ____  ______________
-- Q4  Payments per day/method, 1 month   _____   ____  ______________   _____   ____  ______________
-- Q5  First free EV space                _____   ____  ______________   _____   ____  ______________
--
-- 4a  YEAR(EntryTime) = 2026             reads _____  operator ______________
--     EntryTime range (whole year)       reads _____  operator ______________
-- 4b  YEAR()/MONTH() = one month         reads _____  operator ______________
--     EntryTime range (one month)        reads _____  operator ______________
-- 5   Q1 without INCLUDE                 reads _____  operators ____________________
--     Q1 with INCLUDE (covering)         reads _____  operators ____________________
-- =====================================================================
