<#
.SYNOPSIS
    Install and start AgentDock inside the daily-driver user's own logon session.

.DESCRIPTION
    Invoked by the scheduled task that install-agentdock.ps1 (staged mode) registers;
    the task fires when the target user logs on, and it may also be triggered by the
    keepalive script. Every parameter is read from files under WorkDirectory, so this
    script never contains a plaintext credential.

    Why it must run as that user:
      AgentDock is a per-user install -- %LOCALAPPDATA%\AgentDock, HKCU\Run and DPAPI
      credentials are all bound to the current Windows user. Only installing as the
      daily-driver user (inside their interactive session) makes the software it
      installs, the files it writes and the desktop it drives actually belong to them.

    NOTE: this file is executed by Windows PowerShell 5.1 (the scheduled task action),
    which reads script files as ANSI unless a BOM is present. Keep it pure ASCII.

    Exit codes: 0 = installed (or a healthy instance already exists), 1 = failed,
                2 = port busy, 3 = missing staged parameters.
#>
[CmdletBinding()]
param(
    [string] $WorkDirectory = 'C:\agentdock-install',
    [string] $ReportFile = '',
    [int]    $Port = 8765
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$work = $WorkDirectory
if ([string]::IsNullOrWhiteSpace($ReportFile)) { $ReportFile = Join-Path $work 'provision-report.txt' }
$statusFile = Join-Path $work 'status.json'
$log = New-Object System.Collections.Generic.List[string]
function L($m) { $script:log.Add([string]$m) }
function Flush { $script:log | Set-Content -LiteralPath $ReportFile -Encoding UTF8 }

$sw = [Diagnostics.Stopwatch]::StartNew()
$mySession = (Get-Process -Id $PID).SessionId
$root = Join-Path $env:LOCALAPPDATA 'AgentDock'

L ("P-start " + (Get-Date -Format o))
L ("whoami=" + (whoami))
L ("session=" + $mySession)
L ("userprofile=" + $env:USERPROFILE)

function Read-TextSafe {
    param([string] $Path)
    # IMPORTANT: do NOT use [IO.File]::ReadAllText here. Its default share mode is
    # FileShare.Read (= "others may read, nobody may write"), so it FAILS against any
    # file currently held open for writing. cloudflared keeps cloudflared.err.log open
    # for the whole session, so every read threw an IOException and was swallowed by
    # the catch below -> this script could never see "Registered tunnel connection"
    # and always reported tunnel_registered=False although the tunnel was up.
    # Observed 2026-09-27 on run #47: 4 registrations in the log, still judged False,
    # which turned the task result into 1 and stamped error_code=provision-incomplete.
    # Get-Content works because PowerShell opens with FileShare.ReadWrite. Do the same.
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return '' }
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs)
            try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
        } finally { $fs.Dispose() }
    } catch { }
    return ''
}

function Read-Ini {
    param([string] $Path)
    $kv = @{}
    # .NET read detects and strips a BOM (PS 5.1 Get-Content would assume ANSI);
    # Read-TextSafe additionally tolerates a file held open by another writer.
    foreach ($line in ((Read-TextSafe $Path) -split "`r?`n")) {
        if ($line -match '^\s*([A-Za-z]+)\s*=\s*(.*)$') { $kv[$Matches[1]] = $Matches[2].Trim() }
    }
    return $kv
}

try {
    # ---- idempotency guard: healthy instance already living in this session ----
    $healthOk = $false
    try { Invoke-RestMethod "http://127.0.0.1:$Port/healthz" -TimeoutSec 5 | Out-Null; $healthOk = $true } catch { }
    $mine = @(Get-Process -Name 'agentdock-core' -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $mySession })
    L "guard_healthz=$healthOk guard_session_core=$($mine.Count)"
    if ($healthOk -and $mine.Count -gt 0) { L 'RESULT=ALREADY_RUNNING'; Flush; exit 0 }

    # ---- staged parameters ----
    $stage = Read-Ini (Join-Path $work 'rdpadmin-stage.ini')
    if ($stage.Count -eq 0) { $stage = Read-Ini (Join-Path $work 'result.ini') }
    $auth = [string]$stage['BearerToken']
    $oauth = [string]$stage['OAuthPassword']
    $serverUrl = [string]$stage['ServerUrl']
    $tunnelMode = [string]$stage['TunnelMode']
    if ([string]::IsNullOrWhiteSpace($tunnelMode)) { $tunnelMode = 'named' }
    if ([string]::IsNullOrWhiteSpace($auth)) { L 'RESULT=NO_AUTH_TOKEN'; Flush; exit 3 }
    if ($null -eq $oauth) { $oauth = '' }
    if ([string]::IsNullOrWhiteSpace($serverUrl)) {
        $serverUrl = (Read-TextSafe (Join-Path $work 'named-server-url.txt')).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($serverUrl)) { $serverUrl = 'https://agent.yundn.dpdns.org' }
    L "params auth_len=$($auth.Length) oauth_len=$($oauth.Length) url=$serverUrl tunnel=$tunnelMode"

    $zip = Join-Path $work 'agentdock_windows_amd64.zip'
    $sha = Join-Path $work 'agentdock_windows_amd64.zip.sha256'
    $installer = Join-Path $work 'install.ps1'
    foreach ($f in @($zip, $sha, $installer)) {
        if (-not (Test-Path -LiteralPath $f)) { L "RESULT=MISSING_STAGE_FILE $f"; Flush; exit 3 }
    }

    # ---- the port must be free ----
    $busy = $true
    for ($i = 0; $i -lt 30; $i++) {
        if (-not (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) { $busy = $false; break }
        Start-Sleep -Seconds 2
    }
    L "port${Port}_busy=$busy"
    if ($busy) { L 'RESULT=PORT_BUSY'; Flush; exit 2 }

    # ---- install (install.ps1 is re-runnable; -RegisterStartup writes THIS user's HKCU\Run) ----
    $resultFile = Join-Path $work 'result-provisioned.ini'
    Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
    $winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer,
        '-InstallChannel', 'script',
        '-OfflineArchive', $zip,
        '-OfflineChecksumFile', $sha,
        '-Port', "$Port",
        '-TunnelMode', $tunnelMode,
        '-RegisterStartup',
        '-ResultFile', $resultFile,
        '-AuthToken', $auth,
        '-OAuthPassword', $oauth)
    if ($tunnelMode -ne 'none') {
        $a += '-ConfigurePublicAccess'
        $a += @('-ServerUrl', $serverUrl)
    }
    if ($tunnelMode -eq 'named') {
        $tokenFile = Join-Path $work 'tunnel.token'
        if (-not (Test-Path -LiteralPath $tokenFile)) { L 'RESULT=NO_TUNNEL_TOKEN_FILE'; Flush; exit 3 }
        $a += @('-TunnelTokenFile', $tokenFile)
    }
    $out = & $winPs @a 2>&1 | Out-String
    L "install_exit=$LASTEXITCODE"
    if ($out) { L ("install_tail=" + ($out.Substring([Math]::Max(0, $out.Length - 900)).Trim())) }

    $kv = Read-Ini $resultFile
    if (Test-Path -LiteralPath $resultFile) {
        L ("result_ini=" + ((Read-TextSafe $resultFile) -replace "`r?`n", ' | '))
    } else {
        L 'result_ini=(missing)'
    }

    # ---- wait for health ----
    $ok = $false
    for ($i = 0; $i -lt 60; $i++) {
        try { Invoke-RestMethod "http://127.0.0.1:$Port/healthz" -TimeoutSec 5 | Out-Null; $ok = $true; break } catch { }
        Start-Sleep -Seconds 2
    }
    L "healthz_after=$ok"

    # ---- wait for the tunnel to register ----
    # Evidence, in order of reliability:
    #   1) cloudflared's own log ("Registered tunnel connection", 4 lines on a healthy
    #      start) -- both .err.log and .out.log are scanned since the split varies;
    #   2) the public entry point answering /healthz -- the end-to-end truth, used as a
    #      fallback in case the log is rotated or truncated during the wait.
    # Either hit counts as registered. The log alone was previously NOT readable at all
    # (see the FileShare note in Read-TextSafe), which is what caused the false negative.
    $reg = $false
    $regEv = ''
    if ($ok -and $tunnelMode -ne 'none') {
        $cfLogs = @('cloudflared.err.log', 'cloudflared.out.log')
        for ($i = 0; $i -lt 90; $i++) {
            foreach ($n in $cfLogs) {
                $t = Read-TextSafe (Join-Path $root $n)
                if ($t -and ($t -match 'Registered tunnel connection')) { $reg = $true; $regEv = "log:$n"; break }
            }
            if ($reg) { break }
            # Give the tunnel a ~30s head start before poking the public endpoint.
            if ($serverUrl -and $i -ge 15 -and ($i % 5 -eq 0)) {
                try {
                    Invoke-WebRequest "$serverUrl/healthz" -TimeoutSec 8 -UseBasicParsing | Out-Null
                    $reg = $true; $regEv = 'public-healthz'; break
                } catch { }
            }
            Start-Sleep -Seconds 2
        }
    } elseif ($ok) {
        $reg = $true; $regEv = 'tunnel-mode-none'
    }
    $cfSessions = @(Get-Process -Name 'cloudflared' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty SessionId)
    $coreSessions = @(Get-Process -Name 'agentdock-core' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty SessionId)
    L "cloudflared_sessions=$($cfSessions -join ',')"
    L "core_sessions=$($coreSessions -join ',')"
    L "tunnel_registered=$reg"
    L "tunnel_evidence=$regEv"

    # ---- write status.json back (consumed by keepalive / publish step) ----
    $success = $ok -and $reg -and ($coreSessions -contains $mySession)
    $coreInSession = ($coreSessions -contains $mySession)
    $publicMcp = ''
    if ($tunnelMode -ne 'none') { $publicMcp = "$serverUrl/mcp" }
    $msg = 'AgentDock installed and started inside the target user session'
    $code = ''
    if (-not $success) {
        $msg = 'Install or tunnel verification did not pass; see provision-report.txt'
        # Name the failing stage so a later reader does not have to re-diagnose it.
        if (-not $ok) { $code = 'install-healthz-failed' }
        elseif (-not $reg) { $code = 'tunnel-not-registered' }
        elseif (-not $coreInSession) { $code = 'core-not-in-target-session' }
        else { $code = 'provision-incomplete' }
    }
    @{
        stage             = 'installed'
        success           = $success
        error_code        = $code
        message           = $msg
        version           = [string]$stage['Version']
        engine_version    = [string]$kv['Version']
        local_mcp_url     = "http://127.0.0.1:$Port/mcp"
        public_mcp_url    = $publicMcp
        bearer_token      = $auth
        oauth_password    = $oauth
        health            = [string]$kv['Health']
        privilege_mode    = [string]$kv['PrivilegeMode']
        tunnel_mode       = $tunnelMode
        install_exit      = 0
        target_user       = $env:USERNAME
        # Runtime facts, so publish/keepalive have real values to compare
        # (-OnlyIfChanged diffs core_alive / healthz_ok) instead of blanks.
        core_alive        = ($coreSessions.Count -gt 0)
        healthz_ok        = $ok
        tunnel_registered = $reg
        tunnel_evidence   = $regEv
        installed_at      = (Get-Date).ToUniversalTime().ToString('o')
        updated_at        = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statusFile -Encoding utf8

    L "status_written=$statusFile"
    if ($success) { L 'RESULT=INSTALLED_OK' } else { L 'RESULT=INSTALLED_PARTIAL' }
}
catch {
    L ("EXCEPTION: " + $_.Exception.Message)
    L ("stack: " + $_.ScriptStackTrace)
    L 'RESULT=EXCEPTION'
}

$sw.Stop()
L "elapsed=$([int]$sw.Elapsed.TotalSeconds)s"
Flush
if (@($log | Where-Object { $_ -match 'RESULT=INSTALLED_OK' }).Count -gt 0) { exit 0 }
exit 1
