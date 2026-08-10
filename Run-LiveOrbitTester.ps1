<#
.SYNOPSIS
Controls the real, visible Orbit or Bust 2 Windows build as a feedback-driven tester.

.DESCRIPTION
Captures the 1280x720 game client, reads rendered telemetry with Windows.Media.Ocr,
sends verified foreground keyboard/mouse input, aborts doomed or noncompetitive runs,
and persists build-keyed learning state. The flight loop makes no model, API, or
network calls.

.PARAMETER Mode
Validate performs local prerequisite checks and is the safe default. Run controls the
live game. Probe inspects a live frame or replays -ProbeImage offline.

.PARAMETER Preset
SRB, Heavy, or Orbiter tests one craft. All tests each craft and uses the saved best
time to bound later attempts.

.PARAMETER MaxAttempts
Maximum attempts per selected preset.

.PARAMETER GameExe
Path to OrbitOrBust2.exe. Defaults to OB2_GAME_EXE, then a sibling game repository.

.PARAMETER ExpectedSha256
Build identity guard for a known build.

.PARAMETER AllowUnknownBuild
Explicitly permits a build whose SHA-256 differs from ExpectedSha256. Use only while
creating and validating a new build-specific adapter and benchmark.

.PARAMETER LearningStatePath
Mutable state path. When omitted, state is isolated by executable SHA-256 beneath
the current user's local application-data directory.

.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Run-LiveOrbitTester.ps1 -Mode Run -Preset All -MaxAttempts 1

.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Run-LiveOrbitTester.ps1 -Mode Probe -ProbeImage .\benchmarks\94CA7490BB67F23E34BEB87B8C73E7D85D6C767A259BC2A90C57C39F0BB0EC42\evidence\srb\019_stable_orbit.png
#>
param(
    [ValidateSet('Validate', 'Run', 'Probe')]
    [string] $Mode = 'Validate',
    [int] $MaxAttempts = 1,
    [ValidateSet('SRB', 'Heavy', 'Orbiter', 'All')]
    [string] $Preset = 'SRB',
    [double] $TurnStartM = 350.0,
    [double] $TurnEndM = 30000.0,
    [double] $TargetApM = 82000.0,
    [double] $TargetPeM = 71000.0,
    [double] $MaxAoARad = 0.28,
    [double] $HardLimitS = 235.0,
    [string] $ProbeImage = '',
    [string] $ProbeKey = '',
    [int] $ProbeHoldMs = 500,
    [string] $GameExe = $env:OB2_GAME_EXE,
    [string] $ExpectedSha256 = '94CA7490BB67F23E34BEB87B8C73E7D85D6C767A259BC2A90C57C39F0BB0EC42',
    [switch] $AllowUnknownBuild,
    [string] $OutputRoot = (Join-Path $PSScriptRoot 'runs'),
    [string] $LearningStatePath = '',
    [string] $BenchmarkStatePath = (Join-Path $PSScriptRoot 'benchmarks\94CA7490BB67F23E34BEB87B8C73E7D85D6C767A259BC2A90C57C39F0BB0EC42\best-known.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime

Add-Type -ReferencedAssemblies 'System.Drawing' -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class Oob2Win32
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT point);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int command);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int x, int y, int width, int height, bool repaint);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint mapType);
    [DllImport("user32.dll")] public static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);

    public static Bitmap DebugTextBitmap(Bitmap source, Rectangle crop, int scale)
    {
        using (var raw = new Bitmap(crop.Width, crop.Height, PixelFormat.Format24bppRgb))
        {
            using (var g = Graphics.FromImage(raw))
                g.DrawImage(source, new Rectangle(0, 0, crop.Width, crop.Height), crop, GraphicsUnit.Pixel);

            // Theme-muted F3 glyphs have substantial red+blue as well as green; the
            // terrain/sky does not. Produce OCR-friendly black glyphs on white without
            // changing what the player sees.
            for (var y = 0; y < raw.Height; y++)
            for (var x = 0; x < raw.Width; x++)
            {
                var c = raw.GetPixel(x, y);
                var glyph = c.R >= 145 && c.G >= 175 && c.B >= 125;
                raw.SetPixel(x, y, glyph ? Color.Black : Color.White);
            }

            var output = new Bitmap(raw.Width * scale, raw.Height * scale, PixelFormat.Format24bppRgb);
            using (var g = Graphics.FromImage(output))
            {
                g.Clear(Color.White);
                g.InterpolationMode = InterpolationMode.NearestNeighbor;
                g.PixelOffsetMode = PixelOffsetMode.Half;
                g.DrawImage(raw, new Rectangle(0, 0, output.Width, output.Height));
            }
            return output;
        }
    }
}
'@

[void][Oob2Win32]::SetProcessDPIAware()
[void][Windows.Graphics.Imaging.BitmapDecoder,Windows.Foundation,ContentType=WindowsRuntime]
[void][Windows.Graphics.Imaging.SoftwareBitmap,Windows.Foundation,ContentType=WindowsRuntime]
[void][Windows.Media.Ocr.OcrEngine,Windows.Foundation,ContentType=WindowsRuntime]
[void][Windows.Media.Ocr.OcrResult,Windows.Foundation,ContentType=WindowsRuntime]

$script:OcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
if ($null -eq $script:OcrEngine) { throw 'Windows.Media.Ocr is unavailable.' }

$script:Mu = 3.5316e12
$script:RadiusM = 600000.0
$script:AtmosphereM = 70000.0
$script:WindowWidth = 1298
$script:WindowHeight = 768
$script:ClientWidth = 1280
$script:ClientHeight = 720
$script:Window = [IntPtr]::Zero
$script:ExpectedProcessId = 0
$script:ExpectedExecutable = ''
$script:FlightActive = $false
$script:ControllerMutex = $null
$script:RunDirectory = $null
$script:TranscriptPath = $null
$script:LastEvidenceAt = -999.0
$script:EvidenceIndex = 0
$script:BestLiveTimeS = [double]::NaN

$script:Presets = @{
    # Coordinates are relative to the 1280x720 game client, not the desktop.
    SRB = @{ X = 1126; Y = 376; Craft = 'Strap-On Orbiter'; Parts = 10; Stages = 5 }
    Heavy = @{ X = 1125; Y = 327; Craft = 'Heavy-Lift Orbiter'; Parts = 8; Stages = 4 }
    Orbiter = @{ X = 1218; Y = 278; Craft = 'Orbit-Class Ascent'; Parts = 11; Stages = 4 }
}

$script:VirtualKeys = @{
    SPACE = 0x20; Z = 0x5A; X = 0x58; LEFT = 0x25; RIGHT = 0x27
    ESC = 0x1B; F3 = 0x72; O = 0x4F; L = 0x4C; PERIOD = 0xBE
    COMMA = 0xBC; M = 0x4D; T = 0x54; ENTER = 0x0D
}

function Await-WinRT {
    param($Operation, [Type] $ResultType)
    $method = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object {
            $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and
            $_.GetParameters().Count -eq 1
        } | Select-Object -First 1
    $task = $method.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    $task.Wait()
    return $task.Result
}

function Write-RunLog {
    param([string] $Message)
    $stamp = [DateTimeOffset]::UtcNow.ToString('o')
    $line = "$stamp`t$Message"
    Write-Host $line
    if ($script:TranscriptPath) { Add-Content -LiteralPath $script:TranscriptPath -Value $line -Encoding UTF8 }
}

function Get-RunRelativePath {
    param([string] $Path)
    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
        $fullRoot = [IO.Path]::GetFullPath($OutputRoot).TrimEnd('\') + '\'
        if ($fullPath.StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)) {
            return $fullPath.Substring($fullRoot.Length).Replace('\','/')
        }
    } catch { }
    return [IO.Path]::GetFileName($Path)
}

function Get-GameWindow {
    param([switch] $LaunchIfMissing)
    $resolvedExpected = [IO.Path]::GetFullPath($GameExe)
    $processName = [IO.Path]::GetFileNameWithoutExtension($resolvedExpected)
    $deadline = [DateTime]::UtcNow.AddSeconds($(if($LaunchIfMissing){25}else{12}))
    $launchChecked = $false
    do {
        $matches = @(Get-Process -Name $processName -ErrorAction SilentlyContinue |
            Where-Object {
                $_.MainWindowHandle -ne 0 -and
                $_.Path -and ([IO.Path]::GetFullPath($_.Path) -eq $resolvedExpected)
            })
        if ($matches.Count -gt 1) {
            throw "Multiple visible windows belong to $resolvedExpected; refusing ambiguous input."
        }
        $process = $matches | Select-Object -First 1
        if ($process) {
            $script:Window = $process.MainWindowHandle
            $script:ExpectedProcessId = $process.Id
            $script:ExpectedExecutable = $resolvedExpected
            [void][Oob2Win32]::ShowWindow($script:Window, 9)
            [void][Oob2Win32]::MoveWindow($script:Window, 0, 0, $script:WindowWidth, $script:WindowHeight, $true)
            [void][Oob2Win32]::SetForegroundWindow($script:Window)
            return $process
        }
        if ($LaunchIfMissing -and -not $launchChecked) {
            $launchChecked = $true
            $existing = Get-Process -Name $processName -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -and ([IO.Path]::GetFullPath($_.Path) -eq $resolvedExpected) } |
                Select-Object -First 1
            if (-not $existing) {
                [void](Start-Process -FilePath $GameExe -WorkingDirectory ([IO.Path]::GetDirectoryName($GameExe)) -PassThru)
            }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "No visible window belongs to $GameExe"
}

function Assert-TargetWindow {
    if ($script:Window -eq [IntPtr]::Zero -or $script:ExpectedProcessId -le 0) {
        [void](Get-GameWindow)
    }
    [void][Oob2Win32]::SetForegroundWindow($script:Window)
    Start-Sleep -Milliseconds 35
    $foreground = [Oob2Win32]::GetForegroundWindow()
    [uint32] $foregroundProcessId = 0
    if ($foreground -ne [IntPtr]::Zero) {
        [void][Oob2Win32]::GetWindowThreadProcessId($foreground, [ref]$foregroundProcessId)
    }
    if ($foreground -ne $script:Window -or $foregroundProcessId -ne $script:ExpectedProcessId) {
        throw 'The verified game window is not foreground; input was not sent.'
    }
    $foregroundProcess = Get-Process -Id $foregroundProcessId -ErrorAction Stop
    if (-not $foregroundProcess.Path -or
        [IO.Path]::GetFullPath($foregroundProcess.Path) -ne $script:ExpectedExecutable) {
        throw 'Foreground process path no longer matches the verified executable; input was not sent.'
    }
}

function Get-ClientScreenOrigin {
    [Oob2Win32+POINT] $origin = New-Object Oob2Win32+POINT
    if (-not [Oob2Win32]::ClientToScreen($script:Window, [ref]$origin)) {
        throw 'ClientToScreen failed.'
    }
    return $origin
}

function Get-WindowBitmap {
    if ($script:Window -eq [IntPtr]::Zero) { [void](Get-GameWindow) }
    [Oob2Win32+RECT] $rect = New-Object Oob2Win32+RECT
    if (-not [Oob2Win32]::GetClientRect($script:Window, [ref]$rect)) { throw 'GetClientRect failed.' }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -ne $script:ClientWidth -or $height -ne $script:ClientHeight) {
        throw "Unexpected game client size ${width}x${height}; expected $($script:ClientWidth)x$($script:ClientHeight)."
    }
    $origin = Get-ClientScreenOrigin
    $bitmap = [Drawing.Bitmap]::new($width, $height, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($origin.X, $origin.Y, 0, 0, $bitmap.Size, [Drawing.CopyPixelOperation]::SourceCopy)
    }
    finally { $graphics.Dispose() }
    return $bitmap
}

function Invoke-BitmapOcr {
    param([Drawing.Bitmap] $Bitmap, [switch] $SpatialLines)
    $memory = [IO.MemoryStream]::new()
    $stream = $null
    $softwareBitmap = $null
    try {
        $Bitmap.Save($memory, [Drawing.Imaging.ImageFormat]::Png)
        $memory.Position = 0
        $stream = [IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($memory)
        $decoder = Await-WinRT ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $softwareBitmap = Await-WinRT ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $result = Await-WinRT ($script:OcrEngine.RecognizeAsync($softwareBitmap)) ([Windows.Media.Ocr.OcrResult])
        $recognized = $result.Text
        if ($SpatialLines) {
            $words = @()
            foreach ($line in $result.Lines) {
                foreach ($word in $line.Words) {
                    $rect = $word.BoundingRect
                    $words += [pscustomobject]@{ Text=$word.Text; X=$rect.X; Y=($rect.Y+($rect.Height/2.0)) }
                }
            }
            $groups = [Collections.ArrayList]::new()
            foreach ($word in @($words | Sort-Object Y,X)) {
                $group = $null
                foreach ($candidate in $groups) {
                    if ([Math]::Abs($candidate.Y-$word.Y) -le 16.0) { $group=$candidate; break }
                }
                if ($null -eq $group) {
                    $group = [pscustomobject]@{ Y=$word.Y; Words=[Collections.ArrayList]::new() }
                    [void]$groups.Add($group)
                }
                [void]$group.Words.Add($word)
                $group.Y = ($group.Words | Measure-Object Y -Average).Average
            }
            $rebuilt = foreach ($group in @($groups | Sort-Object Y)) {
                (($group.Words | Sort-Object X | ForEach-Object Text) -join ' ')
            }
            $recognized = $rebuilt -join ' '
        }
        return ($recognized -replace '\b(?:mis|mfs)\b', 'm/s' -replace '\bO(?=\s*(?:m/s|kN|kPa))', '0' -replace '(?i)Ctril', 'Ctrl')
    }
    finally {
        if ($softwareBitmap) { $softwareBitmap.Dispose() }
        if ($stream) { $stream.Dispose() }
        $memory.Dispose()
    }
}

function Get-ScaledCrop {
    param(
        [Drawing.Bitmap] $Bitmap,
        [Drawing.Rectangle] $Crop,
        [int] $Scale = 4
    )
    $scaled = [Drawing.Bitmap]::new($Crop.Width*$Scale, $Crop.Height*$Scale, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [Drawing.Graphics]::FromImage($scaled)
    $attributes = [Drawing.Imaging.ImageAttributes]::new()
    try {
        $graphics.Clear([Drawing.Color]::White)
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::Half
        # The F3 overlay is intentionally subtle. Raise local contrast before OCR while
        # leaving the actual visible game unchanged.
        [single]$contrast = 3.2
        [single]$translate = (1.0-$contrast)/2.0
        $matrix = [Drawing.Imaging.ColorMatrix]::new([single[][]]@(
            @($contrast,0,0,0,0),
            @(0,$contrast,0,0,0),
            @(0,0,$contrast,0,0),
            @(0,0,0,1,0),
            @($translate,$translate,$translate,0,1)
        ))
        $attributes.SetColorMatrix($matrix)
        $destination = [Drawing.Rectangle]::new(0,0,$scaled.Width,$scaled.Height)
        $graphics.DrawImage($Bitmap,$destination,$Crop.X,$Crop.Y,$Crop.Width,$Crop.Height,[Drawing.GraphicsUnit]::Pixel,$attributes)
    }
    finally { $attributes.Dispose(); $graphics.Dispose() }
    return $scaled
}

function Get-DebugTextBitmap {
    param([Drawing.Bitmap] $Bitmap)
    # Historical evidence includes the 1298x768 outer frame; live captures use only
    # the privacy-safe 1280x720 client area.
    if ($Bitmap.Width -ge 1290 -and $Bitmap.Height -ge 760) {
        return [Oob2Win32]::DebugTextBitmap($Bitmap, [Drawing.Rectangle]::new(1088,160,202,154), 3)
    }
    return [Oob2Win32]::DebugTextBitmap($Bitmap, [Drawing.Rectangle]::new(1079,122,199,154), 3)
}

function Get-VisibleState {
    param([switch] $KeepBitmap)
    $bitmap = Get-WindowBitmap
    try {
        $text = Invoke-BitmapOcr $bitmap
        # OCR the low-contrast F3 overlay separately. Its fixed top-right crop avoids
        # column-order confusion and makes rendered pos/vel/angle available to the loop.
        $debugCrop = Get-DebugTextBitmap $bitmap
        try { $text += ' DEBUG_CROP ' + (Invoke-BitmapOcr $debugCrop -SpatialLines) }
        finally { $debugCrop.Dispose() }
        return [pscustomobject]@{ Text = $text; Bitmap = $(if ($KeepBitmap) { $bitmap.Clone() } else { $null }) }
    }
    finally { $bitmap.Dispose() }
}

function Save-Evidence {
    param([string] $Label, [double] $MissionTime = -1)
    if (-not $script:RunDirectory) { return }
    if ($MissionTime -ge 0 -and ($MissionTime - $script:LastEvidenceAt) -lt 4.0 -and $Label -eq 'periodic') { return }
    $script:EvidenceIndex++
    $safe = $Label -replace '[^A-Za-z0-9_-]', '_'
    $path = Join-Path $script:RunDirectory ('{0:D3}_{1}.png' -f $script:EvidenceIndex, $safe)
    $bitmap = Get-WindowBitmap
    try { $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png) }
    finally { $bitmap.Dispose() }
    if ($MissionTime -ge 0) { $script:LastEvidenceAt = $MissionTime }
    Write-RunLog "evidence label=$Label path=$(Get-RunRelativePath $path)"
}

function Send-PhysicalKey {
    param(
        [Parameter(Mandatory)][string] $Key,
        [int] $HoldMs = 55,
        [switch] $Quiet
    )
    $name = $Key.ToUpperInvariant()
    if (-not $script:VirtualKeys.ContainsKey($name)) { throw "Unknown key $Key" }
    Assert-TargetWindow
    $vk = [byte]$script:VirtualKeys[$name]
    $scan = [byte][Oob2Win32]::MapVirtualKey($vk, 0)
    [uint32]$downFlags = 0x0008
    if ($name -in @('LEFT','RIGHT')) { $downFlags = $downFlags -bor 0x0001 }
    try {
        [Oob2Win32]::keybd_event($vk, $scan, $downFlags, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds ([Math]::Max(10, $HoldMs))
    }
    finally {
        # Always release a key that this process pressed, even if the window loses focus.
        [Oob2Win32]::keybd_event($vk, $scan, ($downFlags -bor 0x0002), [UIntPtr]::Zero)
    }
    if (-not $Quiet) { Write-RunLog "action key=$name holdMs=$HoldMs" }
}

function Invoke-GameClick {
    param([int] $X, [int] $Y, [string] $Reason)
    if ($X -lt 0 -or $X -ge $script:ClientWidth -or $Y -lt 0 -or $Y -ge $script:ClientHeight) {
        throw "Refusing out-of-client click ($X,$Y)."
    }
    Assert-TargetWindow
    $origin = Get-ClientScreenOrigin
    $screenX = $origin.X + $X
    $screenY = $origin.Y + $Y
    if (-not [Oob2Win32]::SetCursorPos($screenX, $screenY)) {
        throw "SetCursorPos failed for verified client point ($X,$Y); click was not sent."
    }
    Assert-TargetWindow
    $confirmedOrigin = Get-ClientScreenOrigin
    [Oob2Win32+POINT] $cursor = New-Object Oob2Win32+POINT
    if ($confirmedOrigin.X -ne $origin.X -or $confirmedOrigin.Y -ne $origin.Y -or
        -not [Oob2Win32]::GetCursorPos([ref]$cursor) -or
        $cursor.X -ne $screenX -or $cursor.Y -ne $screenY) {
        throw "Cursor or game-client position changed before mouse-down; click was not sent."
    }
    try {
        [Oob2Win32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 45
    }
    finally {
        [Oob2Win32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    }
    Write-RunLog "action clientClick=($X,$Y) reason=$Reason"
}

function Convert-ToDouble {
    param([string] $Value)
    if ($null -eq $Value) { return [double]::NaN }
    $clean = $Value.Replace(',', '')
    [double]$parsed = 0.0
    $styles = [Globalization.NumberStyles]::Float -bor [Globalization.NumberStyles]::AllowThousands
    if ([double]::TryParse($clean,$styles,[Globalization.CultureInfo]::InvariantCulture,[ref]$parsed)) { return $parsed }
    return [double]::NaN
}

function Get-MatchDouble {
    param([string] $Text, [string] $Pattern, [string] $Group = 'n')
    $match = [regex]::Match($Text, $Pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) { return [double]::NaN }
    return Convert-ToDouble $match.Groups[$Group].Value
}

function Get-Telemetry {
    param([string] $Text)
    $normalized = $Text -replace "`r|`n", ' '
    $pos = [regex]::Match($normalized, 'pos:\s*[\(\{]\s*(?<x>-?[\d.,]+)\s*,\s*(?<y>-?[\d.,]+)\s*[\)\}]\s*m', 'IgnoreCase')
    $vel = [regex]::Match($normalized, 'vel:\s*[\(\{]\s*(?<x>-?[\d.,]+)\s*,\s*(?<y>-?[\d.,]+)\s*[\)\}]\s*m/s', 'IgnoreCase')
    if (-not $pos.Success) {
        $pos = [regex]::Match($normalized, '[\(\{]\s*(?<x>-?[\d.,]+)\s*,\s*(?<y>-?[\d.,]+)\s*[\)\}]\s*m(?!/s)', 'IgnoreCase')
    }
    if (-not $vel.Success) {
        $vel = [regex]::Match($normalized, '[\(\{]\s*(?<x>-?[\d.,]+)\s*,\s*(?<y>-?[\d.,]+)\s*[\)\}]\s*m/s', 'IgnoreCase')
    }
    $angleMatch = [regex]::Match($normalized, 'angle:\s*(?<n>-?[\daAbBoOsS.,]+)\s*deg', 'IgnoreCase')
    $angle = [double]::NaN
    if ($angleMatch.Success) {
        $angleGlyphs = $angleMatch.Groups['n'].Value -replace '[aAbB]', '8' -replace '[oO]', '0' -replace '[sS]', '5'
        $angle = Convert-ToDouble $angleGlyphs
    }
    if ([double]::IsNaN($angle)) {
        # Full-screen OCR sometimes lays out F3 as a label column followed by a value
        # column. The only degree-valued telemetry on this screen is vessel attitude.
        $angleValue = [regex]::Match($normalized, '\b(?<n>-?[\d.,]+)\s*deg\b', 'IgnoreCase')
        if ($angleValue.Success) { $angle = Convert-ToDouble $angleValue.Groups['n'].Value }
    }
    $ut = Get-MatchDouble $normalized 'ut:\s*(?<n>[\d.,]+)\s*s'
    if ([double]::IsNaN($ut)) {
        $missionClock = [regex]::Match($normalized, 'T\+\s*(?<min>\d{1,2})\s*:\s*(?<sec>\d{2}[\.,]\d)', 'IgnoreCase')
        if ($missionClock.Success) {
            $ut = (Convert-ToDouble $missionClock.Groups['min'].Value)*60.0 + (Convert-ToDouble $missionClock.Groups['sec'].Value)
        }
    }
    $tick = Get-MatchDouble $normalized 'tick:\s*(?<n>\d+)'
    $stageFuel = Get-MatchDouble $normalized 'Stage\s+fuel\s+(?<n>[\d.,]+)\s*t'
    $totalFuel = Get-MatchDouble $normalized 'Total\s+fuel\s+(?<n>[\d.,]+)\s*t'
    $mass = Get-MatchDouble $normalized 'Mass\s+(?<n>[\d.,]+)\s*t'
    $thrust = Get-MatchDouble $normalized 'Thrust\s+(?<n>[\d.,]+)\s*kN'
    $q = Get-MatchDouble $normalized '\bQ\s+(?<n>[\d.,]+)\s*kPa'

    $hudAltitude = [regex]::Match($normalized, 'ALTITUDE\s+(?<n>[\d.,]+)\s*(?<unit>km|m)\b', 'IgnoreCase')
    $hudVertical = Get-MatchDouble $normalized '(?<n>[+-]?[\d.,]+)\s*m/s\s*vertical'
    $hudSpeed = Get-MatchDouble $normalized 'SPEED\s+(?<n>[\d.,]+)\s*m/s'
    $hudAp = [regex]::Match($normalized, '\bAp\s+(?<n>-?[\d.,]+)\s*(?<unit>km|m)\b', 'IgnoreCase')
    $hudPe = [regex]::Match($normalized, '\bPe\s+(?<n>-?[\d.,]+)\s*(?<unit>km|m)\b', 'IgnoreCase')
    $hudTta = [regex]::Match($normalized, 'Time\s+to\s+apoapsis:\s*(?<min>\d+)\s*:\s*(?<sec>\d{2})', 'IgnoreCase')

    $hasDebugVector = $pos.Success -and $vel.Success
    $x = $y = $vx = $vy = [double]::NaN
    if ($pos.Success) { $x = Convert-ToDouble $pos.Groups['x'].Value; $y = Convert-ToDouble $pos.Groups['y'].Value }
    if ($vel.Success) { $vx = Convert-ToDouble $vel.Groups['x'].Value; $vy = Convert-ToDouble $vel.Groups['y'].Value }

    $alt = [double]::NaN; $ap = [double]::NaN; $pe = [double]::NaN
    $radial = [double]::NaN; $speed = [double]::NaN; $energy = [double]::NaN
    $timeToAp = [double]::NaN; $ecc = [double]::NaN; $semiMajor = [double]::NaN
    if ($hasDebugVector) {
        $r = [Math]::Sqrt($x*$x + $y*$y)
        $speed2 = $vx*$vx + $vy*$vy
        $speed = [Math]::Sqrt($speed2)
        $alt = $r - $script:RadiusM
        $radial = (($x*$vx) + ($y*$vy)) / $r
        $energy = ($speed2 / 2.0) - ($script:Mu / $r)
        if ($energy -lt 0) {
            $semiMajor = -$script:Mu / (2.0 * $energy)
            $rv = ($x*$vx) + ($y*$vy)
            $ex = ((($speed2 - ($script:Mu/$r))*$x) - ($rv*$vx)) / $script:Mu
            $ey = ((($speed2 - ($script:Mu/$r))*$y) - ($rv*$vy)) / $script:Mu
            $ecc = [Math]::Sqrt($ex*$ex + $ey*$ey)
            if ($ecc -lt 1.0) {
                $ap = ($semiMajor * (1.0 + $ecc)) - $script:RadiusM
                $pe = ($semiMajor * (1.0 - $ecc)) - $script:RadiusM
                if ($ecc -gt 1e-7) {
                    $cosE = [Math]::Max(-1.0, [Math]::Min(1.0, (1.0 - ($r/$semiMajor)) / $ecc))
                    $sinE = $rv / ($ecc * [Math]::Sqrt($script:Mu * $semiMajor))
                    $E = [Math]::Atan2($sinE, $cosE)
                    if ($E -lt 0) { $E += 2.0 * [Math]::PI }
                    $M = $E - ($ecc * [Math]::Sin($E))
                    $n = [Math]::Sqrt($script:Mu / [Math]::Pow($semiMajor, 3.0))
                    $deltaM = [Math]::PI - $M
                    while ($deltaM -lt 0) { $deltaM += 2.0 * [Math]::PI }
                    $timeToAp = $deltaM / $n
                }
            }
        }
    }

    $hudAltM = [double]::NaN
    if ($hudAltitude.Success) {
        $hudAltM = Convert-ToDouble $hudAltitude.Groups['n'].Value
        if ($hudAltitude.Groups['unit'].Value -match '(?i)km') { $hudAltM *= 1000.0 }
    }
    $hudApM = [double]::NaN
    if ($hudAp.Success) {
        $hudApM = Convert-ToDouble $hudAp.Groups['n'].Value
        if ($hudAp.Groups['unit'].Value -match '(?i)km') { $hudApM *= 1000.0 }
    }
    $hudPeM = [double]::NaN
    if ($hudPe.Success) {
        $hudPeM = Convert-ToDouble $hudPe.Groups['n'].Value
        if ($hudPe.Groups['unit'].Value -match '(?i)km') { $hudPeM *= 1000.0 }
    }

    # High-contrast HUD telemetry is the decision authority. F3 vectors add direction,
    # but only while their derived magnitude agrees with the independently rendered HUD.
    if ($hasDebugVector) {
        $altAgrees = [double]::IsNaN($hudAltM) -or [Math]::Abs($alt-$hudAltM) -le [Math]::Max(1500.0,[Math]::Abs($hudAltM)*0.04)
        $speedAgrees = [double]::IsNaN($hudSpeed) -or [Math]::Abs($speed-$hudSpeed) -le [Math]::Max(100.0,[Math]::Abs($hudSpeed)*0.20)
        $radialAgrees = [double]::IsNaN($hudVertical) -or [Math]::Abs($radial-$hudVertical) -le [Math]::Max(100.0,[Math]::Abs($hudVertical)*0.25)
        $hasDebugVector = $altAgrees -and $speedAgrees -and $radialAgrees
        if (-not $hasDebugVector) {
            $x=$y=$vx=$vy=[double]::NaN
            $alt=$speed=$radial=$ap=$pe=[double]::NaN
            $timeToAp=$semiMajor=$ecc=$energy=[double]::NaN
        }
    }
    if (-not [double]::IsNaN($hudAltM)) { $alt=$hudAltM }
    if (-not [double]::IsNaN($hudSpeed)) { $speed=$hudSpeed }
    if (-not [double]::IsNaN($hudVertical)) { $radial=$hudVertical }
    if (-not [double]::IsNaN($hudApM)) { $ap=$hudApM }
    if (-not [double]::IsNaN($hudPeM)) { $pe=$hudPeM }
    if ([double]::IsNaN($timeToAp) -and $hudTta.Success) {
        $timeToAp = (Convert-ToDouble $hudTta.Groups['min'].Value)*60.0 + (Convert-ToDouble $hudTta.Groups['sec'].Value)
    }
    if (-not [double]::IsNaN($ap) -and -not [double]::IsNaN($pe)) {
        $semiMajor = $script:RadiusM + (($ap+$pe)/2.0)
        if ($semiMajor -gt 0) {
            $energy = -$script:Mu/(2.0*$semiMajor)
            $ecc = [Math]::Abs($ap-$pe)/(2.0*$script:RadiusM+$ap+$pe)
        }
    }
    $hasDebug = -not [double]::IsNaN($ut) -and -not [double]::IsNaN($angle) -and
        -not [double]::IsNaN($alt) -and -not [double]::IsNaN($speed) -and -not [double]::IsNaN($radial)

    return [pscustomobject]@{
        HasDebug=$hasDebug; HasDebugVector=$hasDebugVector; Text=$normalized; Tick=$tick; UT=$ut
        X=$x; Y=$y; Vx=$vx; Vy=$vy; AngleDeg=$angle
        AltM=$alt; SpeedMps=$speed; RadialMps=$radial
        Energy=$energy; SemiMajorM=$semiMajor; Eccentricity=$ecc
        ApM=$ap; PeM=$pe; TimeToApS=$timeToAp
        StageFuelT=$stageFuel; TotalFuelT=$totalFuel; MassT=$mass
        ThrustKN=$thrust; QKPa=$q
        IsVab=($normalized -match 'CRAFT NAME' -and $normalized -match 'LAUNCH')
        IsFlight=($normalized -match 'MISSION TIME' -or $hasDebug)
        IsDebrief=($normalized -match 'MISSION DEBRIEF')
    }
}

function Get-WrappedRadians {
    param([double] $Radians)
    while ($Radians -gt [Math]::PI) { $Radians -= 2.0 * [Math]::PI }
    while ($Radians -lt -[Math]::PI) { $Radians += 2.0 * [Math]::PI }
    return $Radians
}

function Get-TargetAngle {
    param($Telemetry, [string] $Phase)
    $up = [Math]::Atan2($Telemetry.Y, $Telemetry.X)
    $prograde = if ($Telemetry.SpeedMps -gt 1.0) { [Math]::Atan2($Telemetry.Vy, $Telemetry.Vx) } else { $up }
    if ($Phase -eq 'pitch') {
        $fraction = [Math]::Max(0.0, [Math]::Min(1.0, ($Telemetry.AltM - $TurnStartM) / [Math]::Max(1.0, $TurnEndM - $TurnStartM)))
        $target = $up - ([Math]::Sqrt($fraction) * [Math]::PI / 2.0)
        if ($Telemetry.AltM -lt $script:AtmosphereM -and $Telemetry.SpeedMps -gt 100.0) {
            $offset = Get-WrappedRadians ($target - $prograde)
            $offset = [Math]::Max(-$MaxAoARad, [Math]::Min($MaxAoARad, $offset))
            $target = $prograde + $offset
        }
        return $target
    }
    return $prograde
}

function Wait-ForScene {
    param([ValidateSet('Vab','Flight')][string] $Scene, [double] $Seconds = 8.0)
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $state = Get-VisibleState
        $telemetry = Get-Telemetry $state.Text
        if (($Scene -eq 'Vab' -and $telemetry.IsVab) -or ($Scene -eq 'Flight' -and $telemetry.IsFlight)) { return $state.Text }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Scene scene."
}

function Return-ToVab {
    $state = Get-VisibleState
    $telemetry = Get-Telemetry $state.Text
    if ($telemetry.IsVab) { return }
    Send-PhysicalKey ESC 65
    [void](Wait-ForScene Vab 8)
    $script:FlightActive = $false
    Write-RunLog 'scene=VAB reason=revert'
}

function Select-PresetAndLaunch {
    param([string] $PresetName)
    Return-ToVab
    $spec = $script:Presets[$PresetName]
    Invoke-GameClick $spec.X $spec.Y "select-$PresetName"
    Start-Sleep -Milliseconds 250
    $vab = Get-VisibleState
    $verified = $vab.Text -match [regex]::Escape($spec.Craft) -and
        $vab.Text -match ('Parts\s*:?\s*{0}\b' -f $spec.Parts) -and
        $vab.Text -match ('Stages\s*:?\s*{0}\b' -f $spec.Stages)
    if (-not $verified) {
        Invoke-GameClick $spec.X $spec.Y "retry-select-$PresetName"
        Start-Sleep -Milliseconds 250
        $vab = Get-VisibleState
        $verified = $vab.Text -match [regex]::Escape($spec.Craft) -and
            $vab.Text -match ('Parts\s*:?\s*{0}\b' -f $spec.Parts) -and
            $vab.Text -match ('Stages\s*:?\s*{0}\b' -f $spec.Stages)
    }
    if (-not $verified) {
        throw "VAB OCR did not verify '$($spec.Craft)' with $($spec.Parts) parts and $($spec.Stages) stages."
    }
    Write-RunLog "preflight preset=$PresetName craft=$($spec.Craft) verified=true"
    Save-Evidence 'preflight_verified'
    Invoke-GameClick 1130 639 'launch'
    # From this point onward, any exception must attempt cut/revert cleanup even if
    # OCR has not yet confirmed the flight scene.
    $script:FlightActive = $true
    Start-Sleep -Milliseconds 220
    Send-PhysicalKey SPACE 55
    Send-PhysicalKey Z 40
    Start-Sleep -Milliseconds 80
    Send-PhysicalKey F3 50 -Quiet
    Write-RunLog 'launch immediateStage=true throttle=full debug=toggle'
    [void](Wait-ForScene Flight 6)
}

function Invoke-LiveAttempt {
    param([int] $AttemptNumber, [string] $PresetName)
    $attemptDir = Join-Path $script:RunDirectory ('attempt-{0:D2}-{1}' -f $AttemptNumber, $PresetName.ToLowerInvariant())
    [void](New-Item -ItemType Directory -Path $attemptDir -Force)
    $oldRunDir = $script:RunDirectory
    $script:RunDirectory = $attemptDir
    $script:EvidenceIndex = 0
    $script:LastEvidenceAt = -999.0

    Write-RunLog "attempt=$AttemptNumber preset=$PresetName status=preparing"
    Select-PresetAndLaunch $PresetName
    Save-Evidence 'liftoff'

    $phase = 'pitch'
    $previousPhase = ''
    $startUt = 0.0
    $previousAngleRad = [double]::NaN
    $previousUt = [double]::NaN
    $previousKinematicUt = [double]::NaN
    $upAngle = [Math]::PI/2.0
    $lastSaneSpeed = [double]::NaN
    $lastSaneAngle = [double]::NaN
    $lastSaneAngleUt = [double]::NaN
    $lastValidTta = [double]::NaN
    $lastValidTtaAtUt = [double]::NaN
    $maxThrust = 0.0
    $lastPositiveThrust = 0.0
    $lastStagePressUt = -99.0
    $lastGoodWall = [DateTime]::UtcNow
    $lastDebugToggleWall = [DateTime]::MinValue
    $badHeadingSince = [double]::NaN
    $successReads = 0
    $lastSuccessUt = [double]::NaN
    $lastLogUt = -999.0
    $reason = ''
    $result = 'aborted'
    $final = $null

    $wallDeadline = [DateTime]::UtcNow.AddMinutes(6)
    while ([DateTime]::UtcNow -lt $wallDeadline) {
        $visible = Get-VisibleState
        $t = Get-Telemetry $visible.Text
        if (-not $t.HasDebug) {
            if ($t.IsDebrief) { $reason = 'game-debrief-before-orbit'; break }
            if ($t.IsVab) { $reason = 'unexpected-vab'; break }
            # Do not toggle a visible overlay off just because one OCR frame lost a
            # number. Only restore F3 when its rendered title is actually absent.
            if ($visible.Text -notmatch '(?i)debug overlay' -and
                ([DateTime]::UtcNow-$lastDebugToggleWall).TotalSeconds -gt 0.8) {
                Send-PhysicalKey F3 40 -Quiet
                $lastDebugToggleWall = [DateTime]::UtcNow
            }
            if (([DateTime]::UtcNow - $lastGoodWall).TotalSeconds -gt 2.5) { $reason = 'telemetry-stale'; break }
            Start-Sleep -Milliseconds 45
            continue
        }
        $lastGoodWall = [DateTime]::UtcNow
        $elapsed = $t.UT - $startUt
        if ($elapsed -lt 0) { $elapsed = $t.UT }

        # Reject common pixel-font OCR artifacts without hiding sustained divergence.
        if ([Math]::Abs($t.AngleDeg) -gt 360.0) {
            if ([Math]::Abs($t.AngleDeg/10.0) -le 180.0) { $t.AngleDeg /= 10.0 }
            elseif ($t.AngleDeg -gt 360.0 -and $t.AngleDeg -lt 460.0) { $t.AngleDeg -= 400.0 }
        }
        if (-not [double]::IsNaN($lastSaneAngle) -and -not [double]::IsNaN($lastSaneAngleUt) -and $t.UT -gt $lastSaneAngleUt) {
            $candidateDeltaDeg = (Get-WrappedRadians (($t.AngleDeg-$lastSaneAngle)*[Math]::PI/180.0))*180.0/[Math]::PI
            $maxPlausibleDeltaDeg = [Math]::Max(6.0,8.0*($t.UT-$lastSaneAngleUt))
            if ([Math]::Abs($candidateDeltaDeg) -gt $maxPlausibleDeltaDeg) {
                Write-RunLog ('ocr-reject field=angle raw={0:F1} held={1:F1} delta={2:F1}' -f $t.AngleDeg,$lastSaneAngle,$candidateDeltaDeg)
                $t.AngleDeg = $lastSaneAngle
            } else {
                $lastSaneAngle = $t.AngleDeg
                $lastSaneAngleUt = $t.UT
            }
        } else {
            $lastSaneAngle = $t.AngleDeg
            $lastSaneAngleUt = $t.UT
        }
        if ($t.SpeedMps -gt 4000.0 -and $t.AltM -lt 200000.0) {
            $t.SpeedMps = if (-not [double]::IsNaN($lastSaneSpeed)) { [Math]::Max([Math]::Abs($t.RadialMps),$lastSaneSpeed) } else { [Math]::Abs($t.RadialMps) }
        }
        $lastSaneSpeed = $t.SpeedMps
        if (-not [double]::IsNaN($t.TimeToApS)) {
            $lastValidTta = $t.TimeToApS
            $lastValidTtaAtUt = $t.UT
        }
        $ttaForDecision = if (-not [double]::IsNaN($t.TimeToApS)) { $t.TimeToApS } elseif (-not [double]::IsNaN($lastValidTta)) { [Math]::Max(0.0,$lastValidTta-($t.UT-$lastValidTtaAtUt)) } else { [double]::NaN }

        # The subtle F3 vector text can lose punctuation in Windows OCR. The normal HUD
        # independently renders altitude, vertical speed, and total speed in high contrast.
        # Reconstruct the local frame from those values when needed; eastward motion is
        # known from the selected launch profile.
        if (-not $t.HasDebugVector) {
            if (-not [double]::IsNaN($previousKinematicUt) -and $t.UT -gt $previousKinematicUt) {
                $tangentForRate = [Math]::Sqrt([Math]::Max(0.0, ($t.SpeedMps*$t.SpeedMps)-($t.RadialMps*$t.RadialMps)))
                $upAngle -= ($tangentForRate/[Math]::Max(1.0,$script:RadiusM+$t.AltM))*($t.UT-$previousKinematicUt)
            }
            $rSynth = $script:RadiusM+$t.AltM
            $tangent = [Math]::Sqrt([Math]::Max(0.0, ($t.SpeedMps*$t.SpeedMps)-($t.RadialMps*$t.RadialMps)))
            $t.X = $rSynth*[Math]::Cos($upAngle)
            $t.Y = $rSynth*[Math]::Sin($upAngle)
            $t.Vx = ($t.RadialMps*[Math]::Cos($upAngle))+($tangent*[Math]::Sin($upAngle))
            $t.Vy = ($t.RadialMps*[Math]::Sin($upAngle))-($tangent*[Math]::Cos($upAngle))
        } else {
            $upAngle = [Math]::Atan2($t.Y,$t.X)
        }
        $previousKinematicUt = $t.UT

        if (-not [double]::IsNaN($t.ThrustKN) -and $t.ThrustKN -gt 0) {
            $lastPositiveThrust = $t.ThrustKN
            $maxThrust = [Math]::Max($maxThrust, $t.ThrustKN)
        }

        $orbitMessage = $t.Text -match 'ORBIT!|Periapsis\s+is\s+above\s+the\s+atmosphere'
        $orbitTelemetrySane = -not [double]::IsNaN($t.PeM) -and
            -not [double]::IsNaN($t.ApM) -and
            $t.PeM -gt $TargetPeM -and $t.ApM -ge $t.PeM -and $t.ApM -lt 10000000
        if ($orbitMessage -and $orbitTelemetrySane) {
            if ([double]::IsNaN($lastSuccessUt) -or $t.UT -gt ($lastSuccessUt + 0.05)) {
                $successReads++
                $lastSuccessUt = $t.UT
            }
        } else { $successReads = 0 }
        if ($successReads -ge 2) {
            Send-PhysicalKey X 45
            $phase = 'orbit'
            $result = 'success'
            $reason = 'live-periapsis-cleared-atmosphere'
            $final = $t
            Save-Evidence 'stable_orbit' $elapsed
            break
        }

        if ($phase -ne 'circularize') {
            if (-not [double]::IsNaN($t.ApM) -and $t.ApM -ge $TargetApM) {
                $halfBurn = 0.0
                if ($lastPositiveThrust -gt 0 -and -not [double]::IsNaN($t.MassT) -and $t.MassT -gt 0 -and $t.SemiMajorM -gt 0) {
                    $ra = $script:RadiusM + $t.ApM
                    $speedAtAp = [Math]::Sqrt([Math]::Max(0.0, $script:Mu*((2.0/$ra) - (1.0/$t.SemiMajorM))))
                    $circular = [Math]::Sqrt($script:Mu/$ra)
                    $accel = ($lastPositiveThrust*1000.0)/($t.MassT*1000.0)
                    if ($accel -gt 0) { $halfBurn = [Math]::Max(0.0, $circular-$speedAtAp)/$accel/2.0 }
                }
                if ($phase -eq 'pitch') {
                    Send-PhysicalKey X 45
                    $phase = 'coast'
                    Write-RunLog ('phase=coast elapsed={0:F2} apKm={1:F2} peKm={2:F2} tta={3:F1} halfBurn={4:F1}' -f $elapsed,($t.ApM/1000),($t.PeM/1000),$t.TimeToApS,$halfBurn)
                    Save-Evidence 'ascent_cutoff' $elapsed
                }
                if ($phase -eq 'coast' -and ($t.RadialMps -lt 0 -or (-not [double]::IsNaN($ttaForDecision) -and $ttaForDecision -le $halfBurn))) {
                    Send-PhysicalKey Z 45
                    $phase = 'circularize'
                    Write-RunLog ('phase=circularize elapsed={0:F2} apKm={1:F2} peKm={2:F2} tta={3:F1} halfBurn={4:F1}' -f $elapsed,($t.ApM/1000),($t.PeM/1000),$t.TimeToApS,$halfBurn)
                    Save-Evidence 'circularization_start' $elapsed
                }
            }
        }

        $lowerText = $t.Text.ToLowerInvariant()
        $cool = ($t.UT - $lastStagePressUt) -ge 0.8
        if ($cool -and $lowerText -match 'drop\s+(?:2\s+)?boosters') {
            $thrustLost = $maxThrust -gt 0 -and -not [double]::IsNaN($t.ThrustKN) -and $t.ThrustKN -lt ($maxThrust*0.80)
            if ($thrustLost -or (-not [double]::IsNaN($t.StageFuelT) -and $t.StageFuelT -le 0.02)) {
                Send-PhysicalKey SPACE 55
                $lastStagePressUt = $t.UT
                $maxThrust = 0.0
                Write-RunLog ('stage=drop-boosters elapsed={0:F2} thrustKN={1:F0}' -f $elapsed,$t.ThrustKN)
                Save-Evidence 'boosters_dropped' $elapsed
            }
        } elseif ($cool -and $lowerText -match '\[?space\]?\s*separate') {
            if (-not [double]::IsNaN($t.StageFuelT) -and $t.StageFuelT -le 0.02) {
                Send-PhysicalKey SPACE 55
                $lastStagePressUt = $t.UT
                $maxThrust = 0.0
                Write-RunLog ('stage=separate-hotstage elapsed={0:F2}' -f $elapsed)
                Save-Evidence 'core_separated' $elapsed
            }
        } elseif ($cool -and $lowerText -match '\[?space\]?\s*ignite' -and -not [double]::IsNaN($t.ThrustKN) -and $t.ThrustKN -le 0.1 -and $phase -ne 'coast') {
            Send-PhysicalKey SPACE 55
            $lastStagePressUt = $t.UT
            Write-RunLog ('stage=ignite elapsed={0:F2}' -f $elapsed)
        }

        $target = Get-TargetAngle $t $phase
        $angle = $t.AngleDeg * [Math]::PI / 180.0
        $error = Get-WrappedRadians ($target - $angle)
        $errorDeg = $error*180.0/[Math]::PI
        $thresholdDeg = if ($phase -eq 'pitch') { 0.9 } else { 1.2 }
        if ([Math]::Abs($errorDeg) -gt $thresholdDeg) {
            # In vacuum, a 15-95 ms duty cycle cannot arrest accumulated angular
            # momentum. SAS re-anchors after every release, so use deterministic
            # error-only pulses and give coast/circularization materially more authority.
            $hold = if ($phase -eq 'pitch') {
                [int][Math]::Min(170, 20+(7*[Math]::Abs($errorDeg)))
            } else {
                [int][Math]::Min(500, 40+(13*[Math]::Abs($errorDeg)))
            }
            if ($errorDeg -gt 0) { Send-PhysicalKey LEFT $hold -Quiet }
            else { Send-PhysicalKey RIGHT $hold -Quiet }
            if ([Math]::Abs($errorDeg) -gt 8.0) { Write-RunLog ('steer key={0} holdMs={1} errorDeg={2:F1}' -f $(if($errorDeg-gt0){'LEFT'}else{'RIGHT'}),$hold,$errorDeg) }
        }
        $previousAngleRad = $angle
        $previousUt = $t.UT

        if ([Math]::Abs($error) -gt (35.0*[Math]::PI/180.0) -and $t.AltM -gt 1000) {
            if ([double]::IsNaN($badHeadingSince)) { $badHeadingSince = $elapsed }
        } else { $badHeadingSince = [double]::NaN }

        if (($elapsed - $lastLogUt) -ge 1.0 -or $phase -ne $previousPhase) {
            Write-RunLog ('obs elapsed={0:F2} phase={1} altKm={2:F2} speed={3:F0} radial={4:F0} angle={5:F1} target={6:F1} apKm={7:F2} peKm={8:F2} fuelT={9:F2} thrustKN={10:F0}' -f $elapsed,$phase,($t.AltM/1000),$t.SpeedMps,$t.RadialMps,$t.AngleDeg,($target*180/[Math]::PI),($t.ApM/1000),($t.PeM/1000),$t.TotalFuelT,$t.ThrustKN)
            $lastLogUt = $elapsed
            $previousPhase = $phase
        }
        if (($elapsed % 15.0) -lt 0.35) { Save-Evidence 'periodic' $elapsed }

        if ($elapsed -ge $HardLimitS) { $reason = 'hard-mission-time-limit'; $final=$t; break }
        if (-not [double]::IsNaN($script:BestLiveTimeS) -and $elapsed -ge $script:BestLiveTimeS -and $t.PeM -lt $TargetPeM) { $reason='best-live-time-exceeded'; $final=$t; break }
        if (-not [double]::IsNaN($badHeadingSince) -and ($elapsed-$badHeadingSince) -gt 2.0) { $reason='heading-diverged'; $final=$t; break }
        if ($t.Energy -ge 0 -and $t.AltM -gt 1000) { $reason='escape-trajectory-not-fast-orbit'; $final=$t; break }
        if (-not [double]::IsNaN($t.ApM) -and $t.ApM -gt 350000 -and $t.PeM -lt $script:AtmosphereM) { $reason='apoapsis-overshoot'; $final=$t; break }
        if ($t.RadialMps -lt -25 -and $t.AltM -lt 85000 -and $t.PeM -lt $script:AtmosphereM) { $reason='descending-suborbital-below-85km'; $final=$t; break }
        if (-not [double]::IsNaN($t.TotalFuelT) -and $t.TotalFuelT -le 0.001 -and $t.PeM -lt $script:AtmosphereM -and $lowerText -match 'deploy') { $reason='out-of-fuel-before-orbit'; $final=$t; break }
        if ($phase -eq 'coast' -and -not [double]::IsNaN($ttaForDecision) -and $ttaForDecision -gt 180) { $reason='noncompetitive-coast'; $final=$t; break }

        Start-Sleep -Milliseconds 60
    }

    if (-not $reason) { $reason = 'wall-clock-watchdog' }
    if ($result -ne 'success') {
        Send-PhysicalKey X 35 -Quiet
        Save-Evidence "abort_$reason" $(if ($final) { $final.UT-$startUt } else { -1 })
        Send-PhysicalKey ESC 60
        try { [void](Wait-ForScene Vab 8) } catch { Write-RunLog "revert-warning=$($_.Exception.Message)" }
        $script:FlightActive = $false
    }

    $record = [ordered]@{
        attempt=$AttemptNumber; preset=$PresetName; craft=$script:Presets[$PresetName].Craft; result=$result; reason=$reason
        profile=[ordered]@{turnStartM=$TurnStartM;turnEndM=$TurnEndM;targetApM=$TargetApM;targetPeM=$TargetPeM;maxAoARad=$MaxAoARad}
        missionTimeS=$(if ($final) { [Math]::Round($final.UT-$startUt,2) } else { $null })
        finalAltitudeM=$(if ($final) { [Math]::Round($final.AltM,1) } else { $null })
        finalApM=$(if ($final) { [Math]::Round($final.ApM,1) } else { $null })
        finalPeM=$(if ($final) { [Math]::Round($final.PeM,1) } else { $null })
        remainingFuelT=$(if ($final) { $final.TotalFuelT } else { $null })
        evidenceDirectory=(Get-RunRelativePath $attemptDir)
    }
    $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $attemptDir 'result.json') -Encoding UTF8
    Write-RunLog ('attempt={0} result={1} reason={2} met={3}' -f $AttemptNumber,$result,$reason,$record.missionTimeS)
    $script:RunDirectory = $oldRunDir
    return [pscustomobject]$record
}

$offlineProbe = $Mode -eq 'Probe' -and -not [string]::IsNullOrWhiteSpace($ProbeImage)
$offlineOperation = $Mode -eq 'Validate' -or $offlineProbe
if ($offlineProbe -and -not [string]::IsNullOrWhiteSpace($ProbeKey)) {
    throw '-ProbeKey cannot be combined with an offline -ProbeImage replay.'
}

if (-not $offlineOperation -and [string]::IsNullOrWhiteSpace($GameExe)) {
    $siblingBuild = Join-Path (Split-Path -Parent $PSScriptRoot) 'orbit-or-bust-2\build\windows\OrbitOrBust2.exe'
    if (Test-Path -LiteralPath $siblingBuild) { $GameExe = $siblingBuild }
}

[void](New-Item -ItemType Directory -Path $OutputRoot -Force)
$hash = $null
$process = $null
$priorLearning = $null
$priorBestLiveOrbit = $null

if (-not $offlineOperation) {
    if ([string]::IsNullOrWhiteSpace($GameExe) -or -not (Test-Path -LiteralPath $GameExe -PathType Leaf)) {
        throw 'Game executable was not found. Pass -GameExe or set OB2_GAME_EXE.'
    }
    $GameExe = (Resolve-Path -LiteralPath $GameExe).Path
    $hash = (Get-FileHash -LiteralPath $GameExe -Algorithm SHA256).Hash.ToUpperInvariant()
    if (-not $AllowUnknownBuild) {
        if ($ExpectedSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
            throw 'ExpectedSha256 must be a 64-character hexadecimal hash unless -AllowUnknownBuild is present.'
        }
        if ($hash -ne $ExpectedSha256.ToUpperInvariant()) {
            throw "Build SHA-256 mismatch. Expected $ExpectedSha256 but found $hash. Pass -AllowUnknownBuild only while validating a new build adapter."
        }
    }
    if ([string]::IsNullOrWhiteSpace($LearningStatePath)) {
        $stateRoot = if ($env:LOCALAPPDATA) {
            Join-Path $env:LOCALAPPDATA 'OB2Tester\state'
        } else {
            Join-Path $PSScriptRoot 'state'
        }
        $LearningStatePath = Join-Path (Join-Path $stateRoot $hash) 'learning-state.json'
    }
    # Keyboard, mouse, and foreground focus are shared across all visible builds in a
    # Windows session, so the lock must not be scoped to one executable hash.
    $script:ControllerMutex = [Threading.Mutex]::new($false, 'Local\OB2Tester-GlobalInputController')
    if (-not $script:ControllerMutex.WaitOne(0)) {
        throw 'Another OB2 Tester controller is already active in this Windows session.'
    }

    foreach ($stateCandidate in @($LearningStatePath, $BenchmarkStatePath)) {
        if ([string]::IsNullOrWhiteSpace($stateCandidate) -or -not (Test-Path -LiteralPath $stateCandidate)) { continue }
        try {
            $candidateState = Get-Content -LiteralPath $stateCandidate -Raw | ConvertFrom-Json
            $candidateSha = if ($candidateState.PSObject.Properties['executableSha256']) { [string]$candidateState.executableSha256 } else { '' }
            if ($candidateSha -notmatch '^[A-Fa-f0-9]{64}$') {
                Write-Warning "Ignoring state without a valid build SHA-256: $stateCandidate"
                continue
            }
            if ($candidateSha.ToUpperInvariant() -ne $hash) {
                Write-Warning "Ignoring state for a different build: $stateCandidate"
                continue
            }
            if ($null -eq $priorLearning) { $priorLearning = $candidateState }
            if ($stateCandidate -eq $LearningStatePath -and
                $candidateState.PSObject.Properties['activeProfile'] -and
                $null -ne $candidateState.activeProfile) {
                $savedProfile = $candidateState.activeProfile
                $savedTurnStart = [double]$savedProfile.turnStartM
                $savedTurnEnd = [double]$savedProfile.turnEndM
                $savedTargetAp = [double]$savedProfile.targetApM
                $savedTargetPe = [double]$savedProfile.targetPeM
                $savedMaxAoA = [double]$savedProfile.maxAoARad
                $profileValues = @($savedTurnStart,$savedTurnEnd,$savedTargetAp,$savedTargetPe,$savedMaxAoA)
                $profileFinite = @($profileValues | Where-Object { [double]::IsNaN($_) -or [double]::IsInfinity($_) }).Count -eq 0
                if ($profileFinite -and $savedTurnStart -ge 0 -and $savedTurnEnd -gt $savedTurnStart -and
                    $savedTargetAp -gt $script:AtmosphereM -and $savedTargetPe -gt $script:AtmosphereM -and
                    $savedMaxAoA -gt 0 -and $savedMaxAoA -le 1.5) {
                    if (-not $PSBoundParameters.ContainsKey('TurnStartM')) { $TurnStartM = $savedTurnStart }
                    if (-not $PSBoundParameters.ContainsKey('TurnEndM')) { $TurnEndM = $savedTurnEnd }
                    if (-not $PSBoundParameters.ContainsKey('TargetApM')) { $TargetApM = $savedTargetAp }
                    if (-not $PSBoundParameters.ContainsKey('TargetPeM')) { $TargetPeM = $savedTargetPe }
                    if (-not $PSBoundParameters.ContainsKey('MaxAoARad')) { $MaxAoARad = $savedMaxAoA }
                } else {
                    Write-Warning "Ignoring invalid active profile in state: $stateCandidate"
                }
            }
            if ($candidateState.PSObject.Properties['bestLiveOrbit'] -and
                $null -ne $candidateState.bestLiveOrbit -and
                $candidateState.bestLiveOrbit.PSObject.Properties['missionTimeS']) {
                $candidateTime = [double]$candidateState.bestLiveOrbit.missionTimeS
                if ($candidateTime -gt 0 -and -not [double]::IsNaN($candidateTime) -and
                    -not [double]::IsInfinity($candidateTime) -and
                    ([double]::IsNaN($script:BestLiveTimeS) -or $candidateTime -lt $script:BestLiveTimeS)) {
                    $script:BestLiveTimeS = $candidateTime
                    $priorBestLiveOrbit = $candidateState.bestLiveOrbit
                }
            }
        } catch {
            Write-Warning "State was unreadable and will be ignored: $stateCandidate ($($_.Exception.Message))"
        }
    }
    $process = Get-GameWindow -LaunchIfMissing
}

if ($Mode -eq 'Validate') {
    $benchmarkReady = Test-Path -LiteralPath $BenchmarkStatePath -PathType Leaf
    $language = if ($script:OcrEngine.RecognizerLanguage) { $script:OcrEngine.RecognizerLanguage.LanguageTag } else { 'unknown' }
    Write-Host "VALIDATE powershell=$($PSVersionTable.PSVersion) ocr=$language benchmark=$benchmarkReady liveInput=false"
    exit 0
}

if ($Mode -eq 'Probe') {
    if ($ProbeKey) {
        Send-PhysicalKey $ProbeKey $ProbeHoldMs
        Start-Sleep -Milliseconds 250
    }
    if ($ProbeImage) {
        if (-not (Test-Path -LiteralPath $ProbeImage -PathType Leaf)) { throw "Probe image does not exist: $ProbeImage" }
        $probeSource = [Drawing.Bitmap]::FromFile((Resolve-Path -LiteralPath $ProbeImage).Path)
        try {
            $probeText = Invoke-BitmapOcr $probeSource
            $probeDebug = Get-DebugTextBitmap $probeSource
            try { $probeText += ' DEBUG_CROP ' + (Invoke-BitmapOcr $probeDebug -SpatialLines) }
            finally { $probeDebug.Dispose() }
            $state = [pscustomobject]@{Text=$probeText;Bitmap=$probeSource.Clone()}
        }
        finally { $probeSource.Dispose() }
    } else { $state = Get-VisibleState -KeepBitmap }
    try {
        $probePath = Join-Path $OutputRoot 'probe.png'
        $state.Bitmap.Save($probePath, [Drawing.Imaging.ImageFormat]::Png)
        $probeCrop = Get-DebugTextBitmap $state.Bitmap
        try { $probeCrop.Save((Join-Path $OutputRoot 'probe-debug-crop.png'), [Drawing.Imaging.ImageFormat]::Png) }
        finally { $probeCrop.Dispose() }
        $state.Text | Set-Content -LiteralPath (Join-Path $OutputRoot 'probe-ocr.txt') -Encoding UTF8
        $telemetry = Get-Telemetry $state.Text
        $sourceLabel = if ($offlineProbe) { 'offline-image' } else { 'live-build' }
        Write-Host "PROBE source=$sourceLabel debug=$($telemetry.HasDebug) flight=$($telemetry.IsFlight) vab=$($telemetry.IsVab)"
        Write-Host ($telemetry | ConvertTo-Json -Depth 3)
        Write-Host "OCR: $($state.Text)"
    }
    finally { if ($state.Bitmap) { $state.Bitmap.Dispose() } }
    exit 0
}

$runStamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmssfffZ')
$script:RunDirectory = Join-Path $OutputRoot $runStamp
[void](New-Item -ItemType Directory -Path $script:RunDirectory -Force)
$script:TranscriptPath = Join-Path $script:RunDirectory 'live-action-transcript.log'

Write-RunLog "session=start executable=$([IO.Path]::GetFileName($GameExe)) sha256=$hash client=1280x720 localOcr=true"
Write-RunLog "profile turnStartM=$TurnStartM turnEndM=$TurnEndM targetApM=$TargetApM targetPeM=$TargetPeM maxAoARad=$MaxAoARad hardLimitS=$HardLimitS"

$results = @()
$bestLiveOrbit = $priorBestLiveOrbit
$presetsToRun = if ($Preset -eq 'All') { @('SRB','Heavy','Orbiter') } else { @($Preset) }
$attemptOrdinal = 0
try {
    foreach ($presetName in $presetsToRun) {
        for ($presetAttempt = 1; $presetAttempt -le $MaxAttempts; $presetAttempt++) {
            $attemptOrdinal++
            $results += Invoke-LiveAttempt $attemptOrdinal $presetName
            $currentResult = $results[-1]
            if ($currentResult.result -eq 'success') {
                $currentTime = [double]$currentResult.missionTimeS
                if ($currentTime -gt 0 -and -not [double]::IsNaN($currentTime) -and
                    -not [double]::IsInfinity($currentTime) -and
                    ([double]::IsNaN($script:BestLiveTimeS) -or $currentTime -lt $script:BestLiveTimeS)) {
                    # Promote the live success immediately so later presets in -Preset All
                    # are bounded during this same session.
                    $script:BestLiveTimeS = $currentTime
                    $bestLiveOrbit = [ordered]@{
                        preset=$currentResult.preset
                        craft=$currentResult.craft
                        missionTimeS=$currentResult.missionTimeS
                        successGate='two distinct rendered frames with sane Ap/Pe, periapsis above 71 km, and the rendered ORBIT confirmation'
                        finalAltitudeM=$currentResult.finalAltitudeM
                        finalApoapsisM=$currentResult.finalApM
                        finalPeriapsisM=$currentResult.finalPeM
                        remainingFuelT=$currentResult.remainingFuelT
                        profile=$currentResult.profile
                        evidenceDirectory=$currentResult.evidenceDirectory
                    }
                }
                break
            }
            if ($presetAttempt -lt $MaxAttempts) {
                if ($results[-1].reason -match 'apoapsis-overshoot') { $TargetApM = [Math]::Max(76000, $TargetApM-3000) }
                elseif ($results[-1].reason -match 'descending|out-of-fuel') { $TurnEndM = [Math]::Max(24000, $TurnEndM-2000) }
                Write-RunLog "learning nextPresetAttempt=$($presetAttempt+1) turnEndM=$TurnEndM targetApM=$TargetApM"
            }
        }
    }
}
catch {
    Write-RunLog "session=exception message=$($_.Exception.Message)"
    if ($script:FlightActive) {
        try { Send-PhysicalKey X 35 -Quiet } catch { }
        try { Send-PhysicalKey ESC 60 -Quiet } catch { }
        $script:FlightActive = $false
    }
    if ($script:ControllerMutex) {
        try { $script:ControllerMutex.ReleaseMutex() } catch { }
        $script:ControllerMutex.Dispose()
        $script:ControllerMutex = $null
    }
    throw
}

ConvertTo-Json -InputObject @($results) -Depth 6 | Set-Content -LiteralPath (Join-Path $script:RunDirectory 'session-results.json') -Encoding UTF8

$learning = [ordered]@{
    schemaVersion=2
    executableFileName=[IO.Path]::GetFileName($GameExe)
    executableSha256=$hash
    updatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
    bestLiveOrbit=$bestLiveOrbit
    activeProfile=[ordered]@{turnStartM=$TurnStartM;turnEndM=$TurnEndM;targetApM=$TargetApM;targetPeM=$TargetPeM;maxAoARad=$MaxAoARad}
    lastSessionName=[IO.Path]::GetFileName($script:RunDirectory)
    lastSessionResults=$results
    learnedGuards=$(if($priorLearning -and $priorLearning.PSObject.Properties['learnedGuards']){$priorLearning.learnedGuards}else{@(
        'Prefer high-contrast HUD telemetry over unvalidated F3 readings.',
        'Reject impossible single-frame attitude jumps before steering.',
        'Never deploy the recovery parachute during ascent.',
        'Revert on stale telemetry, heading divergence, noncompetitive coast, suborbital descent, or best-time expiry.'
    )})
    liveModuleComparisons=$(if($priorLearning -and $priorLearning.PSObject.Properties['liveModuleComparisons']){$priorLearning.liveModuleComparisons}else{@()})
}
$learningDirectory = Split-Path -Parent $LearningStatePath
if ($learningDirectory) { [void](New-Item -ItemType Directory -Path $learningDirectory -Force) }
$learning | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $LearningStatePath -Encoding UTF8
Write-RunLog "session=complete successes=$(@($results | Where-Object result -eq 'success').Count) attempts=$($results.Count)"
Write-Host "RESULT_DIR=$(Get-RunRelativePath $script:RunDirectory)"
if ($script:ControllerMutex) {
    $script:ControllerMutex.ReleaseMutex()
    $script:ControllerMutex.Dispose()
    $script:ControllerMutex = $null
}
