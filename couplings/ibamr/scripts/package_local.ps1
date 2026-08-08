param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string[]]$IncludeUntracked = @()
)

$ErrorActionPreference = 'Stop'

$git = 'C:\Program Files\Git\cmd\git.exe'
$gitTar = 'C:\Program Files\Git\usr\bin\tar.exe'
$Repository = (Resolve-Path -LiteralPath $Repository).Path
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

$fullRevision = (& $git -C $Repository rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $fullRevision -notmatch '^[0-9a-f]{40}$') {
    throw 'cannot determine repository revision'
}
$revision = $fullRevision.Substring(0, 12)
$trackedStatus = @(& $git -C $Repository status --porcelain --untracked-files=no)
if ($LASTEXITCODE -ne 0) {
    throw 'cannot determine tracked working-tree status'
}
$trackedDirty = if ($trackedStatus.Count -gt 0) { 'true' } else { 'false' }

$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$name = "smarties-ibamr-$stamp-$revision"
$stage = Join-Path $OutputDirectory $name
if (Test-Path -LiteralPath $stage) {
    throw "immutable package staging path already exists: $stage"
}
New-Item -ItemType Directory -Path $stage | Out-Null
$stage = (Resolve-Path -LiteralPath $stage).Path

$files = [System.Collections.Generic.List[string]]::new()
foreach ($relative in @(& $git -C $Repository ls-files --cached)) {
    if ($LASTEXITCODE -ne 0) {
        throw 'cannot enumerate tracked files'
    }
    $files.Add($relative.Replace('\', '/'))
}

$allowedUntracked = [System.Collections.Generic.List[string]]::new()
foreach ($candidate in $IncludeUntracked) {
    $relative = $candidate.Replace('\', '/')
    if ($relative.StartsWith('./')) {
        $relative = $relative.Substring(2)
    }
    if ([IO.Path]::IsPathRooted($candidate) -or $relative.StartsWith('../') -or
        [string]::IsNullOrWhiteSpace($relative)) {
        throw "invalid untracked allowlist path: $candidate"
    }
    $matches = @(& $git -C $Repository ls-files --others --exclude-standard -- $relative)
    if ($LASTEXITCODE -ne 0 -or $matches -notcontains $relative) {
        throw "allowlisted path is not an untracked, nonignored file: $relative"
    }
    if (-not $allowedUntracked.Contains($relative)) {
        $allowedUntracked.Add($relative)
        $files.Add($relative)
    }
}

$excludedGitlinks = [System.Collections.Generic.List[string]]::new()
foreach ($relative in $files) {
    $source = Join-Path $Repository $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        $stageEntry = @(& $git -C $Repository ls-files --stage -- $relative)
        if ($LASTEXITCODE -eq 0 -and $stageEntry.Count -eq 1 -and
            $stageEntry[0].StartsWith('160000 ')) {
            $excludedGitlinks.Add($relative)
            continue
        }
        throw "package source file is missing: $relative"
    }

    $target = Join-Path $stage $relative
    New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
    Copy-Item -LiteralPath $source -Destination $target
}

$metadata = Join-Path $stage 'SOURCE_METADATA.txt'
$metadataLines = @(
    "revision=$fullRevision"
    "short_revision=$revision"
    "tracked_dirty=$trackedDirty"
    "included_untracked_count=$($allowedUntracked.Count)"
    "excluded_gitlink_count=$($excludedGitlinks.Count)"
) + @($allowedUntracked | ForEach-Object { "included_untracked=$_" }) +
    @($excludedGitlinks | ForEach-Object { "excluded_gitlink=$_" })
$ascii = New-Object System.Text.ASCIIEncoding
[IO.File]::WriteAllText($metadata, ($metadataLines -join "`n") + "`n", $ascii)

$manifest = Join-Path $stage 'SOURCE_MANIFEST.sha256'
$manifestLines = @(Get-ChildItem -LiteralPath $stage -Recurse -File |
    Where-Object FullName -ne $manifest |
    Sort-Object FullName |
    ForEach-Object {
        $hash = (Get-FileHash -Algorithm SHA256 $_.FullName).Hash.ToLowerInvariant()
        $relative = $_.FullName.Substring($stage.Length + 1).Replace('\', '/')
        "$hash  $relative"
    })
[IO.File]::WriteAllText($manifest, ($manifestLines -join "`n") + "`n", $ascii)

$archive = Join-Path $OutputDirectory "$name.tar.gz"
if (Test-Path -LiteralPath $archive) {
    throw "immutable package archive already exists: $archive"
}
Push-Location $OutputDirectory
try {
    & $gitTar -czf "$name.tar.gz" -C $name .
    if ($LASTEXITCODE -ne 0) {
        throw 'tar failed'
    }
}
finally {
    Pop-Location
}

Write-Output $archive
