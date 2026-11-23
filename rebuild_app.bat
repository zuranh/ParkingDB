@echo off
REM ==================================================================
REM  rebuild_app.bat  -  builds everything:
REM    1. the React front end  (app\parking-client  ->  app\ParkingWeb\wwwroot)
REM    2. the C# Web API       (app\ParkingWeb, Release)
REM  run_app.bat calls it automatically the first time.
REM  Run it yourself after changing code. Close the
REM  "ParkingDB web server" window first, or step 2 fails.
REM ==================================================================
where npm >nul 2>nul
if errorlevel 1 (
  echo Node.js is not installed - it is needed to build the React front end.
  echo Install Node.js LTS from https://nodejs.org  then try again.
  pause
  exit /b 1
)
where dotnet >nul 2>nul
if errorlevel 1 (
  echo The .NET SDK is not installed.
  echo Install the .NET 8 SDK from https://dotnet.microsoft.com/download
  echo then try again.
  pause
  exit /b 1
)

echo [1/2] Building the React front end...
cd /d "%~dp0app\parking-client"
if not exist node_modules (
  echo       First time: downloading React and Vite - about a minute...
  call npm install
  if errorlevel 1 goto failed
)
call npm run build
if errorlevel 1 goto failed

echo [2/2] Building the C# Web API...
cd /d "%~dp0app\ParkingWeb"
dotnet build -c Release -v q
if errorlevel 1 goto failed

echo.
echo Build finished.
if not "%1"=="nopause" pause
exit /b 0

:failed
echo.
echo BUILD FAILED - send a screenshot of the red lines above.
echo If it says a file is locked: close the ParkingDB web server window first.
pause
exit /b 1
