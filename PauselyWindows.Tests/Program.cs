using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using PauselyWindows.Services;

var tests = new (string Name, Action Body)[]
{
    ("strict semantic versions", TestSemanticVersions),
    ("SHA-256 digest parsing", TestDigestParsing),
    ("setup release asset selection", TestReleaseAssetSelection),
    ("malformed release metadata", TestMalformedReleaseMetadata),
    ("pinned certificate and code-signing EKU", TestPinnedCertificatePolicy),
    ("wrong signer rejection", TestWrongSignerPolicy),
    ("missing code-signing EKU rejection", TestMissingCodeSigningEkuPolicy),
    ("missing RFC 3161 timestamp rejection", TestMissingTimestampPolicy),
    ("SHA-1 primary signature rejection", TestSha1PrimarySignaturePolicy),
    ("mismatched RFC 3161 imprint rejection", TestMismatchedTimestampImprintPolicy),
    ("timestamp policy error rejection", TestTimestampErrorPolicy),
    ("noncritical or multipurpose TSA EKU rejection", TestTimestampEkuPolicy),
    ("expired signing-time rejection", TestExpiredSigningTimePolicy),
    ("unexpected signer-chain error rejection", TestUnexpectedChainErrorPolicy),
    ("unexpected signer-chain shape rejection", TestUnexpectedChainShapePolicy),
    ("unexpected signer CTL error rejection", TestUnexpectedCtlErrorPolicy)
};

var failures = new List<string>();
foreach ((string name, Action body) in tests)
{
    try
    {
        body();
        Console.WriteLine($"PASS {name}");
    }
    catch (Exception ex)
    {
        failures.Add($"{name}: {ex.Message}");
        Console.Error.WriteLine($"FAIL {name}: {ex}");
    }
}

if (failures.Count > 0)
{
    Console.Error.WriteLine(
        $"{failures.Count} of {tests.Length} Windows policy tests failed.");
    return 1;
}

Console.WriteLine($"PASS all {tests.Length} Windows policy tests");
return 0;

static void TestSemanticVersions()
{
    Assert.True(
        ReleaseMetadataParser.TryParseSemanticVersion(
            "v1.2.3",
            out Version version,
            out string normalized));
    Assert.Equal(new Version(1, 2, 3), version);
    Assert.Equal("1.2.3", normalized);

    foreach (string invalid in new[]
             {
                 "", "v1.2", "1.2.3.4", "v01.2.3", "release-1.2.3",
                 "v1.2.3-beta", " v1.2.3"
             })
    {
        Assert.False(
            ReleaseMetadataParser.TryParseSemanticVersion(
                invalid,
                out _,
                out _),
            $"'{invalid}' must not be accepted as a release version.");
    }
}

static void TestDigestParsing()
{
    string hex = new('A', 64);
    Assert.True(
        ReleaseMetadataParser.TryParseSha256Digest(
            $"sha256:{hex}",
            out byte[] digest));
    Assert.Equal(32, digest.Length);

    foreach (string invalid in new[]
             {
                 hex, $"sha512:{hex}", $"sha256:{hex[..62]}",
                 $"sha256:{new string('Z', 64)}", "sha256:"
             })
    {
        Assert.False(
            ReleaseMetadataParser.TryParseSha256Digest(invalid, out _),
            $"'{invalid}' must not be accepted as a SHA-256 digest.");
    }
}

static void TestReleaseAssetSelection()
{
    string digest = $"sha256:{new string('1', 64)}";
    string json = $$"""
        {
          "tag_name": "v1.0.6",
          "body": "Release notes",
          "assets": [
            {
              "name": "Pausely-Windows.exe",
              "browser_download_url": "https://example.invalid/portable.exe",
              "size": 10,
              "digest": "{{digest}}"
            },
            {
              "name": "Pausely-Windows-Setup.exe",
              "browser_download_url": "https://github.com/pdevh/Pausely/releases/download/v1.0.6/Pausely-Windows-Setup.exe",
              "size": 20,
              "digest": "{{digest}}"
            }
          ]
        }
        """;

    Assert.True(
        ReleaseMetadataParser.TryParseLatestRelease(
            json,
            out ReleaseMetadata? release,
            out string error),
        error);
    Assert.NotNull(release);
    Assert.Equal(new Version(1, 0, 6), release!.Version);
    Assert.Equal("Pausely-Windows-Setup.exe", release.Installer.Name);
    Assert.Equal(
        "https://github.com/pdevh/Pausely/releases/download/v1.0.6/Pausely-Windows-Setup.exe",
        release.Installer.DownloadUri.AbsoluteUri);
    Assert.Equal(20L, release.Installer.Size);
}

static void TestMalformedReleaseMetadata()
{
    string digest = $"sha256:{new string('2', 64)}";
    string validAsset = $$"""
        {
          "name": "Pausely-Windows-Setup.exe",
          "browser_download_url": "https://github.com/pdevh/Pausely/releases/download/v1.0.6/Pausely-Windows-Setup.exe",
          "size": 20,
          "digest": "{{digest}}"
        }
        """;
    string[] malformed =
    {
        "{",
        """{"tag_name":"v1.0.6","tag_name":"v1.0.7","assets":[]}""",
        """{"tag_name":"latest","assets":[]}""",
        $$"""{"tag_name":"1.0.6","assets":[{{validAsset}}]}""",
        """{"tag_name":"v1.0.6"}""",
        """{"tag_name":"v1.0.6","assets":[]}""",
        $$"""{"tag_name":"v1.0.6","assets":[{{validAsset}},{{validAsset}}]}""",
        $$"""
          {
            "tag_name":"v1.0.6",
            "assets":[{
              "name":"Pausely-Windows-Setup.exe",
              "browser_download_url":"http://github.com/pdevh/Pausely/releases/download/v1.0.6/Pausely-Windows-Setup.exe",
              "size":20,
              "digest":"{{digest}}"
            }]
          }
          """,
        $$"""
          {
            "tag_name":"v1.0.6",
            "assets":[{
              "name":"Pausely-Windows-Setup.exe",
              "browser_download_url":"https://attacker.invalid/pdevh/Pausely/releases/download/v1.0.6/Pausely-Windows-Setup.exe",
              "size":20,
              "digest":"{{digest}}"
            }]
          }
          """,
        $$"""
          {
            "tag_name":"v1.0.6",
            "assets":[{
              "name":"Pausely-Windows-Setup.exe",
              "browser_download_url":"https://github.com/pdevh/Pausely/releases/download/v1.0.6/Pausely-Windows-Setup.exe",
              "size":{{ReleaseMetadataParser.MaximumInstallerAssetSize + 1}},
              "digest":"{{digest}}"
            }]
          }
          """,
        $$"""
          {
            "tag_name":"v1.0.6",
            "assets":[{
              "name":"Pausely-Windows-Setup.exe",
              "browser_download_url":"https://github.com/pdevh/Pausely/releases/download/v1.0.6/Pausely-Windows-Setup.exe",
              "size":0,
              "digest":"{{digest}}"
            }]
          }
          """,
        $$"""
          {
            "tag_name":"v1.0.6",
            "assets":[{
              "name":"Pausely-Windows-Setup.exe",
              "browser_download_url":"https://github.com/pdevh/Pausely/releases/download/v1.0.6/Pausely-Windows-Setup.exe",
              "size":20,
              "digest":"sha256:bad"
            }]
          }
          """
    };

    foreach (string json in malformed)
    {
        Assert.False(
            ReleaseMetadataParser.TryParseLatestRelease(json, out _, out _),
            $"Malformed metadata was accepted: {json}");
    }
}

static void TestPinnedCertificatePolicy()
{
    using X509Certificate2 signer = LoadPinnedSigner();
    using X509Certificate2 timestamp = CreateCertificate(
        "CN=Pausely Test Timestamp",
        WindowsSignaturePolicy.TimeStampingEku,
        DateTimeOffset.UtcNow.AddDays(-2),
        DateTimeOffset.UtcNow.AddYears(1),
        ekuCritical: true);

    SignatureVerificationResult result = WindowsSignaturePolicy.Evaluate(
        CreateValidEvidence(signer, timestamp, DateTimeOffset.UtcNow),
        DateTimeOffset.UtcNow);

    Assert.True(result.IsValid, result.Error);
    Assert.True(
        WindowsSignaturePolicy.HasEnhancedKeyUsage(
            signer,
            WindowsSignaturePolicy.CodeSigningEku));
}

static void TestWrongSignerPolicy()
{
    using X509Certificate2 wrongSigner = CreateCertificate(
        "CN=Wrong Signer",
        WindowsSignaturePolicy.CodeSigningEku,
        DateTimeOffset.UtcNow.AddDays(-1),
        DateTimeOffset.UtcNow.AddYears(1));
    using X509Certificate2 timestamp = CreateTimestampCertificate();

    SignatureVerificationResult result = WindowsSignaturePolicy.Evaluate(
        CreateValidEvidence(wrongSigner, timestamp, DateTimeOffset.UtcNow),
        DateTimeOffset.UtcNow);

    Assert.False(result.IsValid);
    Assert.Contains("pinned", result.Error);
}

static void TestMissingCodeSigningEkuPolicy()
{
    using X509Certificate2 signerWithoutEku = CreateCertificate(
        "CN=No EKU",
        eku: null,
        DateTimeOffset.UtcNow.AddDays(-1),
        DateTimeOffset.UtcNow.AddYears(1));
    Assert.False(
        WindowsSignaturePolicy.HasEnhancedKeyUsage(
            signerWithoutEku,
            WindowsSignaturePolicy.CodeSigningEku));

    using X509Certificate2 pinnedSigner = LoadPinnedSigner();
    using X509Certificate2 timestamp = CreateTimestampCertificate();
    SignaturePolicyEvidence evidence = CreateValidEvidence(
        pinnedSigner,
        timestamp,
        DateTimeOffset.UtcNow);

    using X509Certificate2 substitutedPinnedBytes =
        X509CertificateLoader.LoadCertificate(signerWithoutEku.RawData);
    SignatureVerificationResult pinResult = WindowsSignaturePolicy.Evaluate(
        evidence with { SignerCertificate = substitutedPinnedBytes },
        DateTimeOffset.UtcNow);
    Assert.False(pinResult.IsValid);

    // The pure EKU predicate is independently exercised above. A certificate
    // cannot both omit the EKU and retain the committed certificate's exact hash.
}

static void TestMissingTimestampPolicy()
{
    using X509Certificate2 signer = LoadPinnedSigner();
    using X509Certificate2 timestamp = CreateTimestampCertificate();
    SignaturePolicyEvidence evidence = CreateValidEvidence(
        signer,
        timestamp,
        DateTimeOffset.UtcNow);

    SignatureVerificationResult result = WindowsSignaturePolicy.Evaluate(
        evidence with
        {
            Rfc3161Tokens = Array.Empty<Rfc3161TokenEvidence>()
        },
        DateTimeOffset.UtcNow);

    Assert.False(result.IsValid);
    Assert.Contains("RFC 3161", result.Error);
}

static void TestTimestampErrorPolicy()
{
    using X509Certificate2 signer = LoadPinnedSigner();
    using X509Certificate2 timestamp = CreateTimestampCertificate();
    SignaturePolicyEvidence evidence = CreateValidEvidence(
        signer,
        timestamp,
        DateTimeOffset.UtcNow);
    TimestampPolicyEvidence failedTimestamp =
        evidence.Timestamps[0] with { ProviderError = unchecked((int)0x800B0101) };

    SignatureVerificationResult result = WindowsSignaturePolicy.Evaluate(
        evidence with { Timestamps = new[] { failedTimestamp } },
        DateTimeOffset.UtcNow);

    Assert.False(result.IsValid);
    Assert.Contains("timestamp policy failed", result.Error);
}

static void TestSha1PrimarySignaturePolicy()
{
    using X509Certificate2 signer = LoadPinnedSigner();
    using X509Certificate2 timestamp = CreateTimestampCertificate();
    SignaturePolicyEvidence evidence = CreateValidEvidence(
        signer,
        timestamp,
        DateTimeOffset.UtcNow);

    SignatureVerificationResult result = WindowsSignaturePolicy.Evaluate(
        evidence with { PrimarySignatureHashAlgorithmOid = "1.3.14.3.2.26" },
        DateTimeOffset.UtcNow);

    Assert.False(result.IsValid);
    Assert.Contains("primary Authenticode signature", result.Error);
}

static void TestMismatchedTimestampImprintPolicy()
{
    using X509Certificate2 signer = LoadPinnedSigner();
    using X509Certificate2 timestamp = CreateTimestampCertificate();
    SignaturePolicyEvidence evidence = CreateValidEvidence(
        signer,
        timestamp,
        DateTimeOffset.UtcNow);
    Rfc3161TokenEvidence mismatchedToken = evidence.Rfc3161Tokens[0] with
    {
        MessageImprint = new byte[32]
    };

    SignatureVerificationResult result = WindowsSignaturePolicy.Evaluate(
        evidence with { Rfc3161Tokens = new[] { mismatchedToken } },
        DateTimeOffset.UtcNow);

    Assert.False(result.IsValid);
    Assert.Contains("not bound", result.Error);
}

static void TestTimestampEkuPolicy()
{
    using X509Certificate2 signer = LoadPinnedSigner();
    DateTimeOffset now = DateTimeOffset.UtcNow;
    using X509Certificate2 noncriticalTimestamp = CreateCertificate(
        "CN=Noncritical Timestamp",
        WindowsSignaturePolicy.TimeStampingEku,
        now.AddDays(-1),
        now.AddYears(1),
        ekuCritical: false);
    SignatureVerificationResult noncriticalResult = WindowsSignaturePolicy.Evaluate(
        CreateValidEvidence(signer, noncriticalTimestamp, now),
        now);
    Assert.False(noncriticalResult.IsValid);
    Assert.Contains("exclusive, critical", noncriticalResult.Error);

    using X509Certificate2 multipurposeTimestamp = CreateCertificate(
        "CN=Multipurpose Timestamp",
        WindowsSignaturePolicy.TimeStampingEku,
        now.AddDays(-1),
        now.AddYears(1),
        ekuCritical: true,
        additionalEku: WindowsSignaturePolicy.CodeSigningEku);
    SignatureVerificationResult multipurposeResult = WindowsSignaturePolicy.Evaluate(
        CreateValidEvidence(signer, multipurposeTimestamp, now),
        now);
    Assert.False(multipurposeResult.IsValid);
    Assert.Contains("exclusive, critical", multipurposeResult.Error);
}

static void TestExpiredSigningTimePolicy()
{
    using X509Certificate2 signer = LoadPinnedSigner();
    DateTimeOffset signingTime =
        new(signer.NotAfter.ToUniversalTime().AddDays(1));
    using X509Certificate2 timestamp = CreateCertificate(
        "CN=Future Test Timestamp",
        WindowsSignaturePolicy.TimeStampingEku,
        signingTime.AddDays(-2),
        signingTime.AddDays(2),
        ekuCritical: true);
    SignaturePolicyEvidence evidence =
        CreateValidEvidence(signer, timestamp, signingTime);

    SignatureVerificationResult result = WindowsSignaturePolicy.Evaluate(
        evidence,
        signingTime.AddHours(1));

    Assert.False(result.IsValid);
    Assert.Contains("was not valid", result.Error);
}

static void TestUnexpectedChainErrorPolicy()
{
    using X509Certificate2 signer = LoadPinnedSigner();
    using X509Certificate2 timestamp = CreateTimestampCertificate();
    SignaturePolicyEvidence evidence = CreateValidEvidence(
        signer,
        timestamp,
        DateTimeOffset.UtcNow);

    SignatureVerificationResult result = WindowsSignaturePolicy.Evaluate(
        evidence with
        {
            SignerChainErrorStatus =
                WindowsSignaturePolicy.CertTrustIsUntrustedRoot | 0x00000001
        },
        DateTimeOffset.UtcNow);

    Assert.False(result.IsValid);
    Assert.Contains("trust-status", result.Error);
}

static void TestUnexpectedChainShapePolicy()
{
    using X509Certificate2 signer = LoadPinnedSigner();
    using X509Certificate2 timestamp = CreateTimestampCertificate();
    SignaturePolicyEvidence evidence = CreateValidEvidence(
        signer,
        timestamp,
        DateTimeOffset.UtcNow);

    SignatureVerificationResult result = WindowsSignaturePolicy.Evaluate(
        evidence with { SignerChainCertificateCount = 2 },
        DateTimeOffset.UtcNow);

    Assert.False(result.IsValid);
    Assert.Contains("exactly one", result.Error);
}

static void TestUnexpectedCtlErrorPolicy()
{
    using X509Certificate2 signer = LoadPinnedSigner();
    using X509Certificate2 timestamp = CreateTimestampCertificate();
    SignaturePolicyEvidence evidence = CreateValidEvidence(
        signer,
        timestamp,
        DateTimeOffset.UtcNow);
    CertificatePolicyEvidence certificate = evidence.SignerCertificates[0] with
    {
        ControlError = unchecked((int)0x800B010A)
    };

    SignatureVerificationResult result = WindowsSignaturePolicy.Evaluate(
        evidence with { SignerCertificates = new[] { certificate } },
        DateTimeOffset.UtcNow);

    Assert.False(result.IsValid);
    Assert.Contains("CTL", result.Error);
}

static SignaturePolicyEvidence CreateValidEvidence(
    X509Certificate2 signer,
    X509Certificate2 timestamp,
    DateTimeOffset signingTime)
{
    var timestampEvidence = new TimestampPolicyEvidence(
        WindowsSignaturePolicy.TimestampSignerType,
        ProviderError: 0,
        ChainErrorStatus: 0,
        Certificates: Array.Empty<CertificatePolicyEvidence>(),
        timestamp,
        signingTime);
    byte[] primaryEncryptedHash = { 1, 2, 3, 4 };
    var token = new Rfc3161TokenEvidence(
        WindowsSignaturePolicy.Sha256Oid,
        SHA256.HashData(primaryEncryptedHash),
        signingTime,
        timestamp.GetCertHash(HashAlgorithmName.SHA256));
    return new SignaturePolicyEvidence(
        WindowsSignaturePolicy.CertEUntrustedRoot,
        WindowsSignaturePolicy.CertEUntrustedRoot,
        WindowsSignaturePolicy.CertTrustIsUntrustedRoot,
        SignerChainCertificateCount: 1,
        new[]
        {
            new CertificatePolicyEvidence(
                WindowsSignaturePolicy.CertEUntrustedRoot,
                ControlError: 0)
        },
        signer,
        WindowsSignaturePolicy.Sha256Oid,
        primaryEncryptedHash,
        new[] { token },
        new[] { timestampEvidence });
}

static X509Certificate2 LoadPinnedSigner()
{
    string path = Path.Combine(
        AppContext.BaseDirectory,
        "Fixtures",
        "Pausely-Windows-Release-Certificate.pem");
    string pem = File.ReadAllText(path);
    string base64 = pem
        .Replace("-----BEGIN CERTIFICATE-----", "", StringComparison.Ordinal)
        .Replace("-----END CERTIFICATE-----", "", StringComparison.Ordinal)
        .Replace("\r", "", StringComparison.Ordinal)
        .Replace("\n", "", StringComparison.Ordinal);
    return X509CertificateLoader.LoadCertificate(
        Convert.FromBase64String(base64));
}

static X509Certificate2 CreateTimestampCertificate()
{
    return CreateCertificate(
        "CN=Pausely Test Timestamp",
        WindowsSignaturePolicy.TimeStampingEku,
        DateTimeOffset.UtcNow.AddDays(-2),
        DateTimeOffset.UtcNow.AddYears(1),
        ekuCritical: true);
}

static X509Certificate2 CreateCertificate(
    string subject,
    string? eku,
    DateTimeOffset notBefore,
    DateTimeOffset notAfter,
    bool ekuCritical = false,
    string? additionalEku = null)
{
    using RSA key = RSA.Create(2048);
    var request = new CertificateRequest(
        subject,
        key,
        HashAlgorithmName.SHA256,
        RSASignaturePadding.Pkcs1);
    request.CertificateExtensions.Add(
        new X509BasicConstraintsExtension(false, false, 0, critical: true));
    request.CertificateExtensions.Add(
        new X509KeyUsageExtension(
            X509KeyUsageFlags.DigitalSignature,
            critical: true));
    if (eku != null)
    {
        var usages = new OidCollection { new Oid(eku) };
        if (additionalEku != null)
        {
            usages.Add(new Oid(additionalEku));
        }
        request.CertificateExtensions.Add(
            new X509EnhancedKeyUsageExtension(usages, ekuCritical));
    }

    X509SignatureGenerator generator =
        X509SignatureGenerator.CreateForRSA(key, RSASignaturePadding.Pkcs1);
    using X509Certificate2 certificate = request.Create(
        request.SubjectName,
        generator,
        notBefore,
        notAfter,
        RandomNumberGenerator.GetBytes(16));
    return X509CertificateLoader.LoadCertificate(certificate.RawData);
}

static class Assert
{
    internal static void True(bool condition, string? message = null)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message ?? "Expected true.");
        }
    }

    internal static void False(bool condition, string? message = null) =>
        True(!condition, message ?? "Expected false.");

    internal static void Equal<T>(T expected, T actual)
        where T : notnull
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException(
                $"Expected '{expected}', got '{actual}'.");
        }
    }

    internal static void NotNull(object? value)
    {
        if (value == null)
        {
            throw new InvalidOperationException("Expected a non-null value.");
        }
    }

    internal static void Contains(string expected, string actual)
    {
        if (!actual.Contains(expected, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                $"Expected '{actual}' to contain '{expected}'.");
        }
    }
}
