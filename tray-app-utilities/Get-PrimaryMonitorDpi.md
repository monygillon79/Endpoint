# Get-PrimaryMonitorDpi.ps1

Eleven-line P/Invoke probe that reports the primary monitor's true DPI and scale factor — the value a PerMonitorV2-aware app actually receives, not the 96 that `Graphics.FromHwnd(IntPtr.Zero)` misleadingly returns.

## What it does

- Compiles a tiny C# shim exposing `MonitorFromPoint` (user32) and `GetDpiForMonitor` (shcore, `MDT_EFFECTIVE_DPI`).
- Resolves the monitor at (0,0) and prints its effective DPI and the scale multiplier (e.g., `144 (scale = 1.5x)`).

## Usage

```powershell
.\Get-PrimaryMonitorDpi.ps1
# Primary monitor DPI: 144 (scale = 1.5x)
```

Handy when debugging WinForms/WPF DPI scaling: legacy GDI+ APIs report the system DPI from process start, while `GetDpiForMonitor` reflects per-monitor reality — a mismatch between the two is the classic cause of half-scaled custom-painted UI.
