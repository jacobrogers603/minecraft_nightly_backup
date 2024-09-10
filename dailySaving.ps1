# Define parameters for the script  
param (
    [Parameter(Mandatory=$true)]
    [string]$serverPath,
    [Parameter(Mandatory=$true)]
    [string]$backupPath,
    [Parameter(Mandatory=$true)]
    [string]$rconPassword,
    [Parameter(Mandatory=$true)]
    [string]$serverIp,  
    [Parameter(Mandatory=$true)]
    [string]$nssmServiceName
)

# Aux functions
# Function to send a message to players via RCON
function Send-MinecraftMessage {
    param (
        [string]$message
    )
    
    Write-Log "Sending message to Minecraft players via RCON: $message"
    
    # Send the message using the RCON "say" command
    & rcon-cli -H $serverIp -p 25575 -P $rconPassword "say $message"
}

# Function to stop the Minecraft server using RCON
function Stop-MinecraftServer {
    Write-Log "Sending stop command to Minecraft server via RCON."

    # Call rcon-cli to send the "stop" command
    & rcon-cli -H $serverIp -p 25575 -P $rconPassword stop
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

    # Check if the folder exists
    if (-not (Test-Path -Path $folderPath)) {
        # Folder does not exist, create it
        New-Item -Path $folderPath -ItemType Directory | Out-Null
        Write-Host "Folder created: $folderPath"
    } else {
        # Folder exists, no need to create
        Write-Host "Folder already exists: $folderPath"
    }
}

# Variables
$backupDir = (Get-Date).ToString("MM-dd-yyyy") + "_backup_" + (Get-LastPartOfPath $serverPath)
$logFile = Join-Path $backupPath "dailySaving.log"

Write-Log "----------------------------------------------------------------" $false
Write-Log ""
Write-Log ("Starting nightly backup process: Copying the directory at the path of`n" + $serverPath + "`nand backing it up to `n" + $backupPath + "`nin a new timestamped folder.") $false
Write-Log "----------------------------------------------------------------" $false

# Check if the date-based directory already exists on the NAS
if (Test-Path $backupDir) {
    Write-Log ""
    Write-Log "Error: Directory $backupDir already exists. Exiting script." $false
    Write-Log "----------------------------------------------------------------`n`n" $false
    exit 1
}

# Create the backupPath folder if it doesn't exist
New-FolderIfNotExists $backupPath

# Create the date-based folder in the backupPath directory
try {
    Write-Log "Creating directory, $backupDir, in current directory."
    New-Item -ItemType Directory -Path $backupDir
} catch {
    Write-Log ""
    Write-Log ("Error creating directory ${backupDir}: $_") $false
    Write-Log "----------------------------------------------------------------`n`n" $false
    exit 1
}

# Warn the players
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

# Stop the server
Stop-MinecraftServer
Stop-MinecraftService

# Do the backup process
Write-Log "Starting file copy process."
Get-ChildItem -Path $serverPath -Recurse | ForEach-Object {
    # Calculate the relative path of the file/folder to preserve structure
    $relativePath = $_.FullName.Substring($serverPath.Length)
    $destinationPath = Join-Path $backupDir $relativePath.TrimStart('\')
    $fullDestinationPath = Join-Path $backupDir $destinationPath

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
