# 安装 VB-Audio Virtual Cable，让无音频设备的 Hyper-V 虚机拥有渲染端点，
# 从而 Piik 的 "System sound" 能通过 WASAPI loopback 采到桌面声音。
# 幂等 + 失败不致命：已装则跳过；失败只写 audio.json 的标记，不中断工作流。
#
# 判据为什么用 MMDevices\Audio\Render 子键数：
#   Win32_SoundDevice / PnP MEDIA 类都可能残留或为空，与「Piik 能否拿到默认渲染端点」
#   并不等价。Piik 的 SystemAudioAvailable() 实际调用 GetDefaultAudioEndpoint(eRender)，
#   只要该注册表项下没有子键，就一个渲染端点都没有。
#
# 为什么必须跑 VBCABLE_Setup_x64.exe：
#   pnputil /add-driver 只把驱动包注册进 DriverStore（会提示 "Already exists in the system"），
#   并不会创建 root 枚举设备节点。没有设备节点就没有 MEDIA 设备、也就没有音频端点。
#   官方 setup 程序内部会建 ROOT\MEDIA\0000 并绑定驱动，这是端点出现的唯一途径。
[CmdletBinding()]
param(
  [string]$LogFile = 'C:\piik-auto\audio.json',
  [int]$TimeoutSec = 120
)

$ErrorActionPreference = 'Continue'
$RenderKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'

$result = [ordered]@{
  ok          = $false
  installed   = $false
  devices     = 0
  render      = 0
  endpoints   = @()
  action      = ''
  setupExit   = $null
  pnputilUsed = $false
  error       = ''
}

function Save-Result {
  try {
    $dir = Split-Path -Parent $LogFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    ($result | ConvertTo-Json -Depth 5) | Out-File $LogFile -Encoding utf8
  } catch {}
}

function Get-RenderCount {
  try { return @(Get-ChildItem $RenderKey -ErrorAction SilentlyContinue).Count } catch { return 0 }
}

function Update-Snapshot {
  $result.render = Get-RenderCount
  $result.devices = @(Get-CimInstance Win32_SoundDevice -ErrorAction SilentlyContinue).Count
  $result.endpoints = @(Get-PnpDevice -Class AudioEndpoint -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName } | ForEach-Object { $_.FriendlyName })
  return $result.render
}

function Wait-ForRender([int]$Seconds) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    if ((Get-RenderCount) -gt 0) { return $true }
    Start-Sleep -Seconds 3
  }
  return ((Get-RenderCount) -gt 0)
}

try {
  if ((Update-Snapshot) -gt 0) {
    $result.ok = $true
    $result.installed = $true
    $result.action = 'already-present'
    Write-Host "渲染端点已存在（$($result.render) 个），跳过安装"
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
  $setup = Join-Path $ex 'VBCABLE_Setup_x64.exe'
  if (-not (Test-Path $inf)) { throw 'vbMmeCable64_win7.inf 不存在' }

  # 该驱动用旧代码签名证书，证书过期 + 根不受信 ⇒ pnputil 会拒绝。
  # 把签发证书及其链导入「受信任的发布者」「受信任的根证书」即可放行。
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

  # 关键步骤：官方 setup 创建 root 枚举设备节点（-i 安装，-h 隐藏窗口）。
  if (Test-Path $setup) {
    Write-Host "创建虚拟声卡设备节点 ..."
    try {
      $proc = Start-Process -FilePath $setup -ArgumentList '-i', '-h' -PassThru -Wait -WindowStyle Hidden -ErrorAction Stop
      $result.setupExit = $proc.ExitCode
      Write-Host "  setup exit=$($proc.ExitCode)"
    } catch {
      Write-Warning "  setup 调用失败：$($_.Exception.Message)"
    }
    if (Wait-ForRender ([Math]::Min($TimeoutSec, 45))) {
      $result.action = 'installed'
    }
  } else {
    Write-Warning "VBCABLE_Setup_x64.exe 不存在，退回 pnputil"
  }

  if ((Get-RenderCount) -eq 0) {
    Write-Host "设备节点未出现，退回 pnputil /add-driver ..."
    $result.pnputilUsed = $true
    $out = & pnputil.exe /add-driver $inf /install 2>&1
    $out | Where-Object { $_ } | ForEach-Object { Write-Host "  $_" }
    if ($out -match 'Failed to add driver package') {
      $result.error = (($out | Select-Object -Last 2) -join ' ')
    }
    [void](Wait-ForRender 20)
  }

  if ((Get-RenderCount) -eq 0) {
    Write-Host "端点仍未出现，重启音频服务 ..."
    Restart-Service AudioEndpointBuilder -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
    Restart-Service Audiosrv -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 6
    [void](Wait-ForRender 15)
  }

  $n = (Update-Snapshot)
  $result.installed = ($n -gt 0)
  $result.ok = ($n -gt 0)
  if ($n -gt 0) {
    $result.action = if ($result.action) { $result.action } else { 'installed' }
    $result.error = ''
  } else {
    $result.action = 'no-endpoint'
    if (-not $result.error) { $result.error = '驱动已注册但未出现渲染端点' }
  }
  Write-Host "渲染端点：$n；设备：$($result.devices)；端点列表：$($result.endpoints -join ', ')"
} catch {
  $result.error = $_.Exception.Message
  $result.ok = $false
  Write-Warning "虚拟声卡安装失败（不影响画面/键控）：$($_.Exception.Message)"
}

Save-Result
exit 0
