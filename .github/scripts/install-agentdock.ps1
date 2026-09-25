<#
.SYNOPSIS
    在云桌面（GitHub Actions windows runner）启动后，静默安装并启动定制版 AgentDock。

.DESCRIPTION
    定制版 AgentDock 位于私有仓库 dtkluo/agentdock-v2 的 Release 中，产物为：
      - agentdock_windows_amd64.zip（离线载荷，约 88 MB）
      - agentdock_windows_amd64.zip.sha256
      - install.ps1（上游安装脚本，支持 -InstallChannel script 静默通道）
    本脚本负责：解析 release -> 带 token 下载 -> SHA256 校验 -> 调用 install.ps1
    -> 解析结果文件 -> 输出统一的状态 JSON 供后续步骤与手机端消费。

    为什么走 -InstallChannel script 而不是 setup：
      install.ps1 只在 InstallChannel=setup 时校验「交互式桌面会话」，Actions runner
      的步骤进程不具备该上下文；script 通道无此校验，可完全静默执行。

.NOTES
    必需环境变量：
      AGENTDOCK_GH_TOKEN       具备读取私有 release 权限的 PAT
    可选环境变量：
      AGENTDOCK_TUNNEL_TOKEN   named 模式必需（cloudflared tunnel token）
      AGENTDOCK_AUTH_TOKEN     固定 Bearer Token（不传则每次随机）
      AGENTDOCK_OAUTH_PASSWORD 固定 OAuth 登录密码（不传则每次随机）
    named 模式的公网地址：-PublicUrl 缺省即用内置的云桌面专属固定域名，
      无需额外配置；如需换域名再显式传入覆盖。
    输出：
      <WorkDirectory>\status.json   安装结果（含凭据，仅本机/私有仓库可见）
#>
[CmdletBinding()]
param(
    [string] $AgentDockRepo = 'dtkluo/agentdock-v2',
    [string] $Version = 'v0.8.3-dev4',
    [int]    $Port = 8765,
    [ValidateSet('named', 'quick', 'none')]
    [string] $TunnelMode = 'named',
    [string] $PublicUrl = '',
    [string] $WorkDirectory = 'C:\agentdock-install'
)

# 云桌面专属固定域名。定制版 AgentDock 的安装向导（packaging/windows/includes/code.iss
# 的 DefaultNamedServerUrl）与 Cloudflare Tunnel 均绑定此域名，其他设备（含本机）不使用，
# 因此不存在多个 cloudflared 副本连同一 tunnel 导致请求落错节点的问题。
$defaultPublicUrl = 'https://agent.yundn.dpdns.org'

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$work = $WorkDirectory
New-Item -ItemType Directory -Path $work -Force | Out-Null
$statusFile = Join-Path $work 'status.json'

function Write-Status {
    param([hashtable] $Status)
    $Status['updated_at'] = (Get-Date).ToUniversalTime().ToString('o')
    $Status | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statusFile -Encoding utf8
}

function Write-Summary {
    param([string] $Markdown)
    if ($env:GITHUB_STEP_SUMMARY) {
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $Markdown -Encoding utf8
    }
}

if ([string]::IsNullOrWhiteSpace($env:AGENTDOCK_GH_TOKEN)) {
    Write-Warning '未配置 AGENTDOCK_GH_TOKEN，跳过 AgentDock 安装（需具备读取私有仓库 release 的权限）。'
    Write-Status @{
        stage          = 'skipped'
        success        = $false
        error_code     = 'missing-token'
        message        = '未配置 AGENTDOCK_GH_TOKEN，已跳过安装'
    }
    exit 0
}

$owner = $AgentDockRepo.Split('/')[0]
$repo  = $AgentDockRepo.Split('/')[1]
$curl  = Join-Path $env:SystemRoot 'System32\curl.exe'
$headers = @{
    Authorization = "Bearer $($env:AGENTDOCK_GH_TOKEN)"
    Accept        = 'application/vnd.github+json'
    'User-Agent'  = 'cloud-desktop-setup'
}

# ---------- 1. 解析 release ----------
$apiUrl = if ($Version -eq 'latest') {
    "https://api.github.com/repos/$owner/$repo/releases/latest"
} else {
    "https://api.github.com/repos/$owner/$repo/releases/tags/$Version"
}
$release = Invoke-RestMethod -Uri $apiUrl -Headers $headers
Write-Host "定制版 AgentDock：$($release.tag_name)（发布于 $($release.published_at)）"

# ---------- 2. 下载资产 ----------
function Save-ReleaseAsset {
    param([string] $Name, [string] $Destination)

    $asset = $release.assets | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if (-not $asset) { throw "release $($release.tag_name) 中缺少资产：$Name" }

    $url = "https://api.github.com/repos/$owner/$repo/releases/assets/$($asset.id)"
    & $curl -sSL --fail --retry 3 --retry-delay 2 `
        -H "Authorization: Bearer $($env:AGENTDOCK_GH_TOKEN)" `
        -H 'Accept: application/octet-stream' `
        -H 'User-Agent: cloud-desktop-setup' `
        -o $Destination $url
    if ($LASTEXITCODE -ne 0) { throw "下载 $Name 失败（curl exit=$LASTEXITCODE）" }

    $size = [math]::Round((Get-Item -LiteralPath $Destination).Length / 1MB, 1)
    Write-Host "已下载 $Name（$size MB）"
}

$zipPath       = Join-Path $work 'agentdock_windows_amd64.zip'
$checksumPath  = Join-Path $work 'agentdock_windows_amd64.zip.sha256'
$installerPath = Join-Path $work 'install.ps1'

Save-ReleaseAsset -Name 'agentdock_windows_amd64.zip'        -Destination $zipPath
Save-ReleaseAsset -Name 'agentdock_windows_amd64.zip.sha256' -Destination $checksumPath
Save-ReleaseAsset -Name 'install.ps1'                        -Destination $installerPath

# ---------- 3. SHA256 校验 ----------
$expected = ((Get-Content -LiteralPath $checksumPath -Raw) -split '\s+')[0].Trim().ToLowerInvariant()
$actual   = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($expected -ne $actual) { throw "SHA256 校验失败：期望 $expected，实际 $actual" }
Write-Host 'OK：离线包 SHA256 校验通过'

# ---------- 4. 组装安装参数 ----------
$resultFile = Join-Path $work 'result.ini'
Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue

$installArgs = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installerPath,
    '-InstallChannel', 'script',
    '-OfflineArchive', $zipPath,
    '-OfflineChecksumFile', $checksumPath,
    '-Port', "$Port",
    '-TunnelMode', $TunnelMode,
    '-RegisterStartup',
    '-ResultFile', $resultFile
)

if ($TunnelMode -ne 'none') {
    $installArgs += '-ConfigurePublicAccess'
}

if ($TunnelMode -eq 'named') {
    if ([string]::IsNullOrWhiteSpace($env:AGENTDOCK_TUNNEL_TOKEN)) {
        throw 'named 模式需要 AGENTDOCK_TUNNEL_TOKEN（Cloudflare Tunnel Token）'
    }
    # 未传 -PublicUrl 或显式传空串（保活重装时状态里可能没有公网地址）都回落到内置
    # 默认域名。若放任为空，install.ps1 会走 Read-Host 交互分支，在 CI 里挂死。
    if ([string]::IsNullOrWhiteSpace($PublicUrl)) { $PublicUrl = $defaultPublicUrl }
    # Tunnel Token 走文件而非命令行，避免出现在进程列表与日志中
    $tokenFile = Join-Path $work 'tunnel.token'
    [IO.File]::WriteAllText($tokenFile, $env:AGENTDOCK_TUNNEL_TOKEN, [Text.UTF8Encoding]::new($false))
    $installArgs += @('-ServerUrl', $PublicUrl, '-TunnelTokenFile', $tokenFile, '-DeleteTunnelTokenFile')
}

if (-not [string]::IsNullOrWhiteSpace($env:AGENTDOCK_AUTH_TOKEN)) {
    $installArgs += @('-AuthToken', $env:AGENTDOCK_AUTH_TOKEN)
}
if (-not [string]::IsNullOrWhiteSpace($env:AGENTDOCK_OAUTH_PASSWORD)) {
    $installArgs += @('-OAuthPassword', $env:AGENTDOCK_OAUTH_PASSWORD)
}

# ---------- 5. 静默安装 ----------
# 安装器真实调用路径是 Windows PowerShell 5.1（脚本要求纯 ASCII 与 5.1 语法）
$winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
Write-Host "开始静默安装：install.ps1 -InstallChannel script -TunnelMode $TunnelMode -RegisterStartup -Port $Port"
$installExit = 0
try {
    & $winPs @installArgs
    $installExit = $LASTEXITCODE
} catch {
    Write-Warning "install.ps1 执行异常：$($_.Exception.Message)"
    $installExit = -1
}
Write-Host "install.ps1 退出码：$installExit"

# ---------- 6. 解析结果 ----------
$kv = @{}
if (Test-Path -LiteralPath $resultFile) {
    foreach ($line in ((Get-Content -LiteralPath $resultFile -Raw) -split "`r?`n")) {
        if ($line -match '^\s*([A-Za-z]+)\s*=\s*(.*)$') { $kv[$Matches[1]] = $Matches[2].Trim() }
    }
}

function Get-Value {
    param([string] $Key)
    if ($kv.ContainsKey($Key)) { return $kv[$Key] }
    return ''
}

$status = @{
    stage          = 'installed'
    success        = ((Get-Value 'Success') -eq 'true')
    error_code     = Get-Value 'Code'
    message        = Get-Value 'Message'
    warning_code   = Get-Value 'WarningCode'
    warning        = Get-Value 'WarningMessage'
    version        = Get-Value 'Version'
    local_mcp_url  = (Get-Value 'LocalMCPUrl')
    public_mcp_url = (Get-Value 'PublicMCPUrl').TrimEnd('/')
    bearer_token   = Get-Value 'BearerToken'
    oauth_password = Get-Value 'OAuthPassword'
    health         = Get-Value 'Health'
    privilege_mode = Get-Value 'PrivilegeMode'
    tunnel_mode    = $TunnelMode
    install_exit   = $installExit
}
Write-Status -Status $status

$visible = $status.GetEnumerator() | Where-Object { $_.Key -notin @('bearer_token', 'oauth_password') }
Write-Host 'AgentDock 安装结果：'
foreach ($item in $visible) { Write-Host ("  {0} = {1}" -f $item.Key, $item.Value) }

if ($status.success) {
    $publicLine = if ($status.public_mcp_url) { "公网 MCP：$($status.public_mcp_url)" } else { '公网 MCP：（未启用隧道）' }
    Write-Summary @"
## AgentDock 已安装并启动

- 版本：$($status.version)
- 本地 MCP：$($status.local_mcp_url)
- $publicLine
- 隧道模式：$TunnelMode
- 健康状态：$($status.health)

凭据已写入 `status.json`，由后续步骤同步到私有仓库供手机端读取。
"@
} else {
    Write-Warning "AgentDock 安装未成功：$($status.error_code) $($status.message)"
    Write-Summary @"
## AgentDock 安装未成功

- 阶段错误码：`$($status.error_code)`
- 说明：$($status.message)
- install.ps1 退出码：$installExit

云桌面（RDP / EasyTier）不受影响，可照常使用。
"@
}
