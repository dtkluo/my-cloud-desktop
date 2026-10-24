<#
.SYNOPSIS
  Download the custom Piik runtime, start it in the console session, and drive the Host page
  through Chrome DevTools Protocol so the cloud desktop shares itself automatically.

.DESCRIPTION
  Produces C:\piik-auto\piik.json with the invite URL, room code and password so the state
  publisher can surface it to the phone controller.

  Must run AFTER EasyTier is up when -LanAddress is used, because Piik validates that the
  requested LAN address is an active IPv4 address.
#>
[CmdletBinding()]
param(
  [string]$ZipUrl = 'https://github.com/dtkluo/my-cloud-desktop/releases/download/piik-runtime-v1/piik-runtime.zip',
  [string]$InstallDir = 'D:\piik',
  [int]$Port = 8787,
  [int]$CdpPort = 9223,
  [string]$RoomPassword = '8682268',
  [string]$LanAddress = '192.168.110.88',
  [string]$TargetUser = 'runneradmin',
  [int]$TimeoutSec = 300,
  [string]$Preset = 'HD · 1080p 30 fps'
)

$ErrorActionPreference = 'Stop'
$work = 'C:\piik-auto'
$result = [ordered]@{
  ok = $false; state = 'starting'; url = ''; site = ''; room_code = ''; password = $RoomPassword
  resolution = ''; fps = 0; audio = $false; remote_control = $false; elapsed_sec = 0; error = ''
}
New-Item -ItemType Directory -Force -Path $work | Out-Null

function Write-Result([string]$state, [string]$errorText) {
  $result.state = $state
  $result.error = $errorText
  ($result | ConvertTo-Json -Depth 6) | Out-File (Join-Path $work 'piik.json') -Encoding utf8
}

try {
  # ---------- 1. runtime files ----------
  $appExe = Join-Path $InstallDir 'piik-app.exe'
  if (-not (Test-Path $appExe)) {
    $zip = Join-Path $work 'piik-runtime.zip'
    if (-not (Test-Path $zip) -or (Get-Item $zip).Length -lt 10000000) {
      Write-Host "Downloading Piik runtime from $ZipUrl"
      $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
      & $curl -sSL --retry 3 --retry-delay 2 -o $zip $ZipUrl
      if ($LASTEXITCODE -ne 0) { throw "download failed (curl exit $LASTEXITCODE)" }
    }
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Expand-Archive -Path $zip -DestinationPath $InstallDir -Force
  }
  if (-not (Test-Path $appExe)) { throw 'piik-app.exe missing after extraction' }
  $script = Join-Path $work 'piik-auto-host.mjs'
  if (-not (Test-Path $script)) {
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
    $src = Join-Path $here 'piik-auto-host.mjs'
    if (Test-Path $src) { Copy-Item $src $script -Force }
  }
  if (-not (Test-Path $script)) { throw 'piik-auto-host.mjs missing' }

  # ---------- 2. pre-approve the local Host origin so the App connects without a human ----------
  $cfgDir = Join-Path (Join-Path $env:SystemDrive 'Users') "$TargetUser\AppData\Roaming\Piik"
  New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
  $hostOrigin = "http://127.0.0.1:$Port"
  $cfgJson = '{"version":1,"localAccessPassword":"","site":"' + $hostOrigin + '"}'
  [IO.File]::WriteAllText((Join-Path $cfgDir 'client.json'), $cfgJson, (New-Object Text.UTF8Encoding($false)))

  # ---------- 3. launcher scripts run in the console session ----------
  $nodeExe = (Get-Command node -ErrorAction Stop).Source
  $chrome = @(
    'C:\Program Files\Google\Chrome\Application\chrome.exe',
    'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
    'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $chrome) { throw 'no Chromium browser found' }

  $appArgs = "--link --port $Port"
  if ($LanAddress) { $appArgs += " --lan-address $LanAddress" }
  $launchApp = @"
`$ErrorActionPreference='Continue'
Get-Process piik-app -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1
Start-Process -FilePath '$appExe' -ArgumentList '$appArgs' -WorkingDirectory '$InstallDir' -RedirectStandardOutput '$work\app.log' -RedirectStandardError '$work\app.err.log' -WindowStyle Hidden
"@
  $launchChrome = @"
`$ErrorActionPreference='Continue'
Get-CimInstance Win32_Process -Filter "Name='chrome.exe' OR Name='msedge.exe'" -ErrorAction SilentlyContinue | Where-Object { `$_.CommandLine -like '*piik-auto*' } | ForEach-Object { Stop-Process -Id `$_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1
Remove-Item '$work\chrome-profile' -Recurse -Force -ErrorAction SilentlyContinue
Start-Process -FilePath '$chrome' -ArgumentList '--headless=new','--remote-debugging-port=$CdpPort','--user-data-dir=$work\chrome-profile','--no-first-run','--no-default-browser-check','--disable-extensions','--disable-features=Translate','--window-size=1600,1000','about:blank' -WindowStyle Hidden
"@
  Set-Content -Path (Join-Path $work 'launch-app.ps1') -Value $launchApp -Encoding utf8
  Set-Content -Path (Join-Path $work 'launch-chrome.ps1') -Value $launchChrome -Encoding utf8

  $user = "$([System.Net.Dns]::GetHostName())\$TargetUser"
  function Start-SessionTask([string]$name, [string]$scriptPath) {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $name
  }

  Get-Process piik-app -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-SessionTask 'PiikHostApp' (Join-Path $work 'launch-app.ps1')

  # ---------- 4. wait for the public site to appear ----------
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  $site = ''
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    $log = Get-Content (Join-Path $work 'app.log') -Raw -ErrorAction SilentlyContinue
    if ($log -and $log -match 'https://[a-z0-9-]+\.trycloudflare\.com') {
      $site = $Matches[0]
      break
    }
  }
  if (-not $site) {
    $tail = (Get-Content (Join-Path $work 'app.log') -Raw -ErrorAction SilentlyContinue)
    if ($tail) { $tail = $tail.Substring([Math]::Max(0, $tail.Length - 400)) }
    throw "public site not ready; log tail: $tail"
  }
  $result.site = $site
  $result.url = "$site/"
  Write-Host "Piik site ready: $site"

  # ---------- 5. headless browser + automation ----------
  Start-SessionTask 'PiikHostChrome' (Join-Path $work 'launch-chrome.ps1')
  $cdpDeadline = (Get-Date).AddSeconds(45)
  while ((Get-Date) -lt $cdpDeadline) {
    Start-Sleep -Seconds 2
    $probe = & (Join-Path $env:SystemRoot 'System32\curl.exe') -s -m 3 "http://127.0.0.1:$CdpPort/json/version"
    if ($probe) { break }
  }

  $env:PIIK_CDP_PORT = "$CdpPort"
  $env:PIIK_ROOM_PASSWORD = $RoomPassword
  $env:PIIK_PRESET = $Preset
  $env:PIIK_RESULT = (Join-Path $work 'piik-result.json')
  $env:PIIK_HOST_URL = "http://127.0.0.1:$Port/#piik-client=1"
  $nodeOut = & $nodeExe $script 2>&1 | Out-String
  Write-Host "automation: $($nodeOut.Trim())"

  $raw = Get-Content (Join-Path $work 'piik-result.json') -Raw -ErrorAction SilentlyContinue
  if (-not $raw) { throw "automation produced no result: $nodeOut" }
  $r = $raw | ConvertFrom-Json

  $result.ok = [bool]$r.ok
  $result.room_code = [string]$r.roomId
  if ($r.inviteUrl) { $result.url = [string]$r.inviteUrl }
  $result.resolution = [string]$r.resolution
  $result.fps = [int]$r.fps
  $result.audio = [bool]$r.audio
  $result.remote_control = [bool]$r.remoteControl
  $result.elapsed_sec = [int]$r.elapsedSec
  if (-not $r.ok) {
    $errs = ($r.errors -join '; ')
    Write-Result 'failed' ($errs.Substring(0, [Math]::Min(300, $errs.Length)))
    exit 1
  }
  Write-Result 'sharing' ''
  Write-Host "Piik OK room=$($result.room_code) url=$($result.url) remote=$($result.remote_control) audio=$($result.audio)"
}
catch {
  Write-Result 'failed' $_.Exception.Message
  Write-Host "Piik start failed: $($_.Exception.Message)"
  exit 1
}
