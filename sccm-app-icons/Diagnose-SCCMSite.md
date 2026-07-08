# Diagnose-SCCMSite.ps1

Quick forensic sweep to answer "what SCCM site is this machine actually connected to?" when consoles misbehave or site auto-detection fails.

## What it does

- Recursively searches HKCU/HKLM `SOFTWARE\Microsoft` for ConfigMgr/SMS/AdminUI keys and dumps their values.
- Queries `root\SMS:SMS_ProviderLocation` via CIM for provider bindings.
- Dumps the CCM client keys (`SMS\Mobile Client`, `CCM`, `CCMSetup`).
- Lists existing PSDrives (a connected console leaves a `CMSite` drive).
- Writes the full report to `%TEMP%\sccm_diagnostic.txt` and echoes it to the console.

## Usage

```powershell
.\Diagnose-SCCMSite.ps1
```

Read-only against the registry/WMI; safe to run anywhere.
