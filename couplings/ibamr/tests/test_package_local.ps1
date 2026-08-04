$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
$out = Join-Path $repo '.artifacts\package-test'

if (Test-Path -LiteralPath $out) {
    Remove-Item -LiteralPath $out -Recurse -Force
}

$ignoredProbes = @(
    (Join-Path $repo '.artifacts\forbidden-package-probe.txt'),
    (Join-Path $repo '.codebase-memory\forbidden-package-probe.txt'),
    (Join-Path $repo 'couplings\ibamr\build\forbidden-package-probe.txt'),
    (Join-Path $repo 'couplings\ibamr\runs\forbidden-package-probe.txt')
)
foreach ($probe in $ignoredProbes) {
    New-Item -ItemType Directory -Force -Path (Split-Path $probe) | Out-Null
    Set-Content -LiteralPath $probe -Value 'must not be packaged'
}

& "$repo\couplings\ibamr\scripts\package_local.ps1" `
    -Repository $repo `
    -OutputDirectory $out

if ($LASTEXITCODE -ne 0) {
    throw 'package_local.ps1 failed'
}

$archives = @(Get-ChildItem -LiteralPath $out -Filter '*.tar.gz')
if ($archives.Count -ne 1) {
    throw "expected exactly one archive, found $($archives.Count)"
}

$archive = $archives[0]
$listing = @(& tar -tzf $archive.FullName) | ForEach-Object { $_.TrimStart('.').TrimStart('/') }
if ($LASTEXITCODE -ne 0) {
    throw 'archive listing failed'
}

$design = 'docs/superpowers/specs/2026-08-04-ibamr-eel2d-coupling-framework-design.md'
if ($listing -notcontains $design) {
    throw 'tracked design missing'
}

if ($listing -notcontains 'SOURCE_MANIFEST.sha256') {
    throw 'source manifest missing'
}

foreach ($forbidden in @('.git/', '.artifacts/', '.codebase-memory/', '.worktrees/', 'couplings/ibamr/build/', 'couplings/ibamr/runs/')) {
    if ($listing | Where-Object { $_.StartsWith($forbidden) }) {
        throw "forbidden path packaged: $forbidden"
    }
}

Write-Output "PASS: $($archive.FullName)"
