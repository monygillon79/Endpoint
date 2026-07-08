<#
.SYNOPSIS
    Updates the icon on a single SCCM application by editing SDMPackageXML
    through the official Microsoft.ConfigurationManagement.ApplicationManagement
    SDK, then writing it back via SMS_Application.Put() with a
    ConfigurationManager IResultObject.Put fallback. Includes post-write
    verification of the saved icon bytes.

.NOTES
    Default MaxIconDimension is 250 px. SCCM pre-2103 caps icons at 250x250
    and the SMS Provider on many sites silently no-ops Put() when the
    re-serialized SDMPackageXML exceeds ~32 KB (a PowerShell WMI transport
    limit on string properties). A 250x250 PNG keeps the total XML under
    that limit. Pass -MaxIconDimension 512 if your site is 2103+ and the
    provider is configured for the larger cap.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$AppName,

    [string]$IconDir          = "C:\Temp\Icons",
    [string]$IconPath         = "",
    [string]$SiteCode         = "",
    [string]$SiteServer       = "",
    [int]   $MaxIconDimension = 175,
    [string]$ConsoleBinPath   = "",
    [switch]$Commit
)

Set-StrictMode -Version 1
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK   { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Fail { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Write-Info { param([string]$m) Write-Host "  [INFO] $m" -ForegroundColor White }
function Write-Dry  { param([string]$m) Write-Host "  [DRY]  $m" -ForegroundColor Magenta }

function Get-WmiPropSafe {
    param($obj, [string]$name)
    $p = $obj.PSObject.Properties[$name]
    if ($p) { return $p.Value } else { return $null }
}

function Write-PutFailure {
    param($ErrRecord, [string]$Label)
    $ex = $ErrRecord.Exception
    $inner = if ($ex.InnerException) { $ex.InnerException.Message } else { "<none>" }
    $hresult = if ($ex.HResult) { "0x{0:X8}" -f $ex.HResult } else { "<none>" }
    Write-Fail "$Label failed: $($ex.Message)"
    Write-Fail "HRESULT: $hresult"
    Write-Fail "Inner  : $inner"
}

function Set-CmAppXml {
    # WqlResultObject doesn't support PowerShell indexer access, but it
    # does expose SetPropertyValue() via reflection on some module
    # versions. Try that first (it writes through to the property bag),
    # fall back to the dot-accessor (which sets a PS-side cache).
    param($CmApp, [string]$Xml)

    [Type[]]$twoArgSig = @([string], [object])
    foreach ($name in @("SetPropertyValue", "SetSingleItem")) {
        try {
            $m = $CmApp.GetType().GetMethod($name, $twoArgSig)
            if ($m) {
                $m.Invoke($CmApp, @("SDMPackageXML", $Xml)) | Out-Null
                return $name
            }
        } catch {
            # method probe failed; try the next signature
        }
    }
    $CmApp.SDMPackageXML = $Xml
    return "DotAccessor"
}

function Get-IconBytesFitted {
    param(
        [Parameter(Mandatory)] [string]$SourcePath,
        [Parameter(Mandatory)] [int]   $Max
    )

    Add-Type -AssemblyName System.Drawing | Out-Null
    $img = [System.Drawing.Image]::FromFile($SourcePath)
    try {
        if ($img.Width -le $Max -and $img.Height -le $Max) {
            return [pscustomobject]@{
                Bytes   = [System.IO.File]::ReadAllBytes($SourcePath)
                Width   = $img.Width
                Height  = $img.Height
                Resized = $false
            }
        }
        $ratio = [Math]::Min($Max / $img.Width, $Max / $img.Height)
        $newW  = [int][Math]::Round($img.Width  * $ratio)
        $newH  = [int][Math]::Round($img.Height * $ratio)
        $bmp = New-Object System.Drawing.Bitmap $newW, $newH
        try {
            $bmp.SetResolution($img.HorizontalResolution, $img.VerticalResolution)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            try {
                $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
                $g.DrawImage($img, 0, 0, $newW, $newH)
            } finally { $g.Dispose() }
            $ms = New-Object System.IO.MemoryStream
            try {
                $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
                $bytes = $ms.ToArray()
            } finally { $ms.Dispose() }
        } finally { $bmp.Dispose() }
        return [pscustomobject]@{ Bytes=$bytes; Width=$newW; Height=$newH; Resized=$true }
    } finally {
        $img.Dispose()
    }
}

function Resolve-ConsoleBinPath {
    param([string]$Override)
    if ($Override -and (Test-Path $Override)) { return $Override }
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:SMS_ADMIN_UI_PATH) {
        $candidates.Add((Split-Path $env:SMS_ADMIN_UI_PATH -Parent))
        $candidates.Add($env:SMS_ADMIN_UI_PATH)
    }
    $candidates.Add("C:\Program Files (x86)\Microsoft Endpoint Manager\AdminConsole\bin")
    $candidates.Add("C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin")
    $candidates.Add("C:\Program Files\Microsoft Endpoint Manager\AdminConsole\bin")
    $candidates.Add("C:\Program Files\Microsoft Configuration Manager\AdminConsole\bin")
    foreach ($p in $candidates) {
        if ($p -and (Test-Path (Join-Path $p "Microsoft.ConfigurationManagement.ApplicationManagement.dll"))) { return $p }
    }
    return $null
}

Write-Host "Update-SingleAppIcon.ps1 build: 2026-05-12-r10" -ForegroundColor DarkGray

Write-Step "Resolving SCCM site connection"
if (-not $SiteCode) {
    $reg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\SMS\Setup" -ErrorAction SilentlyContinue
    if ($reg) { $SiteCode = $reg."Site Code" }
}
if (-not $SiteServer) { $SiteServer = $env:COMPUTERNAME }
if (-not $SiteCode) { Write-Fail "Could not auto-detect site code. Pass -SiteCode."; exit 1 }
Write-OK "Site code  : $SiteCode"
Write-OK "Site server: $SiteServer"

Write-Step "Locating icon for '$AppName'"
$iconFile = $null
if ($IconPath) {
    if (-not (Test-Path -LiteralPath $IconPath)) { Write-Fail "IconPath not found: $IconPath"; exit 1 }
    $iconFile = Get-Item -LiteralPath $IconPath
} else {
    if (-not (Test-Path $IconDir)) { Write-Fail "Icon directory not found: $IconDir"; exit 1 }
    $iconFile = Get-ChildItem -Path $IconDir -File | Where-Object { $_.BaseName -eq $AppName } | Select-Object -First 1
    if (-not $iconFile) {
        $norm = $AppName -replace '[^a-zA-Z0-9]', ''
        $iconFile = Get-ChildItem -Path $IconDir -File |
                    Where-Object { ($_.BaseName -replace '[^a-zA-Z0-9]', '') -ieq $norm } | Select-Object -First 1
    }
    if (-not $iconFile) {
        $prefix = $AppName.Substring(0, [Math]::Min(15, $AppName.Length))
        $iconFile = Get-ChildItem -Path $IconDir -File |
                    Where-Object { $_.BaseName -ilike "*$prefix*" } | Select-Object -First 1
    }
}
if (-not $iconFile) {
    Write-Fail "No icon file found in '$IconDir' matching '$AppName'."
    Get-ChildItem $IconDir -File | ForEach-Object { Write-Host "    $($_.Name)" }
    exit 1
}
Write-OK "Icon file : $($iconFile.FullName)"
Write-OK "File size : $($iconFile.Length) bytes"

$iconInfo = Get-IconBytesFitted -SourcePath $iconFile.FullName -Max $MaxIconDimension
if ($iconInfo.Resized) {
    Write-Warn ("Original exceeded {0}px -- resized to {1}x{2} ({3} bytes PNG)" -f $MaxIconDimension, $iconInfo.Width, $iconInfo.Height, $iconInfo.Bytes.Length)
} else {
    Write-OK ("Dimensions: {0} x {1} px (within {2}px cap; no resize)" -f $iconInfo.Width, $iconInfo.Height, $MaxIconDimension)
}
$iconBytes = $iconInfo.Bytes
$expectedB64 = [Convert]::ToBase64String($iconBytes)

Write-Step "Loading SCCM Admin Console assemblies"
$binPath = Resolve-ConsoleBinPath -Override $ConsoleBinPath
if (-not $binPath) {
    Write-Fail "Could not find Microsoft.ConfigurationManagement.ApplicationManagement.dll."
    exit 1
}
Write-OK "Console bin: $binPath"

$assemblyResolveHandler = [System.ResolveEventHandler]{
    param($sender, $resolveArgs)
    $shortName = ($resolveArgs.Name -split ',')[0]
    $dllPath = Join-Path $binPath "$shortName.dll"
    if (Test-Path $dllPath) { return [System.Reflection.Assembly]::LoadFrom($dllPath) }
    return $null
}
[System.AppDomain]::CurrentDomain.add_AssemblyResolve($assemblyResolveHandler)

try {
    $sdkDlls = @(
        "Microsoft.ConfigurationManagement.ApplicationManagement.dll",
        "Microsoft.ConfigurationManagement.ApplicationManagement.MsiInstaller.dll",
        "Microsoft.ConfigurationManagement.ApplicationManagement.Extender.dll",
        "Microsoft.ConfigurationManagement.ApplicationManagement.WindowsInstaller.dll",
        "DcmObjectModel.dll"
    )
    foreach ($dll in $sdkDlls) {
        $p = Join-Path $binPath $dll
        if (Test-Path $p) {
            try { [System.Reflection.Assembly]::LoadFrom($p) | Out-Null }
            catch { Write-Warn "Could not load $dll : $($_.Exception.Message)" }
        }
    }
    if (-not ('Microsoft.ConfigurationManagement.ApplicationManagement.Serialization.SccmSerializer' -as [type])) {
        Write-Fail "SccmSerializer type not found."
        exit 1
    }

    Write-Step "Fetching SMS_Application from WMI on $SiteServer"
    $wmiNS       = "root\SMS\site_$SiteCode"
    $escapedName = $AppName -replace "'", "''"
    $wmiApp = Get-WmiObject -Namespace $wmiNS -ComputerName $SiteServer `
                  -Class SMS_Application `
                  -Filter "LocalizedDisplayName='$escapedName' AND IsLatest=1" `
                  -ErrorAction Stop | Select-Object -First 1
    if (-not $wmiApp) { Write-Fail "Application not found via WMI."; exit 1 }
    $wmiApp.Get()
    Write-OK "Found: $($wmiApp.LocalizedDisplayName)  (CI_ID: $($wmiApp.CI_ID))"
    $preVersion = $wmiApp.SDMPackageVersion

    $sdmXml = $wmiApp.SDMPackageXML
    if ([string]::IsNullOrWhiteSpace($sdmXml)) {
        Write-Fail "SDMPackageXML is empty."
        exit 1
    }

    Write-Step "Updating Icon via SccmSerializer"
    $appObj = [Microsoft.ConfigurationManagement.ApplicationManagement.Serialization.SccmSerializer]::DeserializeFromString($sdmXml, $true)
    if (-not $appObj.DisplayInfo -or $appObj.DisplayInfo.Count -eq 0) {
        Write-Fail "Application has no DisplayInfo entries."
        exit 1
    }
    $iconObj = New-Object Microsoft.ConfigurationManagement.ApplicationManagement.Icon
    $iconObj.Data = $iconBytes

    $defaultLang = $null
    $defLangProp = $appObj.DisplayInfo.PSObject.Properties["DefaultLanguage"]
    if ($defLangProp) { $defaultLang = $defLangProp.Value }
    $appliedTo = 0
    foreach ($di in $appObj.DisplayInfo) {
        if (-not $defaultLang -or $di.Language -eq $defaultLang) {
            $di.Icon = $iconObj
            $appliedTo++
        }
    }
    if ($appliedTo -eq 0) {
        $appObj.DisplayInfo[0].Icon = $iconObj
        $appliedTo = 1
    }
    Write-OK "Icon applied to $appliedTo DisplayInfo entry/entries (default language: $defaultLang)."

    $newXml = [Microsoft.ConfigurationManagement.ApplicationManagement.Serialization.SccmSerializer]::SerializeToString($appObj, $false)
    Write-OK "Re-serialized SDMPackageXML ($($newXml.Length) chars; was $($sdmXml.Length))"
    if ($newXml.Length -gt 32766) {
        Write-Warn ("Saved XML is {0} chars -- over the 32 KB threshold that triggers silent" -f $newXml.Length)
        Write-Warn "no-op-touch on many SMS Providers. If Put doesn't persist, rerun with"
        Write-Warn "-MaxIconDimension $([int]($MaxIconDimension * 0.7))."
    }

    Write-Step "Pre-commit diagnostics"
    foreach ($f in @('CI_ID','CI_UniqueID','SDMPackageVersion','IsLatest','IsObjectLocked',
                     'ObjectLockedUser','ObjectLockedMachine','SecuredScopeNames',
                     'DateLastModified','LastModifiedBy','CreatedBy','NumberOfDeploymentTypes')) {
        $v = Get-WmiPropSafe $wmiApp $f
        if ($null -ne $v) { Write-Info ("{0,-22} : {1}" -f $f, $v) }
    }

    if (-not $Commit) {
        Write-Dry "DRY RUN -- pass -Commit to apply."
    } else {
        $committed = $false

        Write-Step "Writing changes to SCCM (Attempt 1: WMI SMS_Application.Put)"
        $wmiApp.SDMPackageXML = $newXml
        try {
            $putResult = $wmiApp.Put()
            if ($putResult) {
                Write-OK "SMS_Application.Put() succeeded."
                $committed = $true
            }
        } catch {
            Write-PutFailure -ErrRecord $_ -Label "WMI Put"
            Write-Warn "Falling back to ConfigurationManager module path..."
        }

        if (-not $committed) {
            Write-Step "Writing changes to SCCM (Attempt 2: ConfigurationManager module)"
            $cmModulePaths = @()
            if ($env:SMS_ADMIN_UI_PATH) {
                $cmModulePaths += (Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH -Parent) 'ConfigurationManager.psd1')
            }
            $cmModulePaths += @(
                (Join-Path $binPath 'ConfigurationManager.psd1'),
                'C:\Program Files (x86)\Microsoft Endpoint Manager\AdminConsole\bin\ConfigurationManager.psd1',
                'C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1'
            )
            $cmModule = $cmModulePaths | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
            if (-not $cmModule) {
                Write-Fail "ConfigurationManager.psd1 not found."
            } else {
                try {
                    if (-not (Get-Module ConfigurationManager)) {
                        Import-Module $cmModule -ErrorAction Stop -DisableNameChecking
                    }
                    if (-not (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue)) {
                        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer -ErrorAction Stop | Out-Null
                    }
                    $prevLocation = Get-Location
                    Set-Location "$SiteCode`:"
                    try {
                        $cmApp = Get-CMApplication -Name $AppName -ErrorAction Stop
                        if (-not $cmApp) { throw "Get-CMApplication returned null." }
                        $setMethod = Set-CmAppXml -CmApp $cmApp -Xml $newXml
                        Write-Info "SetSDMPackageXML via: $setMethod"
                        $cmApp.Put()
                        Write-OK "ConfigurationManager IResultObject.Put() succeeded."
                        $committed = $true
                    } finally {
                        Set-Location $prevLocation
                    }
                } catch {
                    Write-PutFailure -ErrRecord $_ -Label "CM IResultObject Put"
                }
            }
        }

        if ($committed) {
            Write-OK "App  : $($wmiApp.LocalizedDisplayName)"
            Write-OK "Icon : $($iconFile.FullName)"

            Write-Step "Post-write verification"
            Start-Sleep -Seconds 2
            try {
                $vApp = Get-WmiObject -Namespace $wmiNS -ComputerName $SiteServer `
                            -Class SMS_Application `
                            -Filter "LocalizedDisplayName='$escapedName' AND IsLatest=1" `
                            -ErrorAction Stop | Select-Object -First 1
                if ($vApp) {
                    $vApp.Get()
                    $savedXml = $vApp.SDMPackageXML
                    Write-Info ("Saved SDMPackageVersion : {0}  (was {1} before Put)" -f $vApp.SDMPackageVersion, $preVersion)
                    Write-Info ("Saved XML length        : {0} chars  (we sent {1})" -f $savedXml.Length, $newXml.Length)

                    $iconMatches = [regex]::Matches($savedXml, '<Icon[^>]*>[\s\S]*?<Data>([\s\S]*?)</Data>[\s\S]*?</Icon>')
                    Write-Info ("Icon blocks in saved XML: {0}" -f $iconMatches.Count)
                    $matchedOurs = $false
                    for ($i = 0; $i -lt $iconMatches.Count; $i++) {
                        $b64 = $iconMatches[$i].Groups[1].Value.Trim()
                        try {
                            $sz = ([Convert]::FromBase64String($b64)).Length
                            $isOurs = ($b64 -eq $expectedB64)
                            if ($isOurs) { $matchedOurs = $true }
                            $marker = if ($isOurs) { "<-- our icon (match)" } else { "" }
                            Write-Info ("  Icon[{0}]: {1} bytes  {2}" -f $i, $sz, $marker)
                        } catch {
                            Write-Warn ("  Icon[{0}]: could not decode base64" -f $i)
                        }
                    }

                    if ($matchedOurs) {
                        Write-OK "Our icon is present in saved SDMPackageXML."
                    } else {
                        Write-Fail "Our icon was NOT found in saved SDMPackageXML."
                        Write-Fail "Put returned success, but SDMPackageXML did not persist."
                        Write-Info ""
                        Write-Info "Next steps:"
                        Write-Info "  * If XML was over 32 KB, rerun with smaller -MaxIconDimension."
                        Write-Info "  * Otherwise, run this script directly on the site server"
                        Write-Info "    ($SiteServer) -- remote WMI Put on lazy properties is"
                        Write-Info "    rejected by the SMS Provider in many configurations."
                        Write-Info "  * Or grep SMSPROV.log on the server for 'SDMPackageXML' at"
                        Write-Info "    the time of this run for the real reason."
                    }
                } else {
                    Write-Warn "Post-write re-fetch returned no application."
                }
            } catch {
                Write-Warn "Post-write verification failed: $($_.Exception.Message)"
            }

            Write-Info "Replication can take a few minutes."
        } else {
            $failedXmlPath = Join-Path $env:TEMP ("sccm_icon_failed_xml_{0}_{1:yyyyMMdd_HHmmss}.xml" -f $wmiApp.CI_ID, (Get-Date))
            try {
                Set-Content -LiteralPath $failedXmlPath -Value $newXml -Encoding UTF8
                Write-Info "Failed XML written to: $failedXmlPath"
            } catch {}
            Write-Info ""
            Write-Info "Both save paths failed. Possible causes:"
            Write-Info "  1. Account lacks Modify on app's security scope ($($wmiApp.SecuredScopeNames))."
            Write-Info "  2. Inspect SMSPROV.log on $SiteServer for the real reason."
            Write-Info "  3. Run this script on the site server itself."
            Write-Info "  4. Try -MaxIconDimension $([int]($MaxIconDimension * 0.7)) (smaller icon)."
            exit 1
        }
    }
}
finally {
    [System.AppDomain]::CurrentDomain.remove_AssemblyResolve($assemblyResolveHandler)
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
