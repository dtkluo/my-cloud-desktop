<#
.SYNOPSIS
    真正执行 webtor WSL Docker 部署，并把结果写进状态文件供手机端展示。

.DESCRIPTION
    由 webtor-schedule.ps1（开机勾选 / 按需命令）调用。
    本脚本只负责「执行一次 + 记状态」，去重由调用方负责。
    部署本体是可重复的 deploy-webtor.ps1：镜像/卷已存在时全部跳过。

    密码与身份透传（2026-11-24）：
      -AdminPw 必须显式传下去，否则 deploy-webtor.ps1 会随机生成一个密码，
      手机端登录就跟预期对不上；没有 webtor.env 文件时尤其容易被忽略。
      -RdpUser/-RdpPass 用于 deploy 里注册 WebtorProxy 任务 —— 那个代理进程同样要
      能看到 rdpadmin 的 WSL，否则端口转发起不来（表现为 502）。
#>
[CmdletBinding()]
param(
    [string] $WorkDir    = 'C:\webtor-auto',
    [string] $RequestId  = '',
    [string] $RunId      = '',
    [string] $StateRepo  = '',
    [string] $StatePath  = '',
    [string] $RdpUser    = 'rdpadmin',
    [string] $RdpPass    = '',
    [string] $AdminPw    = '',
    [string] $Vip        = '',
    [int]    $Port       = 8081
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

$statusFile = Join-Path $WorkDir 'status.json'
$logFile    = Join-Path $WorkDir 'deploy.log'
$scripts    = Split-Path $PSScriptRoot -Parent
$deploy     = Join-Path $PSScriptRoot 'deploy-webtor.ps1'
$publisher  = Join-Path $scripts 'publish-agentdock-state.ps1'

if (-not $Vip) { $Vip = $env:ET_VIRTUAL_IP }
if (-not $Vip) { $Vip = '192.168.110.88' }

function Write-WebtorStatus {
    param(
        [string] $State,
        [string] $Message,
        [string] $Url = '',
        [string] $Extra = ''
    )
    $obj = [ordered]@{
        state       = $State
        ok          = ($State -eq 'ready')
        url         = $Url
        message     = $Message
        request_id  = $RequestId
        run_id      = $RunId
        updated_at  = (Get-Date).ToUniversalTime().ToString('o')
        log         = $logFile
        detail      = $Extra
    }
    [IO.File]::WriteAllText($statusFile, ($obj | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    if ($StateRepo -and $env:STATE_TOKEN -and (Test-Path -LiteralPath $publisher)) {
        try {
            & $publisher -StateRepo $StateRepo -StatePath $StatePath -WebtorStateFile $statusFile | Out-Null
        } catch {
            Write-Warning "webtor 状态补推失败：$($_.Exception.Message)"
        }
    }
}

Write-WebtorStatus -State 'building' -Message 'WSL Docker 部署中（首次需拉镜像，约 3-8 分钟）'

$t0 = Get-Date
& $deploy -Port $Port -Vip $Vip -AdminPw $AdminPw -KitDir $PSScriptRoot `
    -RdpUser $RdpUser -RdpPass $RdpPass *> $logFile
$rc = $LASTEXITCODE
$mins = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)

if ($rc -eq 0) {
    $url = "http://${Vip}:$Port"
    Write-WebtorStatus -State 'ready' -Url $url `
        -Message "部署完成（${mins} 分钟）"
} else {
    $tail = ''
    if (Test-Path -LiteralPath $logFile) {
        $tail = ((Get-Content $logFile -Tail 8) -join ' | ')
    }
    Write-WebtorStatus -State 'failed' -Message "部署失败（rc=$rc）" -Extra $tail
}
exit $rc
