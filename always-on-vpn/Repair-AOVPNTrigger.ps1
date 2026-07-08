# Template: replace placeholder domains, hosts, routes, OU paths, app IDs, and branding values before use.
<#
.SYNOPSIS
    Repairs the Always On VPN trigger behavior so it stops dropping active RDP sessions.

.DESCRIPTION
    This script replaces C:\ProgramData\AOVPN\Scripts\Trigger-AlwaysOnVPN.ps1 with a safer version that:
      - Does NOT disconnect/recycle an already-connected VPN based on one failed probe.
      - Uses multiple corporate reachability probes instead of only csi.example.org:443.
      - Treats rasdial success + Get-VpnConnection Connected as connected, even if app probes fail.
      - Uses a global mutex to prevent overlapping trigger runs from fighting over rasdial.
      - Disables the aggressive AOVPN-Trigger-Periodic scheduled task.
      - Updates remaining AOVPN trigger tasks to IgnoreNew for multiple-instance behavior.

    Run from an elevated PowerShell session.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Repair-AOVPNTrigger.ps1 -RunNow
#>

param(
    [switch]$RunNow
)

$ErrorActionPreference = 'Stop'

$BaseDir       = 'C:\ProgramData\AOVPN'
$ScriptDir     = Join-Path $BaseDir 'Scripts'
$LogDir        = Join-Path $BaseDir 'Logs'
$TriggerPath   = Join-Path $ScriptDir 'Trigger-AlwaysOnVPN.ps1'
$RepairLogPath = Join-Path $LogDir 'Repair-AOVPNTrigger.log'

function Write-RepairLog {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$timestamp - $Message"
    Write-Host $line
    try {
        if (-not (Test-Path $LogDir)) {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("$line`r`n")
        $fs = [System.IO.File]::Open($RepairLogPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
    } catch {}
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Error 'This repair must be run from an elevated PowerShell session.'
    exit 1
}

New-Item -ItemType Directory -Path $ScriptDir -Force | Out-Null
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

Write-RepairLog 'Starting Always On VPN trigger repair.'

if (Test-Path $TriggerPath) {
    $backup = "$TriggerPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -Path $TriggerPath -Destination $backup -Force
    Write-RepairLog "Backed up existing trigger script to: $backup"
}

$FixedTriggerScript = @'
# Always On VPN Connection Trigger Script v4.1 - RDP-safe
#
# Purpose:
#   Keep AlwaysOnVPN connected when off corp, but do NOT tear down an active VPN
#   session simply because one health probe fails. This prevents periodic trigger
#   runs from dropping RDP sessions.
#
# Key changes from v4.0:
#   - No forced disconnect/recycle when VPN status is Connected.
#   - Multiple corp probes instead of a single csi.example.org:443 probe.
#   - rasdial success + Get-VpnConnection Connected is considered connected.
#   - Global mutex prevents overlapping trigger runs.
#   - Logging uses FileShare.ReadWrite to avoid log-file lock errors.

$LogFile        = 'C:\ProgramData\AOVPN\Logs\Trigger-Log.txt'
$VPNName        = 'AlwaysOnVPN'
$VPNServer      = 'vpn.example.org'
$ProbeTimeoutMs = 7000
$MaxLogBytes    = 1048576
$KeepArchives   = 3

# At least one successful probe means corp resources are reachable.
# Keep csi in the list, but do not let that one probe control the whole tunnel.
$CorpProbes = @(
    @{ Host = '10.0.0.10';                         Port = 53  }, # Internal DNS/DC by IP
    @{ Host = 'dc01.corp.example.local'; Port = 389 }, # LDAP/DC by name
    @{ Host = 'csi.example.org';              Port = 443 }  # Existing app probe
)

function Write-TriggerLog {
    param([string]$Message)

    try {
        $logDir = Split-Path $LogFile -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }

        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $line = "$timestamp - $Message`r`n"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)
        $fs = [System.IO.File]::Open($LogFile, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
    } catch {
        # Avoid breaking VPN logic because logging failed.
    }
}

function Invoke-LogRotation {
    try {
        if (Test-Path $LogFile) {
            if ((Get-Item $LogFile).Length -gt $MaxLogBytes) {
                $stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
                $archive = $LogFile -replace '\.txt$', "-archived-$stamp.txt"
                Get-Content $LogFile -Tail 1000 | Set-Content $archive -Encoding UTF8 -ErrorAction SilentlyContinue
                Set-Content $LogFile -Value $null -Encoding UTF8 -ErrorAction SilentlyContinue

                $logDir = Split-Path $LogFile -Parent
                Get-ChildItem -Path $logDir -Filter 'Trigger-Log-archived-*.txt' -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -Skip $KeepArchives |
                    Remove-Item -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {}
}

function Test-TcpPort {
    param(
        [string]$ComputerName,
        [int]$Port,
        [int]$TimeoutMs = 7000
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $false
        }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Test-CorpReachability {
    $results = @()

    foreach ($probe in $CorpProbes) {
        $ok = Test-TcpPort -ComputerName $probe.Host -Port $probe.Port -TimeoutMs $ProbeTimeoutMs
        $results += [pscustomobject]@{
            Host      = $probe.Host
            Port      = $probe.Port
            Reachable = $ok
        }
    }

    $successCount = @($results | Where-Object { $_.Reachable }).Count
    $details = ($results | ForEach-Object { "$($_.Host):$($_.Port)=$($_.Reachable)" }) -join '; '

    return [pscustomobject]@{
        AnyReachable = ($successCount -gt 0)
        SuccessCount = $successCount
        Details      = $details
    }
}

function Get-VpnStatus {
    try {
        $v = Get-VpnConnection -Name $VPNName -AllUserConnection -ErrorAction SilentlyContinue
        if ($v) { return $v.ConnectionStatus }
    } catch {}
    return 'Unknown'
}

function Test-ActiveRdpToPrivateNetwork {
    try {
        $rdpConnections = Get-NetTCPConnection -State Established -RemotePort 3389 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.RemoteAddress -match '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)'
            }

        if ($rdpConnections) {
            $count = @($rdpConnections).Count
            Write-TriggerLog "Detected $count active RDP connection(s) to private IPs. Active sessions are protected."
            return $true
        }
    } catch {
        Write-TriggerLog "Could not evaluate active RDP sessions: $_"
    }

    return $false
}

function Connect-VPN {
    $dnsReady = $false

    for ($i = 1; $i -le 6; $i++) {
        try {
            $resolved = [System.Net.Dns]::GetHostAddresses($VPNServer) |
                Where-Object { $_.AddressFamily -eq 'InterNetwork' }

            if ($resolved) {
                Write-TriggerLog "VPN server resolved: $VPNServer -> $($resolved[0].IPAddressToString)"
                $dnsReady = $true
                break
            }
        } catch {}

        Write-TriggerLog "VPN DNS attempt $i failed, retrying in 5s..."
        Start-Sleep -Seconds 5
    }

    if (-not $dnsReady) {
        Write-TriggerLog "ERROR: could not resolve $VPNServer. Aborting connect; next trigger will retry."
        return $false
    }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Write-TriggerLog "VPN connect attempt $attempt of 3..."

        try {
            $out = rasdial $VPNName 2>&1 | Out-String
            Write-TriggerLog ('rasdial: ' + $out.Trim())
        } catch {
            Write-TriggerLog "rasdial error: $_"
        }

        Start-Sleep -Seconds 5

        $statusAfterDial = Get-VpnStatus
        $reachability = Test-CorpReachability
        Write-TriggerLog "Post-dial status=$statusAfterDial; probes: $($reachability.Details)"

        if ($statusAfterDial -eq 'Connected') {
            if ($reachability.AnyReachable) {
                Write-TriggerLog 'VPN connected and at least one corp probe is reachable.'
            } else {
                Write-TriggerLog 'VPN connected, but corp probes are not reachable yet. Leaving VPN up; not recycling.'
            }
            return $true
        }

        Write-TriggerLog "VPN not connected yet; waiting 10s before retry."
        Start-Sleep -Seconds 10
    }

    return $false
}

Invoke-LogRotation

$mutexName = 'Global\AOVPN-Trigger-Lock'
$mutex = $null
$hasMutex = $false

try {
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $hasMutex = $mutex.WaitOne(0)

    if (-not $hasMutex) {
        Write-TriggerLog 'Another trigger instance is already running. Exiting to avoid overlapping rasdial actions.'
        exit 0
    }

    Write-TriggerLog '=== Trigger run started ==='

    $status = Get-VpnStatus
    $reachability = Test-CorpReachability
    Write-TriggerLog "VPN status=$status; corp probes: $($reachability.Details)"

    if ($status -eq 'Connected') {
        if ($reachability.AnyReachable) {
            Write-TriggerLog 'VPN is Connected and corp resources are reachable. Nothing to do.'
        } else {
            [void](Test-ActiveRdpToPrivateNetwork)
            Write-TriggerLog 'VPN is Connected but all corp probes failed. Leaving active tunnel up to avoid dropping RDP/user sessions.'
        }

        Write-TriggerLog '=== Trigger run completed ==='
        exit 0
    }

    if ($reachability.AnyReachable) {
        Write-TriggerLog 'Corp resources are reachable without VPN. Device is likely on corporate network; VPN not required.'
        Write-TriggerLog '=== Trigger run completed ==='
        exit 0
    }

    if (Connect-VPN) {
        Write-TriggerLog 'VPN connection established or already connected.'
    } else {
        Write-TriggerLog 'ERROR: VPN failed to connect this run; next trigger will retry.'
    }

    Write-TriggerLog '=== Trigger run completed ==='
} finally {
    if ($hasMutex -and $mutex) {
        try { $mutex.ReleaseMutex() | Out-Null } catch {}
    }
    if ($mutex) {
        try { $mutex.Dispose() } catch {}
    }
}
'@

Set-Content -Path $TriggerPath -Value $FixedTriggerScript -Encoding UTF8 -Force
Write-RepairLog "Wrote fixed trigger script to: $TriggerPath"

# Disable the aggressive 5-minute periodic trigger. This is the main RDP-drop prevention item.
$periodicTask = Get-ScheduledTask -TaskName 'AOVPN-Trigger-Periodic' -ErrorAction SilentlyContinue
if ($periodicTask) {
    Disable-ScheduledTask -TaskName 'AOVPN-Trigger-Periodic' | Out-Null
    Write-RepairLog 'Disabled scheduled task: AOVPN-Trigger-Periodic'
} else {
    Write-RepairLog 'Periodic scheduled task not found: AOVPN-Trigger-Periodic'
}

# Make remaining trigger tasks ignore overlapping starts.
$triggerTasks = @(
    'AOVPN-Trigger-Startup',
    'AOVPN-Trigger-NetworkChange',
    'AOVPN-Trigger-AdapterOnline',
    'AOVPN-Trigger-Resume'
)

foreach ($taskName in $triggerTasks) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-RepairLog "Scheduled task not found: $taskName"
        continue
    }

    try {
        $settings = New-ScheduledTaskSettingsSet `
            -MultipleInstances IgnoreNew `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable

        Set-ScheduledTask -TaskName $taskName -Settings $settings | Out-Null
        Enable-ScheduledTask -TaskName $taskName | Out-Null
        Write-RepairLog "Updated scheduled task settings: $taskName -> MultipleInstances=IgnoreNew"
    } catch {
        Write-RepairLog "WARNING: Failed to update task settings for $taskName. Error: $_"
    }
}

# Verify target script was written.
if (Test-Path $TriggerPath) {
    $hash = Get-FileHash -Path $TriggerPath -Algorithm SHA256
    Write-RepairLog "Verified trigger script exists. SHA256=$($hash.Hash)"
}

if ($RunNow) {
    Write-RepairLog 'Running fixed trigger script once for validation...'
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $TriggerPath)
    $p = Start-Process -FilePath $powershell -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
    Write-RepairLog "Validation run completed. ExitCode=$($p.ExitCode)"
}

Write-RepairLog 'Always On VPN trigger repair completed.'
Write-RepairLog 'Review C:\ProgramData\AOVPN\Logs\Trigger-Log.txt after testing RDP over VPN.'
