param(
    [switch] $SkipOcrReplay
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$controller = Join-Path $repoRoot 'Run-LiveOrbitTester.ps1'
$buildId = '94CA7490BB67F23E34BEB87B8C73E7D85D6C767A259BC2A90C57C39F0BB0EC42'
$benchmarkRoot = Join-Path $repoRoot ('benchmarks\' + $buildId)
$failures = [Collections.Generic.List[string]]::new()

function Assert-Test {
    param([bool] $Condition, [string] $Message)
    if ($Condition) { Write-Host "PASS  $Message" -ForegroundColor Green }
    else {
        Write-Host "FAIL  $Message" -ForegroundColor Red
        $script:failures.Add($Message)
    }
}

$tokens = $null
$parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile($controller, [ref]$tokens, [ref]$parseErrors)
Assert-Test ($parseErrors.Count -eq 0) 'controller parses in Windows PowerShell'
$controllerText = Get-Content -LiteralPath $controller -Raw -Encoding UTF8
Assert-Test ($controllerText.Contains('ConvertTo-Json -InputObject @($results)')) 'session results always serialize as a JSON array'
Assert-Test ($controllerText.Contains("'Local\OB2Tester-GlobalInputController'")) 'one session-wide mutex protects global input'
Assert-Test ($controllerText.Contains("ExpectedSha256 -notmatch '^[A-Fa-f0-9]{64}$'")) 'blank or malformed expected hashes cannot bypass the build guard'

try {
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [void][Windows.Media.Ocr.OcrEngine,Windows.Foundation,ContentType=WindowsRuntime]
    $ocrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    Assert-Test ($null -ne $ocrEngine) 'Windows.Media.Ocr is available'
} catch {
    Assert-Test $false "Windows.Media.Ocr dependency check: $($_.Exception.Message)"
}

$jsonFiles = @(Get-ChildItem -LiteralPath $benchmarkRoot -Recurse -Filter '*.json') +
    @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'schemas') -Filter '*.json')
foreach ($jsonFile in $jsonFiles) {
    try {
        [void](Get-Content -LiteralPath $jsonFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json)
        Assert-Test $true "JSON parses: $($jsonFile.FullName.Substring($repoRoot.Length + 1))"
    } catch {
        Assert-Test $false "JSON parses: $($jsonFile.FullName.Substring($repoRoot.Length + 1))"
    }
}

$imageFiles = @(Get-ChildItem -LiteralPath $benchmarkRoot -Recurse -Filter '*.png')
foreach ($imageFile in $imageFiles) {
    try {
        $image = [Drawing.Image]::FromFile($imageFile.FullName)
        $width = $image.Width
        $height = $image.Height
        $image.Dispose()
        Assert-Test ($width -ge 1280 -and $height -ge 720) "image decodes: $($imageFile.Name)"
    } catch {
        Assert-Test $false "image decodes: $($imageFile.Name)"
    }
}

$manifest = Join-Path $benchmarkRoot 'SHA256SUMS'
if (Test-Path -LiteralPath $manifest) {
    foreach ($line in Get-Content -LiteralPath $manifest -Encoding UTF8) {
        if (-not $line.Trim()) { continue }
        if ($line -notmatch '^(?<hash>[A-Fa-f0-9]{64})  (?<path>.+)$') {
            Assert-Test $false "manifest line format: $line"
            continue
        }
        $manifestPath = Join-Path $benchmarkRoot ($Matches.path.Replace('/', '\'))
        $actual = if (Test-Path -LiteralPath $manifestPath) { (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash } else { '' }
        Assert-Test ($actual -eq $Matches.hash.ToUpperInvariant()) "evidence hash: $($Matches.path)"
    }
} else { Assert-Test $false 'benchmark SHA256SUMS exists' }

$forbiddenExecutables = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File | Where-Object { $_.Extension -in @('.exe','.dll','.pck') })
Assert-Test ($forbiddenExecutables.Count -eq 0) 'repository does not bundle game executables or DLLs'

$trackedTextRoots = @(
    $controller,
    (Join-Path $repoRoot 'README.md'),
    (Join-Path $repoRoot 'NOTICE.md'),
    (Join-Path $repoRoot 'docs'),
    $benchmarkRoot
)
$privatePattern = 'C:\\Users\\|\\\.codex\\visualizations|github_pat_|ghp_[A-Za-z0-9]+'
$privateMatches = @()
foreach ($textRoot in $trackedTextRoots) {
    if (Test-Path -LiteralPath $textRoot -PathType Leaf) {
        $privateMatches += Select-String -LiteralPath $textRoot -Pattern $privatePattern -CaseSensitive:$false
    } else {
        $privateMatches += Get-ChildItem -LiteralPath $textRoot -Recurse -File |
            Where-Object { $_.Extension -in @('.md','.json','.log','.ps1') } |
            Select-String -Pattern $privatePattern -CaseSensitive:$false
    }
}
Assert-Test ($privateMatches.Count -eq 0) 'published text contains no user-profile paths or token patterns'

$markdownFiles = @(
    (Get-Item -LiteralPath (Join-Path $repoRoot 'README.md'))
    (Get-Item -LiteralPath (Join-Path $repoRoot 'NOTICE.md'))
) + @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'docs') -Recurse -Filter '*.md')
foreach ($markdownFile in $markdownFiles) {
    $markdown = Get-Content -LiteralPath $markdownFile.FullName -Raw -Encoding UTF8
    foreach ($linkMatch in [regex]::Matches($markdown, '\[[^\]]+\]\((?<target>[^\)#]+)(?:#[^\)]*)?\)')) {
        $target = $linkMatch.Groups['target'].Value
        if ($target -match '^(?:https?://|mailto:)') { continue }
        $resolvedLink = [IO.Path]::GetFullPath((Join-Path $markdownFile.DirectoryName $target))
        Assert-Test (Test-Path -LiteralPath $resolvedLink) "Markdown link resolves: $($markdownFile.Name) -> $target"
    }
}

if (-not $SkipOcrReplay) {
    $fixture = Join-Path $benchmarkRoot 'evidence\srb\019_stable_orbit.png'
    $testOutput = Join-Path ([IO.Path]::GetTempPath()) ('OB2Tester-Test-' + [Guid]::NewGuid().ToString('N'))
    try {
        $probeOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $controller `
            -Mode Probe -ProbeImage $fixture -OutputRoot $testOutput 2>&1 | Out-String
        Assert-Test ($LASTEXITCODE -eq 0) 'offline OCR replay exits successfully'
        Assert-Test ($probeOutput -match 'source=offline-image') 'offline replay does not attach to the game'
        Assert-Test ($probeOutput -match 'flight=True') 'offline replay recognizes a flight scene'
        Assert-Test ($probeOutput -match 'ORBIT') 'offline replay recognizes stable-orbit evidence'
    } catch {
        Assert-Test $false "offline OCR replay: $($_.Exception.Message)"
    } finally {
        $resolvedTemp = [IO.Path]::GetFullPath($testOutput)
        $allowedPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()) + 'OB2Tester-Test-'
        if ($resolvedTemp.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $resolvedTemp)) {
            Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
        }
    }
}

if ($failures.Count -gt 0) {
    throw "$($failures.Count) repository validation check(s) failed."
}
Write-Host 'All repository checks passed.' -ForegroundColor Green
