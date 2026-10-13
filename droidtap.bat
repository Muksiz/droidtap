@echo off
rem Starts, stops, records with and updates droidtap on Windows; the
rem counterpart of droidtap.sh. Without a command (or when double-clicked) it
rem shows a menu. Usage:
rem   droidtap.bat [start ^| record [name] ^| stop ^| open ^| status ^| update]
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"

set "URL=http://localhost:6080"
set "CONTAINER=droidtap-emulator"
set "MODE="

call :find_engine
if errorlevel 1 (
    if "%~1"=="" pause
    exit /b 1
)

if "%~1"=="" goto menu
if /i "%~1"=="start" goto start
if /i "%~1"=="record" goto record_args
if /i "%~1"=="stop" goto stop
if /i "%~1"=="open" goto open
if /i "%~1"=="status" goto status
if /i "%~1"=="update" goto update
if /i "%~1"=="_rebuild" goto rebuild_then
echo Usage: %~nx0 [start ^| record [name] ^| stop ^| open ^| status ^| update]
exit /b 2

rem ---------------------------------------------------------------- menu

:menu
set "MODE=menu"
echo.
call :android_running
if errorlevel 1 (
    echo droidtap - Android is not running
) else (
    echo droidtap - Android is running: %URL%
)
echo   1^) Start Android
echo   2^) Record
echo   3^) Stop Android
echo   4^) Open the Android screen in the browser
echo   5^) Status and log
echo   6^) Update (git pull, rebuild the containers^)
echo   q^) Quit
set "PICK="
set /p "PICK=> "
echo.
if "!PICK!"=="1" call :start
if "!PICK!"=="2" call :record_menu
if "!PICK!"=="3" call :stop
if "!PICK!"=="4" call :open
if "!PICK!"=="5" call :status
if "!PICK!"=="6" goto update
if /i "!PICK!"=="q" exit /b 0
goto menu

rem ------------------------------------------------------------ commands

:start
echo Starting Android... (the first start downloads several GB)
%COMPOSE% up -d
if errorlevel 1 goto start_failed
call :open_desktop
if errorlevel 1 goto start_failed
exit /b 0
:start_failed
echo.
echo Something went wrong. Recent log:
%COMPOSE% logs --tail 25
exit /b 1

:record_menu
set "NAME="
set /p "NAME=Name of the recording (empty: date and time): "
set "RECORD_ARGS="
if defined NAME set RECORD_ARGS="!NAME!"
goto record

rem Everything after "record" is passed on to droidtap.
:record_args
set "RECORD_ARGS="
:record_args_next
shift
if "%~1"=="" goto record
set RECORD_ARGS=%RECORD_ARGS% %1
goto record_args_next

:record
call :android_running
if errorlevel 1 (
    echo Android is not running. Start it first.
    exit /b 1
)
%COMPOSE% --profile record run --rm recorder %RECORD_ARGS%
exit /b

:stop
echo Stopping Android...
%COMPOSE% down
exit /b

:open
call :android_running
if errorlevel 1 (
    echo Android is not running. Start it first.
    exit /b 1
)
goto open_desktop

:status
call :android_running
if errorlevel 1 (
    echo Android is not running.
) else (
    echo Android is running: %URL%
)
echo.
%COMPOSE% ps
echo.
%COMPOSE% logs --tail 25
exit /b

rem "update" fetches the new version and hands over to it for the rest, so
rem that the rebuild is done the way the new version wants it. cmd reads a
rem batch file line by line while running it and git replaces this file, so
rem both steps are in one block, which is read as a whole, and nothing of
rem the old file runs afterwards: starting a batch file without "call" does
rem not come back. For the same reason this is only reached with "goto".
:update
echo Fetching the latest version...
(
    git pull || goto update_failed
    "%~f0" _rebuild %MODE%
)
:update_failed
echo.
echo git pull failed, nothing was changed. See the message above.
if "%MODE%"=="menu" goto menu
exit /b 1

:rebuild_then
call :rebuild
if "%~2"=="menu" goto menu
exit /b

:rebuild
echo Rebuilding the containers...
%COMPOSE% --profile record build
if errorlevel 1 exit /b 1
call :android_running
if errorlevel 1 (
    echo Up to date.
    exit /b 0
)
echo Restarting Android with the new version...
%COMPOSE% down
if errorlevel 1 exit /b 1
goto start

rem ------------------------------------------------------------- helpers

:find_engine
docker compose version >nul 2>&1
if not errorlevel 1 (
    set "ENGINE=docker"
    set "COMPOSE=docker compose"
    goto check_engine
)
podman compose version >nul 2>&1
if not errorlevel 1 (
    set "ENGINE=podman"
    set "COMPOSE=podman compose"
    goto check_engine
)
where podman-compose >nul 2>&1
if not errorlevel 1 (
    set "ENGINE=podman"
    set "COMPOSE=podman-compose"
    goto check_engine
)
echo Neither "docker compose" nor "podman compose" was found.
echo Install Docker Desktop or Podman Desktop first.
exit /b 1
:check_engine
%ENGINE% info >nul 2>&1
if errorlevel 1 (
    echo %ENGINE% is installed but not running. Start it first.
    exit /b 1
)
exit /b 0

:android_running
set "RUNNING="
for /f "usebackq delims=" %%s in (`%ENGINE% inspect -f "{{.State.Running}}" %CONTAINER% 2^>nul`) do set "RUNNING=%%s"
if "%RUNNING%"=="true" exit /b 0
exit /b 1

:open_desktop
echo Waiting for the desktop...
set /a TRIES=0
:open_desktop_wait
curl -s -o nul "%URL%/"
if not errorlevel 1 (
    start "" "%URL%"
    echo The desktop is at %URL%. Android needs about a minute to boot.
    exit /b 0
)
set /a TRIES+=1
if %TRIES% geq 60 exit /b 1
rem Waits two seconds; "timeout" refuses to run without a keyboard.
ping -n 3 127.0.0.1 >nul
goto open_desktop_wait
