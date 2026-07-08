<#
.SYNOPSIS
    Exports an inventory of all deployed SCCM applications to a CSV file.

.DESCRIPTION
    Connects to a Configuration Manager (SCCM Current Branch) site server,
    queries all deployed applications, and exports details including whether
    each app currently has an icon set.

.PARAMETER SiteCode
    Your SCCM site code (e.g., "P01").

.PARAMETER SiteServer
    The FQDN or hostname of your SCCM site server (e.g., "cm01.contoso.com").

.PARAMETER OutputPath
    Path for the output CSV. Defaults to ".\sccm_inventory.csv".

.PARAMETER IncludePackages
    If specified, also includes legacy Packages (not just Applications).

.EXAMPLE
    .\Get-SCCMAppInventory.ps1 -SiteCode "P01" -SiteServer "cm01.contoso.com"

.EXAMPLE
    .\Get-SCCMAppInventory.ps1 -SiteCode "P01" -SiteServer "cm01.contoso.com" -IncludePackages -OutputPath "C:\SCCM\inventory.csv"
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = "Your SCCM site code, e.g. P01")]
    [string]$SiteCode,

    [Parameter(Mandatory = $true, HelpMessage = "FQDN of your SCCM site server")]
    [string]$SiteServer,

    [string]$OutputPath = ".\sccm_inventory.csv",

    [switch]$IncludePackages
)

#region --- Helpers ---

function Write-Step {
    param([string]$Message, [string]$Color = "Cyan")
    Write-Host "`n==> $Message" -ForegroundColor $Color
}

function Write-OK   { param([string]$m) Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "  [!!] $m" -ForegroundColor Yellow }
function Write-Fail { param([string]$m) Write-Host "  [XX] $m" -ForegroundColor Red }

function Test-IconPresent {
    param([string]$SDMPackageXML)
    try {
        if ([string]::IsNullOrWhiteSpace($SDMPackageXML)) { return $false }

        # SCCM's SDMPackageXML declares a default namespace, which causes PowerShell's
        # dot-notation (e.g. $xml.AppMgmtDigest.Application...) to silently return $null
        # for every node. We must use XmlNamespaceManager + SelectNodes instead.
        $xml       = [xml]$SDMPackageXML
        $nsMgr     = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
        $nsMgr.AddNamespace("a", "http://schemas.microsoft.com/SystemCenterConfigurationManager/2009/AppMgmtDigest")

        # Icon base64 data lives in <Icon><Data>...</Data></Icon>
        $dataNodes = $xml.SelectNodes("//a:Icon/a:Data", $nsMgr)
        foreach ($node in $dataNodes) {
            if (-not [string]::IsNullOrWhiteSpace($node.InnerText)) { return $true }
        }

        # Fallback: regex scan of the raw XML string — catches namespace variations
        # and apps created by older/third-party tools that may omit the namespace.
        return ($SDMPackageXML -match '<Data>\s*[A-Za-z0-9+/]{20,}')

    } catch {
        # Last resort if XML parsing itself fails
        return ($SDMPackageXML -match '<Data>\s*[A-Za-z0-9+/]{20,}')
    }
}

#endregion

#region --- Module & Site Connection ---

Write-Step "Loading ConfigurationManager module"

# Locate the CM module — try several common install paths
$possibleModulePaths = @(
    "$env:SMS_ADMIN_UI_PATH\..\ConfigurationManager.psd1",
    "C:\Program Files (x86)\Microsoft Endpoint Manager\AdminConsole\bin\ConfigurationManager.psd1",
    "C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1"
)

$modulePath = $possibleModulePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $modulePath) {
    Write-Fail "ConfigurationManager.psd1 not found. Is the SCCM Admin Console installed on this machine?"
    exit 1
}

try {
    Import-Module $modulePath -ErrorAction Stop
    Write-OK "Module loaded from: $modulePath"
} catch {
    Write-Fail "Failed to import module: $_"
    exit 1
}

Write-Step "Connecting to site $SiteCode on $SiteServer"

if (-not (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue)) {
    try {
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer -ErrorAction Stop | Out-Null
        Write-OK "PSDrive $SiteCode`:\ created"
    } catch {
        Write-Fail "Could not create PSDrive for site $SiteCode`: $_"
        exit 1
    }
} else {
    Write-OK "PSDrive $SiteCode`:\ already exists"
}

Push-Location "$SiteCode`:\"

#endregion

#region --- Query Applications ---

$inventory = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Step "Querying deployed Applications"

try {
    $allApps = Get-CMApplication -ErrorAction Stop
    $deployedApps = $allApps | Where-Object { $_.IsDeployed -eq $true }
    Write-OK "Found $($deployedApps.Count) deployed applications (of $($allApps.Count) total)"

    foreach ($app in $deployedApps) {
        $hasIcon = Test-IconPresent -SDMPackageXML $app.SDMPackageXML

        $inventory.Add([PSCustomObject]@{
            Type              = "Application"
            Name              = $app.LocalizedDisplayName
            Publisher         = $app.Manufacturer
            Version           = $app.SoftwareVersion
            HasExistingIcon   = $hasIcon
            DeploymentTypes   = $app.NumberOfDeploymentTypes
            CI_UniqueID       = $app.CI_UniqueID
            DateCreated       = $app.DateCreated
            DateLastModified  = $app.DateLastModified
            IsEnabled         = $app.IsEnabled
            IconStatus        = if ($hasIcon) { "HAS_ICON" } else { "NEEDS_ICON" }
        })
    }
} catch {
    Write-Fail "Error querying applications: $_"
}

#endregion

#region --- Query Packages (optional) ---

if ($IncludePackages) {
    Write-Step "Querying deployed Packages (legacy)"

    try {
        # Packages with at least one deployment
        $deployedPackages = Get-CMPackage -ErrorAction Stop | Where-Object {
            (Get-CMDeployment -SoftwareName $_.Name -ErrorAction SilentlyContinue) -ne $null
        }
        Write-OK "Found $($deployedPackages.Count) deployed packages"

        foreach ($pkg in $deployedPackages) {
            $inventory.Add([PSCustomObject]@{
                Type              = "Package"
                Name              = $pkg.Name
                Publisher         = $pkg.Manufacturer
                Version           = $pkg.Version
                HasExistingIcon   = $false   # Packages don't support icons natively
                DeploymentTypes   = "N/A"
                CI_UniqueID       = $pkg.PackageID
                DateCreated       = $pkg.SourceDate
                DateLastModified  = $pkg.LastRefreshTime
                IsEnabled         = $true
                IconStatus        = "NOT_SUPPORTED"
            })
        }
    } catch {
        Write-Warn "Could not query packages: $_"
    }
}

#endregion

#region --- Export & Summary ---

Pop-Location

if ($inventory.Count -eq 0) {
    Write-Warn "No deployed applications found. Nothing exported."
    exit 0
}

Write-Step "Exporting inventory"

try {
    $inventory | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-OK "Exported $($inventory.Count) records to: $OutputPath"
} catch {
    Write-Fail "Could not write CSV: $_"
    exit 1
}

# Print summary
$apps           = $inventory | Where-Object { $_.Type -eq "Application" }
$needsIcon      = $apps      | Where-Object { $_.IconStatus -eq "NEEDS_ICON" }
$hasIcon        = $apps      | Where-Object { $_.IconStatus -eq "HAS_ICON" }

Write-Step "Summary" "Magenta"
Write-Host "  Total deployed apps  : $($apps.Count)"         -ForegroundColor White
Write-Host "  Already have an icon : $($hasIcon.Count)"      -ForegroundColor Green
Write-Host "  Need an icon         : $($needsIcon.Count)"    -ForegroundColor Yellow

if ($IncludePackages) {
    $pkgs = $inventory | Where-Object { $_.Type -eq "Package" }
    Write-Host "  Legacy packages      : $($pkgs.Count) (icons not supported)" -ForegroundColor Gray
}

Write-Host "`nNext step: Run .\Find-AppIcons.ps1 -InventoryPath `"$OutputPath`"" -ForegroundColor Cyan

#endregion
