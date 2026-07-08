# On a target machine, confirm new version installed
Get-ItemProperty 'HKLM:\Software\Contoso\IT Tray' | Select Version, InstallPath
(Get-Item 'C:\Program Files\Contoso IT Tray\ContosoITTray.exe').VersionInfo.FileVersion

# Confirm old ProductCode is gone and new one is registered
Get-WmiObject Win32_Product -Filter "Name='Contoso IT Tray'" | Select Name, Version, IdentifyingNumber
