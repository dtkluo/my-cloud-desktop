# guac-bootstrap.ps1
# 在 GitHub Actions runner 开机后重建「网页端 RDP（Apache Guacamole）」。
# 幂等：可重复执行。冷启动约 5-8 分钟（下载 WSL 发行版 + Docker 镜像）。
#
# 用法（workflow 中）：
#   & pwsh -NoProfile -File .github/scripts/guac-bootstrap.ps1 `
#       -RdpUser $env:GUAC_RDP_USER -RdpPass $env:GUAC_RDP_PASS -GuacPass $env:GUAC_WEB_PASS `
#       -StateOut C:\guac-auto\guac.json
#
# 依赖：.github/scripts/guac/guac-deploy.sh（WSL 侧部署脚本，同目录提交）

param(
  [string]$RdpUser      = 'rdpadmin',
  [Parameter(Mandatory=$true)][string]$RdpPass,
  [Parameter(Mandatory=$true)][string]$GuacPass,
  [string]$Distro       = 'Ubuntu-24.04',
  [string]$StateOut     = 'C:\guac-auto\guac.json',
  [string]$WorkDir      = 'C:\guac-auto',
  [string]$DeploySh     = "$PSScriptRoot\guac\guac-deploy.sh",
  [string]$ImageBundle  = '',          # 可选：预导出的镜像包 URL（.tar.zst），命中则跳过 docker pull
  [switch]$SkipWslInstall
)

$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$logPath = Join-Path $WorkDir 'bootstrap.log'
function Log($m) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
  Write-Output $line
  $line | Out-File -FilePath $logPath -Append -Encoding utf8
}
Log "=== guac-bootstrap start ==="

# ---------- 1) WSL 发行版 ----------
$distros = (& wsl.exe -l -q 2>$null | Out-String) -replace "`0", ''
if ($distros -notmatch [regex]::Escape($Distro)) {
  if ($SkipWslInstall) { Log "FATAL: distro $Distro missing and -SkipWslInstall set"; exit 1 }
  Log "installing WSL distro $Distro ..."
  & wsl.exe --install -d $Distro --web-download --no-launch 2>&1 | Out-Null
  Start-Sleep -Seconds 5
  $distros = (& wsl.exe -l -q 2>$null | Out-String) -replace "`0", ''
  if ($distros -notmatch [regex]::Escape($Distro)) { Log "FATAL: distro install failed"; exit 1 }
}
Log "distro OK"

# ---------- 2) 防火墙：WSL -> 宿主 3389 ----------
Remove-NetFirewallRule -DisplayName 'WSL-RDP-3389' -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName 'WSL-RDP-3389' -Direction Inbound -Protocol TCP `
  -LocalPort 3389 -RemoteAddress 172.16.0.0/12 -Action Allow -Profile Any | Out-Null
Log "firewall rule OK"

# ---------- 3) WSL 保活计划任务（必须，否则 distro 会随客户端退出而关闭） ----------
$hostName = [System.Net.Dns]::GetHostName()
$taskName = 'Guac-WSL-KeepAlive'
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
$act = New-ScheduledTaskAction -Execute 'C:\Windows\System32\wsl.exe' `
        -Argument ('-d {0} -u root -- /bin/sh -c "exec sleep infinity"' -f $Distro)
$trigBoot = New-ScheduledTaskTrigger -AtStartup
$trigBoot.Delay = 'PT20S'
$trigLogon = New-ScheduledTaskTrigger -AtLogOn -User "$hostName\$RdpUser"
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -MultipleInstances IgnoreNew
try {
  Register-ScheduledTask -TaskName $taskName -Action $act -Trigger @($trigBoot,$trigLogon) `
    -Settings $set -User "$hostName\$RdpUser" -Password $RdpPass -RunLevel Highest -Force | Out-Null
  Start-ScheduledTask -TaskName $taskName
  Log "keepalive task registered"
} catch { Log ("keepalive task FAILED: " + $_.Exception.Message) }
Start-Sleep -Seconds 6

# ---------- 4) WSL 内：docker + 镜像 + 部署 ----------
function Invoke-WslSh([string]$shPath, [string]$log) {
  if (-not (Test-Path $shPath)) { Log "MISSING_SH=$shPath"; return 1 }
  $txt = [IO.File]::ReadAllText($shPath) -replace "`r`n", "`n" -replace "`r", "`n"
  [IO.File]::WriteAllText($shPath, $txt, (New-Object System.Text.UTF8Encoding($false)))
  $wslPath = '/mnt/' + $shPath.Substring(0,1).ToLower() + $shPath.Substring(2).Replace('\','/')
  $out = & wsl.exe -d $Distro -u root -- bash $wslPath 2>&1 | Out-String
  $rc = $LASTEXITCODE
  $out | Out-File -FilePath $log -Encoding utf8
  "WSL_RC=$rc" | Out-File -FilePath $log -Append -Encoding utf8
  return $rc
}

$probe = Join-Path $WorkDir 'probe.sh'
@'
#!/bin/bash
command -v docker >/dev/null && echo DOCKER=yes || echo DOCKER=no
docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -c guacamole || echo IMG=0
'@ | Set-Content -Path $probe -Encoding utf8

$pLog = Join-Path $WorkDir 'probe.log'
Invoke-WslSh $probe $pLog | Out-Null
$pOut = Get-Content $pLog -Raw -ErrorAction SilentlyContinue
Log ("probe: " + ($pOut -replace "`r`n", ' '))

if ($pOut -notmatch 'DOCKER=yes') {
  Log "installing docker.io in WSL ..."
  $di = Join-Path $WorkDir 'docker-install.sh'
  @'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y docker.io > /tmp/docker-install.log 2>&1
echo "APT_RC=$?"
systemctl enable --now docker > /dev/null 2>&1
sleep 4
echo "DOCKER_ACTIVE=$(systemctl is-active docker)"
docker --version
'@ | Set-Content -Path $di -Encoding utf8
  Invoke-WslSh $di (Join-Path $WorkDir 'docker-install.log') | Out-Null
}

# 镜像：优先用预导出的 bundle（GitHub Release 单文件下载，约 250-300MB，比 docker pull 快且稳），
#       没有 bundle 或 bundle 里缺镜像时才回退到公网 docker pull。
if ($ImageBundle) {
  $bundlePath = Join-Path $WorkDir 'guac-images.tar.gz'
  $cached = $false
  if (Test-Path -LiteralPath $bundlePath) {
    if ((Get-Item -LiteralPath $bundlePath).Length -ge 10485760) { $cached = $true }
  }
  if ($cached) {
    Log "bundle already cached"
  } else {
    Log "downloading image bundle ..."
    & curl.exe -fL --connect-timeout 20 --max-time 600 -o $bundlePath $ImageBundle 2>&1 | Out-Null
    $sz = 0
    if (Test-Path -LiteralPath $bundlePath) {
      $sz = (Get-Item -LiteralPath $bundlePath).Length
    }
    Log ("bundle bytes=" + $sz)
    if ($sz -lt 10485760) { Remove-Item -LiteralPath $bundlePath -Force -ErrorAction SilentlyContinue }
  }
}

$imgSh = Join-Path $WorkDir 'pull.sh'
@'
#!/bin/bash
BUNDLE=/mnt/c/guac-auto/guac-images.tar.gz
if [ -f "$BUNDLE" ]; then
  echo "LOAD bundle"
  docker load -i "$BUNDLE" 2>&1 | tail -3
fi
for img in guacamole/guacd:1.6.0 guacamole/guacamole:1.6.0; do
  if ! docker image inspect "$img" > /dev/null 2>&1; then
    echo "PULL $img"
    docker pull "$img" 2>&1 | tail -2
  else
    echo "HAVE $img"
  fi
done
'@ | Set-Content -Path $imgSh -Encoding utf8
Invoke-WslSh $imgSh (Join-Path $WorkDir 'pull.log') | Out-Null
Log "images ready"

# ---------- 5) 生成部署脚本（注入密码，避免明文入库） ----------
if (-not (Test-Path $DeploySh)) { Log "FATAL: deploy script missing: $DeploySh"; exit 1 }
$deployTpl = [IO.File]::ReadAllText($DeploySh)
$deployTpl = $deployTpl.Replace('__RDP_USER__', $RdpUser)
$deployTpl = $deployTpl.Replace('__RDP_PASS__', $RdpPass)
$deployTpl = $deployTpl.Replace('__GUAC_PASS__', $GuacPass)
$deployRun = Join-Path $WorkDir 'guac-deploy.sh'
[IO.File]::WriteAllText($deployRun, $deployTpl, (New-Object System.Text.UTF8Encoding($false)))

Invoke-WslSh $deployRun (Join-Path $WorkDir 'deploy.log') | Out-Null
Log "containers deployed"

# ---------- 6) systemd 自启 + cloudflared 隧道 ----------
$units = Join-Path $WorkDir 'units.sh'
@'
#!/bin/bash
set -u
mkdir -p /opt/guacamole
cp /mnt/c/guac-auto/guac-deploy.sh /opt/guacamole/start-guac.sh 2>/dev/null
sed -i 's/\r$//' /opt/guacamole/start-guac.sh 2>/dev/null
chmod +x /opt/guacamole/start-guac.sh

cat > /etc/systemd/system/guac-stack.service <<'EOF'
[Unit]
Description=Apache Guacamole stack via docker
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/guacamole/start-guac.sh
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

if [ ! -x /usr/local/bin/cloudflared ]; then
  curl -fsSL --max-time 180 -o /usr/local/bin/cloudflared \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
  chmod +x /usr/local/bin/cloudflared
fi

cat > /etc/systemd/system/cloudflared-guac.service <<'EOF'
[Unit]
Description=Cloudflare Quick Tunnel for Guacamole
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --url http://127.0.0.1:8080 --no-autoupdate --logfile /var/log/cloudflared-guac.log --loglevel info
Restart=always
RestartSec=8

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable guac-stack > /dev/null 2>&1
systemctl enable cloudflared-guac > /dev/null 2>&1
systemctl is-active guac-stack > /dev/null 2>&1 || systemctl start guac-stack
systemctl is-active cloudflared-guac > /dev/null 2>&1 || systemctl restart cloudflared-guac
sleep 18
echo "GUAC_STACK=$(systemctl is-active guac-stack)"
echo "CLOUDFLARED=$(systemctl is-active cloudflared-guac)"
grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' /var/log/cloudflared-guac.log 2>/dev/null | head -1
'@ | Set-Content -Path $units -Encoding utf8
Invoke-WslSh $units (Join-Path $WorkDir 'units.log') | Out-Null

$uOut = Get-Content (Join-Path $WorkDir 'units.log') -Raw -ErrorAction SilentlyContinue
$url = ([regex]::Match($uOut, 'https://[a-z0-9-]+\.trycloudflare\.com')).Value

# ---------- 7) 本地健康检查 ----------
$http = ''
for ($i = 0; $i -lt 8; $i++) {
  $http = (curl.exe -s -o NUL -w "%{http_code}" --max-time 6 'http://127.0.0.1:8080/guacamole/')
  if ($http -eq '200') { break }
  Start-Sleep -Seconds 6
}
Log "local_http=$http tunnel=$url"

# ---------- 8) 状态输出 ----------
$state = [ordered]@{
  ok            = ($http -eq '200' -and $url -ne '')
  url           = if ($url) { "$url/guacamole/" } else { '' }
  home          = if ($url) { $url } else { '' }
  username      = 'admin'
  password      = $GuacPass
  rdp_target    = "$RdpUser@localhost:3389"
  local_http    = $http
  browser_ready = ($http -eq '200')
  updated_at    = (Get-Date).ToUniversalTime().ToString('o')
}
New-Item -ItemType Directory -Force -Path (Split-Path $StateOut -Parent) | Out-Null
($state | ConvertTo-Json -Depth 4) | Set-Content -Path $StateOut -Encoding utf8
Log ("state -> " + $StateOut)

# ---------- 9) 自己收尾：把 guac 段补推到手机端 ----------
# 本脚本通常由计划任务异步拉起（见 guac-schedule.ps1），那时 workflow 的步骤 6 早已跑完、
# 手机端也已显示「已就绪」。这里再推一次，只是把网页端 URL 补上，不阻塞任何人。
$pub = Join-Path (Split-Path $PSScriptRoot -Parent) 'publish-agentdock-state.ps1'
if (-not (Test-Path -LiteralPath $pub)) { $pub = Join-Path $PSScriptRoot 'publish-agentdock-state.ps1' }
$tok = $env:STATE_TOKEN
if (-not $tok) { $tok = $env:AGENTDOCK_GH_TOKEN }
$repo = $env:AGENTDOCK_STATUS_REPO
$spath = $env:AGENTDOCK_STATUS_PATH
if ((Test-Path -LiteralPath $pub) -and $tok -and $repo -and $spath) {
  Log "re-publishing state with guac section ..."
  $pout = & pwsh -NoProfile -ExecutionPolicy Bypass -File $pub `
            -StateRepo $repo -StatePath $spath -Port 8765 2>&1 | Out-String
  $pout | Out-File -FilePath (Join-Path $WorkDir 'publish.log') -Encoding utf8
  Log ("publish_rc=" + $LASTEXITCODE)
} else {
  Log "skip publish (missing token/repo or publisher script)"
}

Log "=== guac-bootstrap done ==="
