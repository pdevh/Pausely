[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [switch]$Signed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "WindowsRelease.Common.ps1")

Assert-PauselySemVer -Version $Version

$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$projectPath = Join-Path $workspace "PauselyWindows\PauselyWindows.csproj"
$testProjectPath = Join-Path `
    $workspace `
    "PauselyWindows.Tests\PauselyWindows.Tests.csproj"
$publishDirectory = Join-Path $workspace "out"
$installerDirectory = Join-Path $workspace "installer-out"
$assetDirectory = Join-Path $workspace "release-assets"
$diagnosticsDirectory = Join-Path $workspace "release-diagnostics"
$portableSource = Join-Path $publishDirectory "PauselyWindows.exe"
$portableAsset = Join-Path $assetDirectory "Pausely-Windows.exe"
$setupAsset = Join-Path $assetDirectory "Pausely-Windows-Setup.exe"
$expectedCertificateSha256 =
    "75A3947C8623E4EAD6C840D11A64B9A303AA8929548B30F7B14AAED37018A1C7"

foreach ($directory in @(
    $publishDirectory,
    $installerDirectory,
    $assetDirectory,
    $diagnosticsDirectory
)) {
    if (Test-Path -LiteralPath $directory) {
        Remove-Item -LiteralPath $directory -Recurse -Force
    }
    New-Item -ItemType Directory -Path $directory | Out-Null
}

$env:GITHUB_WORKSPACE = $workspace
$env:PAUSELY_WINDOWS_CERTIFICATE_SHA256 = $expectedCertificateSha256

Invoke-PauselyProcess `
    -FilePath "dotnet.exe" `
    -ArgumentList @(
        "restore",
        $testProjectPath,
        "--locked-mode"
    ) `
    -TimeoutSeconds 300 `
    -WorkingDirectory $workspace `
    -Description "locked Windows policy-test restore" | Out-Null

$policyTestResult = Invoke-PauselyProcess `
    -FilePath "dotnet.exe" `
    -ArgumentList @(
        "run",
        "--project", $testProjectPath,
        "--configuration", "Release",
        "--no-restore"
    ) `
    -TimeoutSeconds 300 `
    -WorkingDirectory $workspace `
    -Description "Windows release policy tests" `
    -Quiet
@(
    $policyTestResult.StdOut
    $policyTestResult.StdErr
) | Set-Content `
    -LiteralPath (Join-Path $diagnosticsDirectory "policy-tests.txt") `
    -Encoding utf8

Invoke-PauselyProcess `
    -FilePath "dotnet.exe" `
    -ArgumentList @(
        "restore",
        $projectPath,
        "--runtime", "win-x64",
        "--locked-mode"
    ) `
    -TimeoutSeconds 300 `
    -WorkingDirectory $workspace `
    -Description "locked NuGet restore" | Out-Null

Invoke-PauselyProcess `
    -FilePath "dotnet.exe" `
    -ArgumentList @(
        "publish",
        $projectPath,
        "-c", "Release",
        "-r", "win-x64",
        "--self-contained", "true",
        "--no-restore",
        "-p:PublishSingleFile=true",
        "-p:IncludeNativeLibrariesForSelfExtract=true",
        "-p:DebugType=None",
        "-p:DebugSymbols=false",
        "-p:Version=$Version",
        "-p:FileVersion=$Version",
        "-o", $publishDirectory
    ) `
    -TimeoutSeconds 600 `
    -WorkingDirectory $workspace `
    -Description "Windows publish" | Out-Null

$publishedFiles = @(Get-ChildItem -LiteralPath $publishDirectory -File)
if ($publishedFiles.Count -ne 1 -or $publishedFiles[0].Name -ne "PauselyWindows.exe") {
    throw "Expected only out/PauselyWindows.exe, found: $($publishedFiles.Name -join ', ')"
}

Add-Type -AssemblyName System.Drawing
$sourceIconPath = Join-Path $workspace "PauselyWindows\Pausely.ico"
$iconSize = [System.Drawing.Size]::new(32, 32)
$sourceIcon = [System.Drawing.Icon]::new($sourceIconPath, $iconSize)
$publishedIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($portableSource)
if ($null -eq $publishedIcon) {
    throw "Published executable does not contain an application icon."
}
$sourceBitmap = $sourceIcon.ToBitmap()
$publishedBitmap = $publishedIcon.ToBitmap()
try {
    for ($y = 0; $y -lt 32; $y++) {
        for ($x = 0; $x -lt 32; $x++) {
            if ($sourceBitmap.GetPixel($x, $y).ToArgb() -ne
                $publishedBitmap.GetPixel($x, $y).ToArgb()) {
                throw "Published executable icon differs from Pausely.ico at ($x, $y)."
            }
        }
    }
}
finally {
    $sourceBitmap.Dispose()
    $publishedBitmap.Dispose()
    $sourceIcon.Dispose()
    $publishedIcon.Dispose()
}

if ($Signed) {
    foreach ($requiredName in @(
        "WINDOWS_SIGNING_CERTIFICATE",
        "WINDOWS_SIGNING_CERTIFICATE_PASSWORD",
        "RUNNER_TEMP"
    )) {
        if ([string]::IsNullOrWhiteSpace(
            [Environment]::GetEnvironmentVariable($requiredName)
        )) {
            throw "Signed builds require '$requiredName'."
        }
    }

    $publicCertificatePath = Join-Path `
        $workspace `
        ".github\signing\Pausely-Windows-Release-Certificate.pem"
    $pfxPath = Join-Path $env:RUNNER_TEMP "pausely-windows-release-signing.pfx"
    try {
        $pfxBytes = [Convert]::FromBase64String(
            $env:WINDOWS_SIGNING_CERTIFICATE
        )
    }
    catch {
        throw "WINDOWS_SIGNING_CERTIFICATE is not valid base64."
    }
    [IO.File]::WriteAllBytes($pfxPath, $pfxBytes)

    $publicCertificate =
        [Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $publicCertificatePath
        )
    $publicSha256 = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($publicCertificate.RawData)
    )
    if ($publicSha256 -ne $expectedCertificateSha256) {
        throw "The committed Windows release certificate does not match its pin."
    }

    $pfxCertificates =
        [Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
    $pfxCertificates.Import(
        $pfxPath,
        $env:WINDOWS_SIGNING_CERTIFICATE_PASSWORD,
        [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
    )
    $pfxCertificate = $pfxCertificates |
        Where-Object { $_.HasPrivateKey } |
        Select-Object -First 1
    if ($null -eq $pfxCertificate) {
        throw "The Windows signing PFX contains no private key."
    }
    $pfxSha256 = $pfxCertificate.GetCertHashString(
        [Security.Cryptography.HashAlgorithmName]::SHA256
    )
    if ($pfxSha256 -ne $expectedCertificateSha256) {
        throw "The Windows signing PFX does not match the committed certificate."
    }
    if ($pfxCertificate.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow -or
        $pfxCertificate.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow) {
        throw "The Windows signing certificate is not currently valid."
    }
    $codeSigningEku = "1.3.6.1.5.5.7.3.3"
    $hasCodeSigningEku = $pfxCertificate.Extensions |
        Where-Object {
            $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]
        } |
        ForEach-Object { $_.EnhancedKeyUsages } |
        Where-Object { $_.Value -eq $codeSigningEku }
    if ($null -eq $hasCodeSigningEku) {
        throw "The Windows signing certificate has no code-signing EKU."
    }

    $signTool = Get-ChildItem `
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" |
        Sort-Object { [Version]$_.Directory.Parent.Name } -Descending |
        Select-Object -First 1
    if ($null -eq $signTool) {
        throw "A compatible x64 SignTool was not found."
    }

    $env:PAUSELY_SIGNTOOL_PATH = $signTool.FullName
    $env:PAUSELY_WINDOWS_SIGNING_PFX = $pfxPath
    $env:PAUSELY_WINDOWS_SIGNING_PFX_PASSWORD =
        $env:WINDOWS_SIGNING_CERTIFICATE_PASSWORD

    & (Join-Path $PSScriptRoot "Sign-WindowsArtifact.ps1") `
        -FilePath $portableSource

    # This is the same pinned production verifier used by the updater. Running
    # it immediately before ISCC replaces Inno's trust-dependent signcheck.
    Invoke-PauselyProcess `
        -FilePath $portableSource `
        -ArgumentList @("--verify-update-signature", $portableSource) `
        -TimeoutSeconds 60 `
        -Description "pinned pre-compilation signature verification" | Out-Null
}

$innoVersion = "6.7.3"
$innoTag = "is-6_7_3"
$innoAssetName = "innosetup-$innoVersion.exe"
$innoInstaller = Join-Path $env:RUNNER_TEMP $innoAssetName
$innoDirectory = Join-Path $env:RUNNER_TEMP "Pausely-Inno-$innoVersion"
for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
        Remove-Item -LiteralPath $innoInstaller -Force -ErrorAction SilentlyContinue
        Invoke-PauselyProcess `
            -FilePath "gh.exe" `
            -ArgumentList @(
                "release", "download", $innoTag,
                "--repo", "jrsoftware/issrc",
                "--pattern", $innoAssetName,
                "--dir", $env:RUNNER_TEMP,
                "--clobber"
            ) `
            -TimeoutSeconds 120 `
            -Description "Inno Setup download attempt $attempt" | Out-Null
        Invoke-PauselyProcess `
            -FilePath "gh.exe" `
            -ArgumentList @(
                "release", "verify-asset", $innoTag, $innoInstaller,
                "--repo", "jrsoftware/issrc"
            ) `
            -TimeoutSeconds 120 `
            -Description "Inno Setup attestation verification" | Out-Null
        break
    }
    catch {
        if ($attempt -eq 3) {
            throw
        }
        Start-Sleep -Seconds ([Math]::Pow(2, $attempt))
    }
}

$innoSignature = Get-AuthenticodeSignature -LiteralPath $innoInstaller
if ($innoSignature.Status -ne
    [System.Management.Automation.SignatureStatus]::Valid) {
    throw "Downloaded Inno Setup has invalid Authenticode status '$($innoSignature.Status)'."
}
if ($innoSignature.SignerCertificate.Subject -notmatch 'CN=Pyrsys B\.V\.') {
    throw "Unexpected Inno Setup publisher '$($innoSignature.SignerCertificate.Subject)'."
}

Invoke-PauselyProcess `
    -FilePath $innoInstaller `
    -ArgumentList @(
        "/VERYSILENT",
        "/SUPPRESSMSGBOXES",
        "/NORESTART",
        "/SP-",
        "/DIR=$innoDirectory"
    ) `
    -TimeoutSeconds 180 `
    -Description "Inno Setup installation" | Out-Null

$isccPath = Join-Path $innoDirectory "ISCC.exe"
if (-not (Test-Path -LiteralPath $isccPath -PathType Leaf)) {
    throw "ISCC.exe was not installed at $isccPath."
}

$isccArguments = @(
    "/DAppVersion=$Version",
    "/DSourceDir=$publishDirectory",
    "/DOutputDir=$installerDirectory"
)
if ($Signed) {
    $signingScript = Join-Path $PSScriptRoot "Sign-WindowsArtifact.ps1"
    $signCommand =
        'pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
        "-File `$q$signingScript`$q -FilePath `$f"
    $isccArguments += "/DSignedBuild=1"
    $isccArguments += "/SPauselySign=$signCommand"
}
$isccArguments += Join-Path $workspace "PauselyWindows\installer\Pausely.iss"

Invoke-PauselyProcess `
    -FilePath $isccPath `
    -ArgumentList $isccArguments `
    -TimeoutSeconds 600 `
    -WorkingDirectory $workspace `
    -Description "Inno Setup compilation" | Out-Null

$builtSetup = Join-Path $installerDirectory "Pausely-Windows-Setup.exe"
if (-not (Test-Path -LiteralPath $builtSetup -PathType Leaf)) {
    throw "Inno Setup did not create $builtSetup."
}

Copy-Item -LiteralPath $portableSource -Destination $portableAsset
Copy-Item -LiteralPath $builtSetup -Destination $setupAsset

[pscustomobject]@{
    Version = $Version
    Signed = [bool]$Signed
    Portable = $portableAsset
    Setup = $setupAsset
} | ConvertTo-Json | Set-Content `
    -LiteralPath (Join-Path $diagnosticsDirectory "build-summary.json") `
    -Encoding utf8
