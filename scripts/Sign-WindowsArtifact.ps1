[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath
)

$ErrorActionPreference = "Stop"

foreach ($requiredName in @(
    "GITHUB_WORKSPACE",
    "PAUSELY_SIGNTOOL_PATH",
    "PAUSELY_WINDOWS_SIGNING_PFX",
    "PAUSELY_WINDOWS_SIGNING_PFX_PASSWORD"
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

$pfxPath = [IO.Path]::GetFullPath($env:PAUSELY_WINDOWS_SIGNING_PFX)
if (-not (Test-Path -LiteralPath $pfxPath -PathType Leaf)) {
    throw "The temporary Windows signing PFX does not exist: $pfxPath"
}

. (Join-Path $PSScriptRoot "WindowsRelease.Common.ps1")

$timestampServers = @(
    "http://timestamp.digicert.com",
    "http://timestamp.sectigo.com"
)
$lastFailure = $null
foreach ($timestampServer in $timestampServers) {
    foreach ($attempt in 1..2) {
        try {
            # SignTool requires the PFX password on its private command line. The
            # helper deliberately logs neither the arguments nor the password.
            Invoke-PauselyProcess `
                -FilePath $env:PAUSELY_SIGNTOOL_PATH `
                -ArgumentList @(
                    "sign",
                    "/v",
                    "/fd", "SHA256",
                    "/f", $pfxPath,
                    "/p", $env:PAUSELY_WINDOWS_SIGNING_PFX_PASSWORD,
                    "/tr", $timestampServer,
                    "/td", "SHA256",
                    $resolvedFile
                ) `
                -TimeoutSeconds 90 `
                -Description "Authenticode signing attempt $attempt via $timestampServer" `
                -Quiet | Out-Null
            return
        }
        catch {
            $lastFailure = $_
            Write-Warning "Timestamp/signing attempt $attempt via $timestampServer failed."
        }
    }
}

throw "Authenticode signing failed after all timestamp retries: $lastFailure"
