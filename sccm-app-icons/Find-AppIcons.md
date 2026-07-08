# Find-AppIcons.ps1

Automated icon sourcing for an entire SCCM application estate: reads the inventory CSV and hunts down a high-quality 512x512 PNG for every app, producing a reviewable CSV before anything touches SCCM.

## What it does

For each application, tries sources in priority order:

1. **WinGet manifests** (GitHub API, optional `-GitHubToken` to lift rate limits) — most accurate for known Windows apps
2. **Clearbit Logo API** — publisher/company logos, free, no key
3. **Publisher website** `og:image` / `apple-touch-icon`
4. Flags `MANUAL_NEEDED` for anything unresolved (expect this for internal/line-of-business apps)

Downloads are normalized to 512x512 PNG via GDI+ — images are loaded through a `MemoryStream` rather than `Image.FromFile()` to avoid the file-lock-induced "A generic error occurred in GDI+" save failure, with disposal in `finally` blocks. Results land in `icons\` plus `icon_review.csv` for human review.

## Usage

```powershell
.\Find-AppIcons.ps1 -InventoryPath .\sccm_inventory.csv
# live re-check against SCCM, only fetch for apps missing icons:
.\Find-AppIcons.ps1 -InventoryPath .\sccm_inventory.csv -OnlyMissingIcons -SiteCode P01 -SiteServer cm01.contoso.com
```

## Notes

- With `-SiteCode`/`-SiteServer`, icon presence is verified live from `SDMPackageXML` (namespace-aware), overriding possibly-stale CSV status.
- StrictMode-safe throughout (`@()`-wrapped pipeline counts).
- Internal apps rarely have public icons — plan a manual pass for those.
