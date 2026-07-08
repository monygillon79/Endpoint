# LayoutModification.xml

Windows 11 taskbar layout template consumed by the branding/defaults scripts in this folder.

## What it does

- Uses the `LayoutModificationTemplate` schema with `PinListPlacement="Replace"` to define the taskbar pin set (File Explorer, Edge, Outlook, Teams).
- Deployed to the Default profile / OEM folder by `Set-Win11-24H2-UserCustomizableDefaults.ps1` or `Set-Win11Branding.ps1`, and referenced via `LayoutXMLPath`.

## Notes

- `DesktopApplicationLinkPath` entries only resolve if those shortcuts exist at first sign-in.
- The Teams AppUserModelID differs between classic and new Teams — validate with `Get-StartApps *Teams*` on a reference machine.
- `Replace` removes all other default pins; switch to `Append` to keep Microsoft's defaults.
