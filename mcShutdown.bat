@echo off
setlocal enableextensions

rem ====== EDIT ME ======
set "UPSC_PATH=C:\Program Files\WinNUT\upsc.exe"
set "UPSSPEC=ups@192.168.0.128"   rem Synology NUT host:upsname
set "MCRCON_PATH=C:\mcrcon\mcrcon.exe"
set "RCON_PASS=REDACTED"
set "RCON_PORT=25575"
set "SERVICE_NAME=mc_82424"
rem ======================

set "LOGFILE=C:\minecraft\mcShutdown.log"
set "LOCKFILE=C:\minecraft\shutdown.lock"

call :log "==== WinNUT hook fired ===="

rem Prevent duplicate runs
if exist "%LOCKFILE%" (
  call :log "Shutdown already in progress (lock exists). Exiting."
  goto end
)
echo 1>"%LOCKFILE%"

rem ---- Step 1: confirm FSD is actually active ----
call :get_status
echo %UPS_STATUS% | find /I "FSD" >nul
if errorlevel 1 (
  call :log "FSD not present on first check. Aborting."
  goto end
)
call :log "FSD detected. Waiting 25s to confirm (NAS has ~20s delay)..."
timeout /t 25 /nobreak >nul

rem ---- Step 2: re-check FSD after grace window ----
call :get_status
echo %UPS_STATUS% | find /I "FSD" >nul
if errorlevel 1 (
  call :log "FSD cleared on re-check. Aborting shutdown."
  goto end
)
call :log "FSD still active. Proceeding with graceful server stop."

rem ---- Step 3: graceful Minecraft stop (try RCON first) ----
if exist "%MCRCON_PATH%" (
  call :log "Using mcrcon to warn/save/stop..."
  "%MCRCON_PATH%" -P %RCON_PORT% -p "%RCON_PASS%" "say [UPS] Server shutting down in 20s..."
  timeout /t 5 /nobreak >nul
  "%MCRCON_PATH%" -P %RCON_PORT% -p "%RCON_PASS%" "save-all"
  timeout /t 2 /nobreak >nul
  "%MCRCON_PATH%" -P %RCON_PORT% -p "%RCON_PASS%" "stop"
) else (
  call :log "mcrcon not found; attempting service stop: %SERVICE_NAME%"
  sc stop "%SERVICE_NAME%" >nul 2>&1
)

rem Optional: wait a few seconds for clean exit
timeout /t 10 /nobreak >nul

rem ---- Step 4: system shutdown ----
call :log "Initiating system shutdown (Synology FSD)."
shutdown /s /t 5 /c "UPS master (Synology) forced shutdown (FSD)."

goto end

:get_status
for /f "usebackq delims=" %%A in (`"%UPSC_PATH%" %UPSSPEC% ups.status 2^>nul`) do set "UPS_STATUS=%%A"
if not defined UPS_STATUS set "UPS_STATUS="
call :log "ups.status = [%UPS_STATUS%]"
exit /b 0

:log
echo [%date% %time%] %~1>>"%LOGFILE%"
exit /b 0

:end
del "%LOCKFILE%" >nul 2>&1
call :log "==== Hook finished ===="
endlocal
