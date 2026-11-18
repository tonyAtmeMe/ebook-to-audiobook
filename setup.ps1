# ==========================================================
# EbookAutomation Universal Installer Script (Fully Self-Healing)
# ==========================================================
# Run as Administrator

$ErrorActionPreference = "Stop"
$InstallDir = "C:\EbookAutomation"
$BinDir = "$InstallDir\bin"
$InboxDir = "C:\AudiobookInbox"
$CloudDir = "C:\AudiobookCloud"
$ArchiveDir = "$InboxDir\archive"
$ProcessingDir = "$InboxDir\processing"
$ServiceName = "EbookAudioService"

Write-Host "[*] Provisioning directory structure..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
New-Item -ItemType Directory -Force -Path $InboxDir | Out-Null
New-Item -ItemType Directory -Force -Path $CloudDir | Out-Null
New-Item -ItemType Directory -Force -Path $ArchiveDir | Out-Null
New-Item -ItemType Directory -Force -Path $ProcessingDir | Out-Null

# 1. Automatically Install Git if missing
if (!(Get-Command "git" -ErrorAction SilentlyContinue)) {
    Write-Host "[*] Installing Git for Windows..." -ForegroundColor Cyan
    try {
        winget install --id Git.Git -e --silent --accept-package-agreements --accept-source-agreements
    } catch {
        Write-Host "[!] Warning: Git install skipped or already present." -ForegroundColor Yellow
    }
}

# 2. Automatically Install eSpeak NG (Fixes Kokoro Aborted! phonemizer crash)
if (!(Get-Command "espeak-ng" -ErrorAction SilentlyContinue) -and !(Test-Path "C:\Program Files\eSpeak NG")) {
    Write-Host "[*] Installing eSpeak NG speech binaries via winget..." -ForegroundColor Cyan
    try {
        winget install --id espeak-ng.espeak-ng -e --silent --accept-package-agreements --accept-source-agreements
    } catch {
        Write-Host "[!] Warning: eSpeak NG install skipped." -ForegroundColor Yellow
    }
}

# 3. Automatically Install FFmpeg (Required for MP3 audio compression)
if (!(Get-Command "ffmpeg" -ErrorAction SilentlyContinue) -and !(Test-Path "$BinDir\ffmpeg.exe")) {
    Write-Host "[*] Installing FFmpeg via winget..." -ForegroundColor Cyan
    try {
        winget install --id Gyan.FFmpeg -e --silent --accept-package-agreements --accept-source-agreements
    } catch {
        Write-Host "[!] Winget FFmpeg install failed. Downloading static release fallback..." -ForegroundColor Yellow
        $FFmpegZip = "$InstallDir\ffmpeg.zip"
        try {
            Invoke-WebRequest -Uri "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip" -OutFile $FFmpegZip
            Expand-Archive -Path $FFmpegZip -DestinationPath "$InstallDir\ffmpeg_temp" -Force
            $ExtractedBin = Get-ChildItem -Path "$InstallDir\ffmpeg_temp" -Filter "ffmpeg.exe" -Recurse | Select-Object -ExpandProperty DirectoryName -First 1
            if ($ExtractedBin) {
                Copy-Item "$ExtractedBin\ffmpeg.exe" "$BinDir\ffmpeg.exe" -Force
                Copy-Item "$ExtractedBin\ffprobe.exe" "$BinDir\ffprobe.exe" -Force
                Write-Host "[+] FFmpeg successfully placed into $BinDir" -ForegroundColor Green
            }
            Remove-Item "$InstallDir\ffmpeg_temp" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $FFmpegZip -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Host "[!] Warning: Could not download FFmpeg fallback. Ensure ffmpeg is in system path." -ForegroundColor Yellow
        }
    }
}

# 4. Automatically Fetch NSSM if missing from installation directory
$NssmExe = Get-ChildItem -Path $InstallDir -Filter "nssm.exe" -Recurse | Select-Object -ExpandProperty FullName -First 1
if (!$NssmExe) {
    Write-Host "[*] Downloading NSSM (Non-Sucking Service Manager)..." -ForegroundColor Cyan
    $NssmZip = "$InstallDir\nssm.zip"
    try {
        Invoke-WebRequest -Uri "https://nssm.cc/release/nssm-2.24.zip" -OutFile $NssmZip
        Expand-Archive -Path $NssmZip -DestinationPath "$InstallDir\nssm_temp" -Force
        $ExtractedNssm = Get-ChildItem -Path "$InstallDir\nssm_temp" -Filter "nssm.exe" -Recurse | Where-Object { $_.FullName -match "win64" } | Select-Object -ExpandProperty FullName -First 1
        if ($ExtractedNssm) {
            Copy-Item $ExtractedNssm "$BinDir\nssm.exe" -Force
            Write-Host "[+] NSSM successfully placed into $BinDir" -ForegroundColor Green
        }
        Remove-Item "$InstallDir\nssm_temp" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $NssmZip -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Host "[!] Error: Failed to download NSSM." -ForegroundColor Red
    }
}

# 5. Automatically Install Microsoft Visual C++ Redistributable (Fixes WinError 126 globally)
Write-Host "[*] Checking/Installing Microsoft Visual C++ Redistributable (x64)..." -ForegroundColor Cyan
$VCRedistPath = "$InstallDir\vc_redist.x64.exe"
try {
    Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vc_redist.x64.exe" -OutFile $VCRedistPath
    Start-Process -FilePath $VCRedistPath -ArgumentList "/install", "/quiet", "/norestart" -Wait
    Remove-Item $VCRedistPath -Force -ErrorAction SilentlyContinue
} catch {
    Write-Host "[!] Warning: VC++ Redistributable download skipped or already installed." -ForegroundColor Yellow
}

# --- MACHINE PATH INJECTION FOR SESSION 0 ---
Write-Host "[*] Updating Machine Environment PATH..." -ForegroundColor Cyan
$CurrentMachinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$PathsToAdd = @($BinDir, "C:\Program Files\eSpeak NG\command-line", "C:\Program Files\Git\bin")
foreach ($p in $PathsToAdd) {
    if (Test-Path $p) {
        if ($CurrentMachinePath -notlike "*$p*") {
            $CurrentMachinePath = "$p;$CurrentMachinePath"
        }
    }
}
[Environment]::SetEnvironmentVariable("Path", $CurrentMachinePath, "Machine")
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")

# --- CONFIGURE FIREWALL RULE FOR REMOTE RDP CLIENT ACCESS ---
Write-Host "[*] Configuring Windows Firewall rule for remote Web Dashboard access (Port 8000)..." -ForegroundColor Cyan
try {
    if (!(Get-NetFirewallRule -DisplayName "Ebook Pipeline Dashboard" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "Ebook Pipeline Dashboard" -Direction Inbound -Protocol TCP -LocalPort 8000 -Action Allow | Out-Null
        Write-Host "[+] Firewall rule added successfully." -ForegroundColor Green
    }
} catch {
    Write-Host "[!] Warning: Could not configure firewall rule automatically." -ForegroundColor Yellow
}

# --- SET STRICT NTFS PERMISSIONS ---
Write-Host "[*] Configuring NTFS ACL permissions on directories..." -ForegroundColor Cyan
foreach ($dir in @($InstallDir, $InboxDir, $CloudDir)) {
    icacls $dir /setintegritylevel high | Out-Null
    icacls $dir /grant "*S-1-5-18:(OI)(CI)F" /t | Out-Null
    icacls $dir /grant "Everyone:(OI)(CI)F" /t | Out-Null
}

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

# Re-locate nssm.exe
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

    & $NssmExe install $ServiceName $PythonExe "-m uvicorn app:app --host 0.0.0.0 --port 8000"
    & $NssmExe set $ServiceName AppDirectory $InstallDir
    & $NssmExe set $ServiceName AppStdout "$InstallDir\service_out.log"
    & $NssmExe set $ServiceName AppStderr "$InstallDir\service_err.log"
    & $NssmExe set $ServiceName AppRotateFiles 1
    & $NssmExe set $ServiceName AppRotateBytes 10485760
    & $NssmExe set $ServiceName ObjectName LocalSystem

    Write-Host "[*] Starting service..." -ForegroundColor Cyan
    & $NssmExe start $ServiceName
    Write-Host "[+] Installation complete! Dashboard available locally at http://127.0.0.1:8000 or remotely at http://<server-ip>:8000" -ForegroundColor Green
} else {
    Write-Host "[!] Error: nssm.exe could not be found anywhere inside $InstallDir." -ForegroundColor Red
    exit 1
}