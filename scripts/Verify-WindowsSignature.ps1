[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedSha256
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($env:PAUSELY_SIGNTOOL_PATH)) {
    throw "PAUSELY_SIGNTOOL_PATH is missing."
}

$resolvedFile = (Resolve-Path -LiteralPath $FilePath).Path

& $env:PAUSELY_SIGNTOOL_PATH verify /pa /all /v /tw $resolvedFile
if ($LASTEXITCODE -ne 0) {
    throw "SignTool verification failed for $resolvedFile with exit code $LASTEXITCODE."
}

$signature = Get-AuthenticodeSignature -LiteralPath $resolvedFile
if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
    throw "Authenticode status for $resolvedFile is '$($signature.Status)', expected 'Valid'."
}

if ($null -eq $signature.SignerCertificate) {
    throw "No signer certificate was found for $resolvedFile."
}

$actualSha256 = $signature.SignerCertificate.GetCertHashString(
    [Security.Cryptography.HashAlgorithmName]::SHA256
)
if ($actualSha256 -ne $ExpectedSha256) {
    throw "Unexpected signing certificate for $resolvedFile. Expected SHA-256 '$ExpectedSha256', got '$actualSha256'."
}

$codeSigningEku = "1.3.6.1.5.5.7.3.3"
$hasCodeSigningEku = $signature.SignerCertificate.Extensions |
    Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } |
    ForEach-Object { $_.EnhancedKeyUsages } |
    Where-Object { $_.Value -eq $codeSigningEku }

if ($null -eq $hasCodeSigningEku) {
    throw "Signer certificate for $resolvedFile does not contain the code-signing EKU."
}

if ($null -eq $signature.TimeStamperCertificate) {
    throw "No RFC 3161 timestamp certificate was found for $resolvedFile."
}
