# ==========================================================
# EbookAutomation Universal Installer Script (Fully Self-Healing)
# ==========================================================
# Run as Administrator

$ErrorActionPreference = "Stop"
$InstallDir = "C:\EbookAutomation"
$InboxDir = "C:\AudiobookInbox"
$CloudDir = "C:\AudiobookCloud"
$ArchiveDir = "$InboxDir\archive"
$ServiceName = "EbookAudioService"

Write-Host "[*] Provisioning directory structure..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path $InboxDir | Out-Null
New-Item -ItemType Directory -Force -Path $CloudDir | Out-Null
New-Item -ItemType Directory -Force -Path $ArchiveDir | Out-Null

# 1. Automatically Install Git if missing
if (!(Get-Command "git" -ErrorAction SilentlyContinue)) {
    Write-Host "[*] Installing Git for Windows..." -ForegroundColor Cyan
    try {
        winget install --id Git.Git -e --silent --accept-package-agreements --accept-source-agreements
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    } catch {
        Write-Host "[!] Warning: Git install skipped or already present." -ForegroundColor Yellow
    }
}

# 2. Automatically Install eSpeak NG (Fixes Kokoro Aborted! phonemizer crash)
if (!(Get-Command "espeak-ng" -ErrorAction SilentlyContinue) -and !(Test-Path "C:\Program Files\eSpeak NG")) {
    Write-Host "[*] Installing eSpeak NG speech binaries via winget..." -ForegroundColor Cyan
    try {
        winget install --id espeak-ng.espeak-ng -e --silent --accept-package-agreements --accept-source-agreements
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    } catch {
        Write-Host "[!] Warning: eSpeak NG install skipped." -ForegroundColor Yellow
    }
}

# 3. Automatically Install Microsoft Visual C++ Redistributable (Fixes WinError 126 globally)
Write-Host "[*] Checking/Installing Microsoft Visual C++ Redistributable (x64)..." -ForegroundColor Cyan
$VCRedistPath = "$InstallDir\vc_redist.x64.exe"
try {
    Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vc_redist.x64.exe" -OutFile $VCRedistPath
    Start-Process -FilePath $VCRedistPath -ArgumentList "/install", "/quiet", "/norestart" -Wait
    Remove-Item $VCRedistPath -Force -ErrorAction SilentlyContinue
} catch {
    Write-Host "[!] Warning: VC++ Redistributable download skipped or already installed." -ForegroundColor Yellow
}

# Set strict NTFS permissions for Session 0 LocalSystem and Everyone
Write-Host "[*] Configuring NTFS ACL permissions on Inbox..." -ForegroundColor Cyan
icacls $InboxDir /setintegritylevel high | Out-Null
icacls $InboxDir /grant "*S-1-5-18:(OI)(CI)F" /t | Out-Null
icacls $InboxDir /grant "Everyone:(OI)(CI)F" /t | Out-Null

Write-Host "[*] Setting up Python Virtual Environment..." -ForegroundColor Cyan
Set-Location $InstallDir
if (!(Test-Path "$InstallDir\.venv")) {
    python -m venv .venv
}

$PythonExe = "$InstallDir\.venv\Scripts\python.exe"
$PipExe = "$InstallDir\.venv\Scripts\pip.exe"

Write-Host "[*] Upgrading pip and installing Python dependencies..." -ForegroundColor Cyan
& $PipExe install --upgrade pip
& $PipExe install fastapi uvicorn watchdog pypdf ebooklib python-docx soundfile numpy torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu
& $PipExe install kokoro soundfile espeakng-loader

# Verify app.py exists in InstallDir
if (!(Test-Path "$InstallDir\app.py")) {
    Write-Host "[!] Error: app.py not found in $InstallDir. Please place it there before running." -ForegroundColor Red
    exit 1
}

# Force-kill any lingering Python/Uvicorn tasks to prevent service locks
Get-Process python -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# Automatically locate nssm.exe anywhere within the installation directory structure
$NssmExe = Get-ChildItem -Path $InstallDir -Filter "nssm.exe" -Recurse | Select-Object -ExpandProperty FullName -First 1

if ($NssmExe) {
    Write-Host "[*] Found NSSM at: $NssmExe" -ForegroundColor Cyan
    Write-Host "[*] Configuring NSSM Service: $ServiceName..." -ForegroundColor Cyan
    
    # Safely force stop and remove service if it exists
    $ExistingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($ExistingService) {
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        & $NssmExe remove $ServiceName confirm 2>$null
        Start-Sleep -Seconds 2
    }

    & $NssmExe install $ServiceName $PythonExe "-m uvicorn app:app --host 127.0.0.1 --port 8000"
    & $NssmExe set $ServiceName AppDirectory $InstallDir
    & $NssmExe set $ServiceName AppStdout "$InstallDir\service_out.log"
    & $NssmExe set $ServiceName AppStderr "$InstallDir\service_err.log"
    & $NssmExe set $ServiceName AppRotateFiles 1
    & $NssmExe set $ServiceName AppRotateBytes 10485760
    & $NssmExe set $ServiceName ObjectName LocalSystem

    Write-Host "[*] Starting service..." -ForegroundColor Cyan
    & $NssmExe start $ServiceName
    Write-Host "[+] Installation complete! Dashboard available at http://127.0.0.1:8000" -ForegroundColor Green
} else {
    Write-Host "[!] Error: nssm.exe could not be found anywhere inside $InstallDir." -ForegroundColor Red
    exit 1
}