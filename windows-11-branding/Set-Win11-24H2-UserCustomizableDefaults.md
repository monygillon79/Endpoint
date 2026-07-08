# Set-Win11-24H2-UserCustomizableDefaults.ps1

Sets default Start menu, taskbar, and wallpaper during Windows 11 24H2 imaging **without locking anything down** — users can change everything after first sign-in. This is the "sane defaults" counterpart to `Set-Win11Branding.ps1`.

## What it does

- Detects the target Windows root from a parameter or SCCM task sequence variables (works online and offline, so it can run right after *Apply Operating System Image*).
- Copies or generates Start layout JSON into the Default profile shell folder.
- Copies or generates taskbar layout XML (`LayoutModification.xml`) into the OEM folder and Default profile, and sets `LayoutXMLPath` in the target SOFTWARE hive.
- Stages the corporate wallpaper into the Windows wallpaper directory and seeds the Default User hive.
- Registers an Active Setup entry so each new user gets the default wallpaper exactly once — after that it's theirs to change.
- Optionally applies the wallpaper to already-loaded user hives when run against the online OS.

## Usage

SCCM task sequence step (SYSTEM), after *Apply Operating System Image* and before *Setup Windows and ConfigMgr*. Package the wallpaper and optional layout files alongside the script.

## Design notes

- Windows 11 Start pins depend on the pinned apps actually existing at first sign-in; validate Teams/Outlook pin identifiers against your image.
- Active Setup's operative values are `StubPath`, `Version`, and `IsInstalled` — the display string is cosmetic.
- Use this script when the goal is a default *experience*; use `Set-Win11Branding.ps1` only when enforcement is a requirement.

## Rollback

Adjust or remove the copied layout/wallpaper files and the Active Setup entry before first sign-ins; existing users can simply change their settings.
