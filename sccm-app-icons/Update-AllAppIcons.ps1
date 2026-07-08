<#
.SYNOPSIS
    Bulk-applies icons from a folder to SCCM applications whose names match
    the icon file basenames. Reuses the proven Update-SingleAppIcon.ps1
    pipeline (SDK serializer, two-attempt save, post-write verification)
    for every icon found.

.DESCRIPTION
    For each *.png/*.jpg/*.jpeg/*.bmp/*.ico file in -IconDir, the script:
      1. Strips the extension to derive a candidate app name.
      2. Looks up the SCCM app via WMI by LocalizedDisplayName, with
         exact, normalized (non-alphanumeric stripped), and substring
         fallback matching.
      3. Resizes the icon in-memory to fit MaxIconDimension.
      4. Deserializes the app's SDMPackageXML via SccmSerializer, replaces
         the Icon on the default DisplayInfo, re-serializes.
      5. Attempts SMS_Application.Put() over WMI, falling back to the
         ConfigurationManager IResultObject path.
      6. Verifies the saved SDMPackageXML actually contains our icon
         bytes and logs the outcome.

    All apps are loaded once into a name dictionary; the SDK assemblies
    and CM module load once. Failures on individual icons do not stop
    the run.

.PARAMETER IconDir
    Folder of icon files. Default: C:\Temp\Icons.

.PARAMETER SiteCode
    SCCM site code. Auto-detected from local registry if omitted.

.PARAMETER SiteServer
    SCCM site server FQDN. Defaults to the local machine.

.PARAMETER MaxIconDimension
    Max icon dimension in pixels. Default: 175 (stays under SCCM's 32 KB
    SDMPackageXML write threshold). Use 250 or 512 on newer sites.

.PARAMETER ConsoleBinPath
    Optional override of the SCCM Admin Console bin folder.

.PARAMETER LogPath
    CSV log of per-app outcome. Default: .\icon_update_batch_log.csv.

.PARAMETER SkipIfHasIcon
    Skip apps that already have a non-empty icon in SDMPackageXML.

.PARAMETER NameFilter
    Optional wildcard pattern applied to icon basenames (e.g. "VLC*").

.PARAMETER Commit
    Actually persist changes. Without this flag the run is a dry-run.

.EXAMPLE
    .\Update-AllAppIcons.ps1 -SiteCode P01 `
        -SiteServer cm01.contoso.local

.EXAMPLE
    .\Update-AllAppIcons.ps1 -SiteCode P01 `
        -SiteServer cm01.contoso.local -Commit
#>

[CmdletBinding()]
param (
    [string]$IconDir          = "C:\Temp\Icons",
    [string]$SiteCode         = "",
    [string]$SiteServer       = "",
    [int]   $MaxIconDimension = 175,
    [string]$ConsoleBinPath   = "",
    [string]$LogPath          = ".\icon_update_batch_log.csv",
    [string]$NameFilter       = "",
    [switch]$SkipIfHasIcon,
    [switch]$Commit
)

Set-StrictMode -Version 1
$ErrorActionPreference = "Stop"

# -- Output helpers ----------------------------------------------------------
function Write-Step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK   { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Fail { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Write-Skip { param([string]$m) Write-Host "  [SKIP] $m" -ForegroundColor Gray }
function Write-Info { param([string]$m) Write-Host "  [INFO] $m" -ForegroundColor White }
function Write-Dry  { param([string]$m) Write-Host "  [DRY]  $m" -ForegroundColor Magenta }

function Get-WmiPropSafe {
    param($obj, [string]$name)
    $p = $obj.PSObject.Properties[$name]
    if ($p) { return $p.Value } else { return $null }
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

function Set-CmAppXml {
    param($CmApp, [string]$Xml)
    [Type[]]$twoArgSig = @([string], [object])
    foreach ($name in @("SetPropertyValue", "SetSingleItem")) {
        try {
            $m = $CmApp.GetType().GetMethod($name, $twoArgSig)
            if ($m) {
                $m.Invoke($CmApp, @("SDMPackageXML", $Xml)) | Out-Null
                return $name
            }
        } catch { }
    }
    $CmApp.SDMPackageXML = $Xml
    return "DotAccessor"
}

function Test-HasIcon {
    param([string]$Xml)
    if ([string]::IsNullOrWhiteSpace($Xml)) { return $false }
    return [bool]([regex]::Match($Xml, '<Icon[^>]*>[\s\S]*?<Data>\s*[A-Za-z0-9+/]{20,}').Success)
}

# ============================================================================

Write-Host "Update-AllAppIcons.ps1 build: 2026-05-12-r2" -ForegroundColor DarkGray
$startTime = Get-Date

# -- Site detection ----------------------------------------------------------
Write-Step "Resolving SCCM site connection"
if (-not $SiteCode) {
    $reg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\SMS\Setup" -ErrorAction SilentlyContinue
    if ($reg) { $SiteCode = $reg."Site Code" }
}
if (-not $SiteServer) { $SiteServer = $env:COMPUTERNAME }
if (-not $SiteCode) { Write-Fail "Could not auto-detect site code. Pass -SiteCode."; exit 1 }
Write-OK "Site code  : $SiteCode"
Write-OK "Site server: $SiteServer"

# -- Enumerate icon files ----------------------------------------------------
Write-Step "Enumerating icons in '$IconDir'"
if (-not (Test-Path $IconDir)) {
    Write-Fail "Icon directory not found: $IconDir"
    exit 1
}
$iconFiles = Get-ChildItem -Path $IconDir -File |
             Where-Object { $_.Extension -match '^\.(png|jpg|jpeg|bmp|ico|gif)$' }
if ($NameFilter) {
    $iconFiles = $iconFiles | Where-Object { $_.BaseName -like $NameFilter }
}
if (-not $iconFiles -or $iconFiles.Count -eq 0) {
    Write-Fail "No icon files found in '$IconDir'."
    exit 1
}
Write-OK ("Found {0} icon file(s)" -f $iconFiles.Count)

# -- Load SDK assemblies -----------------------------------------------------
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

$log = [System.Collections.Generic.List[pscustomobject]]::new()
$summary = @{
    Total      = $iconFiles.Count
    Matched    = 0
    NoMatch    = 0
    Skipped    = 0
    Succeeded  = 0
    Failed     = 0
    NoOpTouch  = 0
    DryRun     = 0
}

try {
    foreach ($dll in @(
        "Microsoft.ConfigurationManagement.ApplicationManagement.dll",
        "Microsoft.ConfigurationManagement.ApplicationManagement.MsiInstaller.dll",
        "Microsoft.ConfigurationManagement.ApplicationManagement.Extender.dll",
        "Microsoft.ConfigurationManagement.ApplicationManagement.WindowsInstaller.dll",
        "DcmObjectModel.dll"
    )) {
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

    Write-Step "Fetching SMS_Application name index from $SiteServer"
    $wmiNS = "root\SMS\site_$SiteCode"
    $allApps = Get-WmiObject -Namespace $wmiNS -ComputerName $SiteServer `
                   -Class SMS_Application `
                   -Filter "IsLatest=1" -ErrorAction Stop |
               Select-Object LocalizedDisplayName, CI_ID, ModelName
    Write-OK ("Loaded {0} application(s) (IsLatest=1)" -f @($allApps).Count)

    $byExact = @{}
    $byNorm  = @{}
    foreach ($a in $allApps) {
        $n = $a.LocalizedDisplayName
        if ([string]::IsNullOrWhiteSpace($n)) { continue }
        if (-not $byExact.ContainsKey($n)) { $byExact[$n] = @() }
        $byExact[$n] += ,$a
        $norm = $n -replace '[^a-zA-Z0-9]', ''
        if ($norm) {
            if (-not $byNorm.ContainsKey($norm)) { $byNorm[$norm] = @() }
            $byNorm[$norm] += ,$a
        }
    }

    $cmModule = $null
    $cmPaths = @()
    if ($env:SMS_ADMIN_UI_PATH) {
        $cmPaths += (Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH -Parent) 'ConfigurationManager.psd1')
    }
    $cmPaths += @(
        (Join-Path $binPath 'ConfigurationManager.psd1'),
        'C:\Program Files (x86)\Microsoft Endpoint Manager\AdminConsole\bin\ConfigurationManager.psd1',
        'C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1'
    )
    $cmModule = $cmPaths | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if ($cmModule) {
        if (-not (Get-Module ConfigurationManager)) {
            try {
                Import-Module $cmModule -ErrorAction Stop -DisableNameChecking
                Write-OK "ConfigurationManager module loaded."
            } catch {
                Write-Warn "Failed to load ConfigurationManager module: $($_.Exception.Message)"
                $cmModule = $null
            }
        }
        if ($cmModule -and -not (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue)) {
            try {
                New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer -ErrorAction Stop | Out-Null
            } catch {
                Write-Warn "Failed to create CMSite PSDrive: $($_.Exception.Message)"
                $cmModule = $null
            }
        }
    }

    # -- Per-icon processing loop -----------------------------------------
    $idx = 0
    foreach ($iconFile in $iconFiles) {
        $idx++
        $candidateName = $iconFile.BaseName
        Write-Step ("[{0}/{1}] icon file: {2}" -f $idx, $iconFiles.Count, $iconFile.Name)

        $logRow = [pscustomobject]@{
            IconFile         = $iconFile.FullName
            CandidateName    = $candidateName
            MatchedAppName   = ""
            MatchType        = ""
            CI_ID            = ""
            Outcome          = ""
            Detail           = ""
            SavedVersionBump = ""
            Timestamp        = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        }

        $candidates = $null
        $matchType = ""
        if ($byExact.ContainsKey($candidateName)) {
            $candidates = $byExact[$candidateName]
            $matchType = "exact"
        } else {
            $norm = $candidateName -replace '[^a-zA-Z0-9]', ''
            if ($norm -and $byNorm.ContainsKey($norm)) {
                $candidates = $byNorm[$norm]
                $matchType = "normalized"
            } else {
                $prefix = $candidateName.Substring(0, [Math]::Min(15, $candidateName.Length))
                $hits = @($allApps | Where-Object { $_.LocalizedDisplayName -ilike "*$prefix*" })
                if ($hits.Count -gt 0) {
                    $candidates = $hits
                    $matchType = "substring"
                }
            }
        }

        if (-not $candidates -or $candidates.Count -eq 0) {
            Write-Skip "No SCCM application matches '$candidateName'."
            $logRow.Outcome = "NO_MATCH"
            $logRow.Detail  = "No SMS_Application with this exact/normalized/substring name."
            $summary.NoMatch++
            $log.Add($logRow)
            continue
        }
        if ($candidates.Count -gt 1) {
            Write-Skip ("Ambiguous: {0} apps match '{1}' via {2}." -f $candidates.Count, $candidateName, $matchType)
            $logRow.Outcome = "AMBIGUOUS"
            $logRow.MatchType = $matchType
            $logRow.Detail  = ($candidates | ForEach-Object { $_.LocalizedDisplayName }) -join " | "
            $summary.Skipped++
            $log.Add($logRow)
            continue
        }

        $appHit = $candidates[0]
        $logRow.MatchedAppName = $appHit.LocalizedDisplayName
        $logRow.MatchType      = $matchType
        $logRow.CI_ID          = $appHit.CI_ID
        $summary.Matched++

        Write-OK ("'{0}'  ==>  SCCM app: '{1}'" -f $candidateName, $appHit.LocalizedDisplayName)
        Write-Info ("match type: {0}    CI_ID: {1}" -f $matchType, $appHit.CI_ID)

        $escapedName = $appHit.LocalizedDisplayName -replace "'", "''"
        $wmiApp = $null
        try {
            $wmiApp = Get-WmiObject -Namespace $wmiNS -ComputerName $SiteServer `
                          -Class SMS_Application `
                          -Filter "LocalizedDisplayName='$escapedName' AND IsLatest=1" `
                          -ErrorAction Stop | Select-Object -First 1
            if ($wmiApp) { $wmiApp.Get() }
        } catch {
            Write-Fail "WMI fetch failed: $($_.Exception.Message)"
            $logRow.Outcome = "FETCH_FAILED"
            $logRow.Detail  = $_.Exception.Message
            $summary.Failed++
            $log.Add($logRow)
            continue
        }
        if (-not $wmiApp) {
            Write-Fail "App found in index but not in re-fetch."
            $logRow.Outcome = "FETCH_FAILED"
            $summary.Failed++
            $log.Add($logRow)
            continue
        }

        $preVersion = $wmiApp.SDMPackageVersion
        $sdmXml     = $wmiApp.SDMPackageXML
        if ([string]::IsNullOrWhiteSpace($sdmXml)) {
            Write-Fail "SDMPackageXML is empty."
            $logRow.Outcome = "EMPTY_XML"
            $summary.Failed++
            $log.Add($logRow)
            continue
        }

        if ($SkipIfHasIcon -and (Test-HasIcon -Xml $sdmXml)) {
            Write-Skip "App already has an icon; -SkipIfHasIcon set."
            $logRow.Outcome = "SKIPPED_HAS_ICON"
            $summary.Skipped++
            $log.Add($logRow)
            continue
        }

        try {
            $iconInfo  = Get-IconBytesFitted -SourcePath $iconFile.FullName -Max $MaxIconDimension
            $iconBytes = $iconInfo.Bytes
            $expectedB64 = [Convert]::ToBase64String($iconBytes)
            if ($iconInfo.Resized) {
                Write-Info ("Resized to {0}x{1} ({2} bytes)" -f $iconInfo.Width, $iconInfo.Height, $iconBytes.Length)
            } else {
                Write-Info ("Dimensions {0}x{1} ({2} bytes)" -f $iconInfo.Width, $iconInfo.Height, $iconBytes.Length)
            }
        } catch {
            Write-Fail "Image processing failed: $($_.Exception.Message)"
            $logRow.Outcome = "IMAGE_ERROR"
            $logRow.Detail  = $_.Exception.Message
            $summary.Failed++
            $log.Add($logRow)
            continue
        }

        try {
            $appObj = [Microsoft.ConfigurationManagement.ApplicationManagement.Serialization.SccmSerializer]::DeserializeFromString($sdmXml, $true)
            if (-not $appObj.DisplayInfo -or $appObj.DisplayInfo.Count -eq 0) {
                throw "Application has no DisplayInfo entries."
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
            if ($appliedTo -eq 0) { $appObj.DisplayInfo[0].Icon = $iconObj }
            $newXml = [Microsoft.ConfigurationManagement.ApplicationManagement.Serialization.SccmSerializer]::SerializeToString($appObj, $false)
        } catch {
            Write-Fail "Serialize/modify failed: $($_.Exception.Message)"
            $logRow.Outcome = "SERIALIZE_ERROR"
            $logRow.Detail  = $_.Exception.Message
            $summary.Failed++
            $log.Add($logRow)
            continue
        }

        if (-not $Commit) {
            Write-Dry "DRY RUN -- would Put() $($newXml.Length)-char XML."
            $logRow.Outcome = "DRY_RUN"
            $logRow.Detail  = "XML length: $($newXml.Length)"
            $summary.DryRun++
            $log.Add($logRow)
            continue
        }

        $committed = $false
        $putDetail = ""

        $wmiApp.SDMPackageXML = $newXml
        try {
            $r = $wmiApp.Put()
            if ($r) { $committed = $true; $putDetail = "WMI Put" }
        } catch {
            $putDetail = "WMI Put failed: $($_.Exception.Message)"
        }

        if (-not $committed -and $cmModule) {
            try {
                $prevLoc = Get-Location
                Set-Location "$SiteCode`:"
                try {
                    $cmApp = Get-CMApplication -Name $appHit.LocalizedDisplayName -ErrorAction Stop
                    if ($cmApp) {
                        $setMethod = Set-CmAppXml -CmApp $cmApp -Xml $newXml
                        $cmApp.Put()
                        $committed = $true
                        $putDetail = "CM IResultObject ($setMethod)"
                    }
                } finally { Set-Location $prevLoc }
            } catch {
                $putDetail += " | CM Put failed: $($_.Exception.Message)"
            }
        }

        if (-not $committed) {
            Write-Fail "Both Put paths failed: $putDetail"
            $logRow.Outcome = "PUT_FAILED"
            $logRow.Detail  = $putDetail
            $summary.Failed++
            $log.Add($logRow)
            continue
        }

        Start-Sleep -Milliseconds 500
        $verified = $false
        try {
            $vApp = Get-WmiObject -Namespace $wmiNS -ComputerName $SiteServer `
                        -Class SMS_Application `
                        -Filter "LocalizedDisplayName='$escapedName' AND IsLatest=1" `
                        -ErrorAction Stop | Select-Object -First 1
            if ($vApp) {
                $vApp.Get()
                $logRow.SavedVersionBump = "$preVersion -> $($vApp.SDMPackageVersion)"
                $savedXml = $vApp.SDMPackageXML
                $iconMatches = [regex]::Matches($savedXml, '<Icon[^>]*>[\s\S]*?<Data>([\s\S]*?)</Data>[\s\S]*?</Icon>')
                foreach ($m in $iconMatches) {
                    if ($m.Groups[1].Value.Trim() -eq $expectedB64) { $verified = $true; break }
                }
            }
        } catch {
            $putDetail += " | Verify failed: $($_.Exception.Message)"
        }

        if ($verified) {
            Write-OK "Icon persisted and verified in SDMPackageXML."
            $logRow.Outcome = "SUCCESS"
            $logRow.Detail  = "$putDetail; version $($logRow.SavedVersionBump)"
            $summary.Succeeded++
        } else {
            Write-Warn "Put returned success but icon bytes not found in saved XML (no-op touch)."
            $logRow.Outcome = "NO_OP_TOUCH"
            $logRow.Detail  = "$putDetail; version $($logRow.SavedVersionBump); icon missing in saved XML"
            $summary.NoOpTouch++
        }
        $log.Add($logRow)
    }
} finally {
    [System.AppDomain]::CurrentDomain.remove_AssemblyResolve($assemblyResolveHandler)
}

# -- Write log --------------------------------------------------------------
Write-Step "Writing log to $LogPath"
try {
    $log | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8
    Write-OK "Log written: $LogPath"
} catch {
    Write-Warn "Failed to write log: $($_.Exception.Message)"
}

# -- Icon -> App mapping table ----------------------------------------------
Write-Step "Icon -> App mapping (matched only)"
$mapped = @($log | Where-Object { $_.MatchedAppName -ne "" })
if ($mapped.Count -gt 0) {
    $iconLens = $mapped | ForEach-Object { (Split-Path $_.IconFile -Leaf).Length }
    $appLens  = $mapped | ForEach-Object { $_.MatchedAppName.Length }
    $maxIcon = ($iconLens | Measure-Object -Maximum).Maximum
    $maxApp  = ($appLens  | Measure-Object -Maximum).Maximum
    if ($maxIcon -lt 9)  { $maxIcon = 9 }
    if ($maxApp  -lt 12) { $maxApp  = 12 }
    $hdr = "  {0,-$maxIcon}  =>  {1,-$maxApp}  {2,-10}  {3}" -f 'icon file','SCCM app','match','outcome'
    Write-Host $hdr -ForegroundColor White
    $dashLen = $maxIcon + $maxApp + 30
    Write-Host ("  " + ('-' * $dashLen)) -ForegroundColor DarkGray
    foreach ($r in $mapped) {
        $iconShort = Split-Path $r.IconFile -Leaf
        $line = "  {0,-$maxIcon}  =>  {1,-$maxApp}  {2,-10}  {3}" -f $iconShort, $r.MatchedAppName, $r.MatchType, $r.Outcome
        $color = switch ($r.Outcome) {
            'SUCCESS'          { 'Green' }
            'DRY_RUN'          { 'Magenta' }
            'NO_OP_TOUCH'      { 'Yellow' }
            'SKIPPED_HAS_ICON' { 'Gray' }
            default            { 'Red' }
        }
        Write-Host $line -ForegroundColor $color
    }
} else {
    Write-Info "(no icons matched any SCCM application)"
}

$unmatched = @($log | Where-Object { $_.Outcome -eq 'NO_MATCH' -or $_.Outcome -eq 'AMBIGUOUS' })
if ($unmatched.Count -gt 0) {
    Write-Step "Unmatched / ambiguous icons"
    foreach ($r in $unmatched) {
        $iconShort = Split-Path $r.IconFile -Leaf
        Write-Host ("  {0}  [{1}]" -f $iconShort, $r.Outcome) -ForegroundColor Yellow
        if ($r.Outcome -eq 'AMBIGUOUS') {
            Write-Host ("    candidates: {0}" -f $r.Detail) -ForegroundColor DarkGray
        }
    }
}

$elapsed = (Get-Date) - $startTime
Write-Step "Summary"
Write-Info ("Total icons     : {0}" -f $summary.Total)
Write-Info ("Matched to app  : {0}" -f $summary.Matched)
Write-Info ("No app match    : {0}" -f $summary.NoMatch)
Write-Info ("Skipped         : {0}" -f $summary.Skipped)
if ($Commit) {
    Write-Info ("Succeeded       : {0}" -f $summary.Succeeded)
    Write-Info ("No-op touch     : {0}" -f $summary.NoOpTouch)
    Write-Info ("Failed          : {0}" -f $summary.Failed)
} else {
    Write-Info ("Would attempt   : {0}" -f $summary.DryRun)
}
Write-Info ("Elapsed         : {0:mm\:ss}" -f $elapsed)

Write-Host ""
if ($Commit) {
    Write-Host "Done. Verify individual apps with Verify-AppIcon.ps1." -ForegroundColor Green
} else {
    Write-Host "Dry-run complete. Re-run with -Commit to apply." -ForegroundColor Magenta
}
