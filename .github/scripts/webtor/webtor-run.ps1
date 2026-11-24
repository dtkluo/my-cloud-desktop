<#
.SYNOPSIS
    真正执行 webtor WSL Docker 热部署，并把结果写进状态文件供手机端展示。

.DESCRIPTION
    由 webtor-schedule.ps1（开机勾选）或 webtor-command.ps1（按需命令）调用。
    本脚本只负责「执行一次 + 记状态」，去重由调用方负责。
    部署本体是可重复的 deploy-webtor.ps1：镜像/卷已存在时全部跳过，实测 0.4 分钟。

.NOTES
    STATE_TOKEN 必须存在（部署完会立刻补推一次状态到手机端）。
#>
[CmdletBinding()]
param(
    [string] $WorkDir    = 'C:\webtor-auto',
    [string] $RequestId  = '',
    [string] $RunId      = '',
    [string] $StateRepo  = '',
    [string] $StatePath  = ''
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

$statusFile = Join-Path $WorkDir 'status.json'
$logFile    = Join-Path $WorkDir 'deploy.log'
$scripts    = Split-Path $PSScriptRoot -Parent
$deploy     = Join-Path $PSScriptRoot 'deploy-webtor.ps1'
$publisher  = Join-Path $scripts 'publish-agentdock-state.ps1'

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
    # 每次状态变化都补推一次，手机端 30 秒轮询即可看到，不必等下一分钟保活同步
    if ($StateRepo -and $env:STATE_TOKEN -and (Test-Path -LiteralPath $publisher)) {
        try {
            & $publisher -StateRepo $StateRepo -StatePath $StatePath -WebtorStateFile $statusFile | Out-Null
        } catch {
            Write-Warning "webtor 状态补推失败：$($_.Exception.Message)"
        }
    }
}

Write-WebtorStatus -State 'building' -Message 'WSL Docker 热部署中（首次约 2-3 分钟）'

$t0 = Get-Date
& $deploy *> $logFile
$rc = $LASTEXITCODE
$mins = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)

if ($rc -eq 0) {
    $url = "http://192.168.110.88:8081"
    Write-WebtorStatus -State 'ready' -Url $url `
        -Message "部署完成（${mins} 分钟，登录页 HTTP 200）"
} else {
    $tail = ''
    if (Test-Path -LiteralPath $logFile) {
        $tail = ((Get-Content $logFile -Tail 8) -join ' | ')
    }
    Write-WebtorStatus -State 'failed' -Message "部署失败（rc=$rc）" -Extra $tail
}
exit $rc
