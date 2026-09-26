<#
.SYNOPSIS
    云桌面会话保活期间的 AgentDock 守护与连接信息同步。

.DESCRIPTION
    供长期运行步骤（EasyTier 保活循环）按固定间隔调用，做三件事：
      1. 探测 AgentDock 核心是否存活（进程 + /healthz）；
      2. 若已退出则修复 —— ⚠️ 修复方式已变更：AgentDock 现在归属**日常使用账号**
         （staged 模式），由"该用户登录时"触发的计划任务在其自己的会话里安装/启动，
         因此这里只触发那个任务，**绝不再用当前身份（runneradmin）重装**，
         否则又会把 AgentDock 装回一个主人看不到的账号里；
      3. 复检公网地址是否漂移（quick 隧道重启后 URL 会变），有变化才回写状态文件。

    任何一步失败都只告警、不中断云桌面会话。

.NOTES
    全部参数通过环境变量或下方默认值获取；未配置 AGENTDOCK_GH_TOKEN 时静默退出。
#>
[CmdletBinding()]
param(
    [string] $WorkDirectory = 'C:\agentdock-install',
    [string] $StateRepo = 'dtkluo/agentdock-v2',
    [string] $StatePath = 'runtime/cloud-desktop.json',
    [int]    $Port = 8765,
    [switch] $NoRepair
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$scripts   = $PSScriptRoot
$statusFile = Join-Path $WorkDirectory 'status.json'

if ([string]::IsNullOrWhiteSpace($env:AGENTDOCK_GH_TOKEN)) { exit 0 }
if (-not (Test-Path -LiteralPath $statusFile)) { exit 0 }
if ([string]::IsNullOrWhiteSpace($env:STATE_TOKEN)) { exit 0 }

$status = Get-Content -LiteralPath $statusFile -Raw | ConvertFrom-Json

# ---------- 1. 存活探测 ----------
# 注意：核心进程真名是 agentdock-core（历史写法 'agentdock' 永远匹配不到，
# 会让 $coreAlive 恒为 false —— 判健康请以 healthz 为准）。
$coreAlive = @(Get-Process -Name 'agentdock-core' -ErrorAction SilentlyContinue).Count -gt 0
$healthOk  = $false
try {
    Invoke-RestMethod -Uri "http://127.0.0.1:$Port/healthz" -TimeoutSec 8 | Out-Null
    $healthOk = $true
} catch {
    $healthOk = $false
}

if (-not $coreAlive -and -not $healthOk) {
    Write-Warning '检测到 AgentDock 核心已退出。'
    if ($NoRepair) {
        Write-Warning '（已指定 -NoRepair，跳过修复）'
    } else {
        $mode = ''
        $modeFile = Join-Path $WorkDirectory 'install-mode.txt'
        if (Test-Path -LiteralPath $modeFile) { $mode = (Get-Content -LiteralPath $modeFile -Raw).Trim() }

        $taskName = 'AgentDock-UserInstall'
        $taskFile = Join-Path $WorkDirectory 'provision-task-name.txt'
        if (Test-Path -LiteralPath $taskFile) {
            $fromFile = (Get-Content -LiteralPath $taskFile -Raw).Trim()
            if ($fromFile) { $taskName = $fromFile }
        }

        if ($mode -like 'staged:*') {
            $target = $mode.Substring('staged:'.Length)
            $hasSession = $false
            try {
                $q = & (Join-Path $env:SystemRoot 'System32\quser.exe') $target 2>$null
                if ($LASTEXITCODE -eq 0 -and $q) { $hasSession = $true }
            } catch { $hasSession = $false }

            if ($hasSession -and (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
                Write-Host "触发 $target 会话内的安装任务：$taskName"
                try { Start-ScheduledTask -TaskName $taskName } catch { Write-Warning "触发失败：$($_.Exception.Message)" }
            } else {
                Write-Host "AgentDock 归属 $target，但其当前没有活动会话；待其登录后由计划任务 $taskName 自动拉起。"
            }
        } else {
            # 就地模式（安装时 -TargetUser 即当前用户）→ 维持旧行为：以当前身份重装
            $version = if ($status.version) { $status.version } else { '' }
            $tunnel  = if ($status.tunnel_mode) { $status.tunnel_mode } else { 'named' }
            $public  = if ($status.public_mcp_url) { ($status.public_mcp_url -replace '/mcp$', '') } else { '' }

            Write-Host "按原参数重装：Version=$version TunnelMode=$tunnel"
            try {
                & (Join-Path $scripts 'install-agentdock.ps1') `
                    -Version $version `
                    -TunnelMode $tunnel `
                    -PublicUrl $public `
                    -Port $Port `
                    -WorkDirectory $WorkDirectory `
                    -TargetUser ''
                $status = Get-Content -LiteralPath $statusFile -Raw | ConvertFrom-Json
            } catch {
                Write-Warning "重装失败（不影响云桌面）：$($_.Exception.Message)"
            }
        }
    }
} else {
    Write-Host "AgentDock 核心存活：进程=$coreAlive  healthz=$healthOk"
}

# ---------- 2. 连接信息漂移同步 ----------
try {
    & (Join-Path $scripts 'publish-agentdock-state.ps1') `
        -StatusFile $statusFile `
        -StateRepo $StateRepo `
        -StatePath $StatePath `
        -Port $Port `
        -OnlyIfChanged
} catch {
    Write-Warning "状态同步失败（不影响云桌面）：$($_.Exception.Message)"
}

exit 0
