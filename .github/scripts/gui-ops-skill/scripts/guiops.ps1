# guiops.ps1 - AgentDock gui-ops client. Runs in ANY session (typically the
# AgentDock exec session). Submits a command JSON to the worker queue and waits
# for the result. Output: a single JSON line on stdout. ASCII only.
param(
    [Parameter(Mandatory = $true)][string] $Op,
    [int] $X = -1,
    [int] $Y = -1,
    [int] $W = -1,
    [int] $H = -1,
    [string] $Text = '',
    [string] $Keys = '',
    [string] $Title = '',
    [ValidateSet('left', 'right', 'middle')]
    [string] $Button = 'left',
    [switch] $Double,
    [int] $Delta = -120,
    [string] $Action = '',
    [int] $Ms = 0,
    [string] $Echo = '',
    [string] $Out = '',
    [int] $TimeoutSec = 25,
    [int] $SettleMs = 200,
    [string] $Root = 'C:\ProgramData\gui-ops'
)

$ErrorActionPreference = 'Stop'
$queueDir   = Join-Path $Root 'queue'
$outDir     = Join-Path $Root 'out'
$statusFile = Join-Path $Root 'status.json'

function Out-Json([hashtable] $o) {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::Out.Write(($o | ConvertTo-Json -Depth 6 -Compress))
    [Console]::Out.Write("`n")
}

function Fail([string] $code, [string] $msg, [string] $hint) {
    $o = @{ op = $Op; ok = $false; error = $code; message = $msg }
    if ($hint) { $o['hint'] = $hint }
    Out-Json $o
    exit 1
}

if (-not (Test-Path -LiteralPath $queueDir)) {
    Fail 'queue-missing' ('queue dir not found: ' + $queueDir) 'worker not installed; run install-guiops.ps1 on the host'
}

# ---- worker liveness (heartbeat must be newer than 15s) ----
$alive = $false
$beatAge = -1
try {
    if (Test-Path -LiteralPath $statusFile) {
        $st = [System.IO.File]::ReadAllText($statusFile) | ConvertFrom-Json
        $beat = [datetime]$st.last_beat
        $beatAge = [int]([DateTime]::UtcNow - $beat.ToUniversalTime()).TotalSeconds
        if ($beatAge -lt 15) { $alive = $true }
    }
} catch { }
if (-not $alive) {
    Fail 'worker-not-running' ('no fresh worker heartbeat (age=' + $beatAge + 's)') 'start scheduled task AgentDock-GuiOpsWorker; check ' + (Join-Path $Root 'worker.log')
}

# ---- build command ----
$cmd = @{ op = $Op }
switch ($Op) {
    'screenshot' { }
    'click' {
        if ($X -lt 0 -or $Y -lt 0) { Fail 'bad-args' 'click requires -X and -Y' '' }
        $cmd['x'] = $X; $cmd['y'] = $Y; $cmd['button'] = $Button; $cmd['double'] = [bool]$Double
    }
    'move' {
        if ($X -lt 0 -or $Y -lt 0) { Fail 'bad-args' 'move requires -X and -Y' '' }
        $cmd['x'] = $X; $cmd['y'] = $Y
    }
    'scroll' {
        if ($X -lt 0 -or $Y -lt 0) { Fail 'bad-args' 'scroll requires -X and -Y' '' }
        $cmd['x'] = $X; $cmd['y'] = $Y; $cmd['delta'] = $Delta
    }
    'type' {
        if ($Text -eq '') { Fail 'bad-args' 'type requires -Text' '' }
        $cmd['text'] = $Text
    }
    'key' {
        if ($Keys -eq '') { Fail 'bad-args' 'key requires -Keys (e.g. ctrl+shift+esc)' '' }
        $cmd['keys'] = $Keys
    }
    'window' {
        if ($Action -eq '') { Fail 'bad-args' 'window requires -Action (list|activate|foreground)' '' }
        $cmd['action'] = $Action
        if ($Action -eq 'activate') {
            if ($Title -eq '') { Fail 'bad-args' 'window activate requires -Title' '' }
            $cmd['title'] = $Title
        }
    }
    'sleep' { $cmd['ms'] = $Ms }
    'ping'  { $cmd['echo'] = $Echo }
    default { Fail 'bad-op' ('unknown op: ' + $Op) 'valid: screenshot|click|move|scroll|type|key|window|sleep|ping' }
}

# ---- submit (write tmp then atomic move so worker never sees a partial file) ----
$id = [guid]::NewGuid().ToString('N')
$qFile = Join-Path $queueDir ($id + '.json')
$tmpFile = Join-Path $queueDir ($id + '.tmp')
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($tmpFile, ($cmd | ConvertTo-Json -Depth 5 -Compress), $utf8)
Move-Item -LiteralPath $tmpFile -Destination $qFile -Force

# ---- wait for result ----
$rFile = Join-Path $outDir ($id + '.json')
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
$resultText = $null
while ([DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 150
    if (Test-Path -LiteralPath $rFile) {
        try {
            $resultText = [System.IO.File]::ReadAllText($rFile)
            break
        } catch { }
    }
}
if ($null -eq $resultText) {
    Fail 'timeout' ('no result within ' + $TimeoutSec + 's') 'check ' + (Join-Path $Root 'worker.log')
}

$res = $resultText | ConvertFrom-Json
Remove-Item -LiteralPath $rFile -Force -ErrorAction SilentlyContinue

# ---- post processing ----
$outObj = @{ op = $Op; ok = [bool]$res.ok }
foreach ($p in $res.PSObject.Properties) {
    if ($p.Name -ne '_id' -and $p.Name -ne 'op' -and $p.Name -ne 'ok') { $outObj[$p.Name] = $p.Value }
}
if ($Op -eq 'screenshot' -and $outObj['ok']) {
    Start-Sleep -Milliseconds $SettleMs
    if ($Out -ne '') {
        $destDir = Split-Path -Parent $Out
        if ($destDir -and -not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Copy-Item -LiteralPath $res.file -Destination $Out -Force
        $outObj['file'] = $Out
    }
}
Out-Json $outObj
if ($outObj['ok']) { exit 0 }
exit 1
