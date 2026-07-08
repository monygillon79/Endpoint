# Get-SCCMAppInventory.ps1

Exports an inventory of all deployed SCCM applications to CSV, including whether each app currently has an icon — stage 1 of the icon pipeline.

## What it does

- Connects to a Configuration Manager (Current Branch) site via the ConfigurationManager module (4-tier module discovery, so it works on admin workstations with non-standard console installs).
- Queries all deployed Applications (optionally legacy Packages with `-IncludePackages`).
- Detects icon presence with namespace-aware XML parsing of `SDMPackageXML` (`XmlNamespaceManager` + XPath, regex fallback) — naive dot-notation navigation silently returns `$null` on the AppMgmt default namespace and misreports every app as icon-less.
- Writes `sccm_inventory.csv` with name, version, publisher, deployment state, and `IconStatus`.

## Usage

```powershell
.\Get-SCCMAppInventory.ps1 -SiteCode "P01" -SiteServer "cm01.contoso.com"
.\Get-SCCMAppInventory.ps1 -SiteCode "P01" -SiteServer "cm01.contoso.com" -IncludePackages -OutputPath "C:\SCCM\inventory.csv"
```

Requires the ConfigMgr console installed locally and rights to query the SMS Provider.
