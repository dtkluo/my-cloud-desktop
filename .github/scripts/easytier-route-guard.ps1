[CmdletBinding()]
param(
    # pre  = EasyTier 启动前：把物理网卡 metric 钉死，让 TUN 的 0.0.0.0/0 永远抢不过它
    # post = EasyTier 启动后：直接把 TUN 上的 0.0.0.0/0 删掉并复查有效出接口
    [ValidateSet('pre', 'post')][string]$Phase = 'pre',
    [string]$Target = '8.8.8.8',
    [int]$PhysicalMetric = 10
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

function Get-EgressInfo {
    param([string]$T)
    try {
        $r = @(Find-NetRoute -RemoteIPAddress $T -ErrorAction SilentlyContinue)
        if ($r.Count -eq 0) { return $null }
        $rt = $r | Where-Object { $_.DestinationPrefix } | Select-Object -Last 1
        if (-not $rt) { $rt = $r | Select-Object -Last 1 }
        return [pscustomobject]@{ Alias = $rt.InterfaceAlias; Index = $rt.InterfaceIndex }
    } catch { return $null }
}

function Get-TunIndex {
    @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.Status -eq 'Up' -and (
            $_.InterfaceDescription -match 'EasyTier|Wintun|TAP-Windows|WireGuard' -or
            $_.Name -match 'EasyTier|tun|wintun'
        )
    } | ForEach-Object { $_.ifIndex })
}

if ($Phase -eq 'pre') {
    # EasyTier 的 TUN 会挂一条 metric 9005 的 0.0.0.0/0。托管 runner 的物理网卡 metric
    # 每次开机都可能不同，一旦 TUN 胜出，到 GitHub / Cloudflare 的流量就被吸进虚拟网卡
    # 形成回环 → 整机失联、服务一个都起不来（2026-11-24 21:00 实证）。
    $eg = Get-EgressInfo -Target $Target
    if ($eg) {
        try {
            Set-NetIPInterface -InterfaceIndex $eg.Index -AddressFamily IPv4 `
                -InterfaceMetric $PhysicalMetric -ErrorAction Stop
            Write-Host "已固定物理网卡 $($eg.Alias) (ifIndex=$($eg.Index)) 的 IPv4 metric=$PhysicalMetric"
        } catch {
            Write-Host "（固定网卡 metric 跳过：$($_.Exception.Message)）"
        }
    } else {
        Write-Host "（未能判定物理网卡，跳过 metric 固定）"
    }
    exit 0
}

# post：v8 已无 exit node，TUN 上的默认路由是纯负担，删掉没有任何功能损失。
for ($k = 0; $k -lt 3; $k++) {
    $tun = @(Get-TunIndex)
    if (-not $tun) { break }
    foreach ($idx in $tun) {
        try { Remove-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $idx -Confirm:$false -ErrorAction Stop } catch { }
    }
    Start-Sleep -Milliseconds 700
}
$eg2 = Get-EgressInfo -Target $Target
if ($eg2) { Write-Host "清理后访问 $Target 的出接口：$($eg2.Alias) (ifIndex=$($eg2.Index))" }
else { Write-Host "（清理后仍无法判定出接口）" }
