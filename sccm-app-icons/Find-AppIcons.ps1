<#
.SYNOPSIS
    Finds and downloads 512x512 PNG icons for SCCM applications.

.DESCRIPTION
    Reads the inventory CSV produced by Get-SCCMAppInventory.ps1, then for each
    application attempts to locate a high-quality 512x512 icon from multiple
    sources (WinGet manifests, Clearbit Logo API, publisher website og:image).
    Downloads icons to a local folder and produces icon_review.csv for you to
    review and adjust before applying icons to SCCM.

    Icon source priority:
      1. WinGet GitHub manifest  - most accurate for known Windows apps
      2. Clearbit Logo API       - great for publisher/company logos (free, no key)
      3. Publisher website og:image / apple-touch-icon
      4. MANUAL_NEEDED           - flagged for you to supply manually

.PARAMETER InventoryPath
    Path to sccm_inventory.csv from Get-SCCMAppInventory.ps1.

.PARAMETER IconsFolder
    Folder to save downloaded icons. Created if it doesn't exist.
    Defaults to ".\icons".

.PARAMETER ReviewCsvPath
    Output path for the review CSV. Defaults to ".\icon_review.csv".

.PARAMETER OnlyMissingIcons
    If specified, skip apps that already have an icon set in SCCM.
    When -SiteCode and -SiteServer are also provided, icon presence is
    verified live against SCCM using namespace-aware XML detection.
    Otherwise the IconStatus column from the inventory CSV is used.

.PARAMETER SiteCode
    Optional. Your SCCM site code (e.g., "P01"). When provided together with
    -SiteServer, the script connects to SCCM and live-checks each app's icon
    status directly from SDMPackageXML, overriding the HasExistingIcon value
    in the CSV (which may be stale if generated before the detection fix).

.PARAMETER SiteServer
    Optional. FQDN or hostname of your SCCM site server. Required when
    -SiteCode is specified.

.PARAMETER GitHubToken
    Optional GitHub personal access token. Without it the GitHub API allows
    60 requests/hour; with a token it allows 5,000/hour. Recommended if you
    have more than ~50 apps.

.PARAMETER Force
    Re-download icons even if a local file already exists.

.EXAMPLE
    .\Find-AppIcons.ps1 -InventoryPath ".\sccm_inventory.csv"

.EXAMPLE
    .\Find-AppIcons.ps1 -InventoryPath ".\sccm_inventory.csv" -OnlyMissingIcons `
        -SiteCode "P01" -SiteServer "cm01.contoso.com" -GitHubToken "ghp_xxxx"
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$InventoryPath,

    [string]$IconsFolder   = ".\icons",
    [string]$ReviewCsvPath = ".\icon_review.csv",

    [switch]$OnlyMissingIcons,

    # Optional live SCCM connection for accurate icon detection
    [string]$SiteCode,
    [string]$SiteServer,

    [string]$GitHubToken,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region --- Helpers ---

function Write-Step { param([string]$m, [string]$c = "Cyan")  Write-Host "`n==> $m" -ForegroundColor $c }
function Write-OK   { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green  }
function Write-Warn { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Fail { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red    }
function Write-Info { param([string]$m) Write-Host "  [...]  $m" -ForegroundColor Gray   }

# Namespace-aware icon detection - mirrors the fix in Get-SCCMAppInventory.ps1.
# SCCM's SDMPackageXML declares a default XML namespace, which causes PowerShell's
# dot-notation navigation to silently return $null for every node. We must use
# XmlNamespaceManager + SelectNodes to traverse the document correctly.
function Test-IconPresent {
    param([string]$SDMPackageXML)
    try {
        if ([string]::IsNullOrWhiteSpace($SDMPackageXML)) { return $false }

        $xml   = [xml]$SDMPackageXML
        $nsMgr = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
        $nsMgr.AddNamespace("a", "http://schemas.microsoft.com/SystemCenterConfigurationManager/2009/AppMgmtDigest")

        $dataNodes = $xml.SelectNodes("//a:Icon/a:Data", $nsMgr)
        foreach ($node in $dataNodes) {
            if (-not [string]::IsNullOrWhiteSpace($node.InnerText)) { return $true }
        }

        # Fallback regex - catches apps created without the default namespace declaration
        return ($SDMPackageXML -match '<Data>\s*[A-Za-z0-9+/]{20,}')
    } catch {
        return ($SDMPackageXML -match '<Data>\s*[A-Za-z0-9+/]{20,}')
    }
}

# Build default HTTP headers. Use $script: scope so function default parameter
# values can reference it reliably regardless of call depth.
$script:defaultHeaders = @{ "User-Agent" = "SCCM-IconHelper/1.0" }
if ($GitHubToken) {
    $script:defaultHeaders["Authorization"] = "token $GitHubToken"
}

function Invoke-SafeWeb {
    param(
        [string]$Uri,
        [hashtable]$Headers  = $script:defaultHeaders,
        [int]$TimeoutSec     = 15
    )
    try {
        $r = Invoke-WebRequest -Uri $Uri -Headers $Headers -UseBasicParsing `
                               -TimeoutSec $TimeoutSec -ErrorAction Stop
        return $r
    } catch {
        return $null
    }
}

function Invoke-SafeRestGet {
    param(
        [string]$Uri,
        [hashtable]$Headers  = $script:defaultHeaders,
        [int]$TimeoutSec     = 15
    )
    try {
        $r = Invoke-RestMethod -Uri $Uri -Headers $Headers -TimeoutSec $TimeoutSec -ErrorAction Stop
        return $r
    } catch {
        return $null
    }
}

# Resize/convert an image to 512x512 PNG using System.Drawing.
# Source is loaded via MemoryStream rather than FromFile() to avoid the GDI+
# "A generic error occurred" failure that happens when FromFile() holds a file
# lock and GDI+ then tries to write the output PNG to the same or a nearby path.
function Save-IconAs512 {
    param([string]$SourcePath, [string]$DestPath)
    $ms  = $null
    $src = $null
    $bmp = $null
    $g   = $null
    try {
        Add-Type -AssemblyName System.Drawing

        $bytes = [System.IO.File]::ReadAllBytes($SourcePath)
        $ms    = New-Object System.IO.MemoryStream(,$bytes)
        $src   = [System.Drawing.Image]::FromStream($ms)

        $bmp = New-Object System.Drawing.Bitmap(512, 512)
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.DrawImage($src, 0, 0, 512, 512)
        $bmp.Save($DestPath, [System.Drawing.Imaging.ImageFormat]::Png)
        return $true
    } catch {
        Write-Warn "Image resize failed: $_"
        return $false
    } finally {
        if ($g)   { $g.Dispose()   }
        if ($bmp) { $bmp.Dispose() }
        if ($src) { $src.Dispose() }
        if ($ms)  { $ms.Dispose()  }
    }
}

# Download a URL to a temp file, then resize to 512x512 PNG at $DestPath
function Download-AndResize {
    param([string]$Url, [string]$DestPath)
    $tmp = [System.IO.Path]::GetTempFileName() + ".img"
    try {
        $r = Invoke-SafeWeb -Uri $Url
        if (-not $r -or $r.StatusCode -ne 200) { return $false }

        # Check content-type to avoid HTML error pages
        $ct = $r.Headers["Content-Type"]
        if ($ct -and $ct -match "text/html") { return $false }

        [System.IO.File]::WriteAllBytes($tmp, $r.Content)

        # Verify it is actually an image
        try {
            Add-Type -AssemblyName System.Drawing
            $test = [System.Drawing.Image]::FromFile($tmp)
            $test.Dispose()
        } catch {
            return $false
        }

        return (Save-IconAs512 -SourcePath $tmp -DestPath $DestPath)
    } catch {
        return $false
    } finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
}

# Sanitize an app name for use as a filename
function Get-SafeFilename {
    param([string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars() -join ''
    $re = "[{0}]" -f [regex]::Escape($invalid)
    return ($Name -replace $re, '_').Trim()
}

# Try to derive a domain from a publisher name
function Get-PublisherDomain {
    param([string]$Publisher)
    if ([string]::IsNullOrWhiteSpace($Publisher)) { return $null }

    $knownDomains = @{
        "Microsoft"                  = "microsoft.com"
        "Microsoft Corp"             = "microsoft.com"
        "Microsoft Corporation"      = "microsoft.com"
        "Adobe"                      = "adobe.com"
        "Adobe Inc"                  = "adobe.com"
        "Adobe Inc."                 = "adobe.com"
        "Adobe Systems"              = "adobe.com"
        "Google"                     = "google.com"
        "Google LLC"                 = "google.com"
        "Google Inc"                 = "google.com"
        "Mozilla"                    = "mozilla.org"
        "Mozilla Foundation"         = "mozilla.org"
        "Mozilla Corporation"        = "mozilla.org"
        "Apple"                      = "apple.com"
        "Apple Inc"                  = "apple.com"
        "Apple Inc."                 = "apple.com"
        "Zoom"                       = "zoom.us"
        "Zoom Video Communications"  = "zoom.us"
        "Slack"                      = "slack.com"
        "Slack Technologies"         = "slack.com"
        "Dropbox"                    = "dropbox.com"
        "Dropbox Inc"                = "dropbox.com"
        "Citrix"                     = "citrix.com"
        "Citrix Systems"             = "citrix.com"
        "VMware"                     = "vmware.com"
        "VMware, Inc."               = "vmware.com"
        "Oracle"                     = "oracle.com"
        "Oracle Corporation"         = "oracle.com"
        "SAP"                        = "sap.com"
        "SAP SE"                     = "sap.com"
        "7-Zip"                      = "7-zip.org"
        "Igor Pavlov"                = "7-zip.org"
        "Notepad++"                  = "notepad-plus-plus.org"
        "Notepad++ Team"             = "notepad-plus-plus.org"
        "VLC"                        = "videolan.org"
        "VideoLAN"                   = "videolan.org"
        "Foxit"                      = "foxit.com"
        "Foxit Software"             = "foxit.com"
        "TeamViewer"                 = "teamviewer.com"
        "TeamViewer GmbH"            = "teamviewer.com"
        "Atlassian"                  = "atlassian.com"
        "Atlassian Corp"             = "atlassian.com"
        "Cisco"                      = "cisco.com"
        "Cisco Systems"              = "cisco.com"
        "Webex"                      = "webex.com"
        "Autodesk"                   = "autodesk.com"
        "Autodesk, Inc"              = "autodesk.com"
        "Sophos"                     = "sophos.com"
        "McAfee"                     = "mcafee.com"
        "Symantec"                   = "symantec.com"
        "ESET"                       = "eset.com"
        "Trend Micro"                = "trendmicro.com"
        "Palo Alto Networks"         = "paloaltonetworks.com"
        "CrowdStrike"                = "crowdstrike.com"
        "WinRAR"                     = "win-rar.com"
        "RARLAB"                     = "win-rar.com"
        "PuTTY"                      = "putty.org"
        "Wireshark"                  = "wireshark.org"
        "VirtualBox"                 = "virtualbox.org"
        "Oracle VirtualBox"          = "virtualbox.org"
        "FileZilla"                  = "filezilla-project.org"
        "Git"                        = "git-scm.com"
        "GitHub"                     = "github.com"
        "GitHub, Inc"                = "github.com"
        "HashiCorp"                  = "hashicorp.com"
        "Docker"                     = "docker.com"
        "Python"                     = "python.org"
        "Python Software Foundation" = "python.org"
        "Node.js"                    = "nodejs.org"
        "OpenJS Foundation"          = "nodejs.org"
    }

    if ($knownDomains.ContainsKey($Publisher)) {
        return $knownDomains[$Publisher]
    }

    foreach ($key in $knownDomains.Keys) {
        if ($Publisher -match [regex]::Escape($key)) {
            return $knownDomains[$key]
        }
    }

    # Last resort: strip common legal suffixes and build a .com guess
    $clean = $Publisher -replace '\s+(Inc\.?|LLC|Corp\.?|Ltd\.?|GmbH|AG|SE|Co\.|Corporation|Limited|Software|Systems|Technologies|Technology|Group)$', ''
    $clean = $clean.Trim() -replace '\s+', '' -replace '[^a-zA-Z0-9\-]', ''
    if ($clean.Length -gt 2) {
        return "$($clean.ToLower()).com"
    }

    return $null
}

#endregion

#region --- Icon Source Functions ---

# Source 1: WinGet manifest on GitHub
function Get-IconFromWinGet {
    param([string]$AppName, [string]$Publisher)

    Write-Info "Trying WinGet manifest..."
    $query = $AppName
    if ($Publisher) { $query = "$Publisher $AppName" }

    $searchUri = "https://api.github.com/search/code?q={0}+filename:en-US+repo:microsoft/winget-pkgs&per_page=5" -f [uri]::EscapeUriString($query)
    $result = Invoke-SafeRestGet -Uri $searchUri

    if (-not $result -or -not $result.items) { return $null }

    foreach ($item in $result.items) {
        $rawUrl = $item.html_url -replace "github\.com/(.+)/blob/(.+)", "raw.githubusercontent.com/`$1/`$2"
        $yaml   = Invoke-SafeWeb -Uri $rawUrl
        if (-not $yaml) { continue }

        if ($yaml.Content -match '(?i)IconUrl\s*:\s*(https?://\S+)') {
            $iconUrl = $Matches[1].Trim()
            Write-Info "Found icon URL in WinGet manifest: $iconUrl"
            return $iconUrl
        }
    }
    return $null
}

# Source 2: Clearbit Logo API (free, no key, great for company logos)
function Get-IconFromClearbit {
    param([string]$Domain)
    if (-not $Domain) { return $null }

    Write-Info "Trying Clearbit logo for domain: $Domain"
    $url = "https://logo.clearbit.com/$Domain"
    $r   = Invoke-SafeWeb -Uri $url
    if ($r -and $r.StatusCode -eq 200) {
        $ct = $r.Headers["Content-Type"]
        if ($ct -and $ct -match "image") {
            return $url
        }
    }
    return $null
}

# Source 3: Publisher website og:image / apple-touch-icon
function Get-IconFromWebsite {
    param([string]$Domain)
    if (-not $Domain) { return $null }

    Write-Info "Trying website og:image for: $Domain"
    $r = Invoke-SafeWeb -Uri "https://$Domain" -TimeoutSec 10
    if (-not $r -or $r.StatusCode -ne 200) { return $null }

    $html = $r.Content

    # NOTE: These patterns use double-quoted strings with backtick-escaped double
    # quotes (`"). In PowerShell, single-quoted strings do not support \' as an
    # escape sequence - a bare ' inside a single-quoted string terminates it,
    # which was causing parse errors in earlier versions of this script.

    # Try og:image meta tag
    if ($html -match "<meta[^>]+property=[`"']og:image[`"'][^>]+content=[`"']([^`"']+)[`"']") {
        $imgUrl = $Matches[1]
        if ($imgUrl -notmatch "^https?://") { $imgUrl = "https://$Domain$imgUrl" }
        Write-Info "Found og:image: $imgUrl"
        return $imgUrl
    }

    # Try apple-touch-icon link tag (usually 180x180 - acceptable starting point)
    if ($html -match "<link[^>]+rel=[`"']apple-touch-icon[`"'][^>]+href=[`"']([^`"']+)[`"']") {
        $imgUrl = $Matches[1]
        if ($imgUrl -notmatch "^https?://") { $imgUrl = "https://$Domain$imgUrl" }
        Write-Info "Found apple-touch-icon: $imgUrl"
        return $imgUrl
    }

    return $null
}

# Source 4: DuckDuckGo Instant Answer - fallback for brand logos
function Get-IconFromDuckDuckGo {
    param([string]$AppName, [string]$Publisher)

    Write-Info "Trying DuckDuckGo Instant Answer..."
    $searchTerm = if ($Publisher) { "$Publisher $AppName" } else { $AppName }
    $uri = "https://api.duckduckgo.com/?q={0}&format=json&no_redirect=1&no_html=1" -f [uri]::EscapeUriString($searchTerm)

    $result = Invoke-SafeRestGet -Uri $uri
    if (-not $result) { return $null }

    if ($result.Image -and $result.Image -ne "") {
        $img = $result.Image
        if ($img -notmatch "^https?://") { $img = "https://duckduckgo.com$img" }
        Write-Info "Found DDG Instant Answer image: $img"
        return $img
    }

    return $null
}

#endregion

#region --- Optional Live SCCM Connection ---

# $liveIconStatus is a hashtable of AppName -> bool, populated only when
# -SiteCode and -SiteServer are both supplied.
$liveIconStatus = $null

if ($SiteCode -and $SiteServer) {
    Write-Step "Connecting to SCCM for live icon detection ($SiteCode on $SiteServer)"

    $possibleModulePaths = @(
        "$env:SMS_ADMIN_UI_PATH\..\ConfigurationManager.psd1",
        "C:\Program Files (x86)\Microsoft Endpoint Manager\AdminConsole\bin\ConfigurationManager.psd1",
        "C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1"
    )
    $modulePath = $possibleModulePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $modulePath) {
        Write-Warn "ConfigurationManager module not found - falling back to CSV icon status."
    } else {
        try {
            Import-Module $modulePath -ErrorAction Stop

            if (-not (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue)) {
                New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer -ErrorAction Stop | Out-Null
            }

            Push-Location "$SiteCode`:\"
            Write-Info "Querying all applications for live icon status..."

            $liveIconStatus = @{}
            $allApps = Get-CMApplication -ErrorAction Stop
            foreach ($a in $allApps) {
                $liveIconStatus[$a.LocalizedDisplayName] = Test-IconPresent -SDMPackageXML $a.SDMPackageXML
            }

            Pop-Location
            Write-OK "Live icon status loaded for $($liveIconStatus.Count) applications"
        } catch {
            $errMsg = $_.Exception.Message
            Write-Warn "Could not query SCCM - falling back to CSV icon status. Error: $errMsg"
            $liveIconStatus = $null
            try { Pop-Location } catch { $null = $_ }
        }
    }
} elseif ($SiteCode -or $SiteServer) {
    Write-Warn "Both -SiteCode and -SiteServer must be provided for live checking. Falling back to CSV."
}

#endregion

#region --- Main ---

if (-not (Test-Path $InventoryPath)) {
    Write-Fail "Inventory file not found: $InventoryPath"
    exit 1
}

if (-not (Test-Path $IconsFolder)) {
    New-Item -ItemType Directory -Path $IconsFolder -Force | Out-Null
    Write-OK "Created icons folder: $IconsFolder"
}

Write-Step "Loading inventory from: $InventoryPath"
$inventory = Import-Csv -Path $InventoryPath -Encoding UTF8

# Filter to Applications only (packages do not support icons)
$apps = @($inventory | Where-Object { $_.Type -eq "Application" })

if ($OnlyMissingIcons) {
    if ($liveIconStatus) {
        $apps = @($apps | Where-Object {
            $iconFound = $liveIconStatus[$_.Name]
            -not $iconFound
        })
        Write-OK "Filtered to $($apps.Count) apps that need icons (live SCCM check)"
    } else {
        $apps = @($apps | Where-Object { $_.IconStatus -eq "NEEDS_ICON" })
        Write-OK "Filtered to $($apps.Count) apps that need icons (CSV - may be stale)"
    }
} else {
    Write-OK "Processing $($apps.Count) applications"
}

$reviewResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$i = 0

foreach ($app in $apps) {
    $i++
    $name      = $app.Name
    $publisher = $app.Publisher
    $safeName  = Get-SafeFilename -Name $name
    $destPath  = Join-Path $IconsFolder "$safeName.png"

    Write-Step "[$i/$($apps.Count)] $name" "White"

    $iconUrl    = $null
    $source     = "MANUAL_NEEDED"
    $downloaded = $false

    # Skip download if icon already exists locally and -Force not specified
    if ((Test-Path $destPath) -and -not $Force) {
        Write-OK "Icon already exists locally (use -Force to re-download)"
        $source     = "CACHED"
        $downloaded = $true
    } else {
        # 1. WinGet manifest
        $iconUrl = Get-IconFromWinGet -AppName $name -Publisher $publisher
        if ($iconUrl) {
            $downloaded = Download-AndResize -Url $iconUrl -DestPath $destPath
            if ($downloaded) { $source = "WinGet" } else { $iconUrl = $null }
        }

        # 2. Clearbit
        if (-not $downloaded) {
            $domain  = Get-PublisherDomain -Publisher $publisher
            $iconUrl = Get-IconFromClearbit -Domain $domain
            if ($iconUrl) {
                $downloaded = Download-AndResize -Url $iconUrl -DestPath $destPath
                if ($downloaded) { $source = "Clearbit" } else { $iconUrl = $null }
            }
        }

        # 3. Website og:image
        if (-not $downloaded) {
            $domain  = Get-PublisherDomain -Publisher $publisher
            $iconUrl = Get-IconFromWebsite -Domain $domain
            if ($iconUrl) {
                $downloaded = Download-AndResize -Url $iconUrl -DestPath $destPath
                if ($downloaded) { $source = "WebOGImage" } else { $iconUrl = $null }
            }
        }

        # 4. DuckDuckGo
        if (-not $downloaded) {
            $iconUrl = Get-IconFromDuckDuckGo -AppName $name -Publisher $publisher
            if ($iconUrl) {
                $downloaded = Download-AndResize -Url $iconUrl -DestPath $destPath
                if ($downloaded) { $source = "DuckDuckGo" } else { $iconUrl = $null }
            }
        }
    }

    if ($downloaded) {
        Write-OK "Icon saved [$source]: $destPath"
    } else {
        Write-Warn "No icon found - marked MANUAL_NEEDED"
        $destPath = ""
        $iconUrl  = ""
    }

    # Resolve HadExistingIcon: prefer live SCCM data, fall back to CSV value
    if ($liveIconStatus -and $liveIconStatus.ContainsKey($name)) {
        $hadIcon = $liveIconStatus[$name]
    } else {
        $hadIcon = ($app.HasExistingIcon -eq "True")
    }

    # Safely resolve the full icon path
    $resolvedIconPath = ""
    if ($downloaded -and ($destPath -ne "")) {
        $rp = Resolve-Path $destPath -ErrorAction SilentlyContinue
        $resolvedIconPath = if ($rp) { $rp.Path } else { $destPath }
    }

    $reviewResults.Add([PSCustomObject]@{
        AppName          = $name
        Publisher        = $publisher
        Version          = $app.Version
        CI_UniqueID      = $app.CI_UniqueID
        HadExistingIcon  = $hadIcon
        IconStatusSource = if ($liveIconStatus) { "LiveSCCM" } else { "CSV" }
        IconFilePath     = $resolvedIconPath
        IconSourceURL    = if ($iconUrl) { $iconUrl } else { "" }
        IconSource       = $source
        Status           = if ($downloaded) { "READY" } else { "MANUAL_NEEDED" }
        ApplyToSCCM      = if ($downloaded) { "YES" } else { "NO" }
        Notes            = ""
    })

    # Brief pause to be polite to external APIs
    Start-Sleep -Milliseconds 500
}

#endregion

#region --- Export Review CSV ---

Write-Step "Exporting review CSV"
$reviewResults | Export-Csv -Path $ReviewCsvPath -NoTypeInformation -Encoding UTF8
Write-OK "Review CSV written to: $ReviewCsvPath"

# Wrap in @() so .Count is always available under Set-StrictMode -Version Latest,
# even when Where-Object returns exactly one item (which would otherwise be an
# unwrapped object with no .Count property).
$ready       = @($reviewResults | Where-Object { $_.Status -eq "READY" }).Count
$needsManual = @($reviewResults | Where-Object { $_.Status -eq "MANUAL_NEEDED" }).Count

Write-Step "Summary" "Magenta"
Write-Host "  Icons found and ready : $ready"       -ForegroundColor Green
Write-Host "  Need manual icon      : $needsManual" -ForegroundColor Yellow

Write-Host @"

NEXT STEPS:
  1. Open icon_review.csv and review the IconFilePath for each app.
  2. For any row where Status = MANUAL_NEEDED, place a 512x512 PNG in the
     icons\ folder named after the app (e.g. "App Name.png"), fill in
     IconFilePath, and set ApplyToSCCM to YES.
  3. To skip an app entirely, set ApplyToSCCM to NO in the CSV.
  4. Apply the curated icons folder with:
     .\Update-AllAppIcons.ps1 -IconDir <icons folder> -Commit
"@ -ForegroundColor Cyan

#endregion
