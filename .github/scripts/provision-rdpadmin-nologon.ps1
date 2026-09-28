<#
.SYNOPSIS
    不依赖 rdpadmin 真实登录，直接以 rdpadmin 身份跑完 AgentDock 的 provisioning。
    用于替代失败的「环回 RDP 唤醒」方案（wake-rdpadmin-session.ps1）。

.DESCRIPTION
    背景与根因（2026-09-28 实测取证）：
      AgentDock 按用户安装（%LOCALAPPDATA%\AgentDock + HKCU + DPAPI 都绑定具体用户），
      工作流步骤 5 以 staging 模式落地安装器，并注册计划任务 AgentDock-UserInstall：
          触发 = 用户登录时（LogonTrigger）
          身份 = rdpadmin，LogonType = Interactive
          动作 = powershell -File C:\agentdock-install\provision-agentdock-user.ps1
      因为 LogonType 是 Interactive，**必须有人真的登录**才会触发；
      runner 步骤跑在 runneradmin 会话里，rdpadmin 从不登录 => 永不触发。

    上一版方案是「从本机 RDP 自己」（mstsc 连 127.0.0.1）来伪造一次登录，实测失败：
      * 步骤跑满 180s 超时（= 一直没等到 AgentDock 就绪）；
      * RemoteConnectionManager/Operational 在 02:21:05-02:24:11 期间**零条** id=261
        （Listener RDP-Tcp 收到连接），也没有任何 session 仲裁 / 4624；
      * 对照实验：即使在当前**有桌面的交互式会话**里手动跑同样的环回 mstsc，
        同样零连接事件、进程随即消失 => 不是"Actions 非交互"的问题，
        而是环回 mstsc 这条路本身不成立。

    本方案的关键洞察：provision 脚本是**纯命令行**的（装 AgentDock + 拉 cloudflared，
    实测 40s），它需要的只是 **rdpadmin 的身份**，而不是一个图形会话。
    计划任务用「保存密码」方式（LogonType=Password）运行时：
      * 不需要任何用户登录；
      * Windows 会自动为该账号授予「作为批处理作业登录」；
      * profile 会加载、HKCU 可用（2026-09-28 探针实测：
        whoami=runnervm99s1a\rdpadmin、USERPROFILE=C:\Users\rdpadmin、
        HKCU\Software 可枚举、LastTaskResult=0）。
    于是我们注册一个同样动作、但 LogonType=Password 的任务并立即触发即可。

.PARAMETER Password
    rdpadmin 的密码。留空则从 -PasswordFile 读取。

.NOTES
    进程存活实证：原 LogonTrigger 任务跑完（40s）退出后，agentdock-core 与
    cloudflared 依然在跑（healthz 200）=> 任务结束不会带走子进程，可以放心收尾。
#>
[CmdletBinding()]
param(
    [string] $User = 'rdpadmin',
    [string] $Password = '',
    [string] $PasswordFile = 'C:\agentdock-install\rdp-password.txt',
    [string] $ProvisionScript = 'C:\agentdock-install\provision-agentdock-user.ps1',
    [string] $TaskName = 'AgentDock-AutoProvision',
    [int]    $Port = 8765,
    [int]    $TimeoutSec = 300,
    [int]    $PollIntervalSec = 10
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
Import-Module ScheduledTasks -ErrorAction Stop

$healthUrl = "http://127.0.0.1:$Port/healthz"
$report    = 'C:\agentdock-install\provision-report.txt'

function Test-AgentDockUp {
    try { return ((Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 5).StatusCode -eq 200) }
    catch { return $false }
}

# ---------- 0. 前置检查 ----------
if ([string]::IsNullOrWhiteSpace($Password) -and (Test-Path -LiteralPath $PasswordFile)) {
    $Password = (Get-Content -LiteralPath $PasswordFile -Raw).Trim()
}
if ([string]::IsNullOrWhiteSpace($Password)) {
    Write-Error "缺少 $User 的密码（传 -Password 或确保 $PasswordFile 存在）"
    exit 3
}
if (-not (Test-Path -LiteralPath $ProvisionScript)) {
    Write-Error "找不到 provision 脚本：$ProvisionScript"
    exit 3
}

# ---------- 0.5 幂等：已就绪就什么都不做 ----------
if (Test-AgentDockUp) {
    Write-Host "AgentDock 已就绪（$healthUrl），跳过 provisioning"
    exit 0
}

Write-Host "provisioning 前会话状态："
(quser 2>&1 | Out-String).Trim()

# ---------- 1. 注册「无需登录」的一次性任务 ----------
# 动作与 AgentDock-UserInstall 完全一致，唯一区别是身份用「保存密码」
# （LogonType=Password），因此不必等 rdpadmin 真实登录。
$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arg    = "-NoProfile -ExecutionPolicy Bypass -File `"$ProvisionScript`""
$action = New-ScheduledTaskAction -Execute $psExe -Argument $arg

Register-ScheduledTask -TaskName $TaskName -Action $action `
    -User $User -Password $Password -RunLevel Highest -Force | Out-Null

$t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Write-Host "已注册任务 $TaskName（UserId=$($t.Principal.UserId) LogonType=$($t.Principal.LogonType) RunLevel=$($t.Principal.RunLevel)）"
if ($t.Principal.LogonType -ne 'Password') {
    Write-Warning "LogonType 不是 Password（实际=$($t.Principal.LogonType)），可能仍需登录才能运行"
}

# ---------- 2. 立即触发 ----------
Start-ScheduledTask -TaskName $TaskName
Write-Host "已触发 $TaskName，开始等待 AgentDock 就绪（最多 ${TimeoutSec}s）"

# ---------- 3. 轮询 ----------
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$ok = $false
$i  = 0
while ((Get-Date) -lt $deadline) {
    $i++
    Start-Sleep -Seconds $PollIntervalSec
    if (Test-AgentDockUp) { $ok = $true; break }
    if ($i % 3 -eq 0) {
        $ti = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        Write-Host "[$i] 等待中…（已等待 $($i * $PollIntervalSec)s，任务结果=$($ti.LastTaskResult)）"
    }
}

# ---------- 4. 诊断 ----------
$ti = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
Write-Host "任务 $TaskName：LastRunTime=$($ti.LastRunTime) LastTaskResult=$($ti.LastTaskResult)"
Write-Host "provisioning 后会话状态："
(quser 2>&1 | Out-String).Trim()
if (Test-Path -LiteralPath $report) {
    Write-Host "--- provision-report.txt ---"
    (Get-Content -LiteralPath $report -Raw -ErrorAction SilentlyContinue).Trim()
}
Write-Host "--- 进程 ---"
(Get-Process -Name 'agentdock*', 'cloudflared' -ErrorAction SilentlyContinue |
    Select-Object Id, SessionId, ProcessName | Format-Table -AutoSize | Out-String).Trim()

# ---------- 5. 收尾：注销一次性任务（避免把 rdpadmin 密码留在任务里）----------
# 实证：任务结束不会带走它启动的 agentdock-core / cloudflared，可以安全注销。
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "已注销一次性任务 $TaskName"

if ($ok) {
    Write-Host "OK：AgentDock 已就绪（$healthUrl）"
    exit 0
}

Write-Warning "超时：${TimeoutSec}s 内 AgentDock 未就绪。"
Write-Host "回退方案：仍需人工 RDP 登录一次 $User（或用本机的 rdp_wake.py 免密唤醒）。"
exit 1
