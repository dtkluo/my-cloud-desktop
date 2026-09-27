<#
.SYNOPSIS
    在云桌面本机用「环回 RDP」建立 rdpadmin 的交互式会话，触发 AgentDock 的
    登录时计划任务，从而免去人工 RDP 那一步。

.DESCRIPTION
    为什么需要这一步：
      AgentDock 是**按用户安装**的（%LOCALAPPDATA%\AgentDock、HKCU 与 DPAPI 凭据
      都绑定具体 Windows 用户）。安装器在工作流里以 staging 模式落地，注册了
      计划任务 AgentDock-UserInstall：
          触发 = 该用户登录时（LogonTrigger）
          身份 = rdpadmin，LogonType = Interactive
          动作 = powershell -File C:\agentdock-install\provision-agentdock-user.ps1
      工作流步骤本身跑在 runneradmin 的会话里，rdpadmin 从不登录 => 任务永不触发，
      AgentDock 起不来。过去靠人工 RDP 登录来"点燃"它。

    本脚本把这件事自动化：**从本机自己 RDP 自己**（127.0.0.1:3389）。
    环回 RDP 会为 rdpadmin 创建一个真正的交互式会话（登录类型 10/2），
    于是计划任务触发、AgentDock 拉起；随后杀掉 mstsc，会话转为 Disconnected
    但**不会被注销**，AgentDock 继续运行。用户之后再从手机/PC 连进来，
    会**接回同一个会话**，看到的是已经就绪的桌面。

    为什么不用「另开一个仓库 / 另一个工作流在外面连进来」：
      外部 RDP 需要先解决可达性（EasyTier 组网或 Cloudflare TCP 隧道），
      多一条链路就多一个故障点，而且还要多消耗一台 runner。
      环回 RDP 全在本机完成，零外部依赖。

.PARAMETER Password
    rdpadmin 的密码。留空则从 -PasswordFile 读取。

.PARAMETER KeepSession
    默认在 AgentDock 就绪后杀掉 mstsc（会话转 Disconnected）。
    加此开关则保留 mstsc 进程，会话保持 Active。

.NOTES
    两个硬约束（踩过）：
      1. 启动 mstsc 的进程必须本身处于**交互式会话**中。GitHub Actions 的
         windows runner 跑在 runneradmin 的 console 会话里（query session 可见
         `console runneradmin 2 Active`），满足条件。
      2. mstsc 必须与轮询循环处在**同一个长生命周期进程**内。若单发启动后
         父进程立刻退出，子进程树会被回收（实测 10s 后 mstsc 消失）。
         所以本脚本启动 mstsc 后不退出，一直轮询到就绪或超时。
#>
[CmdletBinding()]
param(
    [string] $User = 'rdpadmin',
    [string] $Password = '',
    [string] $PasswordFile = '',
    [int]    $Port = 8765,
    [int]    $TimeoutSec = 180,
    [int]    $PollIntervalSec = 5,
    # mstsc 进程退出后再观察多久才判定失败（会话可能已建好，只是客户端进程退了）
    [int]    $GraceSec = 60,
    [switch] $KeepSession,
    [string] $WorkDirectory = 'C:\agentdock-install'
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# ---------- 0. 取密码 ----------
if ([string]::IsNullOrWhiteSpace($Password)) {
    if ($PasswordFile -and (Test-Path -LiteralPath $PasswordFile)) {
        $Password = (Get-Content -LiteralPath $PasswordFile -Raw).Trim()
    }
}
if ([string]::IsNullOrWhiteSpace($Password)) {
    Write-Error '缺少 rdpadmin 密码（传 -Password 或 -PasswordFile）'
    exit 3
}

$healthUrl = "http://127.0.0.1:$Port/healthz"
$mstsc     = Join-Path $env:SystemRoot 'System32\mstsc.exe'

# 工作目录可能尚未存在（步骤 5 才会创建），这里兜底建一下
if (-not (Test-Path -LiteralPath $WorkDirectory)) {
    New-Item -ItemType Directory -Path $WorkDirectory -Force | Out-Null
}
$rdpFile = Join-Path $WorkDirectory 'wake-loopback.rdp'

function Test-AgentDockUp {
    try {
        $r = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 5
        return ($r.StatusCode -eq 200)
    } catch {
        return $false
    }
}

# ---------- 0.5 幂等：已经就绪就什么都不做 ----------
# 重跑 workflow / 手动重触发时会再次走到这一步，没必要再连一次。
if (Test-AgentDockUp) {
    Write-Host "AgentDock 已就绪（$healthUrl），跳过唤醒"
    exit 0
}

Write-Host "唤醒前会话状态："
(quser 2>&1 | Out-String).Trim()

# ---------- 1. 写 .rdp ----------
# 配方取自本机已验证可用的 cloud-desktop.rdp：关键是
#   authentication level:i:0 + prompt for credentials:i:0 + username:s:
# 三者齐备才不会弹证书/凭据对话框（CI 里弹窗 = 永久挂住）。
$rdpText = @(
    'screen mode id:i:1'
    'use multimon:i:0'
    'desktopwidth:i:1400'
    'desktopheight:i:900'
    'session bpp:i:32'
    'compression:i:1'
    'keyboardhook:i:2'
    'audiocapturemode:i:0'
    'videoplaybackmode:i:1'
    'connection type:i:7'
    'networkautodetect:i:1'
    'bandwidthautodetect:i:1'
    'displayconnectionbar:i:1'
    'disable wallpaper:i:1'
    'allow font smoothing:i:0'
    'allow desktop composition:i:0'
    'disable full window drag:i:1'
    'disable menu anims:i:1'
    'disable themes:i:1'
    'disable cursor setting:i:0'
    'bitmapcachepersistenable:i:1'
    'full address:s:127.0.0.1'
    'audiomode:i:2'
    'redirectprinters:i:0'
    'redirectcomports:i:0'
    'redirectsmartcards:i:0'
    'redirectclipboard:i:1'
    'redirectposdevices:i:0'
    'autoreconnection enabled:i:1'
    'authentication level:i:0'
    'prompt for credentials:i:0'
    'promptcredentialonce:i:0'
    'negotiate security layer:i:1'
    'remoteapplicationmode:i:0'
    'alternate shell:s:'
    'shell working directory:s:'
    'gatewayhostname:s:'
    'gatewayusagemethod:i:4'
    'gatewaycredentialssource:i:4'
    'drivestoredirect:s:'
    "username:s:$User"
) -join "`r`n"
Set-Content -LiteralPath $rdpFile -Value $rdpText -Encoding ASCII

# ---------- 2. 存凭据（IP 与主机名各存一份，防 mstsc 归一化后查不到）----------
$targets = @("TERMSRV/127.0.0.1", "TERMSRV/localhost", "TERMSRV/$env:COMPUTERNAME")
foreach ($t in $targets) {
    cmdkey /add:$t /user:$User /pass:$Password | Out-Null
}
Write-Host "已写入凭据目标：$($targets -join ', ')"

# ---------- 3. 启动 mstsc（本进程不退出，持续轮询）----------
Write-Host "启动环回 RDP：mstsc -> 127.0.0.1（用户 $User）"
$mstscProc = Start-Process -FilePath $mstsc -ArgumentList "`"$rdpFile`"" -PassThru
Write-Host "mstsc pid=$($mstscProc.Id)"

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$graceUntil = $null          # mstsc 退出之后的观察截止时间
$ok = $false
$i = 0
while ((Get-Date) -lt $deadline) {
    $i++
    Start-Sleep -Seconds $PollIntervalSec
    if (Test-AgentDockUp) { $ok = $true; break }
    # mstsc 退出**不等于失败**：会话可能已经建好、provision 脚本正在跑。
    # 所以不立刻放弃，再给 GraceSec 秒观察窗口。
    if ($mstscProc.HasExited -and $null -eq $graceUntil) {
        Write-Warning "[$i] mstsc 已退出（exit=$($mstscProc.ExitCode)），继续观察 ${GraceSec}s"
        $graceUntil = (Get-Date).AddSeconds($GraceSec)
    }
    if ($null -ne $graceUntil -and (Get-Date) -gt $graceUntil) {
        Write-Warning "[$i] 观察窗口结束，AgentDock 仍未就绪"
        break
    }
    if ($i % 4 -eq 0) { Write-Host "[$i] 等待 AgentDock 就绪…（已等待 $($i * $PollIntervalSec)s）" }
}

# ---------- 4. 收尾 ----------
if (-not $KeepSession) {
    Get-Process -Name 'mstsc' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host '已结束 mstsc（会话转为 Disconnected，AgentDock 继续运行）'
}
foreach ($t in $targets) { cmdkey /delete:$t | Out-Null }
Remove-Item -LiteralPath $rdpFile -Force -ErrorAction SilentlyContinue

Write-Host "唤醒后会话状态："
(quser 2>&1 | Out-String).Trim()

if ($ok) {
    Write-Host "OK：AgentDock 已就绪（$healthUrl）"
    exit 0
}

# ---------- 5. 失败诊断 ----------
# 失败不该静默：把可用于判断原因的信息都打出来，同时**不影响**后续步骤
# （workflow 侧该步骤设了 continue-on-error，用户仍可人工 RDP 兜底）。
Write-Warning "超时：${TimeoutSec}s 内 AgentDock 未就绪。诊断信息："
Write-Host "  - mstsc 是否存在：$((Test-Path -LiteralPath $mstsc))"
Write-Host "  - 目标端口监听："
(netstat -ano | Select-String ":$Port" | Out-String).Trim()
Write-Host "  - AgentDock 进程："
(Get-Process -Name 'agentdock*' -ErrorAction SilentlyContinue |
    Select-Object Id, SessionId, ProcessName | Format-Table -AutoSize | Out-String).Trim()
exit 1
