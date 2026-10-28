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

  , [switch]$SkipFixedPassword

  , [string]$DeviceRemark = ''

)



$ErrorActionPreference = 'Continue'

$script:PwdChangeSkipped = $false


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

# Edge 欢迎弹窗防护（2026-10-27 晚实测）：这台 VM 每次开机 Edge 都会弹欢迎页抢焦点，
# 盖在 BilldDesk 上 ⇒ Shot 按 rect 抓屏抓到的是 Edge 内容，OCR 全是广告文案，
# 眼睛/铅笔/绑定点击全部落在 Edge 上静默空转（固定密码没设、绑定没提交，
# 用户端表现为「密码错误」）。开机先杀 Edge，一劳永逸。
try { Stop-Process -Name msedge -Force -ErrorAction SilentlyContinue } catch { }

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

      # 遮挡/切页失败防护（2026-10-27 晚实测）：点主控 tab 若落在遮挡物上，
      # 截图其实还是被控页——被控页同样没有黄色 tab，会被误判「已登录」。
      # 被控页独有特征 = 9 位设备码（3x3 分组或纯 9 位数字）；检测到就视为
      # 「判定无效」，Focus 后重试点主控再判一轮。
      $ctrlPageSeen = $false

      foreach ($ln in $ll) {

        if ($ln.Text -match '(\d{3})\s*(\d{3})\s*(\d{3})') { $ctrlPageSeen = $true; break }

      }

      if (-not $needLogin -and $ctrlPageSeen) {

        L 'WARN: still on 被控 page (main-control click lost?), re-focusing and retrying'

        [BdWin]::Focus()

        Start-Sleep -Milliseconds 1000

        [BdWin]::Click($ofx + [int](185 * $sf), $ofy + [int](560 * $sf))

        Start-Sleep -Milliseconds 1500

        $lgeo = Shot2 $loginShot $lgeo

        if ($lgeo) {

          $ll = OcrImage $loginShot

          foreach ($ln in $ll) { L ('  login-ocr-retry| ' + $ln.Text) }

          $needLogin = Test-LoginTabPixel $loginShot $lgeo $sf

        }

      }

      $loggedIn = (-not $needLogin)

      if ($needLogin) { L 'login page detected (yellow tab pixel)' }

    }

    if ($needLogin) {

      L 'login page detected, submitting account'

      [BdWin]::Click($ofx + [int](300 * $sf), $ofy + [int](216 * $sf))

      Start-Sleep -Milliseconds 600

      [System.Windows.Forms.SendKeys]::SendWait('{END}{BACKSPACE 40}')

      Start-Sleep -Milliseconds 200

      [System.Windows.Forms.SendKeys]::SendWait($LoginUser)

      Start-Sleep -Milliseconds 500

      [BdWin]::Click($ofx + [int](300 * $sf), $ofy + [int](271 * $sf))

      Start-Sleep -Milliseconds 600

      [System.Windows.Forms.SendKeys]::SendWait('{END}{BACKSPACE 40}')

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

          [System.Windows.Forms.SendKeys]::SendWait('{END}{BACKSPACE 40}')

          Start-Sleep -Milliseconds 200

          [System.Windows.Forms.SendKeys]::SendWait($LoginUser)

          Start-Sleep -Milliseconds 500

          [BdWin]::Click($ofx + [int](300 * $sf), $ofy + [int](271 * $sf))

          Start-Sleep -Milliseconds 600

          [System.Windows.Forms.SendKeys]::SendWait('{END}{BACKSPACE 40}')

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

# 2026-10-28 根因修正：底部 tab 图标 x 会漂移（65 → 42 实测漂 23px），
# 点偏了就落在图标间隙、点击无效，UI 停在设备页导致后续眼睛点击全落空。
# 对策：点一次验证一次 —— 被控页特征 =「允许远程本机」黄色开关（600 基准
# x[160,210] y[100,180] 一带有黄像素），不确认就换 x 重试。
function Test-BeikongPixel([string]$p) {

  $b = New-Object System.Drawing.Bitmap($p)

  $hit = 0

  for ($x = 160; $x -le 210; $x++) {

    for ($y = 100; $y -le 180; $y++) {

      $c = $b.GetPixel($x, $y)

      if ($c.R -gt 200 -and $c.G -gt 140 -and $c.B -lt 120) { $hit++ }

    }

  }

  $b.Dispose()

  return ($hit -ge 15)

}

$bk = $false

foreach ($tx in @(65, 42, 88, 55)) {

  [BdWin]::Click($geo.L + [int]($tx * $tabScale), $geo.T + [int](560 * $tabScale))

  Start-Sleep -Milliseconds 1500

  $ng = Shot2 $shotPath $geo

  if ($ng) { $geo = $ng } else { L 'WARN: shot failed after switching to 被控'; continue }

  if (Test-BeikongPixel $shotPath) { $bk = $true; L ('beikong tab confirmed at x=' + $tx); break }

  L ('beikong tab NOT confirmed at x=' + $tx)

}

if (-not $bk) { L 'WARN: beikong tab unconfirmed after all x, continue anyway' }

$lines = OcrImage $shotPath

foreach ($ln in $lines) { L ('  ocr| ' + $ln.Text) }

# 截图内容校验（2026-10-27 晚）：窗口被其他弹窗（Edge 欢迎页等）遮挡时，
# Shot 按 rect 抓到的是遮挡物内容，OCR 里完全没有 billd 字样。
# 此时激活 BilldDesk 重拍重 OCR 一次，防止后续所有点击作用在遮挡物上。
$bdSeen = $false

foreach ($ln in $lines) {

  if ($ln.Text -match 'billd') { $bdSeen = $true; break }

}

if (-not $bdSeen) {

  L 'WARN: shot content is not BilldDesk (occluded?), re-focusing and re-shooting'

  [BdWin]::Focus()

  Start-Sleep -Milliseconds 1200

  $ng2 = Shot2 $shotPath $geo

  if ($ng2) {

    $geo = $ng2

    $lines = OcrImage $shotPath

    foreach ($ln in $lines) { L ('  ocr-retry| ' + $ln.Text) }

  }

}

# 页面错误检测（2026-10-27 晚二次实测）：切回被控失败时截图仍是「设备」页，
# OCR 里含本机 COMPTUERNAME（设备列表条目）⇒ 采集到的会是别人的设备码。
# 检测到就重试切被控页并重拍（最多 2 轮）。
$devPageSeen = $false

$myHost = $env:COMPUTERNAME.ToLower()

foreach ($ln in $lines) {

  if ($ln.Text.ToLower().Contains($myHost)) { $devPageSeen = $true; break }

}

$devPageTries = 0

while ($devPageSeen -and $devPageTries -lt 2) {

  $devPageTries++

  L ('WARN: still on device page (switch to controlled lost?), retry ' + $devPageTries)

  [BdWin]::Focus()

  Start-Sleep -Milliseconds 800

  [BdWin]::Click($geo.L + [int](65 * ($geo.W / 600.0)), $geo.T + [int](560 * ($geo.W / 600.0)))

  Start-Sleep -Milliseconds 2000

  $ng3 = Shot2 $shotPath $geo

  if ($ng3) {

    $geo = $ng3

    $lines = OcrImage $shotPath

    foreach ($ln in $lines) { L ('  ocr-retry2| ' + $ln.Text) }

    $devPageSeen = $false

    foreach ($ln in $lines) {

      if ($ln.Text.ToLower().Contains($myHost)) { $devPageSeen = $true; break }

    }

  }

}



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

# 2026-10-28 下午根因：OCR 给出的行 Y 偶发偏小 40px 上下（截图重试期间窗口在动画，
# 拿到的是上一帧/缩放图的 bbox）。devY 一旦偏小，2.5 节的眼睛点击坐标与密码行
# OCR 过滤窗口全部落空 ⇒ 读不到旧密码 ⇒ SKIP 改密 ⇒ 状态文件写的是假固定密码。
# 历史实测（1024x768 全屏、600x600 窗口）devY 稳定在 192 附近；越界即用兜底值。
if ($devY -lt 0 -or $devY -lt 172 -or $devY -gt 240) {

  L ('WARN: devY out of range (' + $devY + '), clamp to fallback 192')

  $devY = 192.0

}



# ---------- 2.5 固定连接密码（-FixedPassword 传入时执行） ----------

# 背景：BilldDesk 的默认密码是机器指纹派生的固定值（GitHub runner 镜像 MachineGuid

# 相同 ⇒ 每台新 VM 都是同一个初始密码），且开机约 15-25 分钟后会自动轮换成随机值，

# 导致状态文件里推的密码很快失效（2026-10-26 实测）。对策：开机就用「铅笔」对话框

# 把密码改成 bootstrap 生成的随机 8 位，此后不再轮换，状态文件里的值始终有效。

if ($FixedPassword -and $devCode -and -not $SkipFixedPassword) {

  $script:PwdChangeSkipped = $false

  Add-Type -AssemblyName System.Windows.Forms

  $scaleF = $geo.H / 600.0

  L ('set fixed password len=' + $FixedPassword.Length)

  # 2026-10-28 根因修正：改密弹窗的「旧密码」框是空的，必须先点眼睛读出当前
  # 密码填进去，否则提交被服务端拒绝（连续三次 MISMATCH 均因此，非时序问题）。
  # 眼睛 600 基准 = (500, devY+105)，与铅笔 (545, devY+105) 同行（1024x768 实测）。
  $oldPwd = ''

  [BdWin]::Click($geo.L + [int](500 * $scaleF), $geo.T + [int](($devY + 105.0) * $scaleF))

  Start-Sleep -Milliseconds 2000

  $curShot = Join-Path $OutDir 'shot-curpwd.png'

  if (Shot $curShot) {

    $cl = OcrImage $curShot

    foreach ($ln in $cl) { L ('  curpwd-ocr| ' + $ln.Text) }

    foreach ($ln in $cl) {

      # 2026-10-28：窗口放宽到 +165（原 +130），并排除设备码行自身
      if ($ln.Y -lt ($devY + 50) -or $ln.Y -gt ($devY + 165)) { continue }

      $t = ($ln.Text -replace '[^A-Za-z0-9]', '')

      if ($t.Length -ge 5 -and $t.Length -le 16 -and $t -ne $devCode) { $oldPwd = $t; break }

    }

  }

  # 点回去重新掩码

  [BdWin]::Click($geo.L + [int](500 * $scaleF), $geo.T + [int](($devY + 105.0) * $scaleF))

  Start-Sleep -Milliseconds 500

  # 2026-10-28 补充：若密码本来就是明文（上次流程遗留），上面点眼睛把它切回了
  # 掩码导致 OCR 读空 —— 再点一次恢复明文重读；仍读不到才放弃（放弃时不提交
  # 改密，避免用错误旧密码做无效提交）。

  if (-not $oldPwd) {

    L 'curpwd not read, re-click eye (plain<->mask toggle)'

    [BdWin]::Click($geo.L + [int](500 * $scaleF), $geo.T + [int](($devY + 105.0) * $scaleF))

    Start-Sleep -Milliseconds 2000

    if (Shot $curShot) {

      $cl = OcrImage $curShot

      foreach ($ln in $cl) { L ('  curpwd-ocr2| ' + $ln.Text) }

      foreach ($ln in $cl) {

        # 2026-10-28：窗口放宽到 +165（原 +130），并排除设备码行自身
        if ($ln.Y -lt ($devY + 50) -or $ln.Y -gt ($devY + 165)) { continue }

        $t = ($ln.Text -replace '[^A-Za-z0-9]', '')

        if ($t.Length -ge 5 -and $t.Length -le 16 -and $t -ne $devCode) { $oldPwd = $t; break }

      }

    }

    [BdWin]::Click($geo.L + [int](500 * $scaleF), $geo.T + [int](($devY + 105.0) * $scaleF))

    Start-Sleep -Milliseconds 500

    L ('old password(from ocr2)=' + $oldPwd)

  }

  L ('old password(from ocr)=' + $oldPwd)

  if (-not $oldPwd) {

    $script:PwdChangeSkipped = $true

    L 'old password unknown, SKIP fixed password change'

  } else {

  # 铅笔图标：与眼睛同行（devY+105 中心），x≈545（600 基准，屏幕 757）。
  # 2026-10-28 下午实测：流程全对但仍偶发 MISMATCH —— 弹窗留存（新密码框疑似
  # 输入偶发丢失，提交被本地校验拒绝）。加就地读回验证 + 自动重试，最多 2 次。
  for ($fx = 1; $fx -le 2; $fx++) {

    L ('fixed password attempt ' + $fx)

  [BdWin]::Click($geo.L + [int](545 * $scaleF), $geo.T + [int](($devY + 105.0) * $scaleF))

  Start-Sleep -Milliseconds 1800

  # 旧密码输入框（2026-10-28 实测 600 基准 (341,306)，即全屏 (553,366)）

  [BdWin]::Click($geo.L + [int](341 * $scaleF), $geo.T + [int](306 * $scaleF))

  Start-Sleep -Milliseconds 700

  [System.Windows.Forms.SendKeys]::SendWait('{END}{BACKSPACE 40}')

  Start-Sleep -Milliseconds 250

  [System.Windows.Forms.SendKeys]::SendWait($oldPwd)

  Start-Sleep -Milliseconds 500

  # 新密码输入框（对话框内固定位置 (341,360)）

  [BdWin]::Click($geo.L + [int](341 * $scaleF), $geo.T + [int](360 * $scaleF))

  Start-Sleep -Milliseconds 700

  [System.Windows.Forms.SendKeys]::SendWait('{END}{BACKSPACE 40}')

  Start-Sleep -Milliseconds 250

  [System.Windows.Forms.SendKeys]::SendWait($FixedPassword)

  Start-Sleep -Milliseconds 600

  # 确定按钮 (300,415)

  [BdWin]::Click($geo.L + [int](300 * $scaleF), $geo.T + [int](415 * $scaleF))

  Start-Sleep -Milliseconds 2500

  L 'fixed password submitted'

  # 就地读回验证：点眼睛重读，I/1 与 O 折叠比对
  Start-Sleep -Milliseconds 1500

  [BdWin]::Click($geo.L + [int](500 * $scaleF), $geo.T + [int](($devY + 105.0) * $scaleF))

  Start-Sleep -Milliseconds 2000

  $fxShot = Join-Path $OutDir ('shot-fxv' + $fx + '.png')

  $fxOk = $false

  if (Shot $fxShot) {

    $fxFold = { param($s) $s -replace '[I1]', 'l' -replace 'O', '0' }

    foreach ($ln in (OcrImage $fxShot)) {

      L ('  fxv-ocr| ' + $ln.Text)

      $t = ($ln.Text -replace '[^A-Za-z0-9]', '')

      if ($t.Length -ge 5 -and $t.Length -le 16 -and ((& $fxFold $t) -eq (& $fxFold $FixedPassword))) { $fxOk = $true; break }

    }

  }

  # 点回去重新掩码（恢复进入前状态）

  [BdWin]::Click($geo.L + [int](500 * $scaleF), $geo.T + [int](($devY + 105.0) * $scaleF))

  Start-Sleep -Milliseconds 500

  if ($fxOk) { L 'fixed password verified (in 2.5)'; break }

  if ($fx -lt 2) {

    L 'mismatch in 2.5, close dialog and retry'

    [BdWin]::Click($geo.L + [int](431 * $scaleF), $geo.T + [int](203 * $scaleF))   # 弹窗 X

    Start-Sleep -Milliseconds 1200

  }

  }   # end for fx

  }   # end else (old password known)

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
    # 只在「密码行」的 OCR 行里找密码：窗口内 y ∈ [devY+50, devY+165]
    # （设备码行在 devY，密码行在其下方；顶部横幅/版本号都在带外）
    $ocrPwd = ''
    foreach ($ln in $l2) {
      if ($ln.Y -lt ($devY + 50) -or $ln.Y -gt ($devY + 165)) { continue }
      $t = ($ln.Text -replace '[^A-Za-z0-9]', '')
      if ($t.Length -ge 5 -and $t.Length -le 16 -and $t -ne $devCode) { $ocrPwd = $t; break }
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
      } elseif ($script:PwdChangeSkipped) {
        # 改密被跳过（旧密码没读到）⇒ 真实密码仍是自动密码，绝不能把没生效的
        # FixedPassword 当真实值推给手机（2026-10-28 主人就是按这个假值连接失败的）
        $password = ''
        L 'password change skipped, refuse to report unverified fixed value'
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



# ---------- 3.5 设备列表维护（BilldDesk v0.623.0） ----------
#
# 2026-10-28 晚 v0.623.0 实测改版：开发者修好了「多端登录同一账号不显示在线设备」，
# 「设备」页现在是「同账号在线设备 / 我的设备」两个分组。同账号在线设备可直接远控，
# 只要客户端登录了账号就会出现，**不再依赖固定连接密码**（旧版必须改密才能保住绑定）。
#
# 本段职责（对应主人的两条要求）：
#   1) 删除「我的设备」里所有离线/失效条目 —— 即上一个实例残留的死设备；
#   2) 把本机作为一条新设备加进去，备注 cloud-desktop-MMdd-HHmm（带时间），
#      主人在列表里一眼能看出哪条是刚开机这台。
#
# 坐标（600 基准，1024x768 / 窗口 600x600@212,60 实测）：
#   设备 tab(300,552)  我的设备分组(90,152)  添加设备按钮(229,61)
#   添加弹窗：备注(340,277) 设备码(340,332) 连接密码(340,388) 确定(300,441)
#   删除确认：取消(229,352) 确定(372,352)
#   条目 n 设备码行 y = 108 + 70*(n-1)；该行删除按钮 (549, y+25)
#
# 判定在线/离线用颜色而不是 OCR 文字：OCR 引擎是 en-US，读不了「在线/离线」，
# 但状态文字的颜色可靠 —— 在线是绿色，离线/失效是灰色。

$script:BindState = ''
$script:Remark = ''
$script:DevClean = ''

function Get-RowOnline([string]$p, [int]$y, [double]$sc) {
  # 状态文字在设备码行下方 +12..+34，绿色判定；坐标按 600 基准缩放
  $b = New-Object System.Drawing.Bitmap($p)
  $hit = 0
  $y0 = [Math]::Max(0, [int](($y + 12) * $sc))
  $y1 = [Math]::Min($b.Height - 1, [int](($y + 34) * $sc))
  $x0 = [int](242 * $sc); $x1 = [int](300 * $sc)
  for ($py = $y0; $py -le $y1; $py++) {
    for ($px = $x0; $px -le $x1; $px++) {
      if ($px -ge $b.Width) { break }
      $c = $b.GetPixel($px, $py)
      if ($c.G -gt 130 -and $c.G -gt ($c.R + 35) -and $c.G -gt ($c.B + 25)) { $hit++ }
    }
  }
  $b.Dispose()
  return ($hit -ge 10)
}

if ($devCode -and $LoginUser -and $script:LoginState -ne 'error' -and $script:LoginState -ne 'unknown' -and $script:LoginState -ne '') {

  try {

    Add-Type -AssemblyName System.Windows.Forms
    $bs = $geo.W / 600.0
    $script:Remark = if ($DeviceRemark) { $DeviceRemark } else { 'cloud-desktop-' + (Get-Date).ToUniversalTime().AddHours(8).ToString('MMdd-HHmm') }

    # 进「设备」页 + 选「我的设备」分组
    [BdWin]::Click($geo.L + [int](300 * $bs), $geo.T + [int](552 * $bs))
    Start-Sleep -Milliseconds 2000
    [BdWin]::Click($geo.L + [int](90 * $bs), $geo.T + [int](152 * $bs))
    Start-Sleep -Milliseconds 1500

    $ds = Join-Path $OutDir 'shot-dev.png'

    # ---- A. 逐个删除离线/失效条目（每删一条重新截图，行会往上移） ----
    $delCount = 0

    for ($round = 1; $round -le 6; $round++) {

      $dg = Shot2 $ds $geo
      if (-not $dg) { $script:DevClean = 'no-shot'; break }
      $geo = $dg

      $dl = OcrImage $ds
      foreach ($ln in $dl) { L ('  dev-ocr| ' + [int]$ln.Y + ' ' + $ln.Text) }

      # 设备码行：8~10 位纯数字，且落在列表区（y 80..480）
      $rows = @()
      foreach ($ln in $dl) {
        $t = ($ln.Text -replace '[^0-9]', '')
        if ($t.Length -ge 8 -and $t.Length -le 10 -and $ln.Y -gt 80 -and $ln.Y -lt 480) {
          $rows += [pscustomobject]@{ Code = $t; Y = [double]$ln.Y }
        }
      }

      if ($rows.Count -eq 0) { L 'dev: no device rows parsed'; break }

      $mine = $false
      $victim = $null
      foreach ($rw in ($rows | Sort-Object Y)) {
        $online = Get-RowOnline $ds ([int]$rw.Y) $bs
        $isMine = ($rw.Code -eq $devCode)
        L ('  row code=' + $rw.Code + ' y=' + [int]$rw.Y + ' mine=' + $isMine + ' online=' + $online)
        if ($isMine -and -not $mine) {
          # 本机旧条目：照样删掉，下面重新添加一次，让备注总是本次开机的时间戳
          $mine = $true
          $victim = $rw
          continue
        }
        if (-not $online -and -not $victim) { $victim = $rw }
      }

      if (-not $victim) { L 'dev: no offline leftover to delete'; break }

      L ('dev: delete leftover code=' + $victim.Code + ' y=' + [int]$victim.Y)
      [BdWin]::Click($geo.L + [int](549 * $bs), $geo.T + [int](($victim.Y + 25) * $bs))
      Start-Sleep -Milliseconds 1600
      [BdWin]::Click($geo.L + [int](372 * $bs), $geo.T + [int](352 * $bs))   # 确认「确定」
      Start-Sleep -Milliseconds 2600
      $delCount++

    }

    $script:DevClean = 'deleted-' + $delCount

    # ---- B. 本机不在列表就添加（备注带时间戳） ----
    $dg2 = Shot2 $ds $geo
    if ($dg2) { $geo = $dg2 }
    $dl2 = OcrImage $ds
    $mineNow = $false
    foreach ($ln in $dl2) {
      if ((($ln.Text -replace '[^0-9]', '')) -eq $devCode) { $mineNow = $true; break }
    }

    if ($mineNow) {

      L 'dev: current instance already listed, skip add'
      $script:BindState = 'already'

    } elseif (-not $password) {

      L 'dev: no current password readable, skip add (cleanup only)'
      $script:BindState = 'skip-no-password'

    } else {

      L ('dev: add current device remark=' + $script:Remark)
      [BdWin]::Click($geo.L + [int](229 * $bs), $geo.T + [int](61 * $bs))     # 添加设备
      Start-Sleep -Milliseconds 1800

      [BdWin]::Click($geo.L + [int](340 * $bs), $geo.T + [int](277 * $bs))    # 设备备注
      Start-Sleep -Milliseconds 500
      [System.Windows.Forms.SendKeys]::SendWait('{END}{BACKSPACE 40}')
      Start-Sleep -Milliseconds 250
      [System.Windows.Forms.SendKeys]::SendWait($script:Remark)
      Start-Sleep -Milliseconds 400

      [BdWin]::Click($geo.L + [int](340 * $bs), $geo.T + [int](332 * $bs))    # 设备代码
      Start-Sleep -Milliseconds 500
      [System.Windows.Forms.SendKeys]::SendWait('{END}{BACKSPACE 40}')
      Start-Sleep -Milliseconds 250
      [System.Windows.Forms.SendKeys]::SendWait($devCode)
      Start-Sleep -Milliseconds 400

      [BdWin]::Click($geo.L + [int](340 * $bs), $geo.T + [int](388 * $bs))    # 连接密码
      Start-Sleep -Milliseconds 500
      [System.Windows.Forms.SendKeys]::SendWait('{END}{BACKSPACE 40}')
      Start-Sleep -Milliseconds 250
      [System.Windows.Forms.SendKeys]::SendWait($password)
      Start-Sleep -Milliseconds 400

      [BdWin]::Click($geo.L + [int](300 * $bs), $geo.T + [int](441 * $bs))    # 确定
      Start-Sleep -Milliseconds 3200

      # 验证：重截图，列表里应出现本机设备码
      $dg3 = Shot2 $ds $geo
      $script:BindState = 'unverified'
      if ($dg3) {
        $geo = $dg3
        $dl3 = OcrImage $ds
        foreach ($ln in $dl3) {
          if ((($ln.Text -replace '[^0-9]', '')) -eq $devCode) { $script:BindState = 'ok'; break }
        }
      }

      L ('dev: add verify state=' + $script:BindState)

    }

    # 回「被控」页
    [BdWin]::Click($geo.L + [int](60 * $bs), $geo.T + [int](552 * $bs))
    Start-Sleep -Milliseconds 1200

  } catch { L ('dev flow failed: ' + $_.Exception.Message); $script:BindState = 'error' }

} elseif ($devCode -and $LoginUser) {

  $script:BindState = 'skip-no-login-state'

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

  remark    = [string]$script:Remark

  dev_clean = [string]$script:DevClean

  bind      = if ($LoginUser) { if ($script:BindState) { $script:BindState } else { 'skipped' } } else { '' }

  window    = if ($geo) { ($geo.W.ToString() + 'x' + $geo.H.ToString()) } else { '' }

  session   = $sess

  updated_at = (Get-Date).ToUniversalTime().ToString('o')

  error     = ''

}

($result | ConvertTo-Json -Depth 4) | Out-File (Join-Path $OutDir 'billddesk.json') -Encoding utf8

L ('wrote billddesk.json ok=' + $result.ok + ' state=' + $result.state)

L 'DONE'

