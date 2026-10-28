@echo off
setlocal
cd /d "%~dp0"
title Client Launcher
set PORT=4000

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
echo   Client Launcher
echo -----------------------------------------------------
echo   1. Start client   (production)
echo   2. Start client   (dev / auto-reload)
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
set MODE=node launcher.js
goto launch

:start_dev
set MODE=node --watch launcher.js
goto launch

:launch
netstat -ano | findstr ":%PORT% " | findstr "LISTENING" >nul 2>&1
if not errorlevel 1 (
  echo Client already running on port %PORT%.
  goto open_console
)
echo [1/3] Starting client on port %PORT%...
start "client" cmd /k "%MODE%"
echo [2/3] Waiting for client to be ready...
set /a tries=0
:wait
ping -n 2 127.0.0.1 >nul
set /a tries+=1
curl.exe -s -o nul "http://localhost:%PORT%/api/health"
if not errorlevel 1 goto ready
if %tries% geq 20 goto slow
goto wait

:slow
echo Warning: client not ready after 20 tries, opening console anyway.
:ready
echo [3/3] Client is ready.
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
echo [check] Verifying server connection...
curl.exe -s -f -o nul "http://localhost:%PORT%/api/route/services"
if errorlevel 1 goto server_down
goto show_console

:server_down
echo.
echo =====================================================
echo   WARNING: client is running, but the SERVER is unreachable
echo -----------------------------------------------------
echo   Details and Chinese guidance: see the "client" window
echo   (the launcher prints the server address and the fix steps),
echo   or read client\README.md
echo.
echo   Quick fix:
echo     1) edit  client\data\routing-ips.txt
echo        - set "primary": true on the line of your server
echo     2) or run: node launcher.js --server=IP:PORT
echo     3) check the server is started, its port 3000 is allowed
echo        through the firewall, and both machines can reach
echo        each other
echo =====================================================
echo.

:show_console
echo Opening console...
start "" "http://localhost:%PORT%/"
echo.
echo Console: http://localhost:%PORT%/
echo Close the "client" window to stop the client.
ping -n 6 127.0.0.1 >nul
endlocal
exit /b 0
