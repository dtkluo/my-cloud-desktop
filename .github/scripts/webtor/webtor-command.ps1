<#
.SYNOPSIS
    保活期间每分钟轮询一次「手机端下发的 webtor 部署命令」，命中则执行一次。

.DESCRIPTION
    命令放在状态仓库的 runtime/commands/webtor.json：
      {"action":"deploy","run_id":"<GITHUB_RUN_ID>","request_id":"<unique>","requested_at":"..."}

    三个防呆：
      1. run_id 必须与当前会话一致 —— 上一轮会话遗留的命令不会在新实例上重放；
      2. request_id 去重，写本地 last-request.txt 在**启动部署之前**，避免 1 分钟轮询重复触发；
      3. 只接 action=deploy，其他值一律忽略，后续扩展不会误执行。

    DEPLOY 用 Start-Process 拉起，不阻塞保活循环（父步骤会跑满 6 小时，子进程不会被回收）。
#>
[CmdletBinding()]
param(
    [string] $StateRepo    = 'dtkluo/agentdock-v2',
    [string] $CommandPath  = 'runtime/commands/webtor.json',
    [string] $StatePath    = 'runtime/cloud-desktop.json',
    [string] $WorkDir      = 'C:\webtor-auto',
    [string] $RdpUser      = '',
    [string] $RdpPass      = '',
    [string] $AdminPw      = '',
    [int]    $Port         = 8081
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

if (-not $RdpUser) { $RdpUser = if ($env:RDP_USER) { $env:RDP_USER } else { 'rdpadmin' } }
if (-not $RdpPass) { $RdpPass = [string]$env:RDP_PASS }
if (-not $AdminPw) { $AdminPw = [string]$env:WEBTOR_ADMIN_PW }

if ([string]::IsNullOrWhiteSpace($env:STATE_TOKEN)) { exit 0 }
$runId = [string]$env:GITHUB_RUN_ID
if (-not $runId) { exit 0 }

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$lastFile = Join-Path $WorkDir 'last-request.txt'

$parts = $StateRepo.Split('/')
if ($parts.Count -lt 2) { exit 0 }
$api = "https://api.github.com/repos/$($parts[0])/$($parts[1])/contents/$CommandPath"
$hdr = @{
    Authorization = "Bearer $($env:STATE_TOKEN)"
    Accept        = 'application/vnd.github+json'
    'User-Agent'  = 'cloud-desktop-webtor-command'
}

try {
    $res = Invoke-RestMethod -Uri $api -Headers $hdr -Method Get -TimeoutSec 15
} catch {
    # 404 = 还没有命令文件，属正常；其余仅告警，不影响云桌面
    return
}
if (-not $res -or -not $res.content) { return }

try {
    $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($res.content -replace '\s', '')))
    $cmd  = $text | ConvertFrom-Json
} catch {
    Write-Warning "webtor 命令文件解析失败：$($_.Exception.Message)"
    return
}

if ([string]$cmd.action -ne 'deploy') { return }
if ([string]$cmd.run_id -ne $runId) {
    Write-Host "webtor 命令属于 run $($cmd.run_id)，当前为 $runId，忽略（防上一轮残留重放）"
    return
}
$requestId = [string]$cmd.request_id
if (-not $requestId) { return }

$last = ''
if (Test-Path -LiteralPath $lastFile) { $last = (Get-Content $lastFile -Raw).Trim() }
if ($last -eq $requestId) { return }

# 先落去重标记，再拉起部署：即便下面的 Start-Process 失败，也不会一分钟后重复拉
[IO.File]::WriteAllText($lastFile, $requestId, (New-Object System.Text.UTF8Encoding($false)))

# 必须走计划任务，不能 Start-Process：保活 step 跑在 runneradmin 下，Start-Process
# 拉起的子进程同样是 runneradmin —— 而 WSL 发行版注册在 rdpadmin 的 HKCU 里，
# 那样部署会直接报「没有名为 Ubuntu-24.04 的发行版」。webtor-schedule.ps1 会用
# -RdpUser/-RdpPass 注册任务，身份才对；同时它也是 <3 秒返回，不阻塞保活循环。
$sched = Join-Path $PSScriptRoot 'webtor-schedule.ps1'
if (-not (Test-Path -LiteralPath $sched)) {
    Write-Warning "缺少 $sched，无法执行部署"
    return
}
Write-Host "收到 webtor 部署命令 $requestId，注册后台任务"
& $sched -WorkDir $WorkDir -RequestId $requestId -RunId $runId `
    -StateRepo $StateRepo -StatePath $StatePath `
    -RdpUser $RdpUser -RdpPass $RdpPass -AdminPw $AdminPw -Port $Port
