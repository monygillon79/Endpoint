# Update-SingleAppIcon.ps1

Sets the icon on a single SCCM application the *reliable* way — by editing `SDMPackageXML` through the official `Microsoft.ConfigurationManagement.ApplicationManagement` SDK — with dry-run defaults, diagnostics, and post-write verification.

## Why it exists

`Set-CMApplication -IconLocationFile` can report success without persisting anything, and hand-patching the XML with regex produces schema-invalid documents, stale digests, and opaque `Put()` "Generic failure" errors. This script does the round-trip properly:

1. Loads the app over WMI and deserializes `SDMPackageXML` via `SccmSerializer`.
2. Resizes the icon in-memory (default 175 px — see below) and replaces the `Icon` on the default `DisplayInfo`.
3. Re-serializes (validation-relaxed) and dumps pre-commit diagnostics.
4. Two-attempt save: raw WMI `SMS_Application.Put()`, falling back to the ConfigurationManager `IResultObject.Put()` path (with a reflection probe for `SetPropertyValue`, since `WqlResultObject` doesn't support indexer syntax).
5. Verifies the *saved* XML actually contains the new icon bytes — catching the provider's silent no-op failure mode where only the timestamp changes.
6. On failure, dumps the rejected XML to `%TEMP%` for analysis.

## Usage

```powershell
.\Update-SingleAppIcon.ps1 -AppName "7-Zip 24.09" -IconPath C:\Icons\7zip.png            # dry run
.\Update-SingleAppIcon.ps1 -AppName "7-Zip 24.09" -IconPath C:\Icons\7zip.png -Commit    # apply
```

`-SiteCode`/`-SiteServer` auto-detect from the local registry when omitted.

## The 32 KB gotcha

On many sites the SMS Provider silently no-ops `Put()` when the re-serialized `SDMPackageXML` exceeds ~32 KB (WMI string-property transport limit). A 175 px PNG keeps typical apps under it; SCCM 2103+ sites configured for the larger cap can use `-MaxIconDimension 512`. If a save "succeeds" but the revision number doesn't increment, lower the dimension.
