#Requires -Version 5.1
<#
    guangya-skill-login.ps1 —— 让云桌面 AgentDock 的 guangya-pan skill 自动完成设备码登录。

    背景：AgentDock 的 guangya-pan skill 是 bundled（每台自带），只差登录；
          而本 VM 每次重建都会丢登录态（rdpadmin profile 由镜像重建），
          所以每次开机都要重新授权一次。

    设计：本脚本**只负责申请/领取**，批准由外部已登录端完成（本机 _dl/gy_approve.py，
          或任何持有有效光鸭凭据的机器调用 /v1/user/device/authorize）。

      1) status  -> 已有凭据：直接结束（幂等）
      2) login_state=awaiting -> login_poll：若外部已批准则领取令牌
      3) 否则 -> login 申请 user_code，落盘到 OutFile（由 publish 同步到状态仓库，
                 批准者读它即可批准），然后就地 poll 等待 -PollSeconds 秒

    用法：
      pwsh -File guangya-skill-login.ps1
      pwsh -File guangya-skill-login.ps1 -PollSeconds 120 -RegisterRepeating
#>
[CmdletBinding()]
param(
    [string] $SkillRun    = '',   # run.py 全路径；留空自动发现
    [string] $StateFile   = '',   # skill 状态文件；留空取 rdpadmin 默认位置
    [string] $OutFile     = 'C:\agentdock-install\gy-login.json',
    [int]    $PollSeconds = 120,  # 申请设备码后就地等待批准的秒数
    [string] $TaskName    = 'GuangyaSkillLogin',
    [switch] $RegisterRepeating,  # 注册每 3 分钟重试的任务（等外部批准）
    [string] $PasswordFile = 'C:\agentdock-install\rdp-password.txt'
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# ---------- 定位 python / run.py / state ----------
$py = (Get-Command python -ErrorAction SilentlyContinue |
       Select-Object -First 1).Source
if (-not $py) { $py = 'C:\hostedtoolcache\windows\Python\3.12.10\x64\python.exe' }
if (-not (Test-Path $py)) { $py = 'python' }

if (-not $SkillRun) {
    $hit = Get-ChildItem 'C:\Users\*\.agentdock\skill-store\installed\guangya-pan\*\run.py' `
           -ErrorAction SilentlyContinue | Sort-Object FullName -Descending |
           Select-Object -First 1
    if ($hit) { $SkillRun = $hit.FullName }
}
if (-not $SkillRun -or -not (Test-Path $SkillRun)) {
    Write-Host '[gy] 未找到 guangya-pan 的 run.py，跳过'
    exit 0
}
if (-not $StateFile) {
    $StateFile = 'C:\Users\rdpadmin\.local\state\guangya-pan\state.json'
}
# 显式指定状态文件：避免以别的用户身份跑时落到错误的 profile
$env:GUANGYA_STATE_FILE = $StateFile
Write-Host "[gy] python   = $py"
Write-Host "[gy] run.py   = $SkillRun"
Write-Host "[gy] state    = $StateFile"

# 把自身固化到一个稳定路径：便于外部批准者（本机 gy_approve.py）通过 MCP 直接触发，
# 也便于周期任务引用（不依赖 workflow 的 checkout 目录，它关机后就没了）
try {
    $fixed = 'C:\agentdock-install\guangya-skill-login.ps1'
    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath) -and
        ($PSCommandPath -ne $fixed)) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $fixed -Force
    }
} catch { }

function Invoke-Skill {
    param([string] $Action, [hashtable] $Extra = @{})
    $payload = @{ skill_action = $Action }
    foreach ($k in $Extra.Keys) { $payload[$k] = $Extra[$k] }
    $stdinJson = $payload | ConvertTo-Json -Compress -Depth 5
    $raw = ''
    try {
        $raw = ($stdinJson | & $py -X utf8 $SkillRun 2>&1 | Out-String)
    } catch {
        return @{ ok = $false; error = $_.Exception.Message }
    }
    $i = $raw.IndexOf('{'); $j = $raw.LastIndexOf('}')
    if ($i -lt 0 -or $j -lt $i) { return @{ ok = $false; error = '输出不是 JSON'; raw = $raw } }
    try {
        return ($raw.Substring($i, $j - $i + 1) | ConvertFrom-Json)
    } catch {
        return @{ ok = $false; error = 'JSON 解析失败'; raw = $raw }
    }
}

function Write-LoginFile {
    param([string] $State, [string] $UserCode, [string] $DeviceId, [string] $Message)
    $obj = [ordered]@{
        state      = $State
        user_code  = $UserCode
        device_id  = $DeviceId
        message    = $Message
        updated_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ($obj | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $OutFile -Encoding UTF8
    Write-Host "[gy] 落盘 $OutFile -> state=$State user_code=$UserCode"
}

# ---------- 1) 已有凭据？ ----------
$st = Invoke-Skill 'status'
if ($st.ok -and $st.has_credential) {
    Write-Host "[gy] 已登录：device_id=$($st.device_id)"
    Write-LoginFile 'authorized' '' ([string]$st.device_id) '已登录'
    exit 0
}

# ---------- 2) 有进行中的设备码？ ----------
if ($st.login_state -eq 'awaiting') {
    Write-Host '[gy] 存在进行中的设备码，尝试领取'
    $pr = Invoke-Skill 'login_poll' @{ timeout = [Math]::Min(110, $PollSeconds) }
    if ($pr.ok -and ($pr.state -eq 'authorized' -or $pr.access_token)) {
        $st2 = Invoke-Skill 'status'
        Write-Host "[gy] 领取成功 device_id=$($st2.device_id)"
        Write-LoginFile 'authorized' '' ([string]$st2.device_id) '已登录'
        if ($TaskName) { Start-Job { param($n) try { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue } catch { } } -ArgumentList $TaskName | Out-Null }
        exit 0
    }
    Write-Host "[gy] 尚未被批准（state=$($pr.state)），保留设备码等待外部批准"
}

# ---------- 3) 申请新设备码 ----------
$lg = Invoke-Skill 'login'
if (-not $lg.ok) {
    Write-Host "[gy] 申请设备码失败：$($lg.error)"
    Write-LoginFile 'error' '' '' ([string]$lg.error)
    exit 1
}
$userCode = [string]$lg.user_code
$deviceId = [string]$lg.device_id
Write-Host "[gy] 已申请设备码 user_code=$userCode device_id=$deviceId"
Write-Host "[gy] 授权链接 $($lg.verification_uri)"
Write-LoginFile 'awaiting' $userCode $deviceId '等待外部批准（user_code 已同步到状态仓库）'

# ---------- 4) 注册周期重试任务（等外部批准后自动领取） ----------
if ($RegisterRepeating -and $TaskName) {
    try {
        Import-Module ScheduledTasks -ErrorAction Stop
        $pass = ''
        if (Test-Path $PasswordFile) { $pass = (Get-Content -LiteralPath $PasswordFile -Raw).Trim() }
        $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -PollSeconds 100 -OutFile `"$OutFile`""
        $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
        $trg = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(3)) -RepetitionInterval (New-TimeSpan -Minutes 3) -RepetitionDuration (New-TimeSpan -Days 1)
        if ($pass) {
            Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg `
                -User 'rdpadmin' -Password $pass -RunLevel Highest -Force | Out-Null
        } else {
            Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Force | Out-Null
        }
        Write-Host "[gy] 已注册周期任务 $TaskName（每 3 分钟重试领取）"
    } catch {
        Write-Warning "[gy] 周期任务注册失败（不致命）：$($_.Exception.Message)"
    }
}

# ---------- 5) 就地等待批准 ----------
if ($PollSeconds -gt 0) {
    Write-Host "[gy] 就地等待批准 ${PollSeconds}s ..."
    $pr2 = Invoke-Skill 'login_poll' @{ timeout = $PollSeconds }
    if ($pr2.ok -and ($pr2.state -eq 'authorized' -or $pr2.access_token)) {
        $st3 = Invoke-Skill 'status'
        Write-Host "[gy] 领取成功 device_id=$($st3.device_id)"
        Write-LoginFile 'authorized' '' ([string]$st3.device_id) '已登录'
        exit 0
    }
    Write-Host "[gy] 本轮未等到批准（state=$($pr2.state)）；设备码仍在，等待外部批准后由周期任务领取"
}

exit 0
