@echo off
TITLE EbookAutomation Service Installer
echo ========================================================
echo   EbookAutomation - Service Setup and Repair Script
echo ========================================================
echo.

:: Verify Administrator Privileges
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [!] ERROR: Right-click this script and select "Run as administrator"!
    pause
    exit /b 1
)

set "TARGET_DIR=C:\EbookAutomation"
set "SERVICE_NAME=EbookAudioService"
set "NSSM_EXE=%TARGET_DIR%\nssm-2.24\nssm-2.24\win64\nssm.exe"

cd /d "%TARGET_DIR%"

echo [*] Step 1: Cleaning up old service registration...
if exist "%NSSM_EXE%" (
    "%NSSM_EXE%" stop %SERVICE_NAME% >nul 2>&1
    "%NSSM_EXE%" remove %SERVICE_NAME% confirm >nul 2>&1
)

echo [*] Step 2: Rebuilding venv stubs while keeping site-packages intact...
if exist ".venv" (
    if exist ".venv_old" rmdir /s /q .venv_old
    ren .venv .venv_old
)

if exist "C:\Program Files\Python312\python.exe" (
    "C:\Program Files\Python312\python.exe" -m venv .venv
) else (
    echo [!] ERROR: Python 3.12 is not installed at C:\Program Files\Python312.
    pause
    exit /b 1
)

if exist ".venv_old" (
    xcopy /s /e /y .venv_old\Lib\site-packages "%TARGET_DIR%\.venv\Lib\site-packages\" >nul
    rmdir /s /q .venv_old
)

echo [*] Step 3: Registering service via explicit NSSM path...
"%NSSM_EXE%" install %SERVICE_NAME% "%TARGET_DIR%\.venv\Scripts\python.exe" "-m uvicorn app:app --host 127.0.0.1 --port 8000"
"%NSSM_EXE%" set %SERVICE_NAME% AppDirectory "%TARGET_DIR%"
"%NSSM_EXE%" set %SERVICE_NAME% AppStdout "%TARGET_DIR%\service_out.log"
"%NSSM_EXE%" set %SERVICE_NAME% AppStderr "%TARGET_DIR%\service_err.log"
"%NSSM_EXE%" set %SERVICE_NAME% AppEnvironmentExtra "PATH=%TARGET_DIR%\.venv\Lib\site-packages\torch\lib;%TARGET_DIR%\.venv\Scripts;C:\Windows\system32;C:\Windows"

echo [*] Step 4: Starting service...
"%NSSM_EXE%" start %SERVICE_NAME%

echo.
echo ========================================================
echo   Setup Complete!
echo ========================================================
pause