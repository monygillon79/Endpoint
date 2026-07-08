# Check-TrayAppAutolaunch.ps1

One-shot diagnostic for "why isn't the tray app starting for this user?" — walks every mechanism that can block an HKLM Run-key autostart and prints a labeled verdict for each.

## What it checks

- EXE present under `%ProgramFiles%` and its install timestamp.
- The HKLM `Run` entry itself.
- **HKCU `StartupApproved\Run`** — decodes the first status byte to reveal whether the user disabled the app in Task Manager's Startup tab (`0x03` = disabled), the most commonly missed cause.
- A shadowing HKCU `Run` override.
- Whether the interactive logon predates the install (Run keys only fire at logon — an app installed mid-session won't be running yet).
- Whether the process is actually running.
- The app's crash log (`%LOCALAPPDATA%\...\Logs\fatal.log`, last 40 lines).
- Recent **AppLocker** denies (events 8004/8007) and **Windows Defender** operational events mentioning the binary — the silent killers for unsigned line-of-business apps.

## Usage

```powershell
.\Check-TrayAppAutolaunch.ps1    # run in the affected user's session
```

Written for a specific in-house tray app ("Contoso IT Tray"); repoint the four name/path variables at the top for any autostarted app.
