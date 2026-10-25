# Rebuild the Patched Piik App (remote-control resilience)
#
# Downloads the upstream Piik source, overlays the patched files stored next to this
# script, builds the web client and the Windows app, and leaves piik-app.exe ready.
#
# Usage (on the cloud desktop, after Go is available):
#   pwsh -File .github/scripts/piik-build/rebuild-piik.ps1
#
# Why the overlay instead of a patch file: upstream moves fast and line offsets drift.
# Overlaying whole files is immune to that and fails loudly if a file stops existing.

[CmdletBinding()]
param(
  [string]$BaseSha  = '066e218d84a237db41d455975c89a002eb3d0d79',
  [string]$WorkDir  = 'C:\piikbuild',
  [string]$OutExe   = 'C:\piikbuild\out\piik-app.exe',
  [switch]$SkipFrontend,
  [switch]$KeepSource
)

$ErrorActionPreference = 'Stop'
$log = Join-Path $WorkDir 'rebuild-overlay.log'
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
function Log([string]$m) {
  $line = (Get-Date -Format 'HH:mm:ss') + ' ' + $m
  Add-Content -Path $log -Value $line -Encoding UTF8
  Write-Host $line
}
Set-Content -Path $log -Value '' -Encoding UTF8

$here = $PSScriptRoot
$overlay = Join-Path $here 'overlay'
if (-not (Test-Path $overlay)) { throw "overlay directory missing: $overlay" }

# ---------- 1. Go ----------
$go = 'C:\go\bin\go.exe'
if (-not (Test-Path $go)) {
  Log 'Go not found, downloading go1.27.3 ...'
  $zip = Join-Path $WorkDir 'go.zip'
  $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
  $urls = @(
    'https://mirrors.aliyun.com/golang/go1.27.3.windows-amd64.zip',
    'https://go.dev/dl/go1.27.3.windows-amd64.zip'
  )
  $ok = $false
  foreach ($u in $urls) {
    & $curl -fL --connect-timeout 15 --max-time 900 -o $zip $u 2>&1 | Out-Null
    if ((Get-Item $zip -EA SilentlyContinue).Length -gt 40000000) { $ok = $true; break }
    Remove-Item $zip -Force -EA SilentlyContinue
  }
  if (-not $ok) { throw 'Go download failed' }
  Expand-Archive -Path $zip -DestinationPath 'C:\' -Force
  if (-not (Test-Path $go)) { throw 'Go extraction failed' }
}
$env:Path = 'C:\go\bin;C:\Program Files\nodejs;' + $env:Path
Log ('go: ' + (& $go version))

# ---------- 2. source ----------
$src = Join-Path $WorkDir 'src-ovl'
if (-not (Test-Path (Join-Path $src 'go.mod'))) {
  $tar = Join-Path $WorkDir 'piik-src.tar.gz'
  $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
  if (-not (Test-Path $tar) -or (Get-Item $tar).Length -lt 1000000) {
    Log "downloading source $BaseSha ..."
    & $curl -fL --connect-timeout 20 --max-time 900 -o $tar "https://codeload.github.com/TNTcraftHIM/Piik/tar.gz/$BaseSha" 2>&1 | Out-Null
  }
  New-Item -ItemType Directory -Force -Path $src | Out-Null
  & tar.exe -xzf $tar -C $src --strip-components=1
}
if (-not (Test-Path (Join-Path $src 'go.mod'))) { throw 'source extraction failed' }
Log ('source ready: ' + $src)

# ---------- 3. overlay patched files ----------
$applied = 0
Get-ChildItem $overlay -Recurse -File | ForEach-Object {
  $rel = $_.FullName.Substring($overlay.Length).TrimStart('\', '/')
  $dst = Join-Path $src $rel
  if (-not (Test-Path (Split-Path $dst -Parent))) { throw "overlay target directory missing: $rel (upstream layout changed?)" }
  Copy-Item $_.FullName $dst -Force
  $applied++
  Log ("  overlay -> $rel")
}
Log "overlay applied: $applied files"

# ---------- 4. frontend ----------
if (-not $SkipFrontend) {
  $npm = Join-Path $env:ProgramFiles 'nodejs\npm.cmd'
  if (-not (Test-Path $npm)) { throw 'npm not found' }
  Push-Location $src
  if (-not (Test-Path (Join-Path $src 'node_modules'))) {
    Log 'npm ci ...'
    & $npm ci --no-audit --no-fund 2>&1 | Add-Content -Path $log -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { Pop-Location; throw "npm ci failed ($LASTEXITCODE)" }
  } else { Log 'node_modules present, skip npm ci' }
  Log 'npm run build:web ...'
  & $npm run build:web 2>&1 | Add-Content -Path $log -Encoding UTF8
  if ($LASTEXITCODE -ne 0) { Pop-Location; throw "build:web failed ($LASTEXITCODE)" }
  Pop-Location
} else { Log 'SkipFrontend: reusing existing dist' }

$dist = Join-Path $src 'internal\server\webassets\dist'
if (-not (Test-Path (Join-Path $dist 'index.html'))) { throw 'web dist missing index.html' }
Log ('dist files: ' + (Get-ChildItem $dist -Recurse -File | Measure-Object).Count)

# ---------- 5. go build ----------
New-Item -ItemType Directory -Force -Path (Split-Path $OutExe -Parent) | Out-Null
$env:CGO_ENABLED = '0'
Push-Location $src
Log 'go build ...'
& $go build -trimpath -ldflags '-s -w' -o $OutExe ./cmd/piik-app 2>&1 | Add-Content -Path $log -Encoding UTF8
$rc = $LASTEXITCODE
Pop-Location
if ($rc -ne 0 -or -not (Test-Path $OutExe)) { throw "go build failed (rc=$rc)" }
Log ('exe: ' + $OutExe + ' size=' + (Get-Item $OutExe).Length)
Log ('sha256: ' + (Get-FileHash $OutExe -Algorithm SHA256).Hash)

if (-not $KeepSource) { Log 'note: source kept on disk for incremental rebuilds; delete manually to force a clean unzip' }
Log 'done'
