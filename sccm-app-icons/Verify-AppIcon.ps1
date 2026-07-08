param (
    [string]$AppName    = "7-Zip 24.09",
    [string]$SiteCode   = "",
    [string]$SiteServer = "",
    [switch]$RefreshClient
)

Set-StrictMode -Version 1
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK   { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Fail { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Write-Info { param([string]$m) Write-Host "  [INFO] $m" -ForegroundColor White }

Write-Step "Resolving SCCM site"

if (-not $SiteCode) {
    $reg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\SMS\Setup" -ErrorAction SilentlyContinue
    $SiteCode = $reg."Site Code"
}
if (-not $SiteServer) { $SiteServer = $env:COMPUTERNAME }
if (-not $SiteCode) { Write-Fail "Could not detect site code. Pass -SiteCode P01"; exit 1 }

Write-OK "Site: $SiteCode  |  Server: $SiteServer"

Write-Step "Loading ConfigurationManager module"

$modulePath = $null
$regPaths = @(
    "HKLM:\SOFTWARE\Microsoft\ConfigMgr10\Setup",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\ConfigMgr10\Setup"
)
foreach ($rp in $regPaths) {
    if (Test-Path $rp) {
        $ui = (Get-ItemProperty $rp -ErrorAction SilentlyContinue)."UI Installation Directory"
        if ($ui) {
            $c = Join-Path $ui "bin\ConfigurationManager.psd1"
            if (Test-Path $c) { $modulePath = $c; break }
        }
    }
}
if (-not $modulePath) {
    $f = Get-ChildItem "C:\Program Files*" -Recurse -Filter "ConfigurationManager.psd1" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { $modulePath = $f.FullName }
}
if (-not $modulePath) { Write-Fail "ConfigurationManager.psd1 not found."; exit 1 }
if (-not (Get-Module ConfigurationManager)) { Import-Module $modulePath -ErrorAction Stop }
Write-OK "Module: $modulePath"

$prevLoc = Get-Location
if (-not (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue)) {
    New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer | Out-Null
}
Set-Location "${SiteCode}:"

Write-Step "Reading application from SCCM: '$AppName'"
$app = Get-CMApplication -Name $AppName -ErrorAction SilentlyContinue
if (-not $app) {
    Set-Location $prevLoc
    Write-Fail "Application not found: '$AppName'"
    exit 1
}
Write-OK "Found: $($app.LocalizedDisplayName)  (CI_ID: $($app.CI_ID))"

Write-Step "Checking icon via Get-CMApplication"
$iconProp = $app.PSObject.Properties["Icon"]
if ($iconProp -and $iconProp.Value) {
    Write-OK "app.Icon is populated: $($iconProp.Value.Length) base64 chars"
} else {
    Write-Info "app.Icon property not available via Get-CMApplication (normal for some SCCM versions) -- using WMI check below."
}

Write-Step "Reading icon data from SMS_Application via WMI"
Set-Location $prevLoc

$escapedName = $AppName -replace "'", "''"
$wmiNS   = "root\SMS\site_$SiteCode"
$wmiApp  = Get-WmiObject -Namespace $wmiNS -ComputerName $SiteServer -Class SMS_Application `
               -Filter "LocalizedDisplayName='$escapedName' AND IsLatest=1" `
               -ErrorAction SilentlyContinue | Select-Object -First 1

if (-not $wmiApp) {
    $wmiApp = Get-WmiObject -Namespace $wmiNS -ComputerName $SiteServer -Class SMS_Application `
                  -Filter "CI_ID=$($app.CI_ID) AND IsLatest=1" `
                  -ErrorAction SilentlyContinue | Select-Object -First 1
}

if ($wmiApp) {
    $wmiApp.Get()

    # Try direct Icon lazy property first; fall back to SDMPackageXML parsing
    $iconB64 = $null
    $iconPropWmi = $wmiApp.PSObject.Properties["Icon"]
    if ($iconPropWmi -and -not [string]::IsNullOrWhiteSpace($iconPropWmi.Value)) {
        $iconB64 = $iconPropWmi.Value
        Write-Info "Icon source: SMS_Application.Icon (lazy property)"
    } else {
        Write-Info "Icon lazy property not present -- checking SDMPackageXML..."
        $xml = $wmiApp.SDMPackageXML
        if ($xml) {
            # Icon is base64 encoded inside <Icon><Data>...</Data></Icon> in the XML
            if ($xml -match '<Icon[^>]*>[\s\S]*?<Data>([\s\S]*?)</Data>') {
                $iconB64 = $Matches[1].Trim()
                Write-Info "Icon source: SDMPackageXML embedded data"
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($iconB64)) {
        Write-Fail "Icon field is EMPTY in SCCM. Re-run Update-SingleAppIcon.ps1 -Commit with a valid PNG."
    } else {
        $iconBytes = [Convert]::FromBase64String($iconB64)
        $byteCount = $iconBytes.Length
        $kiloBytes = [Math]::Round($byteCount / 1024, 1)
        Write-OK "Icon data present: $byteCount bytes / $kiloBytes KB"

        $safeName = $AppName -replace '[^a-zA-Z0-9]', '_'
        $outPath  = [System.IO.Path]::Combine($env:TEMP, "sccm_icon_verify_$safeName.png")
        [System.IO.File]::WriteAllBytes($outPath, $iconBytes)
        Write-OK "Saved to: $outPath"

        try {
            Add-Type -AssemblyName System.Drawing
            $img = [System.Drawing.Image]::FromFile($outPath)
            $w = $img.Width
            $h = $img.Height
            Write-OK "Dimensions: $w x $h px"
            $img.Dispose()
            if ($w -lt 128 -or $h -lt 128) {
                Write-Warn "Smaller than 128x128 -- may appear blurry in Software Center."
            } else {
                Write-OK "Size OK for Software Center."
            }
        } catch {
            Write-Warn "Could not read image dimensions: $_"
        }

        Write-Info "Opening icon for visual verification..."
        Start-Process $outPath
    }
} else {
    Write-Warn "Could not retrieve SMS_Application via WMI -- skipping byte-level check."
}

Set-Location "${SiteCode}:"

Write-Step "Application metadata"
Write-Info "DateLastModified : $($app.DateLastModified)"
Write-Info "LastModifiedBy   : $($app.LastModifiedBy)"
Write-Info "CI_UniqueID      : $($app.CI_UniqueID)"

Set-Location $prevLoc

if ($RefreshClient) {
    Write-Step "Triggering Machine Policy Retrieval on local CCM client"
    try {
        Invoke-WmiMethod -Namespace "root\CCM" -Class SMS_Client -Name TriggerSchedule `
                         -ArgumentList "{00000000-0000-0000-0000-000000000021}" | Out-Null
        Invoke-WmiMethod -Namespace "root\CCM" -Class SMS_Client -Name TriggerSchedule `
                         -ArgumentList "{00000000-0000-0000-0000-000000000022}" | Out-Null
        Write-OK "Policy cycles triggered (Retrieval + Evaluation)."
    } catch {
        Write-Warn "WMI trigger failed: $_"
        Write-Info "Manual: Control Panel > Configuration Manager > Actions > Machine Policy Retrieval"
    }
    Write-Info "Software Center should refresh within 1-2 minutes."
}

Write-Host ""
Write-Host "Done." -ForegroundColor Cyan
Write-Host "  - If the icon image opened correctly: SCCM has the right data." -ForegroundColor Gray
Write-Host "  - If Software Center still shows old icon: run with -RefreshClient." -ForegroundColor Gray
Write-Host "  - If icon was EMPTY: re-run Update-SingleAppIcon.ps1 -Commit." -ForegroundColor Gray
