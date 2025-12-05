<# : batch portion
@echo off
setlocal
cd /d "%~dp0"

:: 1. Check for Administrator privileges
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: 2. Hand off execution to the PowerShell section below
echo Starting Yggdrasil Setup and Optimization Script...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression ($(Get-Content '%~f0' | Out-String))"
pause
goto :EOF
#>

# --- POWERSHELL PORTION STARTS HERE ---

$ErrorActionPreference = "Stop"
$msiFileName = "yggdrasil-0.5.12-x64.msi"
$repoUrl = "https://github.com/yggdrasil-network/public-peers/archive/refs/heads/master.zip"
$confPath = "$env:ProgramData\Yggdrasil\yggdrasil.conf"

# --- STEP 1: Check Installation ---
Write-Host "`n[1/5] Checking Yggdrasil Installation..." -ForegroundColor Cyan

$service = Get-Service "yggdrasil" -ErrorAction SilentlyContinue

if (-not $service) {
    Write-Host "Yggdrasil service not found." -ForegroundColor Yellow
    if (Test-Path $msiFileName) {
        Write-Host "Installing $msiFileName. Please complete the installation wizard..." -ForegroundColor Cyan
        # Start MSI and wait for user to finish
        $proc = Start-Process -FilePath $msiFileName -PassThru -Wait
        
        # Check again after install
        if (-not (Get-Service "yggdrasil" -ErrorAction SilentlyContinue)) {
            Write-Error "Installation seemingly failed or service not started. Exiting."
        }
        Write-Host "Installation complete." -ForegroundColor Green
    } else {
        Write-Error "Yggdrasil is not installed and '$msiFileName' was not found in the current folder."
    }
} else {
    Write-Host "Yggdrasil is already installed." -ForegroundColor Green
}

# --- STEP 2: Download and Extract Peers ---
Write-Host "`n[2/5] Downloading Public Peers repository..." -ForegroundColor Cyan

$zipPath = "$env:TEMP\ygg_peers.zip"
$extractPath = "$env:TEMP\ygg_peers_extract"

try {
    Invoke-WebRequest -Uri $repoUrl -OutFile $zipPath
    if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
} catch {
    Write-Error "Failed to download or extract peers: $_"
}

Write-Host "Scanning Markdown files for peers..."
$allPeers = @()
$pattern = '`((?:tcp|tls|quic|ws)://[^`]+)`'

$mdFiles = Get-ChildItem -Path $extractPath -Recurse -Filter "*.md"
foreach ($file in $mdFiles) {
    $content = Get-Content $file.FullName -Raw
    $matches = [regex]::Matches($content, $pattern)
    foreach ($m in $matches) {
        $allPeers += $m.Groups[1].Value
    }
}

$uniquePeers = $allPeers | Select-Object -Unique
Write-Host "Found $($uniquePeers.Count) unique peer strings." -ForegroundColor Green

# --- STEP 3: Find Fastest Unique Peers ---
Write-Host "`n[3/5] Pinging peers to find the fastest 4 unique hosts (Timeout: 250ms)..." -ForegroundColor Cyan
Write-Host "This may take a minute..."

$pingResults = @()
$pingClass = [System.Net.NetworkInformation.Ping]::new()

foreach ($peerUri in $uniquePeers) {
    try {
        # Parse Hostname from URI to identify the server
        $uriObj = [System.Uri]$peerUri
        $hostName = $uriObj.Host

        # Fast Ping (250ms timeout)
        try {
            $reply = $pingClass.Send($hostName, 250)
            if ($reply.Status -eq "Success") {
                # Add Host to the object so we can filter duplicates later
                $pingResults += [PSCustomObject]@{
                    Peer = $peerUri
                    Latency = $reply.RoundtripTime
                    Host = $hostName
                }
                Write-Host "." -NoNewline -ForegroundColor Gray
            }
        } catch {
            # Ping failed
        }
    } catch {
        # URI parsing failed
    }
}
Write-Host "" # New line

if ($pingResults.Count -eq 0) {
    Write-Error "Could not reach any public peers. Check your internet connection."
}

# --- SELECTION LOGIC ---
# 1. Sort by Latency (Fastest first)
$sortedResults = $pingResults | Sort-Object Latency

# 2. Select top 4, but ensure Hosts are unique
$bestPeers = @()
$seenHosts = @() # Keep track of hosts we've already added

foreach ($item in $sortedResults) {
    if ($item.Host -notin $seenHosts) {
        $bestPeers += $item
        $seenHosts += $item.Host
    }
    
    # Stop once we have 4 unique hosts
    if ($bestPeers.Count -ge 4) { break }
}

Write-Host "`nTop 4 Unique Peers found:" -ForegroundColor Green
$bestPeers | Format-Table -Property Latency, Host, Peer -AutoSize

# --- STEP 4: Edit Configuration ---
Write-Host "`n[4/5] Updating Yggdrasil Configuration ($confPath)..." -ForegroundColor Cyan

if (-not (Test-Path $confPath)) {
    Write-Error "Config file not found at $confPath. Is Yggdrasil installed correctly?"
}

# Backup config
Copy-Item $confPath "$confPath.bak" -Force
Write-Host "Backup created at $confPath.bak"

# Read Config
$configContent = Get-Content $confPath -Raw

# Create JSON formatted string for the peers
$peerStringList = $bestPeers.Peer | ForEach-Object { "    ""$_""" }
$newPeersBlock = "Peers: [`n" + ($peerStringList -join ",`n") + "`n  ]"

# Regex replace the Peers section
$regex = "(?s)Peers:\s*\[.*?\]"

if ($configContent -match $regex) {
    $newConfigContent = $configContent -replace $regex, $newPeersBlock
} else {
    Write-Warning "Could not find 'Peers: []' block. Appending to end."
    $newConfigContent = $configContent + "`n$newPeersBlock"
}

# Save using .NET to force UTF-8 NO BOM (fixes start error)
$Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding $False
[System.IO.File]::WriteAllText($confPath, $newConfigContent, $Utf8NoBomEncoding)

Write-Host "Configuration updated successfully." -ForegroundColor Green

# --- STEP 5: Restart Service ---
Write-Host "`n[5/5] Restarting Yggdrasil Service..." -ForegroundColor Cyan
try {
    Restart-Service "yggdrasil"
    Write-Host "Done! Yggdrasil is running with new peers." -ForegroundColor Green
} catch {
    Write-Error "Failed to restart service. Please check $confPath manually."
}

# Cleanup
Remove-Item $zipPath -ErrorAction SilentlyContinue
Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue