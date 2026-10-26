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

  [string]$FallbackPassword = '',

  [string]$FixedPassword = '',

  [string]$LoginUser = '',

  [string]$LoginPass = ''

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



# ---------- 2.5 关闭「消息中心」弹窗 ----------

# 全新安装首次启动会弹「消息中心」对话框，恰好盖住设备码（2026-10-26 实测，

# OCR 只能读到弹窗文字，整轮白跑）。弹窗特征：纯白(255)背景 + 右上角 × 图标，

# × 灰度 lum<110（半透明遮罩是均匀的 127 灰，不会命中），600 基准下在

# x[430,441] y[203,213]。窄扫描窗口 x[0.70W,0.75W] y[0.32H,0.38H] 只认

# × 形状的小簇（<=24px），命中才点击，无弹窗时该区域是白色卡片不会误点。

$popTries = 0

while ($popTries -lt 3) {

  $popTries++

  $px0 = [int]($geo.W * 0.70); $px1 = [int]($geo.W * 0.75)

  $py0 = [int]($geo.H * 0.32); $py1 = [int]($geo.H * 0.38)

  $bmp = New-Object System.Drawing.Bitmap($geo.W, $geo.H)

  $g = [System.Drawing.Graphics]::FromImage($bmp)

  $g.DrawImage([System.Drawing.Image]::FromFile($shotPath), 0, 0)

  $g.Dispose()

  $xs = @(); $ys = @()

  for ($y = $py0; $y -le $py1; $y++) {

    for ($x = $px0; $x -le $px1; $x++) {

      $c = $bmp.GetPixel($x, $y)

      $lum = 0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B

      if ($lum -lt 110) { $xs += $x; $ys += $y }

    }

  }

  $bmp.Dispose()

  if ($xs.Count -lt 6) { L ('popup: none (try ' + $popTries + ' pts=' + $xs.Count + ')'); break }

  $minX = ($xs | Measure-Object -Minimum).Minimum

  $maxX = ($xs | Measure-Object -Maximum).Maximum

  $minY = ($ys | Measure-Object -Minimum).Minimum

  $maxY = ($ys | Measure-Object -Maximum).Maximum

  if (($maxX - $minX) -gt 24 -or ($maxY - $minY) -gt 24) {

    L ('popup: dark blob too big w=' + ($maxX - $minX) + ' h=' + ($maxY - $minY) + ', skip')

    break

  }

  $ax = $geo.L + [int](($minX + $maxX) / 2)

  $ay = $geo.T + [int](($minY + $maxY) / 2)

  L ('popup: cross at ' + [int](($minX + $maxX) / 2) + ',' + [int](($minY + $maxY) / 2) + ' -> click ' + $ax + ',' + $ay)

  [BdWin]::Click($ax, $ay)

  Start-Sleep -Milliseconds 1200

  $geo = Shot $shotPath

  if (-not $geo) { L 'popup: shot failed after click'; break }

}



# ---------- 2.6 主控端自动登录（-LoginUser/-LoginPass 传入时执行） ----------

# 需求（2026-10-27）：本机 BilldDesk 登录 dtka1 账号后，主人手机主控端登录同一

# 账号即可在「设备」页直接远程，免设备码/连接密码。绑定关系持久存在服务端账号

# 下、连接密码已被 bootstrap 固定为恒定值，所以每次开机只需确保客户端处于登录态。

# 流程：点「主控」tab -> OCR 判登录态 -> 未登录则填账号密码点「确定」-> 回「被控」tab。

# 坐标为 600 基准（v0.621 于 1024x768 实测）：主控(185,560) 被控(65,560)、

# 用户名框(300,216) 密码框(300,271) 确定(300,326)。

# 判定依据：登录页独有「用户名/注册」字样；已登录主控页独有「设备代码」字样。

$script:LoginState = ''

if ($LoginUser -and $LoginPass) {

  try {

    Add-Type -AssemblyName System.Windows.Forms

    $sf = $geo.W / 600.0

    $ofx = $geo.L; $ofy = $geo.T

    [BdWin]::Click($ofx + [int](185 * $sf), $ofy + [int](560 * $sf))

    Start-Sleep -Milliseconds 1500

    $loginShot = Join-Path $OutDir 'shot-login.png'

    $lgeo = Shot $loginShot

    $needLogin = $false

    $loggedIn = $false

    if ($lgeo) {

      $ll = OcrImage $loginShot

      foreach ($ln in $ll) { L ('  login-ocr| ' + $ln.Text) }

      foreach ($ln in $ll) {

        if ($ln.Text -match '设备代码') { $loggedIn = $true; break }

      }

      if (-not $loggedIn) {

        foreach ($ln in $ll) {

          if ($ln.Text -match '用户名|注\s*册') { $needLogin = $true; break }

        }

      }

    }

    if ($needLogin) {

      L 'login page detected, submitting account'

      [BdWin]::Click($ofx + [int](300 * $sf), $ofy + [int](216 * $sf))

      Start-Sleep -Milliseconds 600

      [System.Windows.Forms.SendKeys]::SendWait('^a')

      Start-Sleep -Milliseconds 200

      [System.Windows.Forms.SendKeys]::SendWait($LoginUser)

      Start-Sleep -Milliseconds 500

      [BdWin]::Click($ofx + [int](300 * $sf), $ofy + [int](271 * $sf))

      Start-Sleep -Milliseconds 600

      [System.Windows.Forms.SendKeys]::SendWait('^a')

      Start-Sleep -Milliseconds 200

      [System.Windows.Forms.SendKeys]::SendWait($LoginPass)

      Start-Sleep -Milliseconds 500

      [BdWin]::Click($ofx + [int](300 * $sf), $ofy + [int](326 * $sf))

      Start-Sleep -Milliseconds 3000

      $script:LoginState = 'submitted'

      $vgeo = Shot $loginShot

      if ($vgeo) {

        $vl = OcrImage $loginShot

        foreach ($ln in $vl) { L ('  login-vfy| ' + $ln.Text) }

        foreach ($ln in $vl) {

          if ($ln.Text -match '设备代码') { $script:LoginState = 'ok'; break }

        }

      }

      L ('login state=' + $script:LoginState)

    } elseif ($loggedIn) {

      $script:LoginState = 'already'

      L 'already logged in, skip'

    } else {

      $script:LoginState = 'unknown'

      L 'WARN: could not classify login page'

    }

    # 回「被控」tab 继续设备码采集

    [BdWin]::Click($ofx + [int](65 * $sf), $ofy + [int](560 * $sf))

    Start-Sleep -Milliseconds 1500

    $geo = Shot $shotPath

    if (-not $geo) { L 'WARN: shot failed after switching back to 被控' }

  } catch { L ('login flow failed: ' + $_.Exception.Message); $script:LoginState = 'error' }

}





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



# ---------- 2.5 固定连接密码（-FixedPassword 传入时执行） ----------

# 背景：BilldDesk 的默认密码是机器指纹派生的固定值（GitHub runner 镜像 MachineGuid

# 相同 ⇒ 每台新 VM 都是同一个初始密码），且开机约 15-25 分钟后会自动轮换成随机值，

# 导致状态文件里推的密码很快失效（2026-10-26 实测）。对策：开机就用「铅笔」对话框

# 把密码改成 bootstrap 生成的随机 8 位，此后不再轮换，状态文件里的值始终有效。

if ($FixedPassword -and $devCode) {

  Add-Type -AssemblyName System.Windows.Forms

  $scaleF = $geo.H / 600.0

  L ('set fixed password len=' + $FixedPassword.Length)

  # 铅笔图标：与眼睛同行（devY+105 中心），x≈545（600 基准）

  [BdWin]::Click($geo.L + [int](545 * $scaleF), $geo.T + [int](($devY + 105.0) * $scaleF))

  Start-Sleep -Milliseconds 1800

  # 新密码输入框（对话框内固定位置）

  [BdWin]::Click($geo.L + [int](338 * $scaleF), $geo.T + [int](360 * $scaleF))

  Start-Sleep -Milliseconds 700

  [System.Windows.Forms.SendKeys]::SendWait('^a')

  Start-Sleep -Milliseconds 250

  [System.Windows.Forms.SendKeys]::SendWait($FixedPassword)

  Start-Sleep -Milliseconds 600

  # 确定按钮

  [BdWin]::Click($geo.L + [int](307 * $scaleF), $geo.T + [int](415 * $scaleF))

  Start-Sleep -Milliseconds 2500

  L 'fixed password submitted'

}



# ---------- 3. 像素定位眼睛图标并点击 ----------

$password = ''

if ($devCode -and $devY -ge 0) {

  # 密码行图标相对设备码行的偏移：600 基准下眼睛图标在 devY+95 ~ +116

  # （2026-10-26 实测 devY=192、图标 y[287,308] 中心 297；旧版扫描带 ±12

  #  只罩住图标上沿、点击 y 又固定取带中心 278，偏 19px 点到空白，密码永远出不来）

  $scale = $geo.H / 600.0

  $y0 = [int]([Math]::Max(0, $devY + (55.0 * $scale)))

  $y1 = [int]([Math]::Min($geo.H - 1, $devY + (125.0 * $scale)))

  $x0 = [int]($geo.W * 0.75)

  $x1 = [int]($geo.W * 0.99)

  L ("scan eye region x[$x0,$x1) y[$y0,$y1)")



  $bmp = New-Object System.Drawing.Bitmap($geo.W, $geo.H)

  $g = [System.Drawing.Graphics]::FromImage($bmp)

  $g.DrawImage([System.Drawing.Image]::FromFile($shotPath), 0, 0)

  $g.Dispose()



  $cols = @{}

  $rowsY = @{}

  for ($y = $y0; $y -le $y1; $y++) {

    for ($x = $x0; $x -le $x1; $x++) {

      $c = $bmp.GetPixel($x, $y)

      $lum = 0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B

      if ($lum -lt 170) {

        if ($cols.ContainsKey($x)) { $cols[$x] = $cols[$x] + 1 } else { $cols[$x] = 1 }

        if ($rowsY.ContainsKey($x)) { $rowsY[$x] = @($rowsY[$x]) + $y } else { $rowsY[$x] = @($y) }

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

    # 点击 y 用眼睛簇实际暗像素的 y 中心，而不是扫描带中心

    $eyeYs = @()

    foreach ($cx0 in $eye) {

      if ($rowsY.ContainsKey($cx0)) { $eyeYs += $rowsY[$cx0] }

    }

    if ($eyeYs.Count -gt 0) {

      $minY = ($eyeYs | Measure-Object -Minimum).Minimum

      $maxY = ($eyeYs | Measure-Object -Maximum).Maximum

      $ey = $geo.T + [int](($minY + $maxY) / 2)

    } else {

      $ey = $geo.T + [int](($y0 + $y1) / 2)

    }

    L ("click eye at $ex,$ey")

    [BdWin]::Click($ex, $ey)

    Start-Sleep -Milliseconds 2000



    $pwdShot = Join-Path $OutDir 'shot-pwd.png'

    [void](Shot $pwdShot)

    $l2 = OcrImage $pwdShot

    foreach ($ln in $l2) { L ('  ocr2| ' + $ln.Text) }
    # 只在「密码行」的 OCR 行里找密码：窗口内 y ∈ [devY+55, devY+130]
    # （设备码行在 devY，密码行在其下方；顶部横幅/版本号都在带外）
    $ocrPwd = ''
    foreach ($ln in $l2) {
      if ($ln.Y -lt ($devY + 55) -or $ln.Y -gt ($devY + 130)) { continue }
      $t = ($ln.Text -replace '[^A-Za-z0-9]', '')
      if ($t.Length -ge 5 -and $t.Length -le 16) { $ocrPwd = $t; break }
    }
    L ('password(from ocr)=' + $ocrPwd)
    if ($FixedPassword) {
      if ($ocrPwd -eq $FixedPassword) {
        $password = $FixedPassword
        L 'fixed password verified'
      } elseif ($ocrPwd) {
        # 固定密码设置失败（输入被拒/提交失败）：OCR 读到的真实密码仍可用，如实上报
        $password = $ocrPwd
        L ('fixed password MISMATCH, reporting real value len=' + $ocrPwd.Length)
      } else {
        $password = $FixedPassword
        L 'password unverifiable by ocr, keep fixed value'
      }
    } else {
      $password = $ocrPwd
    }

    # 点回去重新掩码

    [BdWin]::Click($ex, $ey)

    Start-Sleep -Milliseconds 400

  }

}



if (-not $password -and $FixedPassword) {

  # 我们自己设置的密码就是权威值（OCR 偶尔读不到密码行，不能退回旧默认值）

  $password = $FixedPassword

  L ('password fallback=fixed')

} elseif (-not $password -and $FallbackPassword) {

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

  account   = $LoginUser

  login     = if ($LoginUser) { if ($script:LoginState) { $script:LoginState } else { 'skipped' } } else { '' }

  window    = ($geo.W.ToString() + 'x' + $geo.H.ToString())

  session   = $sess

  updated_at = (Get-Date).ToUniversalTime().ToString('o')

  error     = ''

}

($result | ConvertTo-Json -Depth 4) | Out-File (Join-Path $OutDir 'billddesk.json') -Encoding utf8

L ('wrote billddesk.json ok=' + $result.ok + ' state=' + $result.state)

L 'DONE'

