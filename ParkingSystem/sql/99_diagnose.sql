-- =====================================================================
-- 99_diagnose.sql   (helper - not part of the numbered build)
-- ---------------------------------------------------------------------
-- WHAT : Answers "why did usp_VehicleEntry say 50003 No free space?"
--          Grid 1 - are spaces REALLY free?
--          Grid 2 - is ANOTHER window holding locks in ParkingDB?
--          Grid 3 - which windows have a transaction left open?
-- WHY  : The entry procedure reads spaces WITH (UPDLOCK, READPAST).
--        READPAST means "skip rows that someone else has locked".
--        So if another SSMS window has an OPEN transaction that touched
--        the spaces (for example a query you stopped with the red Stop
--        button in the middle of a test or demo), those spaces are
--        invisible to the procedure and it answers "No free space".
--        Stopping a query does NOT roll back its transaction - it stays
--        open, holding its locks, until that window commits, rolls back
--        or is closed.
-- HOW  : Open in a new window, F5.
-- =====================================================================
USE ParkingDB;
GO

-- Grid 1: the real state of the spaces (expect ~258 free, ~40 occupied, 2 out of service)
SELECT CASE WHEN IsActive = 0   THEN 'out of service'
            WHEN IsOccupied = 1 THEN 'occupied'
            ELSE 'free' END       AS SpaceState,
       COUNT(*)                   AS Spaces
FROM dbo.ParkingSpaces
GROUP BY CASE WHEN IsActive = 0   THEN 'out of service'
              WHEN IsOccupied = 1 THEN 'occupied'
              ELSE 'free' END;

-- Grid 2: locks held in ParkingDB by OTHER sessions (windows).
-- Expect NO rows. Any row = another window is holding locks.
SELECT l.request_session_id     AS OtherSessionID,
       l.resource_type,
       l.request_mode,
       l.request_status,
       COUNT(*)                 AS LockCount
FROM sys.dm_tran_locks AS l
WHERE l.resource_database_id = DB_ID()
  AND l.request_session_id <> @@SPID
  AND l.resource_type <> 'DATABASE'          -- every connection holds a harmless shared DATABASE lock
GROUP BY l.request_session_id, l.resource_type, l.request_mode, l.request_status
ORDER BY OtherSessionID;

-- Grid 3: sessions with an OPEN transaction, and the last SQL they ran.
-- The session_id is the number in brackets on each SSMS tab, e.g. "(74)".
SELECT s.session_id                  AS SessionID,
       s.program_name,
       s.login_name,
       at.transaction_begin_time     AS OpenSince,
       LEFT(t.text, 300)             AS LastSqlStarted
FROM sys.dm_tran_session_transactions AS st
JOIN sys.dm_tran_active_transactions  AS at ON at.transaction_id = st.transaction_id
JOIN sys.dm_exec_sessions             AS s  ON s.session_id      = st.session_id
JOIN sys.dm_exec_connections          AS c  ON c.session_id      = s.session_id
OUTER APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) AS t
WHERE s.session_id <> @@SPID
ORDER BY at.transaction_begin_time;

-- Grid 4: who is WAITING for whom right now (run this while the app is stuck).
-- WaitingSession = the stuck one (usually the app); BlockedBy = the window
-- that holds the lock. Expect NO rows when nothing is stuck.
SELECT r.session_id          AS WaitingSession,
       r.blocking_session_id AS BlockedBy,
       r.wait_type,
       r.wait_time / 1000    AS WaitingSeconds,
       s.program_name        AS WaitingProgram,
       LEFT(t.text, 200)     AS WaitingSql
FROM sys.dm_exec_requests AS r
JOIN sys.dm_exec_sessions AS s ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE r.blocking_session_id <> 0;

-- FIX (pick one):
--   a) Go to the SSMS tab whose number matches SessionID, run:
--          IF @@TRANCOUNT > 0 ROLLBACK;
--   b) Close that tab; when SSMS asks "commit these transactions?" answer NO.
--   c) From this window:   KILL <SessionID>;     (rolls that window's work back)
-- Then run 04_procedures.sql again.
