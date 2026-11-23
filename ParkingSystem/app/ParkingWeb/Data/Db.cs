using System.Text.Json;
using Microsoft.Data.SqlClient;

namespace ParkingWeb.Data;

/// <summary>
/// Creates database connections. The connection string is NEVER written in
/// the source code. It is read, in this order, from:
///   1. the environment variable PARKING_DB_CONNECTION
///   2. appsettings.json next to the .exe (git-ignored; copy
///      appsettings.example.json and put your password in it)
/// </summary>
public static class Db
{
    public const string EnvironmentVariable = "PARKING_DB_CONNECTION";

    // Lazy: read the settings once, the first time a connection is needed.
    private static readonly Lazy<string> ConnectionString = new(LoadConnectionString);

    /// <summary>Opens a new connection. Always use it inside a "using" block.
    /// (ADO.NET pools connections, so opening one per call is cheap.)</summary>
    public static SqlConnection OpenConnection()
    {
        var connection = new SqlConnection(ConnectionString.Value);
        connection.Open();
        return connection;
    }

    private static string LoadConnectionString()
    {
        string? fromEnvironment = Environment.GetEnvironmentVariable(EnvironmentVariable);
        if (!string.IsNullOrWhiteSpace(fromEnvironment))
            return fromEnvironment;

        string path = Path.Combine(AppContext.BaseDirectory, "appsettings.json");
        if (File.Exists(path))
        {
            using JsonDocument doc = JsonDocument.Parse(File.ReadAllText(path));
            if (doc.RootElement.TryGetProperty("ConnectionStrings", out JsonElement strings) &&
                strings.TryGetProperty("ParkingDb", out JsonElement value) &&
                !string.IsNullOrWhiteSpace(value.GetString()))
            {
                return value.GetString()!;
            }
        }

        throw new InvalidOperationException(
            "No database connection string found.\n\n" +
            $"Either set the environment variable {EnvironmentVariable}, or copy " +
            "appsettings.example.json to appsettings.json and put your password in it.");
    }
}
