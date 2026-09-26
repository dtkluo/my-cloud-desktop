<#
.SYNOPSIS
    云桌面（GitHub Actions windows runner）启动后，静默部署定制版 AgentDock 到「日常使用账号」。

.DESCRIPTION
    定制版 AgentDock 位于私有仓库 dtkluo/agentdock-v2 的 Release 中，产物为：
      - agentdock_windows_amd64.zip（离线载荷，约 88 MB）
      - agentdock_windows_amd64.zip.sha256
      - install.ps1（上游安装脚本，支持 -InstallChannel script 静默通道）
    本脚本负责：解析 release -> 带 token 下载 -> SHA256 校验 -> 部署 -> 解析结果文件
    -> 输出统一的状态 JSON 供后续步骤与手机端消费。

    ⚠️ 为什么默认走 staged（暂存 + 登录触发）而不是就地安装：
      AgentDock 是**纯用户级**安装 —— 程序落在 %LOCALAPPDATA%\AgentDock、自启写
      HKCU\Run、凭据是 DPAPI 文件（绑定当前 Windows 用户）。「装进哪个账号」完全取决于
      **以谁的身份跑 install.ps1**。而本工作流的步骤进程以 runneradmin（runner 服务账号）
      身份执行，主人日常 RDP 登录的是另一个账号（默认 rdpadmin）—— 直接就地安装会把
      AgentDock 装进一个主人看不见、用不上的账号里（历史事故）。
      注意：跨用户直接拷贝安装目录**无效**（DPAPI 凭据解不开）。

      staged 流程：
        1. 下载并校验离线载荷；
        2. 把安装参数、隧道令牌、服务地址**暂存**到 WorkDirectory（ACL 收紧至
           Administrators + 目标用户）；
        3. 注册一个「目标用户登录时」触发的计划任务（主体 Interactive ⇒ 进程跑在
           **该用户自己的会话里**，无需密码、也无需其当前已登录），由
           provision-agentdock-user.ps1 完成安装与启动；
        4. 若目标用户此刻已有活动会话，立即触发一次；
        5. 写一份**预期值**的 status.json（health=pending-logon），使第 6 步同步给手机端
           的连接提示词在开机阶段就可用（Bearer Token 是固定 secret，与谁在跑无关）。

    -TargetUser 传空串或等于当前用户即回到旧行为（就地安装，供排查/兼容用）。

    为什么走 -InstallChannel script 而不是 setup：
      install.ps1 只在 InstallChannel=setup 时校验「交互式桌面会话」，Actions runner
      的步骤进程不具备该上下文；script 通道无此校验，可完全静默执行。

.NOTES
    必需环境变量：
      AGENTDOCK_GH_TOKEN       具备读取私有 release 权限的 PAT
    可选环境变量：
      AGENTDOCK_TUNNEL_TOKEN   named 模式必需（cloudflared tunnel token）
      AGENTDOCK_AUTH_TOKEN     固定 Bearer Token（不传则本次生成并固化到暂存文件）
      AGENTDOCK_OAUTH_PASSWORD 固定 OAuth 登录密码（同上）
      RDP_USER                 目标账号名；若工作流透传则**优先于** -TargetUser
    named 模式的公网地址：-PublicUrl 缺省即用内置的云桌面专属固定域名，
      无需额外配置；如需换域名再显式传入覆盖。
    输出：
      <WorkDirectory>\status.json   安装结果（含凭据，仅本机/私有仓库可见）
      <WorkDirectory>\rdpadmin-stage.ini / tunnel.token / named-server-url.txt / install-mode.txt
#>
[CmdletBinding()]
param(
    [string] $AgentDockRepo = 'dtkluo/agentdock-v2',
    [string] $Version = 'v0.8.3-dev4',
    [int]    $Port = 8765,
    [ValidateSet('named', 'quick', 'none')]
    [string] $TunnelMode = 'named',
    [string] $PublicUrl = '',
    [string] $WorkDirectory = 'C:\agentdock-install',
    # 目标账号（主人日常 RDP 使用的账号）。传空串或等于当前用户即退回就地安装。
    [string] $TargetUser = 'rdpadmin',
    [string] $TaskName = 'AgentDock-UserInstall'
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
$currentUser = $env:USERNAME

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

function Get-AgentDockTunnelLogs {
    <#
      收集 cloudflared 的原始日志。
      背景：tunnel start 失败时 agentdock.exe 只把日志尾部 2048 字节经 result.ini
      回传，而多行值会被上方按行解析的 INI 读取逻辑截断，最终往往只剩一行，
      不足以定位（例如「Named Tunnel 未在 45s 内注册连接」就丢掉了全部上下文）。
      这里直接读取落盘日志写入 job summary，保证下一次会话能拿到一手证据。
      cloudflared 日志位置：<runtime-root>\cloudflared.{err,out}.log
    #>
    param([int] $MaxBytes = 16384)

    $bases = @()
    foreach ($base in @($env:LOCALAPPDATA, $env:ProgramData, $env:USERPROFILE)) {
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        $candidate = Join-Path $base 'AgentDock'
        if (Test-Path -LiteralPath $candidate) { $bases += $candidate }
    }
    if ($bases.Count -eq 0) { return '' }

    $secrets = @($env:AGENTDOCK_TUNNEL_TOKEN, $env:AGENTDOCK_AUTH_TOKEN,
                 $env:AGENTDOCK_OAUTH_PASSWORD, $env:AGENTDOCK_GH_TOKEN) |
               Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $sb = [System.Text.StringBuilder]::new()
    foreach ($root in $bases) {
        foreach ($name in @('cloudflared.err.log', 'cloudflared.out.log')) {
            $files = @(Get-ChildItem -LiteralPath $root -Recurse -Filter $name -File -ErrorAction SilentlyContinue)
            foreach ($f in $files) {
                [void]$sb.AppendLine("##### $($f.FullName)  ($($f.Length) 字节) #####")
                try {
                    $text = Get-Content -LiteralPath $f.FullName -Raw -Encoding utf8 -ErrorAction Stop
                    if (-not $text) { $text = '(空)' }
                    if ($text.Length -gt $MaxBytes) {
                        $text = '...[已裁剪前部]...' + "`n" + $text.Substring($text.Length - $MaxBytes)
                    }
                    foreach ($secret in $secrets) {
                        $text = $text -replace [regex]::Escape($secret), '<redacted>'
                    }
                    [void]$sb.AppendLine($text.TrimEnd())
                } catch {
                    [void]$sb.AppendLine("(读取失败：$($_.Exception.Message))")
                }
            }
        }
    }
    return $sb.ToString().Trim()
}

function Protect-ForUser {
    # 把含凭据的暂存文件 ACL 收紧到「Administrators + 目标用户」，避免同机其他账号可读。
    param([string] $Path, [string] $User)
    try {
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRule($rule) | Out-Null }
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule('BUILTIN\Administrators', 'FullControl', 'Allow')))
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($User, 'FullControl', 'Allow')))
        Set-Acl -LiteralPath $Path -AclObject $acl
        return 'ok'
    } catch {
        return "failed: $($_.Exception.Message)"
    }
}

function Resolve-DailyDriverUser {
    <#
      解析「AgentDock 该装进哪个账号」。返回空串表示「就地安装（当前用户）」。
        1) 候选为空串、或等于当前用户 → 调用方**明确**要求就地安装，直接返回空串，
           不做任何发现（保活脚本的就地分支依赖这个语义）。
        2) 候选账号在本机存在 → 用它。
        3) 候选账号不存在（如 RDP_USERNAME secret 改了名，参数里的默认值落空）
           → 自动发现：本地 Administrators 组里的「非内置、非当前用户、非 runner
             服务账号」用户。有这层兜底，不至于把 AgentDock 装错地方或静默装回 runneradmin。
        4) 仍找不到 → 空串（退回就地安装）。
    #>
    param([string] $Candidate, [string] $CurrentUser)

    if ([string]::IsNullOrWhiteSpace($Candidate) -or ($Candidate -eq $CurrentUser)) { return '' }
    if (Get-LocalUser -Name $Candidate -ErrorAction SilentlyContinue) { return $Candidate }

    Write-Warning "指定的目标用户 $Candidate 在本机不存在，尝试自动发现本地管理员账号。"

    $skip = @('Administrator', 'DefaultAccount', 'Guest', 'WDAGUtilityAccount',
              'DefaultUser', 'sshd', 'runneradmin')
    try {
        $adminGroup = (Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop).Name
        foreach ($member in @(Get-LocalGroupMember -Group $adminGroup -ErrorAction Stop)) {
            if ($member.ObjectClass -ne 'User') { continue }
            $name = ($member.Name -split '\\')[-1]
            if ($name -eq $CurrentUser) { continue }
            if ($skip -contains $name) { continue }
            if (Get-LocalUser -Name $name -ErrorAction SilentlyContinue) {
                Write-Host "自动发现日常使用账号：$name（本地管理员组成员）"
                return $name
            }
        }
    } catch {
        Write-Warning "自动发现账号失败：$($_.Exception.Message)"
    }
    return ''
}

# 顶层兜底：任何未处理异常（release 404、资产下载失败、网络中断等）都必须落一份
# 可见的失败状态。否则状态文件会停留在上一次会话的旧值，手机端表现为「一切正常」，
# 而实际链路早已失效——这是最难排查的一类故障。
trap {
    try {
        $trapMessage = $_.Exception.Message
        Write-Warning "安装流程异常终止：$trapMessage"
        Write-Status @{
            stage             = 'failed'
            success           = $false
            error_code        = 'unhandled-exception'
            message           = $trapMessage
            requested_version = $Version
            tunnel_mode       = $TunnelMode
            install_exit      = -1
        }
        $trapLines = @(
            ''
            '## AgentDock 安装流程异常终止'
            ''
            "- 请求版本：``$Version``"
            "- 隧道模式：$TunnelMode"
            "- 目标用户：$TargetUser"
            "- 异常信息：$trapMessage"
        )
        $trapLogs = Get-AgentDockTunnelLogs
        if ($trapLogs) { $trapLines += @('', '```text', $trapLogs, '```') }
        Write-Summary ($trapLines -join "`n")
    } catch {
        Write-Warning "记录失败状态时再次出错：$($_.Exception.Message)"
    }
    exit 0
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
# 注意：dtkluo/agentdock-v2 的 release 全部标记为 prerelease，GitHub 的
# /releases/latest 只返回「最新的非 prerelease」，在本仓库必然 404。
# 因此 'latest' 走列表接口显式取首项（含 prerelease）；同时把解析出的真实
# tag 写进状态文件，避免保活重装拿到字面量 'latest' 再次 404。
if ([string]::IsNullOrWhiteSpace($Version) -or $Version -in @('latest', 'auto')) {
    $releaseList = Invoke-RestMethod -Uri "https://api.github.com/repos/$owner/$repo/releases?per_page=1" -Headers $headers
    if (-not $releaseList -or @($releaseList).Count -eq 0) {
        throw "仓库 $AgentDockRepo 没有任何 release（含 prerelease）"
    }
    $release = @($releaseList)[0]
} else {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$owner/$repo/releases/tags/$Version" -Headers $headers
}
$resolvedVersion = [string] $release.tag_name
Write-Host "定制版 AgentDock：$resolvedVersion（发布于 $($release.published_at)）"

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

# ---------- 4. 凭据与服务地址（就地与 staged 共用） ----------
# 凭据优先取环境变量；未提供则本次生成并固化到暂存文件，保证「同一次部署」内部一致。
$authToken = $env:AGENTDOCK_AUTH_TOKEN
if ([string]::IsNullOrWhiteSpace($authToken)) {
    $authToken = -join (1..64 | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
    Write-Host '未提供 AGENTDOCK_AUTH_TOKEN，本次生成 64 位十六进制令牌并固化到暂存文件。'
}
$oauthPassword = $env:AGENTDOCK_OAUTH_PASSWORD
if ([string]::IsNullOrWhiteSpace($oauthPassword)) {
    $oauthPassword = -join (1..32 | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
    Write-Host '未提供 AGENTDOCK_OAUTH_PASSWORD，本次生成 32 位十六进制密码并固化到暂存文件。'
}

# 未传 -PublicUrl 或显式传空串（保活重装时状态里可能没有公网地址）都回落到内置默认域名。
# 若放任为空，install.ps1 会走 Read-Host 交互分支，在 CI 里挂死。
if ([string]::IsNullOrWhiteSpace($PublicUrl)) { $PublicUrl = $defaultPublicUrl }
$PublicUrl = $PublicUrl.TrimEnd('/')

# Tunnel Token 走文件而非命令行，避免出现在进程列表与日志中
$tunnelTokenFile = Join-Path $work 'tunnel.token'
if ($TunnelMode -eq 'named') {
    if ([string]::IsNullOrWhiteSpace($env:AGENTDOCK_TUNNEL_TOKEN)) {
        throw 'named 模式需要 AGENTDOCK_TUNNEL_TOKEN（Cloudflare Tunnel Token）'
    }
    [IO.File]::WriteAllText($tunnelTokenFile, $env:AGENTDOCK_TUNNEL_TOKEN, [Text.UTF8Encoding]::new($false))
} elseif (Test-Path -LiteralPath $tunnelTokenFile) {
    Remove-Item -LiteralPath $tunnelTokenFile -Force -ErrorAction SilentlyContinue
}

# ---------- 5. 分流：就地安装（旧行为） 还是 暂存 + 登录触发 ----------
$candidate = $TargetUser
if (-not [string]::IsNullOrWhiteSpace($env:RDP_USER)) {
    $candidate = $env:RDP_USER.Trim()
    Write-Host "目标用户取自环境变量 RDP_USER：$candidate"
}
$TargetUser = Resolve-DailyDriverUser -Candidate $candidate -CurrentUser $currentUser
$staged = -not [string]::IsNullOrWhiteSpace($TargetUser)

if (-not $staged) {
    # ================= 就地安装（旧行为 / staged 的兜底） =================
    Write-Host "未找到可用的其他本地账号，退回就地安装（当前用户 $currentUser）。"

    # ---------- 6. 组装安装参数（就地） ----------
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
        $installArgs += @('-ServerUrl', $PublicUrl, '-TunnelTokenFile', $tunnelTokenFile, '-DeleteTunnelTokenFile')
    }

    $installArgs += @('-AuthToken', $authToken, '-OAuthPassword', $oauthPassword)

    # ---------- 7. 静默安装（就地） ----------
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

    # ---------- 8. 解析结果（就地） ----------
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
        version        = $resolvedVersion
        engine_version = Get-Value 'Version'
        local_mcp_url  = (Get-Value 'LocalMCPUrl')
        public_mcp_url = (Get-Value 'PublicMCPUrl').TrimEnd('/')
        bearer_token   = Get-Value 'BearerToken'
        oauth_password = Get-Value 'OAuthPassword'
        health         = Get-Value 'Health'
        privilege_mode = Get-Value 'PrivilegeMode'
        tunnel_mode    = $TunnelMode
        install_exit   = $installExit
        target_user    = $currentUser
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
- 安装账号：$currentUser（就地模式）
- 本地 MCP：$($status.local_mcp_url)
- $publicLine
- 隧道模式：$TunnelMode
- 健康状态：$($status.health)

凭据已写入 `status.json`，由后续步骤同步到私有仓库供手机端读取。
"@
    } else {
        Write-Warning "AgentDock 安装未成功：$($status.error_code) $($status.message)"

        # agentdock 回传给 result.ini 的 message 只保留了 cloudflared 日志尾部的一行
        # （INI 按行解析会截断多行值），不足以定位失败原因；这里把落盘日志原文补上。
        $tunnelLogs = Get-AgentDockTunnelLogs
        $summaryLines = @(
            ''
            '## AgentDock 安装未成功'
            ''
            "- 请求版本：``$Version``"
            "- 解析版本：``$resolvedVersion``"
            "- 阶段错误码：``$($status.error_code)``"
            "- install.ps1 退出码：$installExit"
            "- 隧道模式：$TunnelMode"
            ''
            '### agentdock 回传的 message'
            ''
            '```text'
            $status.message
            '```'
        )
        if ($tunnelLogs) {
            $summaryLines += @('', '### cloudflared 原始日志', '', '```text', $tunnelLogs, '```')
        }
        $summaryLines += @('', '云桌面（RDP / EasyTier）不受影响，可照常使用。')
        Write-Summary ($summaryLines -join "`n")
    }
    exit 0
}

# ================= staged 模式：暂存 + 目标用户登录时安装 =================
Write-Host "暂存模式：AgentDock 将安装到 $TargetUser，并在其登录会话内启动。"

# 9.1 暂存安装参数（供目标用户会话内的 provision 脚本读取）
$stageIni = Join-Path $work 'rdpadmin-stage.ini'
$stageLines = @(
    '[Stage]'
    "TargetUser=$TargetUser"
    "Port=$Port"
    "TunnelMode=$TunnelMode"
    "ServerUrl=$PublicUrl"
    "BearerToken=$authToken"
    "OAuthPassword=$oauthPassword"
    "Version=$resolvedVersion"
)
Set-Content -LiteralPath $stageIni -Value ($stageLines -join "`r`n") -Encoding utf8
Set-Content -LiteralPath (Join-Path $work 'named-server-url.txt') -Value $PublicUrl -Encoding utf8
Set-Content -LiteralPath (Join-Path $work 'install-mode.txt') -Value "staged:$TargetUser" -Encoding utf8
Set-Content -LiteralPath (Join-Path $work 'provision-task-name.txt') -Value $TaskName -Encoding utf8

# 9.2 把 provision 脚本本体拷进暂存目录（runner 的 checkout 随时可能被清理，
#     而目标用户可能要过很久才登录）
$provisionSource = Join-Path $PSScriptRoot 'provision-agentdock-user.ps1'
if (-not (Test-Path -LiteralPath $provisionSource)) {
    throw "缺少 provision 脚本：$provisionSource"
}
$provisionTarget = Join-Path $work 'provision-agentdock-user.ps1'
Copy-Item -LiteralPath $provisionSource -Destination $provisionTarget -Force
Write-Host "已暂存 provision 脚本：$provisionTarget"

# 9.3 收紧含密文件的 ACL（仅 Administrators 与目标用户可读）
foreach ($secretFile in @($stageIni, $tunnelTokenFile, $provisionTarget)) {
    if (Test-Path -LiteralPath $secretFile) {
        Write-Host ("  ACL $([IO.Path]::GetFileName($secretFile)) -> " + (Protect-ForUser -Path $secretFile -User $TargetUser))
    }
}

# 9.4 注册「目标用户登录时」触发的计划任务（主体 Interactive：进程跑在**该用户自己的会话**里，
#     无需密码、无需其已登录 —— 这正是「装进主人日常账号」的关键）
$winPsPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action = New-ScheduledTaskAction -Execute $winPsPath `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -File "' + $provisionTarget + '"')
$principal = New-ScheduledTaskPrincipal -UserId $TargetUser -LogonType Interactive -RunLevel Highest
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $TargetUser
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal `
    -Trigger $trigger -Settings $settings -Force | Out-Null
Write-Host "已注册计划任务：$TaskName（用户 $TargetUser 登录时触发）"

$registered = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$taskOk = $null -ne $registered
$principalUser = if ($taskOk) { $registered.Principal.UserId } else { '' }
Write-Host "  任务主体：$principalUser / $($registered.Principal.LogonType) / $($registered.Principal.RunLevel)"

# 9.5 目标用户此刻已有活动会话 → 立即触发一次（正常情况下开机时他还没登录）
$sessionActive = $false
try {
    $q = & (Join-Path $env:SystemRoot 'System32\quser.exe') $TargetUser 2>$null
    if ($LASTEXITCODE -eq 0 -and $q) { $sessionActive = $true }
} catch { $sessionActive = $false }
if ($sessionActive) {
    Write-Host "$TargetUser 已有活动会话，立即触发安装任务。"
    Start-ScheduledTask -TaskName $TaskName
} else {
    Write-Host "$TargetUser 当前没有活动会话：等待其 RDP 登录后自动安装并启动。"
}

# 9.6 写预期值的 status.json —— 让第 6 步能把可用的连接信息同步给手机端
#     （Bearer Token 来自固定 secret，与谁在跑无关，所以开机阶段即可用）
$publicMcpUrl = if ($TunnelMode -ne 'none') { $PublicUrl } else { '' }
Write-Status -Status @{
    stage            = 'staged'
    success          = $true
    error_code       = ''
    message          = if ($sessionActive) { "已触发 $TargetUser 会话内安装" } else { "等待 $TargetUser 登录后安装" }
    version          = $resolvedVersion
    engine_version   = $resolvedVersion
    local_mcp_url    = "http://127.0.0.1:$Port/mcp"
    public_mcp_url   = $publicMcpUrl
    bearer_token     = $authToken
    oauth_password   = $oauthPassword
    health           = 'pending-logon'
    privilege_mode   = 'standard'
    tunnel_mode      = $TunnelMode
    install_exit     = 0
    target_user      = $TargetUser
    task_name        = $TaskName
    task_registered  = $taskOk
}

Write-Summary @"
## AgentDock 已暂存，等待日常账号登录

- 版本：$resolvedVersion
- 安装目标账号：$TargetUser（其登录后在自己的会话里自动安装并启动）
- 计划任务：$TaskName（主体 $principalUser / Interactive / Highest）—— 注册成功：$taskOk
- 暂存目录：$work（含离线包、install.ps1、隧道令牌、参数文件）
- 公网 MCP（登录后可用）：$publicMcpUrl
- 当前状态：$(if ($sessionActive) { '已立即触发' } else { '等待登录' })

> 说明：AgentDock 是用户级安装（%LOCALAPPDATA% + HKCU\Run + DPAPI 凭据），
> 只有装进日常使用账号，它安装的软件、写入的文件、驱动的桌面才真的落在主人自己的环境里。
"@

exit 0
