<#
.SYNOPSIS
  EasyTier 中继路径预热 + 对等节点可达性探测（非致命，永不 exit≠0）。

.DESCRIPTION
  背景：托管 runner 处在 PortRestricted NAT 之后，无法与对端打洞，只能走中继，
  开机后「对端 → 云端 VIP」的可达性会有一段建立窗口。

  本脚本做三件事：
    1) 从 `easytier-cli peer` 自动发现同网段对端，逐包探测其可达性
       —— 首轮即向每个对端发包，促使中继路径与虚拟路由尽早建立/刷新；
    2) 判定采用「ICMP 优先、TCP 兜底」：ICMP 不通时再试 TCP 3389 / 8081。
       原因见 run#225 实测——该轮 ICMP 全程不通但 TCP 8081 一直可达，
       说明 Windows 防火墙默认丢弃入站 echo request，单用 ping 会把对端误判为不可达；
    3) 每次运行追加一行汇总到 -LogFile（默认 C:\easytier\warmup.log），
       供开机后核对脚本确实执行过（Actions 日志要等作业结束才能下载）。

  设计约束：
    - 全部流量只是单包 ICMP / 单次 TCP 连接，代价可忽略；
    - 有总预算（BudgetSeconds）与全通提前退出，最坏不拖过预算；
    - 任何异常只打印、不抛出，不影响步骤 7 的主链路。

.PARAMETER CliPath
  easytier-cli.exe 路径。留空则自动在 C:\easytier 下查找。

.PARAMETER SelfVip
  本机虚拟 IP，用于从对端清单里剔除自己。

.PARAMETER Rounds
  轮数。开机后调用默认 3 轮；保活循环里建议 -Rounds 1 -Quiet。

.PARAMETER Quiet
  静默模式：不打每轮明细与可达明细（保活循环用）。

.PARAMETER NoLogFile
  不写 -LogFile 追加行（本地调试用）。
#>
[CmdletBinding()]
param(
    [string]   $CliPath       = '',
    [string]   $SelfVip       = '',
    [string]   $NetPrefix     = '192.168.110.',
    [int]      $Rounds        = 3,
    [int]      $TimeoutMs     = 1200,
    [int]      $TcpTimeoutMs  = 800,
    [int]      $BudgetSeconds = 45,
    [int[]]    $TcpProbePorts = @(3389, 8081),
    [string]   $LogFile       = 'C:\easytier\warmup.log',
    [switch]   $NoLogFile,
    [switch]   $Quiet
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
Say ("[warmup] 探测 {0} 轮，ICMP {1}ms / TCP {2}ms，总预算 {3}s" -f $Rounds, $TimeoutMs, $TcpTimeoutMs, $BudgetSeconds)

# ---------- 3. 单节点探测（ICMP 优先，TCP 兜底） ----------
$ping = New-Object System.Net.NetworkInformation.Ping

function Test-Peer {
    param([string] $ip)

    try {
        $rep = $ping.Send($ip, $TimeoutMs)
        if ($rep -and $rep.Status -eq 'Success') { return 'icmp' }
    } catch { }

    foreach ($port in $TcpProbePorts) {
        $tc = New-Object System.Net.Sockets.TcpClient
        try {
            $iar = $tc.BeginConnect($ip, $port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne($TcpTimeoutMs, $false) -and $tc.Connected) {
                try { $tc.EndConnect($iar) } catch { }
                return "tcp:$port"
            }
        } catch {
        } finally {
            try { $tc.Close() } catch { }
        }
    }
    return ''
}

# ---------- 4. 逐轮探测 ----------
$hit = @{}
foreach ($p in $peers) { $hit[$p] = '' }

for ($r = 1; $r -le $Rounds; $r++) {
    if ($sw.Elapsed.TotalSeconds -ge $BudgetSeconds) {
        Say ("[warmup] 达到总预算 {0}s，提前结束" -f $BudgetSeconds)
        break
    }
    $ok = 0
    foreach ($p in $peers) {
        if ($sw.Elapsed.TotalSeconds -ge $BudgetSeconds) { break }
        $how = Test-Peer -ip $p
        if ($how) { $ok++; if (-not $hit[$p]) { $hit[$p] = $how } }
    }
    Say ("[warmup] 第 {0}/{1} 轮：{2}/{3} 可达" -f $r, $Rounds, $ok, $peers.Count)
    if ($ok -eq $peers.Count) { break }          # 全通即收工
    if ($r -lt $Rounds) { Start-Sleep -Seconds 2 }
}
try { $ping.Dispose() } catch { }

# ---------- 5. 汇总 ----------
$okList  = @($peers | Where-Object { $hit[$_] })
$badList = @($peers | Where-Object { -not $hit[$_] })

Out ("[warmup] 完成：可达 {0}/{1}，耗时 {2:N1}s" -f $okList.Count, $peers.Count, $sw.Elapsed.TotalSeconds)
if ($okList.Count -gt 0) {
    Say ("[warmup] 可达明细：" + (($okList | ForEach-Object { "$_($($hit[$_]))" }) -join ', '))
}
if ($badList.Count -gt 0) {
    # 不写 Warning，避免 Actions 把可选探测标成告警；用普通行保留证据即可
    Out ("[warmup] 未响应节点（可能尚未开机或中继未建立）：{0}" -f ($badList -join ', '))
}

# ---------- 6. 落盘一行（供事后核对脚本确实执行过） ----------
if (-not $NoLogFile -and $LogFile) {
    try {
        $dir = Split-Path -Parent $LogFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $miss = if ($badList.Count -gt 0) { $badList -join ',' } else { '无' }
        $line = '{0} | 可达 {1}/{2} | 缺 {3} | {4:N1}s' -f `
                (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $okList.Count, $peers.Count, $miss, $sw.Elapsed.TotalSeconds
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        Say "[warmup] 写日志失败（不影响）：$($_.Exception.Message)"
    }
}

exit 0
