<#
.SYNOPSIS
    IT Environment Data Collector for DocForge v2.0.0
    Collects Active Directory, Group Policy, SCCM, and Network configuration data
    and packages it as an AES-256 encrypted JSON bundle for automated documentation
    generation via the DocForge platform and Claude's API.

.DESCRIPTION
    This script gathers comprehensive IT environment data from on-premises systems:
    - Active Directory: Users, Groups, OUs, Computers, Domain Controllers, Trusts,
      Service Accounts, and Privileged Group Membership
    - Group Policy: GPO details, links, WMI filters, and parsed policy settings
      (registry, security, scripts, folder redirection, software installation)
    - SCCM/MECM: Device inventory, collections, software deployments, patch compliance,
      software inventory, and BitLocker status
    - Network: DNS, DHCP, adapters, routes, firewall rules, and Certificate Infrastructure

    Modules run in parallel via a PowerShell RunspacePool for faster collection.
    Output is a single AES-256-CBC encrypted .dfpkg file (format version 2) ready
    for upload to the DocForge platform. Use -SkipEncryption for plain JSON output
    during development.

.PARAMETER OutputPath
    Directory where the collection bundle will be saved. Defaults to current directory.

.PARAMETER Modules
    Which modules to collect. Defaults to All. Options: All, AD, GPO, SCCM, Network

.PARAMETER Passphrase
    SecureString passphrase used to derive the AES-256 encryption key via PBKDF2.
    Mandatory unless -SkipEncryption is set.

.PARAMETER SkipEncryption
    If set, outputs plain JSON instead of an encrypted bundle (for development only).

.PARAMETER SCCMSiteServer
    Hostname or IP of the SCCM/MECM site server. Auto-detected if not provided.

.PARAMETER SCCMSiteCode
    SCCM/MECM site code (e.g. "PS1"). Auto-detected if not provided.

.PARAMETER Silent
    Suppress all Write-Host color output. Write structured NDJSON log entries to a
    log file in the output path instead. Exits with code 1 if any errors occurred,
    0 if clean. Suitable for Windows Scheduled Task execution.

.EXAMPLE
    .\Collect-ITEnvironment.ps1 -OutputPath "C:\DocForge" -Modules All
    .\Collect-ITEnvironment.ps1 -Modules AD,GPO -SkipEncryption
    .\Collect-ITEnvironment.ps1 -OutputPath "C:\DocForge" -Silent

.NOTES
    Version  : 2.0.0
    Requires appropriate permissions:
    - AD      : Domain User (read), Domain Admin (full detail)
    - GPO     : Group Policy read access
    - SCCM    : SCCM Admin or Read-Only Analyst role
    - Network : Local Admin on the collection machine, DNS/DHCP admin for those modules
#>

[CmdletBinding()]
param(
    [string]$OutputPath = (Get-Location).Path,

    [ValidateSet("All", "AD", "GPO", "SCCM", "Network")]
    [string[]]$Modules = @("All"),

    [System.Security.SecureString]$Passphrase,

    [switch]$SkipEncryption,

    [string]$SCCMSiteServer = "",
    [string]$SCCMSiteCode   = "",

    [switch]$Silent
)

# ============================================================================
# CONFIGURATION & INITIALIZATION
# ============================================================================

$ErrorActionPreference = "Continue"
$script:CollectionErrors   = [System.Collections.Generic.List[object]]::new()
$script:CollectionWarnings = [System.Collections.Generic.List[object]]::new()
$script:AnyErrors          = $false

$Timestamp        = Get-Date -Format "yyyyMMdd_HHmmss"
$CollectorVersion = "2.0.0"
$PartialFile      = Join-Path $OutputPath "docforge_partial_$Timestamp.json"

# Validate passphrase requirement
if (-not $SkipEncryption -and -not $Passphrase) {
    $Passphrase = Read-Host -AsSecureString "Enter encryption passphrase"
}

# Master data object
$EnvironmentData = [ordered]@{
    metadata = [ordered]@{
        collector_version  = $CollectorVersion
        collection_date    = (Get-Date -Format "o")
        collected_by       = "$env:USERDOMAIN\$env:USERNAME"
        collection_machine = $env:COMPUTERNAME
        modules_requested  = $Modules
        modules_completed  = [System.Collections.Generic.List[string]]::new()
        modules_timing     = [ordered]@{}
        errors             = @()
        warnings           = @()
    }
    active_directory = $null
    group_policy     = $null
    sccm             = $null
    network          = $null
}

# Log file for -Silent mode
$LogFile = Join-Path $OutputPath "docforge_collection_$Timestamp.log"

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

function Write-Status {
    param([string]$Message, [string]$Level = "INFO", [string]$Module = "")
    $ts = Get-Date -Format "HH:mm:ss"

    if ($Silent) {
        $entry = [ordered]@{
            timestamp = (Get-Date -Format "o")
            level     = $Level
            module    = $Module
            message   = $Message
        }
        ($entry | ConvertTo-Json -Compress) | Out-File -FilePath $LogFile -Append -Encoding UTF8
    } else {
        $color = switch ($Level) {
            "INFO"    { "Cyan" }
            "SUCCESS" { "Green" }
            "WARN"    { "Yellow" }
            "ERROR"   { "Red" }
            default   { "White" }
        }
        Write-Host "[$ts][$Level] $Message" -ForegroundColor $color
    }
}

function Add-CollectionError {
    param([string]$Module, [string]$Message)
    $entry = [ordered]@{ module = $Module; message = $Message; timestamp = (Get-Date -Format "o") }
    $script:CollectionErrors.Add($entry)
    $script:AnyErrors = $true
    Write-Status "[$Module] $Message" "ERROR" $Module
}

function Add-CollectionWarning {
    param([string]$Module, [string]$Message)
    $entry = [ordered]@{ module = $Module; message = $Message; timestamp = (Get-Date -Format "o") }
    $script:CollectionWarnings.Add($entry)
    Write-Status "[$Module] $Message" "WARN" $Module
}

function Test-ModuleRequested {
    param([string]$ModuleName)
    return ($Modules -contains "All") -or ($Modules -contains $ModuleName)
}

function Save-PartialData {
    try {
        $EnvironmentData | ConvertTo-Json -Depth 20 -Compress:$false |
            Out-File -FilePath $PartialFile -Encoding UTF8 -Force
    } catch {
        # Best-effort; do not fail the run over a partial save
    }
}

# ============================================================================
# RETRY WRAPPER
# ============================================================================

function Invoke-WithRetry {
    param(
        [scriptblock]$ScriptBlock,
        [int]$MaxAttempts  = 3,
        [int]$DelaySeconds = 5,
        [string]$Description = "operation"
    )
    $attempt = 0
    $lastEx  = $null
    while ($attempt -lt $MaxAttempts) {
        $attempt++
        try {
            return (& $ScriptBlock)
        } catch {
            $lastEx = $_
            if ($attempt -lt $MaxAttempts) {
                Write-Status "  Retry $attempt/$MaxAttempts for '$Description': $_" "WARN"
                Start-Sleep -Seconds $DelaySeconds
            }
        }
    }
    throw $lastEx
}

# ============================================================================
# AES-256-CBC ENCRYPTION
# File format: [4-byte magic "DFPK"][1-byte version=2][16-byte salt][16-byte IV][encrypted bytes]
# ============================================================================

function Protect-DataAES256 {
    param(
        [byte[]]$PlainBytes,
        [System.Security.SecureString]$Passphrase
    )

    # Convert SecureString to plain text for key derivation only
    $bstr      = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Passphrase)
    $plainPass = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

    try {
        # Generate random 16-byte salt
        $salt = New-Object byte[] 16
        $rng  = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($salt)

        # Derive 256-bit key and 128-bit IV using PBKDF2 / SHA256, 100,000 iterations
        $passBytes = [System.Text.Encoding]::UTF8.GetBytes($plainPass)
        $pbkdf2    = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
            $passBytes, $salt, 100000,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256
        )
        $key = $pbkdf2.GetBytes(32)   # 256 bits
        $iv  = $pbkdf2.GetBytes(16)   # 128 bits

        # Encrypt with AES-256-CBC
        $aes           = [System.Security.Cryptography.Aes]::Create()
        $aes.KeySize   = 256
        $aes.BlockSize = 128
        $aes.Mode      = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding   = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key       = $key
        $aes.IV        = $iv

        $encryptor   = $aes.CreateEncryptor()
        $memStream   = New-Object System.IO.MemoryStream
        $cryptStream = New-Object System.Security.Cryptography.CryptoStream(
            $memStream, $encryptor,
            [System.Security.Cryptography.CryptoStreamMode]::Write
        )
        $cryptStream.Write($PlainBytes, 0, $PlainBytes.Length)
        $cryptStream.FlushFinalBlock()
        $encryptedBytes = $memStream.ToArray()

        # Assemble output: magic + version + salt + IV + ciphertext
        $magic   = [System.Text.Encoding]::ASCII.GetBytes("DFPK")
        $version = [byte]2

        $output = New-Object System.IO.MemoryStream
        $output.Write($magic, 0, 4)
        $output.WriteByte($version)
        $output.Write($salt, 0, 16)
        $output.Write($iv, 0, 16)
        $output.Write($encryptedBytes, 0, $encryptedBytes.Length)

        return $output.ToArray()
    } finally {
        # Zero out plaintext passphrase from memory
        if ($plainPass) {
            $chars = $plainPass.ToCharArray()
            for ($i = 0; $i -lt $chars.Length; $i++) { $chars[$i] = [char]0 }
        }
    }
}

# ============================================================================
# MODULE SCRIPTBLOCKS (executed inside runspaces)
# Each scriptblock receives $args[0] as a hashtable of shared parameters.
# Returns: @{ data = ...; errors = @(...); warnings = @(...) }
# ============================================================================

$script:ADScriptBlock = {
    param($Params)

    $result = @{ data = $null; errors = [System.Collections.Generic.List[object]]::new(); warnings = [System.Collections.Generic.List[object]]::new() }

    function Fail($msg) { $result.errors.Add(  @{ module = "AD"; message = $msg; timestamp = (Get-Date -Format "o") }) }
    function Warn($msg) { $result.warnings.Add(@{ module = "AD"; message = $msg; timestamp = (Get-Date -Format "o") }) }

    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        Fail "ActiveDirectory PowerShell module not installed. Install via RSAT."
        return $result
    }
    try { Import-Module ActiveDirectory -ErrorAction Stop }
    catch { Fail "Failed to import ActiveDirectory module: $_"; return $result }

    $ad = [ordered]@{}

    # --- Domain Info ---
    try {
        $domain = Get-ADDomain
        $forest = Get-ADForest
        $ad.domain = [ordered]@{
            name                  = $domain.Name
            dns_root              = $domain.DNSRoot
            netbios_name          = $domain.NetBIOSName
            domain_mode           = $domain.DomainMode.ToString()
            forest_name           = $forest.Name
            forest_mode           = $forest.ForestMode.ToString()
            forest_domains        = @($forest.Domains)
            schema_master         = $forest.SchemaMaster
            naming_master         = $forest.DomainNamingMaster
            pdc_emulator          = $domain.PDCEmulator
            rid_master            = $domain.RIDMaster
            infrastructure_master = $domain.InfrastructureMaster
            domain_sid            = $domain.DomainSID.Value
        }
    } catch { Fail "Failed to collect domain info: $_" }

    # --- Domain Controllers ---
    try {
        $dcs = Get-ADDomainController -Filter *
        $ad.domain_controllers = @($dcs | ForEach-Object {
            [ordered]@{
                name              = $_.Name
                hostname          = $_.HostName
                ip_address        = $_.IPv4Address
                site              = $_.Site
                os                = $_.OperatingSystem
                os_version        = $_.OperatingSystemVersion
                is_global_catalog = $_.IsGlobalCatalog
                is_read_only      = $_.IsReadOnly
                enabled           = $_.Enabled
                roles             = @($_.OperationMasterRoles)
            }
        })
    } catch { Fail "Failed to collect DCs: $_" }

    # --- Organizational Units ---
    try {
        $ous = Get-ADOrganizationalUnit -Filter * -Properties Description, ManagedBy, Created
        $ad.organizational_units = @($ous | ForEach-Object {
            [ordered]@{
                name               = $_.Name
                distinguished_name = $_.DistinguishedName
                description        = $_.Description
                managed_by         = $_.ManagedBy
                created            = if ($_.Created) { $_.Created.ToString("o") } else { $null }
            }
        })
    } catch { Fail "Failed to collect OUs: $_" }

    # --- Users (summary) ---
    try {
        $users = Get-ADUser -Filter * -Properties DisplayName, EmailAddress, Department, Title, `
            Manager, Enabled, LastLogonDate, Created, PasswordLastSet, PasswordNeverExpires, `
            LockedOut, MemberOf, Description
        $ad.users = [ordered]@{
            total_count                  = $users.Count
            enabled_count                = ($users | Where-Object Enabled -eq $true).Count
            disabled_count               = ($users | Where-Object Enabled -eq $false).Count
            locked_count                 = ($users | Where-Object LockedOut -eq $true).Count
            password_never_expires_count = ($users | Where-Object PasswordNeverExpires -eq $true).Count
            stale_90_days                = ($users | Where-Object { $_.LastLogonDate -and $_.LastLogonDate -lt (Get-Date).AddDays(-90) }).Count
            accounts                     = @($users | ForEach-Object {
                [ordered]@{
                    sam_account_name       = $_.SamAccountName
                    display_name           = $_.DisplayName
                    email                  = $_.EmailAddress
                    department             = $_.Department
                    title                  = $_.Title
                    enabled                = $_.Enabled
                    locked_out             = $_.LockedOut
                    last_logon             = if ($_.LastLogonDate) { $_.LastLogonDate.ToString("o") } else { $null }
                    password_last_set      = if ($_.PasswordLastSet) { $_.PasswordLastSet.ToString("o") } else { $null }
                    password_never_expires = $_.PasswordNeverExpires
                    created                = if ($_.Created) { $_.Created.ToString("o") } else { $null }
                    group_count            = ($_.MemberOf).Count
                    ou                     = ($_.DistinguishedName -replace '^CN=[^,]+,', '')
                }
            })
        }
    } catch { Fail "Failed to collect users: $_" }

    # --- Groups ---
    try {
        $groups = Get-ADGroup -Filter * -Properties Description, ManagedBy, Members, GroupScope, GroupCategory, Created
        $ad.groups = [ordered]@{
            total_count        = $groups.Count
            security_count     = ($groups | Where-Object GroupCategory -eq "Security").Count
            distribution_count = ($groups | Where-Object GroupCategory -eq "Distribution").Count
            groups             = @($groups | ForEach-Object {
                [ordered]@{
                    name               = $_.Name
                    sam_account_name   = $_.SamAccountName
                    distinguished_name = $_.DistinguishedName
                    description        = $_.Description
                    scope              = $_.GroupScope.ToString()
                    category           = $_.GroupCategory.ToString()
                    managed_by         = $_.ManagedBy
                    member_count       = ($_.Members).Count
                    created            = if ($_.Created) { $_.Created.ToString("o") } else { $null }
                }
            })
        }
    } catch { Fail "Failed to collect groups: $_" }

    # --- Computers ---
    try {
        $computers = Get-ADComputer -Filter * -Properties OperatingSystem, OperatingSystemVersion, `
            LastLogonDate, Created, Enabled, Description, DNSHostName, IPv4Address, MemberOf
        $ad.computers = [ordered]@{
            total_count   = $computers.Count
            enabled_count = ($computers | Where-Object Enabled -eq $true).Count
            os_summary    = @($computers | Group-Object OperatingSystem | Sort-Object Count -Descending | ForEach-Object {
                [ordered]@{ os = $_.Name; count = $_.Count }
            })
            stale_90_days = ($computers | Where-Object { $_.LastLogonDate -and $_.LastLogonDate -lt (Get-Date).AddDays(-90) }).Count
            computers     = @($computers | ForEach-Object {
                [ordered]@{
                    name         = $_.Name
                    dns_hostname = $_.DNSHostName
                    ip_address   = $_.IPv4Address
                    os           = $_.OperatingSystem
                    os_version   = $_.OperatingSystemVersion
                    enabled      = $_.Enabled
                    last_logon   = if ($_.LastLogonDate) { $_.LastLogonDate.ToString("o") } else { $null }
                    created      = if ($_.Created) { $_.Created.ToString("o") } else { $null }
                    description  = $_.Description
                    ou           = ($_.DistinguishedName -replace '^CN=[^,]+,', '')
                }
            })
        }
    } catch { Fail "Failed to collect computers: $_" }

    # --- Sites & Subnets ---
    try {
        $sites     = Get-ADReplicationSite -Filter *
        $subnets   = Get-ADReplicationSubnet -Filter *
        $siteLinks = Get-ADReplicationSiteLink -Filter *
        $ad.sites  = [ordered]@{
            sites      = @($sites | ForEach-Object {
                [ordered]@{ name = $_.Name; description = $_.Description; location = $_.Location }
            })
            subnets    = @($subnets | ForEach-Object {
                [ordered]@{ name = $_.Name; site = $_.Site; location = $_.Location; description = $_.Description }
            })
            site_links = @($siteLinks | ForEach-Object {
                [ordered]@{
                    name                      = $_.Name
                    cost                      = $_.Cost
                    replication_frequency_min = $_.ReplicationFrequencyInMinutes
                    sites_included            = @($_.SitesIncluded)
                }
            })
        }
    } catch { Warn "Failed to collect sites/subnets (may require Enterprise Admin): $_" }

    # --- Trust Relationships ---
    try {
        $trusts = Get-ADTrust -Filter *
        $ad.trusts = @($trusts | ForEach-Object {
            [ordered]@{
                name              = $_.Name
                source            = $_.Source
                target            = $_.Target
                direction         = $_.Direction.ToString()
                trust_type        = $_.TrustType.ToString()
                is_transitive     = $_.IsTreeParent -or $_.IsTreeRoot
                forest_transitive = $_.ForestTransitive
            }
        })
    } catch { Warn "Failed to collect trusts: $_" }

    # --- Fine-Grained Password Policies ---
    try {
        $defaultPolicy = Get-ADDefaultDomainPasswordPolicy
        $fineGrained   = Get-ADFineGrainedPasswordPolicy -Filter *
        $ad.password_policies = [ordered]@{
            default_policy = [ordered]@{
                min_length           = $defaultPolicy.MinPasswordLength
                complexity_enabled   = $defaultPolicy.ComplexityEnabled
                history_count        = $defaultPolicy.PasswordHistoryCount
                max_age_days         = $defaultPolicy.MaxPasswordAge.Days
                min_age_days         = $defaultPolicy.MinPasswordAge.Days
                lockout_threshold    = $defaultPolicy.LockoutThreshold
                lockout_duration_min = $defaultPolicy.LockoutDuration.TotalMinutes
                lockout_window_min   = $defaultPolicy.LockoutObservationWindow.TotalMinutes
            }
            fine_grained_policies = @($fineGrained | ForEach-Object {
                [ordered]@{
                    name               = $_.Name
                    precedence         = $_.Precedence
                    min_length         = $_.MinPasswordLength
                    complexity_enabled = $_.ComplexityEnabled
                    history_count      = $_.PasswordHistoryCount
                    max_age_days       = $_.MaxPasswordAge.Days
                    lockout_threshold  = $_.LockoutThreshold
                    applies_to         = @($_.AppliesTo)
                }
            })
        }
    } catch { Warn "Failed to collect password policies: $_" }

    # --- Service Accounts ---
    try {
        $svcAccounts = Get-ADUser -Filter { ServicePrincipalName -like "*" } `
            -Properties DisplayName, Enabled, LastLogonDate, PasswordNeverExpires, PasswordLastSet, `
                        ServicePrincipalName, DistinguishedName
        # Also look in OUs with "service" in the name
        $svcOUs        = Get-ADOrganizationalUnit -Filter { Name -like "*service*" } -ErrorAction SilentlyContinue
        $svcOUAccounts = [System.Collections.Generic.List[object]]::new()
        foreach ($ou in $svcOUs) {
            $ouAccts = Get-ADUser -SearchBase $ou.DistinguishedName -Filter * `
                -Properties DisplayName, Enabled, LastLogonDate, PasswordNeverExpires, PasswordLastSet, `
                            ServicePrincipalName, DistinguishedName -ErrorAction SilentlyContinue
            foreach ($acct in $ouAccts) { $svcOUAccounts.Add($acct) }
        }
        $allSvcAccts = (@($svcAccounts) + @($svcOUAccounts)) | Sort-Object SamAccountName -Unique
        $ad.service_accounts = @($allSvcAccts | ForEach-Object {
            [ordered]@{
                sam_account_name       = $_.SamAccountName
                display_name           = $_.DisplayName
                enabled                = $_.Enabled
                last_logon             = if ($_.LastLogonDate) { $_.LastLogonDate.ToString("o") } else { $null }
                password_never_expires = $_.PasswordNeverExpires
                password_last_set      = if ($_.PasswordLastSet) { $_.PasswordLastSet.ToString("o") } else { $null }
                spns                   = @($_.ServicePrincipalName)
                ou                     = ($_.DistinguishedName -replace '^CN=[^,]+,', '')
            }
        })
    } catch { Warn "Failed to collect service accounts: $_" }

    # --- Privileged Group Membership ---
    try {
        $privilegedGroups = @(
            "Domain Admins",
            "Enterprise Admins",
            "Schema Admins",
            "Backup Operators",
            "Account Operators",
            "Server Operators",
            "Print Operators",
            "Remote Desktop Users",
            "Group Policy Creator Owners",
            "Administrators"
        )

        $ad.privileged_groups = @($privilegedGroups | ForEach-Object {
            $groupName = $_
            try {
                $grp = Get-ADGroup -Identity $groupName -ErrorAction SilentlyContinue
                if (-not $grp) { return }
                $members = Get-ADGroupMember -Identity $groupName -Recursive -ErrorAction SilentlyContinue
                $memberDetails = @($members | ForEach-Object {
                    $m = $_
                    if ($m.objectClass -eq "user") {
                        $u    = Get-ADUser -Identity $m.SamAccountName `
                            -Properties Enabled, DisplayName, ServicePrincipalName -ErrorAction SilentlyContinue
                        $isSvc = ($u -and $u.ServicePrincipalName -and $u.ServicePrincipalName.Count -gt 0)
                        [ordered]@{
                            sam                = $m.SamAccountName
                            display_name       = if ($u) { $u.DisplayName } else { $m.Name }
                            enabled            = if ($u) { $u.Enabled } else { $null }
                            is_service_account = $isSvc
                        }
                    } else {
                        [ordered]@{
                            sam                = $m.SamAccountName
                            display_name       = $m.Name
                            enabled            = $null
                            is_service_account = $false
                        }
                    }
                })
                [ordered]@{ group_name = $groupName; members = $memberDetails }
            } catch {
                Warn "Failed to collect members for group '$groupName': $_"
                $null
            }
        } | Where-Object { $_ })
    } catch { Warn "Failed to collect privileged groups: $_" }

    $result.data = $ad
    return $result
}

# ---------------------------------------------------------------------------

$script:GPOScriptBlock = {
    param($Params)

    $result = @{ data = $null; errors = [System.Collections.Generic.List[object]]::new(); warnings = [System.Collections.Generic.List[object]]::new() }

    function Fail($msg) { $result.errors.Add(  @{ module = "GPO"; message = $msg; timestamp = (Get-Date -Format "o") }) }
    function Warn($msg) { $result.warnings.Add(@{ module = "GPO"; message = $msg; timestamp = (Get-Date -Format "o") }) }

    if (-not (Get-Module -ListAvailable -Name GroupPolicy)) {
        Fail "GroupPolicy PowerShell module not installed. Install via RSAT."
        return $result
    }
    try {
        Import-Module GroupPolicy     -ErrorAction Stop
        Import-Module ActiveDirectory -ErrorAction SilentlyContinue
    } catch { Fail "Failed to import GroupPolicy module: $_"; return $result }

    $gpo = [ordered]@{}

    # Helper: parse structured GPO settings from namespace-stripped XML document
    function Get-GPOSettings {
        param([xml]$Report)

        $settings = [ordered]@{
            computer_settings = [ordered]@{
                registry_settings     = @()
                security_settings     = [ordered]@{}
                script_assignments    = @()
                folder_redirection    = @()
                software_installation = @()
            }
            user_settings = [ordered]@{
                registry_settings     = @()
                script_assignments    = @()
                folder_redirection    = @()
                software_installation = @()
            }
        }

        function Parse-RegistrySettings {
            param($ConfigNode)
            $regs = [System.Collections.Generic.List[object]]::new()
            if (-not $ConfigNode) { return @($regs) }
            $regSection = $ConfigNode.RegistrySettings
            if (-not $regSection) { return @($regs) }
            foreach ($r in @($regSection.Registry)) {
                if (-not $r) { continue }
                $regs.Add([ordered]@{
                    key_path = $r.Properties.key
                    name     = $r.Properties.name
                    type     = $r.Properties.type
                    value    = $r.Properties.value
                    action   = $r.Properties.action
                })
            }
            return @($regs)
        }

        function Parse-ScriptAssignments {
            param($ConfigNode, [string]$ConfigType)
            $scripts = [System.Collections.Generic.List[object]]::new()
            if (-not $ConfigNode) { return @($scripts) }
            $scriptSection = $ConfigNode.Scripts
            if (-not $scriptSection) { return @($scripts) }
            foreach ($scriptType in @("Startup","Shutdown","Logon","Logoff")) {
                foreach ($s in @($scriptSection.$scriptType.Script)) {
                    if (-not $s) { continue }
                    $scripts.Add([ordered]@{
                        type       = $scriptType
                        config     = $ConfigType
                        command    = $s.Command
                        parameters = $s.Parameters
                        order      = $s.Order
                    })
                }
            }
            return @($scripts)
        }

        function Parse-SoftwareInstallation {
            param($ConfigNode)
            $sw = [System.Collections.Generic.List[object]]::new()
            if (-not $ConfigNode) { return @($sw) }
            $swNode = $ConfigNode.SoftwareInstallation
            if (-not $swNode) { return @($sw) }
            foreach ($p in @($swNode.MsiApplication)) {
                if (-not $p) { continue }
                $sw.Add([ordered]@{
                    name         = $p.Name
                    source_path  = $p.Path
                    deployment   = $p.DeploymentType
                    auto_install = $p.AutoInstall
                })
            }
            return @($sw)
        }

        $compNode = $Report.GPO.Computer
        $userNode = $Report.GPO.User

        $settings.computer_settings.registry_settings = Parse-RegistrySettings $compNode
        $settings.user_settings.registry_settings     = Parse-RegistrySettings $userNode

        # Computer Security Settings
        try {
            $secNode = $compNode.SecuritySettings
            if ($secNode) {
                $uraList = @($secNode.UserRightsAssignment)
                if ($uraList) {
                    $settings.computer_settings.security_settings.user_rights = @($uraList | ForEach-Object {
                        if (-not $_) { return }
                        [ordered]@{
                            right   = $_.Name
                            members = @($_.Member | ForEach-Object { $_.Name.'#text' })
                        }
                    } | Where-Object { $_ })
                }
                $sysAccess = $secNode.SystemAccess
                if ($sysAccess) {
                    $settings.computer_settings.security_settings.system_access = [ordered]@{
                        minimum_password_age    = $sysAccess.MinimumPasswordAge
                        maximum_password_age    = $sysAccess.MaximumPasswordAge
                        minimum_password_length = $sysAccess.MinimumPasswordLength
                        password_complexity     = $sysAccess.PasswordComplexity
                        lockout_bad_count       = $sysAccess.LockoutBadCount
                        lockout_duration        = $sysAccess.LockoutDuration
                    }
                }
                $secDescs = @($secNode.SecurityDescriptor)
                if ($secDescs) {
                    $settings.computer_settings.security_settings.security_descriptors = @($secDescs | ForEach-Object {
                        if (-not $_) { return }
                        [ordered]@{ name = $_.Name; sddl = $_.SDDL }
                    } | Where-Object { $_ })
                }
            }
        } catch {}

        $settings.computer_settings.script_assignments    = Parse-ScriptAssignments $compNode "Computer"
        $settings.user_settings.script_assignments        = Parse-ScriptAssignments $userNode "User"
        $settings.computer_settings.software_installation = Parse-SoftwareInstallation $compNode
        $settings.user_settings.software_installation     = Parse-SoftwareInstallation $userNode

        # Folder Redirection (User)
        try {
            $fdNode = $userNode.FolderRedirection
            if ($fdNode) {
                $settings.user_settings.folder_redirection = @(@($fdNode.Folder) | ForEach-Object {
                    if (-not $_) { return }
                    [ordered]@{
                        name             = $_.Id
                        destination_path = $_.Location.DestinationPath
                        redirect_type    = $_.Location.LocationType
                        grant_exclusive  = $_.GrantExclusive
                        move_contents    = $_.MoveContents
                    }
                } | Where-Object { $_ })
            }
        } catch {}

        return $settings
    }

    # Main GPO collection
    try {
        $gpos = Get-GPO -All
        $gpo.summary = [ordered]@{
            total_count    = $gpos.Count
            enabled_count  = ($gpos | Where-Object { $_.GpoStatus -eq "AllSettingsEnabled" }).Count
            disabled_count = ($gpos | Where-Object { $_.GpoStatus -eq "AllSettingsDisabled" }).Count
        }

        $gpo.policies = @($gpos | ForEach-Object {
            $gpoObj        = $_
            $links         = @()
            $parsedSettings = $null

            try {
                # Strip ALL XML namespaces - both declarations and prefixes on elements/attributes
                $reportRaw = Get-GPOReport -Guid $gpoObj.Id -ReportType XML -ErrorAction Stop
                # Remove all namespace declarations: xmlns="..." and xmlns:prefix="..."
                $reportRaw = $reportRaw -replace 'xmlns(:[a-zA-Z0-9]+)?="[^"]*"', ''
                # Remove all namespace prefixes from elements: <q1:Name> -> <Name>, </q1:Name> -> </Name>
                $reportRaw = $reportRaw -replace '<(/?)([a-zA-Z0-9]+):', '<$1'
                # Remove all namespace prefixes from attributes: xsi:type -> type
                $reportRaw = $reportRaw -replace '\s[a-zA-Z0-9]+:([a-zA-Z0-9]+)=', ' $1='
                [xml]$report = $reportRaw

                $linksNodes = $report.GPO.LinksTo
                if ($linksNodes) {
                    $linkItems = @($linksNodes.Link)
                    if (-not $linkItems -and $linksNodes.SOMPath) {
                        $linkItems = @($linksNodes)
                    }
                    $links = @($linkItems | Where-Object { $_ } | ForEach-Object {
                        [ordered]@{
                            target   = $_.SOMPath
                            enabled  = $_.Enabled
                            enforced = $_.NoOverride
                        }
                    })
                }

                try {
                    $parsedSettings = Get-GPOSettings -Report $report
                } catch {
                    Warn "Failed to parse settings for GPO '$($gpoObj.DisplayName)': $_"
                }
            } catch {
                Warn "Failed to get report for GPO '$($gpoObj.DisplayName)': $_"
            }

            [ordered]@{
                name             = $gpoObj.DisplayName
                id               = $gpoObj.Id.ToString()
                status           = $gpoObj.GpoStatus.ToString()
                created          = $gpoObj.CreationTime.ToString("o")
                modified         = $gpoObj.ModificationTime.ToString("o")
                computer_enabled = $gpoObj.Computer.Enabled
                user_enabled     = $gpoObj.User.Enabled
                computer_version = "$($gpoObj.Computer.DSVersion).$($gpoObj.Computer.SysvolVersion)"
                user_version     = "$($gpoObj.User.DSVersion).$($gpoObj.User.SysvolVersion)"
                wmi_filter       = if ($gpoObj.WmiFilter) { $gpoObj.WmiFilter.Name } else { $null }
                description      = $gpoObj.Description
                links            = $links
                settings         = $parsedSettings
            }
        })

        $gpo.unlinked_gpos = @($gpo.policies | Where-Object { $_.links.Count -eq 0 } | ForEach-Object { $_.name })
    } catch { Fail "Failed to collect GPOs: $_" }

    # WMI Filters
    try {
        $domain  = Get-ADDomain
        $wmiPath = "CN=SOM,CN=WMIPolicy,CN=System,$($domain.DistinguishedName)"
        $wmiFilters = Get-ADObject -SearchBase $wmiPath -Filter { objectClass -eq "msWMI-Som" } -Properties *
        $gpo.wmi_filters = @($wmiFilters | ForEach-Object {
            [ordered]@{
                name        = $_."msWMI-Name"
                description = $_."msWMI-Parm1"
                query       = $_."msWMI-Parm2"
                author      = $_."msWMI-Author"
            }
        })
    } catch { Warn "Failed to collect WMI filters: $_" }

    $result.data = $gpo
    return $result
}

# ---------------------------------------------------------------------------

$script:SCCMScriptBlock = {
    param($Params)

    $result = @{ data = $null; errors = [System.Collections.Generic.List[object]]::new(); warnings = [System.Collections.Generic.List[object]]::new() }

    function Fail($msg) { $result.errors.Add(  @{ module = "SCCM"; message = $msg; timestamp = (Get-Date -Format "o") }) }
    function Warn($msg) { $result.warnings.Add(@{ module = "SCCM"; message = $msg; timestamp = (Get-Date -Format "o") }) }

    # Inline retry wrapper (runspaces are isolated - cannot call outer scope functions)
    function Invoke-Retry {
        param([scriptblock]$SB, [int]$Max = 3, [int]$Delay = 5, [string]$Desc = "op")
        $attempt = 0; $lastEx = $null
        while ($attempt -lt $Max) {
            $attempt++
            try { return (& $SB) }
            catch { $lastEx = $_; if ($attempt -lt $Max) { Start-Sleep -Seconds $Delay } }
        }
        throw $lastEx
    }

    $SCCMSiteServer = $Params.SCCMSiteServer
    $SCCMSiteCode   = $Params.SCCMSiteCode

    # Auto-detect
    if (-not $SCCMSiteServer -or -not $SCCMSiteCode) {
        try {
            $smsProvider = Invoke-Retry -SB {
                Get-CimInstance -Namespace "root\ccm" -ClassName SMS_Authority -ErrorAction Stop
            } -Desc "SCCM authority detection"
            if (-not $SCCMSiteServer) { $SCCMSiteServer = $smsProvider.CurrentManagementPoint }
            if (-not $SCCMSiteCode)   { $SCCMSiteCode   = ($smsProvider.Name -split ":")[1] }
        } catch {
            Warn "SCCM client not detected on this machine. Attempting WMI..."
        }
    }

    if (-not $SCCMSiteServer -or -not $SCCMSiteCode) {
        Fail "Could not determine SCCM site server/code. Use -SCCMSiteServer and -SCCMSiteCode parameters."
        return $result
    }

    $sccm          = [ordered]@{}
    $sccmNamespace = "root\sms\site_$SCCMSiteCode"

    # --- Site Info ---
    try {
        $site = Invoke-Retry -SB {
            Get-CimInstance -ComputerName $SCCMSiteServer -Namespace $sccmNamespace -ClassName SMS_Site -ErrorAction Stop
        } -Desc "SCCM site info"
        $sccm.site = [ordered]@{
            site_code    = $site.SiteCode
            site_name    = $site.SiteName
            server       = $site.ServerName
            version      = $site.Version
            build_number = $site.BuildNumber
            type         = switch ($site.Type) { 1 { "Secondary" } 2 { "Primary" } 4 { "CAS" } default { $site.Type } }
        }
    } catch { Fail "Failed to collect site info: $_" }

    # --- Device Inventory Summary ---
    try {
        $devices = Invoke-Retry -SB {
            Get-CimInstance -ComputerName $SCCMSiteServer -Namespace $sccmNamespace `
                -ClassName SMS_R_System `
                -Property Name, OperatingSystemNameandVersion, Client, Active, `
                           ResourceId, IPAddresses, LastLogonTimestamp, ADSiteName `
                -ErrorAction Stop
        } -Desc "SCCM device inventory"
        $sccm.devices = [ordered]@{
            total_count      = $devices.Count
            active_count     = ($devices | Where-Object Active -eq $true).Count
            client_installed = ($devices | Where-Object Client -eq 1).Count
            os_summary       = @($devices | Group-Object OperatingSystemNameandVersion | Sort-Object Count -Descending | ForEach-Object {
                [ordered]@{ os = $_.Name; count = $_.Count }
            })
            devices          = @($devices | ForEach-Object {
                [ordered]@{
                    name         = $_.Name
                    resource_id  = $_.ResourceId
                    os           = $_.OperatingSystemNameandVersion
                    active       = $_.Active
                    client       = [bool]$_.Client
                    ip_addresses = @($_.IPAddresses)
                    ad_site      = $_.ADSiteName
                }
            })
        }
    } catch { Fail "Failed to collect device inventory: $_" }

    # --- Collections ---
    try {
        $collections = Invoke-Retry -SB {
            Get-CimInstance -ComputerName $SCCMSiteServer -Namespace $sccmNamespace `
                -ClassName SMS_Collection `
                -Property Name, CollectionID, MemberCount, CollectionType, LimitToCollectionID, Comment `
                -ErrorAction Stop
        } -Desc "SCCM collections"
        $sccm.collections = [ordered]@{
            device_collections = @($collections | Where-Object CollectionType -eq 2 | ForEach-Object {
                [ordered]@{
                    name                = $_.Name
                    id                  = $_.CollectionID
                    member_count        = $_.MemberCount
                    limiting_collection = $_.LimitToCollectionID
                    comment             = $_.Comment
                }
            })
            user_collections = @($collections | Where-Object CollectionType -eq 1 | ForEach-Object {
                [ordered]@{
                    name                = $_.Name
                    id                  = $_.CollectionID
                    member_count        = $_.MemberCount
                    limiting_collection = $_.LimitToCollectionID
                    comment             = $_.Comment
                }
            })
        }
    } catch { Fail "Failed to collect collections: $_" }

    # --- Applications & Packages ---
    try {
        $apps = Invoke-Retry -SB {
            Get-CimInstance -ComputerName $SCCMSiteServer -Namespace $sccmNamespace `
                -ClassName SMS_Application -Filter "IsLatest = 1" `
                -Property LocalizedDisplayName, SoftwareVersion, IsDeployed, IsEnabled, DateCreated, CreatedBy `
                -ErrorAction Stop
        } -Desc "SCCM applications"
        $sccm.applications = @($apps | ForEach-Object {
            [ordered]@{
                name       = $_.LocalizedDisplayName
                version    = $_.SoftwareVersion
                deployed   = $_.IsDeployed
                enabled    = $_.IsEnabled
                created    = if ($_.DateCreated) { $_.DateCreated.ToString("o") } else { $null }
                created_by = $_.CreatedBy
            }
        })
    } catch { Fail "Failed to collect applications: $_" }

    # --- Patch Compliance ---
    try {
        $updateSummary = Invoke-Retry -SB {
            Get-CimInstance -ComputerName $SCCMSiteServer -Namespace $sccmNamespace `
                -ClassName SMS_UpdateSummary -ErrorAction Stop
        } -Desc "SCCM update summary"
        if ($updateSummary) {
            $sccm.patch_compliance = [ordered]@{
                total_updates = $updateSummary.Count
                compliant     = ($updateSummary | Where-Object { $_.NumCompliant    -gt 0 }).Count
                non_compliant = ($updateSummary | Where-Object { $_.NumNonCompliant -gt 0 }).Count
                unknown       = ($updateSummary | Where-Object { $_.NumUnknown      -gt 0 }).Count
                error         = ($updateSummary | Where-Object { $_.NumError        -gt 0 }).Count
            }

            # Critical/Important updates missing from >10% of devices
            try {
                $totalDevCount = if ($sccm.devices) { $sccm.devices.total_count } else { 1 }
                $threshold     = [math]::Floor($totalDevCount * 0.10)
                $criticalMissing = Invoke-Retry -SB {
                    Get-CimInstance -ComputerName $SCCMSiteServer -Namespace $sccmNamespace `
                        -ClassName SMS_SoftwareUpdate `
                        -Filter "SeverityName = 'Critical' OR SeverityName = 'Important'" `
                        -Property CI_ID, ArticleID, BulletinID, LocalizedDisplayName, SeverityName `
                        -ErrorAction Stop
                } -Desc "SCCM critical updates"
                $sccm.critical_missing_updates = @($criticalMissing | ForEach-Object {
                    $upd     = $_
                    $summary = $updateSummary | Where-Object { $_.CI_ID -eq $upd.CI_ID } | Select-Object -First 1
                    if ($summary -and $summary.NumNonCompliant -gt $threshold) {
                        [ordered]@{
                            article_id    = $upd.ArticleID
                            bulletin_id   = $upd.BulletinID
                            title         = $upd.LocalizedDisplayName
                            severity      = $upd.SeverityName
                            non_compliant = $summary.NumNonCompliant
                        }
                    }
                } | Where-Object { $_ })
            } catch { Warn "Failed to collect critical missing updates: $_" }
        }
    } catch { Warn "Failed to collect patch compliance: $_" }

    # --- Software Inventory (top 50 most installed) ---
    try {
        $softwareInv = Invoke-Retry -SB {
            Get-CimInstance -ComputerName $SCCMSiteServer -Namespace $sccmNamespace `
                -ClassName SMS_G_System_INSTALLED_SOFTWARE `
                -Property ProductName, ProductVersion, Publisher `
                -ErrorAction Stop
        } -Desc "SCCM software inventory"
        $sccm.software_inventory = @(
            $softwareInv | Group-Object ProductName | Sort-Object Count -Descending |
            Select-Object -First 50 | ForEach-Object {
                $sample = $_.Group | Select-Object -First 1
                [ordered]@{
                    product_name  = $_.Name
                    install_count = $_.Count
                    version       = $sample.ProductVersion
                    publisher     = $sample.Publisher
                }
            }
        )
    } catch { Warn "Failed to collect software inventory: $_" }

    # --- BitLocker Status ---
    try {
        $encVolumes = Invoke-Retry -SB {
            Get-CimInstance -ComputerName $SCCMSiteServer -Namespace $sccmNamespace `
                -ClassName SMS_G_System_ENCRYPTABLE_VOLUME `
                -Property DriveLetter, EncryptionMethod, ProtectionStatus, ConversionStatus `
                -ErrorAction Stop
        } -Desc "SCCM BitLocker status"
        $sccm.bitlocker_status = [ordered]@{
            encrypted_count     = ($encVolumes | Where-Object { $_.ConversionStatus -eq 1 }).Count
            not_encrypted_count = ($encVolumes | Where-Object { $_.ConversionStatus -eq 0 }).Count
            protection_on_count = ($encVolumes | Where-Object { $_.ProtectionStatus -eq 1 }).Count
            total_volumes       = $encVolumes.Count
        }
    } catch { Warn "Failed to collect BitLocker status: $_" }

    $result.data = $sccm
    return $result
}

# ---------------------------------------------------------------------------

$script:NetworkScriptBlock = {
    param($Params)

    $result = @{ data = $null; errors = [System.Collections.Generic.List[object]]::new(); warnings = [System.Collections.Generic.List[object]]::new() }

    function Fail($msg) { $result.errors.Add(  @{ module = "Network"; message = $msg; timestamp = (Get-Date -Format "o") }) }
    function Warn($msg) { $result.warnings.Add(@{ module = "Network"; message = $msg; timestamp = (Get-Date -Format "o") }) }

    # Inline retry wrapper
    function Invoke-Retry {
        param([scriptblock]$SB, [int]$Max = 3, [int]$Delay = 5, [string]$Desc = "op")
        $attempt = 0; $lastEx = $null
        while ($attempt -lt $Max) {
            $attempt++
            try { return (& $SB) }
            catch { $lastEx = $_; if ($attempt -lt $Max) { Start-Sleep -Seconds $Delay } }
        }
        throw $lastEx
    }

    Import-Module ActiveDirectory -ErrorAction SilentlyContinue

    $net = [ordered]@{}

    # --- DNS Configuration ---
    try {
        if (Get-Module -ListAvailable -Name DnsServer) {
            Import-Module DnsServer -ErrorAction Stop
            $zones = Get-DnsServerZone
            $net.dns = [ordered]@{
                source     = "DnsServer module"
                zones      = @($zones | ForEach-Object {
                    [ordered]@{
                        name             = $_.ZoneName
                        type             = $_.ZoneType
                        is_reverse       = $_.IsReverseLookupZone
                        is_ad_integrated = $_.IsDsIntegrated
                        dynamic_update   = $_.DynamicUpdate.ToString()
                    }
                })
                forwarders = @(
                    Invoke-Retry -SB { (Get-DnsServerForwarder).IPAddress.IPAddressToString } -Desc "DNS forwarders"
                )
            }
        } else {
            $dnsData = [ordered]@{
                source                 = "Client-side collection (DnsServer module not available)"
                configured_servers     = @()
                dns_suffix_search_list = @()
                dns_records_from_ad    = @()
                srv_records            = @()
            }

            try {
                $dnsAddrs = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue
                $dnsData.configured_servers = @($dnsAddrs | ForEach-Object {
                    [ordered]@{ interface = $_.InterfaceAlias; servers = @($_.ServerAddresses) }
                })
            } catch {}

            try {
                $dnsClient  = Get-DnsClient -ErrorAction SilentlyContinue
                $suffixes    = @($dnsClient | Select-Object -ExpandProperty ConnectionSpecificSuffix -Unique | Where-Object { $_ })
                $globalSuffix = (Get-DnsClientGlobalSetting -ErrorAction SilentlyContinue).SuffixSearchList
                if ($globalSuffix) { $suffixes += $globalSuffix }
                $dnsData.dns_suffix_search_list = @($suffixes | Select-Object -Unique)
            } catch {}

            try {
                if (Get-Module -Name ActiveDirectory -ErrorAction SilentlyContinue) {
                    $domainDN = (Get-ADDomain).DistinguishedName
                    $dnsContainers = @(
                        "CN=MicrosoftDNS,DC=DomainDnsZones,$domainDN",
                        "CN=MicrosoftDNS,DC=ForestDnsZones,$domainDN"
                    )
                    foreach ($container in $dnsContainers) {
                        try {
                            $zoneObjects = Get-ADObject -SearchBase $container `
                                -Filter { objectClass -eq "dnsZone" } -Properties name, whenCreated `
                                -ErrorAction SilentlyContinue
                            $dnsData.dns_records_from_ad += @($zoneObjects | ForEach-Object {
                                [ordered]@{
                                    zone_name = $_.Name
                                    container = $container -replace "CN=MicrosoftDNS,", ""
                                    created   = if ($_.whenCreated) { $_.whenCreated.ToString("o") } else { $null }
                                }
                            })
                        } catch {}
                    }
                }
            } catch {}

            try {
                $domain = if (Get-Module -Name ActiveDirectory -ErrorAction SilentlyContinue) {
                    (Get-ADDomain).DNSRoot
                } else { $env:USERDNSDOMAIN }
                if ($domain) {
                    $lookups = @("_ldap._tcp.$domain", "_kerberos._tcp.$domain", "_gc._tcp.$domain")
                    $dnsData.srv_records = @($lookups | ForEach-Object {
                        $query = $_
                        try {
                            $res = Invoke-Retry -SB {
                                Resolve-DnsName -Name $query -Type SRV -ErrorAction Stop
                            } -Desc "SRV $query"
                            [ordered]@{
                                query   = $query
                                results = @($res | Where-Object { $_.Type -eq "SRV" } | ForEach-Object {
                                    [ordered]@{
                                        target   = $_.NameTarget
                                        port     = $_.Port
                                        priority = $_.Priority
                                        weight   = $_.Weight
                                    }
                                })
                            }
                        } catch { $null }
                    } | Where-Object { $_ })
                }
            } catch {}

            $net.dns = $dnsData
        }
    } catch { Fail "Failed to collect DNS: $_" }

    # --- DHCP Configuration ---
    try {
        if (Get-Module -ListAvailable -Name DhcpServer) {
            Import-Module DhcpServer -ErrorAction Stop
            $dhcpServers = Get-DhcpServerInDC
            $net.dhcp = [ordered]@{
                source  = "DhcpServer module"
                servers = @($dhcpServers | ForEach-Object {
                    $srv    = $_
                    $scopes = Invoke-Retry -SB {
                        Get-DhcpServerv4Scope -ComputerName $srv.DnsName -ErrorAction Stop
                    } -Desc "DHCP scopes $($srv.DnsName)"
                    [ordered]@{
                        server_name = $srv.DnsName
                        ip_address  = $srv.IPAddress
                        scopes      = @($scopes | ForEach-Object {
                            $scopeId = $_.ScopeId
                            $dnsName = $srv.DnsName
                            $stats   = try {
                                Invoke-Retry -SB {
                                    Get-DhcpServerv4ScopeStatistics -ComputerName $dnsName `
                                        -ScopeId $scopeId -ErrorAction Stop
                                } -Desc "DHCP stats $scopeId"
                            } catch { $null }
                            [ordered]@{
                                scope_id       = $_.ScopeId.ToString()
                                name           = $_.Name
                                subnet_mask    = $_.SubnetMask.ToString()
                                start_range    = $_.StartRange.ToString()
                                end_range      = $_.EndRange.ToString()
                                state          = $_.State
                                lease_duration = $_.LeaseDuration.ToString()
                                in_use         = if ($stats) { $stats.InUse } else { $null }
                                free           = if ($stats) { $stats.Free } else { $null }
                                percent_used   = if ($stats) { $stats.PercentageInUse } else { $null }
                            }
                        })
                    }
                })
            }
        } else {
            $dhcpData = [ordered]@{
                source             = "Client-side collection (DhcpServer module not available)"
                authorized_servers = @()
                client_leases      = @()
            }

            try {
                if (Get-Module -Name ActiveDirectory -ErrorAction SilentlyContinue) {
                    $dhcpAD = Get-ADObject `
                        -SearchBase "CN=NetServices,CN=Services,CN=Configuration,$((Get-ADDomain).DistinguishedName)" `
                        -Filter { objectClass -eq "dhcpClass" } -Properties dhcpServers, name `
                        -ErrorAction SilentlyContinue
                    $dhcpData.authorized_servers = @($dhcpAD | ForEach-Object {
                        [ordered]@{ name = $_.Name; data = $_.dhcpServers }
                    })
                }
            } catch {}

            try {
                $adapters = Get-NetAdapter | Where-Object Status -eq "Up"
                $dhcpData.client_leases = @($adapters | ForEach-Object {
                    $ifIndex = $_.InterfaceIndex; $ifName = $_.Name
                    try {
                        $dhcpEnabled = (Get-NetIPInterface -InterfaceIndex $ifIndex `
                            -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp
                        if ($dhcpEnabled -eq "Enabled") {
                            $lease = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration `
                                -Filter "InterfaceIndex=$ifIndex" -ErrorAction SilentlyContinue
                            [ordered]@{
                                interface      = $ifName
                                dhcp_enabled   = $true
                                dhcp_server    = $lease.DHCPServer
                                ip_address     = ($lease.IPAddress | Select-Object -First 1)
                                subnet_mask    = ($lease.IPSubnet  | Select-Object -First 1)
                                lease_obtained = if ($lease.DHCPLeaseObtained) { $lease.DHCPLeaseObtained.ToString("o") } else { $null }
                                lease_expires  = if ($lease.DHCPLeaseExpires)  { $lease.DHCPLeaseExpires.ToString("o")  } else { $null }
                                dns_domain     = $lease.DNSDomain
                            }
                        }
                    } catch { $null }
                } | Where-Object { $_ })
            } catch {}

            try {
                $dhcpData.discovered_dhcp_servers = @(
                    Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration `
                        -Filter "DHCPEnabled=True" -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty DHCPServer -Unique |
                    Where-Object { $_ }
                )
            } catch {}

            $net.dhcp = $dhcpData
        }
    } catch { Warn "Failed to collect DHCP: $_" }

    # --- Network Adapters & IP Configuration ---
    try {
        $adapters = Get-NetAdapter | Where-Object Status -eq "Up"
        $net.adapters = @($adapters | ForEach-Object {
            $config = Get-NetIPConfiguration -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue
            [ordered]@{
                name            = $_.Name
                interface_desc  = $_.InterfaceDescription
                mac_address     = $_.MacAddress
                link_speed      = $_.LinkSpeed
                ip_addresses    = @($config.IPv4Address | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" })
                default_gateway = $config.IPv4DefaultGateway.NextHop
                dns_servers     = @($config.DNSServer | Where-Object AddressFamily -eq 2 |
                    Select-Object -ExpandProperty ServerAddresses)
            }
        })
    } catch { Fail "Failed to collect network adapters: $_" }

    # --- Routing Table ---
    try {
        $routes = Get-NetRoute -AddressFamily IPv4 | Where-Object {
            $_.DestinationPrefix -ne "0.0.0.0/0" -and
            $_.DestinationPrefix -notlike "127.*"  -and
            $_.DestinationPrefix -notlike "255.*"
        }
        $net.routes = @($routes | ForEach-Object {
            [ordered]@{
                destination = $_.DestinationPrefix
                next_hop    = $_.NextHop
                metric      = $_.RouteMetric
                interface   = $_.InterfaceAlias
            }
        })
    } catch { Warn "Failed to collect routing table: $_" }

    # --- Firewall Rules (summary) ---
    try {
        $fwRules = Get-NetFirewallRule | Where-Object Enabled -eq "True"
        $net.firewall = [ordered]@{
            total_enabled  = $fwRules.Count
            inbound_allow  = ($fwRules | Where-Object { $_.Direction -eq "Inbound"  -and $_.Action -eq "Allow" }).Count
            inbound_block  = ($fwRules | Where-Object { $_.Direction -eq "Inbound"  -and $_.Action -eq "Block" }).Count
            outbound_allow = ($fwRules | Where-Object { $_.Direction -eq "Outbound" -and $_.Action -eq "Allow" }).Count
            outbound_block = ($fwRules | Where-Object { $_.Direction -eq "Outbound" -and $_.Action -eq "Block" }).Count
            rules          = @($fwRules | ForEach-Object {
                [ordered]@{
                    name      = $_.DisplayName
                    direction = $_.Direction.ToString()
                    action    = $_.Action.ToString()
                    profile   = $_.Profile.ToString()
                    program   = $_.Program
                }
            })
        }
    } catch { Warn "Failed to collect firewall rules: $_" }

    # --- Certificate Infrastructure ---
    try {
        $caObjects = @()
        if (Get-Module -Name ActiveDirectory -ErrorAction SilentlyContinue) {
            try {
                $forestDN = (Get-ADForest).RootDomain |
                    ForEach-Object { (Get-ADDomain -Identity $_).DistinguishedName }
                $pkiBase  = "CN=Public Key Services,CN=Services,CN=Configuration,$forestDN"
                $caAD = Invoke-Retry -SB {
                    Get-ADObject -SearchBase $pkiBase `
                        -Filter { objectClass -eq "certificationAuthority" } `
                        -Properties Name, dNSHostName, cACertificate, whenCreated `
                        -ErrorAction Stop
                } -Desc "AD Certificate Authorities"
                $caObjects = @($caAD | ForEach-Object {
                    $certBytes = $_.cACertificate | Select-Object -First 1
                    $certInfo  = $null
                    if ($certBytes) {
                        try {
                            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
                                ,[byte[]]$certBytes)
                            $certInfo = [ordered]@{
                                subject    = $cert.Subject
                                thumbprint = $cert.Thumbprint
                                not_before = $cert.NotBefore.ToString("o")
                                not_after  = $cert.NotAfter.ToString("o")
                                expired    = ($cert.NotAfter -lt (Get-Date))
                            }
                        } catch {}
                    }
                    [ordered]@{
                        ca_name      = $_.Name
                        dns_hostname = $_.dNSHostName
                        created      = if ($_.whenCreated) { $_.whenCreated.ToString("o") } else { $null }
                        ca_cert      = $certInfo
                    }
                })
            } catch { Warn "Failed to query AD for Certificate Authorities: $_" }
        }

        # Check local machine cert store for expiring/expired certs (<90 days)
        $expirySoon = @()
        try {
            $cutoff = (Get-Date).AddDays(90)
            $expiringSoonCerts = Get-ChildItem -Path Cert:\LocalMachine -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509Certificate2] } |
                Where-Object { $_.NotAfter -lt $cutoff }
            $expirySoon = @($expiringSoonCerts | ForEach-Object {
                [ordered]@{
                    subject           = $_.Subject
                    thumbprint        = $_.Thumbprint
                    store_path        = $_.PSParentPath -replace "Microsoft.PowerShell.Security\\Certificate::", "Cert:\"
                    not_after         = $_.NotAfter.ToString("o")
                    expired           = ($_.NotAfter -lt (Get-Date))
                    days_until_expiry = [math]::Floor(($_.NotAfter - (Get-Date)).TotalDays)
                }
            })
        } catch { Warn "Failed to check local certificate store: $_" }

        $net.certificate_infrastructure = [ordered]@{
            certificate_authorities    = $caObjects
            expiring_or_expired_certs  = $expirySoon
        }
    } catch { Warn "Failed to collect certificate infrastructure: $_" }

    $result.data = $net
    return $result
}

# ============================================================================
# PARALLEL EXECUTION ENGINE
# ============================================================================

function Invoke-ModulesParallel {
    param(
        [hashtable]$ModuleMap,
        [hashtable]$SharedParams
    )

    $maxRunspaces = 4
    $pool         = [runspacefactory]::CreateRunspacePool(1, $maxRunspaces)
    $pool.Open()

    $jobs = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($modName in $ModuleMap.Keys) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($ModuleMap[$modName])
        [void]$ps.AddArgument($SharedParams)
        $handle = $ps.BeginInvoke()
        $jobs.Add(@{ Name = $modName; PS = $ps; Handle = $handle; Start = (Get-Date) })
    }

    # Progress indicator
    $completed = [System.Collections.Generic.HashSet[string]]::new()
    while ($completed.Count -lt $jobs.Count) {
        foreach ($j in $jobs) {
            if ($j.Handle.IsCompleted -and -not $completed.Contains($j.Name)) {
                [void]$completed.Add($j.Name)
            }
        }
        $pending = ($jobs | Where-Object { -not $completed.Contains($_.Name) } | ForEach-Object { $_.Name }) -join ", "
        if (-not $Silent -and $pending) {
            Write-Host "`r  Still running: [$pending]$((' ' * 20))" -NoNewline -ForegroundColor DarkCyan
        }
        if ($completed.Count -lt $jobs.Count) { Start-Sleep -Milliseconds 500 }
    }
    if (-not $Silent) { Write-Host "" }

    # Collect results
    $results = @{}
    foreach ($job in $jobs) {
        $modName = $job.Name
        $endTime = Get-Date
        try {
            $output = $job.PS.EndInvoke($job.Handle)
            $results[$modName] = if ($output -and $output.Count -gt 0) {
                $output[0]
            } else {
                @{ data = $null; errors = @(); warnings = @() }
            }
        } catch {
            $results[$modName] = @{
                data     = $null
                errors   = @(@{ module = $modName; message = "Runspace exception: $_"; timestamp = (Get-Date -Format "o") })
                warnings = @()
            }
        }

        # Record timing in metadata
        $EnvironmentData.metadata.modules_timing[$modName] = [ordered]@{
            start        = $job.Start.ToString("o")
            end          = $endTime.ToString("o")
            duration_sec = [math]::Round(($endTime - $job.Start).TotalSeconds, 1)
        }

        $job.PS.Dispose()
    }

    $pool.Close()
    $pool.Dispose()

    return $results
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

if (-not $Silent) {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor White
    Write-Host "  DocForge IT Environment Collector v$CollectorVersion" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor White
    Write-Host ""
}

Write-Status "Collection started at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "INFO" "Main"
Write-Status "Modules: $($Modules -join ', ')" "INFO" "Main"
Write-Status "Output: $OutputPath" "INFO" "Main"
if (-not $Silent) { Write-Host "" }

# Build module map for parallel execution
$moduleMap    = [ordered]@{}
$sharedParams = @{
    SCCMSiteServer = $SCCMSiteServer
    SCCMSiteCode   = $SCCMSiteCode
}

if (Test-ModuleRequested "AD")      { $moduleMap["AD"]      = $script:ADScriptBlock      }
if (Test-ModuleRequested "GPO")     { $moduleMap["GPO"]     = $script:GPOScriptBlock     }
if (Test-ModuleRequested "SCCM")    { $moduleMap["SCCM"]    = $script:SCCMScriptBlock    }
if (Test-ModuleRequested "Network") { $moduleMap["Network"] = $script:NetworkScriptBlock }

Write-Status "Starting parallel collection via RunspacePool (max $([Math]::Min($moduleMap.Count, 4)) concurrent)..." "INFO" "Main"

$moduleResults = Invoke-ModulesParallel -ModuleMap $moduleMap -SharedParams $sharedParams

# Map from runspace key to $EnvironmentData key
$dataKeyMap = @{
    AD      = "active_directory"
    GPO     = "group_policy"
    SCCM    = "sccm"
    Network = "network"
}

foreach ($modName in $moduleResults.Keys) {
    $res = $moduleResults[$modName]

    # Merge errors and warnings into global lists
    foreach ($e in $res.errors)   { $script:CollectionErrors.Add($e);   $script:AnyErrors = $true }
    foreach ($w in $res.warnings) { $script:CollectionWarnings.Add($w) }

    # Store module data
    $dataKey = $dataKeyMap[$modName]
    if ($dataKey) { $EnvironmentData[$dataKey] = $res.data }

    if ($null -ne $res.data) {
        [void]$EnvironmentData.metadata.modules_completed.Add($modName)
        Write-Status "$modName collection complete." "SUCCESS" $modName
    } else {
        Write-Status "$modName returned no data (check errors)." "WARN" $modName
    }

    # Partial save after each module is merged
    Save-PartialData
}

# Finalize metadata
$EnvironmentData.metadata.errors         = $script:CollectionErrors.ToArray()
$EnvironmentData.metadata.warnings       = $script:CollectionWarnings.ToArray()
$EnvironmentData.metadata.collection_end = (Get-Date -Format "o")

# ============================================================================
# OUTPUT
# ============================================================================

$outputJsonFile = Join-Path $OutputPath "docforge_collection_$Timestamp.json"
$outputPkgFile  = $outputJsonFile -replace '\.json$', '.dfpkg'

try {
    $jsonOutput = $EnvironmentData | ConvertTo-Json -Depth 20 -Compress:$false
    $jsonBytes  = [System.Text.Encoding]::UTF8.GetBytes($jsonOutput)

    if ($SkipEncryption) {
        $jsonOutput | Out-File -FilePath $outputJsonFile -Encoding UTF8
        Write-Status "Collection saved (unencrypted): $outputJsonFile" "SUCCESS" "Output"
    } else {
        Write-Status "Encrypting output with AES-256-CBC (PBKDF2/SHA256, 100,000 iterations)..." "INFO" "Output"
        $encryptedBytes = Protect-DataAES256 -PlainBytes $jsonBytes -Passphrase $Passphrase
        [System.IO.File]::WriteAllBytes($outputPkgFile, $encryptedBytes)

        $originalMB  = [math]::Round($jsonBytes.Length / 1MB, 2)
        $encryptedMB = [math]::Round($encryptedBytes.Length / 1MB, 2)
        Write-Status "Collection saved (AES-256-CBC encrypted): $outputPkgFile" "SUCCESS" "Output"
        Write-Status "Size: ${originalMB}MB JSON -> ${encryptedMB}MB .dfpkg (format v2)" "INFO" "Output"
    }

    # Remove the partial save now that the final file is written
    if (Test-Path $PartialFile) {
        Remove-Item $PartialFile -Force -ErrorAction SilentlyContinue
    }
} catch {
    Add-CollectionError "Output" "Failed to save output: $_"
    Write-Status "FATAL: Could not save collection output." "ERROR" "Output"
    Write-Status "Partial data preserved at: $PartialFile" "WARN" "Output"
}

# ============================================================================
# SUMMARY
# ============================================================================

if (-not $Silent) {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor White
    Write-Host "  Collection Summary" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor White
}

Write-Status "Modules completed: $($EnvironmentData.metadata.modules_completed -join ', ')" "INFO" "Main"
Write-Status "Errors: $($script:CollectionErrors.Count)"     $(if ($script:CollectionErrors.Count   -gt 0) { "WARN" } else { "SUCCESS" }) "Main"
Write-Status "Warnings: $($script:CollectionWarnings.Count)" $(if ($script:CollectionWarnings.Count -gt 0) { "WARN" } else { "SUCCESS" }) "Main"

if (-not $Silent) {
    # Per-module timing
    Write-Host ""
    Write-Host "  Module Timing:" -ForegroundColor Cyan
    foreach ($mod in $EnvironmentData.metadata.modules_timing.Keys) {
        $t = $EnvironmentData.metadata.modules_timing[$mod]
        Write-Host "    $mod : $($t.duration_sec)s" -ForegroundColor White
    }

    if ($script:CollectionErrors.Count -gt 0) {
        Write-Host ""
        Write-Host "Errors:" -ForegroundColor Red
        $script:CollectionErrors | ForEach-Object {
            Write-Host "  [$($_.module)] $($_.message)" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Status "Upload this file to your DocForge dashboard to generate documentation." "INFO" "Main"
    Write-Host ""
}

# Exit code for scheduled task / silent mode
if ($Silent) {
    exit $(if ($script:AnyErrors) { 1 } else { 0 })
}
