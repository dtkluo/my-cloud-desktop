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

  # GDI+ Save 偶发 generic error（目标文件被上一轮 OCR/杀软短暂锁住，2026-10-27 实测）：
  # 先删旧文件再带 3 次重试保存，避免整轮白跑。
  if (Test-Path $path) { Remove-Item $path -Force -ErrorAction SilentlyContinue }

  $saveTries = 0

  while ($true) {

    try { $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); break }

    catch {

      $saveTries++

      if ($saveTries -ge 3) { $bmp.Dispose(); return $null }

      Start-Sleep -Milliseconds 500

    }

  }

  $bmp.Dispose()

  return @{ L = $r.L; T = $r.T; W = $w; H = $h }

}

# Shot2：带重试 + 兜底几何体的截图。
# 依据（2026-10-27 实测）：Flutter 窗口在切页/动画瞬间 GetWindowRect 会短暂返回 0，
# 甚至开机首启 12s+ 才就绪。传入了上次已知几何体 $fallback 时，rect 空的情况下
# 直接按 fallback 坐标抓屏（窗口位置不会瞬移，内容大概率正确）。
function Shot2([string]$path, $fallback) {

  for ($i = 0; $i -lt 5; $i++) {

    $g = Shot $path

    if ($g) { return $g }

    if ($fallback) {

      try {

        $bmp = New-Object System.Drawing.Bitmap($fallback.W, $fallback.H)

        $g2 = [System.Drawing.Graphics]::FromImage($bmp)

        $g2.CopyFromScreen($fallback.L, $fallback.T, 0, 0, $bmp.Size)

        $g2.Dispose()

        if (Test-Path $path) { Remove-Item $path -Force -ErrorAction SilentlyContinue }

        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)

        $bmp.Dispose()

        return $fallback

      } catch { return $null }

    }

    Start-Sleep -Milliseconds 800

  }

  return $null

}



# 登录页像素判定：600 基准 x[165,230] y[158,198] 区域出现黄色像素 = 登录页的
# 黄色「登录」tab（2026-10-27 bd-mc1/bd-mc3 截图实测对比：已登录主控页同位置
# 是白色背景）。中文 OCR 不可用（Windows OCR 引擎 en-US 读不了中文），所以
# 登录态判定全部走像素，不依赖 OCR 语言。
function Test-LoginTabPixel([string]$imgPath, $ggeo, [double]$sc) {

  $bmp = New-Object System.Drawing.Bitmap($ggeo.W, $ggeo.H)

  $g = [System.Drawing.Graphics]::FromImage($bmp)

  $g.DrawImage([System.Drawing.Image]::FromFile($imgPath), 0, 0)

  $g.Dispose()

  $hit = $false

  $px0 = [int](165 * $sc); $px1 = [int](230 * $sc)

  $py0 = [int](158 * $sc); $py1 = [int](198 * $sc)

  for ($yy = $py0; $yy -le $py1 -and -not $hit; $yy++) {

    for ($xx = $px0; $xx -le $px1; $xx++) {

      $c = $bmp.GetPixel($xx, $yy)

      if ($c.R -gt 200 -and $c.G -gt 140 -and $c.B -lt 120) { $hit = $true; break }

    }

  }

  $bmp.Dispose()

  return $hit

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

# 白跑一次开机。这里改成「轮询到 rect 有效为止」。2026-10-27 再教训：开机首启

# （workflow 装完立刻跑）rect 就绪花了 12 秒以上，12s 上限导致 bad-rect 误报

# 『启动异常』——放宽到 30s。

$shotPath = Join-Path $OutDir 'shot-home.png'

$geo = $null

$rectDeadline = (Get-Date).AddSeconds(30)

$rectTries = 0

while ((Get-Date) -lt $rectDeadline) {

  $rectTries++

  Start-Sleep -Milliseconds 800

  # 句柄追新（2026-10-27 二次实测）：开机双实例竞争时，开局抓到的 hwnd 可能属于
  # 随后死掉的瞬时实例（rect 恒 0），真正活下来的窗口晚 1~2 秒才出现。
  # 每 3 轮重新枚举一次，句柄变了就自动跟过去（死句柄不会被枚举到，天然淘汰）。
  if (($rectTries % 3) -eq 0) {

    $oldMain = [BdWin]::Main

    [void][BdWin]::FindMain()

    if ([BdWin]::Main -ne $oldMain -and [BdWin]::Main -ne [IntPtr]::Zero) {

      L ('window re-found: ' + $oldMain + ' -> ' + [BdWin]::Main)

      [BdWin]::Focus()

    }

  }

  $geo = Shot $shotPath

  if ($geo) { break }

  L ('rect not ready (try ' + $rectTries + ')')

}

if (-not $geo) {

  L 'BAD_WINDOW_RECT'

  (@{ ok = $false; state = 'bad-rect'; error = 'window rect stayed empty for 30s'; session = $sess } | ConvertTo-Json) |

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

  $ng = Shot2 $shotPath $geo

  if ($ng) { $geo = $ng } else { L 'popup: shot failed after click'; break }

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

    $lgeo = Shot2 $loginShot $geo

    $needLogin = $false

    $loggedIn = $false

    if ($lgeo) {

      $ll = OcrImage $loginShot

      foreach ($ln in $ll) { L ('  login-ocr| ' + $ln.Text) }

      # 像素判定登录态（中文 OCR 不可用，见 Test-LoginTabPixel 注释）
      $needLogin = Test-LoginTabPixel $loginShot $lgeo $sf

      $loggedIn = (-not $needLogin)

      if ($needLogin) { L 'login page detected (yellow tab pixel)' }

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

      $vgeo = Shot2 $loginShot $lgeo

      if ($vgeo) {

        $vl = OcrImage $loginShot

        foreach ($ln in $vl) { L ('  login-vfy| ' + $ln.Text) }

        # 验证：黄色「登录」tab 消失 = 登录成功（像素法，与判定同源）
        if (-not (Test-LoginTabPixel $loginShot $vgeo $sf)) { $script:LoginState = 'ok' }

      }

      L ('login state=' + $script:LoginState)

    } elseif ($loggedIn) {

      $script:LoginState = 'already'

      L 'already logged in, skip'

    } else {

      # 兜底：第一次 Shot 失败（窗口 rect 瞬时为空）。重试截图 + 顺手点一下
      # 可能存在的弹窗 ×（600 基准 (432,175)，无弹窗时是空白区域，无害），
      # 再用像素法分类。
      L 'WARN: login shot failed, retry with popup X fallback'

      [BdWin]::Click($ofx + [int](432 * $sf), $ofy + [int](175 * $sf))

      Start-Sleep -Milliseconds 1500

      $lgeo = Shot2 $loginShot $geo

      if ($lgeo) {

        $ll2 = OcrImage $loginShot

        foreach ($ln in $ll2) { L ('  login-ocr2| ' + $ln.Text) }

        if (Test-LoginTabPixel $loginShot $lgeo $sf) {

          L 'login page confirmed after popup dismiss, submitting account'

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

          $vgeo2 = Shot2 $loginShot $lgeo

          if ($vgeo2) {

            $vl2 = OcrImage $loginShot

            foreach ($ln in $vl2) { L ('  login-vfy2| ' + $ln.Text) }

            if (-not (Test-LoginTabPixel $loginShot $vgeo2 $sf)) { $script:LoginState = 'ok' }

          }

          L ('login state=' + $script:LoginState)

        } else {

          $script:LoginState = 'already'

          L 'already logged in (pixel, after fallback)'

        }

      } else {

        $script:LoginState = 'unknown'

      }

    }

    # 回「被控」tab 继续设备码采集

    [BdWin]::Click($ofx + [int](65 * $sf), $ofy + [int](560 * $sf))

    Start-Sleep -Milliseconds 1500

    $ng = Shot2 $shotPath $geo

    if ($ng) { $geo = $ng } else { L 'WARN: shot failed after switching back to 被控' }

  } catch { L ('login flow failed: ' + $_.Exception.Message); $script:LoginState = 'error' }

}





# ---------- 2.7 采集前强制回「被控」页 ----------

# 教训（2026-10-27）：agent 重跑时应用可能停在 设备/主控 页，OCR 会把设备列表里
# 别的设备码（如 441106985）误当成自己的。采集前无条件点一次「被控」tab。
# 被 tab 600 基准 (65,560)。

$tabScale = $geo.W / 600.0

[BdWin]::Click($geo.L + [int](65 * $tabScale), $geo.T + [int](560 * $tabScale))

Start-Sleep -Milliseconds 1500

$ng = Shot2 $shotPath $geo

if ($ng) { $geo = $ng } else { L 'WARN: shot failed after switching to 被控' }

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
      # OCR 常把小写 l 认成大写 I 或数字 1（2026-10-27 实测 lZfQZFjl -> IZfQZFjl）。
      # 折叠 I/1->l 后一致即视为验证通过（密码含 0/O 混淆同理折叠）。
      $fold = { param($s) $s -replace '[I1]', 'l' -replace 'O', '0' }
      if ($ocrPwd -eq $FixedPassword) {
        $password = $FixedPassword
        L 'fixed password verified'
      } elseif ($ocrPwd -and (& $fold $ocrPwd) -eq (& $fold $FixedPassword)) {
        $password = $FixedPassword
        L 'fixed password verified (ocr I/1/O fold)'
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



# ---------- 3.5 自动重绑账号（设备码每次开机都会变） ----------

# 重大发现（2026-10-27）：BilldDesk 每次开机都是全新安装，设备身份重新生成，
# 设备码会变（679640907 -> 024063379），旧绑定必然失效。所以每次开机在
# 登录 + 固定密码之后，检查账号「设备」列表里有没有当前设备码，没有就自动
# 「添加设备」绑一次（备注 cloud-desktop）。密码恒定 ⇒ 绑定立即在线。
# 坐标 600 基准（v0.621 于 1024x768 实测）：设备 tab(299,560)、添加设备(229,62)、
# 备注(344,278) 设备代码(344,333) 连接密码(344,388) 确定(300,443)。

$script:BindState = ''

if ($devCode -and $password -and $LoginUser -and $script:LoginState -ne 'error' -and $script:LoginState -ne 'unknown') {

  try {

    Add-Type -AssemblyName System.Windows.Forms

    $bindScale = $geo.W / 600.0

    # 设备列表不显示设备码（只有 备注/主机名/IP/版本），所以绑定判定不能用码匹配，
    # 改用主机名：本机条目 = 「cloud-desktop + $env:COMPUTERNAME」同行出现
    # （2026-10-27 实测 OCR 能稳定读出 runnervmdaln5）。
    $hostName = $env:COMPUTERNAME.ToLower()

    # 打开「设备」页
    [BdWin]::Click($geo.L + [int](299 * $bindScale), $geo.T + [int](560 * $bindScale))

    Start-Sleep -Milliseconds 2000

    $bindShot = Join-Path $OutDir 'shot-bind.png'

    $bgeo = Shot2 $bindShot $geo

    $already = $false

    $staleRows = @()

    if ($bgeo) {

      $bl = OcrImage $bindShot

      foreach ($ln in $bl) { L ('  bind-ocr| ' + $ln.Text) }

      $allText = (($bl | ForEach-Object { $_.Text }) -join ' ').ToLower()

      # 已绑判定两种形态（2026-10-27 三次实测）：
      #  a) 手动添加：条目备注 cloud-desktop + 本机主机名同现
      #  b) 登录后自动注册：条目名称直接显示设备码（OCR 去非数字后与 $devCode 相等）
      $devDigits = ($devCode -replace '\D', '')

      $codeHit = $false

      foreach ($ln in $bl) {

        if ($devDigits -and (($ln.Text -replace '\D', '') -eq $devDigits)) { $codeHit = $true; break }

      }

      if ($codeHit) {

        $already = $true

        L 'bind: current device already in account list (device-code match)'

      } elseif ($allText.Contains($hostName) -and $allText.Contains('cloud-desktop')) {

        $already = $true

        L 'bind: current device already in account list (hostname match)'

      } else {

        # 收集历史失效的 cloud-desktop 条目（同行无本机主机名），先清掉再重绑，
        # 避免每次开机堆一条死条目。行文本 y + 15 即该行「删除」按钮（600 基准 x=543）。
        foreach ($ln in $bl) {

          if ($ln.Text -match 'cloud-desktop' -and ($ln.Text.ToLower() -notmatch [regex]::Escape($hostName))) {

            $staleRows += [double]$ln.Y

          }

        }

      }

    }

    if (-not $bgeo) {

      # 连截图都拿不到（窗口被遮挡/最小化）：不盲操作，如实上报
      $script:BindState = 'no-shot'

      L 'bind: skip, no shot available'

    } else {

      foreach ($ry in $staleRows) {

        L ('bind: deleting stale cloud-desktop row at y=' + [int]$ry)

        [BdWin]::Click($geo.L + [int](543 * $bindScale), $geo.T + [int](($ry + 15.0) * $bindScale))

        Start-Sleep -Milliseconds 1500

        # 确认删除对话框（600 基准）：确定 (368,351)
        [BdWin]::Click($geo.L + [int](368 * $bindScale), $geo.T + [int](351 * $bindScale))

        Start-Sleep -Milliseconds 2500

      }

      if ($already) {

        $script:BindState = 'already'

      } else {

        # 清理后复查一次（可能清完才发现本机条目本来就在）
        if ($staleRows.Count -gt 0) {

          $bg2 = Shot2 $bindShot $geo

          if ($bg2) {

            $bl2 = OcrImage $bindShot

            foreach ($ln in $bl2) { L ('  bind-ocr2| ' + $ln.Text) }

            $allText2 = (($bl2 | ForEach-Object { $_.Text }) -join ' ').ToLower()

            $codeHit2 = $false

            foreach ($ln in $bl2) {

              if ($devDigits -and (($ln.Text -replace '\D', '') -eq $devDigits)) { $codeHit2 = $true; break }

            }

            if ($codeHit2 -or ($allText2.Contains($hostName) -and $allText2.Contains('cloud-desktop'))) { $already = $true }

          }

        }

      }

      if ($already) {

        $script:BindState = 'already'

        L 'bind: current device already in account list'

      } else {

        L 'bind: adding current device to account'

        [BdWin]::Click($geo.L + [int](229 * $bindScale), $geo.T + [int](62 * $bindScale))

        Start-Sleep -Milliseconds 1500

        [BdWin]::Click($geo.L + [int](344 * $bindScale), $geo.T + [int](278 * $bindScale))

        Start-Sleep -Milliseconds 500

        [System.Windows.Forms.SendKeys]::SendWait('cloud-desktop')

        Start-Sleep -Milliseconds 400

        [BdWin]::Click($geo.L + [int](344 * $bindScale), $geo.T + [int](333 * $bindScale))

        Start-Sleep -Milliseconds 500

        [System.Windows.Forms.SendKeys]::SendWait($devCode)

        Start-Sleep -Milliseconds 400

        [BdWin]::Click($geo.L + [int](344 * $bindScale), $geo.T + [int](388 * $bindScale))

        Start-Sleep -Milliseconds 500

        [System.Windows.Forms.SendKeys]::SendWait($password)

        Start-Sleep -Milliseconds 400

        [BdWin]::Click($geo.L + [int](300 * $bindScale), $geo.T + [int](443 * $bindScale))

        Start-Sleep -Milliseconds 3000

        # 提交后验证：重新截「设备」页 OCR，看本机主机名是否出现
        $vbindShot = Join-Path $OutDir 'shot-bind2.png'

        $vbgeo = Shot2 $vbindShot $geo

        $script:BindState = 'unverified'

        if ($vbgeo) {

          $vbl = OcrImage $vbindShot

          foreach ($ln in $vbl) { L ('  bind-vfy| ' + $ln.Text) }

          $allTextV = (($vbl | ForEach-Object { $_.Text }) -join ' ').ToLower()

          $codeHitV = $false

          foreach ($ln in $vbl) {

            if ($devDigits -and (($ln.Text -replace '\D', '') -eq $devDigits)) { $codeHitV = $true; break }

          }

          if ($codeHitV -or ($allTextV.Contains($hostName) -and $allTextV.Contains('cloud-desktop'))) { $script:BindState = 'ok' }

        }

        L ('bind: verify state=' + $script:BindState)

      }

    }

    # 回「被控」页
    [BdWin]::Click($geo.L + [int](65 * $bindScale), $geo.T + [int](560 * $bindScale))

    Start-Sleep -Milliseconds 1200

  } catch { L ('bind flow failed: ' + $_.Exception.Message); $script:BindState = 'error' }

} elseif ($devCode -and $password) {

  $script:BindState = 'skip-no-login'

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

  bind      = if ($LoginUser) { if ($script:BindState) { $script:BindState } else { 'skipped' } } else { '' }

  window    = if ($geo) { ($geo.W.ToString() + 'x' + $geo.H.ToString()) } else { '' }

  session   = $sess

  updated_at = (Get-Date).ToUniversalTime().ToString('o')

  error     = ''

}

($result | ConvertTo-Json -Depth 4) | Out-File (Join-Path $OutDir 'billddesk.json') -Encoding utf8

L ('wrote billddesk.json ok=' + $result.ok + ' state=' + $result.state)

L 'DONE'

