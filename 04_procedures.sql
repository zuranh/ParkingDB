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
