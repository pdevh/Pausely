[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [Parameter(Mandatory = $true)]
    [string]$VerifierPath,

    [ValidateRange(1, 300)]
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = "Stop"

$resolvedFile = (Resolve-Path -LiteralPath $FilePath).Path
$resolvedVerifier = (Resolve-Path -LiteralPath $VerifierPath).Path

if ([IO.Path]::GetExtension($resolvedVerifier) -ne ".exe") {
    throw "The Pausely signature verifier must be a Windows executable: $resolvedVerifier"
}

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $resolvedVerifier
$startInfo.UseShellExecute = $false
$startInfo.ArgumentList.Add("--verify-update-signature")
$startInfo.ArgumentList.Add($resolvedFile)

$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
try {
    if (-not $process.Start()) {
        throw "Windows did not start the Pausely signature verifier."
    }

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try {
            $process.Kill($true)
            $process.WaitForExit()
        }
        catch {
            Write-Warning (
                "Could not confirm signature-verifier process-tree cleanup: " +
                $_.Exception.Message
            )
        }
        throw "Pausely signature verification timed out after $TimeoutSeconds seconds."
    }

    $verificationExitCode = $process.ExitCode
}
finally {
    $process.Dispose()
}

if ($verificationExitCode -ne 0) {
    throw (
        "Pausely's pinned Authenticode policy rejected '$resolvedFile' " +
        "with exit code $verificationExitCode."
    )
}

Write-Host "Pausely Authenticode policy accepted: $resolvedFile"
