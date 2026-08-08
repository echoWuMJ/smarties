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

$untrackedProbeRelative = 'couplings/ibamr/tests/untracked-package-probe.txt'
$untrackedProbe = Join-Path $repo $untrackedProbeRelative
Set-Content -LiteralPath $untrackedProbe -Value 'requires an explicit allowlist'

try {

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
if ($listing -notcontains 'SOURCE_METADATA.txt') {
    throw 'source metadata missing'
}
if ($listing -contains $untrackedProbeRelative) {
    throw 'non-allowlisted untracked file was packaged'
}
if ($listing -contains 'docs/superpowers/plans/2026-08-03-node3-smarties-uv-install.md') {
    throw 'pre-existing unrelated untracked file was packaged'
}

$gitTar = 'C:\Program Files\Git\usr\bin\tar.exe'
Push-Location $archive.DirectoryName
foreach ($script in @(
    './couplings/ibamr/scripts/build_node3.sh',
    './couplings/ibamr/scripts/run_node3.sh',
    './couplings/ibamr/tests/test_node3_scripts.sh'
)) {
    $modeLine = (& $gitTar -tvzf $archive.Name $script) -join "`n"
    if ($LASTEXITCODE -ne 0 -or -not $modeLine.StartsWith('-rwxr-xr-x')) {
        Pop-Location
        throw "executable mode missing from archive entry: $script ($modeLine)"
    }
}
Pop-Location

foreach ($forbidden in @('.git/', '.artifacts/', '.codebase-memory/', '.worktrees/', 'couplings/ibamr/build/', 'couplings/ibamr/runs/')) {
    if ($listing | Where-Object { $_.StartsWith($forbidden) }) {
        throw "forbidden path packaged: $forbidden"
    }
}

$extract = Join-Path $out 'extracted'
New-Item -ItemType Directory -Force -Path $extract | Out-Null
& tar -xzf $archive.FullName -C $extract
if ($LASTEXITCODE -ne 0) {
    throw 'archive extraction failed'
}

$metadata = Get-Content -LiteralPath (Join-Path $extract 'SOURCE_METADATA.txt')
$fullRevision = (& 'C:\Program Files\Git\cmd\git.exe' -C $repo rev-parse HEAD).Trim()
if ($metadata -notcontains "revision=$fullRevision") {
    throw 'source metadata revision mismatch'
}
$trackedStatus = @(& 'C:\Program Files\Git\cmd\git.exe' -C $repo status `
    --porcelain --untracked-files=no)
$expectedDirty = if ($trackedStatus.Count -gt 0) { 'true' } else { 'false' }
if ($metadata -notcontains "tracked_dirty=$expectedDirty") {
    throw 'source metadata dirty state mismatch'
}

$manifestPath = Join-Path $extract 'SOURCE_MANIFEST.sha256'
if ([IO.File]::ReadAllBytes($manifestPath) -contains 13) {
    throw 'source manifest contains CR bytes; node3 requires LF line endings'
}
$metadataPath = Join-Path $extract 'SOURCE_METADATA.txt'
if ([IO.File]::ReadAllBytes($metadataPath) -contains 13) {
    throw 'source metadata contains CR bytes; node3 requires LF line endings'
}
foreach ($line in Get-Content -LiteralPath $manifestPath) {
    if ($line -notmatch '^([0-9a-f]{64})  (.+)$') {
        throw "malformed source manifest line: $line"
    }
    $expected = $Matches[1]
    $relative = $Matches[2]
    if ([IO.Path]::IsPathRooted($relative) -or $relative.StartsWith('../')) {
        throw "non-relative source manifest path: $relative"
    }
    $file = Join-Path $extract $relative.Replace('/', '\')
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "source manifest entry missing after extraction: $relative"
    }
    $actual = (Get-FileHash -Algorithm SHA256 $file).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "source manifest checksum mismatch: $relative"
    }
}

$allowOut = Join-Path $out 'allowlisted'
& "$repo\couplings\ibamr\scripts\package_local.ps1" `
    -Repository $repo `
    -OutputDirectory $allowOut `
    -IncludeUntracked $untrackedProbeRelative | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'allowlisted package creation failed'
}
$allowArchive = @(Get-ChildItem -LiteralPath $allowOut -Filter '*.tar.gz')
if ($allowArchive.Count -ne 1) {
    throw 'expected exactly one allowlisted archive'
}
$allowListing = @(& tar -tzf $allowArchive[0].FullName) |
    ForEach-Object { $_.TrimStart('.').TrimStart('/') }
if ($allowListing -notcontains $untrackedProbeRelative) {
    throw 'explicitly allowlisted untracked file was not packaged'
}

Write-Output "PASS: $($archive.FullName)"
}
finally {
    Remove-Item -LiteralPath $untrackedProbe -Force -ErrorAction SilentlyContinue
}
