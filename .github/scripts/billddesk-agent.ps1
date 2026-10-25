#requires -Version 5.1
<#
  BilldDesk 会话内代理（必须在交互会话里跑，通常是 runneradmin / session 2）

  职责：等主窗口出现 -> 截图 -> OCR 取设备码 -> 像素定位“眼睛”图标并点击
        -> 再截图 OCR 取连接密码 -> 写 billddesk.json

  为什么要在交互会话里跑：BilldDesk 是 Flutter 桌面程序，主窗口
  (cls=FLUTTER_RUNNER_WIN32_WINDOW) 只存在于它自己所属的窗口站/桌面，
  session 0 的服务进程 EnumWindows 看不见，CopyFromScreen 也只能拿到黑屏。
#>
param(
  [string]$OutDir = 'C:\billddesk-auto',
  [int]$WaitWindowSec = 90,
  [string]$FallbackPassword = ''
)

$ErrorActionPreference = 'Continue'
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
$logPath = Join-Path $OutDir 'agent.log'
function L($m) {
  $line = (Get-Date -Format 'HH:mm:ss') + ' ' + $m
  Add-Content -Path $logPath -Value $line -Encoding UTF8
}
Set-Content -Path $logPath -Value '' -Encoding UTF8

$sess = (Get-Process -Id $PID).SessionId
L ("agent start sess=$sess user=" + (whoami))

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class BdWin {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RC r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern IntPtr SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr p);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [StructLayout(LayoutKind.Sequential)] public struct RC { public int L, T, R, B; }

  public static IntPtr Main = IntPtr.Zero;
  public static string MainTitle = "";

  public static bool FindMain() {
    Main = IntPtr.Zero; MainTitle = "";
    int bestArea = 0;
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      StringBuilder cn = new StringBuilder(256); GetClassNameW(h, cn, 256);
      if (cn.ToString() == "FLUTTER_RUNNER_WIN32_WINDOW") {
        StringBuilder sb = new StringBuilder(512); GetWindowTextW(h, sb, 512);
        string t = sb.ToString();
        if (t.IndexOf("billd", StringComparison.OrdinalIgnoreCase) >= 0) {
          RC r; GetWindowRect(h, out r);
          int a = (r.R - r.L) * (r.B - r.T);
          if (a > bestArea) { bestArea = a; Main = h; MainTitle = t; }
        }
      }
      return true;
    }, IntPtr.Zero);
    return Main != IntPtr.Zero;
  }

  public static void Focus() {
    if (Main == IntPtr.Zero) return;
    ShowWindow(Main, 5);
    SetWindowPos(Main, (IntPtr)(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0008);
    SetWindowPos(Main, (IntPtr)(-2), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0004);
    uint tid = GetWindowThreadProcessId(Main, IntPtr.Zero);
    uint cur = GetCurrentThreadId();
    AttachThreadInput(cur, tid, true);
    BringWindowToTop(Main);
    SetForegroundWindow(Main);
    AttachThreadInput(cur, tid, false);
  }

  public static void Click(int x, int y) {
    SetCursorPos(x, y);
    System.Threading.Thread.Sleep(180);
    mouse_event(0x0002, 0, 0, 0, IntPtr.Zero);
    System.Threading.Thread.Sleep(40);
    mouse_event(0x0004, 0, 0, 0, IntPtr.Zero);
  }
}
"@

# ---------- OCR ----------
$script:OcrOk = $false
try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
  function Await($t, $rt) {
    $m = $asTask.MakeGenericMethod($rt)
    $nt = $m.Invoke($null, @($t))
    [void]$nt.Wait(-1)
    $nt.Result
  }
  [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = 'WindowsRuntime'] | Out-Null
  [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = 'WindowsRuntime'] | Out-Null
  [Windows.Storage.StorageFile, Windows.Foundation, ContentType = 'WindowsRuntime'] | Out-Null
  $script:OcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
  if (-not $script:OcrEngine) {
    $ls = [Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages
    if ($ls.Count -gt 0) { $script:OcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($ls[0]) }
  }
  if ($script:OcrEngine) {
    $script:OcrOk = $true
    L ('ocr engine=' + $script:OcrEngine.RecognizerLanguage.LanguageTag)
  } else { L 'ocr engine unavailable' }
} catch { L ('ocr init failed: ' + $_.Exception.Message) }

function OcrImage([string]$path) {
  if (-not $script:OcrOk) { return @() }
  $f  = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
  $st = Await ($f.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
  $dec = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($st)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $sb = Await ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
  $res = Await ($script:OcrEngine.RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])
  $out = @()
  foreach ($ln in $res.Lines) {
    $x = 0.0; $y = 0.0; $ww = 0.0
    $words = @($ln.Words)
    if ($words.Count -gt 0) {
      $x  = $words[0].BoundingRect.X
      $y  = $words[0].BoundingRect.Y
      $last = $words[$words.Count - 1].BoundingRect
      $ww = ($last.X + $last.Width) - $x
    }
    $out += [pscustomobject]@{ Text = $ln.Text; X = $x; Y = $y; W = $ww }
  }
  return $out
}

function Shot([string]$path) {
  $r = New-Object BdWin+RC
  [void][BdWin]::GetWindowRect([BdWin]::Main, [ref]$r)
  $w = $r.R - $r.L; $h = $r.B - $r.T
  if ($w -le 10 -or $h -le 10) { return $null }
  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
  $g.Dispose()
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  return @{ L = $r.L; T = $r.T; W = $w; H = $h }
}

# ---------- 1. 等窗口 ----------
$deadline = (Get-Date).AddSeconds($WaitWindowSec)
$found = $false
$launched = $false
$sw = [Diagnostics.Stopwatch]::StartNew()
while ((Get-Date) -lt $deadline) {
  if ([BdWin]::FindMain()) { $found = $true; break }
  # 8 秒还没窗口就主动拉一次 GUI（Service 有时不会立刻拉起）
  if (-not $launched -and $sw.Elapsed.TotalSeconds -ge 8) {
    $launched = $true
    try {
      $exe = 'C:\Program Files\BilldDesk\BilldDesk.exe'
      if (Test-Path $exe) {
        Start-Process -FilePath $exe -WorkingDirectory 'C:\Program Files\BilldDesk' -ErrorAction Stop
        L 'launched BilldDesk.exe directly'
      }
    } catch { L ('launch failed: ' + $_.Exception.Message) }
  }
  Start-Sleep -Seconds 2
}
if (-not $found) {
  L 'NO_MAIN_WINDOW'
  (@{ ok = $false; state = 'no-window'; error = 'main window not found'; session = $sess } | ConvertTo-Json) |
    Out-File (Join-Path $OutDir 'billddesk.json') -Encoding utf8
  L 'DONE'
  exit 1
}
L ('window=' + [BdWin]::Main + ' title=' + [BdWin]::MainTitle)
[BdWin]::Focus()

# ---------- 2. 截图 + OCR 设备码 ----------
# 冷启动竞态（2026-10-25 实测）：BillDesk 刚被拉起时 hwnd 和标题都对了，
# 但 GetWindowRect 仍返回 0x0 —— Flutter 是「先建窗口壳、后定尺寸」。
# 实测 22:26:42 找到窗口、22:26:44 量到的宽高还是 0，于是整轮直接判 bad-rect 退出，
# 白跑一次开机。这里改成「轮询到 rect 有效为止」，最多等 12 秒。
$shotPath = Join-Path $OutDir 'shot-home.png'
$geo = $null
$rectDeadline = (Get-Date).AddSeconds(12)
$rectTries = 0
while ((Get-Date) -lt $rectDeadline) {
  $rectTries++
  Start-Sleep -Milliseconds 800
  $geo = Shot $shotPath
  if ($geo) { break }
  L ('rect not ready (try ' + $rectTries + ')')
}
if (-not $geo) {
  L 'BAD_WINDOW_RECT'
  (@{ ok = $false; state = 'bad-rect'; error = 'window rect stayed empty for 12s'; session = $sess } | ConvertTo-Json) |
    Out-File (Join-Path $OutDir 'billddesk.json') -Encoding utf8
  L 'DONE'
  exit 2
}
L ('rect=' + $geo.W + 'x' + $geo.H + ' after ' + $rectTries + ' tries')
L ("geo={0}x{1}+{2}+{3}" -f $geo.W, $geo.H, $geo.L, $geo.T)

$lines = OcrImage $shotPath
foreach ($ln in $lines) { L ('  ocr| ' + $ln.Text) }

$devCode = ''
$devY = -1.0
foreach ($ln in $lines) {
  if ($ln.Text -match '(\d{3})\s*(\d{3})\s*(\d{3})') {
    $devCode = $Matches[1] + $Matches[2] + $Matches[3]
    $devY = [double]$ln.Y
    break
  }
}
if (-not $devCode) {
  foreach ($ln in $lines) {
    $digits = ($ln.Text -replace '[^0-9]', '')
    if ($digits.Length -eq 9) { $devCode = $digits; $devY = [double]$ln.Y; break }
  }
}
L ("devCode=" + $devCode + " devY=" + $devY)

# ---------- 3. 像素定位眼睛图标并点击 ----------
$password = ''
if ($devCode -and $devY -ge 0) {
  # 密码行相对设备码行的偏移（600 基准下约 +86px）
  $scale = $geo.H / 600.0
  $pwdY = $devY + (86.0 * $scale)
  $y0 = [int]([Math]::Max(0, $pwdY - 12 * $scale))
  $y1 = [int]([Math]::Min($geo.H - 1, $pwdY + 12 * $scale))
  $x0 = [int]($geo.W * 0.75)
  $x1 = [int]($geo.W * 0.99)
  L ("scan eye region x[$x0,$x1) y[$y0,$y1)")

  $bmp = New-Object System.Drawing.Bitmap($geo.W, $geo.H)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.DrawImage([System.Drawing.Image]::FromFile($shotPath), 0, 0)
  $g.Dispose()

  $cols = @{}
  for ($y = $y0; $y -le $y1; $y++) {
    for ($x = $x0; $x -le $x1; $x++) {
      $c = $bmp.GetPixel($x, $y)
      $lum = 0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B
      if ($lum -lt 170) {
        if ($cols.ContainsKey($x)) { $cols[$x] = $cols[$x] + 1 } else { $cols[$x] = 1 }
      }
    }
  }
  $bmp.Dispose()

  $xs = @($cols.Keys | Sort-Object)
  L ('dark cols=' + $xs.Count)
  if ($xs.Count -gt 0) {
    $clusters = @(); $cur = @($xs[0])
    for ($i = 1; $i -lt $xs.Count; $i++) {
      if ($xs[$i] - $xs[$i - 1] -le 6) { $cur += $xs[$i] } else { $clusters += , $cur; $cur = @($xs[$i]) }
    }
    $clusters += , $cur
    L ('clusters=' + $clusters.Count)
    foreach ($cl in $clusters) { L ('  cluster ' + $cl[0] + '..' + $cl[-1]) }

    $eye = $clusters[0]   # 最左簇 = 眼睛
    $ex = $geo.L + [int](($eye[0] + $eye[-1]) / 2)
    $ey = $geo.T + [int](($y0 + $y1) / 2)
    L ("click eye at $ex,$ey")
    [BdWin]::Click($ex, $ey)
    Start-Sleep -Milliseconds 1600

    $pwdShot = Join-Path $OutDir 'shot-pwd.png'
    [void](Shot $pwdShot)
    $l2 = OcrImage $pwdShot
    foreach ($ln in $l2) { L ('  ocr2| ' + $ln.Text) }
    foreach ($ln in $l2) {
      if ($ln.Text -match '(?<![A-Za-z0-9])([A-Za-z0-9]{8})(?![A-Za-z0-9])') {
        $password = $Matches[1]
        break
      }
    }
    if (-not $password) {
      foreach ($ln in $l2) {
        $t = ($ln.Text -replace '[^A-Za-z0-9]', '')
        if ($t.Length -eq 8 -and $t -notmatch '^\d+$') { $password = $t; break }
      }
    }
    L ('password(from ocr)=' + $password)
    # 点回去重新掩码
    [BdWin]::Click($ex, $ey)
    Start-Sleep -Milliseconds 400
  }
}

if (-not $password -and $FallbackPassword) {
  $password = $FallbackPassword
  L ('password fallback=' + $password)
}

# ---------- 4. 落盘 ----------
$result = [ordered]@{
  ok        = [bool]($devCode -and $password)
  state     = if ($devCode -and $password) { 'ready' } elseif ($devCode) { 'no-password' } else { 'no-device-code' }
  device_code = if ($devCode) { ($devCode.Substring(0,3) + ' ' + $devCode.Substring(3,3) + ' ' + $devCode.Substring(6,3)) } else { '' }
  device_uuid = $devCode
  password  = $password
  window    = ($geo.W.ToString() + 'x' + $geo.H.ToString())
  session   = $sess
  updated_at = (Get-Date).ToUniversalTime().ToString('o')
  error     = ''
}
($result | ConvertTo-Json -Depth 4) | Out-File (Join-Path $OutDir 'billddesk.json') -Encoding utf8
L ('wrote billddesk.json ok=' + $result.ok + ' state=' + $result.state)
L 'DONE'
