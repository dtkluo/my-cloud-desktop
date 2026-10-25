#requires -Version 5.1
<#
.SYNOPSIS
    把 BilldDesk 的设备码 / 连接密码同步到私有仓库状态文件，供手机端读取。

.DESCRIPTION
    取代原来的 piik 段。写入 runtime/cloud-desktop.json 的 billddesk 节点，
    同时把历史 piik 节点标成 retired（不再下发 URL，避免手机端给出死链）。

    必需环境变量：STATE_TOKEN（私有仓库 contents:write）
#>
[CmdletBinding()]
param(
    [string] $ResultFile = 'C:\billddesk-auto\billddesk.json',
    [string] $StateRepo  = 'dtkluo/agentdock-v2',
    [string] $StatePath  = 'runtime/cloud-desktop.json',
    [switch] $OnlyIfChanged
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

if (-not (Test-Path -LiteralPath $ResultFile)) {
    Write-Warning "未找到 BilldDesk 结果文件：$ResultFile"
    exit 0
}
if ([string]::IsNullOrWhiteSpace($env:STATE_TOKEN)) {
    Write-Warning '未配置 STATE_TOKEN，跳过同步。'
    exit 0
}

$r = Get-Content -LiteralPath $ResultFile -Raw | ConvertFrom-Json

$state = switch ($r.state) {
    'ready'          { 'ready' }
    'no-password'    { 'degraded' }
    'no-device-code' { 'degraded' }
    'no-window'      { 'failed' }
    'bad-rect'       { 'failed' }
    'agent-timeout'  { 'failed' }
    default          { if ($r.ok) { 'ready' } else { 'failed' } }
}

$msg = if ($state -eq 'ready') {
    'BilldDesk 已就绪（设备码 ' + $r.device_code + '，runneradmin 会话，原生 WebRTC UDP）'
} elseif ($state -eq 'degraded') {
    'BilldDesk 已启动但凭据不完整（' + $r.state + '），请查看界面'
} else {
    'BilldDesk 启动失败：' + $r.error
}

$node = [ordered]@{
    state          = $state
    device_code    = [string]$r.device_code
    device_uuid    = [string]$r.device_uuid
    password       = [string]$r.password
    kind           = 'webrtc-native'
    window         = [string]$r.window
    session        = [int]$r.session
    audio          = [bool]$r.audio
    install_dir    = [string]$r.install_dir
    message        = $msg
    updated_at     = (Get-Date).ToUniversalTime().ToString('o')
}

$api = 'https://api.github.com/repos/' + $StateRepo + '/contents/' + $StatePath
$headers = @{
    Authorization          = 'Bearer ' + $env:STATE_TOKEN
    Accept                 = 'application/vnd.github+json'
    'User-Agent'           = 'billddesk-state'
    'X-GitHub-Api-Version' = '2022-11-28'
}

function Get-Remote {
    $resp = Invoke-RestMethod -Uri ($api + '?ref=main') -Headers $headers -Method Get -TimeoutSec 30
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($resp.content -replace '\s', '')))
    return @{ sha = $resp.sha; obj = ($json | ConvertFrom-Json) }
}

$cur = Get-Remote

if ($OnlyIfChanged) {
    $old = $cur.obj.billddesk
    if ($old -and $old.device_code -eq $node.device_code -and $old.password -eq $node.password -and $old.state -eq $node.state) {
        Write-Host 'billddesk 状态无变化，跳过提交'
        exit 0
    }
}

$cur.obj | Add-Member -NotePropertyName billddesk -NotePropertyValue $node -Force
$cur.obj.updated_at = (Get-Date).ToUniversalTime().ToString('o')

# 历史 piik 段：保留字段但标记退役，避免手机端继续给出已失效的房间链接
if ($cur.obj.PSObject.Properties.Name -contains 'piik' -and $cur.obj.piik) {
    $cur.obj.piik.state = 'retired'
    $cur.obj.piik.url   = ''
    $cur.obj.piik.message = '已由 BilldDesk 取代'
}

$body = @{
    message = ('billddesk: ' + $state + ' code=' + $node.device_code)
    content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($cur.obj | ConvertTo-Json -Depth 12)))
    sha     = $cur.sha
    branch  = 'main'
} | ConvertTo-Json -Depth 6

$null = Invoke-RestMethod -Uri $api -Headers $headers -Method Put -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 45
Write-Host ('billddesk 状态已同步: state=' + $state + ' code=' + $node.device_code)
exit 0
