<#
.SYNOPSIS
    开机勾选「一并部署 webtor」时调用：注册一次性计划任务，5 秒后异步部署。

.DESCRIPTION
    同步执行会把「云桌面可连接」推迟 2-3 分钟。这里沿用 guac-schedule.ps1 已验证的
    模式：只写启动器 + 注册任务，<3 秒返回；项目生命周期独立于 workflow step。

    部署脚本本体在仓库 .github/scripts/webtor/ 下，机器每次重建都会重新检出，
    不依赖磁盘上的残留文件。
#>
[CmdletBinding()]
param(
    [string] $WorkDir    = 'C:\webtor-auto',
    [string] $TaskName   = 'Webtor-Deploy',
    [int]    $DelaySeconds = 5,
    [string] $StateRepo  = '',
    [string] $StatePath  = '',
    [string] $RunId      = ''
)

$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

$scripts  = Split-Path $PSScriptRoot -Parent
$runner   = Join-Path $PSScriptRoot 'webtor-run.ps1'
$launcher = Join-Path $WorkDir 'run-webtor.ps1'

function Q([string]$s) { "'" + ($s -replace "'", "''") + "'" }

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('$ErrorActionPreference = ''Continue''')
[void]$sb.AppendLine('$ProgressPreference = ''SilentlyContinue''')
if ($env:STATE_TOKEN)    { [void]$sb.AppendLine("`$env:STATE_TOKEN = $(Q $env:STATE_TOKEN)") }
if ($env:ET_VIRTUAL_IP)  { [void]$sb.AppendLine("`$env:ET_VIRTUAL_IP = $(Q $env:ET_VIRTUAL_IP)") }
if ($env:ET_SOCKS5_PORT) { [void]$sb.AppendLine("`$env:ET_SOCKS5_PORT = $(Q $env:ET_SOCKS5_PORT)") }
[void]$sb.AppendLine("& $(Q $runner) -WorkDir $(Q $WorkDir) -RequestId $(Q "boot-$RunId") -RunId $(Q $RunId) -StateRepo $(Q $StateRepo) -StatePath $(Q $StatePath) *> $(Q (Join-Path $WorkDir 'run.log'))")
[void]$sb.AppendLine('exit $LASTEXITCODE')
[IO.File]::WriteAllText($launcher, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
$pwshPath = (Get-Process -Id $PID).Path
$act = New-ScheduledTaskAction -Execute $pwshPath `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $launcher) `
    -WorkingDirectory $WorkDir
$trig = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddSeconds([Math]::Max($DelaySeconds, 0)))
$set  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -StartWhenAvailable `
    -MultipleInstances IgnoreNew -RestartCount 1 -RestartInterval (New-TimeSpan -Minutes 2)
# deploy-webtor.ps1 带 #Requires -RunAsAdministrator，任务必须显式提权
$principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$env:USERNAME" `
    -LogonType S4U -RunLevel Highest
Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trig -Settings $set `
    -Principal $principal -Force | Out-Null
Write-Host "webtor 开机部署任务已注册：$TaskName（${DelaySeconds}s 后执行）"
