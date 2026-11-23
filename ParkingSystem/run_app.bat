@echo off
REM ==================================================================
REM  run_app.bat  -  double-click to start the Parking app.
REM  1. the first time: builds the React front end and the C# Web API
REM  2. starts the Web API in its own black window (close it = stop)
REM  3. opens http://localhost:5000 in your browser
REM ==================================================================
set "WEB=%~dp0app\ParkingWeb"
set "EXE=%WEB%\bin\Release\net8.0\ParkingWeb.exe"
if not exist "%WEB%\wwwroot\index.html" call "%~dp0rebuild_app.bat" nopause
if not exist "%EXE%" call "%~dp0rebuild_app.bat" nopause
if not exist "%EXE%" (
  echo The app could not be built. See the messages above.
  pause
  exit /b 1
)
cd /d "%WEB%"
start "ParkingDB web server - close this window to stop it" "%EXE%"
timeout /t 3 /nobreak >nul
start "" http://localhost:5000
