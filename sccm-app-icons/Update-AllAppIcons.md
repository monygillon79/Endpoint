# Update-AllAppIcons.ps1

Bulk icon application: points at a folder of icon files and applies each to the SCCM application whose name matches the file basename, reusing the proven `Update-SingleAppIcon.ps1` pipeline (SDK serializer, two-attempt save, post-write verification) per icon.

## What it does

- Loads all SCCM apps **once** into a name dictionary (single WMI query, single SDK/module load).
- Matches each `*.png/*.jpg/*.jpeg/*.bmp/*.ico` basename to an app in three tiers: exact -> normalized (non-alphanumeric stripped) -> substring. Ambiguous matches are skipped, never guessed.
- Resizes in-memory to `-MaxIconDimension` (default 175 px, staying under the SMS Provider's ~32 KB `SDMPackageXML` write threshold).
- Isolates failures per icon — one bad file never aborts the run.
- Logs every outcome to CSV: `SUCCESS`, `NO_OP_TOUCH` (provider accepted the write but didn't persist — detected by byte verification), `NO_MATCH`, `AMBIGUOUS`, `SKIPPED_HAS_ICON`, `PUT_FAILED`; ends with an icon-to-app mapping table.

## Usage

```powershell
.\Update-AllAppIcons.ps1 -IconDir C:\Icons -SiteCode P01 -SiteServer cm01.contoso.local            # dry run
.\Update-AllAppIcons.ps1 -IconDir C:\Icons -SiteCode P01 -SiteServer cm01.contoso.local -Commit    # apply
```

Optional: `-NameFilter` to scope the run, `-SkipIfHasIcon` to leave already-iconned apps untouched.
