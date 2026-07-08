# Template: replace placeholder domains, hosts, routes, OU paths, app IDs, and branding values before use.
<# 
  SYSTEM-level Win11 24H2 branding + layout configurator (SCCM-safe)
  All-in-one FIXED v5

  Changes vs v4:
  - Adds NEW-USER RunOnce fallback (in Default user hive) to call the per-user wallpaper script on first logon.
    This is in addition to Active Setup. On Win11 24H2 this improves reliability for "new users not getting wallpaper".
  - Improves reg.exe add logging: captures stdout/stderr and flags "ERROR:" text even if exit code is misleading.
  - Keeps: HKLM wallpaper policy (all users), loaded+offline profile wallpaper, lock screen, default profile layouts.
#>

[CmdletBinding()]
param(
  [string]$WallpaperFileName   = "Org-Background.jpg",
  [string]$LockScreenFileName  = "LockScreen.jpg",
  [string]$StartJsonFileName   = "LayoutModification.json",
  [string]$TaskbarXmlFileName  = "LayoutModification.xml",
  [string]$LogDir              = "C:\ProgramData\OrgLogs\Win11-Branding"
)

$ErrorActionPreference = "Stop"

#region Logging
function Initialize-Logging {
  if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
  $script:LogFile = Join-Path $LogDir "Set-Win11Branding.log"
  "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [INFO] ========== Script starting ==========" |
    Out-File -FilePath $script:LogFile -Force -Encoding utf8
}
function Write-Log {
  param([Parameter(Mandatory)][string]$Message,[ValidateSet("INFO","WARN","ERROR")][string]$Level="INFO")
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  "[$ts] [$Level] $Message" | Out-File -FilePath $script:LogFile -Append -Encoding utf8
}
Initialize-Logging
#endregion

#region Helpers
function Ensure-Folder([Parameter(Mandatory)][string]$Path) {
  if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Force -Path $Path | Out-Null }
}
function Ensure-RegKey([Parameter(Mandatory)][string]$Path) {
  if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
}

function Invoke-RegAdd {
  param(
    [Parameter(Mandatory)][string]$Key,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Type,
    [Parameter(Mandatory)][string]$Data
  )
  $args = @("add", $Key, "/v", $Name, "/t", $Type, "/d", $Data, "/f")
  $out = & reg.exe @args 2>&1
  $code = $LASTEXITCODE
  $outText = ($out | Out-String).Trim()

  $looksBad = ($code -ne 0) -or ($outText -match 'ERROR:\s')
  if ($looksBad) {
    Write-Log ("reg.exe add FAILED (exit={0}) Key={1} Name={2} Type={3} Data={4} Output={5}" -f $code,$Key,$Name,$Type,$Data,$outText) "WARN"
  } else {
    Write-Log ("reg.exe add OK Key={0} Name={1}" -f $Key, $Name)
  }
  return (-not $looksBad)
}

function Get-LoadedUserSIDs {
  try {
    Get-ChildItem -Path "Registry::HKEY_USERS" -ErrorAction SilentlyContinue |
      Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } |
      Select-Object -ExpandProperty PSChildName
  } catch { @() }
}
function Get-UserProfileDirectories {
  Get-ChildItem -Path "C:\Users" -Directory -ErrorAction SilentlyContinue |
    Where-Object {
      $_.Name -notin @("Default", "Public", "All Users", "Default User") -and
      $_.Name -notlike "WDAGUtilityAccount*" -and
      $_.Name -notlike "DefaultAppPool*" -and
      $_.Name -notlike "Administrator*" -and
      $_.Name -notlike "S-1-5-*"
    }
}
function Get-ProfilePathFromSID([Parameter(Mandatory)][string]$SID) {
  $profileList = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$SID"
  try {
    if (Test-Path $profileList) {
      return (Get-ItemProperty -Path $profileList -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath
    }
  } catch { }
  $null
}
function Invoke-SafeHiveUnload([Parameter(Mandatory)][string]$HiveKey) {
  [gc]::Collect(); [gc]::WaitForPendingFinalizers(); Start-Sleep -Seconds 1
  for ($i=1; $i -le 5; $i++) {
    & reg.exe unload "$HiveKey" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { return $true }
    Write-Log ("Hive unload attempt {0} failed for {1} (exit={2}). Retrying..." -f $i,$HiveKey,$LASTEXITCODE) "WARN"
    Start-Sleep -Seconds 2
    [gc]::Collect(); [gc]::WaitForPendingFinalizers()
  }
  Write-Log ("Failed to unload hive {0} after 5 attempts." -f $HiveKey) "ERROR"
  $false
}

function Set-WallpaperRegistryForHive {
  param([Parameter(Mandatory)][string]$HiveRoot,[Parameter(Mandatory)][string]$WallpaperPath)

  $desktopKey = Join-Path $HiveRoot "Control Panel\Desktop"
  if (-not (Test-Path $desktopKey)) { New-Item -Path $desktopKey -Force | Out-Null }
  Set-ItemProperty -Path $desktopKey -Name "Wallpaper"      -Type String -Value $WallpaperPath
  Set-ItemProperty -Path $desktopKey -Name "WallpaperStyle" -Type String -Value "0"
  Set-ItemProperty -Path $desktopKey -Name "TileWallpaper"  -Type String -Value "0"

  $colorsKey = Join-Path $HiveRoot "Control Panel\Colors"
  if (-not (Test-Path $colorsKey)) { New-Item -Path $colorsKey -Force | Out-Null }
  Set-ItemProperty -Path $colorsKey -Name "Background" -Type String -Value "0 0 0"
}

function Set-MachineWallpaperPolicy([Parameter(Mandatory)][string]$WallpaperPath) {
  $sysPolicyKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
  Ensure-RegKey $sysPolicyKey
  Set-ItemProperty -Path $sysPolicyKey -Name "Wallpaper"      -Type String -Value $WallpaperPath
  Set-ItemProperty -Path $sysPolicyKey -Name "WallpaperStyle" -Type String -Value "0"
  Write-Log ("HKLM wallpaper policy configured: {0} (Center)" -f $WallpaperPath)
}

function Set-LockScreenPolicy([Parameter(Mandatory)][string]$LockScreenPath) {
  $cloudContentKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
  Ensure-RegKey $cloudContentKey
  Set-ItemProperty -Path $cloudContentKey -Name "DisableWindowsSpotlightFeatures"     -Type DWord -Value 1
  Set-ItemProperty -Path $cloudContentKey -Name "DisableWindowsSpotlightOnLockScreen" -Type DWord -Value 1

  $policyKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
  Ensure-RegKey $policyKey
  Set-ItemProperty -Path $policyKey -Name "LockScreenImage"            -Type String -Value $LockScreenPath
  Set-ItemProperty -Path $policyKey -Name "LockScreenOverlaysDisabled" -Type DWord  -Value 1

  $cspKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP"
  Ensure-RegKey $cspKey
  Set-ItemProperty -Path $cspKey -Name "LockScreenImagePath"   -Type String -Value $LockScreenPath
  Set-ItemProperty -Path $cspKey -Name "LockScreenImageUrl"    -Type String -Value $LockScreenPath
  Set-ItemProperty -Path $cspKey -Name "LockScreenImageStatus" -Type DWord  -Value 1

  Write-Log ("Lock screen policy configured: {0}" -f $LockScreenPath)
}

function Install-DefaultProfileLayouts {
  param([Parameter(Mandatory)][string]$StartJsonSrc,[Parameter(Mandatory)][string]$TaskbarXmlSrc)
  $defaultShellDir = "C:\Users\Default\AppData\Local\Microsoft\Windows\Shell"
  Ensure-Folder $defaultShellDir

  if (Test-Path $StartJsonSrc) {
    $dest = Join-Path $defaultShellDir "LayoutModification.json"
    Copy-Item -Path $StartJsonSrc -Destination $dest -Force
    Write-Log ("Default profile Start JSON deployed: {0}" -f $dest)
  } else { Write-Log ("Start JSON not found: {0}" -f $StartJsonSrc) "WARN" }

  if (Test-Path $TaskbarXmlSrc) {
    $dest = Join-Path $defaultShellDir "LayoutModification.xml"
    Copy-Item -Path $TaskbarXmlSrc -Destination $dest -Force
    Write-Log ("Default profile Taskbar XML deployed: {0}" -f $dest)
  } else { Write-Log ("Taskbar XML not found: {0}" -f $TaskbarXmlSrc) "WARN" }
}

function Install-ActiveSetupWallpaperRefresh {
  param([Parameter(Mandatory)][string]$WallpaperPath,[Parameter(Mandatory)][string]$LogDir)

  $activeSetupDir = "C:\ProgramData\OrgBranding"
  Ensure-Folder $activeSetupDir

  $perUserScript = Join-Path $activeSetupDir "Apply-Wallpaper-PerUser.ps1"
  $perUserLog    = Join-Path $LogDir "Apply-Wallpaper-PerUser.log"

  $content = @"
`$ErrorActionPreference = 'SilentlyContinue'
function Write-PerUserLog([string]`$msg) {
  try { `"[{0}] {1}`" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), `$msg | Out-File -FilePath '$perUserLog' -Append -Encoding utf8 } catch { }
}
Write-PerUserLog 'Per-user wallpaper apply starting (Active Setup/RunOnce).'
`$wall = '$WallpaperPath'
New-Item -Path 'HKCU:\Control Panel\Desktop' -Force | Out-Null
Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper      -Type String -Value `$wall
Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Type String -Value '0'
Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper  -Type String -Value '0'
New-Item -Path 'HKCU:\Control Panel\Colors' -Force | Out-Null
Set-ItemProperty -Path 'HKCU:\Control Panel\Colors' -Name Background -Type String -Value '0 0 0'
rundll32.exe user32.dll,UpdatePerUserSystemParameters 1,True | Out-Null
Write-PerUserLog ('Per-user wallpaper apply completed. Wallpaper={0}' -f `$wall)
"@
  Set-Content -Path $perUserScript -Value $content -Encoding UTF8 -Force
  Write-Log ("Per-user script created: {0}" -f $perUserScript)

  $guid = "{B2D1B6F7-4A75-4D5C-9A9E-3C3C9D6D8F01}"
  $stub = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$perUserScript`""

  foreach ($key in @(
    "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\$guid",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Active Setup\Installed Components\$guid"
  )) {
    Ensure-RegKey $key
    Set-ItemProperty -Path $key -Name "(Default)" -Type String -Value "Org Wallpaper Apply"
    Set-ItemProperty -Path $key -Name "Version"   -Type String -Value "1,0,0,0"
    Set-ItemProperty -Path $key -Name "StubPath"  -Type String -Value $stub
  }
  Write-Log ("Active Setup registered (runs once per user). GUID={0}" -f $guid)
  return @{ ScriptPath = $perUserScript; Stub = $stub }
}

function Configure-DefaultUserHive {
  param(
    [Parameter(Mandatory)][string]$DefaultNtUser,
    [Parameter(Mandatory)][string]$WallpaperPath,
    [Parameter(Mandatory)][string]$PerUserScriptPath
  )

  if (-not (Test-Path $DefaultNtUser)) {
    Write-Log ("Default user NTUSER.DAT not found: {0}" -f $DefaultNtUser) "WARN"
    return
  }

  $hiveKey = "HKU\DefaultProfile"
  $loaded = $false
  try {
    Write-Log ("Loading Default user hive: {0}" -f $DefaultNtUser)
    $out = & reg.exe load "$hiveKey" "$DefaultNtUser" 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("reg load failed exit={0} output={1}" -f $LASTEXITCODE,($out|Out-String)) }
    $loaded = $true

    # Wallpaper + black background for NEW profiles
    Invoke-RegAdd -Key "$hiveKey\Control Panel\Desktop" -Name "Wallpaper"      -Type "REG_SZ" -Data "$WallpaperPath" | Out-Null
    Invoke-RegAdd -Key "$hiveKey\Control Panel\Desktop" -Name "WallpaperStyle" -Type "REG_SZ" -Data "0" | Out-Null
    Invoke-RegAdd -Key "$hiveKey\Control Panel\Desktop" -Name "TileWallpaper"  -Type "REG_SZ" -Data "0" | Out-Null
    Invoke-RegAdd -Key "$hiveKey\Control Panel\Colors"  -Name "Background"     -Type "REG_SZ" -Data "0 0 0" | Out-Null
    Write-Log "Default profile wallpaper + black background configured."

    # IMPORTANT: RunOnce fallback for brand-new users (more reliable than Active Setup alone in some 24H2 builds)
    $runOnceKey = "$hiveKey\Software\Microsoft\Windows\CurrentVersion\RunOnce"
    $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PerUserScriptPath`""
    Invoke-RegAdd -Key $runOnceKey -Name "OrgWallpaperApply" -Type "REG_SZ" -Data $cmd | Out-Null
    Write-Log ("Default profile RunOnce added to apply wallpaper at first logon: {0}" -f $cmd)
  }
  catch {
    Write-Log ("Error configuring Default profile hive: {0}" -f $_) "WARN"
  }
  finally {
    if ($loaded) {
      Invoke-SafeHiveUnload -HiveKey $hiveKey | Out-Null
      Write-Log "Default profile hive unloaded."
    }
  }
}

function Set-WallpaperForLoadedUsers([Parameter(Mandatory)][string]$WallpaperPath) {
  foreach ($sid in (Get-LoadedUserSIDs)) {
    try {
      Set-WallpaperRegistryForHive -HiveRoot ("Registry::HKEY_USERS\{0}" -f $sid) -WallpaperPath $WallpaperPath
      Write-Log ("Wallpaper configured for loaded user SID: {0}" -f $sid)
    } catch {
      Write-Log ("Failed to set wallpaper for loaded SID {0}: {1}" -f $sid, $_) "WARN"
    }
  }
}

function Set-WallpaperForOfflineProfiles([Parameter(Mandatory)][string]$WallpaperPath) {
  $loadedSIDs  = Get-LoadedUserSIDs
  $loadedPaths = $loadedSIDs | ForEach-Object { Get-ProfilePathFromSID -SID $_ } | Where-Object { $_ }

  foreach ($profile in Get-UserProfileDirectories) {
    if ($profile.Name -eq "defaultuser0") { continue }
    $ntUser = Join-Path $profile.FullName "NTUSER.DAT"
    if (-not (Test-Path $ntUser)) { continue }

    if ($profile.FullName -in $loadedPaths) {
      Write-Log ("Profile {0} already loaded, skipping offline hive." -f $profile.Name)
      continue
    }

    $tempHiveName = "Offline_" + ([guid]::NewGuid().ToString("N"))
    $hiveKey  = "HKU\$tempHiveName"
    $loaded = $false

    try {
      Write-Log ("Loading offline hive for {0} ({1})" -f $profile.Name, $ntUser)
      $out = & reg.exe load "$hiveKey" "$ntUser" 2>&1
      if ($LASTEXITCODE -ne 0) { throw ("reg load failed exit={0} output={1}" -f $LASTEXITCODE,($out|Out-String)) }
      $loaded = $true

      $hiveRoot = "Registry::HKEY_USERS\$tempHiveName"
      Set-WallpaperRegistryForHive -HiveRoot $hiveRoot -WallpaperPath $WallpaperPath
      Write-Log ("Wallpaper configured for offline profile: {0}" -f $profile.Name)
    }
    catch {
      Write-Log ("Offline wallpaper config failed for {0}: {1}" -f $profile.Name, $_) "WARN"
    }
    finally {
      if ($loaded) {
        Invoke-SafeHiveUnload -HiveKey $hiveKey | Out-Null
        Write-Log ("Offline hive unloaded for: {0}" -f $profile.Name)
      }
    }
  }
}
#endregion

try {
  Write-Log ("Running as: {0}" -f ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name))
  $cv = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
  Write-Log ("OS: {0} Build: {1}.{2}" -f $cv.ProductName, $cv.CurrentBuild, $cv.UBR)

  $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
  Write-Log ("Script directory: {0}" -f $scriptDir)

  # Source files
  $wallSrc = Join-Path $scriptDir $WallpaperFileName
  $lockSrc = Join-Path $scriptDir $LockScreenFileName
  $jsonSrc = Join-Path $scriptDir $StartJsonFileName
  $xmlSrc  = Join-Path $scriptDir $TaskbarXmlFileName

  # Destinations
  $wallDstDir = "C:\Windows\Web\Wallpaper\ORG"
  $wallDst    = Join-Path $wallDstDir $WallpaperFileName
  $lockDstDir = "C:\Windows\Web\Screen"
  $lockDst    = Join-Path $lockDstDir $LockScreenFileName
  $lockBackupDir = "C:\Windows\Org-LockScreen"
  $lockBackup    = Join-Path $lockBackupDir $LockScreenFileName
  $defaultNtUser  = "C:\Users\Default\NTUSER.DAT"

  # 1) Copy wallpaper (JPG)
  if (-not (Test-Path $wallSrc)) { throw ("Wallpaper source missing: {0}" -f $wallSrc) }
  Ensure-Folder $wallDstDir
  Copy-Item -Path $wallSrc -Destination $wallDst -Force
  Write-Log ("Wallpaper copied: {0}" -f $wallDst)

  # 2) Enforce wallpaper for ALL users (HKLM policy)
  Set-MachineWallpaperPolicy -WallpaperPath $wallDst

  # 3) Create per-user apply script + Active Setup
  $pu = Install-ActiveSetupWallpaperRefresh -WallpaperPath $wallDst -LogDir $LogDir
  $perUserScriptPath = $pu.ScriptPath

  # 4) Best-effort immediate apply for existing users
  Set-WallpaperForLoadedUsers -WallpaperPath $wallDst
  Set-WallpaperForOfflineProfiles -WallpaperPath $wallDst

  # 5) Lock screen (optional)
  if (Test-Path $lockSrc) {
    Ensure-Folder $lockDstDir
    Copy-Item -Path $lockSrc -Destination $lockDst -Force
    Ensure-Folder $lockBackupDir
    Copy-Item -Path $lockSrc -Destination $lockBackup -Force
    Set-LockScreenPolicy -LockScreenPath $lockDst
  }

  # 6) NEW USERS ONLY: Default profile layout files
  Install-DefaultProfileLayouts -StartJsonSrc $jsonSrc -TaskbarXmlSrc $xmlSrc

  # 7) NEW USERS ONLY: Default profile wallpaper + black background + RunOnce fallback
  Configure-DefaultUserHive -DefaultNtUser $defaultNtUser -WallpaperPath $wallDst -PerUserScriptPath $perUserScriptPath

  Write-Log "========== Script completed successfully =========="
  exit 0
}
catch {
  Write-Log ("FATAL: {0}" -f $_) "ERROR"
  Write-Log ($_.ScriptStackTrace) "ERROR"
  exit 1
}
