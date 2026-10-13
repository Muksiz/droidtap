@echo off
rem Starts, stops, records with and updates droidtap on Windows; the
rem counterpart of droidtap.sh. Without a command (or when double-clicked) it
rem shows a menu. Usage:
rem   droidtap.bat [start ^| record [name] ^| listen [name] ^| recordings ^| stop ^| status ^| update]
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"

set "URL=http://localhost:6080"
set "CONTAINER=droidtap-emulator"
set "MODE="

rem Colours, and EL, which clears the rest of a line.
for /f %%e in ('echo prompt $E^| cmd') do set "ESC=%%e"
set "S_BOLD=%ESC%[1m"
set "S_DIM=%ESC%[90m"
set "S_RED=%ESC%[31m"
set "S_GREEN=%ESC%[32m"
set "S_CYAN=%ESC%[36m"
set "S_OFF=%ESC%[0m"
if defined NO_COLOR for %%s in (BOLD DIM RED GREEN CYAN OFF) do set "S_%%s="
set "EL=%ESC%[K"

rem The texts below are UTF-8. The console is switched to that here, and
rem back at :quit.
set "OLDCP="
for /f "tokens=2 delims=:." %%c in ('chcp') do set /a "OLDCP=%%c" 2>nul
if "%OLDCP%"=="0" set "OLDCP="
chcp 65001 >nul

rem The commands that work without a container engine.
if /i "%~1"=="recordings" call :recordings & goto quit
if /i "%~1"=="listen" call :listen "%~2" & goto quit

call :find_engine
if not errorlevel 1 goto dispatch
if "%~1"=="" pause
set "RC=1"
goto quit_rc

:dispatch
if "%~1"=="" goto menu
if /i "%~1"=="start" call :start & goto quit
if /i "%~1"=="record" call :record_args %* & goto quit
if /i "%~1"=="stop" call :stop & goto quit
if /i "%~1"=="status" call :status & goto quit
if /i "%~1"=="update" goto update
if /i "%~1"=="_rebuild" goto rebuild_then
echo Usage: %~nx0 [start ^| record [name] ^| listen [name] ^| recordings ^| stop ^| status ^| update]
set "RC=2"
goto quit_rc

rem Every way out comes through here, with the result in the error level or,
rem at :quit_rc, in RC.
:quit
set "RC=%errorlevel%"
:quit_rc
if defined OLDCP chcp %OLDCP% >nul 2>&1
exit /b %RC%

rem ---------------------------------------------------------------- menu
rem
rem The menu is drawn over itself, from the top left corner, and again every
rem few seconds to keep up with the world. What it starts gets a cleared
rem screen.

:menu
set "MODE=menu"
set "MSG="
:menu_clear
cls
:menu_draw
call :android_running
if errorlevel 1 (set "UP=") else (set "UP=1")
set "COUNT=0"
for %%f in (recordings\*.wav) do set /a COUNT+=1
rem Recording and stopping need a running Android.
if defined UP (
    set "STATE=%S_GREEN%●%S_OFF% running at %S_CYAN%%URL%%S_OFF%"
    set "ITEM1=Open Android in the browser "
    set "HINT1="
    set "HINT2=until Ctrl+C"
    set "HINT5=its apps and logins are kept"
    set "S_NEED="
) else (
    set "STATE=%S_DIM%○ not running%S_OFF%"
    set "ITEM1=Start Android               "
    set "HINT1=and open its screen in the browser"
    set "HINT2=start Android first"
    set "HINT5=it is not running"
    set "S_NEED=%S_DIM%"
)
echo %ESC%[H%EL%
echo   %S_DIM%┌──────────────────────────────────────────────────────────┐%S_OFF%%EL%
echo   %S_DIM%│%S_OFF%  %S_BOLD%%S_GREEN%droidtap%S_OFF%  records what Android plays, and nothing else  %S_DIM%│%S_OFF%%EL%
echo   %S_DIM%└──────────────────────────────────────────────────────────┘%S_OFF%%EL%
echo.%EL%
echo    Android      %STATE%%EL%
echo    Recordings   %COUNT% in the folder recordings%EL%
echo.%EL%
echo    %S_BOLD%1%S_OFF%  %ITEM1%  %S_DIM%%HINT1%%S_OFF%%EL%
echo    %S_BOLD%2%S_OFF%  %S_NEED%Record                      %S_OFF%  %S_DIM%%HINT2%%S_OFF%%EL%
echo    %S_BOLD%3%S_OFF%  Listen to the recording       %S_DIM%while it is being made, with ffplay%S_OFF%%EL%
echo    %S_BOLD%4%S_OFF%  Open the recordings folder%EL%
echo    %S_BOLD%5%S_OFF%  %S_NEED%Stop Android                %S_OFF%  %S_DIM%%HINT5%%S_OFF%%EL%
echo    %S_BOLD%6%S_OFF%  Status and log%EL%
echo    %S_BOLD%7%S_OFF%  Update                        %S_DIM%git pull, rebuild the containers%S_OFF%%EL%
echo    %S_BOLD%q%S_OFF%  Quit%EL%
echo.%EL%
echo.   !MSG!%EL%
echo.%EL%
echo   %S_DIM%Press 1-7, or q to quit%S_OFF%%EL%%ESC%[J

rem "r" is what choice answers by itself after five seconds: draw again.
choice /c 1234567qr /n /t 5 /d r >nul
set "PICK=%errorlevel%"
if "%PICK%"=="9" goto menu_draw
set "MSG="
if "%PICK%"=="1" goto menu_start
if "%PICK%"=="2" goto menu_record
if "%PICK%"=="3" goto menu_listen
if "%PICK%"=="4" goto menu_recordings
if "%PICK%"=="5" goto menu_stop
if "%PICK%"=="6" goto menu_status
if "%PICK%"=="7" goto menu_update
if "%PICK%"=="8" set "RC=0" & goto quit_rc
rem choice cannot work without a keyboard.
if "%PICK%"=="255" set "RC=1" & goto quit_rc
goto menu_draw

:menu_start
cls
call :start
if errorlevel 1 goto menu_pause
set "MSG=%S_GREEN%Android is open in the browser.%S_OFF%"
if defined FRESH set "MSG=!MSG! It needs about a minute to boot."
goto menu_clear

:menu_record
if defined UP goto menu_record_now
set "MSG=%S_RED%Android is not running. Start it first.%S_OFF%"
goto menu_draw
:menu_record_now
cls
call :record_menu
goto menu_pause

:menu_listen
cls
call :listen ""
goto menu_pause

:menu_recordings
call :recordings >nul
set "MSG=%S_GREEN%Opened the folder%S_OFF% !CD!\recordings"
goto menu_draw

:menu_stop
cls
call :stop
if errorlevel 1 goto menu_pause
set "MSG=%S_GREEN%Android is stopped.%S_OFF%"
goto menu_clear

:menu_status
cls
call :status
goto menu_pause

:menu_update
cls
goto update

rem Leaves what a command printed on the screen until a key is pressed.
:menu_pause
echo.
pause
goto menu_clear

rem ------------------------------------------------------------ commands

rem Opens the Android screen in the browser, starting Android first if
rem needed. Leaves behind in FRESH whether it had to.
:start
set "FRESH="
call :android_running
if not errorlevel 1 goto start_open
set "FRESH=1"
echo %S_CYAN%►%S_OFF% %S_BOLD%Starting Android%S_OFF% (the first start downloads several GB)
%COMPOSE% up -d
if errorlevel 1 goto start_failed
:start_open
call :open_desktop
if errorlevel 1 goto start_failed
if defined FRESH echo   Android needs about a minute to boot.
exit /b 0
:start_failed
echo.
echo %S_RED%Something went wrong.%S_OFF% Recent log:
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
    echo %S_RED%Android is not running.%S_OFF% Start it first.
    exit /b 1
)
%COMPOSE% --profile record run --rm recorder %RECORD_ARGS%
exit /b

rem Plays a recording while it is being made, from a second before its end, so
rem that there is always something left to play. The file is only read, which
rem the recording does not notice. Without a name it is the newest recording.
rem An ffplay.exe next to this file goes before an installed one: Windows
rem looks in the current folder first.
:listen
where ffplay >nul 2>&1
if errorlevel 1 (
    echo %S_RED%ffplay was not found.%S_OFF% It comes with FFmpeg. Install that, for example with
    echo "winget install Gyan.FFmpeg" and a new window, or put ffplay.exe in !CD!
    exit /b 1
)
rem The newest is the one created last: while a file is being written, the
rem folder's other facts about it are out of date.
set "LISTEN_FILE="
if not "%~1"=="" set "LISTEN_FILE=recordings\%~n1.wav"
if not defined LISTEN_FILE for /f "delims=" %%f in ('dir /b /a:-d /o:d /t:c recordings\*.wav 2^>nul') do set "LISTEN_FILE=recordings\%%f"
if not defined LISTEN_FILE goto listen_none
if not exist "!LISTEN_FILE!" goto listen_none
rem For the same reason the length is asked of the file itself. 192 bytes are
rem a millisecond of 48 kHz, 16 bit, stereo.
set "LISTEN_AT="
for /f "usebackq" %%s in (`powershell -NoProfile -Command "$f = [IO.File]::Open($env:LISTEN_FILE, 'Open', 'Read', 'ReadWrite'); $ms = [Math]::Max(0, [Math]::Floor($f.Length / 192) - 1000); $f.Close(); '{0}.{1:000}' -f [Math]::Floor($ms / 1000), ($ms %% 1000)"`) do set "LISTEN_AT=%%s"
if not defined LISTEN_AT (
    echo %S_RED%Could not read%S_OFF% !LISTEN_FILE!
    exit /b 1
)
echo Listening to !LISTEN_FILE!, a second behind - press Ctrl+C to stop
rem The header's length is out of date, and the file's end is not the end.
ffplay -nodisp -nostats -loglevel error -probesize 32 -analyzeduration 0 -follow 1 -ignore_length 1 -ss %LISTEN_AT% -i "!LISTEN_FILE!"
exit /b
:listen_none
echo %S_RED%There is no recording to listen to.%S_OFF% Start one first, in another window.
exit /b 1

:recordings
echo The recordings are in !CD!\recordings
start "" "!CD!\recordings"
exit /b 0

:stop
echo %S_CYAN%►%S_OFF% %S_BOLD%Stopping Android%S_OFF%
%COMPOSE% down
exit /b

:status
call :android_running
if errorlevel 1 (
    echo %S_DIM%○%S_OFF% Android is not running.
) else (
    echo %S_GREEN%●%S_OFF% Android is running: %S_CYAN%%URL%%S_OFF%
)
echo.
%COMPOSE% ps
echo.
%COMPOSE% logs --tail 25
exit /b

rem "update" fetches the new version and hands over to it for the rest, so
rem that the rebuild is done the way the new version wants it. cmd reads a
rem batch file line by line while running it and git replaces this file, so
rem the steps are in one block, which is read as a whole, and nothing of
rem the old file runs afterwards: starting a batch file without "call" does
rem not come back. For the same reason this is only reached with "goto".
:update
echo %S_CYAN%►%S_OFF% %S_BOLD%Fetching the latest version%S_OFF%
(
    git pull || goto update_failed
    if defined OLDCP chcp %OLDCP% >nul 2>&1
    "%~f0" _rebuild %MODE%
)
:update_failed
echo.
echo %S_RED%git pull failed, nothing was changed.%S_OFF% See the message above.
if "%MODE%"=="menu" goto menu_pause
set "RC=1"
goto quit_rc

:rebuild_then
call :rebuild
if not "%~2"=="menu" goto quit
echo.
pause
goto menu

:rebuild
echo %S_CYAN%►%S_OFF% %S_BOLD%Rebuilding the containers%S_OFF%
%COMPOSE% --profile record build
if errorlevel 1 exit /b 1
call :android_running
if errorlevel 1 (
    echo %S_GREEN%Up to date.%S_OFF%
    exit /b 0
)
echo %S_CYAN%►%S_OFF% %S_BOLD%Restarting Android with the new version%S_OFF%
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
echo %S_RED%Neither "docker compose" nor "podman compose" was found.%S_OFF%
echo Install Docker Desktop or Podman Desktop first.
exit /b 1
:check_engine
%ENGINE% info >nul 2>&1
if errorlevel 1 (
    echo %S_RED%%ENGINE% is installed but not running.%S_OFF% Start it first.
    exit /b 1
)
exit /b 0

:android_running
set "RUNNING="
for /f "usebackq delims=" %%s in (`%ENGINE% inspect -f "{{.State.Running}}" %CONTAINER% 2^>nul`) do set "RUNNING=%%s"
if "%RUNNING%"=="true" exit /b 0
exit /b 1

rem Waits for the desktop to answer, two minutes at most, and opens it.
:open_desktop
<nul set /p "=Waiting for the desktop"
set /a TRIES=0
:open_desktop_wait
curl -s -m 2 -o nul "%URL%/"
if not errorlevel 1 (
    echo.
    start "" "%URL%"
    echo %S_GREEN%The desktop is at%S_OFF% %S_CYAN%%URL%%S_OFF%
    exit /b 0
)
<nul set /p "=."
set /a TRIES+=1
if %TRIES% geq 60 echo. & exit /b 1
rem Waits two seconds; "timeout" refuses to run without a keyboard.
ping -n 3 127.0.0.1 >nul
goto open_desktop_wait
