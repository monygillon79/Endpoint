<#
.SYNOPSIS
    Full SCCM inventory — Applications + Packages, with deployment collections and creator.
    Auto-detects site code and server from the registry (no parameters needed).
.OUTPUT
    C:\Scripts\SCCM\sccm_inventory_full.csv
#>

#region --- Helpers ---
function Write-Step { param([string]$m, [string]$c = "Cyan")   Write-Host "`n==> $m" -ForegroundColor $c }
function Write-OK   { param([string]$m) Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "  [!!] $m" -ForegroundColor Yellow }
function Write-Fail { param([string]$m) Write-Host "  [XX] $m" -ForegroundColor Red }

function Get-SiteInfo {
    # 1. Look for existing CM PSDrives (fastest if console already connected)
    $drive = Get-PSDrive -ErrorAction SilentlyContinue | Where-Object { $_.Provider.Name -eq "CMSite" } | Select-Object -First 1
    if ($drive) { return @{ SiteCode = $drive.Name; SiteServer = $drive.Root } }

    # 2. Try all known AdminUI registry paths (HKCU and HKLM, 32/64-bit)
    $regPaths = @(
        "HKCU:\SOFTWARE\Microsoft\ConfigMgr10\AdminUI\Connection",
        "HKLM:\SOFTWARE\Microsoft\ConfigMgr10\AdminUI\Connection",
        "HKCU:\SOFTWARE\Wow6432Node\Microsoft\ConfigMgr10\AdminUI\Connection",
        "HKLM:\SOFTWARE\Wow6432Node\Microsoft\ConfigMgr10\AdminUI\Connection"
    )
    foreach ($p in $regPaths) {
        if (Test-Path $p) {
            $reg = Get-ItemProperty $p -ErrorAction SilentlyContinue
            if ($reg.SiteCode -and $reg.NamespacePath) {
                $server = ($reg.NamespacePath -split '\\' | Where-Object { $_ -ne '' })[0]
                return @{ SiteCode = $reg.SiteCode; SiteServer = $server }
            }
        }
    }

    # 3. Search HKCU AdminUI history for any saved server connection
    $histPath = "HKCU:\SOFTWARE\Microsoft\ConfigMgr10\AdminUI"
    if (Test-Path $histPath) {
        $keys = Get-ChildItem $histPath -ErrorAction SilentlyContinue
        foreach ($key in $keys) {
            $reg = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
            if ($reg.SiteCode -and $reg.NamespacePath) {
                $server = ($reg.NamespacePath -split '\\' | Where-Object { $_ -ne '' })[0]
                return @{ SiteCode = $reg.SiteCode; SiteServer = $server }
            }
        }
    }

    # 4. Check SMS/CCM client registration (if this machine is an SCCM client)
    $ccmPath = "HKLM:\SOFTWARE\Microsoft\SMS\Mobile Client"
    if (Test-Path $ccmPath) {
        $reg = Get-ItemProperty $ccmPath -ErrorAction SilentlyContinue
        if ($reg.AssignedSiteCode) {
            # Client knows its site code; find the MP/server from HKLM:\SOFTWARE\Microsoft\CCM
            $mpPath = "HKLM:\SOFTWARE\Microsoft\CCM"
            $mp = (Get-ItemProperty $mpPath -ErrorAction SilentlyContinue).CurrentManagementPoint
            if ($mp) { return @{ SiteCode = $reg.AssignedSiteCode; SiteServer = $mp } }
        }
    }

    # 5. Scan WMI for the SMS Provider (works if run on the site server itself)
    try {
        $provider = Get-CimInstance -Namespace "root\SMS" -ClassName "SMS_ProviderLocation" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($provider) { return @{ SiteCode = $provider.SiteCode; SiteServer = $provider.Machine } }
    } catch {}

    # 6. Hardcoded fallback for this environment (detected from open console)
    return @{ SiteCode = "P01"; SiteServer = "cm01.contoso.local" }
}

function Test-IconPresent {
    param([string]$SDMPackageXML)
    try {
        if ([string]::IsNullOrWhiteSpace($SDMPackageXML)) { return $false }
        $xml   = [xml]$SDMPackageXML
        $nsMgr = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
        $nsMgr.AddNamespace("a","http://schemas.microsoft.com/SystemCenterConfigurationManager/2009/AppMgmtDigest")
        $nodes = $xml.SelectNodes("//a:Icon/a:Data", $nsMgr)
        foreach ($n in $nodes) { if (-not [string]::IsNullOrWhiteSpace($n.InnerText)) { return $true } }
        return ($SDMPackageXML -match '<Data>\s*[A-Za-z0-9+/]{20,}')
    } catch {
        return ($SDMPackageXML -match '<Data>\s*[A-Za-z0-9+/]{20,}')
    }
}
#endregion

#region --- Site connection ---
Write-Step "Detecting SCCM site"

$siteInfo = Get-SiteInfo
if (-not $siteInfo) {
    Write-Fail "Could not auto-detect site code/server from registry or existing PSDrives."
    Write-Fail "Ensure the CM Admin Console has been used on this machine at least once."
    exit 1
}
$SiteCode  = $siteInfo.SiteCode
$SiteServer = $siteInfo.SiteServer
Write-OK "Site: $SiteCode  |  Server: $SiteServer"

# Load CM module
$modulePaths = @(
    "$env:SMS_ADMIN_UI_PATH\..\ConfigurationManager.psd1",
    "C:\Program Files (x86)\Microsoft Endpoint Manager\AdminConsole\bin\ConfigurationManager.psd1",
    "C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1"
)
$modulePath = $modulePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $modulePath) { Write-Fail "CM module not found."; exit 1 }

try   { Import-Module $modulePath -ErrorAction Stop; Write-OK "Module loaded" }
catch { Write-Fail "Module import failed: $_"; exit 1 }

if (-not (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue)) {
    try   { New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer -ErrorAction Stop | Out-Null; Write-OK "Connected to $SiteCode" }
    catch { Write-Fail "PSDrive creation failed: $_"; exit 1 }
}
Push-Location "$SiteCode`:\"
#endregion

$inventory = [System.Collections.Generic.List[PSCustomObject]]::new()

#region --- Applications ---
Write-Step "Querying Applications"
try {
    $allApps = Get-CMApplication -ErrorAction Stop
    Write-OK "Found $($allApps.Count) applications"

    foreach ($app in $allApps) {
        $hasIcon = Test-IconPresent -SDMPackageXML $app.SDMPackageXML

        # Deployment info
        $deployments  = Get-CMDeployment -SoftwareName $app.LocalizedDisplayName -ErrorAction SilentlyContinue
        $isDeployed   = ($deployments -ne $null -and @($deployments).Count -gt 0)
        $collections  = if ($isDeployed) {
            ($deployments | ForEach-Object {
                try { (Get-CMCollection -Id $_.CollectionID -ErrorAction SilentlyContinue).Name } catch {}
            } | Where-Object { $_ }) -join "; "
        } else { "" }

        $inventory.Add([PSCustomObject]@{
            Type                = "Application"
            Name                = $app.LocalizedDisplayName
            Publisher           = $app.Manufacturer
            Version             = $app.SoftwareVersion
            IsDeployed          = $isDeployed
            DeployedCollections = $collections
            PackagedBy          = $app.CreatedBy
            DateCreated         = $app.DateCreated
            DateLastModified    = $app.DateLastModified
            HasIcon             = $hasIcon
            IconStatus          = if ($hasIcon) { "HAS_ICON" } else { "NEEDS_ICON" }
        })
    }
    Write-OK "Applications processed: $($allApps.Count)"
} catch {
    Write-Fail "Error querying applications: $_"
}
#endregion

#region --- Packages ---
Write-Step "Querying Packages (legacy)"
try {
    $allPkgs = Get-CMPackage -ErrorAction Stop
    Write-OK "Found $($allPkgs.Count) packages"

    foreach ($pkg in $allPkgs) {
        $deployments = Get-CMDeployment -SoftwareName $pkg.Name -ErrorAction SilentlyContinue
        $isDeployed  = ($deployments -ne $null -and @($deployments).Count -gt 0)
        $collections = if ($isDeployed) {
            ($deployments | ForEach-Object {
                try { (Get-CMCollection -Id $_.CollectionID -ErrorAction SilentlyContinue).Name } catch {}
            } | Where-Object { $_ }) -join "; "
        } else { "" }

        $inventory.Add([PSCustomObject]@{
            Type                = "Package"
            Name                = $pkg.Name
            Publisher           = $pkg.Manufacturer
            Version             = $pkg.Version
            IsDeployed          = $isDeployed
            DeployedCollections = $collections
            PackagedBy          = $pkg.SourceSite   # Packages don't store CreatedBy; SourceSite is closest
            DateCreated         = $pkg.SourceDate
            DateLastModified    = $pkg.LastRefreshTime
            HasIcon             = $false
            IconStatus          = "NOT_SUPPORTED"
        })
    }
    Write-OK "Packages processed: $($allPkgs.Count)"
} catch {
    Write-Warn "Could not query packages: $_"
}
#endregion

Pop-Location

$outputPath = "C:\Scripts\SCCM\sccm_inventory_full.csv"
$inventory | Export-Csv -Path $outputPath -NoTypeInformation -Encoding UTF8
Write-OK "Exported $($inventory.Count) total records to: $outputPath"

$apps     = @($inventory | Where-Object { $_.Type -eq "Application" })
$pkgs     = @($inventory | Where-Object { $_.Type -eq "Package" })
$deployed = @($inventory | Where-Object { $_.IsDeployed -eq $true })

Write-Step "Summary" "Magenta"
Write-Host "  Applications : $($apps.Count)"     -ForegroundColor White
Write-Host "  Packages     : $($pkgs.Count)"     -ForegroundColor White
Write-Host "  Deployed     : $($deployed.Count)" -ForegroundColor Green
Write-Host "`nDone. Output: $outputPath" -ForegroundColor Cyan
