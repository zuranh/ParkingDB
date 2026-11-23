# Parking Management System — ParkingDB

GIN401 Advanced Database Lab · Microsoft SQL Server (2016 or newer) · C# / ADO.NET front end

The database is the project. All business rules live in SQL Server: constraints, stored procedures, triggers and security. The C# app (`app/`) is only a thin window onto it. It calls stored procedures and reads views, and never sends its own table SQL.

---

## Quick start (the short way)

**Once:**

1. **Allow SQL logins** (SSMS): right-click `localhost` at the top of Object Explorer → **Properties** → **Security** → **SQL Server and Windows Authentication mode** → OK. Right-click `localhost` → **Restart** → Yes.
2. **Build the database**: open `sql\SETUP_ALL.sql` in SSMS → menu **Query → SQLCMD Mode** → on line 22 replace `CHANGE_ME` with your password (e.g. `Parking#2026app`) → **F5** → the last grid says **READY** on every line → close the file **without saving**.
3. **Give the app the password**: double-click **`set_password.bat`** and type the same password.

**Every time:** double-click **`run_app.bat`**. The first time it builds the React front end and the C# Web API (a few minutes). A black "ParkingDB web server" window opens (keep it open; closing it stops the app) and your browser opens **http://localhost:5000**.

Needs, once: the **.NET 8 SDK** (dotnet.microsoft.com/download) and **Node.js LTS** (nodejs.org). Changed any code? Close the server window and double-click `rebuild_app.bat`.

`SETUP_ALL.sql` is also the "start over" button: it wipes and rebuilds everything. The numbered scripts below are the same code, one topic per file, for reading, grading and the demos.

---

## 1. What is in this folder

```
ParkingSystem/
  README.md                      <- this file
  run_app.bat                    double-click: starts the app and opens the browser
  rebuild_app.bat                double-click after changing code (builds React + C#)
  set_password.bat               double-click once: saves the app's connection string
  sql/
    00_create_database.sql       creates ParkingDB
    01_schema.sql                6 tables, all constraints, 2 filtered unique indexes
    02_seed_data.sql             test data: 300 spaces, 5,000 cars, 120,000+ sessions
    03_functions_views.sql       fee function + 3 views
    04_procedures.sql            the 8 stored procedures the app uses
    05_triggers.sql              audit-history triggers + "payments cannot be deleted"
    06_indexes_performance.sql   before/after index measurements
    07_security.sql              restricted app login, role, permissions, proof
    08_tests.sql                 ~75 automatic tests, each PASS / FAIL
    09_concurrency_demo.sql      two-window locking demos A, B, C
    99_diagnose.sql              helper: finds windows holding locks / open transactions
    SETUP_ALL.sql                ONE file = 00 + 01-05 + the indexes of 06 + 07 (quick start)
    REBUILD_ALL.sql              01-05 only (no indexes, no security)
  docs/                          (step 10) EXPLAINED.md, ER_diagram.md
  app/parking-client/            React front end (Vite)
  app/ParkingWeb/                C# / ADO.NET Web API (backend)
```

**Each file is separate.** Open each one on its own in SSMS (File → Open → File, or drag it into SSMS) and run it as a whole with **F5 / Execute**. Do **not** paste them all into one window. A few of them need special handling (06, 07 and 09, see below), and running them one by one means an error points to the right script.

---

## 2. Before you start

- SQL Server 2016 or newer and SSMS. Developed on SQL Server 2025 (17.x).
- You are connected in SSMS as an administrator (your Windows account on your own PC is fine).
- At the top of every SSMS window, the database dropdown does not matter: every script starts with `USE ...` itself.

---

## 3. Run order — quick list

| # | File | How to run | Takes |
|---|------|-----------|-------|
| 1 | `00_create_database.sql` | open, F5 | 1 s |
| 2 | `01_schema.sql` | open, F5 | 1 s |
| 3 | `02_seed_data.sql` | open, F5 | 5–20 s |
| 4 | `03_functions_views.sql` | open, F5 | 1 s |
| 5 | `04_procedures.sql` | open, F5 | 1 s |
| 6 | `05_triggers.sql` | open, F5 | 1 s |
| 7 | `06_indexes_performance.sql` | **Ctrl+M first**, then F5 | 5–10 s |
| 8 | `07_security.sql` | **SQLCMD Mode + password line**, then F5 | 1 s |
| 9 | `08_tests.sql` | open, F5 (re-run any time) | 2–5 s |
| 10 | `09_concurrency_demo.sql` | F5 once for setup, then **two windows** by hand | a few min |

Plain numeric order (00 → 09) also works. The table above is simply the order used during development.

---

## 4. Each script: what to do and what you should see

### 00_create_database.sql
Run it. One result row: `ParkingDB | ONLINE | SIMPLE`.
Safe to re-run: it only creates the database if it is missing.

### 01_schema.sql
Run it. The first result grid has **9 lines, all PASS** (6 tables, 6 PKs, 4 FKs, 4 UNIQUE, 13 CHECK, 9 DEFAULT, 2 filtered unique indexes, no extra indexes yet, no cascading FKs). The second grid lists every constraint.

⚠ Re-running it **drops all tables and data**. Afterwards you must run 02, 03, 04, 05 (and 06, 07) again.

### 02_seed_data.sql
Run it. Two grids:
- Row counts: 4 / 300 / 5,000 / ~120,040 sessions (~40 Active, ~1,200 Cancelled) / ~118,000 payments / AuditLog 0. All **PASS**.
- 8 consistency checks, all **0 bad rows, PASS** (no space holds two cars at once, no car is in two places at once, every paid amount = fee, …).

It only works on **empty** tables. If it says *"ParkingDB already contains data"*, run `01` first, then `02`.
Design choice: `02` creates `fn_CalculateFee` itself if it does not exist yet, because the seed data needs the fee rule before `03` has run. `03` then replaces it with the identical official definition.

### 03_functions_views.sql
Run it. First grid: 9 fee tests at the edges (10 min free, 10 min 1 s → 2.00, 61 min → 4.00, …), **all PASS**. Then sample rows from the three views.

### 04_procedures.sql
Run it. It creates the 8 procedures, then runs a hand test: register `  test-001 ` (stored as `TEST-001`), entry, a parked car exits with a fee, it pays, history, dashboard, search. The last grid says **PASS – entry -> exit -> payment works**. The test is rolled back, so nothing changes.

### 05_triggers.sql
Run it. First grid: **12 tests, all PASS** (entry/exit/payment/vehicle/space changes each write the expected audit row; occupancy flips are not logged; one UPDATE of 5 rows writes 5 audit rows; deleting a payment is refused with 50009). Second grid: the audit rows those tests produced, with old/new values as JSON. The tests are rolled back, so the AuditLog stays empty.

### 06_indexes_performance.sql
1. Press **Ctrl+M** (Query → Include Actual Execution Plan).
2. F5.
3. **Messages tab**: under each `===== BEFORE Qx` / `===== AFTER Qx` heading, note `logical reads` and `elapsed time`.
   **Execution plan tab**: note the operator (Clustered Index Scan before, Index Seek after).
4. Fill in the results table in the comments at the bottom of the file.

Re-runnable: it drops its own indexes first, so the "before" numbers are always honest. Logical reads are the number to trust; milliseconds vary from run to run.

### 07_security.sql — needs two extra steps
1. **Allow SQL logins on the server** (once): Object Explorer → right-click the server → Properties → Security → *SQL Server and Windows Authentication mode* → OK → right-click the server → **Restart**. The script warns you if this is still off.
2. In the query window: menu **Query → SQLCMD Mode** (the editor background changes).
3. Add this as the **first line** of the window, with your own strong password (and do not save the file with it):
   ```
   :setvar AppPassword "Parking#2026app"
   ```
4. F5.

If you forget SQLCMD Mode, the script stops with a clear message and changes nothing.
Result: a grid of the role's permissions, the dashboard (run as the app user), then the **proof grid, all PASS**: tables denied (229), procedures and views allowed, the unsafe demo procedure denied, the SQL-injection plates refused, and `dbo.Payments` still exists.

Why a SQL login and not Windows authentication: your own Windows account is the server administrator, so it cannot also be the *restricted* app user. The app needs its own, separate, low-privilege login. Remember the password: the C# app uses it in its connection string.

### 08_tests.sql
Run it any time after 05. The big grid lists every test (81) with Expected / Actual / Result. The last grid is the summary: **Failed = 0, Overall = PASS**.
Test groups: 1xx CHECK + FK, 2xx UNIQUE, 3xx error numbers 50001–50009, 4xx fee edges, 5xx procedures + trigger output, 6xx consistency, 7xx "the test left nothing behind".

### 09_concurrency_demo.sql — two windows
**Setup:** open the file and press F5 once. It only creates `usp_VehicleEntry_Unsafe` and the demo cars `DEMO-1`, `DEMO-2`. Everything else in the file is skipped on purpose.

**Then, for each demo:**
1. Press Ctrl+N twice to get two **new** query windows. Drag one tab to the right so they are side by side.
2. Copy the `WINDOW 1` block (from `USE ParkingDB;` down to `AS Seconds;`) into the left window, and the `WINDOW 2` block into the right window.
3. Press F5 in the left window, then **within 10 seconds** press F5 in the right window.
4. Copy the **RESULT** block into either window and run it, then do the same with the **CLEANUP** block (this un-parks DEMO-1 and DEMO-2 so the next demo can start).

| Demo | You should see |
|------|----------------|
| **A** (unsafe) | Left: parks after ~10 s. Right: **Msg 2601 … UX_Sessions_OneActivePerSpace**. Both picked the same space and the unique index refused the second one. |
| **B** (safe) | Both finish in ~10 s with **different** space codes. ~10 s and not ~20 s proves the right window skipped the locked space instead of waiting. |
| **C1** (one window) | A space marked occupied with no car in it: **GHOST**. The block repairs it afterwards. |
| **C2** (one window) | **CLEAN: rolled back, space still free**, even though the procedure failed half-way. |

Run CLEANUP before B, before C1 and before C2.

---

## 5. Starting over

To rebuild everything from scratch: run `01` → `02` → `03` → `04` → `05` → `06` → `07`, then `08` to confirm. (`00` is only needed once.)
`01` drops the tables (and with them all triggers and indexes on them). The login, user and role from `07` survive, but their permissions point at procedures that were recreated, so run `07` again as well.

---

## 6. Troubleshooting

| You see | Meaning / fix |
|---------|---------------|
| Red squiggles or a red **1** in the bottom bar of the editor | SSMS IntelliSense flags temp tables and objects that are created further down the script. Not an error, so ignore it. Only messages in the **Messages** tab count. |
| `ParkingDB already contains data` (02) | Run `01` first, then `02`. |
| `Missing end comment mark '*/'` | The file got damaged while copying. Download it again and open the file directly instead of copy-pasting. |
| `String or binary data would be truncated` | Should not happen any more (fixed in 01). If it does, re-download the file. |
| 07: `SQLCMD Mode is OFF` | Query → SQLCMD Mode, add the `:setvar` line, run again. |
| 07: `Password validation failed` | Choose a stronger password (8+ characters, upper + lower case, a digit, a symbol). |
| 09 Demo A shows no error | The right window started more than 10 s after the left one. Run CLEANUP and try again, faster. |
| 09 says `already parked` | Run the CLEANUP block. |
| `50003 No free space available` although the lot is not full | Another SSMS window still has an open transaction (usually a query stopped with the red Stop button: stopping does not roll back). Run `sql/99_diagnose.sql`, then roll back or close that window and answer **No** to "commit?". |

---

## 7. Error numbers the app shows

| Number | Meaning |
|--------|---------|
| 50001 | Vehicle is not registered (or is inactive) |
| 50002 | Vehicle is already parked |
| 50003 | No free space available |
| 50004 | Vehicle has no active session / session is not active |
| 50005 | Session is not completed, or was cancelled |
| 50006 | Session already has a payment |
| 50007 | License plate already registered |
| 50008 | Invalid input (the message says which) |
| 50009 | Payments cannot be deleted (protection trigger, not used by the app) |

---

## 8. The application: React front end + C# / ADO.NET backend

As the lab project allows (React.JS for the frontend, C# / ADO.NET for the backend, SQL Server as the DBMS), and as in the Session 08 demo:

```
React front end  (app/parking-client)          runs in the browser
   |   fetch()  HTTP + JSON   e.g. POST /api/entries {"licensePlate":"B 123"}
   v
C# Web API       (app/ParkingWeb/Program.cs)   one /api address = one stored procedure or view
   |   ADO.NET: SqlConnection, SqlCommand (StoredProcedure), typed SqlParameters
   v
SQL Server       ParkingDB                     logs in as parking_app_login: procedures + views only
```

The browser never sees SQL or the database password; the connection string lives only on the server side (environment variable `PARKING_DB_CONNECTION`).

### Files

```
app/parking-client/                 REACT FRONT END
  package.json                      React + Vite (the build tool)
  vite.config.js                    dev server on :3000 with /api forwarded to :5000;
                                    "npm run build" writes the site into ../ParkingWeb/wwwroot
  index.html                        the empty page React draws into
  src/main.jsx                      starts React
  src/App.jsx                       top bar + the five screens
  src/api.js                        the ONLY place that calls the Web API (fetch)
  src/styles.css                    the look (asphalt grey + road-marking yellow)
  src/components/ui.jsx             small pieces: Banner, Ticket, Field, Segmented buttons
  src/components/Dashboard.jsx      numbers, parking map, cars parked now (+ cancel), revenue
  src/components/Register.jsx       register a vehicle
  src/components/Entry.jsx          car arrives -> "GO TO SPACE F1-003"
  src/components/ExitPayment.jsx    car leaves -> fee -> payment
  src/components/History.jsx        search with filters and paging, full history of a plate

app/ParkingWeb/                     C# / ADO.NET BACKEND
  ParkingWeb.csproj                 ASP.NET Core (.NET 8) + Microsoft.Data.SqlClient
  Program.cs                        the Web API: every /api/... address + error handling
  Data/Db.cs                        creates connections (connection string from the env var)
  Data/ParkingRepository.cs         one method per stored procedure / view - the ONLY file with SQL
  Data/ParkingException.cs          database errors 50001-50009 turned into friendly messages
  Models/Models.cs                  the rows the API sends as JSON
  wwwroot/                          (generated) the built React site, served on :5000
```

### The API

| Method + address | Database object |
|---|---|
| GET `/api/dashboard` | usp_GetDashboard |
| GET `/api/spaces`, `/api/space-types` | vw_SpaceStatus |
| GET `/api/active-sessions` | vw_ActiveSessions |
| GET `/api/revenue?days=14` | vw_DailyRevenue |
| GET `/api/sessions?plate=&from=&to=&status=&page=&pageSize=` | usp_SearchSessions |
| GET `/api/vehicles/{plate}/history` | usp_GetVehicleHistory |
| POST `/api/vehicles` | usp_RegisterVehicle |
| POST `/api/entries` | usp_VehicleEntry |
| POST `/api/exits` | usp_VehicleExit |
| POST `/api/payments` | usp_RecordPayment |
| POST `/api/sessions/{id}/cancel` | usp_CancelSession |

A refusal from the database comes back as HTTP 400 with `{"error": "...", "number": 50002}`, and the page shows it in a red banner. Open `http://localhost:5000/api/dashboard` directly in the browser to see the raw JSON.

### Run it
- **Normal:** double-click `run_app.bat` (see Quick start). Everything is on **http://localhost:5000**.
- **While editing the React code (live reload):** start the API with `run_app.bat`, then in a terminal: `cd app\parking-client`, `npm run dev`, and open **http://localhost:3000**. Every saved change appears at once; `/api` calls are forwarded to :5000. When done, run `rebuild_app.bat` so :5000 serves the new version.

### Security in the app
- **SQL injection:** every value goes to SQL Server as a typed parameter of a stored procedure, never glued into SQL text.
- **XSS:** React writes every value (owner names, plates ...) as text, never as HTML, so typed `<script>` is shown, never run.
- **Least privilege:** the API logs in as `parking_app_login`, which can only run the procedures and read the views.
- **Only this computer:** the API listens on `localhost:5000`.
- **No password in the code:** the connection string comes from the environment variable.

### If it does not work
| You see | Fix |
|---------|-----|
| `Node.js is not installed` | Install Node.js LTS from nodejs.org, then run `run_app.bat` again. |
| The browser says the page cannot be reached | The black server window is closed, or still starting: wait 5 seconds and refresh. |
| Red banner: *Login failed for parking_app_login* | Wrong password in `set_password.bat`, or SQL logins not allowed (Quick start step 1). |
| Red banner: *No database connection string found* | Run `set_password.bat`, then close the server window and start `run_app.bat` again. |
| Red banner: *did not answer within 30 seconds* | Another SSMS window holds an open transaction: close the other query tabs (No to commit). |
| The server window closes at once | Port 5000 is used by another program, or the build failed: run `rebuild_app.bat` to see the message. |
