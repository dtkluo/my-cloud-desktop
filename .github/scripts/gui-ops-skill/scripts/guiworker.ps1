# guiworker.ps1 - AgentDock gui-ops resident worker for the INTERACTIVE session.
# Runs as the desktop user (runneradmin) via a scheduled task (LogonType Interactive).
# Polls $Root\queue\*.json, executes GUI actions with SendInput/GDI, writes
# $Root\out\<id>.json (+ PNG for screenshots). All code/comments ASCII only.
param(
    [string] $Root = 'C:\ProgramData\gui-ops'
)

$ErrorActionPreference = 'Continue'
$queueDir   = Join-Path $Root 'queue'
$outDir     = Join-Path $Root 'out'
$statusFile = Join-Path $Root 'status.json'
$logFile    = Join-Path $Root 'worker.log'

function W([string] $m) {
    try {
        Add-Content -LiteralPath $logFile -Encoding ascii -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $m)
    } catch { }
}

if (-not (Test-Path -LiteralPath $queueDir)) { New-Item -ItemType Directory -Path $queueDir -Force | Out-Null }
if (-not (Test-Path -LiteralPath $outDir))   { New-Item -ItemType Directory -Path $outDir -Force   | Out-Null }

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class GuiNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    // Mouse INPUT (type + MOUSEINPUT) - layout-identical to Win32 INPUT on x64 (40 bytes).
    [StructLayout(LayoutKind.Sequential)]
    public struct MINPUT { public uint type; public MOUSEINPUT mi; }
    // Keyboard INPUT padded to the same 40-byte stride as MINPUT.
    [StructLayout(LayoutKind.Sequential)]
    public struct KINPUT { public uint type; public KEYBDINPUT ki; public ulong pad; }
    [DllImport("user32.dll")]
    public static extern uint SendInput(uint nInputs, MINPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")]
    public static extern uint SendInput(uint nInputs, KINPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int maxCount);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int index);
}
"@

[GuiNative]::SetProcessDPIAware() | Out-Null

# SM_* virtual screen metric indexes
$script:SM_X = 76; $script:SM_Y = 77; $script:SM_W = 78; $script:SM_H = 79

function Get-VirtualScreen {
    return @{
        x = [GuiNative]::GetSystemMetrics($script:SM_X)
        y = [GuiNative]::GetSystemMetrics($script:SM_Y)
        w = [GuiNative]::GetSystemMetrics($script:SM_W)
        h = [GuiNative]::GetSystemMetrics($script:SM_H)
    }
}

$MF_MOVE      = 0x0001
$MF_LEFTDOWN  = 0x0002
$MF_LEFTUP    = 0x0004
$MF_RIGHTDOWN = 0x0008
$MF_RIGHTUP   = 0x0010
$MF_MIDDLEDOWN= 0x0020
$MF_MIDDLEUP  = 0x0040
$MF_WHEEL     = 0x0800
$MF_ABSOLUTE  = 0x8000
$MF_VIRTUALDESK = 0x4000
$KF_KEYUP     = 0x0002
$KF_UNICODE   = 0x0004

function Send-Mouse([uint32] $flags, [int] $dx, [int] $dy, [int] $wheel) {
    $inp = New-Object GuiNative+MINPUT
    $inp.type = 0
    $inp.mi.dx = $dx
    $inp.mi.dy = $dy
    if ($wheel -lt 0) {
        $inp.mi.mouseData = [uint32]($wheel -band 0xFFFFFFFF)
    } else {
        $inp.mi.mouseData = [uint32]$wheel
    }
    $inp.mi.dwFlags = $flags
    $cb = [System.Runtime.InteropServices.Marshal]::SizeOf([type][GuiNative+MINPUT])
    [void][GuiNative]::SendInput(1, @($inp), $cb)
}

function Move-MouseAbs([int] $x, [int] $y) {
    $vs = Get-VirtualScreen
    $w = [Math]::Max(1, $vs.w); $h = [Math]::Max(1, $vs.h)
    $nx = [int]((($x - $vs.x) * 65535.0) / $w)
    $ny = [int]((($y - $vs.y) * 65535.0) / $h)
    Send-Mouse ([uint32]($MF_MOVE -bor $MF_ABSOLUTE -bor $MF_VIRTUALDESK)) $nx $ny 0
    [void][GuiNative]::SetCursorPos($x, $y)
}

function Send-Click([int] $x, [int] $y, [string] $button, [bool] $isDouble) {
    Move-MouseAbs $x $y
    Start-Sleep -Milliseconds 60
    $down = $MF_LEFTDOWN; $up = $MF_LEFTUP
    if ($button -eq 'right') { $down = $MF_RIGHTDOWN; $up = $MF_RIGHTUP }
    elseif ($button -eq 'middle') { $down = $MF_MIDDLEDOWN; $up = $MF_MIDDLEUP }
    Send-Mouse ([uint32]$down) 0 0 0
    Start-Sleep -Milliseconds 40
    Send-Mouse ([uint32]$up) 0 0 0
    if ($isDouble) {
        Start-Sleep -Milliseconds 90
        Send-Mouse ([uint32]$down) 0 0 0
        Start-Sleep -Milliseconds 40
        Send-Mouse ([uint32]$up) 0 0 0
    }
}

$script:VkMap = @{
    'ctrl' = 0x11; 'alt' = 0x12; 'shift' = 0x10; 'win' = 0x5B; 'lwin' = 0x5B; 'rwin' = 0x5C
    'enter' = 0x0D; 'return' = 0x0D; 'tab' = 0x09; 'esc' = 0x1B; 'escape' = 0x1B
    'space' = 0x20; 'backspace' = 0x08; 'delete' = 0x2E; 'del' = 0x2E; 'insert' = 0x2D
    'home' = 0x24; 'end' = 0x23; 'pgup' = 0x21; 'pageup' = 0x21; 'pgdn' = 0x22; 'pagedown' = 0x22
    'up' = 0x26; 'down' = 0x28; 'left' = 0x25; 'right' = 0x27
}
for ($i = 1; $i -le 12; $i++) { $script:VkMap[('f' + $i)] = 0x6F + $i }
for ($i = 0; $i -le 9; $i++)  { $script:VkMap[[string]$i] = 0x30 + $i }
foreach ($c in 'abcdefghijklmnopqrstuvwxyz'.ToCharArray()) {
    $script:VkMap[[string]$c] = [int][char]$c - 32
}

function Send-KeyCombo([string] $combo) {
    $parts = @($combo -split '\+' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
    $vks = @()
    foreach ($p in $parts) {
        if ($script:VkMap.ContainsKey($p)) { $vks += [int]$script:VkMap[$p] }
        elseif ($p.Length -eq 1) { $vks += [int][char]$p.ToUpper() }
    }
    if ($vks.Count -eq 0) { throw ('no valid key in combo: ' + $combo) }
    $cb = [System.Runtime.InteropServices.Marshal]::SizeOf([type][GuiNative+KINPUT])
    $inputs = New-Object 'System.Collections.Generic.List[GuiNative+KINPUT]'
    foreach ($vk in $vks) {
        $inp = New-Object GuiNative+KINPUT
        $inp.type = 1; $inp.ki.wVk = [uint16]$vk; $inp.ki.dwFlags = 0; $inp.pad = 0
        $inputs.Add($inp)
    }
    for ($i = $vks.Count - 1; $i -ge 0; $i--) {
        $inp = New-Object GuiNative+KINPUT
        $inp.type = 1; $inp.ki.wVk = [uint16]$vks[$i]; $inp.ki.dwFlags = [uint32]$KF_KEYUP; $inp.pad = 0
        $inputs.Add($inp)
    }
    [void][GuiNative]::SendInput([uint32]$inputs.Count, $inputs.ToArray(), $cb)
}

function Send-Text([string] $text) {
    $cb = [System.Runtime.InteropServices.Marshal]::SizeOf([type][GuiNative+KINPUT])
    $chars = $text.ToCharArray()
    foreach ($ch in $chars) {
        if ($ch -eq "`n") {
            $inp = New-Object GuiNative+KINPUT
            $inp.type = 1; $inp.ki.wVk = 0x0D; $inp.ki.dwFlags = 0; $inp.pad = 0
            [void][GuiNative]::SendInput(1, @($inp), $cb)
            $inp2 = New-Object GuiNative+KINPUT
            $inp2.type = 1; $inp2.ki.wVk = 0x0D; $inp2.ki.dwFlags = [uint32]$KF_KEYUP; $inp2.pad = 0
            [void][GuiNative]::SendInput(1, @($inp2), $cb)
            continue
        }
        $code = [int]$ch
        $inp = New-Object GuiNative+KINPUT
        $inp.type = 1; $inp.ki.wScan = [uint16]$code; $inp.ki.dwFlags = [uint32]$KF_UNICODE; $inp.pad = 0
        [void][GuiNative]::SendInput(1, @($inp), $cb)
        $inp2 = New-Object GuiNative+KINPUT
        $inp2.type = 1; $inp2.ki.wScan = [uint16]$code; $inp2.ki.dwFlags = [uint32]($KF_UNICODE -bor $KF_KEYUP); $inp2.pad = 0
        [void][GuiNative]::SendInput(1, @($inp2), $cb)
        Start-Sleep -Milliseconds 6
    }
}

function Get-WindowInfo([IntPtr] $hWnd) {
    $len = 0
    $sb = New-Object System.Text.StringBuilder 512
    [void][GuiNative]::GetWindowText($hWnd, $sb, 512)
    $pid2 = [uint32]0
    [void][GuiNative]::GetWindowThreadProcessId($hWnd, [ref]$pid2)
    $r = New-Object GuiNative+RECT
    [void][GuiNative]::GetWindowRect($hWnd, [ref]$r)
    $procName = ''
    try { $p = Get-Process -Id $pid2 -ErrorAction Stop; $procName = $p.ProcessName } catch { }
    return @{
        hwnd   = $hWnd.ToInt64()
        title  = $sb.ToString()
        pid    = $pid2
        proc   = $procName
        rect   = @{ x = $r.Left; y = $r.Top; w = ($r.Right - $r.Left); h = ($r.Bottom - $r.Top) }
    }
}

function Find-Window([string] $title) {
    $found = [IntPtr]::Zero
    $cb = [GuiNative+EnumWindowsProc] {
        param([IntPtr] $h, [IntPtr] $lp)
        if ([GuiNative]::IsWindowVisible($h)) {
            $sb = New-Object System.Text.StringBuilder 512
            [void][GuiNative]::GetWindowText($h, $sb, 512)
            $t = $sb.ToString()
            if ($t -and $t.ToLower().Contains($script:findTitle.ToLower())) {
                $script:foundHwnd = $h
                return $false
            }
        }
        return $true
    }
    $script:findTitle = $title
    $script:foundHwnd = [IntPtr]::Zero
    [void][GuiNative]::EnumWindows($cb, [IntPtr]::Zero)
    return $script:foundHwnd
}

function Do-Screenshot([string] $pngPath) {
    $vs = Get-VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $vs.w, $vs.h
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.CopyFromScreen($vs.x, $vs.y, 0, 0, (New-Object System.Drawing.Size $vs.w, $vs.h))
        } finally { $g.Dispose() }
        $bmp.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $bmp.Dispose() }
    return @{ width = $vs.w; height = $vs.h }
}

function Invoke-Command([hashtable] $cmd) {
    $op = [string]$cmd['op']
    $res = @{ op = $op; ok = $false }
    switch ($op) {
        'ping' {
            $res.ok = $true
            $res.echo = [string]$cmd['echo']
        }
        'screenshot' {
            $id = [string]$cmd['_id']
            $pngPath = Join-Path $outDir ($id + '.png')
            $info = Do-Screenshot $pngPath
            $res.ok = $true
            $res.file = $pngPath
            $res.width = $info.width
            $res.height = $info.height
        }
        'click' {
            Send-Click ([int]$cmd['x']) ([int]$cmd['y']) ([string]$cmd['button']) ([bool]$cmd['double'])
            $res.ok = $true
        }
        'move' {
            Move-MouseAbs ([int]$cmd['x']) ([int]$cmd['y'])
            $res.ok = $true
        }
        'scroll' {
            Move-MouseAbs ([int]$cmd['x']) ([int]$cmd['y'])
            Start-Sleep -Milliseconds 60
            Send-Mouse ([uint32]$MF_WHEEL) 0 0 ([int]$cmd['delta'])
            $res.ok = $true
        }
        'type' {
            Send-Text ([string]$cmd['text'])
            $res.ok = $true
        }
        'key' {
            Send-KeyCombo ([string]$cmd['keys'])
            $res.ok = $true
        }
        'window' {
            $action = [string]$cmd['action']
            if ($action -eq 'list') {
                $wins = New-Object System.Collections.Generic.List[object]
                $cb = [GuiNative+EnumWindowsProc] {
                    param([IntPtr] $h, [IntPtr] $lp)
                    if ([GuiNative]::IsWindowVisible($h)) {
                        $sb = New-Object System.Text.StringBuilder 512
                        [void][GuiNative]::GetWindowText($h, $sb, 512)
                        if ($sb.ToString().Length -gt 0) { $script:winList.Add((Get-WindowInfo $h)) }
                    }
                    return $true
                }
                $script:winList = $wins
                [void][GuiNative]::EnumWindows($cb, [IntPtr]::Zero)
                $res.ok = $true
                $res.windows = @($wins | Select-Object -First 40)
            } elseif ($action -eq 'activate') {
                $h = Find-Window ([string]$cmd['title'])
                if ($h -ne [IntPtr]::Zero) {
                    [void][GuiNative]::ShowWindow($h, 9)  # SW_RESTORE
                    Start-Sleep -Milliseconds 120
                    [void][GuiNative]::SetForegroundWindow($h)
                    Start-Sleep -Milliseconds 120
                    $res.ok = $true
                    $res.window = Get-WindowInfo $h
                } else {
                    $res.error = 'window-not-found'
                }
            } elseif ($action -eq 'foreground') {
                $h = [GuiNative]::GetForegroundWindow()
                if ($h -ne [IntPtr]::Zero) {
                    $res.ok = $true
                    $res.window = Get-WindowInfo $h
                } else { $res.ok = $true; $res.window = $null }
            } else {
                $res.error = 'unknown-window-action'
            }
        }
        'sleep' {
            $ms = [int]$cmd['ms']
            if ($ms -lt 0) { $ms = 0 }
            if ($ms -gt 10000) { $ms = 10000 }
            Start-Sleep -Milliseconds $ms
            $res.ok = $true
        }
        default { $res.error = 'unknown-op' }
    }
    return $res
}

function Write-Status([hashtable] $extra) {
    try {
        $s = @{
            ok         = $true
            pid        = $PID
            session    = (Get-Process -Id $PID).SessionId
            user       = $env:USERNAME
            started_at = $script:startedAt
            last_beat  = (Get-Date).ToUniversalTime().ToString('o')
            processed  = $script:processed
        }
        foreach ($k in $extra.Keys) { $s[$k] = $extra[$k] }
        [System.IO.File]::WriteAllText($statusFile, ($s | ConvertTo-Json -Depth 5 -Compress), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# ---- prune stale result files (>2h) ----
try {
    $cut = (Get-Date).AddHours(-2)
    Get-ChildItem -LiteralPath $outDir -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut } | Remove-Item -Force -ErrorAction SilentlyContinue
} catch { }

$script:startedAt = (Get-Date).ToUniversalTime().ToString('o')
$script:processed = 0
$mySession = (Get-Process -Id $PID).SessionId
W ("worker start pid=$PID session=$mySession user=$env:USERNAME root=$Root")

while ($true) {
    Write-Status @{}
    $pending = @()
    try {
        $pending = @(Get-ChildItem -LiteralPath $queueDir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    } catch { }
    foreach ($f in $pending) {
        $id = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $cmdText = ''
        try { $cmdText = [System.IO.File]::ReadAllText($f.FullName) } catch { }
        $cmd = $null
        try { $cmd = $cmdText | ConvertFrom-Json } catch { }
        $res = $null
        if ($null -eq $cmd) {
            $res = @{ op = 'parse'; ok = $false; error = 'bad-json' }
        } else {
            $cmdHash = @{}
            foreach ($p in $cmd.PSObject.Properties) { $cmdHash[$p.Name] = $p.Value }
            $cmdHash['_id'] = $id
            try {
                $res = Invoke-Command $cmdHash
            } catch {
                $res = @{ op = [string]$cmdHash['op']; ok = $false; error = ('exception: ' + $_.Exception.Message) }
            }
        }
        $res['_id'] = $id
        if ($res.ContainsKey('op') -and $res['op'] -eq 'screenshot' -and $res.ok) {
            $fi = Get-Item -LiteralPath $res['file'] -ErrorAction SilentlyContinue
            if ($fi) { $res['size'] = $fi.Length }
        }
        try {
            $json = $res | ConvertTo-Json -Depth 6 -Compress
            [System.IO.File]::WriteAllText((Join-Path $outDir ($id + '.json')), $json, (New-Object System.Text.UTF8Encoding($false)))
        } catch {
            W ("result write failed id=$id err=" + $_.Exception.Message)
        }
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        $script:processed++
        W ("done id=$id op=" + $res['op'] + " ok=" + $res['ok'])
        Start-Sleep -Milliseconds 120
    }
    Start-Sleep -Milliseconds 250
}
