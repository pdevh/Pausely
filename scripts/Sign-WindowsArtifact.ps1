[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath
)

$ErrorActionPreference = "Stop"

foreach ($requiredName in @(
    "GITHUB_WORKSPACE",
    "PAUSELY_SIGNTOOL_PATH",
    "PAUSELY_WINDOWS_CERTIFICATE_SHA1"
)) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($requiredName))) {
        throw "Required environment variable '$requiredName' is missing."
    }
}

$workspace = [IO.Path]::GetFullPath($env:GITHUB_WORKSPACE).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
)
$resolvedFile = [IO.Path]::GetFullPath($FilePath)
$workspacePrefix = $workspace + [IO.Path]::DirectorySeparatorChar

if (-not $resolvedFile.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to sign a file outside GITHUB_WORKSPACE: $resolvedFile"
}

if (-not (Test-Path -LiteralPath $resolvedFile -PathType Leaf)) {
    throw "Signing target does not exist: $resolvedFile"
}

$extension = [IO.Path]::GetExtension($resolvedFile)
$isExecutable = $extension.Equals(".exe", [StringComparison]::OrdinalIgnoreCase)
$signedUninstallerDirectory = [IO.Path]::GetFullPath(
    (Join-Path $workspace "installer-out\signed-uninstallers")
).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$isInnoUninstallerTemporaryFile =
    $resolvedFile.StartsWith($signedUninstallerDirectory, [StringComparison]::OrdinalIgnoreCase) -and
    [IO.Path]::GetFileName($resolvedFile) -match '^uninst\.e(32|64)\.tmp$'

if (-not $isExecutable -and -not $isInnoUninstallerTemporaryFile) {
    throw "Only release executables and Inno Setup's scoped uninstaller PE may be signed: $resolvedFile"
}

$stream = [IO.File]::OpenRead($resolvedFile)
try {
    if ($stream.Length -lt 2 -or $stream.ReadByte() -ne 0x4D -or $stream.ReadByte() -ne 0x5A) {
        throw "Signing target is not a Windows PE file: $resolvedFile"
    }
}
finally {
    $stream.Dispose()
}

& $env:PAUSELY_SIGNTOOL_PATH sign `
    /v `
    /fd SHA256 `
    /s My `
    /sha1 $env:PAUSELY_WINDOWS_CERTIFICATE_SHA1 `
    /tr http://timestamp.digicert.com `
    /td SHA256 `
    $resolvedFile

if ($LASTEXITCODE -ne 0) {
    throw "Authenticode signing failed for $resolvedFile with exit code $LASTEXITCODE."
}
