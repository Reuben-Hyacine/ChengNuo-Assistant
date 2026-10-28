@echo off
setlocal
cd /d "%~dp0"
title Server Launcher
if "%PORT%"=="" set PORT=3000

if not exist "node_modules\express" (
  echo [0/4] Installing dependencies...
  call npm.cmd install
  if errorlevel 1 (
    echo Dependency install failed.
    pause
    exit /b 1
  )
)

:menu
cls
echo =====================================================
echo   Server Launcher
echo -----------------------------------------------------
echo   1. Start server   (production)
echo   2. Start server   (dev / auto-reload)
echo   3. Install dependencies only
echo   Q. Quit
echo =====================================================
set /p choice=Select [1/2/3/Q]: 

if /i "%choice%"=="1" goto start_normal
if /i "%choice%"=="2" goto start_dev
if /i "%choice%"=="3" goto install_only
if /i "%choice%"=="Q" exit /b 0
echo Invalid choice, try again.
ping -n 2 127.0.0.1 >nul
goto menu

:start_normal
set MODE=node src/server.js
goto launch

:start_dev
set MODE=node --watch src/server.js
goto launch

:launch
netstat -ano | findstr ":%PORT% " | findstr "LISTENING" >nul 2>&1
if not errorlevel 1 (
  echo Server already running on port %PORT%.
  goto open_console
)
echo [1/3] Starting server on port %PORT%...
start "server" cmd /k "%MODE%"
echo [2/3] Waiting for server to be ready...
set /a tries=0
:wait
ping -n 2 127.0.0.1 >nul
set /a tries+=1
curl.exe -s -o nul "http://localhost:%PORT%/api/health"
if not errorlevel 1 goto ready
if %tries% geq 20 goto slow
goto wait

:slow
echo Warning: server not ready after 20 tries, opening console anyway.
:ready
echo [3/3] Server is ready.
goto open_console

:install_only
echo Installing dependencies...
call npm.cmd install
if errorlevel 1 (
  echo Dependency install failed.
  pause
  exit /b 1
)
echo Done.
pause
exit /b 0

:open_console
echo Opening console...
start "" "http://localhost:%PORT%/"
echo.
echo Console: http://localhost:%PORT%/
echo Close the "server" window to stop the server.
ping -n 6 127.0.0.1 >nul
endlocal
exit /b 0