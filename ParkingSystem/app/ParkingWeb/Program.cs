using ParkingWeb.Data;

// =====================================================================
// ParkingWeb - the Web API between the browser and SQL Server.
//
//   Browser (wwwroot: HTML/CSS/JS)  --HTTP/JSON-->  this program  --ADO.NET-->  SQL Server
//
// The browser NEVER talks to the database and never sees the connection
// string. Every /api/... address below calls exactly ONE stored procedure
// or reads ONE view through ParkingRepository. All business rules stay in
// the database; this file only translates HTTP <-> procedure calls.
// =====================================================================

var builder = WebApplication.CreateBuilder(args);

// Listen only on this computer: nobody else on the network can call the API.
builder.WebHost.UseUrls("http://localhost:5000");

builder.Services.AddSingleton<ParkingRepository>();

var app = builder.Build();

// ---------------------------------------------------------------------
// Error handling for every request.
// A refusal from the database (THROW 50001-50009, permission, login) is a
// ParkingException: it goes back to the browser as HTTP 400 with the
// database's own message and number, e.g.
//   { "error": "Vehicle B 123 is already parked.", "number": 50002 }
// Anything unexpected becomes HTTP 500 with its message.
// ---------------------------------------------------------------------
app.Use(async (context, next) =>
{
    try
    {
        await next();
    }
    catch (ParkingException ex)
    {
        context.Response.StatusCode = StatusCodes.Status400BadRequest;
        await context.Response.WriteAsJsonAsync(new { error = ex.Message, number = ex.Number });
    }
    catch (Exception ex)
    {
        context.Response.StatusCode = StatusCodes.Status500InternalServerError;
        await context.Response.WriteAsJsonAsync(new { error = ex.Message, number = 0 });
    }
});

// Serve the front end: "/" returns wwwroot/index.html, plus its .css and .js.
app.UseDefaultFiles();
app.UseStaticFiles();

// ---------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------

// usp_GetDashboard - headline numbers
app.MapGet("/api/dashboard", (ParkingRepository repo) => repo.GetDashboard());

// vw_SpaceStatus - every space
app.MapGet("/api/spaces", (ParkingRepository repo) => repo.GetSpaceStatus());

// vw_SpaceStatus (distinct types) - for the Entry screen's buttons
app.MapGet("/api/space-types", (ParkingRepository repo) => repo.GetSpaceTypes());

// vw_ActiveSessions - cars parked now
app.MapGet("/api/active-sessions", (ParkingRepository repo) => repo.GetActiveSessions());

// vw_DailyRevenue - last N days with payments
app.MapGet("/api/revenue", (ParkingRepository repo, int? days) => repo.GetDailyRevenue(Math.Clamp(days ?? 14, 1, 366)));

// usp_SearchSessions - History search with optional filters and paging
app.MapGet("/api/sessions", (ParkingRepository repo, string? plate, DateTime? from, DateTime? to,
                              string? status, int? page, int? pageSize) =>
    repo.SearchSessions(plate, from, to, status, page ?? 1, pageSize ?? 50));

// usp_GetVehicleHistory - every visit of one car
app.MapGet("/api/vehicles/{plate}/history", (ParkingRepository repo, string plate) =>
    repo.GetVehicleHistory(plate));

// ---------------------------------------------------------------------
// Writing (each is one stored procedure = one transaction in the database)
// ---------------------------------------------------------------------

// usp_RegisterVehicle
app.MapPost("/api/vehicles", (ParkingRepository repo, RegisterRequest r) =>
    new { vehicleId = repo.RegisterVehicle(r.LicensePlate ?? "", r.OwnerName ?? "", r.Phone, r.VehicleType ?? "") });

// usp_VehicleEntry
app.MapPost("/api/entries", (ParkingRepository repo, EntryRequest r) =>
    repo.VehicleEntry(r.LicensePlate ?? "", r.SpaceTypeId));

// usp_VehicleExit
app.MapPost("/api/exits", (ParkingRepository repo, ExitRequest r) =>
    repo.VehicleExit(r.LicensePlate ?? ""));

// usp_RecordPayment (the amount is NOT sent: the database takes it from the session)
app.MapPost("/api/payments", (ParkingRepository repo, PaymentRequest r) =>
    new { paymentId = repo.RecordPayment(r.SessionId, r.Method ?? "") });

// usp_CancelSession
app.MapPost("/api/sessions/{id:int}/cancel", (ParkingRepository repo, int id) =>
{
    repo.CancelSession(id);
    return Results.Ok(new { cancelled = id });
});

app.Run();

// ---------------------------------------------------------------------
// The JSON bodies the browser sends (property names are matched without
// caring about upper/lower case: "licensePlate" fills LicensePlate).
// ---------------------------------------------------------------------
record RegisterRequest(string? LicensePlate, string? OwnerName, string? Phone, string? VehicleType);
record EntryRequest(string? LicensePlate, byte? SpaceTypeId);
record ExitRequest(string? LicensePlate);
record PaymentRequest(int SessionId, string? Method);
