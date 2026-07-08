$exe = "$env:ProgramFiles\Contoso IT Tray\ContosoITTray.exe"
Write-Host "`n== EXE present ==" -Foreground Cyan
Test-Path $exe
if (Test-Path $exe) { (Get-Item $exe).LastWriteTime }

Write-Host "`n== HKLM Run entry ==" -Foreground Cyan
Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -Name ContosoITTray -ErrorAction SilentlyContinue

Write-Host "`n== HKCU StartupApproved (Task Manager toggle) ==" -Foreground Cyan
$sa = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' -Name ContosoITTray -ErrorAction SilentlyContinue
if ($sa) {
    $b0 = $sa.ContosoITTray[0]
    "First byte: 0x{0:X2}  ({1})" -f $b0, $(if ($b0 -band 1) { 'DISABLED by user' } else { 'enabled' })
} else { 'No StartupApproved entry (= enabled by default)' }

Write-Host "`n== HKCU Run override (would shadow HKLM) ==" -Foreground Cyan
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name ContosoITTray -ErrorAction SilentlyContinue

Write-Host "`n== Logon session vs install time ==" -Foreground Cyan
$logon = (Get-CimInstance Win32_LogonSession | Where-Object {$_.LogonType -eq 2} | Sort-Object StartTime | Select -First 1).StartTime
"Interactive logon started: $logon"
if (Test-Path $exe) { "EXE installed:           $((Get-Item $exe).LastWriteTime)" }

Write-Host "`n== Tray process running? ==" -Foreground Cyan
Get-Process ContosoITTray -ErrorAction SilentlyContinue

Write-Host "`n== Crash log ==" -Foreground Cyan
$log = "$env:LOCALAPPDATA\ContosoITTray\Logs\fatal.log"
if (Test-Path $log) { Get-Content $log -Tail 40 } else { 'no fatal.log' }

Write-Host "`n== AppLocker recent denies (events 8004/8007) ==" -Foreground Cyan
Get-WinEvent -LogName 'Microsoft-Windows-AppLocker/EXE and DLL' -MaxEvents 200 -ErrorAction SilentlyContinue |
    Where-Object { $_.Id -in 8004,8007 -and $_.Message -match 'ContosoITTray' }

Write-Host "`n== Defender blocks ==" -Foreground Cyan
Get-WinEvent -LogName 'Microsoft-Windows-Windows Defender/Operational' -MaxEvents 200 -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match 'ContosoITTray' }
