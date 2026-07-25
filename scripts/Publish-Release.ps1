[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Tag,

    [Parameter(Mandatory = $true)]
    [string]$AssetDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "WindowsRelease.Common.ps1")

if ($Tag -cnotmatch '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
    throw "Refusing to publish non-release tag '$Tag'."
}
$version = $Tag.Substring(1)
Assert-PauselySemVer -Version $version

$assetDirectory = [IO.Path]::GetFullPath($AssetDirectory)
$expectedNames = @(
    "Pausely-macOS.dmg",
    "Pausely-macOS.zip",
    "appcast.xml",
    "Pausely-Windows-Setup.exe",
    "Pausely-Windows.exe"
)
$actualNames = @(
    Get-ChildItem -LiteralPath $assetDirectory -File |
        Select-Object -ExpandProperty Name |
        Sort-Object
)
$expectedSorted = @($expectedNames | Sort-Object)
if (($actualNames -join "`n") -cne ($expectedSorted -join "`n")) {
    throw @"
Release asset set is not exact.
Expected: $($expectedSorted -join ', ')
Actual:   $($actualNames -join ', ')
"@
}
foreach ($name in $expectedNames) {
    $path = Join-Path $assetDirectory $name
    if ((Get-Item -LiteralPath $path).Length -le 0) {
        throw "Release asset is empty: $name"
    }
}

$existingRelease = Invoke-PauselyProcess `
    -FilePath "gh" `
    -ArgumentList @(
        "release", "view", $Tag,
        "--repo", $env:GITHUB_REPOSITORY,
        "--json", "id"
    ) `
    -TimeoutSeconds 30 `
    -AllowAnyExitCode `
    -Description "existing-release check" `
    -Quiet
if ($existingRelease.ExitCode -eq 0) {
    throw "A release for $Tag already exists; refusing to mutate it."
}
if ($existingRelease.StdErr -notmatch
    '(?i)(release not found|no release found|HTTP 404|not found)') {
    throw "Could not safely establish that $Tag has no release: $($existingRelease.StdErr)"
}

$draftCreated = $false
try {
    # Set this before the network call so an ambiguous client timeout also
    # triggers a best-effort deletion of any server-created draft.
    $draftCreated = $true
    Invoke-PauselyProcess `
        -FilePath "gh" `
        -ArgumentList @(
            "release", "create", $Tag,
            "--repo", $env:GITHUB_REPOSITORY,
            "--target", $env:GITHUB_SHA,
            "--title", "Pausely $Tag",
            "--generate-notes",
            "--draft"
        ) `
        -TimeoutSeconds 90 `
        -Description "draft release creation" | Out-Null
    $uploadArguments = @(
        "release", "upload", $Tag,
        "--repo", $env:GITHUB_REPOSITORY
    )
    foreach ($name in $expectedNames) {
        $uploadArguments += Join-Path $assetDirectory $name
    }
    Invoke-PauselyProcess `
        -FilePath "gh" `
        -ArgumentList $uploadArguments `
        -TimeoutSeconds 600 `
        -Description "five-asset draft upload" | Out-Null

    $release = Invoke-PauselyProcess `
        -FilePath "gh" `
        -ArgumentList @(
            "release", "view", $Tag,
            "--repo", $env:GITHUB_REPOSITORY,
            "--json", "isDraft,assets",
            "--jq", "{isDraft: .isDraft, names: [.assets[].name]}"
        ) `
        -TimeoutSeconds 60 `
        -Description "draft release verification" `
        -Quiet
    $releaseState = $release.StdOut | ConvertFrom-Json
    if (-not $releaseState.isDraft) {
        throw "Release became public before transactional verification completed."
    }
    $releaseAssetNames = @($releaseState.names | Sort-Object)
    if (($releaseAssetNames -join "`n") -cne ($expectedSorted -join "`n")) {
        throw "Draft release asset set differs from the required five assets."
    }

    Invoke-PauselyProcess `
        -FilePath "gh" `
        -ArgumentList @(
            "release", "edit", $Tag,
            "--repo", $env:GITHUB_REPOSITORY,
            "--draft=false",
            "--latest"
        ) `
        -TimeoutSeconds 60 `
        -Description "atomic release publication" | Out-Null
    $draftCreated = $false
}
catch {
    $publicationError = $_
    if ($draftCreated) {
        try {
            Invoke-PauselyProcess `
                -FilePath "gh" `
                -ArgumentList @(
                    "release", "delete", $Tag,
                    "--repo", $env:GITHUB_REPOSITORY,
                    "--yes"
                ) `
                -TimeoutSeconds 60 `
                -Description "failed draft rollback" | Out-Null
        }
        catch {
            Write-Error "Draft rollback also failed: $_"
        }
    }
    throw $publicationError
}
