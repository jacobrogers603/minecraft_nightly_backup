# Define parameters for the script  
param (
    [Parameter(Mandatory=$true)]
    [string]$serverPath,
    [Parameter(Mandatory=$true)]
    [string]$backupPath,
    [Parameter(Mandatory=$true)]
    [string]$rconPassword,
    [Parameter(Mandatory=$false)]
    [string]$serverIp="localhost",  
    [Parameter(Mandatory=$true)]
    [string]$nssmServiceName,
    [Parameter(Mandatory=$false)]
    [bool]$shortHand=$false  # Flag to suppress detailed copy messages
)

# Aux functions
# Function to send a message to players via RCON
function Send-MinecraftMessage {
    param (
        [string]$message
    )
    
    Write-Log "Sending message to Minecraft players via RCON: $message"
    
    # Send the message using the RCON "say" command with timeout
    & mcrcon -H $serverIp -P 25575 -p $rconPassword -w 5 "say $message" 2>&1
}

# Function to stop the Minecraft server using RCON
function Stop-MinecraftServer {
    Write-Log "Sending stop command to Minecraft server via RCON."

    # Call mcrcon to send the "stop" command with timeout
    & mcrcon -H $serverIp -P 25575 -p $rconPassword -w 5 stop 2>&1
}

# Function to start the Minecraft server using NSSM
function Start-MinecraftServer {
    Write-Log ("Starting nssm service: " + $nssmServiceName)

    try {
        $process = Start-Process -FilePath "nssm" -ArgumentList ("start " + $nssmServiceName) -Wait -PassThru

        if ($process.ExitCode -eq 0) {
            Write-Log "Minecraft server started successfully."
            return $true
        } else {
            Write-Log "Failed to start Minecraft server. NSSM returned exit code $($process.ExitCode)."
            return $false
        }
    } catch {
        Write-Log "Error occurred while trying to start NSSM service: $_"
        return $false
    }
}

# Function to stop the Minecraft server using NSSM
function Stop-MinecraftService {
    Write-Log ("Stopping nssm service: " + $nssmServiceName)
    Start-Process -FilePath "nssm" -ArgumentList ("stop " + $nssmServiceName) -Wait
}

function Get-CurrentFolderName {
    # Get the current folder's path where the script is located
    $currentFolderPath = $PSScriptRoot

    # Extract only the folder name (leaf) from the path
    $folderName = Split-Path $currentFolderPath -Leaf

    # Return the folder name
    return $folderName
}

function Get-LastPartOfPath {
    param (
        [string]$path
    )
    # Use Split-Path with -Leaf to get the last part of the path
    return Split-Path -Path $path -Leaf
}

function Write-Log {
    param (
        [string]$message,
        [bool]$includeTimestamp = $true
    )

    # Format the log message with or without the timestamp
    if ($includeTimestamp) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path $logFile -Value "$timestamp - $message" -ErrorAction Stop
    } else {
        Add-Content -Path $logFile -Value "$message" -ErrorAction Stop
    }
}

function Test-AnyPlayers {
    param (
        [string]$serverIp = "localhost",
        [int]$rconPort = 25575,
        [string]$rconPassword
    )

    try {
        $rconOutput = & mcrcon -H $serverIp -P $rconPort -p $rconPassword -w 5 "list" 2>&1
        
        if ($rconOutput -match "There are") {
            if ($rconOutput -match "There are 0") {
                Write-Log "Zero players detected in game"
                return $false
            } else {
                Write-Log "Player(s) detected in game"
                return $true
            }
        } else {
            Write-Log "Minecraft server is not responding or RCON command failed: $rconOutput"
            return $false
        }
    } catch {
        Write-Log "Error occurred while checking Minecraft server status via RCON: $_"
        return $false
    }
}

function Test-MinecraftServer {
    param (
        [string]$serverIp = "localhost",
        [int]$rconPort = 25575,
        [string]$rconPassword
    )

    try {
        # Send a simple "list" command via mcrcon to check if the server is responsive
        $rconOutput = & mcrcon -H $serverIp -P $rconPort -p $rconPassword -w 5 "list" 2>&1

        # Check if the RCON command returned a valid response
        if ($rconOutput -match "There are") {
            Write-Log "Minecraft server is up and responding to RCON commands."
            return $true
        } else {
            Write-Log "Minecraft server is not responding or RCON command failed: $rconOutput"
            return $false
        }
    } catch {
        Write-Log "Error occurred while checking Minecraft server status via RCON: $_"
        return $false
    }
}

function New-FolderIfNotExists {
    param (
        [string]$folderPath
    )

    # Ensure the path is absolute
    if (-not [System.IO.Path]::IsPathRooted($folderPath)) {
        throw "The provided path '$folderPath' is not an absolute path."
    }

    # Normalize the path
    try {
        $fullPath = [System.IO.Path]::GetFullPath($folderPath)
    } catch {
        throw "The path '$folderPath' is not valid."
    }

    # Split the path into components
    $pathComponents = $fullPath -split '[\\/]' | Where-Object { $_ -ne '' }

    # Initialize currentPath for both UNC and local paths
    $currentPath = if ($fullPath.StartsWith('\\')) {
        '\\' + $pathComponents[0] + '\' + $pathComponents[1]
    } else {
        $pathComponents[0] + '\'
    }

    # Iterate over the remaining parts of the path, starting after the drive letter or UNC share
    for ($i = if ($fullPath.StartsWith('\\')) { 2 } else { 1 }; $i -lt $pathComponents.Length; $i++) {
        $currentPath = Join-Path $currentPath $pathComponents[$i]

        # Check if the folder exists
        if (-not (Test-Path -Path $currentPath)) {
            try {
                # Folder does not exist, create it
                New-Item -Path $currentPath -ItemType Directory | Out-Null
            } catch {
                throw "Unable to create directory: $currentPath"
            }
        }
    }
}

# Function to check for player activity from 4:00 AM yesterday to current time based on server logs
function Test-PlayerActivityInLast24Hours {
    param (
        [string]$serverPath  # Path to the Minecraft server directory
    )

    # Construct the path to the logs directory
    $logsDir = Join-Path $serverPath "logs"
    
    # Check if logs directory exists; if not, assume activity to be safe
    if (-not (Test-Path $logsDir)) {
        Write-Log "Logs directory not found. Assuming player activity to be safe."
        return $true
    }

    # Define time window: 4:00 AM yesterday to current time
    $now = Get-Date
    $endTime = $now
    $startTime = [DateTime]::ParseExact($now.AddDays(-1).ToString("yyyy-MM-dd") + " 04:00:00", "yyyy-MM-dd HH:mm:ss", $null)
    
    # Format dates for log file name comparison
    $yesterdayStr = $startTime.ToString("yyyy-MM-dd")
    $todayStr = $now.ToString("yyyy-MM-dd")

    # Initialize activity flag and variables to track last join
    $activity = $false
    $lastJoinTime = $null
    $lastJoinPlayer = $null
    $lastJoinFile = $null

    # Iterate through all files in the logs directory
    Get-ChildItem -Path $logsDir -File | ForEach-Object {
        $file = $_

        # Process latest.log file
        if ($file.Name -eq "latest.log") {
            # Get file's last write time to infer date
            try {
                $fileLastWrite = (Get-Item $file.FullName).LastWriteTime
                # Skip if not from today or yesterday
                if ($fileLastWrite.Date -ne $now.Date -and $fileLastWrite.Date -ne $now.AddDays(-1).Date) {
                    return
                }
                
                # Read entire file content
                $content = Get-Content $file.FullName -Raw -ErrorAction Stop
                if (-not $content) {
                    return
                }
                $lines = $content -split "`n"
                
                # Set log date based on LastWriteTime
                $logDateStr = if ($fileLastWrite.Date -eq $now.Date) { $todayStr } else { $yesterdayStr }
                
                # Check each line for player join events
                foreach ($line in $lines) {
                    if ($line -match "joined the game" -and $line -match '\[(\d{2}):(\d{2}):(\d{2})\]') {
                        try {
                            # Extract time components and player name
                            $hour = [int]$matches[1]
                            $min = [int]$matches[2]
                            $sec = [int]$matches[3]
                            if ($line -match '\]:\s*(\w+)\s*joined the game') {
                                $player = $matches[1]
                            } else {
                                $player = "Unknown"
                            }
                            
                            # Construct timestamp using file's inferred date
                            $logDate = [DateTime]::ParseExact($logDateStr, "yyyy-MM-dd", $null)
                            $lineTime = $logDate.AddHours($hour).AddMinutes($min).AddSeconds($sec)
                            
                            # Check if join time is within the time window
                            if ($lineTime -ge $startTime -and $lineTime -le $endTime) {
                                # Update last join if this is the latest
                                if (-not $lastJoinTime -or $lineTime -gt $lastJoinTime) {
                                    $lastJoinTime = $lineTime
                                    $lastJoinPlayer = $player
                                    $lastJoinFile = $file.Name
                                }
                                $activity = $true
                            }
                        } catch {
                            Write-Log "Error parsing time in latest.log line: ${line} - $_"
                        }
                    }
                }
            } catch {
                Write-Log "Error accessing latest.log: $_"
            }
        } 
        # Process compressed log files (yyyy-MM-dd-n.log.gz)
        elseif ($file.Name -match '^(\d{4}-\d{2}-\d{2})-\d+\.log\.gz$') {
            $logDateStr = $matches[1]
            
            # Only process logs from today or yesterday
            if ($logDateStr -eq $todayStr -or $logDateStr -eq $yesterdayStr) {
                try {
                    # Decompress the gzip file
                    $stream = New-Object System.IO.FileStream $file.FullName, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read)
                    $gzip = New-Object System.IO.Compression.GzipStream $stream, ([IO.Compression.CompressionMode]::Decompress)
                    $reader = New-Object System.IO.StreamReader $gzip
                    $content = $reader.ReadToEnd()
                    $reader.Close()
                    $gzip.Close()
                    $stream.Close()

                    # Split content into lines
                    $lines = $content -split "`n"
                    
                    # Check each line for player join events
                    foreach ($line in $lines) {
                        if ($line -match "joined the game" -and $line -match '\[(\d{2}):(\d{2}):(\d{2})\]') {
                            try {
                                # Extract time components and player name
                                $hour = [int]$matches[1]
                                $min = [int]$matches[2]
                                $sec = [int]$matches[3]
                                if ($line -match '\]:\s*(\w+)\s*joined the game') {
                                    $player = $matches[1]
                                } else {
                                    $player = "Unknown"
                                }
                                
                                # Construct full timestamp for the log line
                                $logDate = [DateTime]::ParseExact($logDateStr, "yyyy-MM-dd", $null)
                                $lineTime = $logDate.AddHours($hour).AddMinutes($min).AddSeconds($sec)
                                
                                # Check if join time is within the time window
                                if ($lineTime -ge $startTime -and $lineTime -le $endTime) {
                                    # Update last join if this is the latest
                                    if (-not $lastJoinTime -or $lineTime -gt $lastJoinTime) {
                                        $lastJoinTime = $lineTime
                                        $lastJoinPlayer = $player
                                        $lastJoinFile = $file.Name
                                    }
                                    $activity = $true
                                }
                            } catch {
                                Write-Log "Error parsing time in $($file.Name): ${line} - $_"
                            }
                        }
                    }
                } catch {
                    Write-Log "Error decompressing or reading $($file.Name): $_"
                }
            }
        }

        # Exit loop early if activity is found and this is the latest join
        if ($activity -and $lastJoinTime -eq $endTime) {
            return $activity
        }
    }

    # Log final result
    if ($activity) {
        Write-Log "Player activity detected: ${lastJoinPlayer} joined at ${lastJoinTime} in ${lastJoinFile}."
    } else {
        Write-Log "No player activity detected between $startTime and $endTime."
    }
    
    # Return activity status
    return $activity
}

# Verify log file is writable
try {
    New-FolderIfNotExists $backupPath 
    $logFile = Join-Path $backupPath "dailySaving.log"
    Write-Log "Starting script execution"
} catch {
    Write-Error "Cannot write to log file at $logFile : $_"
    exit 1
}

# Set the backupPath to go one level deeper into a timestamped folder  
$backupPath = Join-Path $backupPath ((Get-Date).ToString("MM-dd-yyyy") + "_backup_" + (Get-LastPartOfPath $serverPath))

Write-Log "----------------------------------------------------------------" $false
Write-Log ""
Write-Log "Attempting minecraft backup" $false

# Check if this timestamped folder already exists (backup was already done today)
if ((Test-Path $backupPath)) {
    Write-Log "Directory $backupPath already exists. There has already been a backup today, aborting." $false
    Write-Log "----------------------------------------------------------------`n`n" $false
    exit 1
}

# Check for player activity in the last 24 hours
$hasActivity = Test-PlayerActivityInLast24Hours -serverPath $serverPath
if (-not $hasActivity) {
    Write-Log "No player activity in the last 24 hours. Skipping backup." $false
    Write-Log "----------------------------------------------------------------`n`n" $false
    Stop-Process -Id $PID -Force
    exit 0
}

# Create the timestamped folder
New-FolderIfNotExists $backupPath

# Check if the server is up
$serverRunning = Test-MinecraftServer -rconPassword $rconPassword

# If the server is running 
# and there are players in the server currently
# warn the players with a five min countdown
if($serverRunning){
    $playersInGame = Test-AnyPlayers -rconPassword $rconPassword
    if($playersInGame){
        $warningMode = $true
    }else{
        $warningMode = $false
    }
}else{
    $warningMode = $false
}

Write-Log ""
Write-Log ("Starting nightly backup process: Copying the directory at the path of`n" + $serverPath + "`nand backing it up to `n" + $backupPath + "`nin a new timestamped folder.") $false

# Warn the players
if ($warningMode) {
    Write-Log "`nWarn the players, will take around five minutes:`n"
    
    Send-MinecraftMessage "The server will shut down for an automatic backup in five minutes."
    Start-Sleep -Seconds 150
    
    Send-MinecraftMessage "The server will shut down for an automatic backup in two and a half minutes."
    Start-Sleep -Seconds 90
    
    Send-MinecraftMessage "The server will shut down for an automatic backup in one minute."
    Start-Sleep -Seconds 30
    
    Send-MinecraftMessage "The server will shut down for an automatic backup in thirty seconds."
    Start-Sleep -Seconds 30
    
    Send-MinecraftMessage "The server will shut down for an automatic backup in twenty seconds."
    Start-Sleep -Seconds 10
    
    Send-MinecraftMessage "The server will shut down for an automatic backup in ten seconds."
    Start-Sleep -Seconds 10
    
    Send-MinecraftMessage "The server will shut down for an automatic backup in five seconds."
    Start-Sleep -Seconds 1
    
    Send-MinecraftMessage "The server will shut down for an automatic backup in four seconds."
    Start-Sleep -Seconds 1
    
    Send-MinecraftMessage "The server will shut down for an automatic backup in three seconds."
    Start-Sleep -Seconds 1
    
    Send-MinecraftMessage "The server will shut down for an automatic backup in two seconds."
    Start-Sleep -Seconds 1
    
    Send-MinecraftMessage "The server will shut down for an automatic backup in one second."
    Start-Sleep -Seconds 1
    
    Send-MinecraftMessage "The server is shutting down for an automatic backup."
    Start-Sleep -Seconds 3
}

# Stop the server
if($serverRunning){
    Stop-MinecraftServer
    Stop-MinecraftService
}

Write-Log "----------------------------------------------------------------" $false

# Do the backup process
Write-Log "Starting file copy process."
Get-ChildItem -Path $serverPath -Recurse | ForEach-Object {
    # Calculate the relative path of the file/folder to preserve structure
    $relativePath = $_.FullName.Substring($serverPath.Length).TrimStart('\')
    $destinationPath = Join-Path $backupPath $relativePath

    try {
        if ($_.PSIsContainer) {
            # Create directory if it's a folder
            if (-not (Test-Path $destinationPath)) {
                if (-not $shortHand) {
                    Write-Log "Creating directory $destinationPath"
                }
                New-FolderIfNotExists $destinationPath
            }
        } else {
            # Copy file, creating the directory structure
            if (-not $shortHand) {
                Write-Log "Copying file $($_.FullName) to $destinationPath."
            }
            Copy-Item -Path $_.FullName -Destination $destinationPath -Force
        }
    } catch {
        Write-Log "Error copying $($_.FullName): $_"
    }
}

# Restart the server
Write-Log "----------------------------------------------------------------" $false
Write-Log ""
if(Start-MinecraftServer){
    Write-Log "Restarted the minecraft server"
}else{
    Write-Log "Failed to restart the minecraft server"
}

Write-Log ("Backup completed.") $false
Write-Log "----------------------------------------------------------------`n`n" $false

Stop-Process -Id $PID -Force
exit 0