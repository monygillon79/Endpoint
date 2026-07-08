# Template: replace placeholder domains, hosts, routes, OU paths, app IDs, and branding values before use.
<#
.SYNOPSIS
  Windows 11 24H2 SCCM OSD default branding/layout script.

.DESCRIPTION
  Sets DEFAULTS for new users during imaging without locking the settings down:
    - Start pins: LayoutModification.json copied into Default profile shell folder.
    - Taskbar pins: TaskbarLayoutModification.xml copied to C:\Windows\OEM and LayoutXMLPath is set in the target OS SOFTWARE hive.
    - Wallpaper: copied into C:\Windows\Web\Wallpaper\<BrandName>, seeded into Default User hive, and applied once per user through Active Setup.

  This script intentionally does NOT set HKLM wallpaper policy, NoChangingWallPaper, or recurring Start/Taskbar policy.
  Users can change the wallpaper, Start pins, and taskbar pins after first sign-in.

.BEST SCCM TASK SEQUENCE PLACEMENT
  Run this immediately AFTER "Apply Operating System Image" and BEFORE "Setup Windows and ConfigMgr".
  That timing matters because Windows reads the OEM taskbar LayoutXMLPath during specialize.

.PACKAGE CONTENTS
  Required:
    - This script
    - Wallpaper file, default: Org-Background.jpg

  Optional:
    - LayoutModification.json             # custom Start pins
    - TaskbarLayoutModification.xml       # custom taskbar pins

  If the optional layout files are not present, this script generates sane defaults:
    Start: File Explorer, Edge, new Outlook, new Teams
    Taskbar: File Explorer, Edge, new Outlook, new Teams

.NOTES
  Tested logic is designed for Windows 11 24H2 OSD flows. App pins only appear if the app/package exists for the user.
#>

[CmdletBinding()]
param(
    [string]$TargetDrive,
    [string]$RuntimeSystemDrive = 'C:',
    [string]$BrandName = 'ORG',
    [string]$WallpaperFileName = 'Org-Background.jpg',
    [string]$StartJsonFileName = 'LayoutModification.json',
    [string]$TaskbarXmlFileName = 'TaskbarLayoutModification.xml',
    [switch]$ApplyWallpaperToExistingProfiles
)

$ErrorActionPreference = 'Stop'

function Normalize-DriveRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = $Path.Trim().Trim('"')
    if ($p -match '^[A-Za-z]:$') { return "$p\" }
    return ($p.TrimEnd('\') + '\')
}

function Get-ScriptRootSafe {
    if ($PSScriptRoot) { return $PSScriptRoot }
    return (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

function Get-TaskSequenceVariable {
    param([string]$Name)
    try {
        $tsenv = New-Object -ComObject Microsoft.SMS.TSEnvironment
        return $tsenv.Value($Name)
    } catch {
        return $null
    }
}

function Get-TargetWindowsRoot {
    param([string]$SpecifiedDrive)

    $candidates = New-Object System.Collections.Generic.List[string]

    if ($SpecifiedDrive) { $candidates.Add($SpecifiedDrive) }

    foreach ($varName in @('OSDTargetSystemDrive','_SMSTSOSDTargetSystemDrive','SMSTSLocalDataDrive')) {
        $v = Get-TaskSequenceVariable -Name $varName
        if ($v) { $candidates.Add($v) }
    }

    if ($env:SystemDrive -and ($env:SystemDrive -ne 'X:')) { $candidates.Add($env:SystemDrive) }

    try {
        Get-PSDrive -PSProvider FileSystem | ForEach-Object {
            if ($_.Root -and ($_.Root -ne 'X:\')) { $candidates.Add($_.Root) }
        }
    } catch { }

    $uniqueCandidates = $candidates | Where-Object { $_ } | ForEach-Object { Normalize-DriveRoot $_ } | Select-Object -Unique

    foreach ($root in $uniqueCandidates) {
        if (Test-Path (Join-Path $root 'Windows\System32\Config\SOFTWARE')) {
            return $root
        }
    }

    throw 'Could not locate the target Windows installation. Pass -TargetDrive C: or the correct OS drive letter.'
}

function Ensure-Folder {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Force -Path $Path | Out-Null }
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    if ($script:LogFile) { $line | Out-File -FilePath $script:LogFile -Append -Encoding utf8 }
}

function Invoke-RegExe {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & reg.exe @Arguments 2>&1
    $exit = $LASTEXITCODE
    $text = ($output | Out-String).Trim()
    if ($exit -ne 0 -or $text -match '^ERROR:') {
        throw ('reg.exe {0} failed. Exit={1}. Output={2}' -f ($Arguments -join ' '), $exit, $text)
    }
    if ($text) { Write-Log $text }
}

function Load-Hive {
    param(
        [Parameter(Mandatory)][string]$HiveKey,
        [Parameter(Mandatory)][string]$HiveFile
    )
    Invoke-RegExe -Arguments @('load', $HiveKey, $HiveFile)
}

function Unload-Hive {
    param([Parameter(Mandatory)][string]$HiveKey)
    [gc]::Collect()
    [gc]::WaitForPendingFinalizers()
    Start-Sleep -Seconds 1

    for ($i = 1; $i -le 5; $i++) {
        try {
            Invoke-RegExe -Arguments @('unload', $HiveKey)
            return
        } catch {
            Write-Log "Hive unload attempt $i failed for $HiveKey. $_" 'WARN'
            Start-Sleep -Seconds 2
            [gc]::Collect()
            [gc]::WaitForPendingFinalizers()
        }
    }
    throw "Could not unload $HiveKey after 5 attempts."
}

function Reg-AddString {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    Invoke-RegExe -Arguments @('add', $Key, '/v', $Name, '/t', 'REG_SZ', '/d', $Value, '/f')
}

function Reg-AddDword {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Value
    )
    Invoke-RegExe -Arguments @('add', $Key, '/v', $Name, '/t', 'REG_DWORD', '/d', $Value.ToString(), '/f')
}

function New-DefaultStartJsonContent {
@'
{
  "applyOnce": true,
  "pinnedList": [
    { "desktopAppId": "Microsoft.Windows.Explorer" },
    { "desktopAppLink": "%ALLUSERSPROFILE%\\Microsoft\\Windows\\Start Menu\\Programs\\Microsoft Edge.lnk" },
    { "packagedAppId": "Microsoft.OutlookForWindows_8wekyb3d8bbwe!Microsoft.OutlookforWindows" },
    { "packagedAppId": "MSTeams_8wekyb3d8bbwe!MSTeams" }
  ]
}
'@
}

function New-DefaultTaskbarXmlContent {
@'
<?xml version="1.0" encoding="utf-8"?>
<LayoutModificationTemplate
    xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"
    xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout"
    xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout"
    Version="1">
  <CustomTaskbarLayoutCollection PinListPlacement="Replace">
    <defaultlayout:TaskbarLayout>
      <taskbar:TaskbarPinList>
        <taskbar:DesktopApp DesktopApplicationID="Microsoft.Windows.Explorer"/>
        <taskbar:DesktopApp DesktopApplicationLinkPath="%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk"/>
        <taskbar:UWA AppUserModelID="Microsoft.OutlookForWindows_8wekyb3d8bbwe!Microsoft.OutlookforWindows"/>
        <taskbar:UWA AppUserModelID="MSTeams_8wekyb3d8bbwe!MSTeams"/>
      </taskbar:TaskbarPinList>
    </defaultlayout:TaskbarLayout>
  </CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
'@
}

function Write-TextUtf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Install-StartLayoutDefault {
    param(
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][string]$StartJsonFileName
    )

    $defaultShell = Join-Path $TargetRoot 'Users\Default\AppData\Local\Microsoft\Windows\Shell'
    Ensure-Folder $defaultShell

    $source = Join-Path $ScriptRoot $StartJsonFileName
    $dest = Join-Path $defaultShell 'LayoutModification.json'

    if (Test-Path $source) {
        Copy-Item -Path $source -Destination $dest -Force
        Write-Log "Copied custom Start JSON to Default profile: $dest"
    } else {
        Write-TextUtf8NoBom -Path $dest -Content (New-DefaultStartJsonContent)
        Write-Log "Generated default Start JSON: $dest"
    }
}

function Install-TaskbarLayoutDefault {
    param(
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][string]$TaskbarXmlFileName,
        [Parameter(Mandatory)][bool]$TargetIsOnline
    )

    $oemDir = Join-Path $TargetRoot 'Windows\OEM'
    Ensure-Folder $oemDir

    $taskbarDest = Join-Path $oemDir 'TaskbarLayoutModification.xml'
    $source = Join-Path $ScriptRoot $TaskbarXmlFileName

    if (Test-Path $source) {
        Copy-Item -Path $source -Destination $taskbarDest -Force
        Write-Log "Copied custom Taskbar XML to: $taskbarDest"
    } else {
        Write-TextUtf8NoBom -Path $taskbarDest -Content (New-DefaultTaskbarXmlContent)
        Write-Log "Generated default Taskbar XML: $taskbarDest"
    }

    # Compatibility copy: some deployment flows also look in Default User's Shell folder.
    $defaultShell = Join-Path $TargetRoot 'Users\Default\AppData\Local\Microsoft\Windows\Shell'
    Ensure-Folder $defaultShell
    Copy-Item -Path $taskbarDest -Destination (Join-Path $defaultShell 'LayoutModification.xml') -Force
    Write-Log 'Copied compatibility LayoutModification.xml to Default profile shell folder.'

    $runtimeTaskbarXmlPath = Join-Path $RuntimeRoot 'Windows\OEM\TaskbarLayoutModification.xml'

    if ($TargetIsOnline) {
        $explorerKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'
        if (-not (Test-Path $explorerKey)) { New-Item -Path $explorerKey -Force | Out-Null }
        Set-ItemProperty -Path $explorerKey -Name 'LayoutXMLPath' -Type String -Value $runtimeTaskbarXmlPath
        Write-Log "Set live LayoutXMLPath to $runtimeTaskbarXmlPath"
        Write-Log 'Warning: For best taskbar reliability, run this script before Setup Windows and ConfigMgr. If run after specialize/OOBE, the OEM taskbar layout may already have been missed.' 'WARN'
    } else {
        $softwareHive = Join-Path $TargetRoot 'Windows\System32\Config\SOFTWARE'
        $hiveKey = 'HKLM\Org_Offline_SOFTWARE'
        $loaded = $false
        try {
            Load-Hive -HiveKey $hiveKey -HiveFile $softwareHive
            $loaded = $true
            Reg-AddString -Key "$hiveKey\Microsoft\Windows\CurrentVersion\Explorer" -Name 'LayoutXMLPath' -Value $runtimeTaskbarXmlPath
            Write-Log "Set offline LayoutXMLPath to $runtimeTaskbarXmlPath"
        } finally {
            if ($loaded) { Unload-Hive -HiveKey $hiveKey }
        }
    }
}

function Install-WallpaperDefault {
    param(
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][string]$WallpaperFileName,
        [Parameter(Mandatory)][string]$BrandName,
        [Parameter(Mandatory)][bool]$TargetIsOnline
    )

    $source = Join-Path $ScriptRoot $WallpaperFileName
    if (-not (Test-Path $source)) { throw "Wallpaper source missing: $source" }

    $wallDirTarget = Join-Path $TargetRoot ("Windows\Web\Wallpaper\$BrandName")
    Ensure-Folder $wallDirTarget
    $wallTargetPath = Join-Path $wallDirTarget $WallpaperFileName
    Copy-Item -Path $source -Destination $wallTargetPath -Force
    Write-Log "Copied wallpaper to: $wallTargetPath"

    $runtimeWallpaperPath = Join-Path $RuntimeRoot ("Windows\Web\Wallpaper\$BrandName\$WallpaperFileName")

    # Seed Default User hive. This affects newly created profiles but does not lock anything.
    $defaultHiveFile = Join-Path $TargetRoot 'Users\Default\NTUSER.DAT'
    if (-not (Test-Path $defaultHiveFile)) { throw "Default User hive not found: $defaultHiveFile" }

    $defaultHiveKey = 'HKU\Org_DefaultUser'
    $loadedDefault = $false
    try {
        Load-Hive -HiveKey $defaultHiveKey -HiveFile $defaultHiveFile
        $loadedDefault = $true
        Reg-AddString -Key "$defaultHiveKey\Control Panel\Desktop" -Name 'Wallpaper' -Value $runtimeWallpaperPath
        Reg-AddString -Key "$defaultHiveKey\Control Panel\Desktop" -Name 'WallpaperStyle' -Value '0'
        Reg-AddString -Key "$defaultHiveKey\Control Panel\Desktop" -Name 'TileWallpaper' -Value '0'
        Reg-AddString -Key "$defaultHiveKey\Control Panel\Colors" -Name 'Background' -Value '0 0 0'
        Write-Log 'Seeded Default User wallpaper values. WallpaperStyle=0 means Center; TileWallpaper=0 means no tile.'
    } finally {
        if ($loadedDefault) { Unload-Hive -HiveKey $defaultHiveKey }
    }

    # Active Setup fallback: applies the wallpaper once per user at first sign-in, then leaves them alone.
    $programDataTarget = Join-Path $TargetRoot 'ProgramData\OrgBranding'
    Ensure-Folder $programDataTarget

    $perUserScriptTarget = Join-Path $programDataTarget 'Apply-DefaultWallpaper-Once.ps1'
    $perUserScriptRuntime = Join-Path $RuntimeRoot 'ProgramData\OrgBranding\Apply-DefaultWallpaper-Once.ps1'
    $perUserLogRuntime = Join-Path $RuntimeRoot "OrgLogs\Win11-Branding-Defaults\Apply-DefaultWallpaper-Once.log"

    $perUserContent = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$log = '$perUserLogRuntime'
`$logDir = Split-Path -Parent `$log
if (-not (Test-Path `$logDir)) { New-Item -ItemType Directory -Force -Path `$logDir | Out-Null }
function Write-PerUserLog([string]`$Message) {
    '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), `$Message | Out-File -FilePath `$log -Append -Encoding utf8
}
Write-PerUserLog 'Applying default wallpaper once for this user.'
`$wallpaper = '$runtimeWallpaperPath'
New-Item -Path 'HKCU:\Control Panel\Desktop' -Force | Out-Null
Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Type String -Value `$wallpaper
Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Type String -Value '0'
Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Type String -Value '0'
New-Item -Path 'HKCU:\Control Panel\Colors' -Force | Out-Null
Set-ItemProperty -Path 'HKCU:\Control Panel\Colors' -Name Background -Type String -Value '0 0 0'
rundll32.exe user32.dll,UpdatePerUserSystemParameters 1,True | Out-Null
Write-PerUserLog "Default wallpaper applied. User may change it afterward. Wallpaper=`$wallpaper"
"@
    Write-TextUtf8NoBom -Path $perUserScriptTarget -Content $perUserContent
    Write-Log "Created per-user wallpaper fallback script: $perUserScriptTarget"

    $activeSetupGuid = '{A05C7F7D-0E5B-4B4D-92D8-9F1B8C1F2424}'
    $activeSetupStub = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$perUserScriptRuntime`""

    if ($TargetIsOnline) {
        foreach ($key in @(
            "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\$activeSetupGuid",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Active Setup\Installed Components\$activeSetupGuid"
        )) {
            if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
            Set-ItemProperty -Path $key -Name '(Default)' -Type String -Value 'Apply default wallpaper once'
            Set-ItemProperty -Path $key -Name 'Version' -Type String -Value '1,0,0,0'
            Set-ItemProperty -Path $key -Name 'StubPath' -Type String -Value $activeSetupStub
            Set-ItemProperty -Path $key -Name 'IsInstalled' -Type DWord -Value 1
        }
        Write-Log 'Registered Active Setup in live HKLM.'
    } else {
        $softwareHive = Join-Path $TargetRoot 'Windows\System32\Config\SOFTWARE'
        $hiveKey = 'HKLM\Org_Offline_SOFTWARE'
        $loadedSoftware = $false
        try {
            Load-Hive -HiveKey $hiveKey -HiveFile $softwareHive
            $loadedSoftware = $true
            foreach ($relativeKey in @(
                "Microsoft\Active Setup\Installed Components\$activeSetupGuid",
                "WOW6432Node\Microsoft\Active Setup\Installed Components\$activeSetupGuid"
            )) {
                $fullKey = "$hiveKey\$relativeKey"
                Reg-AddString -Key $fullKey -Name '(Default)' -Value 'Apply default wallpaper once'
                Reg-AddString -Key $fullKey -Name 'Version' -Value '1,0,0,0'
                Reg-AddString -Key $fullKey -Name 'StubPath' -Value $activeSetupStub
                Reg-AddDword  -Key $fullKey -Name 'IsInstalled' -Value 1
            }
            Write-Log 'Registered Active Setup in offline SOFTWARE hive.'
        } finally {
            if ($loadedSoftware) { Unload-Hive -HiveKey $hiveKey }
        }
    }
}

function Set-WallpaperForLoadedUsers {
    param([Parameter(Mandatory)][string]$RuntimeWallpaperPath)

    Get-ChildItem -Path 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } |
        ForEach-Object {
            $sid = $_.PSChildName
            try {
                $base = "Registry::HKEY_USERS\$sid"
                New-Item -Path "$base\Control Panel\Desktop" -Force | Out-Null
                Set-ItemProperty -Path "$base\Control Panel\Desktop" -Name 'Wallpaper' -Type String -Value $RuntimeWallpaperPath
                Set-ItemProperty -Path "$base\Control Panel\Desktop" -Name 'WallpaperStyle' -Type String -Value '0'
                Set-ItemProperty -Path "$base\Control Panel\Desktop" -Name 'TileWallpaper' -Type String -Value '0'
                New-Item -Path "$base\Control Panel\Colors" -Force | Out-Null
                Set-ItemProperty -Path "$base\Control Panel\Colors" -Name 'Background' -Type String -Value '0 0 0'
                Write-Log "Updated wallpaper values for loaded user SID $sid"
            } catch {
                Write-Log "Failed to update loaded user SID $sid. $_" 'WARN'
            }
        }
}

try {
    $scriptRoot = Get-ScriptRootSafe
    $targetRoot = Get-TargetWindowsRoot -SpecifiedDrive $TargetDrive
    $runtimeRoot = Normalize-DriveRoot $RuntimeSystemDrive
    if (-not $runtimeRoot) { throw 'RuntimeSystemDrive could not be normalized.' }

    $logRoot = Join-Path $targetRoot 'OrgLogs\Win11-Branding-Defaults'
    Ensure-Folder $logRoot
    $script:LogFile = Join-Path $logRoot 'Set-Win11-24H2-UserCustomizableDefaults.log'
    '[{0}] [INFO] ========= Script starting =========' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Out-File -FilePath $script:LogFile -Force -Encoding utf8

    $systemRootDrive = Normalize-DriveRoot ([System.IO.Path]::GetPathRoot($env:SystemRoot))
    $targetIsOnline = ($systemRootDrive -and ($systemRootDrive.TrimEnd('\') -ieq $targetRoot.TrimEnd('\')))

    Write-Log "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Log "Script root: $scriptRoot"
    Write-Log "Target Windows root: $targetRoot"
    Write-Log "Runtime Windows root used inside registry/default profiles: $runtimeRoot"
    Write-Log "Target appears online: $targetIsOnline"

    Install-StartLayoutDefault -TargetRoot $targetRoot -ScriptRoot $scriptRoot -StartJsonFileName $StartJsonFileName
    Install-TaskbarLayoutDefault -TargetRoot $targetRoot -RuntimeRoot $runtimeRoot -ScriptRoot $scriptRoot -TaskbarXmlFileName $TaskbarXmlFileName -TargetIsOnline $targetIsOnline
    Install-WallpaperDefault -TargetRoot $targetRoot -RuntimeRoot $runtimeRoot -ScriptRoot $scriptRoot -WallpaperFileName $WallpaperFileName -BrandName $BrandName -TargetIsOnline $targetIsOnline

    if ($ApplyWallpaperToExistingProfiles -and $targetIsOnline) {
        $runtimeWallpaper = Join-Path $runtimeRoot ("Windows\Web\Wallpaper\$BrandName\$WallpaperFileName")
        Set-WallpaperForLoadedUsers -RuntimeWallpaperPath $runtimeWallpaper
        Write-Log 'Applied wallpaper values to currently loaded profiles. This still does not lock the wallpaper.'
    } elseif ($ApplyWallpaperToExistingProfiles -and -not $targetIsOnline) {
        Write-Log '-ApplyWallpaperToExistingProfiles was ignored because the target OS is offline.' 'WARN'
    }

    Write-Log 'No enforcing wallpaper/start/taskbar policy was configured. Users can change these settings after first sign-in.'
    Write-Log '========= Script completed successfully ========='
    exit 0
}
catch {
    if ($script:LogFile) {
        Write-Log "FATAL: $_" 'ERROR'
        Write-Log "$($_.ScriptStackTrace)" 'ERROR'
    } else {
        Write-Host "FATAL: $_"
    }
    exit 1
}
