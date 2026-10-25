#requires -Version 5.1
<#
  retire-piik.ps1 —— 幂等停用 Piik（已被 BilldDesk 取代）
  在 runner（session 0）执行，可重复运行。

  做的事：
    1) 注销 Piik 的两个交互计划任务（PiikHostApp / PiikHostChrome），
       否则杀掉进程后会被任务重新拉起
    2) 杀掉 Piik 自己的进程：piik-app / piik-capture / 命令行含 piik 的 cloudflared
       —— 严格按命令行过滤，绝不碰 AgentDock 的 cloudflared 隧道
    3) 等 8 秒复查是否重生
    4) 只停不删：D:\piik 与 C:\piik-auto 保留，便于随时回滚

  退出码：0 = 已停用或无 Piik；非 0 = 有关键失败（不影响 BilldDesk 主流程）
#>
[CmdletBinding()]
param(
    [string[]] $TaskNames = @('PiikHostApp', 'PiikHostChrome'),
    [int]      $SettleSec = 8
)

$ErrorActionPreference = 'Continue'

function L($m) { Write-Host $m }

$hadAny = $false

# ---------------- 1. 计划任务 ----------------
foreach ($tn in $TaskNames) {
    $st = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
    if ($null -eq $st) { L ('  task ' + $tn + ' = none'); continue }
    $hadAny = $true
    try { Stop-ScheduledTask -TaskName $tn -ErrorAction Stop } catch { L ('  stop ' + $tn + ' err: ' + $_.Exception.Message) }
    try { Disable-ScheduledTask -TaskName $tn -ErrorAction Stop | Out-Null } catch { }
    try {
        Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction Stop
        L ('  unregistered ' + $tn)
    } catch { L ('  unregister ' + $tn + ' err: ' + $_.Exception.Message) }
}

# ---------------- 2. 进程 ----------------
$killed = @()

$cfPiik = @(Get-CimInstance Win32_Process -Filter "Name='cloudflared.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like '*piik*' })
foreach ($p in $cfPiik) {
    try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; $killed += ('cloudflared:' + $p.ProcessId) }
    catch { L ('  kill cloudflared ' + $p.ProcessId + ' err: ' + $_.Exception.Message) }
}

foreach ($n in @('piik-app', 'piik-capture')) {
    foreach ($p in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; $killed += ($n + ':' + $p.Id) }
        catch { L ('  kill ' + $n + ' err: ' + $_.Exception.Message) }
    }
}

if ($killed.Count -gt 0) { $hadAny = $true; L ('  killed = ' + ($killed -join ', ')) }
else { L '  killed = (none)' }

# ---------------- 3. 复查 ----------------
if ($SettleSec -gt 0) {
    Start-Sleep -Seconds $SettleSec
    $alive = @()
    foreach ($n in @('piik-app', 'piik-capture')) {
        foreach ($p in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) { $alive += ($n + ':' + $p.Id) }
    }
    $cfLeft = @(Get-CimInstance Win32_Process -Filter "Name='cloudflared.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -and $_.CommandLine -like '*piik*' })
    foreach ($p in $cfLeft) { $alive += ('cloudflared:' + $p.ProcessId) }

    if ($alive.Count -gt 0) {
        L ('  WARN 仍在运行: ' + ($alive -join ', '))
        L 'RESULT retired=False alive=' + ($alive -join ',')
        exit 1
    }
    L '  after settle = NONE (clean)'
}

# ---------------- 4. 报告 ----------------
$cfAll = @(Get-CimInstance Win32_Process -Filter "Name='cloudflared.exe'" -ErrorAction SilentlyContinue)
L ('  cloudflared remaining = ' + $cfAll.Count + ' (AgentDock 隧道应保持)')

if ($hadAny) { L 'RESULT retired=True (previous install stopped)' }
else { L 'RESULT retired=True (piik never installed)' }
exit 0
