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

  if ($w -le 10 -or $h -le 10) { L ('shot: rect invalid ' + $w + 'x' + $h); return $null }

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

      if ($saveTries -ge 3) { L ('shot: save failed ' + $path); $bmp.Dispose(); return $null }

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

        # fallback 保存也要重试：文件锁/杀软短暂占用时一次 Save 就抛异常，
        # 2026-10-29 开机实测导致 Shot2 连续 4 轮全灭、登录兜底判定整个没跑。
        $st2 = 0
        while ($true) {
          try { $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); break }
          catch {
            $st2++
            if ($st2 -ge 3) { L ('shot2: fallback save failed ' + $path); $bmp.Dispose(); return $null }
            Start-Sleep -Milliseconds 500
          }
        }

        $bmp.Dispose()

        return $fallback

      } catch { L ('shot2: fallback exception: ' + $_.Exception.Message); return $null }

    }

    Start-Sleep -Milliseconds 800

  }

  return $null

}



# 登录页像素判定：600 基准 x[165,230] y[158,198] 区域出现黄色像素 = 登录页的
# 黄色「登录」tab（2026-10-27 bd-mc1/bd-mc3 截图实测对比：已登录主控页同位置
# 是白色背景）。中文 OCR 不可用（Windows OCR 引擎 en-US 读不了中文），所以
# 登录态判定全部走像素，不依赖 OCR 语言。
# 底部「主控」tab 是否处于选中（高亮）态：600 基准 x[160,210] y[528,590]。
# 用来区分「点主控没生效、还停在被控页」和「已经在主控页」——2026-10-29 实测
# 冷启动首点会丢，必须确认切页成功，否则会把被控页误判成"已登录"。
function Test-MainTabActive([string]$imgPath, $ggeo, [double]$sc) {

  $bmp = New-Object System.Drawing.Bitmap($ggeo.W, $ggeo.H)

  $g = [System.Drawing.Graphics]::FromImage($bmp)

  $g.DrawImage([System.Drawing.Image]::FromFile($imgPath), 0, 0)

  $g.Dispose()

  $n = 0

  $px0 = [int](160 * $sc); $px1 = [int](210 * $sc)
  $py0 = [int](528 * $sc); $py1 = [int](590 * $sc)

  for ($yy = $py0; $yy -le $py1 -and $n -lt 40; $yy++) {

    for ($xx = $px0; $xx -le $px1 -and $n -lt 40; $xx++) {

      $c = $bmp.GetPixel($xx, $yy)

      if ($c.R -gt 200 -and $c.G -gt 140 -and $c.B -lt 130) { $n++ }

    }

  }

  $bmp.Dispose()

  return ($n -ge 40)

}

function Test-LoginTabPixel([string]$imgPath, $ggeo, [double]$sc) {

  $bmp = New-Object System.Drawing.Bitmap($ggeo.W, $ggeo.H)

  $g = [System.Drawing.Graphics]::FromImage($bmp)

  $g.DrawImage([System.Drawing.Image]::FromFile($imgPath), 0, 0)

  $g.Dispose()

  $hit = $false

  $px0 = [int](175 * $sc); $px1 = [int](225 * $sc)

  $py0 = [int](145 * $sc); $py1 = [int](195 * $sc)

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



# ---------- 2.6 账号登录（-LoginUser/-LoginPass 传入时执行） ----------
#
# 需求（2026-10-29 主人定调）：客户端登录 dtka1 后，主人手机端「设备 → 同账号在线
# 设备」里能看到这台机器，点「远程」直接连，**不需要连接密码**。所以本文只负责
# 保证登录态；连接密码仍读一次做备用展示。
#
# v0.623.0 实测三个坑（2026-10-29）：
#   1) 冷启动后立刻点「主控」tab 会丢点击，UI 停在被控页；旧版 1.5s 后截图看
#      「没有黄色登录字」就判已登录 ⇒ 整段被跳过，实测漏登录。对策：点击后等
#      2.5s，并用底部「主控」tab 是否高亮确认真的切过去了，最多 3 轮。
#   2) 登录页和已登录主控页都有一块黄色大按钮（确定 / 连接），位置几乎相同，
#      不能拿它区分。唯一可靠特征 = 登录页顶部「登录」黄字（600 基准
#      x[175,225] y[145,195]）。
#   3) 账号密码必须逐字符输入：SendKeys 一次发整串会丢字符。
#
# 坐标（600 基准，1024x768 / 窗口 600x600@212,60 实测）：
#   主控 tab(185,552) 被控 tab(60,552)
#   用户名框(300,201) 密码框(256) 眼睛(401,256) 确定(300,311)

$script:LoginState = ''

if ($LoginUser -and $LoginPass) {

  try {

    Add-Type -AssemblyName System.Windows.Forms

    $sf = $geo.W / 600.0
    $ofx = $geo.L
    $ofy = $geo.T
    $loginShot = Join-Path $OutDir 'shot-login.png'

    function TypeSlow([string]$t) {
      foreach ($c in $t.ToCharArray()) {
        [System.Windows.Forms.SendKeys]::SendWait([string]$c)
        Start-Sleep -Milliseconds 120
      }
      Start-Sleep -Milliseconds 400
    }

    # ---- 1) 切到主控页，用底部 tab 高亮确认 ----
    # 2026-10-29 第二次开机实测：Shot2 在登录导航阶段连续 4 轮全灭
    # （GetWindowRect 瞬时归零 + fallback save 无重试），导致整个登录被跳过。
    # 导航判定改用「裸截图」：固定用 $geo 坐标 CopyFromScreen，绕开 rect 检查。
    # 2026-10-29 教训：固定文件名会被 OCR/杀软句柄锁死（第一轮 Save 成功、之后
    # 连续 4 轮 GDI+ generic error），改为每轮唯一文件名 + Save 3 次重试 +
    # catch 内 Dispose，彻底绕开同路径锁竞争。
    $script:BareN = 0
    $script:BarePath = ''

    function BareShot {
      $bmp = $null
      try {
        $script:BareN++
        $bare = Join-Path $OutDir ('shot-login-bare-' + $script:BareN + '.png')
        $script:BarePath = $bare
        $bmp = New-Object System.Drawing.Bitmap([int]$geo.W, [int]$geo.H)
        $g2 = [System.Drawing.Graphics]::FromImage($bmp)
        $g2.CopyFromScreen([int]$geo.L, [int]$geo.T, 0, 0, $bmp.Size)
        $g2.Dispose()
        if (Test-Path $bare) { Remove-Item $bare -Force -ErrorAction SilentlyContinue }
        $tries = 0
        while ($true) {
          try { $bmp.Save($bare, [System.Drawing.Imaging.ImageFormat]::Png); break }
          catch {
            $tries++
            if ($tries -ge 3) { L ('login: bare save failed ' + $bare); return $false }
            Start-Sleep -Milliseconds 500
          }
        }
        return $true
      } catch { L ('login: bare shot failed: ' + $_.Exception.Message); return $false }
      finally { try { if ($bmp) { $bmp.Dispose() } } catch { } }
    }

    $onMain = $false

    for ($r1 = 1; $r1 -le 4; $r1++) {

      [BdWin]::Focus()
      Start-Sleep -Milliseconds 500

      [BdWin]::Click($ofx + [int](185 * $sf), $ofy + [int](552 * $sf))
      Start-Sleep -Milliseconds 2500

      if (BareShot) {
        if (Test-MainTabActive $script:BarePath $geo $sf) { $onMain = $true; break }
        L ('login: main tab not active yet (round ' + $r1 + ')')
      } else {
        L ('login: bare shot failed round ' + $r1)
      }
      Start-Sleep -Milliseconds 800

    }

    if (-not $onMain) {

      # 兜底（2026-10-29 首次真机开机暴露）：nav 全失败不代表已登录 ——
      # 点主控丢点击时 UI 往往正停在登录页。直接看当前画面有没有
      # 登录页顶部「登录」黄字，有就在当前页提交账号，不必非切到主控页。
      if (BareShot) {
        if (Test-LoginTabPixel $script:BarePath $geo $sf) {
          $onMain = $true
          L 'login: nav failed but login tab visible on current page'
        }
      }

    }

    if (-not $onMain) {

      $script:LoginState = 'nav-failed'
      L 'login: cannot reach main-control page'

    } elseif (Test-LoginTabPixel $script:BarePath $geo $sf) {

      L 'login page detected, submitting account'

      # 每框连填两遍：2026-10-29 手动补登实测单击偶发不聚焦（账号进了密码框），
      # 第二遍全清重填覆盖第一遍，任一遍聚焦成功最终值都正确。
      for ($fillPass = 1; $fillPass -le 2; $fillPass++) {

        [BdWin]::Click($ofx + [int](300 * $sf), $ofy + [int](201 * $sf))
        Start-Sleep -Milliseconds 500
        [System.Windows.Forms.SendKeys]::SendWait('^a')
        Start-Sleep -Milliseconds 300
        [System.Windows.Forms.SendKeys]::SendWait('{BACKSPACE 20}')
        Start-Sleep -Milliseconds 300
        TypeSlow $LoginUser

        [BdWin]::Click($ofx + [int](300 * $sf), $ofy + [int](256 * $sf))
        Start-Sleep -Milliseconds 500
        [System.Windows.Forms.SendKeys]::SendWait('^a')
        Start-Sleep -Milliseconds 300
        [System.Windows.Forms.SendKeys]::SendWait('{BACKSPACE 20}')
        Start-Sleep -Milliseconds 300
        TypeSlow $LoginPass
        Start-Sleep -Milliseconds 400

      }

      [BdWin]::Click($ofx + [int](300 * $sf), $ofy + [int](311 * $sf))
      L 'login: submitted'
      Start-Sleep -Milliseconds 4000

      $script:LoginState = 'submitted'

      # 双轮验证：黄色「登录」字消失 = 已进主控页（裸截图，理由同导航段）
      for ($v = 1; $v -le 2; $v++) {

        if (-not (BareShot)) { Start-Sleep -Milliseconds 2500; continue }

        if (-not (Test-LoginTabPixel $script:BarePath $geo $sf)) { $script:LoginState = 'ok'; break }

        L ('login: still on login page, verify round ' + $v)
        Start-Sleep -Milliseconds 2500

      }

      if ($script:LoginState -ne 'ok') { L 'WARN: login verification failed' }

    } else {

      $script:LoginState = 'already'
      L 'already logged in (no login tab), skip'

    }

    L ('login state=' + $script:LoginState)

    # ---- 2) 回被控页继续采集 ----
    [BdWin]::Click($ofx + [int](60 * $sf), $ofy + [int](552 * $sf))
    Start-Sleep -Milliseconds 1800

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



# （2026-10-29 已移除固定密码逻辑：主人改用「同账号在线设备」直连，不再需要恒定密码。）


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
    # 2026-10-29：不再设固定密码，OCR 读到的就是当前真实值；读不到就留空，
    # 绝不把已知旧值当真实值上报。手机端主用「同账号在线设备」直连，不依赖密码。
    $password = $ocrPwd

    # 点回去重新掩码

    [BdWin]::Click($ex, $ey)

    Start-Sleep -Milliseconds 400

  }

}



if (-not $password -and $FallbackPassword) {

  $password = $FallbackPassword

  L ('password fallback=' + $password)

}



# （2026-10-29 已移除设备列表维护：残留条目不会出现在「同账号在线设备」里，
#   备注也不再需要，流程只保留「登录 + 读设备码/密码」。）


# ---------- 4. 落盘 ----------

$result = [ordered]@{

  ok        = [bool]($devCode -and $password)

  state     = if ($devCode -and $password -and $script:LoginState -in @('ok','already','skipped','')) { 'ready' }
              elseif ($devCode -and $password) { 'degraded-login' }
              elseif ($devCode) { 'no-password' } else { 'no-device-code' }

  device_code = if ($devCode) { ($devCode.Substring(0,3) + ' ' + $devCode.Substring(3,3) + ' ' + $devCode.Substring(6,3)) } else { '' }

  device_uuid = $devCode

  password  = $password

  account   = $LoginUser

  login     = if ($LoginUser) { if ($script:LoginState) { $script:LoginState } else { 'skipped' } } else { '' }

  remark    = ''

  dev_clean = 'skipped'

  bind      = 'skipped'


  window    = if ($geo) { ($geo.W.ToString() + 'x' + $geo.H.ToString()) } else { '' }

  session   = $sess

  updated_at = (Get-Date).ToUniversalTime().ToString('o')

  error     = ''

}

($result | ConvertTo-Json -Depth 4) | Out-File (Join-Path $OutDir 'billddesk.json') -Encoding utf8

L ('wrote billddesk.json ok=' + $result.ok + ' state=' + $result.state)

L 'DONE'

