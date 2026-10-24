# Piik 浏览器远控的一体化引导：
#   1) 装虚拟声卡（让无音频设备的 Hyper-V 虚机有渲染端点，Piik 才能采系统声音）
#   2) 启动 Piik 并自动创建私密房间、整屏分享、1080p30、开远控
#   3) 立刻把结果写进 AgentDock 状态文件（手机端无需等 keepalive）
# 设计原则：任何一步失败都不抛出，只记录 warning，保证云桌面本体不受影响。
[CmdletBinding()]
param(
  [string]$LanAddress = '',
  [int]$TimeoutSec = 240,
  [int]$Port = 8787,
  [string]$RoomPassword = '8682268',
  [string]$TargetUser = 'runneradmin',
  [string]$Preset = 'HD · 1080p 30 fps',
  [int]$SessionHours = 6,
  [int]$AgentDockPort = 8765,
  [switch]$SkipPublish
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot        # 仓库根目录
$scriptDir = $PSScriptRoot
Write-Host "[piik-bootstrap] script dir: $scriptDir"

# ---------- 1. 虚拟声卡 ----------
try {
  $audio = Join-Path $scriptDir 'install-virtual-audio.ps1'
  if (Test-Path $audio) {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $audio
    Write-Host "[piik-bootstrap] install-virtual-audio exit=$LASTEXITCODE"
  } else {
    Write-Warning "[piik-bootstrap] install-virtual-audio.ps1 not found"
  }
} catch {
  Write-Warning "[piik-bootstrap] virtual audio failed: $($_.Exception.Message)"
}

# ---------- 2. 启动 Piik ----------
try {
  $host_ = Join-Path $scriptDir 'start-piik-host.ps1'
  if (Test-Path $host_) {
    $args2 = @('-LanAddress', $LanAddress, '-TimeoutSec', "$TimeoutSec", '-Port', "$Port",
               '-RoomPassword', $RoomPassword, '-TargetUser', $TargetUser, '-Preset', $Preset)
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $host_ @args2
    Write-Host "[piik-bootstrap] start-piik-host exit=$LASTEXITCODE"
  } else {
    Write-Warning "[piik-bootstrap] start-piik-host.ps1 not found"
  }
} catch {
  Write-Warning "[piik-bootstrap] piik host failed: $($_.Exception.Message)"
}

if (Test-Path 'C:\piik-auto\piik.json') {
  Write-Host "[piik-bootstrap] --- piik.json ---"
  Get-Content 'C:\piik-auto\piik.json' -Raw | Write-Host
}

# ---------- 3. 发布状态 ----------
if (-not $SkipPublish) {
  try {
    $pub = Join-Path $scriptDir 'publish-agentdock-state.ps1'
    $stateRepo = $env:AGENTDOCK_STATUS_REPO
    $statePath = $env:AGENTDOCK_STATUS_PATH
    if (-not $stateRepo) { $stateRepo = 'dtkluo/agentdock-v2' }
    if (-not $statePath) { $statePath = 'runtime/cloud-desktop.json' }
    if (Test-Path $pub) {
      $args3 = @('-StateRepo', $stateRepo, '-StatePath', $statePath,
                 '-SessionHours', "$SessionHours", '-Port', "$AgentDockPort", '-OnlyIfChanged')
      & pwsh -NoProfile -ExecutionPolicy Bypass -File $pub @args3
      Write-Host "[piik-bootstrap] publish-agentdock-state exit=$LASTEXITCODE"
    } else {
      Write-Warning "[piik-bootstrap] publish-agentdock-state.ps1 not found"
    }
  } catch {
    Write-Warning "[piik-bootstrap] state publish failed: $($_.Exception.Message)"
  }
}

Write-Host "[piik-bootstrap] done"
exit 0
