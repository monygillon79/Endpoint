Add-Type @"
using System.Runtime.InteropServices;
public class D {
    [DllImport("user32.dll")] public static extern System.IntPtr MonitorFromPoint(int x, int y, int f);
    [DllImport("Shcore.dll")] public static extern int GetDpiForMonitor(System.IntPtr h, int t, out uint x, out uint y);
}
"@
$h = [D]::MonitorFromPoint(0,0,1)
$x = 0; $y = 0
[void][D]::GetDpiForMonitor($h, 0, [ref]$x, [ref]$y)
"Primary monitor DPI: $x (scale = $($x/96.0)x)"
