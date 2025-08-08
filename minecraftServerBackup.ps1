# =========================
# Minecraft Nightly Backup
# Dual logs + safe flushes
# =========================

param (
    [Parameter(Mandatory = $true)]
    [string]$serverPath,
    [Parameter(Mandatory = $true)]
    [string]$backupPath,
    [Parameter(Mandatory = $true)]
    [string]$rconPassword,
    [Parameter(Mandatory = $false)]
    [string]$serverIp = "localhost",
    [Parameter(Mandatory = $true)]
    [string]$nssmServiceName,
    [Parameter(Mandatory = $false)]
    [bool]$shortHand = $false
)

# ---------- Helpers ----------

function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$message,
        [ValidateSet("both","summary","detail")][string]$Channel = "both",
        [bool]$includeTimestamp = $true
    )
    $line = if ($includeTimestamp) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $message" } else { $message }

    # full log (skip detail if shorthand mode)
    $writeFull = $true
    if ($shortHand -and $Channel -eq 'detail') { $writeFull = $false }
    if ($writeFull -and $script:logFileFull) {
        $line | Out-File -FilePath $script:logFileFull -Append -Encoding UTF8
    }

    # shorthand log
    if ($Channel -in @('summary','both') -and $script:logFileShort) {
        $line | Out-File -FilePath $script:logFileShort -Append -Encoding UTF8
    }
}

function Send-MinecraftMessage {
    param([string]$message)
    Write-Log "RCON say: $message" -Channel detail
    & mcrcon -H $serverIp -P 25575 -p $rconPassword -w 5 "say $message" 2>&1 | Out-Null
}

function Stop-MinecraftServer {
    Write-Log "Sending stop command to Minecraft server via RCON." -Channel summary
    & mcrcon -H $serverIp -P 25575 -p $rconPassword -w 5 stop 2>&1 | Out-Null
}

function Start-MinecraftServer {
    Write-Log ("Starting nssm service: " + $nssmServiceName) -Channel summary
    try {
        $process = Start-Process -FilePath "nssm" -ArgumentList ("start " + $nssmServiceName) -Wait -PassThru
        if ($process.ExitCode -eq 0) {
            Write-Log "Minecraft server started successfully." -Channel summary
            return $true
        } else {
            Write-Log "Failed to start Minecraft server. NSSM exit code $($process.ExitCode)." -Channel summary
            return $false
        }
    } catch {
        Write-Log "Error while trying to start NSSM service: $_" -Channel summary
        return $false
    }
}

function Stop-MinecraftService {
    Write-Log ("Stopping nssm service: " + $nssmServiceName) -Channel summary
    Start-Process -FilePath "nssm" -ArgumentList ("stop " + $nssmServiceName) -Wait | Out-Null
}

function Get-LastPartOfPath { param([string]$path) (Split-Path -Path $path -Leaf) }

function New-FolderIfNotExists {
    param([string]$folderPath)
    if (-not [System.IO.Path]::IsPathRooted($folderPath)) {
        throw "The provided path '$folderPath' is not an absolute path."
    }
    try { $fullPath = [System.IO.Path]::GetFullPath($folderPath) } catch { throw "The path '$folderPath' is not valid." }

    $pathComponents = $fullPath -split '[\\/]' | Where-Object { $_ -ne '' }
    $currentPath = if ($fullPath.StartsWith('\\')) { '\\' + $pathComponents[0] + '\' + $pathComponents[1] } else { $pathComponents[0] + '\' }

    for ($i = if ($fullPath.StartsWith('\\')) { 2 } else { 1 }; $i -lt $pathComponents.Length; $i++) {
        $currentPath = Join-Path $currentPath $pathComponents[$i]
        if (-not (Test-Path -Path $currentPath)) {
            try { New-Item -Path $currentPath -ItemType Directory | Out-Null }
            catch { throw "Unable to create directory: $currentPath" }
        }
    }
}

function Test-AnyPlayers {
    param([string]$serverIp = "localhost", [int]$rconPort = 25575, [string]$rconPassword)
    try {
        $rconOutput = & mcrcon -H $serverIp -P $rconPort -p $rconPassword -w 5 "list" 2>&1
        if ($rconOutput -match "There are") {
            if ($rconOutput -match "There are 0") {
                Write-Log "Zero players detected in game" -Channel detail
                return $false
            } else {
                Write-Log "Player(s) detected in game" -Channel detail
                return $true
            }
        } else {
            Write-Log "Server not responding or RCON failed: $rconOutput" -Channel detail
            return $false
        }
    } catch {
        Write-Log "Error checking server via RCON: $_" -Channel detail
        return $false
    }
}

function Test-MinecraftServer {
    param([string]$serverIp = "localhost", [int]$rconPort = 25575, [string]$rconPassword)
    try {
        $rconOutput = & mcrcon -H $serverIp -P $rconPort -p $rconPassword -w 5 "list" 2>&1
        if ($rconOutput -match "There are") {
            Write-Log "Minecraft server is up and responding to RCON." -Channel detail
            return $true
        } else {
            Write-Log "Server not responding or RCON failed: $rconOutput" -Channel detail
            return $false
        }
    } catch {
        Write-Log "Error checking server via RCON: $_" -Channel detail
        return $false
    }
}

# Scan 4:00 AM yesterday -> now for player join events
function Test-PlayerActivityInLast24Hours {
    param([string]$serverPath)

    $logsDir = Join-Path $serverPath "logs"
    if (-not (Test-Path $logsDir)) {
        Write-Log "Logs directory not found. Assuming player activity to be safe." -Channel summary
        return $true
    }

    $now = Get-Date
    $endTime = $now
    $startTime = [DateTime]::ParseExact($now.AddDays(-1).ToString("yyyy-MM-dd") + " 04:00:00", "yyyy-MM-dd HH:mm:ss", $null)
    $yesterdayStr = $startTime.ToString("yyyy-MM-dd")
    $todayStr = $now.ToString("yyyy-MM-dd")

    $activity = $false
    $lastJoinTime = $null
    $lastJoinPlayer = $null
    $lastJoinFile = $null

    Get-ChildItem -Path $logsDir -File | ForEach-Object {
        $file = $_

        if ($file.Name -eq "latest.log") {
            try {
                $fileLastWrite = (Get-Item $file.FullName).LastWriteTime
                if ($fileLastWrite.Date -ne $now.Date -and $fileLastWrite.Date -ne $now.AddDays(-1).Date) { return }

                $content = Get-Content $file.FullName -Raw -ErrorAction Stop
                if (-not $content) { return }
                $lines = $content -split "`n"

                $logDateStr = if ($fileLastWrite.Date -eq $now.Date) { $todayStr } else { $yesterdayStr }

                foreach ($line in $lines) {
                    if ($line -match "joined the game" -and $line -match '\[(\d{2}):(\d{2}):(\d{2})\]') {
                        try {
                            $hour = [int]$matches[1]; $min = [int]$matches[2]; $sec = [int]$matches[3]
                            if ($line -match '\]:\s*(\w+)\s*joined the game') { $player = $matches[1] } else { $player = "Unknown" }
                            $logDate = [DateTime]::ParseExact($logDateStr, "yyyy-MM-dd", $null)
                            $lineTime = $logDate.AddHours($hour).AddMinutes($min).AddSeconds($sec)
                            if ($lineTime -ge $startTime -and $lineTime -le $endTime) {
                                if (-not $lastJoinTime -or $lineTime -gt $lastJoinTime) {
                                    $lastJoinTime = $lineTime; $lastJoinPlayer = $player; $lastJoinFile = $file.Name
                                }
                                $activity = $true
                            }
                        } catch { Write-Log "Error parsing latest.log line: ${line} - $_" -Channel detail }
                    }
                }
            } catch { Write-Log "Error accessing latest.log: $_" -Channel detail }
        }
        elseif ($file.Name -match '^(\d{4}-\d{2}-\d{2})-\d+\.log\.gz$') {
            $logDateStr = $matches[1]
            if ($logDateStr -eq $todayStr -or $logDateStr -eq $yesterdayStr) {
                try {
                    $stream = New-Object System.IO.FileStream $file.FullName, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read)
                    $gzip = New-Object System.IO.Compression.GzipStream $stream, ([IO.Compression.CompressionMode]::Decompress)
                    $reader = New-Object System.IO.StreamReader $gzip
                    $content = $reader.ReadToEnd()
                    $reader.Close(); $gzip.Close(); $stream.Close()

                    $lines = $content -split "`n"
                    foreach ($line in $lines) {
                        if ($line -match "joined the game" -and $line -match '\[(\d{2}):(\d{2}):(\d{2})\]') {
                            try {
                                $hour = [int]$matches[1]; $min = [int]$matches[2]; $sec = [int]$matches[3]
                                if ($line -match '\]:\s*(\w+)\s*joined the game') { $player = $matches[1] } else { $player = "Unknown" }
                                $logDate = [DateTime]::ParseExact($logDateStr, "yyyy-MM-dd", $null)
                                $lineTime = $logDate.AddHours($hour).AddMinutes($min).AddSeconds($sec)
                                if ($lineTime -ge $startTime -and $lineTime -le $endTime) {
                                    if (-not $lastJoinTime -or $lineTime -gt $lastJoinTime) {
                                        $lastJoinTime = $lineTime; $lastJoinPlayer = $player; $lastJoinFile = $file.Name
                                    }
                                    $activity = $true
                                }
                            } catch { Write-Log "Error parsing $($file.Name) line: ${line} - $_" -Channel detail }
                        }
                    }
                } catch { Write-Log "Error reading $($file.Name): $_" -Channel detail }
            }
        }
    }

    if ($activity) {
        Write-Log "Player activity detected: ${lastJoinPlayer} joined at ${lastJoinTime} in ${lastJoinFile}." -Channel summary
    } else {
        Write-Log "No player activity detected between $startTime and $endTime." -Channel summary
    }
    return $activity
}

# ---------- Begin script ----------

# Ensure base folder & set log paths BEFORE any logging
try {
    New-FolderIfNotExists $backupPath
} catch {
    # If we can't create the directory, at least write to console
    Write-Error "Cannot create base backup folder at $backupPath : $_"
    Start-Sleep -Milliseconds 300
    exit 1
}

$script:logFileFull  = Join-Path $backupPath "dailySaving-full.log"
$script:logFileShort = Join-Path $backupPath "dailySaving-short.log"

# Daily header (always at least these lines)
Write-Log "----------------------------------------------------------------" -Channel summary -includeTimestamp:$false
Write-Log "" -Channel summary -includeTimestamp:$false
Write-Log "Starting script execution" -Channel summary
Write-Log "Attempting minecraft backup" -Channel summary -includeTimestamp:$false

# Compute per-run folder
$backupRunPath = Join-Path $backupPath ((Get-Date).ToString("MM-dd-yyyy") + "_backup_" + (Get-LastPartOfPath $serverPath))

# If it already exists, bail (already backed up today)
if (Test-Path $backupRunPath) {
    Write-Log "Directory $backupRunPath already exists. Backup already performed today, aborting." -Channel summary -includeTimestamp:$false
    Write-Log "----------------------------------------------------------------`n`n" -Channel summary -includeTimestamp:$false
    Start-Sleep -Milliseconds 300
    exit 1
}

# Check activity
$hasActivity = Test-PlayerActivityInLast24Hours -serverPath $serverPath
if (-not $hasActivity) {
    Write-Log "No player activity in the last 24 hours. Skipping backup." -Channel summary -includeTimestamp:$false
    Write-Log "----------------------------------------------------------------`n`n" -Channel summary -includeTimestamp:$false
    Start-Sleep -Milliseconds 300
    exit 0
}

# Create run folder
New-FolderIfNotExists $backupRunPath

# Determine server/rcon state
$serverRunning = Test-MinecraftServer -rconPassword $rconPassword
$warningMode = $false
if ($serverRunning) {
    $playersInGame = Test-AnyPlayers -rconPassword $rconPassword
    if ($playersInGame) { $warningMode = $true }
}

Write-Log "" -Channel summary -includeTimestamp:$false
Write-Log ("Starting nightly backup process: Copying the directory at`n" + $serverPath + "`ninto`n" + $backupRunPath + "`n(preserving structure).") -Channel summary -includeTimestamp:$false

# Warn if needed
if ($warningMode) {
    Write-Log "`nWarn the players (5 minutes):`n" -Channel summary
    Send-MinecraftMessage "The server will shut down for an automatic backup in five minutes."; Start-Sleep -Seconds 150
    Send-MinecraftMessage "The server will shut down for an automatic backup in two and a half minutes."; Start-Sleep -Seconds 90
    Send-MinecraftMessage "The server will shut down for an automatic backup in one minute."; Start-Sleep -Seconds 30
    Send-MinecraftMessage "The server will shut down for an automatic backup in thirty seconds."; Start-Sleep -Seconds 10
    Send-MinecraftMessage "The server will shut down for an automatic backup in twenty seconds."; Start-Sleep -Seconds 10
    Send-MinecraftMessage "The server will shut down for an automatic backup in ten seconds."; Start-Sleep -Seconds 5
    Send-MinecraftMessage "The server will shut down for an automatic backup in five seconds."; Start-Sleep -Seconds 1
    Send-MinecraftMessage "The server will shut down for an automatic backup in four seconds."; Start-Sleep -Seconds 1
    Send-MinecraftMessage "The server will shut down for an automatic backup in three seconds."; Start-Sleep -Seconds 1
    Send-MinecraftMessage "The server will shut down for an automatic backup in two seconds."; Start-Sleep -Seconds 1
    Send-MinecraftMessage "The server will shut down for an automatic backup in one second."; Start-Sleep -Seconds 1
    Send-MinecraftMessage "The server is shutting down for an automatic backup."; Start-Sleep -Seconds 3
}

# Stop server if running
if ($serverRunning) {
    Stop-MinecraftServer
    Stop-MinecraftService
}

Write-Log "----------------------------------------------------------------" -Channel summary -includeTimestamp:$false

# Copy
Write-Log "Starting file copy process." -Channel summary
Get-ChildItem -Path $serverPath -Recurse | ForEach-Object {
    $relativePath = $_.FullName.Substring($serverPath.Length).TrimStart('\')
    $destinationPath = Join-Path $backupRunPath $relativePath

    try {
        if ($_.PSIsContainer) {
            if (-not (Test-Path $destinationPath)) {
                Write-Log "Creating directory $destinationPath" -Channel detail
                New-FolderIfNotExists $destinationPath
            }
        } else {
            Write-Log "Copying file $($_.FullName) -> $destinationPath" -Channel detail
            Copy-Item -Path $_.FullName -Destination $destinationPath -Force
        }
    } catch {
        Write-Log "Error copying $($_.FullName): $_" -Channel detail
    }
}

# Restart server
Write-Log "----------------------------------------------------------------" -Channel summary -includeTimestamp:$false
Write-Log "" -Channel summary -includeTimestamp:$false
if (Start-MinecraftServer) {
    Write-Log "Restarted the minecraft server" -Channel summary
} else {
    Write-Log "Failed to restart the minecraft server" -Channel summary
}

Write-Log "Backup completed." -Channel summary -includeTimestamp:$false
Write-Log "----------------------------------------------------------------`n`n" -Channel summary -includeTimestamp:$false

Start-Sleep -Milliseconds 300
exit 0
