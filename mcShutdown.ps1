# mcShutdown.ps1 — graceful Minecraft shutdown (PowerShell)
# -Debug : warn players + save + stop service, NO Windows shutdown
#  real  : warn players + save + stop service, THEN Windows shutdown

param([switch]$Debug)

$ErrorActionPreference = 'Stop'

############## EDIT ME ##############
$McrconPath   = 'C:\mcrcon\mcrcon.exe'
$RconHost     = '127.0.0.1'
$RconPort     = 25575
$RconPass     = 'REDACTED'

$ServiceName  = 'mc_82424'   # NSSM service name

# Warning schedule: total 20s (12s + 8s)
$WarnTotal    = 20
$WarnPhase1   = 12   # wait after first warn
$WarnPhase2   = 8    # wait after second warn

# Waits
$PostStopWaitSeconds     = 10   # buffer after /stop before inspecting PIDs
$AppPidWaitSeconds       = 45   # wait for app (Java) descendants to exit
$ServiceStateWaitSeconds = 20   # wait for SCM to report STOPPED
$ShutdownDelaySeconds    = 5    # Windows shutdown timer (real run only)

# Logging
$LogDir   = 'C:\minecraft'
$LogFile  = Join-Path $LogDir 'mcShutdown.log'
#####################################

# Ensure log dir
if (!(Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

# Robust logger with tiny retry to handle share violations
function Log([string]$msg) {
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
  $line = "[$ts] $msg"
  Write-Host $line
  for ($i=0; $i -lt 5; $i++) {
    try { Add-Content -Path $LogFile -Value $line; break }
    catch { Start-Sleep -Milliseconds 40 }
  }
}

# ---------------- Singleton: prevent multiple concurrent runs ----------------
$globalMutexName = 'Global\mcShutdown_singleton'
$mutex = $null
$createdNew = $false
try {
  $mutex = New-Object System.Threading.Mutex($false, $globalMutexName, [ref]$createdNew)
  if (-not $createdNew) {
    Write-Host "[mutex] Another mcShutdown instance is already running. Exiting."
    exit 0
  }
} catch {
  # If mutex creation fails, proceed anyway (better to try a clean stop than nothing)
}

# ---------------- RCON helpers (through cmd.exe to preserve JSON) ----------------
function Invoke-RconCmd([string]$commandString) {
  if (!(Test-Path $McrconPath)) { throw "mcrcon not found at $McrconPath" }
  # Build: /c ""<mcrcon>" -H <host> -P <port> -p "<pass>" <ONE COMMAND STRING>""
  $inner = ('"{0}" -H {1} -P {2} -p "{3}" {4}' -f $McrconPath, $RconHost, $RconPort, $RconPass, $commandString)
  $args  = '/c "' + $inner + '"'

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "cmd.exe"
  $psi.Arguments = $args
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute        = $false
  $p = [System.Diagnostics.Process]::Start($psi)
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  if ($stdout) { $stdout.TrimEnd() | ForEach-Object { Log "mcrcon: $_" } }
  if ($p.ExitCode -ne 0) {
    if ($stderr) { Log "mcrcon ERR: $stderr" }
    throw "mcrcon exited with code $($p.ExitCode)"
  }
}

function Invoke-Tellraw([string]$text, [string]$color, [bool]$bold=$false) {
  $t = $text.Replace('"','\"')
  $boldJson = if ($bold) { ',"bold":true' } else { '' }
  # ONE token (quoted) for cmd.exe; JSON quotes backslashed
  $oneCommand = '"tellraw @a {\"text\":\"' + $t + '\",\"color\":\"' + $color + '\"' + $boldJson + '}"'
  Invoke-RconCmd $oneCommand
}

# ---------------- Service/process helpers ----------------
function Get-ServiceProcess([string]$name) {
  Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction Stop
}

function Get-Descendants([int]$rootPid) {
  $procs = Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name
  $byParent = $procs | Group-Object ParentProcessId -AsHashTable -AsString
  $result = New-Object System.Collections.Generic.HashSet[int]
  $stack = [System.Collections.Generic.Stack[int]]::new()
  $stack.Push($rootPid)
  while ($stack.Count -gt 0) {
    $ppid = $stack.Pop()
    $children = if ($byParent.ContainsKey([string]$ppid)) { $byParent[[string]$ppid] } else { @() }
    foreach ($c in $children) {
      if ($result.Add([int]$c.ProcessId)) { $stack.Push([int]$c.ProcessId) }
    }
  }
  return $procs | Where-Object { $result.Contains([int]$_.ProcessId) }
}

function Wait-ForProcsExit([int[]]$pids, [int]$timeoutSec) {
  if (!$pids -or $pids.Count -eq 0) { return $true }
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    $alive = $pids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }
    if (!$alive -or $alive.Count -eq 0) { return $true }
    Start-Sleep -Seconds 1
  }
  return $false
}

function Wait-ForServiceStopped([string]$name, [int]$timeoutSec) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    $state = (Get-Service -Name $name -ErrorAction Stop).Status
    if ($state -eq 'Stopped') { return $true }
    Start-Sleep -Seconds 1
  }
  return $false
}

# ---------------- Main ----------------
try {
  Log "=============================================="
  Log ("Start: Debug={0}" -f $Debug)
  Log ("Service: {0} | RCON: {1}:{2}" -f $ServiceName, $RconHost, $RconPort)

  # --- Player warnings (continue on failure) ---
  try {
    Log "Warn players: shutdown in ${WarnTotal}s."
    Invoke-Tellraw ("POWER OUTAGE! Server on UPS battery, starting a safe shutdown. Save and stop incoming in {0}s." -f $WarnTotal) 'red' $true
    Start-Sleep -Seconds $WarnPhase1

    Log "Warn players: ${WarnPhase2}s remaining..."
    Invoke-Tellraw ("Stopping soon ({0}s). Stop all activity, prepare for save!" -f $WarnPhase2) 'gold'
    Start-Sleep -Seconds $WarnPhase2

    Log "Warn players: stopping now."
    Invoke-Tellraw 'Stopping now!' 'red' $true
  } catch {
    Log "WARN: RCON tellraw failed: $($_.Exception.Message)"
  }

  # --- save-all + stop via RCON (graceful) ---
  $saveOk = $false
  $stopSent = $false
  try {
    Log "RCON: save-all flush"
    Invoke-RconCmd '"save-all flush"' | Out-Null
    $saveOk = $true
  } catch {
    Log "WARN: save-all failed via RCON: $($_.Exception.Message)"
  }
  try {
    Log "RCON: stop"
    Invoke-RconCmd '"stop"' | Out-Null
    $stopSent = $true
  } catch {
    Log "WARN: stop failed via RCON: $($_.Exception.Message)"
  }

  # --- Ask SCM/NSSM to stop the service so state updates ---
  try {
    Log "SCM: Stop-Service $ServiceName (no-wait)"
    Stop-Service -Name $ServiceName -ErrorAction SilentlyContinue
  } catch {
    Log "WARN: Stop-Service error: $($_.Exception.Message)"
  }
  try { sc.exe stop $ServiceName | Out-Null } catch {}
  try { nssm.exe stop $ServiceName | Out-Null } catch {}

  # --- Buffer, then wait for APP (Java) to exit, not just the wrapper ---
  Log "Post-stop buffer: ${PostStopWaitSeconds}s"
  Start-Sleep -Seconds $PostStopWaitSeconds

  # Re-fetch service info
  $svc = $null
  try { $svc = Get-ServiceProcess $ServiceName } catch { Log "WARN: Could not read service info: $($_.Exception.Message)" }
  [int]$svcPid = if ($svc) { $svc.ProcessId } else { 0 }
  Log ("Service wrapper PID: {0}" -f $svcPid)

  # Descendants (includes java.exe)
  $appProcs = @()
  if ($svcPid -gt 0) { $appProcs = Get-Descendants -rootPid $svcPid }
  $appPids = @()
  if ($appProcs) { $appPids = $appProcs.ProcessId | ForEach-Object {[int]$_} }

  if ($appPids.Count -gt 0) {
    $names = ($appProcs | Select-Object -ExpandProperty Name -Unique) -join ', '
    Log ("App descendants found (count={0}; names={1}): {2}" -f $appPids.Count, $names, ($appPids -join ', '))
    Log ("Waiting up to {0}s for application processes (descendants) to exit..." -f $AppPidWaitSeconds)
    $appGone = Wait-ForProcsExit -pids $appPids -timeoutSec $AppPidWaitSeconds
    if ($appGone) { Log "All application processes have exited." }
    else { Log ("WARN: Some application processes still running after {0}s (graceful-only; not killing)." -f $AppPidWaitSeconds) }
  } else {
    Log "No app descendants found under service wrapper."
    $appGone = $true
  }

  # --- Confirm service STOPPED ---
  Log "Confirming service state STOPPED (up to ${ServiceStateWaitSeconds}s)..."
  $svcStopped = $false
  try {
    $svcStopped = Wait-ForServiceStopped -name $ServiceName -timeoutSec $ServiceStateWaitSeconds
  } catch {
    Log "WARN: Could not query service state: $($_.Exception.Message)"
  }
  if ($svcStopped) { Log "Service reports STOPPED." }
  else { Log "WARN: Service still not reporting STOPPED after ${ServiceStateWaitSeconds}s." }

  # --- Windows shutdown (skip if Debug) ---
  if ($Debug) {
    Log "[DEBUG] Skipping Windows shutdown."
  } else {
    Log "Issuing Windows shutdown in ${ShutdownDelaySeconds}s..."
    Start-Process -FilePath shutdown.exe -ArgumentList "/s","/t",$ShutdownDelaySeconds,"/c","UPS final shutdown" -WindowStyle Hidden
  }

  Log "Done."
}
finally {
  if ($mutex) {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
  }
}
