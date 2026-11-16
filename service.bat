@echo off
TITLE Ebook Audio Service Manager
cd /d C:\EbookAutomation

set "SERVICE_NAME=EbookAudioService"
set "NSSM_PATH=C:\EbookAutomation\nssm.exe"
if not exist "%NSSM_PATH%" set "NSSM_PATH=C:\Program Files\nssm\nssm.exe"

if "%1"=="start" goto :do_start
if "%1"=="stop" goto :do_stop
if "%1"=="restart" goto :do_restart
if "%1"=="status" goto :do_status
if "%1"=="logs" goto :do_logs

:: Interactive Menu if no argument provided
:menu
cls
echo ========================================================
echo   EbookAudioService Control Panel
echo ========================================================
echo 1. Start Service
echo 2. Stop Service
echo 3. Restart Service
echo 4. Check Status
echo 5. View Logs (stdout/stderr)
echo 6. Exit
echo.
set /p choice="Select an option (1-6): "
if "%choice%"=="1" goto :do_start
if "%choice%"=="2" goto :do_stop
if "%choice%"=="3" goto :do_restart
if "%choice%"=="4" goto :do_status
if "%choice%"=="5" goto :do_logs
if "%choice%"=="6" exit /b 0
goto :menu

:do_start
echo [*] Starting %SERVICE_NAME%...
if exist "%NSSM_PATH%" ("%NSSM_PATH%" start %SERVICE_NAME%) else (net start %SERVICE_NAME%)
goto :end

:do_stop
echo [*] Stopping %SERVICE_NAME%...
if exist "%NSSM_PATH%" ("%NSSM_PATH%" stop %SERVICE_NAME%) else (net stop %SERVICE_NAME%)
goto :end

:do_restart
echo [*] Restarting %SERVICE_NAME%...
if exist "%NSSM_PATH%" (
    "%NSSM_PATH%" stop %SERVICE_NAME% >nul 2>&1
    "%NSSM_PATH%" start %SERVICE_NAME%
) else (
    net stop %SERVICE_NAME% >nul 2>&1
    net start %SERVICE_NAME%
)
goto :end

:do_status
echo.
echo [*] Checking status for %SERVICE_NAME%...
if exist "%NSSM_PATH%" (
    "%NSSM_PATH%" status %SERVICE_NAME%
) else (
    sc query %SERVICE_NAME%
)
echo.
pause
goto :menu

:do_logs
cls
echo ========================================================
echo   Service Log Inspection (service_out / service_err)
echo ========================================================
echo --- STDOUT LOG ---
if exist "service_out.log" (
    type service_out.log
) else (
    echo [No service_out.log found yet]
)
echo.
echo --- STDERR LOG ---
if exist "service_err.log" (
    type service_err.log
) else (
    echo [No service_err.log found yet]
)
echo.
pause
goto :menu

:end
pause