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
$portable = Join-Path $workspace "release-assets\Pausely-Windows.exe"
$setup = Join-Path $workspace "release-assets\Pausely-Windows-Setup.exe"
$diagnostics = Join-Path $workspace "release-diagnostics"
$installDirectory = Join-Path $env:RUNNER_TEMP "Pausely-Lifecycle"
$expectedCertificateSha1 = "E729BC983B9B5A1F145103066D43FC53A58D6C57"
$managedProcesses = [Collections.Generic.List[System.Diagnostics.Process]]::new()
$fixtureResults = [ordered]@{}

New-Item -ItemType Directory -Path $diagnostics -Force | Out-Null

function Assert-PinnedSignature {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$Label = $Path
    )

    Invoke-PauselyProcess `
        -FilePath $portable `
        -ArgumentList @("--verify-update-signature", $Path) `
        -TimeoutSeconds 60 `
        -Description "production signature verification: $Label" | Out-Null
}

function Assert-PinnedSignatureRejected {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $result = Invoke-PauselyProcess `
        -FilePath $portable `
        -ArgumentList @("--verify-update-signature", $Path) `
        -TimeoutSeconds 60 `
        -AllowAnyExitCode `
        -Description "negative production signature verification: $Label"
    if ($result.ExitCode -eq 0) {
        throw "The production verifier accepted the $Label fixture."
    }
    $fixtureResults[$Label] = "rejected (exit $($result.ExitCode))"
}

function Assert-NoPinnedTrust {
    foreach ($storeName in @("My", "Root", "TrustedPublisher")) {
        $path = "Cert:\CurrentUser\$storeName\$expectedCertificateSha1"
        if (Test-Path -LiteralPath $path) {
            throw "The Pausely signing certificate unexpectedly exists in CurrentUser\$storeName."
        }
    }
}

if (-not (Test-Path -LiteralPath $portable -PathType Leaf) -or
    -not (Test-Path -LiteralPath $setup -PathType Leaf)) {
    throw "Both Windows release assets must exist before lifecycle testing."
}

if ($Signed -and [string]::IsNullOrWhiteSpace($env:PAUSELY_SIGNTOOL_PATH)) {
    $signTool = Get-ChildItem `
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" |
        Sort-Object { [Version]$_.Directory.Parent.Name } -Descending |
        Select-Object -First 1
    if ($null -eq $signTool) {
        throw "A compatible x64 SignTool was not found."
    }
    $env:PAUSELY_SIGNTOOL_PATH = $signTool.FullName
}

if (Test-Path -LiteralPath $installDirectory) {
    Remove-Item -LiteralPath $installDirectory -Recurse -Force
}

try {
    if ($Signed) {
        Assert-NoPinnedTrust
        Assert-PinnedSignature -Path $portable -Label "portable application"
        Assert-PinnedSignature -Path $setup -Label "setup"
        $fixtureResults["authentic"] = "accepted"
    }

    Invoke-PauselyProcess `
        -FilePath $setup `
        -ArgumentList @(
            "/VERYSILENT",
            "/SUPPRESSMSGBOXES",
            "/NORESTART",
            "/NOICONS",
            "/SP-",
            "/DIR=$installDirectory"
        ) `
        -TimeoutSeconds 180 `
        -Description "silent install" | Out-Null

    $installedApp = Join-Path $installDirectory "PauselyWindows.exe"
    $uninstaller = Join-Path $installDirectory "unins000.exe"
    foreach ($path in @($installedApp, $uninstaller)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Installer did not create $path."
        }
    }

    if ((Get-FileHash -LiteralPath $portable -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $installedApp -Algorithm SHA256).Hash) {
        throw "Installed application is not byte-identical to the signed portable build."
    }

    if ($Signed) {
        Assert-PinnedSignature -Path $installedApp -Label "installed application"
        Assert-PinnedSignature -Path $uninstaller -Label "uninstaller"
    }

    $installedVersion = (Get-Item -LiteralPath $installedApp).VersionInfo
    $expectedVersion = [Version]::Parse($Version)
    if ($installedVersion.FileMajorPart -ne $expectedVersion.Major -or
        $installedVersion.FileMinorPart -ne $expectedVersion.Minor -or
        $installedVersion.FileBuildPart -ne $expectedVersion.Build -or
        $installedVersion.FilePrivatePart -ne 0) {
        throw (
            "Installed version '$($installedVersion.FileVersion)' does not " +
            "exactly match '$Version'."
        )
    }

    $initialProcess = Start-PauselyProcess `
        -FilePath $installedApp `
        -WorkingDirectory $installDirectory
    $managedProcesses.Add($initialProcess)
    if ($initialProcess.WaitForExit(3000)) {
        throw "Installed Pausely exited during its launch smoke test."
    }

    Invoke-PauselyProcess `
        -FilePath $setup `
        -ArgumentList @(
            "/VERYSILENT",
            "/SUPPRESSMSGBOXES",
            "/NORESTART",
            "/CLOSEAPPLICATIONS",
            "/SP-",
            "/PAUSELYAUTOUPDATE=1",
            "/PAUSELYRUNNINGEXE=$installedApp",
            "/DIR=$installDirectory"
        ) `
        -TimeoutSeconds 180 `
        -Description "in-place automatic update" | Out-Null

    $relaunched = $null
    for ($attempt = 0; $attempt -lt 20 -and $null -eq $relaunched; $attempt++) {
        Start-Sleep -Seconds 1
        $relaunched = Get-Process -Name "PauselyWindows" -ErrorAction SilentlyContinue |
            Where-Object {
                try {
                    $_.Id -ne $initialProcess.Id -and
                    $_.MainModule.FileName -eq $installedApp
                }
                catch {
                    $false
                }
            } |
            Select-Object -First 1
    }
    if ($null -eq $relaunched) {
        throw "Automatic update did not relaunch the installed application."
    }
    $managedProcesses.Add($relaunched)
    if (-not $initialProcess.HasExited) {
        throw "Automatic update did not close the original application process."
    }
    Stop-PauselyProcessTree -Process $relaunched

    $portableProcess = Start-PauselyProcess `
        -FilePath $portable `
        -WorkingDirectory (Split-Path -Parent $portable)
    $managedProcesses.Add($portableProcess)
    if ($portableProcess.WaitForExit(3000)) {
        throw "Portable Pausely exited during its launch smoke test."
    }
    Stop-PauselyProcessTree -Process $portableProcess

    if ($Signed) {
        $tamperedSetup = Join-Path $env:RUNNER_TEMP "Pausely-Tampered.exe"
        Copy-Item -LiteralPath $setup -Destination $tamperedSetup -Force
        $stream = [IO.File]::Open(
            $tamperedSetup,
            [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
        try {
            $stream.Position = [Math]::Min(4096, $stream.Length - 1)
            $originalByte = $stream.ReadByte()
            $stream.Position = $stream.Position - 1
            $stream.WriteByte($originalByte -bxor 1)
        }
        finally {
            $stream.Dispose()
        }
        Assert-PinnedSignatureRejected -Path $tamperedSetup -Label "tampered"
        Remove-Item -LiteralPath $tamperedSetup -Force

        $missingTimestampSetup = Join-Path `
            $diagnostics `
            "Pausely-Missing-Timestamp.exe"
        Copy-Item `
            -LiteralPath $portable `
            -Destination $missingTimestampSetup `
            -Force
        Invoke-PauselyProcess `
            -FilePath $env:PAUSELY_SIGNTOOL_PATH `
            -ArgumentList @("remove", "/s", $missingTimestampSetup) `
            -TimeoutSeconds 60 `
            -Description "remove authentic signature for missing-timestamp fixture" `
            -Quiet | Out-Null
        Invoke-PauselyProcess `
            -FilePath $env:PAUSELY_SIGNTOOL_PATH `
            -ArgumentList @(
                "sign",
                "/fd", "SHA256",
                "/f", $env:PAUSELY_WINDOWS_SIGNING_PFX,
                "/p", $env:PAUSELY_WINDOWS_SIGNING_PFX_PASSWORD,
                $missingTimestampSetup
            ) `
            -TimeoutSeconds 90 `
            -Description "missing-timestamp fixture signing" `
            -Quiet | Out-Null
        Assert-PinnedSignatureRejected `
            -Path $missingTimestampSetup `
            -Label "missing-timestamp"
        Remove-Item -LiteralPath $missingTimestampSetup -Force

        $wrongSetup = Join-Path $diagnostics "Pausely-Wrong-Signer.exe"
        $wrongPfx = Join-Path $env:RUNNER_TEMP "pausely-wrong-signer.pfx"
        $wrongPassword = [Convert]::ToHexString(
            [Security.Cryptography.RandomNumberGenerator]::GetBytes(24)
        )
        $rsa = [Security.Cryptography.RSA]::Create(2048)
        try {
            $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
                "CN=Pausely Wrong Signer",
                $rsa,
                [Security.Cryptography.HashAlgorithmName]::SHA256,
                [Security.Cryptography.RSASignaturePadding]::Pkcs1
            )
            $ekus = [Security.Cryptography.OidCollection]::new()
            $ekus.Add([Security.Cryptography.Oid]::new("1.3.6.1.5.5.7.3.3")) | Out-Null
            $request.CertificateExtensions.Add(
                [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new(
                    $ekus,
                    $true
                )
            )
            $wrongCertificate = $request.CreateSelfSigned(
                [DateTimeOffset]::UtcNow.AddMinutes(-5),
                [DateTimeOffset]::UtcNow.AddDays(1)
            )
            try {
                [IO.File]::WriteAllBytes(
                    $wrongPfx,
                    $wrongCertificate.Export(
                        [Security.Cryptography.X509Certificates.X509ContentType]::Pfx,
                        $wrongPassword
                    )
                )
            }
            finally {
                $wrongCertificate.Dispose()
            }

            Copy-Item -LiteralPath $setup -Destination $wrongSetup -Force
            Invoke-PauselyProcess `
                -FilePath $env:PAUSELY_SIGNTOOL_PATH `
                -ArgumentList @("remove", "/s", $wrongSetup) `
                -TimeoutSeconds 60 `
                -Description "remove authentic signature for wrong-signer fixture" `
                -Quiet | Out-Null
            $originalPfx = $env:PAUSELY_WINDOWS_SIGNING_PFX
            $originalPassword = $env:PAUSELY_WINDOWS_SIGNING_PFX_PASSWORD
            try {
                $env:PAUSELY_WINDOWS_SIGNING_PFX = $wrongPfx
                $env:PAUSELY_WINDOWS_SIGNING_PFX_PASSWORD = $wrongPassword
                & (Join-Path $PSScriptRoot "Sign-WindowsArtifact.ps1") `
                    -FilePath $wrongSetup
            }
            finally {
                $env:PAUSELY_WINDOWS_SIGNING_PFX = $originalPfx
                $env:PAUSELY_WINDOWS_SIGNING_PFX_PASSWORD = $originalPassword
            }
            Assert-PinnedSignatureRejected -Path $wrongSetup -Label "wrong-signer"
        }
        finally {
            $rsa.Dispose()
            Remove-Item -LiteralPath $wrongPfx -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $wrongSetup -Force -ErrorAction SilentlyContinue
        }
    }

    Invoke-PauselyProcess `
        -FilePath $uninstaller `
        -ArgumentList @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART") `
        -TimeoutSeconds 180 `
        -Description "silent uninstall" | Out-Null

    for ($attempt = 0; $attempt -lt 20 -and (Test-Path $installedApp); $attempt++) {
        Start-Sleep -Milliseconds 500
    }
    if (Test-Path -LiteralPath $installedApp) {
        throw "Silent uninstall left the installed application behind."
    }
    for ($attempt = 0; $attempt -lt 20 -and
        (Test-Path -LiteralPath $installDirectory); $attempt++) {
        Start-Sleep -Milliseconds 500
    }
    if (Test-Path -LiteralPath $installDirectory) {
        throw "Silent uninstall left its installation directory behind."
    }

    $uninstallRegistryPath =
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\" +
        "{B11BB514-5C60-4D64-BCB6-046F49AC2F92}_is1"
    if (Test-Path -LiteralPath $uninstallRegistryPath) {
        throw "Silent uninstall left the preserved AppId registration behind."
    }

    if ($Signed) {
        Assert-NoPinnedTrust
    }
}
finally {
    foreach ($process in $managedProcesses) {
        Stop-PauselyProcessTree -Process $process
    }
    if ($Signed) {
        Assert-NoPinnedTrust
    }
    $fixtureResults | ConvertTo-Json | Set-Content `
        -LiteralPath (Join-Path $diagnostics "signature-fixtures.json") `
        -Encoding utf8
}
