# Set-Win11Branding.ps1

Policy-style Windows 11 branding enforcement: wallpaper, lock screen, and Start/taskbar layout applied across default, currently-loaded, and offline user profiles. Use only when lock-down is the intent — for changeable defaults use `Set-Win11-24H2-UserCustomizableDefaults.ps1`.

## What it does

- Copies wallpaper and lock-screen assets into Windows-managed directories.
- Sets HKLM wallpaper policy values (overrides user preference).
- Configures lock-screen policy/CSP registry values and disables Windows Spotlight on the lock screen.
- Copies Start/taskbar layout files into Default profile locations.
- Creates a per-user wallpaper apply script and registers Active Setup for future profiles.
- Iterates loaded user hives and mounts offline profile hives to apply the same values, with retry logic on hive unload.
- Adds a RunOnce fallback in the Default User hive.

## Usage

Run as SYSTEM (SCCM package/program or task sequence step) with wallpaper, lock-screen image, Start JSON, and taskbar XML packaged alongside.

## Design notes

- Hive load/unload can fail when a profile is in use; the script retries unloads, but expect occasional skips on busy machines — those profiles are caught by Active Setup/RunOnce at next sign-in.
- HKLM wallpaper policy wins over user choice by design here.

## Rollback

Remove the HKLM policy values and the Active Setup/RunOnce entries; users regain control of personalization.
