#Requires -RunAsAdministrator
<#
.SYNOPSIS
    AgentDock 云桌面 - Webtor 一键部署（不含镜像包，直接 pull）

.DESCRIPTION
    解决一个核心问题：WSL 默认装在 C 盘，而 Docker 所有卷（含 Vault 数据）
    都在 WSL 虚拟盘里。C 盘只剩 20 多 GB，Vault 一存视频就会爆。

    本脚本做四件事：
      1. 检查 WSL 发行版物理位置；若在 C 盘，整体迁到 D 盘（数据从此不进 C 盘）
      2. 拉取 / 导入 webtor 镜像
      3. 建卷并起容器（宿主机 8081 → 容器 8080）
      4. 重建主机侧 TCP 转发与防火墙

    迁移这一步是必需的，不是可选优化：卷落在 ext4 上才是原生速度；
    若只想把卷 bind mount 到 /mnt/d，虽然 xattr 支持（实测通过），
    但 9p 写入约 9 MB/s，视频播放会卡。

.EXAMPLE
    .\deploy-webtor.ps1
    .\deploy-webtor.ps1 -Port 8081 -Vip 192.168.110.88
#>
[CmdletBinding()]
param(
    [string]$Distro      = 'Ubuntu-24.04',
    [string]$WslTarget   = 'D:\WSL\Ubuntu-24.04',
    [int]   $Port        = 8081,
    [string]$Vip         = '192.168.110.88',
    [string]$AdminPw     = '',
    [string]$KitDir      = $PSScriptRoot,
    [string]$Image       = 'ghcr.io/webtor-io/self-hosted:latest',
    # WebtorProxy 计划任务要用的身份。必须与「装了 WSL 发行版的账号」一致，
    # 否则代理进程看不到 WSL（wsl --list 为空），端口转发起不来。
    [string]$RdpUser     = '',
    [string]$RdpPass     = ''
)

$ErrorActionPreference = 'Stop'
$t0 = Get-Date

function Say($m)  { Write-Host "[webtor] $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "[webtor] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[webtor] 失败: $m" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------- 1. 发行版定位（等待就绪）
# [2026-11-24 修复 — 开机竞态]
# 开机勾选场景下，本任务固定 5 秒后执行，而 WSL 发行版由 Guacamole 引导异步安装
# （实测 11:16:08 开始装、11:16:47 才 OK）。原实现是一次判定，于是在 11:16:15
# 读到空列表直接 Die，状态写死成 failed —— 发行版其实 32 秒后就存在了。
# 因此改为轮询等待（上限 15 分钟），把「谁先谁后」的不确定性吸收掉。
Say "检查 WSL 发行版 $Distro ..."
$dsStart = Get-Date
$dsIter  = 0
$distros = @()
while ($true) {
    $distros = @(wsl.exe --list --quiet 2>$null) -replace "`0", '' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if ($distros -contains $Distro) { break }
    $el = [int]((Get-Date) - $dsStart).TotalSeconds
    if ($el -ge 900) { Die "等待 15 分钟仍没有名为 $Distro 的发行版。当前: $($distros -join ', ')" }
    if ($dsIter % 6 -eq 0) { Say "等待发行版安装完成 ${el}s（Guacamole 引导可能正在安装）..." }
    $dsIter++
    Start-Sleep -Seconds 5
}
$waited = [int]((Get-Date) - $dsStart).TotalSeconds
if ($waited -ge 10) { Say "发行版就绪（等待了 ${waited}s）" }

$basePath = $null
foreach ($k in (Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue)) {
    $p = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
    if ($p.DistributionName -eq $Distro) { $basePath = $p.BasePath }
}
if (-not $basePath) { Warn '读不到注册表位置，跳过位置检查' }
else { Say "当前位置: $basePath" }

$needMove = $false
if ($basePath -and ($basePath -notmatch '^[Dd]:')) { $needMove = $true }

# ---------------------------------------------------------- 1.5 禁止 WSL 空闲关闭
# WSL2 默认空闲约 60 秒就把整个虚拟机干掉：容器全停、8081/8080 端口消失，
# 手机端就会看到间歇性 502（2026-11-24 实测过）。vmIdleTimeout=-1 关掉这个行为。
# 这个文件是 per-user 的（rdpadmin 的 %USERPROFILE%），实例每次重建都会丢，所以放在部署里。
$cfgPath  = Join-Path $env:USERPROFILE '.wslconfig'
$cfgRaw   = if (Test-Path -LiteralPath $cfgPath) { Get-Content -LiteralPath $cfgPath -Raw } else { '' }
$cfgDirty = $false
if ($cfgRaw -notmatch 'vmIdleTimeout\s*=\s*-1') {
    if ($cfgRaw -match 'vmIdleTimeout\s*=') {
        $cfgNew = $cfgRaw -replace 'vmIdleTimeout\s*=\s*\S+', 'vmIdleTimeout=-1'
    } elseif ($cfgRaw -match '\[wsl2\]') {
        $cfgNew = $cfgRaw -replace '(\[wsl2\])', "`$1`r`nvmIdleTimeout=-1"
    } elseif ($cfgRaw.Trim()) {
        $cfgNew = $cfgRaw.TrimEnd() + "`r`n`r`n[wsl2]`r`nvmIdleTimeout=-1`r`n"
    } else {
        $cfgNew = "[wsl2]`r`nvmIdleTimeout=-1`r`n"
    }
    [IO.File]::WriteAllText($cfgPath, $cfgNew, (New-Object System.Text.UTF8Encoding($false)))
    $cfgDirty = $true
    Say '.wslconfig：已写入 vmIdleTimeout=-1（禁止空闲关虚拟机）'
} else {
    Say '.wslconfig：vmIdleTimeout=-1 已就绪'
}

if ($needMove) {
    $drive = (Split-Path -Qualifier $WslTarget)
    $freeGB = [math]::Round((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$drive'").FreeSpace / 1GB, 1)
    $vhdx = Get-ChildItem -LiteralPath $basePath -Filter 'ext4.vhdx' -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
    $needGB = if ($vhdx) { [math]::Round($vhdx.Length / 1GB * 1.2 + 1, 1) } else { 8 }
    Say "$drive 可用 ${freeGB} GB，迁移预计需要 ${needGB} GB"
    if ($freeGB -lt $needGB) { Die "$drive 空间不足，无法迁移" }

    # 迁移要 wsl --shutdown，而 Guacamole 的冷启动（6.5）与本任务同时开始：
    # 它正在同一个 WSL 里装 Docker、拉镜像、起容器。此时强关 VM 会打断下载，
    # 甚至让它的 compose 起不来。所以先等它把 'guac-bootstrap done' 标记写完，
    # 最多等 12 分钟；机器上没有 Guacamole 引导日志则直接跳过这段等待。
    $guacLog = 'C:\guac-auto\bootstrap.log'
    if (Test-Path -LiteralPath $guacLog) {
        Say '迁移前等待 Guacamole 引导结束（避免 wsl --shutdown 打断它的下载）...'
        for ($i = 0; $i -lt 240; $i++) {
            $gl = Get-Content -LiteralPath $guacLog -Raw -ErrorAction SilentlyContinue
            if ($gl -match 'guac-bootstrap done') { Say 'Guacamole 引导已结束，继续迁移'; break }
            Start-Sleep -Seconds 3
        }
    }

    Warn '发行版在系统盘，开始迁移到 D 盘（guacamole 会短暂中断）...'
    wsl --shutdown
    Start-Sleep -Seconds 8
    if (Test-Path -LiteralPath $WslTarget) {
        if ((Get-ChildItem -LiteralPath $WslTarget -Force -ErrorAction SilentlyContinue).Count -gt 0) {
            Die "$WslTarget 非空，请先清空或改用 -WslTarget"
        }
    }
    New-Item -ItemType Directory -Path (Split-Path $WslTarget -Parent) -Force | Out-Null
    wsl --manage $Distro --move $WslTarget
    if ($LASTEXITCODE -ne 0) { Die "迁移失败 rc=$LASTEXITCODE" }
    Say '迁移完成，数据此后全部落在 D 盘'
} else {
    Say '发行版已在 D 盘（或无法判定），跳过迁移'
    if ($cfgDirty) {
        # 已装好的机器上改 .wslconfig 也要重启 WSL 才生效；容器 restart=always 会自己回来
        Warn '.wslconfig 变更需重启 WSL 生效（容器约 20 秒后自动恢复）...'
        wsl --shutdown
        Start-Sleep -Seconds 8
    }
}

# ---------------------------------------------------------- 2. Docker 就绪
Say '等待 Linux Docker ...'
$dockerOK = $false
# 开机勾选场景要与 Guacamole 后台引导共用同一个 WSL/Docker；冷启动下载发行版
# 可能要 5-8 分钟，这里最多等 12 分钟，避免抢在 Docker 就绪之前直接失败。
for ($i = 0; $i -lt 240; $i++) {
    $v = (wsl -d $Distro -u root -- bash -lc "docker info --format '{{.ServerVersion}}' 2>/dev/null") -join ''
    if ($v -match '^\d') { $dockerOK = $true; break }
    Start-Sleep -Seconds 3
}
if (-not $dockerOK) { Die 'Docker 未就绪，本方案依赖 workflow 自建的 Linux Docker' }
Say "Docker $v"

# ---------------------------------------------------------- 3. 镜像
$imgGz = Join-Path $KitDir 'webtor-image.tar.gz'
$volGz = Join-Path $KitDir 'webtor-volumes.tar.gz'
$hasImg = ((wsl -d $Distro -u root -- bash -lc "docker image inspect $Image >/dev/null 2>&1 && echo YES || echo NO") -join '') -match 'YES'

if ($hasImg) {
    Say '镜像已存在，跳过'
} elseif (Test-Path $imgGz) {
    Say '本地有镜像包，docker load ...'
    $w = '/mnt/' + $imgGz.Substring(0,1).ToLower() + ($imgGz.Substring(2) -replace '\\','/')
    wsl -d $Distro -u root -- docker load -i $w
    if ($LASTEXITCODE -ne 0) { Die "docker load 失败 rc=$LASTEXITCODE" }
} else {
    Say "拉取镜像 $Image（约 1.4 GB，几分钟）..."
    wsl -d $Distro -u root -- docker pull $Image
    if ($LASTEXITCODE -ne 0) { Die "docker pull 失败 rc=$LASTEXITCODE" }
}

# ---------------------------------------------------------- 4. 数据卷
$existing = (wsl -d $Distro -u root -- bash -lc "docker volume ls --format '{{.Name}}'") -join ' '
foreach ($v in @('webtor_data','webtor_pgdata','webtor_storage')) {
    if ($existing -notmatch "\b$v\b") {
        wsl -d $Distro -u root -- bash -lc "docker volume create $v" | Out-Null
        Say "创建卷 $v"
    }
}

# 若带了卷备份且卷是空的，则还原（仅首次）
if (Test-Path $volGz) {
    $empty = ((wsl -d $Distro -u root -- bash -lc "find /var/lib/docker/volumes/webtor_data/_data -mindepth 1 | head -1") -join '').Trim()
    if (-not $empty) {
        Say '还原数据卷备份 ...'
        $vw = '/mnt/' + $volGz.Substring(0,1).ToLower() + ($volGz.Substring(2) -replace '\\','/')
        $bash = "set -e; rm -rf /tmp/wv; mkdir -p /tmp/wv; tar -xzf $vw -C /tmp/wv; " +
                "for v in webtor_data webtor_pgdata webtor_storage; do " +
                "cp -a /tmp/wv/`$v/_data/. /var/lib/docker/volumes/`$v/_data/; done; rm -rf /tmp/wv; echo RESTORED"
        wsl -d $Distro -u root -- bash -lc $bash
    }
}

# ---------------------------------------------------------- 5. 起容器
$running = ((wsl -d $Distro -u root -- bash -lc "docker ps -a --filter name=webtor --format '{{.Status}}'") -join '')
if ($running -match 'Up') {
    Say "容器已在运行: $running"
} else {
    $envFile = Join-Path $KitDir 'webtor.env'
    if (-not $AdminPw -and (Test-Path $envFile)) {
        Get-Content $envFile | ForEach-Object {
            if ($_ -match '^\s*ADMIN_PASSWORD\s*=\s*(.+)$') { $AdminPw = $Matches[1].Trim() }
        }
    }
    if (-not $AdminPw) {
        $AdminPw = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
        Warn "未提供密码，已生成: $AdminPw  （请记录）"
    }
    $domain = "http://${Vip}:$Port"
    $run = "docker rm -f webtor >/dev/null 2>&1; docker run -d --name webtor --restart=always " +
           "-p ${Port}:8080 -v webtor_data:/data -v webtor_pgdata:/pgdata -v webtor_storage:/storage " +
           "-e DOMAIN=$domain -e ONLY_AUTHORIZED=true -e ADMIN_PASSWORD=$AdminPw $Image"
    wsl -d $Distro -u root -- bash -lc $run
    if ($LASTEXITCODE -ne 0) { Die "docker run 失败 rc=$LASTEXITCODE" }
    Say '等待子系统就绪（约 40 秒）...'
    for ($i = 0; $i -lt 25; $i++) {
        $s = (wsl -d $Distro -u root -- bash -lc "docker ps --filter name=webtor --format '{{.Status}}' 2>/dev/null") -join ''
        if ($s -match 'Up') { break }
        Start-Sleep -Seconds 4
    }
    Say "容器状态: $s"
}

# ---------------------------------------------------------- 6. 主机侧转发
Say '部署端口转发 ...'
New-Item -ItemType Directory -Path 'C:\webtor' -Force | Out-Null
$proxySrc = Join-Path $KitDir 'proxy.py'
if (-not (Test-Path $proxySrc)) { Die "缺少 $proxySrc" }
Copy-Item $proxySrc 'C:\webtor\proxy.py' -Force

$pyText = Get-Content 'C:\webtor\proxy.py' -Raw
$pyText = $pyText -replace 'DISTRO\s*=\s*"[^"]*"', "DISTRO = `"$Distro`""
$pyText = $pyText -replace 'LISTEN_ADDR\s*=\s*\("[^"]*",\s*\d+\)', "LISTEN_ADDR = (`"0.0.0.0`", $Port)"
$pyText = $pyText -replace '(?m)^PORT\s*=\s*\d+', "PORT = $Port"
Set-Content -LiteralPath 'C:\webtor\proxy.py' -Value $pyText -Encoding utf8

$py = $null
$c = Get-ChildItem 'C:\hostedtoolcache\windows\Python' -Filter 'python.exe' -Recurse -ErrorAction SilentlyContinue |
     Where-Object { $_.FullName -match '\\x64\\python\.exe$' } |
     Sort-Object FullName -Descending | Select-Object -First 1
if ($c) { $py = $c.FullName }
if (-not $py) {
    $g = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($g) { $py = $g.Source }
}
if (-not $py) { Die '找不到 python.exe' }

Unregister-ScheduledTask -TaskName 'WebtorProxy' -Confirm:$false -ErrorAction SilentlyContinue
# 清掉所有旧的 proxy 实例：只按 python 路径匹配会漏掉别的解释器起的进程，
# 而它们绑着 VIP 会把流量抢走（表现为 502）。
Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
    Where-Object { $_.CommandLine -match 'webtor\\proxy\.py' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
$action    = New-ScheduledTaskAction -Execute $py -Argument 'C:\webtor\proxy.py' -WorkingDirectory 'C:\webtor'
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
                -MultipleInstances IgnoreNew -RestartCount 3 `
                -RestartInterval (New-TimeSpan -Minutes 1) `
                -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

# 代理进程必须跑在「装了 WSL 的那个账号」下：它要调 wsl.exe 把 8081 转进容器。
# 之前用 S4U + $env:USERNAME，workflow 里就是 runneradmin —— 看不到 rdpadmin 的
# Ubuntu-24.04，代理起来也是空的（页面 502）。这里优先用 rdpadmin + 密码。
$proxyHost = [System.Net.Dns]::GetHostName()
$proxyUser = if ($RdpUser) { "$proxyHost\$RdpUser" } else { "$proxyHost\$env:USERNAME" }
$proxyOK = $false
if ($RdpUser -and $RdpPass) {
    try {
        Register-ScheduledTask -TaskName 'WebtorProxy' -Action $action -Settings $settings `
            -User $proxyUser -Password $RdpPass -RunLevel Highest -Force -ErrorAction Stop | Out-Null
        $proxyOK = $true
    } catch { Warn "proxy 任务（password）注册失败: $($_.Exception.Message)" }
}
if (-not $proxyOK) {
    try {
        Register-ScheduledTask -TaskName 'WebtorProxy' -Action $action -Settings $settings `
            -User $proxyUser -RunLevel Highest -Force -ErrorAction Stop | Out-Null
        $proxyOK = $true
    } catch { Warn "proxy 任务（interactive）注册失败: $($_.Exception.Message)" }
}
if (-not $proxyOK) {
    $principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$env:USERNAME" -LogonType S4U -RunLevel Highest
    Register-ScheduledTask -TaskName 'WebtorProxy' -Action $action -Principal $principal `
        -Settings $settings -Force | Out-Null
    Warn 'proxy 任务退回 S4U（看不到 WSL，端口转发很可能失败）'
}
Start-ScheduledTask -TaskName 'WebtorProxy'

# ---------------------------------------------------------- 6.5 WSL 常驻保活
# WSL2 在没人用时会把整台虚拟机关掉（默认约 60 秒），容器随之全停、端口消失，
# 外部看到的就是间歇性 502。vmIdleTimeout=-1 在新版 WSL（3.0.5）上实测不生效，
# 可靠做法是留一个常驻会话把 VM 钉住：`wsl ... -- sleep infinity` 永不退出。
# 这一个任务同时保住 guacd 和 webtor，比两套各自保活更省。
Say '注册 WSL 常驻保活任务 ...'
$kaName = 'WSL-KeepAlive'
Unregister-ScheduledTask -TaskName $kaName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
$wslExe = @("$env:ProgramFiles\WSL\wsl.exe", "$env:SystemRoot\System32\wsl.exe") |
          Where-Object { Test-Path $_ } | Select-Object -First 1
if ($wslExe) {
    $kaAct = New-ScheduledTaskAction -Execute $wslExe -Argument "-d $Distro -u root -- sleep infinity"
    $kaSet = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    $kaUser = if ($RdpUser) { "$proxyHost\$RdpUser" } else { "$proxyHost\$env:USERNAME" }
    $kaOK = $false
    if ($RdpUser -and $RdpPass) {
        try {
            Register-ScheduledTask -TaskName $kaName -Action $kaAct -Settings $kaSet `
                -User $kaUser -Password $RdpPass -RunLevel Highest -Force -ErrorAction Stop | Out-Null
            $kaOK = $true
        } catch { Warn "WSL 保活任务（password）注册失败: $($_.Exception.Message)" }
    }
    if (-not $kaOK) {
        try {
            $kaPr = New-ScheduledTaskPrincipal -UserId $kaUser -LogonType S4U -RunLevel Highest
            Register-ScheduledTask -TaskName $kaName -Action $kaAct -Settings $kaSet `
                -Principal $kaPr -Force -ErrorAction Stop | Out-Null
            $kaOK = $true
        } catch { Warn "WSL 保活任务（S4U）注册失败: $($_.Exception.Message)" }
    }
    if ($kaOK) {
        try { Start-ScheduledTask -TaskName $kaName } catch { Warn "WSL 保活任务启动失败: $($_.Exception.Message)" }
        Say 'WSL 常驻保活已启动（防止空闲关 VM 导致 502）'
    } else {
        Warn 'WSL 保活未注册：长时间不访问后可能需要先唤醒再打开页面'
    }
} else {
    Warn '找不到 wsl.exe，跳过 WSL 保活'
}

Remove-NetFirewallRule -DisplayName "Webtor $Port" -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "Webtor $Port" -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort $Port -Profile Any | Out-Null

# ---------------------------------------------------------- 7. 验证
Say '验证 ...'
$code = ''
for ($i = 0; $i -lt 6; $i++) {
    Start-Sleep -Seconds 4
    # 用 curl 而不是 Invoke-WebRequest：后者会走系统代理，回环请求被代理拦截返回空
    $code = (curl.exe -s -o NUL -w "%{http_code}" --noproxy "*" --max-time 15 `
                "http://127.0.0.1:$Port/login") -join ''
    if ($code -eq '200' -or $code -eq '401') { break }
}

$volDev = ((wsl -d $Distro -u root -- bash -lc "df -h /var/lib/docker/volumes | tail -1") -join '').Trim().Split()[0]
$mins = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)

Write-Host ''
Say "完成，耗时 $mins 分钟"
Say "登录页 HTTP $code"
Say "卷所在设备: $volDev（/dev/sdd = D 盘 WSL 虚拟盘，非 C 盘）"
Write-Host "        访问 http://${Vip}:$Port" -ForegroundColor Green
if ($AdminPw) { Write-Host "        管理员密码 $AdminPw" -ForegroundColor Green }
Write-Host ''
