# 安装 VB-Audio Virtual Cable，让无音频设备的 Hyper-V 虚机拥有渲染端点，
# 从而 Piik 的 "System sound" 能通过 WASAPI loopback 采到桌面声音。
# 幂等 + 失败不致命：已装则跳过；失败只写 audio.json 的 skipped 标记，不中断工作流。
[CmdletBinding()]
param(
  [string]$LogFile = 'C:\piik-auto\audio.json',
  [int]$TimeoutSec = 90
)

$ErrorActionPreference = 'Continue'
$result = [ordered]@{
  ok        = $false
  installed = $false
  devices   = 0
  endpoints = @()
  action    = ''
  error     = ''
}

function Save-Result {
  try {
    $dir = Split-Path -Parent $LogFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    ($result | ConvertTo-Json -Depth 5) | Out-File $LogFile -Encoding utf8
  } catch {}
}

try {
  $existing = @(Get-CimInstance Win32_SoundDevice -ErrorAction SilentlyContinue)
  $result.devices = $existing.Count
  if ($existing.Count -gt 0) {
    $result.ok = $true
    $result.installed = $true
    $result.action = 'already-present'
    $result.endpoints = @(Get-PnpDevice -Class AudioEndpoint -ErrorAction SilentlyContinue | ForEach-Object { $_.FriendlyName })
    Write-Host "音频设备已存在（$($existing.Count) 个），跳过安装"
    Save-Result
    exit 0
  }

  $work = 'C:\piik-auto\vbcable'
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  $zip = Join-Path $work 'vbcable.zip'
  $url = 'https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack43.zip'

  if (-not (Test-Path $zip) -or (Get-Item $zip).Length -lt 100000) {
    Write-Host "下载虚拟声卡驱动包 ..."
    & "$env:SystemRoot\System32\curl.exe" -sSL --retry 3 --retry-delay 2 -o $zip $url
    if ($LASTEXITCODE -ne 0) { throw "驱动包下载失败 (curl exit $LASTEXITCODE)" }
  }
  if (-not (Test-Path $zip)) { throw '驱动包不存在' }

  $ex = Join-Path $work 'x'
  if (-not (Test-Path (Join-Path $ex 'vbMmeCable64_win7.inf'))) {
    Expand-Archive -Path $zip -DestinationPath $ex -Force
  }
  $cat = Join-Path $ex 'vbaudio_cable64_win7.cat'
  $inf = Join-Path $ex 'vbMmeCable64_win7.inf'
  if (-not (Test-Path $inf)) { throw 'vbMmeCable64_win7.inf 不存在' }

  # 该驱动用 2012 年的 VeriSign 代码签名证书，证书过期 + 根不受信 ⇒ pnputil 会拒绝。
  # 把签发证书及其链导入「受信任的发布者」「受信任的根证书」即可放行（镜像本身已开 testsigning）。
  if (Test-Path $cat) {
    $cert = (Get-AuthenticodeSignature $cat).SignerCertificate
    if ($cert) {
      foreach ($storeName in @('TrustedPublisher', 'Root')) {
        try {
          $st = New-Object System.Security.Cryptography.X509Certificates.X509Store($storeName, 'LocalMachine')
          $st.Open('ReadWrite'); $st.Add($cert); $st.Close()
        } catch { Write-Warning "导入证书到 $storeName 失败：$($_.Exception.Message)" }
      }
      try {
        $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        $chain.ChainPolicy.RevocationMode = 'NoCheck'
        [void]$chain.Build($cert)
        foreach ($el in $chain.ChainElements) {
          if ($el.Certificate.Thumbprint -eq $cert.Thumbprint) { continue }
          try {
            $st = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'LocalMachine')
            $st.Open('ReadWrite'); $st.Add($el.Certificate); $st.Close()
          } catch {}
        }
      } catch {}
    }
  }

  Write-Host "安装驱动 vbMmeCable64_win7.inf ..."
  $out = & pnputil.exe /add-driver $inf /install 2>&1
  $out | Where-Object { $_ } | ForEach-Object { Write-Host "  $_" }
  if ($out -match 'Failed to add driver package') { throw (($out | Select-Object -Last 2) -join ' ') }

  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  $n = 0
  while ((Get-Date) -lt $deadline) {
    $n = @(Get-CimInstance Win32_SoundDevice -ErrorAction SilentlyContinue).Count
    if ($n -gt 0) { break }
    Start-Sleep -Seconds 3
  }
  if ($n -eq 0) {
    Write-Host "端点未出现，重启音频服务 ..."
    Restart-Service AudioEndpointBuilder -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
    Restart-Service Audiosrv -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 6
    $n = @(Get-CimInstance Win32_SoundDevice -ErrorAction SilentlyContinue).Count
  }

  $result.devices = $n
  $result.endpoints = @(Get-PnpDevice -Class AudioEndpoint -ErrorAction SilentlyContinue | ForEach-Object { $_.FriendlyName })
  $result.installed = ($n -gt 0)
  $result.ok = ($n -gt 0)
  $result.action = if ($n -gt 0) { 'installed' } else { 'no-endpoint' }
  if ($n -eq 0) { $result.error = '驱动已注册但未出现音频端点' }
  Write-Host "音频设备数：$n；端点：$($result.endpoints -join ', ')"
} catch {
  $result.error = $_.Exception.Message
  $result.ok = $false
  Write-Warning "虚拟声卡安装失败（不影响画面/键控）：$($_.Exception.Message)"
}

Save-Result
exit 0
