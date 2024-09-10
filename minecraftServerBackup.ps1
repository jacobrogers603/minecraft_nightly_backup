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
    [string]$nssmServiceName
    [Parameter(Mandatory=$false)]
    [bool]$warningMode=$true
)

# Aux functions
# Function to send a message to players via RCON
function Send-MinecraftMessage {
    param (
        [string]$message
    )
    
    Write-Log "Sending message to Minecraft players via RCON: $message"
    
    # Send the message using the RCON "say" command
    & mcrcon -H $serverIp -P 25575 -p $rconPassword "say $message"
}

# Function to stop the Minecraft server using RCON
function Stop-MinecraftServer {
    Write-Log "Sending stop command to Minecraft server via RCON."

    # Call mcrcon to send the "stop" command
    & mcrcon -H $serverIp -P 25575 -p $rconPassword stop
}

# Function to start the Minecraft server using NSSM
function Start-MinecraftServer {
    Write-Log ("Starting nssm service: " + $nssmServiceName)
    Start-Process -FilePath "nssm" -ArgumentList ("start " + $nssmServiceName) -Wait
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
        [bool]$includeTimestamp = $true  # Default is true to include timestamp if left out
    )

    # Format the log message with or without the timestamp
    if ($includeTimestamp) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path $logFile -Value "$timestamp - $message"
    } else {
        Add-Content -Path $logFile -Value "$message"
    }
}

function New-FolderIfNotExists {
    param (
        [string]$folderPath
    )

    # Split the folder path into its components
    $pathComponents = $folderPath -split '\\'

    # Start with the root part of the path
    $currentPath = $pathComponents[0] + '\'

    # Iterate over the remaining parts of the path
    for ($i = 1; $i -lt $pathComponents.Length; $i++) {
        # Append the current folder to the path
        $currentPath = Join-Path $currentPath $pathComponents[$i]

        # Check if the folder exists
        if (-not (Test-Path -Path $currentPath)) {
            # Folder does not exist, create it
            New-Item -Path $currentPath -ItemType Directory | Out-Null
            Write-Host "Folder created: $currentPath"
        }
    }
}

$backupPath = Join-Path $backupPath ((Get-Date).ToString("MM-dd-yyyy") + "_backup_" + (Get-LastPartOfPath $serverPath))
$logFile = Join-Path $backupPath "dailySaving.log"

Write-Log "----------------------------------------------------------------" $false
Write-Log ""
Write-Log ("Starting nightly backup process: Copying the directory at the path of`n" + $serverPath + "`nand backing it up to `n" + $backupPath + "`nin a new timestamped folder.") $false
Write-Log "----------------------------------------------------------------" $false

# If the day's backup folder was already made, quit
if (Test-Path $backupPath) {
    Write-Log ""
    Write-Log "Error: Directory $backupPath already exists. Exiting script." $false
    Write-Log "----------------------------------------------------------------`n`n" $false
    exit 1
}

# If it doesn't exist create the backupPath directory (and any folders we need to get there)
New-FolderIfNotExists $backupPath

# Warn the players
if ($warningMode) {
    Write-Log "`nWarn the players, will take around five minutes...`n"

    Send-MinecraftMessage "The server will shut down for an automatic backup in five minutes."
    Start-Sleep -Seconds 150

    Send-MinecraftMessage "The server will shut down for an automatic backup in two and a half minutes."
    Start-Sleep -Seconds 90

    Send-MinecraftMessage "The server will shut down for an automatic backup in one minute."
    Start-Sleep -Seconds 30

    Send-MinecraftMessage "The server will shut down for an automatic backup in thirty seconds."
    Start-Sleep -Seconds 10

    Send-MinecraftMessage "The server will shut down for an automatic backup in twenty seconds."
    Start-Sleep -Seconds 10

    Send-MinecraftMessage "The server will shut down for an automatic backup in ten seconds."
    Start-Sleep -Seconds 5

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
Stop-MinecraftServer
Stop-MinecraftService

# Do the backup process
Write-Log "Starting file copy process."
Get-ChildItem -Path $serverPath -Recurse | ForEach-Object {
    # Calculate the relative path of the file/folder to preserve structure
    $relativePath = $_.FullName.Substring($serverPath.Length)
    $destinationPath = Join-Path $backupPath $relativePath.TrimStart('\')
    $fullDestinationPath = Join-Path $backupPath $destinationPath

    try {
        if ($_.PSIsContainer) {
            # Create directory if it's a folder
            if (-not (Test-Path $destinationPath)) {
                Write-Log "Creating directory $fullDestinationPath"
                New-Item -ItemType Directory -Path $destinationPath
            }
        } else {
            # Copy file, creating the directory structure
            Write-Log "Copying file $($_.FullName) to $fullDestinationPath."
            Copy-Item -Path $_.FullName -Destination $destinationPath -Force
        }
    } catch {
        Write-Log "Error copying $($_.FullName): $_"
    }
}

# Restart the server
Start-MinecraftServer
Write-Log "`nRestarted the minecraft server`n"

Write-Log "----------------------------------------------------------------" $false
Write-Log ""
Write-Log ("Backup completed.") $false
Write-Log "----------------------------------------------------------------`n`n" $false
