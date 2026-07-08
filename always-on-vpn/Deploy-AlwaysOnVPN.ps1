# Template: replace placeholder domains, hosts, routes, OU paths, app IDs, and branding values before use.
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Always On VPN Device Tunnel Deployment Script
.DESCRIPTION
    Removes existing Always On VPN connections and deploys a new device tunnel
    with automatic connection triggers for Windows 10/11 (including 24H2)
    
    Design notes:
    - Changed server to vpn.example.org
    - Added IKEv2 NAT-T registry fix for Error 809
    - Improved corporate network detection
    - Enhanced system tray icon visibility
    - Better error handling in trigger script
    - CRITICAL: Fixed IPv6 disable to work on ALL adapters (not just "Up")
    
.NOTES
    Version: 2.6
    Author: IT Department
    Requires: Windows 10/11, Machine Certificate for IKEv2 authentication
    Last Modified: 2026-05-05
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"

# Configuration
$VPNName = "AlwaysOnVPN"
$VPNServer = "vpn.example.org"  # Using aov as requested
$LogDir = "C:\ProgramData\AOVPN\Logs"
$ScriptDir = "C:\ProgramData\AOVPN\Scripts"
$LogFile = Join-Path $LogDir "Install-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

# Routes to add
$VPNRoutes = @(
    "10.0.0.0/8",
    "192.168.0.0/16",
    "203.0.113.10/32",
    "203.0.113.11/32",
    "203.0.113.12/32"
)

#region Logging Functions
function Initialize-Logging {
    if (-not (Test-Path $LogDir)) {
        New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
    }
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS')]
        [string]$Level = 'INFO'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp [$Level] $Message"
    
    # Write to log file
    Add-Content -Path $LogFile -Value $logMessage -Encoding UTF8
    
    # Write to console with color
    $color = switch ($Level) {
        'INFO'    { 'White' }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red' }
        'SUCCESS' { 'Green' }
    }
    Write-Host $logMessage -ForegroundColor $color
}
#endregion

#region Prerequisite Checks
function Test-Prerequisites {
    Write-Log "Checking prerequisites..." -Level INFO
    
    # Check if running as SYSTEM or Administrator
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    
    if (-not $isAdmin) {
        Write-Log "Script must run as Administrator" -Level ERROR
        throw "Administrative privileges required"
    }
    
    # Check Windows version (Win10/11)
    $osVersion = [System.Environment]::OSVersion.Version
    if ($osVersion.Major -lt 10) {
        Write-Log "Windows 10 or later required. Current version: $($osVersion.ToString())" -Level ERROR
        throw "Unsupported Windows version"
    }
    
    # Check for machine certificate
    $machineCerts = Get-ChildItem -Path Cert:\LocalMachine\My | 
        Where-Object { 
            $_.HasPrivateKey -and
            ($_.EnhancedKeyUsageList.FriendlyName -contains "Client Authentication" -or
             $_.EnhancedKeyUsageList.ObjectId -contains "1.3.6.1.5.5.7.3.2")
        }
    
    if ($machineCerts.Count -eq 0) {
        Write-Log "No machine certificate found for authentication" -Level WARN
        Write-Log "VPN connection will be created but may fail to connect without proper certificate" -Level WARN
    } else {
        Write-Log "Found $($machineCerts.Count) suitable machine certificate(s)" -Level SUCCESS
        foreach ($cert in $machineCerts) {
            Write-Log "  Certificate: $($cert.Subject)" -Level INFO
            Write-Log "  Valid until: $($cert.NotAfter)" -Level INFO
        }
    }
    
    Write-Log "Prerequisites check completed" -Level SUCCESS
}
#endregion

#region VPN Cleanup Functions
function Remove-ExistingVPNConnections {
    Write-Log "Removing existing Always On VPN connections..." -Level INFO
    
    # Get ALL VPN connections to remove (be thorough)
    $allVpns = @()
    
    try {
        $allVpns += Get-VpnConnection -AllUserConnection -ErrorAction SilentlyContinue
    } catch {}
    
    try {
        $allVpns += Get-VpnConnection -ErrorAction SilentlyContinue
    } catch {}
    
    # Remove each one
    foreach ($vpn in $allVpns) {
        try {
            # Try AllUserConnection first
            Remove-VpnConnection -Name $vpn.Name -AllUserConnection -Force -ErrorAction Stop
            Write-Log "Removed system-wide VPN: $($vpn.Name)" -Level SUCCESS
        } catch {
            try {
                # Try user connection
                Remove-VpnConnection -Name $vpn.Name -Force -ErrorAction Stop
                Write-Log "Removed user VPN: $($vpn.Name)" -Level SUCCESS
            } catch {
                Write-Log "Could not remove VPN: $($vpn.Name) - $_" -Level WARN
            }
        }
        Start-Sleep -Milliseconds 500
    }
    
    # Verify all removed
    $remaining = @()
    try {
        $remaining += Get-VpnConnection -AllUserConnection -ErrorAction SilentlyContinue
    } catch {}
    
    if ($remaining.Count -eq 0) {
        Write-Log "All existing VPN connections removed successfully" -Level SUCCESS
    } else {
        Write-Log "WARNING: $($remaining.Count) VPN connection(s) still exist" -Level WARN
    }
}

function Remove-ExistingScheduledTasks {
    Write-Log "Removing existing VPN-related scheduled tasks..." -Level INFO
    
    # Get ALL tasks with AOVPN in the name
    $allTasks = Get-ScheduledTask | Where-Object { 
        $_.TaskName -like "*AOVPN*" -or 
        $_.TaskName -like "*AlwaysOnVPN*" -or
        $_.TaskName -like "*DeviceTunnel*" -or
        $_.TaskName -like "*Trigger-*VPN*"
    }
    
    foreach ($task in $allTasks) {
        try {
            Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false -ErrorAction Stop
            Write-Log "Removed scheduled task: $($task.TaskName)" -Level SUCCESS
        } catch {
            Write-Log "Could not remove task $($task.TaskName): $_" -Level WARN
        }
    }
    
    if ($allTasks.Count -eq 0) {
        Write-Log "No existing VPN tasks found to remove" -Level INFO
    }
}
#endregion

#region VPN Creation Functions
function New-VPNConnection {
    Write-Log "Creating VPN connection: $VPNName" -Level INFO
    
    try {
        # Add-VpnConnection will create the PBK file if it doesn't exist
        $vpnParams = @{
            Name                  = $VPNName
            ServerAddress         = $VPNServer
            TunnelType           = 'IKEv2'
            AuthenticationMethod = 'MachineCertificate'
            EncryptionLevel      = 'Required'
            SplitTunneling       = $true
            RememberCredential   = $false
            AllUserConnection    = $true
            Force                = $true
        }
        
        Add-VpnConnection @vpnParams -ErrorAction Stop | Out-Null
        
        Write-Log "VPN connection created successfully" -Level SUCCESS
        
        # Verify it was created
        Start-Sleep -Seconds 2
        $vpnCheck = Get-VpnConnection -Name $VPNName -AllUserConnection -ErrorAction Stop
        if ($vpnCheck) {
            Write-Log "Verified VPN connection exists" -Level SUCCESS
        }
        
    } catch {
        Write-Log "Failed to create VPN connection: $_" -Level ERROR
        throw
    }
}

function Add-VPNRoutes {
    Write-Log "Adding VPN routes..." -Level INFO
    
    $successCount = 0
    foreach ($route in $VPNRoutes) {
        try {
            Add-VpnConnectionRoute -ConnectionName $VPNName -DestinationPrefix $route -PassThru -AllUserConnection -ErrorAction Stop | Out-Null
            Write-Log "Added route: $route" -Level SUCCESS
            $successCount++
        } catch {
            Write-Log "Failed to add route ${route}: $_" -Level WARN
        }
    }
    
    Write-Log "Added $successCount of $($VPNRoutes.Count) routes" -Level INFO
}

function Set-DeviceTunnelConfiguration {
    Write-Log "Configuring Device Tunnel settings in PBK file..." -Level INFO
    
    $pbkPath = "$env:ProgramData\Microsoft\Network\Connections\Pbk\rasphone.pbk"
    
    # Wait for PBK file to be created (up to 10 seconds)
    $maxWait = 10
    $waited = 0
    while (-not (Test-Path $pbkPath) -and $waited -lt $maxWait) {
        Write-Log "Waiting for rasphone.pbk to be created..." -Level INFO
        Start-Sleep -Seconds 1
        $waited++
    }
    
    if (-not (Test-Path $pbkPath)) {
        Write-Log "rasphone.pbk not found after waiting $maxWait seconds" -Level ERROR
        throw "PBK file missing - VPN connection may not have been created properly"
    }
    
    Write-Log "Found rasphone.pbk at: $pbkPath" -Level SUCCESS
    
    # Backup original
    $backupPath = "$pbkPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -Path $pbkPath -Destination $backupPath -Force
    Write-Log "Created backup: $backupPath" -Level INFO
    
    try {
        # Read all lines
        $lines = Get-Content -Path $pbkPath -Encoding ASCII
        $output = New-Object System.Collections.ArrayList
        $inTargetSection = $false
        $settingsFound = @{}
        
        # Required settings for Device Tunnel with Split Tunneling
        # IMPORTANT: ShowMonitorIconInTaskBar=1 ensures VPN icon in system tray
        $requiredSettings = @{
            'AlwaysOn'                = '1'
            'AutoLogon'               = '1'
            'UseRasCredentials'       = '0'
            'DeviceTunnel'           = '1'
            'IdleDisconnectSeconds'  = '0'
            'ShowMonitorIconInTaskBar' = '1'  # CRITICAL: Shows VPN icon in system tray
            'RegisterDNS'            = '1'
            'IpPrioritizeRemote'     = '0'
            'IpInterfaceMetric'      = '1'
            'IpDnsFlags'             = '1'
            'Type'                   = '2'
            'DisableIKENameEkuCheck' = '1'
            'VpnStrategy'            = '14'  # IKEv2 only
        }
        
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            
            # Check if entering our VPN section
            if ($line -match "^\[$VPNName\]") {
                $inTargetSection = $true
                [void]$output.Add($line)
                $settingsFound.Clear()
                continue
            }
            
            # Check if entering a different section
            if ($line -match "^\[" -and $line -notmatch "^\[$VPNName\]") {
                # Before leaving our section, add any missing settings
                if ($inTargetSection) {
                    foreach ($key in $requiredSettings.Keys) {
                        if (-not $settingsFound.ContainsKey($key)) {
                            $newLine = "$key=$($requiredSettings[$key])"
                            [void]$output.Add($newLine)
                            Write-Log "Added missing setting: $newLine" -Level INFO
                        }
                    }
                }
                $inTargetSection = $false
            }
            
            # Process line if in our section
            if ($inTargetSection -and $line -match '^([^=]+)=(.*)$') {
                $key = $matches[1]
                $value = $matches[2]
                
                if ($requiredSettings.ContainsKey($key)) {
                    $line = "$key=$($requiredSettings[$key])"
                    $settingsFound[$key] = $true
                    Write-Log "Updated setting: $line" -Level INFO
                }
            }
            
            [void]$output.Add($line)
        }
        
        # If we ended while still in the section, add missing settings
        if ($inTargetSection) {
            foreach ($key in $requiredSettings.Keys) {
                if (-not $settingsFound.ContainsKey($key)) {
                    $newLine = "$key=$($requiredSettings[$key])"
                    [void]$output.Add($newLine)
                    Write-Log "Added missing setting at end: $newLine" -Level INFO
                }
            }
        }
        
        # Write to temp file first
        $tempPath = "$pbkPath.tmp"
        $output | Set-Content -Path $tempPath -Encoding ASCII -Force
        
        # Replace original with temp
        Move-Item -Path $tempPath -Destination $pbkPath -Force
        
        Write-Log "PBK file updated successfully" -Level SUCCESS
        
    } catch {
        Write-Log "Failed to update PBK file: $_" -Level ERROR
        # Restore backup
        if (Test-Path $backupPath) {
            Copy-Item -Path $backupPath -Destination $pbkPath -Force
            Write-Log "Restored backup due to error" -Level WARN
        }
        throw
    }
}

function Set-IKEv2RegistryFix {
    Write-Log "Applying IKEv2 NAT-T registry fix for Error 809..." -Level INFO
    
    try {
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\PolicyAgent"
        
        # AssumeUDPEncapsulationContextOnSendRule
        # 0 = Never assume UDP encapsulation
        # 1 = Assume UDP encapsulation when behind NAT
        # 2 = Always assume UDP encapsulation (most compatible, fixes Error 809)
        New-ItemProperty -Path $regPath `
            -Name "AssumeUDPEncapsulationContextOnSendRule" `
            -Value 2 `
            -PropertyType DWord `
            -Force -ErrorAction SilentlyContinue | Out-Null
        
        Write-Log "Registry fix applied: AssumeUDPEncapsulationContextOnSendRule=2" -Level SUCCESS
        
        # Restart IPsec services to apply changes
        Write-Log "Restarting IPsec services..." -Level INFO
        Restart-Service PolicyAgent -Force -ErrorAction Stop
        Restart-Service IKEEXT -Force -ErrorAction Stop
        Write-Log "IPsec services restarted successfully" -Level SUCCESS
        
    } catch {
        Write-Log "Failed to apply registry fix: $_" -Level WARN
        Write-Log "VPN may still work but Error 809 might occur on some networks" -Level WARN
    }
}

function Disable-IPv6OnInterfaces {
    Write-Log "Disabling IPv6 to force IPv4 connections..." -Level INFO
    
    try {
        # Disable IPv6 on ALL physical network adapters (not just "Up" ones)
        # BUG FIX: Original only disabled on "Up" adapters, missing disconnected adapters
        $adapters = Get-NetAdapter | Where-Object { 
            $_.InterfaceDescription -notlike "*VPN*" -and 
            $_.InterfaceDescription -notlike "*Loopback*" -and
            $_.InterfaceDescription -notlike "*Pseudo*" -and
            $_.InterfaceDescription -notlike "*Virtual*"
        }
        
        $disabledCount = 0
        foreach ($adapter in $adapters) {
            try {
                $binding = Get-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
                if ($binding -and $binding.Enabled) {
                    Disable-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -Confirm:$false -ErrorAction Stop
                    Write-Log "Disabled IPv6 on: $($adapter.Name) (Status: $($adapter.Status))" -Level SUCCESS
                    $disabledCount++
                } else {
                    Write-Log "IPv6 already disabled on: $($adapter.Name)" -Level INFO
                }
            } catch {
                Write-Log "Could not disable IPv6 on $($adapter.Name): $_" -Level WARN
            }
        }
        
        Write-Log "Disabled IPv6 on $disabledCount adapter(s)" -Level SUCCESS
        
        # ALSO set registry to globally prefer IPv4 over IPv6
        try {
            $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters"
            New-ItemProperty -Path $regPath -Name "DisabledComponents" -Value 255 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
            Write-Log "Set registry to disable IPv6 globally (DisabledComponents=255)" -Level SUCCESS
            Write-Log "NOTE: Full IPv6 disable requires reboot, but binding changes work immediately" -Level INFO
        } catch {
            Write-Log "Could not set IPv6 registry: $_" -Level WARN
        }
        
    } catch {
        Write-Log "Error during IPv6 disabling: $_" -Level WARN
    }
}
#endregion

#region Scheduled Task Functions
function New-TriggerScript {
    Write-Log "Creating trigger script..." -Level INFO
    
    if (-not (Test-Path $ScriptDir)) {
        New-Item -Path $ScriptDir -ItemType Directory -Force | Out-Null
    }
    
    $triggerScriptPath = Join-Path $ScriptDir "Trigger-AlwaysOnVPN.ps1"
    
    # Trigger script aligned with Trigger-AlwaysOnVPN.ps1 v3.0
    $triggerScriptContent = @'
# Always On VPN Connection Trigger Script v3.0

$LogFile = "C:\ProgramData\AOVPN\Logs\Trigger-Log.txt"
$VPNName = "AlwaysOnVPN"
$MaxLogSizeBytes = 1048576  # 1 MB
$CorpDomain = "corp.example.local"
$TestHost = "intranet.corp.example.local"
$StartupDelay = 45
$DetectionRetries = 5
$RetryDelay = 10

function Write-TriggerLog {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $LogFile -Append -Encoding UTF8 -ErrorAction SilentlyContinue
}

# Log rotation
try {
    if (Test-Path $LogFile) {
        $logSize = (Get-Item $LogFile).Length
        if ($logSize -gt $MaxLogSizeBytes) {
            $archivePath = $LogFile -replace '\.txt$', "-archived-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
            Copy-Item $LogFile $archivePath -Force -ErrorAction SilentlyContinue
            Get-Content $LogFile -Tail 500 | Set-Content $LogFile -Encoding UTF8
        }
    }
} catch {}

Write-TriggerLog "=== Trigger Script Started ==="

# Wait for network stack
Write-TriggerLog "Waiting $StartupDelay seconds for network initialization..."
Start-Sleep -Seconds $StartupDelay

# Check if already connected
try {
    $vpnStatus = Get-VpnConnection -Name $VPNName -AllUserConnection -ErrorAction SilentlyContinue
    if ($vpnStatus.ConnectionStatus -eq "Connected") {
        Write-TriggerLog "VPN already connected. Exiting."
        exit 0
    }
} catch {
    Write-TriggerLog "Error checking VPN status: $_"
}

# -----------------------------
# IMPROVED CORPORATE DETECTION
# -----------------------------

function Test-CorpNetwork {
    param (
        [string]$Domain,
        [string]$TestHostName
    )

    # Method 1: DNS suffix check
    try {
        $dnsClients = Get-DnsClient -ErrorAction SilentlyContinue
        foreach ($client in $dnsClients) {
            if ($client.ConnectionSpecificSuffix -like "*$Domain*") {
                Write-TriggerLog "Corp network detected via DNS suffix ($($client.InterfaceAlias))"
                return $true
            }
        }
    } catch {}

    # Method 2: Resolve internal hostname
    try {
        $result = Resolve-DnsName $TestHostName -ErrorAction Stop
        if ($result) {
            Write-TriggerLog "Corp network detected via DNS resolution ($TestHostName)"
            return $true
        }
    } catch {
        Write-TriggerLog "DNS resolution failed for $TestHostName"
    }

    return $false
}

$isOnCorpNetwork = $false

for ($i = 1; $i -le $DetectionRetries; $i++) {
    Write-TriggerLog "Corp network detection attempt $i of $DetectionRetries..."

    if (Test-CorpNetwork -Domain $CorpDomain -TestHostName $TestHost) {
        $isOnCorpNetwork = $true
        break
    }

    if ($i -lt $DetectionRetries) {
        Write-TriggerLog "Retrying in $RetryDelay seconds..."
        Start-Sleep -Seconds $RetryDelay
    }
}

if (-not $isOnCorpNetwork) {
    Write-TriggerLog "Not on corporate network after $DetectionRetries attempts"
}

# -----------------------------
# VPN CONNECTION LOGIC
# -----------------------------

if (-not $isOnCorpNetwork) {
    Write-TriggerLog "Attempting VPN connection..."

    $vpnServer = "vpn.example.org"
    $dnsReady = $false

    for ($i=1; $i -le 6; $i++) {
        try {
            $resolved = [System.Net.Dns]::GetHostAddresses($vpnServer) |
                        Where-Object { $_.AddressFamily -eq 'InterNetwork' }

            if ($resolved) {
                Write-TriggerLog "VPN server resolved: $($resolved[0].IPAddressToString)"
                $dnsReady = $true
                break
            }
        } catch {}

        Write-TriggerLog "VPN DNS attempt $i failed, retrying..."
        Start-Sleep -Seconds 5
    }

    if (-not $dnsReady) {
        Write-TriggerLog "ERROR: VPN server DNS failed. Aborting."
        exit 1
    }

    $connected = $false

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Write-TriggerLog "VPN connection attempt $attempt..."

        try {
            $output = rasdial $VPNName 2>&1 | Out-String
            Write-TriggerLog $output
        } catch {
            Write-TriggerLog "Rasdial error: $_"
        }

        Start-Sleep -Seconds 5

        try {
            $vpnStatus = Get-VpnConnection -Name $VPNName -AllUserConnection
            if ($vpnStatus.ConnectionStatus -eq "Connected") {
                Write-TriggerLog "VPN connected successfully"
                $connected = $true
                break
            }
        } catch {}

        Start-Sleep -Seconds 10
    }

    if (-not $connected) {
        Write-TriggerLog "ERROR: VPN failed to connect"
    }

} else {
    Write-TriggerLog "On corporate network. VPN not required."
}

Write-TriggerLog "=== Trigger Script Completed ==="

'@
    
    $triggerScriptContent | Set-Content -Path $triggerScriptPath -Encoding UTF8 -Force
    Write-Log "Trigger script created: $triggerScriptPath" -Level SUCCESS
    
    return $triggerScriptPath
}

function Register-StartupTriggerTask {
    param([string]$ScriptPath)
    
    Write-Log "Registering startup trigger task..." -Level INFO
    
    $taskName = "AOVPN-Trigger-Startup"
    
    # Remove if exists
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    } catch {}
    
    # Create action
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""
    
    # Create trigger (at startup, delay 30 seconds)
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = "PT30S"
    
    # Create principal (run as SYSTEM)
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    
    # Create settings
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew
    
    # Register task
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    
    Write-Log "Startup trigger task registered: $taskName" -Level SUCCESS
}

function Register-NetworkChangeTriggerTask {
    param([string]$ScriptPath)
    
    Write-Log "Registering network change trigger task..." -Level INFO
    
    $taskName = "AOVPN-Trigger-NetworkChange"
    
    # Remove if exists
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    } catch {}
    
    # Create action
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""
    
    # Create principal
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    
    # Create settings
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew
    
    # Register with XML for event trigger (network profile changes)
    $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Triggers Always On VPN connection when network profile changes</Description>
  </RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"&gt;&lt;Select Path="Microsoft-Windows-NetworkProfile/Operational"&gt;*[System[(EventID=10000) or (EventID=10001)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>true</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <DisallowStartOnRemoteAppSession>false</DisallowStartOnRemoteAppSession>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$ScriptPath"</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    
    Register-ScheduledTask -TaskName $taskName -Xml $taskXml -Force | Out-Null
    
    Write-Log "Network change trigger task registered: $taskName" -Level SUCCESS
}

function Register-NetworkAdapterTriggerTask {
    param([string]$ScriptPath)
    
    Write-Log "Registering network adapter trigger task..." -Level INFO
    
    $taskName = "AOVPN-Trigger-AdapterOnline"
    
    # Remove if exists
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    } catch {}
    
    # Create action
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""
    
    # Create principal
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    
    # Create settings
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew
    
    # Register with XML for event trigger (network adapter connected)
    $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Triggers Always On VPN when network adapter comes online</Description>
  </RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"&gt;&lt;Select Path="Microsoft-Windows-NetworkProfile/Operational"&gt;*[System[Provider[@Name='Microsoft-Windows-NetworkProfile'] and (EventID=10000)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
      <Delay>PT30S</Delay>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>true</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <DisallowStartOnRemoteAppSession>false</DisallowStartOnRemoteAppSession>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$ScriptPath"</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    
    Register-ScheduledTask -TaskName $taskName -Xml $taskXml -Force | Out-Null
    
    Write-Log "Network adapter trigger task registered: $taskName" -Level SUCCESS
}
#endregion

#region Registry Functions
function Set-DetectionRegistry {
    Write-Log "Creating detection registry key..." -Level INFO
    
    try {
        $regPath = "HKLM:\SOFTWARE\AOVPN"
        
        if (-not (Test-Path $regPath)) {
            New-Item -Path $regPath -Force | Out-Null
        }
        
        New-ItemProperty -Path $regPath -Name "Installed" -Value "1" -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $regPath -Name "Version" -Value "2.6" -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $regPath -Name "InstallDate" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $regPath -Name "VPNName" -Value $VPNName -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $regPath -Name "VPNServer" -Value $VPNServer -PropertyType String -Force | Out-Null
        
        Write-Log "Detection registry keys created" -Level SUCCESS
        
    } catch {
        Write-Log "Failed to create registry keys: $_" -Level WARN
    }
}
#endregion

#region Main Execution
try {
    Initialize-Logging
    Write-Log "========================================" -Level INFO
    Write-Log "Always On VPN Deployment Started" -Level INFO
    Write-Log "========================================" -Level INFO
    Write-Log "Script Version: 2.6 (Trigger v3 integrated)" -Level INFO
    Write-Log "Target VPN: $VPNName -> $VPNServer" -Level INFO
    Write-Log "Computer: $env:COMPUTERNAME" -Level INFO
    Write-Log ""
    
    # Step 1: Prerequisites
    Test-Prerequisites
    Write-Log ""
    
    # Step 2: Cleanup - Remove ALL existing VPN connections and tasks
    Remove-ExistingVPNConnections
    Remove-ExistingScheduledTasks
    Write-Log ""
    
    # Step 3: Force IPv4 by disabling IPv6
    Disable-IPv6OnInterfaces
    Write-Log ""
    
    # Step 4: Create VPN
    New-VPNConnection
    Add-VPNRoutes
    Set-DeviceTunnelConfiguration
    Write-Log ""
    
    # Step 5: Apply IKEv2 NAT-T registry fix (fixes Error 809)
    Set-IKEv2RegistryFix
    Write-Log ""
    
    # Step 6: Create Triggers
    $triggerScript = New-TriggerScript
    Register-StartupTriggerTask -ScriptPath $triggerScript
    Register-NetworkChangeTriggerTask -ScriptPath $triggerScript
    Register-NetworkAdapterTriggerTask -ScriptPath $triggerScript
    Write-Log ""
    
    # Step 7: Set Detection Key
    Set-DetectionRegistry
    Write-Log ""
    
    Write-Log "========================================" -Level SUCCESS
    Write-Log "Always On VPN Deployment Completed Successfully!" -Level SUCCESS
    Write-Log "========================================" -Level SUCCESS
    Write-Log ""
    Write-Log "CONFIGURATION SUMMARY:" -Level INFO
    Write-Log "  VPN Name: $VPNName" -Level INFO
    Write-Log "  Server: $VPNServer" -Level INFO
    Write-Log "  Tunnel Type: IKEv2" -Level INFO
    Write-Log "  Authentication: Machine Certificate" -Level INFO
    Write-Log "  Split Tunneling: Enabled" -Level INFO
    Write-Log "  System Tray Icon: Enabled" -Level INFO
    Write-Log "  Auto-Connect: When off corporate network" -Level INFO
    Write-Log ""
    Write-Log "Log file: $LogFile" -Level INFO
    Write-Log ""
    Write-Log "NEXT STEPS:" -Level INFO
    Write-Log "1. Reboot or trigger scheduled task to test auto-connection" -Level INFO
    Write-Log "2. Verify VPN icon appears in system tray when connected" -Level INFO
    Write-Log "3. Check trigger logs: C:\ProgramData\AOVPN\Logs\Trigger-Log.txt" -Level INFO
    Write-Log "4. Test connection from non-corporate network (WiFi hotspot)" -Level INFO
    Write-Log ""
    
    exit 0
    
} catch {
    Write-Log "========================================" -Level ERROR
    Write-Log "FATAL ERROR OCCURRED" -Level ERROR
    Write-Log "========================================" -Level ERROR
    Write-Log "Error: $_" -Level ERROR
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level ERROR
    Write-Log ""
    Write-Log "Deployment failed. Check log file for details: $LogFile" -Level ERROR
    exit 1
}
#endregion