<#
.SYNOPSIS
    Deploy the gui-ops AgentDock skill + interactive-session worker on the cloud desktop.
.DESCRIPTION
    Runs in the WORKFLOW context (runneradmin, session 2). Three jobs:
      1. Build a mini core-skill bundle from .github\scripts\gui-ops-skill\
         (packages/gui-ops.zip + manifest.json) at C:\agentdock-install\gui-ops-bundle.
         The bundle is later installed by provision-agentdock-user.ps1 via
         "agentdock skill bootstrap --bundle ..." inside the rdpadmin account
         (the skill state dir is per-user, so the workflow cannot install it itself).
      2. Prepare the runtime dir C:\ProgramData\gui-ops (queue/out, Users=Modify) and
         copy the worker script there (it must be readable by the desktop user).
      3. Register + start the scheduled task AgentDock-GuiOpsWorker
         (principal = current user, Interactive => runs inside session 2, no password).
    Idempotent. Prints one JSON summary line at the end. Exit 0 = worker alive.
#>
[CmdletBinding()]
param(
    [string] $SkillSource = (Join-Path $PSScriptRoot 'gui-ops-skill'),
    [string] $BundleDir = 'C:\agentdock-install\gui-ops-bundle',
    [string] $RuntimeRoot = 'C:\ProgramData\gui-ops',
    [string] $WorkerTask = 'AgentDock-GuiOpsWorker'
)

$ErrorActionPreference = 'Stop'
$summary = @{ ok = $false; bundle = ''; task = $WorkerTask; worker_alive = $false; message = '' }
$diagLog = 'C:\agentdock-install\gui-ops-install.log'

function Say([string] $m) {
    Write-Host ("[gui-ops] " + $m)
    try {
        if (-not (Test-Path -LiteralPath 'C:\agentdock-install')) { New-Item -ItemType Directory -Path 'C:\agentdock-install' -Force | Out-Null }
        Add-Content -LiteralPath $diagLog -Encoding ascii -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $m)
    } catch { }
}

try {
    # ---------- 1. build the mini bundle ----------
    $skillMd = Join-Path $SkillSource 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillMd)) { throw ("SKILL.md not found: " + $skillMd) }
    $md = [System.IO.File]::ReadAllText($skillMd)
    $name = ''
    $version = ''
    if ($md -match '(?m)^name:\s*(\S+)') { $name = $Matches[1] }
    if ($md -match '(?m)^version:\s*(\S+)') { $version = $Matches[1] }
    if ($name -ne 'gui-ops' -or -not $version) { throw ("bad SKILL.md identity name=" + $name + " version=" + $version) }

    $pkgDir = Join-Path $BundleDir 'packages'
    New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
    $zipPath = Join-Path $pkgDir ($name + '.zip')
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

    $stage = Join-Path $env:TEMP ('guiops-stage-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        Copy-Item -Path (Join-Path $SkillSource '*') -Destination $stage -Recurse -Force
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipPath,
            [System.IO.Compression.CompressionLevel]::Optimal, $false)
    } finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.IO.File]::ReadAllBytes($zipPath))
    } finally { $sha.Dispose() }
    $digest = 'sha256:' + (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
    $manifest = @{ skills = @(@{ name = $name; version = $version; path = ('packages/' + $name + '.zip'); digest = $digest }) }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $BundleDir 'manifest.json'),
        ($manifest | ConvertTo-Json -Depth 6), $utf8)
    Say ('bundle ready: ' + $BundleDir + ' (' + $version + ')')
    $summary.bundle = $BundleDir

    # ---------- 2. runtime dir + ACL ----------
    foreach ($d in @($RuntimeRoot, (Join-Path $RuntimeRoot 'queue'), (Join-Path $RuntimeRoot 'out'))) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    # Grant BUILTIN\Users Modify (language-independent SID) so both the exec account
    # and the desktop account can exchange files.
    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
    & $icacls $RuntimeRoot /grant '*S-1-5-32-545:(OI)(CI)M' /Q | Out-Null
    Copy-Item -LiteralPath (Join-Path $SkillSource 'scripts\guiworker.ps1') -Destination (Join-Path $RuntimeRoot 'guiworker.ps1') -Force
    Say ('runtime ready: ' + $RuntimeRoot)

    # ---------- 3. scheduled task (current user, Interactive => own desktop session) ----------
    # NOTE: no logon trigger on purpose - every boot is a fresh VM whose workflow
    # re-runs this script and starts the task immediately (same pattern as
    # billddesk-bootstrap, which is proven to work in this context).
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $psExe `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $RuntimeRoot 'guiworker.ps1') + '"')
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
    Say ('registering task user=' + $env:USERNAME + ' exe=' + $psExe)
    Register-ScheduledTask -TaskName $WorkerTask -Action $action `
        -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null
    Say 'task registered'
    Start-ScheduledTask -TaskName $WorkerTask
    Say ('task started: ' + $WorkerTask)

    # ---------- 4. wait for heartbeat ----------
    $statusFile = Join-Path $RuntimeRoot 'status.json'
    $alive = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            if (Test-Path -LiteralPath $statusFile) {
                $st = [System.IO.File]::ReadAllText($statusFile) | ConvertFrom-Json
                if ($st.ok -and $st.session -ge 0) { $alive = $true; break }
            }
        } catch { }
    }
    $summary.worker_alive = $alive
    if ($alive) {
        $summary.ok = $true
        $summary.message = 'gui-ops deployed; worker heartbeat OK'
    } else {
        $summary.message = 'task started but no heartbeat; check ' + (Join-Path $RuntimeRoot 'worker.log')
    }
} catch {
    $summary.message = 'exception: ' + $_.Exception.Message
    Say ('EXCEPTION at line ' + $_.InvocationInfo.ScriptLineNumber + ': ' + $_.Exception.ToString())
}

$summary | ConvertTo-Json -Depth 4 -Compress | Write-Host
if ($summary.ok) { exit 0 }
exit 1
