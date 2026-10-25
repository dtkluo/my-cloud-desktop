# guac-images-pack.ps1
# 一次性工具：在**已经装好 Guacamole 的机器**上，把两个镜像导出成单个 tar.gz，
# 供 guac-bootstrap.ps1 -ImageBundle <URL> 使用，从而跳过开机时的 docker pull。
#
# 用法（在云桌面里，以管理员身份）：
#   pwsh -NoProfile -File .github/scripts/guac/guac-images-pack.ps1
# 产出：C:\guac-auto\guac-images.tar.gz（预期 250-320MB）
#
# 之后把它传到 Release（例如 dtkluo/my-cloud-desktop: guac-images-v1），
# 再把 asset 的直链填进 workflow 的 GUAC_IMAGE_BUNDLE。

param(
  [string]$Distro = 'Ubuntu-24.04',
  [string]$Out    = 'C:\guac-auto\guac-images.tar.gz',
  [int]   $Level  = 3
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path (Split-Path $Out -Parent) | Out-Null
if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force }

# 确认镜像在位
$chk = & wsl.exe -d $Distro -u root -- bash -lc `
  "docker image inspect guacamole/guacd:1.6.0 guacamole/guacamole:1.6.0 >/dev/null 2>&1 && echo OK || echo MISSING"
if ($chk -notmatch 'OK') {
  throw "镜像不在 WSL 里，先跑一次 guac-bootstrap.ps1 再打包。($chk)"
}

$wslOut = '/mnt/' + $Out.Substring(0,1).ToLower() + $Out.Substring(2).Replace('\','/')
$tarOut = $wslOut + '.tar'
Write-Host "导出中（docker save → gzip -$Level）→ $Out"

& wsl.exe -d $Distro -u root -- docker save -o $tarOut guacamole/guacd:1.6.0 guacamole/guacamole:1.6.0
if ($LASTEXITCODE -ne 0) { throw "docker save 失败，rc=$LASTEXITCODE" }

& wsl.exe -d $Distro -u root -- gzip -f -$Level $tarOut
if ($LASTEXITCODE -ne 0) { throw "gzip 失败，rc=$LASTEXITCODE" }

$gz = $Out + '.gz'
if (Test-Path -LiteralPath $gz) { Move-Item -LiteralPath $gz -Destination $Out -Force }

$f = Get-Item -LiteralPath $Out
$sha = (Get-FileHash -LiteralPath $Out -Algorithm SHA256).Hash
Write-Host ("size_bytes = {0} ({1:N0} MB)" -f $f.Length, ($f.Length / 1MB))
Write-Host "sha256     = $sha"
Write-Host ''
Write-Host '下一步：把它上传为 Release asset，然后把直链填进 workflow 的 GUAC_IMAGE_BUNDLE，'
Write-Host '例如 https://github.com/dtkluo/my-cloud-desktop/releases/download/guac-images-v1/guac-images.tar.gz'
