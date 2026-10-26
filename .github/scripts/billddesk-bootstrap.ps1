#requires -Version 5.1
<#
  BilldDesk 引导脚本 —— 替代 piik-bootstrap.ps1
  在 runner（session 0、SYSTEM/管理员）里执行，负责：
    1) 幂等安装 BilldDesk（Inno 静默）
    2) 确保 BilldDeskService 运行（AUTO_START，LocalSystem）
    3) 注册一个 runneradmin / Interactive 计划任务，把 billddesk-agent.ps1
       送进交互会话（session 2）里去截图 / OCR 取设备码与连接密码
    4) 汇总成 C:\billddesk-auto\billddesk.json

  前置：虚拟声卡（install-virtual-audio.ps1）要在本脚本之前跑，
        否则 BilldDesk 采不到系统声音。
#>
param(
  [string]$InstallerUrl = 'https://github.com/dtkluo/my-cloud-desktop/releases/download/billddesk-lab/BilldDesk_v0.621.0.exe',
  [string]$WorkDir = 'C:\billddesk-auto',
  [string]$AgentUser = 'runneradmin',
  [int]$AgentTimeoutSec = 180,
  [string]$FallbackPassword = 'r9R479JO',
  # 连接密码必须恒定：dtka1 账号下的「设备绑定」是按 设备码+密码 在服务端校验的，
  # 每次开机换密码会让绑定变成「失效」（2026-10-27 实测）。固定后开机 agent 会幂等地
  # 重设成同一值，服务端绑定始终有效，手机主控端可同账号直连。
  [string]$ConnectPassword = 'lZfQZFjl',
  # 主控端自动登录账号（同账号直连用）
  [string]$AccountUser = 'dtka1',
  [string]$AccountPass = 'ljs8682268'
)

$ErrorActionPreference = 'Continue'
if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null }
$logPath = Join-Path $WorkDir 'bootstrap.log'
function L($m) {
  $line = (Get-Date -Format 'HH:mm:ss') + ' ' + $m
  Add-Content -Path $logPath -Value $line -Encoding UTF8
  Write-Host $line
}
Set-Content -Path $logPath -Value '' -Encoding UTF8

L ('bootstrap start sess=' + (Get-Process -Id $PID).SessionId + ' user=' + (whoami))

$installDir = 'C:\Program Files\BilldDesk'
$appExe     = Join-Path $installDir 'BilldDesk.exe'
$jsonPath   = Join-Path $WorkDir 'billddesk.json'

function Write-State($obj) {
  ($obj | ConvertTo-Json -Depth 4) | Out-File $jsonPath -Encoding utf8
}

# ---------------- 进度心跳 ----------------
# 为什么需要它：这一步跑在 workflow 的保活步骤内部，job 要等 6 小时会话结束才会
# 产生可下载日志（GitHub 对 in-progress job 的 logs 接口直接 404），一旦某个子步骤
# 卡住，外部**完全看不见**卡在哪 —— 2026-10-25 就因此白等了半小时。
# 所以把当前 stage 直接写进状态文件的 billddesk_progress 字段，手机端/排障脚本可读。
# 失败一律吞掉：心跳绝不能拖慢或中断主流程。
function Beat($stage) {
  L ('BEAT ' + $stage)
  if ([string]::IsNullOrWhiteSpace($env:STATE_TOKEN)) { return }
  try {
    $api = 'https://api.github.com/repos/dtkluo/agentdock-v2/contents/runtime/cloud-desktop.json'
    $hd  = @{
      Authorization = 'Bearer ' + $env:STATE_TOKEN
      'User-Agent'  = 'billddesk-beat'
      Accept        = 'application/vnd.github+json'
    }
    $r = Invoke-RestMethod -Uri $api -Headers $hd -Method Get -TimeoutSec 20
    $j = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($r.content -replace '\s', ''))) | ConvertFrom-Json
    $prog = [ordered]@{
      stage = $stage
      at    = (Get-Date).ToUniversalTime().ToString('o')
      pid   = $PID
    }
    $j | Add-Member -NotePropertyName billddesk_progress -NotePropertyValue $prog -Force
    $j.updated_at = (Get-Date).ToUniversalTime().ToString('o')
    $body = @{
      message = 'billdesk progress: ' + $stage
      content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($j | ConvertTo-Json -Depth 12)))
      sha     = $r.sha
      branch  = 'main'
    } | ConvertTo-Json -Depth 6
    Invoke-RestMethod -Uri $api -Headers $hd -Method Put -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 30 | Out-Null
  } catch {
    L ('beat failed: ' + $_.Exception.Message)
  }
}

Beat 'start'

# ---------------- -1. 停用 Piik 残留（幂等） ----------------
# BilldDesk 已取代 Piik。若是同一台机器重跑（Piik 装过），这里先把它停干净，
# 避免两套远控同时抢声卡/带宽。全新机器上此步会直接返回 retired=True (never installed)。
$retireScript = Join-Path $PSScriptRoot 'retire-piik.ps1'
if (Test-Path $retireScript) {
  try {
    & $retireScript 2>&1 | ForEach-Object { L ('  retire| ' + $_) }
    L ('retire-piik exit=' + $LASTEXITCODE)
  } catch { L ('retire-piik failed: ' + $_.Exception.Message) }
} else {
  L ('WARN: retire-piik.ps1 not found at ' + $retireScript)
}

# ---------------- 0. 虚拟声卡（必须先于 BilldDesk 启动） ----------------
# 无 GPU 虚机默认一个渲染端点都没有；没有端点，BilldDesk 就无法做系统声音环回。
$audioScript = Join-Path $PSScriptRoot 'install-virtual-audio.ps1'
if (Test-Path $audioScript) {
  L 'installing virtual audio...'
  try {
    & $audioScript 2>&1 | ForEach-Object { L ('  audio| ' + $_) }
    L ('virtual-audio exit=' + $LASTEXITCODE)
  } catch { L ('virtual-audio failed: ' + $_.Exception.Message) }
} else {
  L ('WARN: install-virtual-audio.ps1 not found at ' + $audioScript)
}
Beat 'audio-done'

# ---------------- 1. 安装 ----------------
if (Test-Path $appExe) {
  L 'already installed: ' + $appExe
} else {
  $pkg = Join-Path $WorkDir 'BilldDesk-setup.exe'
  if (-not (Test-Path $pkg) -or (Get-Item $pkg).Length -lt 10MB) {
    Beat 'download-start'
    L ('downloading ' + $InstallerUrl)
    $ok = $false
    for ($try = 1; $try -le 3; $try++) {
      try {
        $ProgressPreference = 'SilentlyContinue'
        # 单次 120s：原先 300s × 3 会让下载卡住时白耗 15 分钟，且外部完全看不到
        Invoke-WebRequest -Uri $InstallerUrl -OutFile $pkg -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        if ((Get-Item $pkg).Length -gt 10MB) { $ok = $true; break }
      } catch {
        L ("  download try$try failed: " + $_.Exception.Message)
        Start-Sleep -Seconds 3
      }
    }
    Beat 'download-done'
    if (-not $ok) {
      Write-State ([ordered]@{ ok = $false; state = 'download-failed'; error = 'installer download failed'; updated_at = (Get-Date).ToUniversalTime().ToString('o') })
      L 'FATAL download failed'
      L 'DONE'
      exit 10
    }
  }
  L ('installer size=' + [int]((Get-Item $pkg).Length/1MB) + 'MB')

  L 'installing silently...'
  $args = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOCANCEL', '/SP-',
            ('/LOG=' + (Join-Path $WorkDir 'install.log')))
  $proc = Start-Process -FilePath $pkg -ArgumentList $args -Wait -PassThru -NoNewWindow
  L ('installer exit=' + $proc.ExitCode)
  Start-Sleep -Seconds 5
  if (-not (Test-Path $appExe)) {
    Write-State ([ordered]@{ ok = $false; state = 'install-failed'; error = ('installer exit ' + $proc.ExitCode); updated_at = (Get-Date).ToUniversalTime().ToString('o') })
    L 'FATAL install failed'
    L 'DONE'
    exit 11
  }
  L 'installed ok'
}

# ---------------- 2. 服务 ----------------
Beat 'install-done'
$svc = Get-Service -Name 'BilldDeskService' -ErrorAction SilentlyContinue
if (-not $svc) {
  L 'WARN: BilldDeskService missing'
} else {
  if ($svc.StartType -ne 'Automatic') {
    try { Set-Service -Name 'BilldDeskService' -StartupType Automatic; L 'service set to Automatic' } catch { L ('set-startup failed: ' + $_.Exception.Message) }
  }
  if ($svc.Status -ne 'Running') {
    try { Start-Service -Name 'BilldDeskService'; L 'service started' } catch { L ('start-service failed: ' + $_.Exception.Message) }
  } else { L 'service already running' }
}

# ---------------- 3. 部署 agent 到本地 ----------------
Beat 'service-done'
$agentSrc = Join-Path $PSScriptRoot 'billddesk-agent.ps1'
$agentDst = Join-Path $WorkDir 'billddesk-agent.ps1'
if (Test-Path $agentSrc) {
  if ((Resolve-Path $agentSrc).Path -ne (Resolve-Path $agentDst -ErrorAction SilentlyContinue).Path) {
    Copy-Item $agentSrc $agentDst -Force
  }
  L 'agent deployed: ' + $agentDst
} elseif (Test-Path $agentDst) {
  L 'agent present: ' + $agentDst
} else {
  Write-State ([ordered]@{ ok = $false; state = 'agent-missing'; error = 'billddesk-agent.ps1 not found'; updated_at = (Get-Date).ToUniversalTime().ToString('o') })
  L 'FATAL agent script missing'
  L 'DONE'
  exit 12
}

if (Test-Path $jsonPath) { Remove-Item $jsonPath -Force -ErrorAction SilentlyContinue }

# ---------------- 4. 注册并运行交互会话任务 ----------------
# 连接密码用恒定值（见 param 注释），agent 会幂等地重设，不再随机生成。
$FixedPassword = $ConnectPassword
L ('fixed password (constant) len=' + $FixedPassword.Length)
$taskName = 'BilldDeskAgent'
try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }
$fbPart = ''
if ($FallbackPassword) { $fbPart = ' -FallbackPassword "' + $FallbackPassword + '"' }
$loginPart = ''
if ($AccountUser -and $AccountPass) { $loginPart = ' -LoginUser "' + $AccountUser + '" -LoginPass "' + $AccountPass + '"' }
$actArg = '-NoProfile -ExecutionPolicy Bypass -File "' + $agentDst + '" -OutDir "' + $WorkDir +
          '" -WaitWindowSec 90 -FixedPassword "' + $FixedPassword + '"' + $fbPart + $loginPart
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $actArg
$principal = New-ScheduledTaskPrincipal -UserId $AgentUser -LogonType Interactive -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
               -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
L ('task registered: ' + $taskName + ' user=' + $AgentUser)
Beat 'task-registered'
Start-ScheduledTask -TaskName $taskName
L 'task started'

# ---------------- 5. 等结果 ----------------
Beat 'task-started'
$deadline = (Get-Date).AddSeconds($AgentTimeoutSec)
$got = $null
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 3
  if (Test-Path $jsonPath) {
    try {
      $raw = Get-Content $jsonPath -Raw -ErrorAction Stop
      if ($raw -and $raw.Trim().Length -gt 10) { $got = $raw | ConvertFrom-Json; break }
    } catch { }
  }
}
if (-not $got) {
  # 兜底：用已知密码 + 让 agent 的下一次运行补设备码
  $got = [pscustomobject]@{
    ok = $false; state = 'agent-timeout'; device_code = ''; device_uuid = ''
    password = $FixedPassword; window = ''; session = 0; error = 'agent did not produce result in time'
  }
  L 'agent timeout'
}

# ---------------- 6. 输出 ----------------
$renderKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
$renderCount = 0
if (Test-Path $renderKey) { $renderCount = @(Get-ChildItem $renderKey -ErrorAction SilentlyContinue).Count }
L ('audio render endpoints=' + $renderCount)

$out = [ordered]@{
  ok          = [bool]$got.ok
  state       = [string]$got.state
  device_code = [string]$got.device_code
  device_uuid = [string]$got.device_uuid
  password    = [string]$got.password
  account     = [string]$got.account
  login       = [string]$got.login
  window      = [string]$got.window
  session     = [int]$got.session
  install_dir = $installDir
  audio       = ($renderCount -gt 0)
  audio_endpoints = $renderCount
  updated_at  = (Get-Date).ToUniversalTime().ToString('o')
  error       = [string]$got.error
}
Write-State $out
L ('RESULT ok=' + $out.ok + ' state=' + $out.state + ' code=' + $out.device_code + ' pwd=' + $out.password)
Beat 'result-ready'

# ---------------- 7. 同步到手机端状态文件 ----------------
# 放在这里而不是 workflow 里，是为了让 workflow 的 run 块只保留一行调用：
# GitHub 对整段 run 脚本有 21000 个 UTF-8 字节的硬上限，超了 dispatch 直接 422。
$stateScript = Join-Path $PSScriptRoot 'billddesk-state.ps1'
if (Test-Path $stateScript) {
  if ([string]::IsNullOrWhiteSpace($env:STATE_TOKEN)) {
    L 'WARN: STATE_TOKEN empty, skip state sync'
  } else {
    L 'syncing state...'
    try {
      & $stateScript -ResultFile $jsonPath 2>&1 | ForEach-Object { L ('  state| ' + $_) }
      L ('billddesk-state exit=' + $LASTEXITCODE)
    } catch { L ('state sync failed: ' + $_.Exception.Message) }
  }
} else {
  L ('WARN: billddesk-state.ps1 not found at ' + $stateScript)
}

L 'DONE'
exit 0
