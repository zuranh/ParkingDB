namespace ParkingWeb.Models;

// Small read-only classes for the rows the screens show.
// "record" gives public properties, which the DataGridView displays as columns.

/// <summary>One row of usp_GetDashboard.</summary>
public sealed record DashboardInfo(
    int TotalSpaces, int InServiceSpaces, int FreeSpaces, int OccupiedSpaces,
    int OutOfServiceSpaces, int ActiveSessions, int PaymentsToday, decimal RevenueToday);

/// <summary>One row of vw_SpaceStatus.</summary>
public sealed record SpaceStatusRow(
    string SpaceCode, byte FloorNo, string SpaceType, decimal HourlyRate,
    bool IsOccupied, bool InService, string? CurrentPlate, DateTime? OccupiedSince);

/// <summary>A space type for the Entry screen's drop-down.</summary>
public sealed record SpaceTypeItem(byte SpaceTypeID, string TypeName, decimal HourlyRate)
{
    public override string ToString() => $"{TypeName}  ({HourlyRate:0.00} per hour)";
}

/// <summary>One row of vw_ActiveSessions.</summary>
public sealed record ActiveSessionRow(
    int SessionID, string LicensePlate, string OwnerName, string VehicleType,
    string SpaceCode, string SpaceType, DateTime EntryTime, int MinutesParked, decimal? CurrentFee);

/// <summary>One row of vw_DailyRevenue.</summary>
public sealed record DailyRevenueRow(DateTime PayDate, int PaymentCount, decimal TotalAmount);

/// <summary>One row of usp_SearchSessions.</summary>
public sealed record SessionSearchRow(
    int SessionID, string LicensePlate, string OwnerName, string SpaceCode,
    DateTime EntryTime, DateTime? ExitTime, string Status, decimal? Fee, string? PaymentMethod);

/// <summary>One page of search results plus the total number of matching rows.</summary>
public sealed record SearchPage(IReadOnlyList<SessionSearchRow> Rows, int TotalRows);

/// <summary>One row of usp_GetVehicleHistory.</summary>
public sealed record VehicleHistoryRow(
    int SessionID, string SpaceCode, string SpaceType, DateTime EntryTime, DateTime? ExitTime,
    string Status, decimal? Fee, string? PaymentMethod, DateTime? PaidAt);

/// <summary>Output of usp_VehicleEntry.</summary>
public sealed record EntryResult(int SessionID, string SpaceCode);

/// <summary>Output of usp_VehicleExit.</summary>
public sealed record ExitResult(int SessionID, decimal Fee);
