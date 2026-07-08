# Verify-AppIcon.ps1

Ground-truth verification that an SCCM application icon really persisted: reads the raw icon bytes back out of `SDMPackageXML` over WMI, decodes them, and opens the image for visual confirmation.

## What it does

- Resolves site code/server (registry auto-detect, parameter override).
- Fetches the application's latest revision (`IsLatest=1`) and extracts the icon block from `SDMPackageXML`.
- Base64-decodes the icon to a temp PNG, reports its dimensions, and opens it in the default viewer — proof independent of what any console cache is showing.
- `-RefreshClient` additionally triggers the client policy cycles so Software Center picks up the change sooner.

## Usage

```powershell
.\Verify-AppIcon.ps1 -AppName "7-Zip 24.09"
.\Verify-AppIcon.ps1 -AppName "7-Zip 24.09" -SiteCode P01 -SiteServer cm01.contoso.local -RefreshClient
```

Useful after any icon write, and essential when diagnosing the provider's silent no-op mode (timestamp moved, icon didn't).
