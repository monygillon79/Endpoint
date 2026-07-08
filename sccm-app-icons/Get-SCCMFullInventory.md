# Get-SCCMFullInventory.ps1

Zero-parameter, run-anywhere SCCM estate report: Applications **and** legacy Packages with their deployment collections and creator, exported to CSV.

## What it does

- Auto-detects the site code and server — checks existing `CMSite` PSDrives first, then all four AdminUI registry paths (HKCU/HKLM x 32/64-bit), then AdminUI connection history. Falls back to template values (`P01` / `cm01.contoso.local`) as a last resort; edit those for your site.
- Queries all Applications and Packages, resolves the collections each is deployed to, and records who created them.
- Writes `sccm_inventory_full.csv` (default under `C:\Scripts\SCCM\` — adjust `$outputPath` at the bottom of the script).

## Usage

```powershell
.\Get-SCCMFullInventory.ps1     # no parameters needed on a console workstation
```

Use `Get-SCCMAppInventory.ps1` instead when feeding the icon pipeline — this one is the human-facing estate report (deployment mapping, ownership), not the icon-status feed.
