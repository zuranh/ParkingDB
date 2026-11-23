/* =====================================================================
   00_create_database.sql
   ---------------------------------------------------------------------
   WHAT : Creates the database ParkingDB (only if it does not exist yet).
   WHY  : Every other script runs inside ParkingDB. Creating it
          "if missing" makes this script safe to run any number of times
          without destroying data.
   CHECK: The last SELECT returns one row: ParkingDB, ONLINE, SIMPLE.
   ===================================================================== */

USE master;
GO

/* DB_ID returns NULL when no database with that name exists,
   so the CREATE runs only the first time. Re-running = no error, no data loss. */
IF DB_ID(N'ParkingDB') IS NULL
BEGIN
    CREATE DATABASE ParkingDB;
    PRINT 'ParkingDB created.';
END
ELSE
    PRINT 'ParkingDB already exists - nothing to do.';
GO

/* SIMPLE recovery: the transaction log is reused automatically after each
   checkpoint. Right for a lab (no log backups needed); a production system
   would normally use FULL so it can restore to a point in time. */
ALTER DATABASE ParkingDB SET RECOVERY SIMPLE;
GO

/* ---------------------------------------------------------------------
   OPTIONAL FULL RESET (commented out on purpose).
   Uncomment and run ONLY if you want to throw everything away and start
   over. SINGLE_USER WITH ROLLBACK IMMEDIATE disconnects other sessions
   (e.g. a second SSMS window) so the DROP is not blocked.
   ---------------------------------------------------------------------
USE master;
ALTER DATABASE ParkingDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE ParkingDB;
CREATE DATABASE ParkingDB;
ALTER DATABASE ParkingDB SET RECOVERY SIMPLE;
--------------------------------------------------------------------- */

/* ---- Check it worked ---- */
SELECT name, state_desc, recovery_model_desc, compatibility_level
FROM sys.databases
WHERE name = N'ParkingDB';
GO
