<#
.SYNOPSIS
    把云桌面上的 AgentDock 连接信息与「AI 助手连接提示词」同步到私有仓库，
    供手机端 workflow-controller 读取并一键复制。

.DESCRIPTION
    读取 install-agentdock.ps1 产出的 status.json，渲染与定制版控制面板
    （desktop/windows/control-panel → UiStrings.zh-CN.resx 的 AiPromptTemplate）
    完全一致的提示词，再通过 GitHub Contents API 写入私有仓库的状态文件。

    -OnlyIfChanged 用于保活轮询：先取远端状态，仅当关键字段变化时才提交，
    避免 6 小时会话里产生大量无意义提交。

.NOTES
    必需环境变量：
      STATE_TOKEN   具备私有仓库 contents:write 权限的 PAT
    可选环境变量：
      ET_VIRTUAL_IP / ET_SOCKS5_PORT / RDP_USER   随状态一起同步，供手机端展示
#>
[CmdletBinding()]
param(
    [string] $StatusFile = 'C:\agentdock-install\status.json',
    [string] $StateRepo = 'dtkluo/agentdock-v2',
    [string] $StatePath = 'runtime/cloud-desktop.json',
    [int]    $Port = 8765,
    [int]    $SessionHours = 6,
    [switch] $OnlyIfChanged
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

if (-not (Test-Path -LiteralPath $StatusFile)) {
    Write-Warning "未找到安装状态文件：$StatusFile（AgentDock 步骤可能被跳过），忽略同步。"
    exit 0
}
if ([string]::IsNullOrWhiteSpace($env:STATE_TOKEN)) {
    Write-Warning '未配置 STATE_TOKEN，无法同步连接信息到手机端。'
    exit 0
}

$status = Get-Content -LiteralPath $StatusFile -Raw | ConvertFrom-Json

# AgentDock 结果文件给出的是 origin，客户端需要 <origin>/mcp
function Normalize-McpUrl {
    param([string] $Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return '' }
    $normalized = $Url.Trim().TrimEnd('/')
    if ($normalized -notmatch '/mcp$') { $normalized = "$normalized/mcp" }
    return $normalized
}

$publicMcp = Normalize-McpUrl $status.public_mcp_url
$localMcp  = Normalize-McpUrl $status.local_mcp_url

# ---------- 运行时存活探测 ----------
$coreAlive = @(Get-Process -Name 'agentdock-core' -ErrorAction SilentlyContinue).Count -gt 0
$healthOk  = $false
try {
    Invoke-RestMethod -Uri "http://127.0.0.1:$Port/healthz" -TimeoutSec 8 | Out-Null
    $healthOk = $true
} catch {
    $healthOk = $false
}

# ---------- 渲染提示词 ----------
# 模板与定制版控制面板保持逐字一致；同步来源：
#   dtkluo/agentdock-v2 → desktop/windows/control-panel/Resources/UiStrings.zh-CN.resx → AiPromptTemplate
$promptLines = @(
    '请连接我的 AgentDock MCP（Streamable HTTP），完成握手并做好接手后续任务的准备。',
    '',
    '【连接信息】',
    'MCP 地址：{0}',
    'OAuth 密码：{1}',
    'Bearer Token：{2}',
    '认证方式：HTTP 请求头携带 Authorization: Bearer <Bearer Token>；客户端若支持 OAuth，也可用 OAuth 密码登录授权。',
    '',
    '【执行规则】',
    '1. 环境先行：连接后第一时间调用 agentdock_context，掌握真实系统环境、内置工具、Skill 索引、动态 MCP 与服务端规则，不要凭猜测行动。',
    '2. 只读优先：执行命令或检查环境前，先用只读命令查看现状；修改完成后必须重新读取或执行验证命令确认真实生效——"命令执行成功"不等于"配置已生效"。',
    '3. 任务管理：多步骤任务全程使用 task_manage 维护：create 建立目标、步骤与完成条件，形成有恢复价值的断点时 checkpoint，收尾用 final_review 复核，全部通过后再 complete。',
    '4. 动态 MCP：先 mcp_tool_search 查找能力，再 mcp_tool_inspect 读取参数 schema，确认无误后用 mcp_tool_call 执行。',
    '5. 安全边界：本机无命令沙箱、无输出内容过滤。删除、覆盖、停服务等破坏性操作必须先确认路径与影响面，能备份先备份，影响不明时先向我确认。',
    '6. 凭据保密：Bearer Token 与 OAuth 密码等同于本机完全控制权，严禁出现在公开聊天、截图、Issue、日志或代码提交中。',
    '',
    '【完成回报】',
    '连接成功后，按以下清单简要回报，然后等待我派发具体任务：',
    '1. 系统与版本（操作系统 / 架构 / AgentDock 版本）；',
    '2. 默认工作目录；',
    '3. 可用工具与 Skill 清单；',
    '4. 需要注意的服务端规则与风险。'
)

$prompt = ''
if ($publicMcp) {
    $prompt = ($promptLines -join "`n") -f $publicMcp, $status.oauth_password, $status.bearer_token
}

$easytierIp = $env:ET_VIRTUAL_IP
$socks5Port = if ($env:ET_SOCKS5_PORT) { $env:ET_SOCKS5_PORT } else { '1080' }

# GITHUB_* 由 runner 自动注入，无需从 YAML 透传
$runId     = if ($env:GITHUB_RUN_ID) { $env:GITHUB_RUN_ID } else { '' }
$runNumber = if ($env:GITHUB_RUN_NUMBER) { $env:GITHUB_RUN_NUMBER } else { '' }
$workflow  = if ($env:GITHUB_WORKFLOW) { $env:GITHUB_WORKFLOW } else { '' }

$payload = [ordered]@{
    schema     = 1
    updated_at = (Get-Date).ToUniversalTime().ToString('o')
    session    = [ordered]@{
        workflow   = $workflow
        run_id     = $runId
        run_number = $runNumber
        hours      = $SessionHours
    }
    agentdock  = [ordered]@{
        installed      = [bool] $status.success
        version        = $status.version
        tunnel_mode    = $status.tunnel_mode
        health         = $status.health
        core_alive     = $coreAlive
        healthz_ok     = $healthOk
        privilege_mode = $status.privilege_mode
        local_mcp_url  = $localMcp
        public_mcp_url = $publicMcp
        bearer_token   = $status.bearer_token
        oauth_password = $status.oauth_password
        error_code     = $status.error_code
        message        = $status.message
        installed_at   = $status.updated_at
    }
    cloud_desktop = [ordered]@{
        easytier_ip = $easytierIp
        socks5      = if ($easytierIp) { "socks5h://${easytierIp}:$socks5Port" } else { '' }
        rdp_user    = $env:RDP_USER
    }
    prompt     = $prompt
}

$org  = $StateRepo.Split('/')[0]
$name = $StateRepo.Split('/')[1]
$api  = "https://api.github.com/repos/$org/$name/contents/$StatePath"
$headers = @{
    Authorization = "Bearer $($env:STATE_TOKEN)"
    Accept        = 'application/vnd.github+json'
    'User-Agent'  = 'cloud-desktop-publisher'
}

# ---------- 读取远端现有状态 ----------
$remoteSha  = $null
$remoteJson = $null
try {
    $existing = Invoke-RestMethod -Uri $api -Headers $headers -Method Get
    $remoteSha = $existing.sha
    $remoteJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($existing.content -replace '\s', ''))) | ConvertFrom-Json
} catch {
    Write-Host "远端尚无状态文件，将首次创建：$StatePath"
}

if ($OnlyIfChanged -and $null -ne $remoteJson) {
    $unchanged = ($remoteJson.agentdock.public_mcp_url -eq $publicMcp) -and
                 ($remoteJson.agentdock.bearer_token -eq $status.bearer_token) -and
                 ($remoteJson.agentdock.core_alive -eq $coreAlive) -and
                 ($remoteJson.agentdock.healthz_ok -eq $healthOk)
    if ($unchanged) {
        Write-Host '连接信息未发生变化，跳过提交。'
        exit 0
    }
}

# ---------- 写入远端 ----------
$json = $payload | ConvertTo-Json -Depth 8
$body = [ordered]@{
    message = "chore(state): 更新云桌面连接信息（run $runNumber）"
    content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    branch  = 'main'
}
if ($remoteSha) { $body.sha = $remoteSha }

Invoke-RestMethod -Uri $api -Headers $headers -Method Put `
    -ContentType 'application/json; charset=utf-8' `
    -Body ($body | ConvertTo-Json) | Out-Null

Write-Host "已同步连接信息：https://github.com/$StateRepo/blob/main/$StatePath"
if ($publicMcp) {
    Write-Host "  公网 MCP：$publicMcp"
} else {
    Write-Warning '  公网 MCP 为空：隧道未就绪或无固定地址，手机端将无法直接连接。'
}
Write-Host "  核心进程存活：$coreAlive；/healthz：$healthOk"
