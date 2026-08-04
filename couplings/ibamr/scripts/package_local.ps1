param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'

$git = 'C:\Program Files\Git\cmd\git.exe'
$revision = (& $git -C $Repository rev-parse --short=12 HEAD).Trim()
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$name = "smarties-ibamr-$stamp-$revision"
$stage = Join-Path $OutputDirectory $name

New-Item -ItemType Directory -Force -Path $stage | Out-Null

$files = & $git -C $Repository ls-files --cached --others --exclude-standard
foreach ($relative in $files) {
    $source = Join-Path $Repository $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        continue
    }

    $target = Join-Path $stage $relative
    New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
    Copy-Item -LiteralPath $source -Destination $target
}

$manifest = Join-Path $stage 'SOURCE_MANIFEST.sha256'
Get-ChildItem $stage -Recurse -File |
    Where-Object FullName -ne $manifest |
    ForEach-Object {
        $hash = (Get-FileHash -Algorithm SHA256 $_.FullName).Hash.ToLowerInvariant()
        $relative = $_.FullName.Substring($stage.Length + 1).Replace('\', '/')
        "$hash  $relative"
    } |
    Set-Content -Encoding ascii $manifest

$archive = Join-Path $OutputDirectory "$name.tar.gz"
$gitTar = 'C:\Program Files\Git\usr\bin\tar.exe'
Push-Location $OutputDirectory
& $gitTar -czf "$name.tar.gz" -C $name .
$tarExitCode = $LASTEXITCODE
Pop-Location
if ($tarExitCode -ne 0) {
    throw 'tar failed'
}

Write-Output $archive
