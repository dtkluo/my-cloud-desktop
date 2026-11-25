<#
.SYNOPSIS
  EasyTier 中继路径预热 + 对等节点可达性探测（非致命，永不 exit≠0）。

.DESCRIPTION
  背景（run#224 实测）：托管 runner 处在 PortRestricted NAT 之后，无法与对端打洞，
  只能走中继。开机会后云端 easytier-core 早已稳定、云端 → 对端 ping 全通，
  但从对端 → 云端 VIP 的可达性出现了约 13 分钟的不稳定窗口
  （09:35–09:42 期间 ping / 3389 / 8081 间歇全丢，09:42:23 起稳定）。
  同一时段对端到其它节点（.3/.11/.110）一直正常，说明问题只在这一跳的中继路径上。

  本脚本做两件事：
    1) 从 `easytier-cli peer` 自动发现同网段对端，逐包探测其可达性
       —— 首轮即向每个对端发 ICMP，促使中继路径与虚拟路由尽早建立/刷新；
    2) 把「哪些节点可达、哪些不可达、耗时多少」写进 Actions 日志，
       下一次开机就有对照数据，不用再靠事后猜。

  设计约束：
    - 全部流量都是单个 ICMP 包，代价可忽略；
    - 有总预算（BudgetSeconds）与全通提前退出，最坏不拖过预算；
    - 任何异常只打印、不抛出，不影响步骤 7 的主链路。

.PARAMETER CliPath
  easytier-cli.exe 路径。留空则自动在 C:\easytier 下查找。

.PARAMETER SelfVip
  本机虚拟 IP，用于从对端清单里剔除自己。

.PARAMETER Rounds
  轮数。开机会后调用默认 3 轮；保活循环里建议 -Rounds 1 -Quiet。

.PARAMETER Quiet
  静默模式：只输出最终汇总，不打每轮明细（保活循环用）。
#>
[CmdletBinding()]
param(
    [string] $CliPath      = '',
    [string] $SelfVip      = '',
    [string] $NetPrefix    = '192.168.110.',
    [int]    $Rounds       = 3,
    [int]    $TimeoutMs    = 1200,
    [int]    $BudgetSeconds = 60,
    [switch] $Quiet
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$sw = [System.Diagnostics.Stopwatch]::StartNew()

function Say { param([string] $m) if (-not $Quiet) { Write-Host $m } }
function Out { param([string] $m) Write-Host $m }

# ---------- 1. 定位 easytier-cli ----------
if (-not $CliPath -or -not (Test-Path -LiteralPath $CliPath)) {
    $found = Get-ChildItem -Path 'C:\easytier' -Recurse -Filter 'easytier-cli.exe' -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if ($found) { $CliPath = $found.FullName }
}
if (-not $CliPath -or -not (Test-Path -LiteralPath $CliPath)) {
    Say '[warmup] 未找到 easytier-cli，跳过预热'
    exit 0
}

# ---------- 2. 发现对等节点 ----------
$peerRaw = ''
try {
    $peerRaw = (& $CliPath peer 2>&1 | Out-String)
    $global:LASTEXITCODE = 0
} catch {
    Say "[warmup] 读取 peer 列表失败：$($_.Exception.Message)"
    exit 0
}

$peers = @([regex]::Matches($peerRaw, [regex]::Escape($NetPrefix) + '\d{1,3}') |
           ForEach-Object { $_.Value } | Sort-Object -Unique)
if ($SelfVip) { $peers = @($peers | Where-Object { $_ -ne $SelfVip }) }

if ($peers.Count -eq 0) {
    Say '[warmup] 当前无其它对等节点，跳过预热'
    exit 0
}

Say ("[warmup] 对端 {0} 个：{1}" -f $peers.Count, ($peers -join ', '))
Say ("[warmup] 探测 {0} 轮，单包超时 {1}ms，总预算 {2}s" -f $Rounds, $TimeoutMs, $BudgetSeconds)

# ---------- 3. 逐轮探测 ----------
$hit = @{}
foreach ($p in $peers) { $hit[$p] = 0 }
$ping = New-Object System.Net.NetworkInformation.Ping

for ($r = 1; $r -le $Rounds; $r++) {
    if ($sw.Elapsed.TotalSeconds -ge $BudgetSeconds) {
        Say ("[warmup] 达到总预算 {0}s，提前结束" -f $BudgetSeconds)
        break
    }
    $ok = 0
    foreach ($p in $peers) {
        if ($sw.Elapsed.TotalSeconds -ge $BudgetSeconds) { break }
        try {
            $rep = $ping.Send($p, $TimeoutMs)
            if ($rep -and $rep.Status -eq 'Success') { $hit[$p]++; $ok++ }
        } catch { }
    }
    Say ("[warmup] 第 {0}/{1} 轮：{2}/{3} 可达" -f $r, $Rounds, $ok, $peers.Count)
    if ($ok -eq $peers.Count) { break }          # 全通即收工
    if ($r -lt $Rounds) { Start-Sleep -Seconds 2 }
}
try { $ping.Dispose() } catch { }

# ---------- 4. 汇总 ----------
$okList  = @($peers | Where-Object { $hit[$_] -gt 0 })
$badList = @($peers | Where-Object { $hit[$_] -eq 0 })

Out ("[warmup] 完成：可达 {0}/{1}，耗时 {2:N1}s" -f $okList.Count, $peers.Count, $sw.Elapsed.TotalSeconds)
if ($badList.Count -gt 0) {
    # 不写 Warning，避免 Actions 把可选探测标成告警；用普通行保留证据即可
    Out ("[warmup] 未响应节点（可能尚未开机或中继未建立）：{0}" -f ($badList -join ', '))
}

exit 0
