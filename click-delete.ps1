Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Drawing;
public class Win32 {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int x, int y, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP   = 0x0004;
    public static void Click(int x, int y) {
        SetCursorPos(x, y);
        mouse_event(MOUSEEVENTF_LEFTDOWN, x, y, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(80);
        mouse_event(MOUSEEVENTF_LEFTUP,   x, y, 0, UIntPtr.Zero);
    }
}
[StructLayout(LayoutKind.Sequential)]
public struct RECT { public int Left, Top, Right, Bottom; }
'@

# Find Chrome window with GitHub tokens page
$root = [System.Windows.Automation.AutomationElement]::RootElement
$classCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'Chrome_WidgetWin_1')
$wins = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $classCond)

$chromeWin = $null
foreach ($w in $wins) {
    if ($w.Current.Name -match 'token|Token') { $chromeWin = $w; break }
}
if (-not $chromeWin) { Write-Output 'GitHub tokens window not found'; exit 1 }

$handle = [IntPtr]$chromeWin.Current.NativeWindowHandle
[Win32]::ShowWindow($handle, 3) | Out-Null   # maximize
Start-Sleep -Milliseconds 300
[Win32]::SetForegroundWindow($handle) | Out-Null
Start-Sleep -Milliseconds 800

# Get window bounds
$rect = New-Object RECT
[Win32]::GetWindowRect($handle, [ref]$rect) | Out-Null
$winX = $rect.Left; $winY = $rect.Top
$winW = $rect.Right - $rect.Left; $winH = $rect.Bottom - $rect.Top
Write-Output "Window at ${winX},${winY} size ${winW}x${winH}"

# Screenshot the window
$bmp = New-Object System.Drawing.Bitmap($winW, $winH)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($winX, $winY, 0, 0, [System.Drawing.Size]::new($winW, $winH))
$g.Dispose()

# Save screenshot for debug
$bmp.Save("$env:TEMP\chrome_snap.png")
Write-Output "Screenshot saved to $env:TEMP\chrome_snap.png"

# Scan for red "Delete" button pixels (GitHub red: approx R>180, G<80, B<80)
$deleteX = -1; $deleteY = -1
for ($y = 100; $y -lt $winH - 10; $y += 2) {
    for ($x = 10; $x -lt $winW - 10; $x += 2) {
        $px = $bmp.GetPixel($x, $y)
        if ($px.R -gt 170 -and $px.G -lt 80 -and $px.B -lt 80) {
            $deleteX = $x; $deleteY = $y
            break
        }
    }
    if ($deleteX -ge 0) { break }
}
$bmp.Dispose()

if ($deleteX -lt 0) {
    Write-Output 'Red Delete button not found in screenshot'
    exit 1
}

$absX = $winX + $deleteX; $absY = $winY + $deleteY
Write-Output "Found red pixel at window-relative $deleteX,$deleteY -> screen $absX,$absY"
[Win32]::Click($absX, $absY)
Write-Output 'Clicked Delete button'
Start-Sleep -Milliseconds 1500

# Screenshot again to find confirm button
$bmp2 = New-Object System.Drawing.Bitmap($winW, $winH)
$g2 = [System.Drawing.Graphics]::FromImage($bmp2)
$g2.CopyFromScreen($winX, $winY, 0, 0, [System.Drawing.Size]::new($winW, $winH))
$g2.Dispose()
$bmp2.Save("$env:TEMP\chrome_snap2.png")

# Find confirm button (same red color in modal)
$confX = -1; $confY = -1
for ($y = 100; $y -lt $winH - 10; $y += 2) {
    for ($x = 10; $x -lt $winW - 10; $x += 2) {
        $px = $bmp2.GetPixel($x, $y)
        if ($px.R -gt 170 -and $px.G -lt 80 -and $px.B -lt 80) {
            $confX = $x; $confY = $y; break
        }
    }
    if ($confX -ge 0) { break }
}
$bmp2.Dispose()

if ($confX -lt 0) {
    Write-Output 'Confirm button not found - check chrome_snap2.png'
    exit 1
}

$absX2 = $winX + $confX; $absY2 = $winY + $confY
Write-Output "Confirm button at $absX2,$absY2 - clicking"
[Win32]::Click($absX2, $absY2)
Write-Output 'Token deleted!'
