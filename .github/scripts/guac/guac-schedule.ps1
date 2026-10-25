# guac-schedule.ps1
# 目的：让「网页端 RDP（Guacamole）」的 5-8 分钟冷启动**完全脱离开机关键路径**。
#
# 做法：本脚本只做一件事 —— 注册一个「5 秒后执行、一次性」的计划任务去跑 guac-bootstrap.ps1，
#       然后立刻返回（实测 <3 秒）。之后 job 继续走步骤 7 的 360 分钟保活，
#       Guacamole 在后台自己装、自己起，装完自己把状态补推到手机端。
#       ⇒ 主链路（RDP / EasyTier / AgentDock / 手机端状态）耗时增量 ≈ 0。
#
# 为什么用计划任务而不是 Start-Process：
#   GitHub Actions 的 step 结束时会回收该 step 的进程树，Start-Process 拉的子进程经常被一起杀掉；
#   计划任务属于 Task Scheduler 服务，生命周期独立于 step，已验证可跨 step 存活。
#
# 用法（workflow 中）：
#   pwsh -NoProfile -File .github/scripts/guac/guac-schedule.ps1 `
#       -RdpUser $env:RDP_USER -RdpPass $env:RDP_PASS -GuacPass $env:GUAC_PASS `
#       -StateRepo $env:AGENTDOCK_STATUS_REPO -StatePath $env:AGENTDOCK_STATUS_PATH
#
# 依赖：同目录上级的 guac-bootstrap.ps1、publish-agentdock-state.ps1（.github/scripts/ 下）

param(
  [string]$RdpUser   = 'rdpadmin',
  [Parameter(Mandatory=$true)][string]$RdpPass,
  [Parameter(Mandatory=$true)][string]$GuacPass,
  [string]$WorkDir   = 'C:\guac-auto',
  [string]$TaskName  = 'Guac-Bootstrap',
  [int]$DelaySeconds = 5,
  [string]$StateRepo = '',
  [string]$StatePath = '',
  [string]$ImageBundle = '',
  [switch]$Now
)

$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

$scripts    = Split-Path $PSScriptRoot -Parent          # .github/scripts
$bootstrap  = Join-Path $scripts 'guac-bootstrap.ps1'
$publisher  = Join-Path $scripts 'publish-agentdock-state.ps1'
$launcher   = Join-Path $WorkDir 'run-guac.ps1'

if (-not (Test-Path -LiteralPath $bootstrap)) {
  Write-Host "MISSING_BOOTSTRAP=$bootstrap"
  exit 0        # 不阻断 job
}

# ---------- 1) 生成启动器（密码只落此文件，不进任务定义 / 不进日志） ----------
$q = { param($s) "'" + ($s -replace "'", "''") + "'" }
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('$ErrorActionPreference = ''Continue''')
[void]$sb.AppendLine('$ProgressPreference = ''SilentlyContinue''')
if ($StateRepo) { [void]$sb.AppendLine("`$env:AGENTDOCK_STATUS_REPO = $(& $q $StateRepo)") }
if ($StatePath) { [void]$sb.AppendLine("`$env:AGENTDOCK_STATUS_PATH = $(& $q $StatePath)") }
if ($env:STATE_TOKEN) { [void]$sb.AppendLine("`$env:STATE_TOKEN = $(& $q $env:STATE_TOKEN)") }
[void]$sb.AppendLine("& $(& $q $bootstrap) -RdpUser $(& $q $RdpUser) -RdpPass $(& $q $RdpPass) -GuacPass $(& $q $GuacPass)$(if ($ImageBundle) { ' -ImageBundle ' + (& $q $ImageBundle) }) *> $(& $q (Join-Path $WorkDir 'run.log'))")
[void]$sb.AppendLine('exit $LASTEXITCODE')

[IO.File]::WriteAllText($launcher, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

# 收紧 ACL：只保留 SYSTEM / Administrators / 本任务身份，避免明文密码被其他用户读到
$hostName = [System.Net.Dns]::GetHostName()
try {
  $acl = New-Object System.Security.AccessControl.FileSecurity
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($id in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators', "$hostName\$RdpUser")) {
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
      $id, 'FullControl', 'Allow')))
  }
  Set-Acl -LiteralPath $launcher -AclObject $acl
  Write-Host 'launcher acl OK'
} catch { Write-Host ("launcher acl WARN: " + $_.Exception.Message) }

# ---------- 2) 注册一次性计划任务并立即触发 ----------
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

$pwshPath = (Get-Process -Id $PID).Path
$act = New-ScheduledTaskAction -Execute $pwshPath `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $launcher) `
        -WorkingDirectory $WorkDir
$trig = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddSeconds([Math]::Max($DelaySeconds, 0)))
$set  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
          -ExecutionTimeLimit (New-TimeSpan -Minutes 40) -StartWhenAvailable `
          -MultipleInstances IgnoreNew -RestartCount 2 `
          -RestartInterval (New-TimeSpan -Minutes 2)

$principal = $null
$registered = $false
try {
  # 注意：Register-ScheduledTask 的 -Principal 与 -Password 属于不同参数集，不能同时给。
  #   带密码（= Password 登录类型，session 0 也能跑）只能用 -User + -Password + -RunLevel。
  Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trig -Settings $set `
    -User "$hostName\$RdpUser" -Password $RdpPass -RunLevel Highest -Force -ErrorAction Stop | Out-Null
  $registered = $true
  Write-Host 'task registered (password logon)'
} catch {
  Write-Host ("task register FAILED: " + $_.Exception.Message)
}

# 兜底：拿不到密码时退回交互式身份（要求 rdpadmin 已有交互会话，步骤 5.5 通常已建立）
if (-not $registered) {
  try {
    Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trig -Settings $set `
      -User "$hostName\$RdpUser" -RunLevel Highest -Force -ErrorAction Stop | Out-Null
    $registered = $true
    Write-Host 'task registered (interactive fallback)'
  } catch { Write-Host ("task fallback FAILED: " + $_.Exception.Message) }
}

if ($registered) {
  try {
    Start-ScheduledTask -TaskName $TaskName
  } catch { Write-Host ("start FAILED: " + $_.Exception.Message) }
  $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  Write-Host ("task state=" + $t.State)
}

# 本脚本到此结束 —— 不等待、不阻塞，bootstrap 在后台自己跑
Write-Host 'guac-schedule done (async)'
exit 0
