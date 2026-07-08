<#  Diagnostic: find SCCM site code / server on this machine  #>
$out = [System.Text.StringBuilder]::new()

# 1. Registry search under HKCU & HKLM for anything CM/SMS/ConfigMgr
foreach ($hive in @("HKCU:\SOFTWARE\Microsoft","HKLM:\SOFTWARE\Microsoft")) {
    try {
        Get-ChildItem $hive -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "ConfigMgr|ConfigurationManager|SCCM|SMS|AdminUI" } |
        ForEach-Object {
            $null = $out.AppendLine("KEY: $($_.Name)")
            try {
                Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue |
                Select-Object * -ExcludeProperty PS* |
                Format-List | Out-String | ForEach-Object { $null = $out.AppendLine($_) }
            } catch {}
        }
    } catch {}
}

# 2. WMI / CIM check for SMS_ProviderLocation
try {
    $p = Get-CimInstance -Namespace "root\SMS" -ClassName "SMS_ProviderLocation" -ErrorAction Stop
    $null = $out.AppendLine("WMI root\SMS SMS_ProviderLocation: $($p | Out-String)")
} catch { $null = $out.AppendLine("WMI root\SMS: $_") }

# 3. Check CCM client
foreach ($p in @("HKLM:\SOFTWARE\Microsoft\SMS\Mobile Client","HKLM:\SOFTWARE\Microsoft\CCM","HKLM:\SOFTWARE\Microsoft\CCMSetup")) {
    if (Test-Path $p) {
        $null = $out.AppendLine("CCM KEY: $p")
        $null = $out.AppendLine((Get-ItemProperty $p | Select-Object * -ExcludeProperty PS* | Format-List | Out-String))
    }
}

# 4. List any existing PSDrives
$null = $out.AppendLine("PSDrives: $(Get-PSDrive | Out-String)")

$result = $out.ToString()
$result | Out-File "$env:TEMP\sccm_diagnostic.txt" -Encoding UTF8
Write-Host "Diagnostic written to sccm_diagnostic.txt" -ForegroundColor Green
Write-Host $result
