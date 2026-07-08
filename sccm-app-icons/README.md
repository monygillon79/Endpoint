# SCCM Application Icon Pipeline

Software Center in Configuration Manager looks half-finished when applications ship without icons. This toolset fixes that at fleet scale: inventory every app, auto-source high-resolution icons, apply them through the ConfigMgr SDK, and verify they actually persisted.

## Pipeline

| Stage | Script | Output |
|---|---|---|
| 1. Inventory | `Get-SCCMAppInventory.ps1` | `sccm_inventory.csv` (apps + icon status) |
| 2. Source icons | `Find-AppIcons.ps1` | `icons\` folder + `icon_review.csv` |
| 3. Review | *(human)* | curated icon folder |
| 4. Apply | `Update-AllAppIcons.ps1` (bulk) / `Update-SingleAppIcon.ps1` (surgical) | icons written to SCCM, CSV outcome log |
| 5. Verify | `Verify-AppIcon.ps1` | decoded icon opened for visual confirmation |

Support utilities: `Get-SCCMFullInventory.ps1` (standalone estate report), `Diagnose-SCCMSite.ps1` (site discovery when console state is broken).

## The hard-won part

`Set-CMApplication -IconLocationFile` reports success but **silently fails to persist icons** on some site versions. These scripts instead edit the application's `SDMPackageXML` through the official `Microsoft.ConfigurationManagement.ApplicationManagement` serializer and write it back via `SMS_Application.Put()`, with a ConfigurationManager `IResultObject` fallback and post-write byte verification. A second provider quirk: when the re-serialized XML exceeds ~32 KB, the SMS Provider can no-op the write (timestamp changes, icon doesn't) — so icons are resized in-memory to 175 px by default to stay under the threshold (use `-MaxIconDimension 512` on 2103+ sites).
