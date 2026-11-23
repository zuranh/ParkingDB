using System.Data;
using Microsoft.Data.SqlClient;
using ParkingWeb.Models;

namespace ParkingWeb.Data;

/// <summary>
/// The ONLY class that talks to the database, and the only place with SQL text.
/// One method per stored procedure / view.
///  - Procedures: always CommandType.StoredProcedure. The app never sends
///    INSERT / UPDATE / DELETE: all business logic lives in the database.
///  - Views: a fixed SELECT with typed parameters (the role may only read views).
///  - Every parameter has an explicit SqlDbType and size. Values are sent as
///    DATA, separate from the command text, so SQL injection is impossible.
///  - Every connection, command and reader is in a "using" block (closed even
///    when an error happens).
///  - SqlException 50001-50009 becomes a ParkingException with the database's
///    friendly message.
/// </summary>
public sealed class ParkingRepository
{
    // =====================================================================
    // Writing procedures
    // =====================================================================

    /// <summary>dbo.usp_RegisterVehicle - returns the new VehicleID.</summary>
    public int RegisterVehicle(string licensePlate, string ownerName, string? phone, string vehicleType) =>
        Execute(connection =>
        {
            using SqlCommand cmd = Procedure(connection, "dbo.usp_RegisterVehicle");
            cmd.Parameters.Add(In("@LicensePlate", SqlDbType.NVarChar, 50, licensePlate));
            cmd.Parameters.Add(In("@OwnerName", SqlDbType.NVarChar, 100, ownerName));
            cmd.Parameters.Add(In("@Phone", SqlDbType.VarChar, 20, phone));
            cmd.Parameters.Add(In("@VehicleType", SqlDbType.VarChar, 20, vehicleType));
            SqlParameter vehicleId = cmd.Parameters.Add(Out("@VehicleID", SqlDbType.Int));

            cmd.ExecuteNonQuery();
            return (int)vehicleId.Value;           // output parameters are read AFTER execution
        });

    /// <summary>dbo.usp_VehicleEntry - spaceTypeId null = any type.</summary>
    public EntryResult VehicleEntry(string licensePlate, byte? spaceTypeId) =>
        Execute(connection =>
        {
            using SqlCommand cmd = Procedure(connection, "dbo.usp_VehicleEntry");
            cmd.Parameters.Add(In("@LicensePlate", SqlDbType.NVarChar, 50, licensePlate));
            cmd.Parameters.Add(In("@SpaceTypeID", SqlDbType.TinyInt, spaceTypeId));
            // @DebugDelaySeconds is not sent: it keeps its default 0 (demo-only parameter).
            SqlParameter sessionId = cmd.Parameters.Add(Out("@SessionID", SqlDbType.Int));
            SqlParameter spaceCode = cmd.Parameters.Add(Out("@SpaceCode", SqlDbType.VarChar, 10));

            cmd.ExecuteNonQuery();
            return new EntryResult((int)sessionId.Value, (string)spaceCode.Value);
        });

    /// <summary>dbo.usp_VehicleExit - closes the active session, returns its fee.</summary>
    public ExitResult VehicleExit(string licensePlate) =>
        Execute(connection =>
        {
            using SqlCommand cmd = Procedure(connection, "dbo.usp_VehicleExit");
            cmd.Parameters.Add(In("@LicensePlate", SqlDbType.NVarChar, 50, licensePlate));
            SqlParameter sessionId = cmd.Parameters.Add(Out("@SessionID", SqlDbType.Int));
            SqlParameter fee = cmd.Parameters.Add(OutDecimal("@Fee", 8, 2));

            cmd.ExecuteNonQuery();
            return new ExitResult((int)sessionId.Value, (decimal)fee.Value);
        });

    /// <summary>dbo.usp_RecordPayment - the amount is taken from the session by the database.</summary>
    public int RecordPayment(int sessionId, string method) =>
        Execute(connection =>
        {
            using SqlCommand cmd = Procedure(connection, "dbo.usp_RecordPayment");
            cmd.Parameters.Add(In("@SessionID", SqlDbType.Int, sessionId));
            cmd.Parameters.Add(In("@Method", SqlDbType.VarChar, 10, method));
            SqlParameter paymentId = cmd.Parameters.Add(Out("@PaymentID", SqlDbType.Int));

            cmd.ExecuteNonQuery();
            return (int)paymentId.Value;
        });

    /// <summary>dbo.usp_CancelSession</summary>
    public void CancelSession(int sessionId) =>
        Execute(connection =>
        {
            using SqlCommand cmd = Procedure(connection, "dbo.usp_CancelSession");
            cmd.Parameters.Add(In("@SessionID", SqlDbType.Int, sessionId));
            cmd.ExecuteNonQuery();
        });

    // =====================================================================
    // Reading procedures
    // =====================================================================

    /// <summary>dbo.usp_GetDashboard - one row of headline numbers.</summary>
    public DashboardInfo GetDashboard() =>
        Execute(connection =>
        {
            using SqlCommand cmd = Procedure(connection, "dbo.usp_GetDashboard");
            using SqlDataReader r = cmd.ExecuteReader();
            if (!r.Read())
                throw new InvalidOperationException("usp_GetDashboard returned no row.");

            return new DashboardInfo(
                TotalSpaces:        r.GetInt32(r.GetOrdinal("TotalSpaces")),
                InServiceSpaces:    r.GetInt32(r.GetOrdinal("InServiceSpaces")),
                FreeSpaces:         r.GetInt32(r.GetOrdinal("FreeSpaces")),
                OccupiedSpaces:     r.GetInt32(r.GetOrdinal("OccupiedSpaces")),
                OutOfServiceSpaces: r.GetInt32(r.GetOrdinal("OutOfServiceSpaces")),
                ActiveSessions:     r.GetInt32(r.GetOrdinal("ActiveSessions")),
                PaymentsToday:      r.GetInt32(r.GetOrdinal("PaymentsToday")),
                RevenueToday:       r.GetDecimal(r.GetOrdinal("RevenueToday")));
        });

    /// <summary>dbo.usp_SearchSessions - optional filters, newest first, one page.</summary>
    public SearchPage SearchSessions(string? licensePlate, DateTime? fromDate, DateTime? toDate,
                                     string? status, int pageNumber, int pageSize) =>
        Execute(connection =>
        {
            using SqlCommand cmd = Procedure(connection, "dbo.usp_SearchSessions");
            cmd.Parameters.Add(In("@LicensePlate", SqlDbType.NVarChar, 50, licensePlate));
            cmd.Parameters.Add(In("@FromDate", SqlDbType.Date, fromDate?.Date));
            cmd.Parameters.Add(In("@ToDate", SqlDbType.Date, toDate?.Date));
            cmd.Parameters.Add(In("@Status", SqlDbType.VarChar, 10, status));
            cmd.Parameters.Add(In("@PageNumber", SqlDbType.Int, pageNumber));
            cmd.Parameters.Add(In("@PageSize", SqlDbType.Int, pageSize));

            var rows = new List<SessionSearchRow>();
            int totalRows = 0;
            using SqlDataReader r = cmd.ExecuteReader();
            while (r.Read())
            {
                rows.Add(new SessionSearchRow(
                    SessionID:     r.GetInt32(r.GetOrdinal("SessionID")),
                    LicensePlate:  r.GetString(r.GetOrdinal("LicensePlate")),
                    OwnerName:     r.GetString(r.GetOrdinal("OwnerName")),
                    SpaceCode:     r.GetString(r.GetOrdinal("SpaceCode")),
                    EntryTime:     r.GetDateTime(r.GetOrdinal("EntryTime")),
                    ExitTime:      NullableDateTime(r, "ExitTime"),
                    Status:        r.GetString(r.GetOrdinal("Status")),
                    Fee:           NullableDecimal(r, "Fee"),
                    PaymentMethod: NullableString(r, "PaymentMethod")));
                totalRows = r.GetInt32(r.GetOrdinal("TotalRows"));   // same value on every row
            }
            return new SearchPage(rows, totalRows);
        });

    /// <summary>dbo.usp_GetVehicleHistory - every session of one vehicle.</summary>
    public List<VehicleHistoryRow> GetVehicleHistory(string licensePlate) =>
        Execute(connection =>
        {
            using SqlCommand cmd = Procedure(connection, "dbo.usp_GetVehicleHistory");
            cmd.Parameters.Add(In("@LicensePlate", SqlDbType.NVarChar, 50, licensePlate));

            var rows = new List<VehicleHistoryRow>();
            using SqlDataReader r = cmd.ExecuteReader();
            while (r.Read())
            {
                rows.Add(new VehicleHistoryRow(
                    SessionID:     r.GetInt32(r.GetOrdinal("SessionID")),
                    SpaceCode:     r.GetString(r.GetOrdinal("SpaceCode")),
                    SpaceType:     r.GetString(r.GetOrdinal("SpaceType")),
                    EntryTime:     r.GetDateTime(r.GetOrdinal("EntryTime")),
                    ExitTime:      NullableDateTime(r, "ExitTime"),
                    Status:        r.GetString(r.GetOrdinal("Status")),
                    Fee:           NullableDecimal(r, "Fee"),
                    PaymentMethod: NullableString(r, "PaymentMethod"),
                    PaidAt:        NullableDateTime(r, "PaidAt")));
            }
            return rows;
        });

    // =====================================================================
    // Views (read-only)
    // =====================================================================

    /// <summary>dbo.vw_SpaceStatus - every space.</summary>
    public List<SpaceStatusRow> GetSpaceStatus() =>
        Execute(connection =>
        {
            using SqlCommand cmd = Query(connection,
                "SELECT SpaceCode, FloorNo, SpaceType, HourlyRate, IsOccupied, InService, CurrentPlate, OccupiedSince " +
                "FROM dbo.vw_SpaceStatus ORDER BY SpaceID;");

            var rows = new List<SpaceStatusRow>();
            using SqlDataReader r = cmd.ExecuteReader();
            while (r.Read())
            {
                rows.Add(new SpaceStatusRow(
                    SpaceCode:     r.GetString(r.GetOrdinal("SpaceCode")),
                    FloorNo:       r.GetByte(r.GetOrdinal("FloorNo")),
                    SpaceType:     r.GetString(r.GetOrdinal("SpaceType")),
                    HourlyRate:    r.GetDecimal(r.GetOrdinal("HourlyRate")),
                    IsOccupied:    r.GetBoolean(r.GetOrdinal("IsOccupied")),
                    InService:     r.GetBoolean(r.GetOrdinal("InService")),
                    CurrentPlate:  NullableString(r, "CurrentPlate"),
                    OccupiedSince: NullableDateTime(r, "OccupiedSince")));
            }
            return rows;
        });

    /// <summary>The space types, read from dbo.vw_SpaceStatus (for the Entry screen).</summary>
    public List<SpaceTypeItem> GetSpaceTypes() =>
        Execute(connection =>
        {
            using SqlCommand cmd = Query(connection,
                "SELECT DISTINCT SpaceTypeID, SpaceType, HourlyRate FROM dbo.vw_SpaceStatus ORDER BY SpaceTypeID;");

            var rows = new List<SpaceTypeItem>();
            using SqlDataReader r = cmd.ExecuteReader();
            while (r.Read())
            {
                rows.Add(new SpaceTypeItem(
                    SpaceTypeID: r.GetByte(r.GetOrdinal("SpaceTypeID")),
                    TypeName:    r.GetString(r.GetOrdinal("SpaceType")),
                    HourlyRate:  r.GetDecimal(r.GetOrdinal("HourlyRate"))));
            }
            return rows;
        });

    /// <summary>dbo.vw_ActiveSessions - cars parked right now, longest-parked first.</summary>
    public List<ActiveSessionRow> GetActiveSessions() =>
        Execute(connection =>
        {
            using SqlCommand cmd = Query(connection,
                "SELECT SessionID, LicensePlate, OwnerName, VehicleType, SpaceCode, SpaceType, " +
                "EntryTime, MinutesParked, CurrentFee " +
                "FROM dbo.vw_ActiveSessions ORDER BY EntryTime;");

            var rows = new List<ActiveSessionRow>();
            using SqlDataReader r = cmd.ExecuteReader();
            while (r.Read())
            {
                rows.Add(new ActiveSessionRow(
                    SessionID:     r.GetInt32(r.GetOrdinal("SessionID")),
                    LicensePlate:  r.GetString(r.GetOrdinal("LicensePlate")),
                    OwnerName:     r.GetString(r.GetOrdinal("OwnerName")),
                    VehicleType:   r.GetString(r.GetOrdinal("VehicleType")),
                    SpaceCode:     r.GetString(r.GetOrdinal("SpaceCode")),
                    SpaceType:     r.GetString(r.GetOrdinal("SpaceType")),
                    EntryTime:     r.GetDateTime(r.GetOrdinal("EntryTime")),
                    MinutesParked: r.GetInt32(r.GetOrdinal("MinutesParked")),
                    CurrentFee:    NullableDecimal(r, "CurrentFee")));
            }
            return rows;
        });

    /// <summary>dbo.vw_DailyRevenue - the most recent N days, newest first.</summary>
    public List<DailyRevenueRow> GetDailyRevenue(int days) =>
        Execute(connection =>
        {
            using SqlCommand cmd = Query(connection,
                "SELECT TOP (@Days) PayDate, PaymentCount, TotalAmount " +
                "FROM dbo.vw_DailyRevenue ORDER BY PayDate DESC;");
            cmd.Parameters.Add(In("@Days", SqlDbType.Int, days));

            var rows = new List<DailyRevenueRow>();
            using SqlDataReader r = cmd.ExecuteReader();
            while (r.Read())
            {
                rows.Add(new DailyRevenueRow(
                    PayDate:      r.GetDateTime(r.GetOrdinal("PayDate")),
                    PaymentCount: r.GetInt32(r.GetOrdinal("PaymentCount")),
                    TotalAmount:  r.GetDecimal(r.GetOrdinal("TotalAmount"))));
            }
            return rows;
        });

    // =====================================================================
    // Helpers
    // =====================================================================

    private static SqlCommand Procedure(SqlConnection connection, string name) =>
        new(name, connection) { CommandType = CommandType.StoredProcedure };

    private static SqlCommand Query(SqlConnection connection, string sql) =>
        new(sql, connection) { CommandType = CommandType.Text };

    /// <summary>Input parameter with a size (strings). null is sent as SQL NULL.</summary>
    private static SqlParameter In(string name, SqlDbType type, int size, object? value) =>
        new(name, type, size) { Value = value ?? DBNull.Value };

    /// <summary>Input parameter without a size (numbers, dates).</summary>
    private static SqlParameter In(string name, SqlDbType type, object? value) =>
        new(name, type) { Value = value ?? DBNull.Value };

    private static SqlParameter Out(string name, SqlDbType type, int size = 0)
    {
        var p = new SqlParameter(name, type) { Direction = ParameterDirection.Output };
        if (size > 0) p.Size = size;
        return p;
    }

    private static SqlParameter OutDecimal(string name, byte precision, byte scale) =>
        new(name, SqlDbType.Decimal) { Direction = ParameterDirection.Output, Precision = precision, Scale = scale };

    private static string? NullableString(SqlDataReader r, string column)
    {
        int i = r.GetOrdinal(column);
        return r.IsDBNull(i) ? null : r.GetString(i);
    }

    private static DateTime? NullableDateTime(SqlDataReader r, string column)
    {
        int i = r.GetOrdinal(column);
        return r.IsDBNull(i) ? null : r.GetDateTime(i);
    }

    private static decimal? NullableDecimal(SqlDataReader r, string column)
    {
        int i = r.GetOrdinal(column);
        return r.IsDBNull(i) ? null : r.GetDecimal(i);
    }

    /// <summary>Opens a connection, runs the work, closes the connection, and
    /// turns database errors into messages a user can understand.</summary>
    private static T Execute<T>(Func<SqlConnection, T> work)
    {
        try
        {
            using SqlConnection connection = Db.OpenConnection();
            return work(connection);
        }
        catch (SqlException ex)
        {
            throw Translate(ex);
        }
    }

    private static void Execute(Action<SqlConnection> work) =>
        Execute<object?>(connection => { work(connection); return null; });

    private static Exception Translate(SqlException ex) => ex.Number switch
    {
        // Our own business errors: the database already wrote a friendly message.
        >= 50001 and <= 50009 => new ParkingException(ex.Number, ex.Message, ex),

        229 => new ParkingException(ex.Number,
            "The application login is not allowed to do this (permission denied).\n" +
            "Run 07_security.sql again.", ex),

        18456 => new ParkingException(ex.Number,
            "Login failed for parking_app_login.\n\n" +
            "Check the password in appsettings.json, and that SQL Server allows " +
            "\"SQL Server and Windows Authentication mode\" (see README).", ex),

        4060 => new ParkingException(ex.Number,
            "Cannot open the database ParkingDB. Does it exist, and was 07_security.sql run?", ex),

        // -2 = "Execution Timeout Expired": the query waited 30 s. Almost always
        // another SSMS window holding an open transaction (locks) on these tables.
        -2 => new ParkingException(ex.Number,
            "The database did not answer within 30 seconds.\n\n" +
            "Most likely another SSMS query window has an unfinished transaction that " +
            "locks the tables (for example a query stopped with the red Stop button). " +
            "Close the other SSMS query windows (answer No to \"commit?\"), then press Refresh.\n" +
            "To see which window it is: run sql\\99_diagnose.sql.", ex),

        2 or 53 or -1 or 258 or 10061 => new ParkingException(ex.Number,
            "Cannot reach SQL Server. Is the SQL Server service running, and is the server name " +
            "in the connection string correct?\n\n" + ex.Message, ex),

        _ => ex
    };
}
