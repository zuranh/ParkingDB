@echo off
REM ==================================================================
REM  set_password.bat  -  run ONCE (double-click).
REM  Saves the app's connection string in the Windows environment
REM  variable PARKING_DB_CONNECTION, for your user on THIS computer.
REM  The password is never stored in the project files.
REM ==================================================================
echo.
echo Parking app - save the database connection on this computer
echo.
set /p PW=Type the SAME password you put in SETUP_ALL.sql, then press Enter: 
if "%PW%"=="" (
  echo No password typed. Nothing was saved.
  pause
  exit /b 1
)
setx PARKING_DB_CONNECTION "Server=localhost;Database=ParkingDB;User ID=parking_app_login;Password=%PW%;Encrypt=True;TrustServerCertificate=True;Application Name=ParkingApp" >nul
if errorlevel 1 (
  echo Could not save it. Try running this file again.
) else (
  echo.
  echo Saved. You can now double-click run_app.bat
  echo (If VS Code or a terminal was open, close and reopen it first.)
)
echo.
pause
