<#
.SYNOPSIS
    注册一次性计划任务，异步执行 webtor WSL Docker 部署（开机勾选 / 按需命令共用）。

.DESCRIPTION
    同步执行会把「云桌面可连接」推迟 2-3 分钟，所以这里只写启动器 + 注册任务，
    <3 秒返回；部署本体在后台自己跑，装完自己把状态补推到手机端。

    [2026-11-24 修复 — 部署失败 rc=1 的根因]
    之前用 -LogonType S4U 注册成「workflow step 的当前用户」，而 workflow step 跑在
    runneradmin 下：S4U 登录不加载用户注册表，且 WSL 发行版是按用户注册在
    HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss 里的（Ubuntu-24.04 属于 rdpadmin）。
    两个原因叠加，部署进程里 `wsl --list --quiet` 返回空列表，deploy-webtor.ps1
    在第一步就 Die：「没有名为 Ubuntu-24.04 的发行版。当前: 」。

    现在与 guac-schedule.ps1 对齐：显式以 -RdpUser / -RdpPass（rdpadmin）注册，
    Password 登录类型在 session 0 也能跑 —— WSL 只要用户 SID 对，不需要交互桌面。
    拿不到密码时退回交互式身份；再不行才退回 S4U（至少能跑出明确的失败状态）。

    密码只落在 launcher 文件里（与 Guacamole 同级别处理），注册后立即收紧 ACL。
#>
[CmdletBinding()]
param(
    [string] $WorkDir      = 'C:\webtor-auto',
    [string] $TaskName     = 'Webtor-Deploy',
    [int]    $DelaySeconds = 5,
    [string] $StateRepo    = '',
    [string] $StatePath    = '',
    [string] $RunId        = '',
    [string] $RequestId    = '',
    [string] $RdpUser      = 'rdpadmin',
    [string] $RdpPass      = '',
    [string] $AdminPw      = '',
    [string] $Vip          = '',
    [int]    $Port         = 8081
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

$runner   = Join-Path $PSScriptRoot 'webtor-run.ps1'
$launcher = Join-Path $WorkDir 'run-webtor.ps1'
if (-not $RequestId) { $RequestId = "boot-$RunId" }

if (-not (Test-Path -LiteralPath $runner)) {
    Write-Host "MISSING_RUNNER=$runner"
    exit 0
}

function Q([string]$s) { "'" + ($s -replace "'", "''") + "'" }

# ---------- 1) 启动器 ----------
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('$ErrorActionPreference = ''Continue''')
[void]$sb.AppendLine('$ProgressPreference = ''SilentlyContinue''')
if ($env:STATE_TOKEN)    { [void]$sb.AppendLine("`$env:STATE_TOKEN = $(Q $env:STATE_TOKEN)") }
if ($env:ET_VIRTUAL_IP)  { [void]$sb.AppendLine("`$env:ET_VIRTUAL_IP = $(Q $env:ET_VIRTUAL_IP)") }
if ($env:ET_SOCKS5_PORT) { [void]$sb.AppendLine("`$env:ET_SOCKS5_PORT = $(Q $env:ET_SOCKS5_PORT)") }
$argLine = '-WorkDir {0} -RequestId {1} -RunId {2} -StateRepo {3} -StatePath {4} -RdpUser {5} -RdpPass {6} -AdminPw {7} -Vip {8} -Port {9}' -f `
    (Q $WorkDir), (Q $RequestId), (Q $RunId), (Q $StateRepo), (Q $StatePath), `
    (Q $RdpUser), (Q $RdpPass), (Q $AdminPw), (Q $Vip), $Port
[void]$sb.AppendLine("& $(Q $runner) $argLine *> $(Q (Join-Path $WorkDir 'run.log'))")
[void]$sb.AppendLine('exit $LASTEXITCODE')
[IO.File]::WriteAllText($launcher, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

# 收紧 ACL：launcher 含 rdpadmin 密码与 webtor 管理员密码，不能给其他用户读
$hostName = [System.Net.Dns]::GetHostName()
try {
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($id in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators', "$hostName\$RdpUser")) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $id, 'FullControl', 'Allow')))
    }
    Set-Acl -LiteralPath $launcher -AclObject $acl
} catch { Write-Host ("launcher acl WARN: " + $_.Exception.Message) }

# ---------- 2) 注册任务 ----------
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

$pwshPath = (Get-Process -Id $PID).Path
$act = New-ScheduledTaskAction -Execute $pwshPath `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $launcher) `
    -WorkingDirectory $WorkDir
$trig = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddSeconds([Math]::Max($DelaySeconds, 0)))
$set  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 45) -StartWhenAvailable `
    -MultipleInstances IgnoreNew -RestartCount 1 -RestartInterval (New-TimeSpan -Minutes 2)

$registered = $false
$how = ''

if ($RdpPass) {
    try {
        Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trig -Settings $set `
            -User "$hostName\$RdpUser" -Password $RdpPass -RunLevel Highest -Force -ErrorAction Stop | Out-Null
        $registered = $true; $how = 'password logon'
    } catch { Write-Host ("password logon FAILED: " + $_.Exception.Message) }
}

if (-not $registered) {
    try {
        Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trig -Settings $set `
            -User "$hostName\$RdpUser" -RunLevel Highest -Force -ErrorAction Stop | Out-Null
        $registered = $true; $how = 'interactive fallback'
    } catch { Write-Host ("interactive fallback FAILED: " + $_.Exception.Message) }
}

if (-not $registered) {
    # 最后兜底：当前身份 S4U。这种身份看不到 rdpadmin 的 WSL，部署会失败，
    # 但至少状态文件能写出明确原因，不会让手机端一直停在「部署中」。
    try {
        $principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$env:USERNAME" `
            -LogonType S4U -RunLevel Highest
        Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trig -Settings $set `
            -Principal $principal -Force -ErrorAction Stop | Out-Null
        $registered = $true; $how = 'S4U fallback (WSL 可能不可见)'
    } catch { Write-Host ("S4U fallback FAILED: " + $_.Exception.Message) }
}

if (-not $registered) { Write-Host 'webtor 部署任务注册失败，跳过（不影响云桌面）'; exit 0 }

try { Start-ScheduledTask -TaskName $TaskName } catch { Write-Host ("start FAILED: " + $_.Exception.Message) }
Write-Host "webtor 部署任务已注册：$TaskName（$how，${DelaySeconds}s 后执行）"
exit 0
