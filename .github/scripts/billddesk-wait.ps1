# billddesk-wait.ps1 - Wait for the background billddesk-bootstrap (launched at step 1.5).
# Polls C:\billddesk-auto\billddesk.json until the bootstrap writes its result (max 8 min).
# Kept as a separate script file because step 7's inline run block is close to the
# GitHub "max expression length 21000" limit (hit on 2026-10-29, commit b348964c).
$ErrorActionPreference = 'Continue'

# ---- banner（原步骤 7 内联输出，为 run 块表达式长度余量移入本脚本，内容不变）----
$vip        = $env:ET_VIRTUAL_IP
$socks5Port = $env:ET_SOCKS5_PORT
Write-Host ""
Write-Host "=========================================="
Write-Host "  >>> RDP 服务器已就绪！ <<<"
Write-Host "  EasyTier IP  : $vip"
Write-Host "  SOCKS5 门户  : socks5h://$vip`:$socks5Port   （v8 唯一对外通道，无认证）"
Write-Host "  客户端配置   : 出口节点留空；自定义路由留空；代理指向上面地址"
Write-Host "  连接方式     : mstsc -> 输入 $vip"
Write-Host "=========================================="

$bdJson = 'C:\billddesk-auto\billddesk.json'
$deadline = (Get-Date).AddMinutes(8)
$got = $null
while ((Get-Date) -lt $deadline) {
  if (Test-Path $bdJson) {
    try {
      $raw = Get-Content $bdJson -Raw -ErrorAction Stop
      if ($raw -and $raw.Trim().Length -gt 10) { $got = $raw | ConvertFrom-Json; break }
    } catch { }
  }
  Start-Sleep -Seconds 10
}
if ($got) {
  Write-Host ("billddesk ready: state={0} code={1} pwd={2} login={3}" -f $got.state, $got.device_code, $got.password, $got.login)
  if ($got.state -ne 'ready') {
    Write-Warning ("billddesk state={0} (not ready), check C:\billddesk-auto\bootstrap.log / agent.log" -f $got.state)
  }
} else {
  Write-Warning "billddesk-bootstrap produced no result within 8 min, check C:\billddesk-auto\bootstrap.log and agent.log"
}
