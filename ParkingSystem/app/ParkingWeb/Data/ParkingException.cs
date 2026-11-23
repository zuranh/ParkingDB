namespace ParkingWeb.Data;

/// <summary>
/// A business error raised by the database (THROW 50001-50009) or a known
/// problem (permission, login), already turned into a message for the user.
/// </summary>
public sealed class ParkingException(int number, string message, Exception inner)
    : Exception(message, inner)
{
    /// <summary>The SQL Server error number, e.g. 50002 = vehicle already parked.</summary>
    public int Number { get; } = number;
}
