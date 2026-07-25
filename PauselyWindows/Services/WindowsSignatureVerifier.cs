using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace PauselyWindows.Services
{
    internal sealed record CertificatePolicyEvidence(int Error, int ControlError);

    internal sealed record TimestampPolicyEvidence(
        uint SignerType,
        int ProviderError,
        uint ChainErrorStatus,
        IReadOnlyList<CertificatePolicyEvidence> Certificates,
        X509Certificate2 Certificate,
        DateTimeOffset VerificationTime);

    internal sealed record Rfc3161TokenEvidence(
        string MessageImprintAlgorithmOid,
        byte[] MessageImprint,
        DateTimeOffset GenerationTime,
        byte[] TimestampCertificateSha256);

    internal sealed record SignaturePolicyEvidence(
        int PolicyResult,
        int SignerProviderError,
        uint SignerChainErrorStatus,
        uint SignerChainCertificateCount,
        IReadOnlyList<CertificatePolicyEvidence> SignerCertificates,
        X509Certificate2 SignerCertificate,
        string PrimarySignatureHashAlgorithmOid,
        byte[] PrimaryEncryptedHash,
        IReadOnlyList<Rfc3161TokenEvidence> Rfc3161Tokens,
        IReadOnlyList<TimestampPolicyEvidence> Timestamps);

    internal sealed record SignatureVerificationResult(bool IsValid, string Error)
    {
        internal static SignatureVerificationResult Success() => new(true, "");

        internal static SignatureVerificationResult Failure(string error) =>
            new(false, error);
    }

    internal static class WindowsSignaturePolicy
    {
        internal const int CertEUntrustedRoot = unchecked((int)0x800B0109);
        internal const string CodeSigningEku = "1.3.6.1.5.5.7.3.3";
        internal const string TimeStampingEku = "1.3.6.1.5.5.7.3.8";
        internal const string Rfc3161CounterSignatureOid = "1.3.6.1.4.1.311.3.3.1";
        internal const string Sha256Oid = "2.16.840.1.101.3.4.2.1";
        internal const uint TimestampSignerType = 0x00000010;
        internal const uint CertTrustIsUntrustedRoot = 0x00000020;
        internal const string ReleaseCertificateSha256 =
            "75A3947C8623E4EAD6C840D11A64B9A303AA8929548B30F7B14AAED37018A1C7";

        internal static SignatureVerificationResult Evaluate(
            SignaturePolicyEvidence evidence,
            DateTimeOffset now)
        {
            if (!IsAllowedSignerPolicyResult(evidence.PolicyResult))
            {
                return SignatureVerificationResult.Failure(
                    $"Authenticode policy failed with HRESULT 0x{evidence.PolicyResult:X8}.");
            }

            if (!IsAllowedSignerPolicyResult(evidence.SignerProviderError))
            {
                return SignatureVerificationResult.Failure(
                    "The Authenticode signer chain has an additional policy error " +
                    $"(0x{evidence.SignerProviderError:X8}).");
            }

            if (evidence.SignerChainErrorStatus != 0 &&
                evidence.SignerChainErrorStatus != CertTrustIsUntrustedRoot)
            {
                return SignatureVerificationResult.Failure(
                    "The Authenticode signer chain has additional trust-status errors " +
                    $"(0x{evidence.SignerChainErrorStatus:X8}).");
            }

            if (evidence.SignerChainCertificateCount != 1 ||
                evidence.SignerCertificates.Count != 1)
            {
                return SignatureVerificationResult.Failure(
                    "The pinned self-signed Pausely signer must have exactly one " +
                    "certificate in its chain.");
            }

            bool untrustedRootReported =
                evidence.PolicyResult == CertEUntrustedRoot ||
                evidence.SignerProviderError == CertEUntrustedRoot;
            foreach (CertificatePolicyEvidence certificate in evidence.SignerCertificates)
            {
                if (certificate.ControlError != 0)
                {
                    return SignatureVerificationResult.Failure(
                        "The Authenticode signer has an unexpected CTL error " +
                        $"(0x{certificate.ControlError:X8}).");
                }

                if (certificate.Error == CertEUntrustedRoot)
                {
                    untrustedRootReported = true;
                    continue;
                }

                if (certificate.Error != 0)
                {
                    return SignatureVerificationResult.Failure(
                        "The Authenticode signer certificate chain has an additional error " +
                        $"(0x{certificate.Error:X8}).");
                }
            }

            bool chainHasOnlyUntrustedRoot =
                evidence.SignerChainErrorStatus == CertTrustIsUntrustedRoot;
            if (untrustedRootReported != chainHasOnlyUntrustedRoot)
            {
                return SignatureVerificationResult.Failure(
                    "Windows returned inconsistent untrusted-root policy evidence for the " +
                    "Authenticode signer.");
            }

            byte[] expectedHash = Convert.FromHexString(ReleaseCertificateSha256);
            byte[] actualHash = evidence.SignerCertificate.GetCertHash(HashAlgorithmName.SHA256);
            if (!CryptographicOperations.FixedTimeEquals(actualHash, expectedHash))
            {
                return SignatureVerificationResult.Failure(
                    "The Authenticode signer does not match Pausely's pinned Windows " +
                    "release certificate.");
            }

            if (!HasEnhancedKeyUsage(evidence.SignerCertificate, CodeSigningEku))
            {
                return SignatureVerificationResult.Failure(
                    "The pinned signer certificate does not contain the code-signing EKU.");
            }

            if (evidence.PrimarySignatureHashAlgorithmOid != Sha256Oid)
            {
                return SignatureVerificationResult.Failure(
                    "The primary Authenticode signature does not use SHA-256.");
            }

            if (evidence.Rfc3161Tokens.Count != 1)
            {
                return SignatureVerificationResult.Failure(
                    "The Authenticode signature must contain exactly one valid RFC 3161 token.");
            }

            if (evidence.Timestamps.Count != 1)
            {
                return SignatureVerificationResult.Failure(
                    "Windows must return exactly one RFC 3161 timestamp signer.");
            }

            Rfc3161TokenEvidence token = evidence.Rfc3161Tokens[0];
            TimestampPolicyEvidence timestamp = evidence.Timestamps[0];
            if (token.MessageImprintAlgorithmOid != Sha256Oid)
            {
                return SignatureVerificationResult.Failure(
                    "The RFC 3161 message imprint does not use SHA-256.");
            }

            byte[] expectedImprint = SHA256.HashData(evidence.PrimaryEncryptedHash);
            if (!CryptographicOperations.FixedTimeEquals(
                    token.MessageImprint,
                    expectedImprint))
            {
                return SignatureVerificationResult.Failure(
                    "The RFC 3161 message imprint is not bound to the primary " +
                    "Authenticode signature.");
            }

            if ((token.GenerationTime - timestamp.VerificationTime).Duration() >
                TimeSpan.FromSeconds(1))
            {
                return SignatureVerificationResult.Failure(
                    "The RFC 3161 token time does not match the timestamp Windows verified.");
            }

            byte[] timestampCertificateHash =
                timestamp.Certificate.GetCertHash(HashAlgorithmName.SHA256);
            if (!CryptographicOperations.FixedTimeEquals(
                    token.TimestampCertificateSha256,
                    timestampCertificateHash))
            {
                return SignatureVerificationResult.Failure(
                    "The RFC 3161 token signer does not match the timestamp signer " +
                    "Windows verified.");
            }

            if (timestamp.SignerType != TimestampSignerType)
            {
                return SignatureVerificationResult.Failure(
                    "Windows did not identify the RFC 3161 countersigner as a " +
                    "timestamp signer.");
            }

            if (timestamp.ProviderError != 0)
            {
                return SignatureVerificationResult.Failure(
                    "RFC 3161 timestamp policy failed with HRESULT " +
                    $"0x{timestamp.ProviderError:X8}.");
            }

            if (timestamp.ChainErrorStatus != 0)
            {
                return SignatureVerificationResult.Failure(
                    "The RFC 3161 timestamp chain has trust-status errors " +
                    $"(0x{timestamp.ChainErrorStatus:X8}).");
            }

            foreach (CertificatePolicyEvidence certificate in timestamp.Certificates)
            {
                if (certificate.Error != 0 || certificate.ControlError != 0)
                {
                    return SignatureVerificationResult.Failure(
                        "The RFC 3161 timestamp certificate chain has an error " +
                        $"(certificate=0x{certificate.Error:X8}, " +
                        $"CTL=0x{certificate.ControlError:X8}).");
                }
            }

            if (!HasExclusiveCriticalEnhancedKeyUsage(
                    timestamp.Certificate,
                    TimeStampingEku))
            {
                return SignatureVerificationResult.Failure(
                    "The RFC 3161 timestamp signer must have an exclusive, critical " +
                    "time-stamping EKU.");
            }

            if (timestamp.VerificationTime == default ||
                timestamp.VerificationTime > now.AddMinutes(5))
            {
                return SignatureVerificationResult.Failure(
                    "The RFC 3161 timestamp contains an invalid signing time.");
            }

            if (!WasValidAt(evidence.SignerCertificate, timestamp.VerificationTime))
            {
                return SignatureVerificationResult.Failure(
                    "The Pausely signing certificate was not valid at the RFC 3161 " +
                    "timestamp time.");
            }

            if (!WasValidAt(timestamp.Certificate, timestamp.VerificationTime))
            {
                return SignatureVerificationResult.Failure(
                    "The RFC 3161 timestamp certificate was not valid at its signing time.");
            }

            return SignatureVerificationResult.Success();
        }

        internal static bool HasEnhancedKeyUsage(X509Certificate2 certificate, string oid)
        {
            foreach (X509Extension extension in certificate.Extensions)
            {
                if (extension is not X509EnhancedKeyUsageExtension enhancedKeyUsage)
                {
                    continue;
                }

                foreach (Oid usage in enhancedKeyUsage.EnhancedKeyUsages)
                {
                    if (usage.Value == oid)
                    {
                        return true;
                    }
                }
            }

            return false;
        }

        internal static bool HasExclusiveCriticalEnhancedKeyUsage(
            X509Certificate2 certificate,
            string oid)
        {
            foreach (X509Extension extension in certificate.Extensions)
            {
                if (extension is not X509EnhancedKeyUsageExtension enhancedKeyUsage)
                {
                    continue;
                }

                return enhancedKeyUsage.Critical &&
                    enhancedKeyUsage.EnhancedKeyUsages.Count == 1 &&
                    enhancedKeyUsage.EnhancedKeyUsages[0].Value == oid;
            }

            return false;
        }

        private static bool IsAllowedSignerPolicyResult(int result) =>
            result == 0 || result == CertEUntrustedRoot;

        private static bool WasValidAt(
            X509Certificate2 certificate,
            DateTimeOffset verificationTime)
        {
            DateTimeOffset notBefore = new(certificate.NotBefore.ToUniversalTime());
            DateTimeOffset notAfter = new(certificate.NotAfter.ToUniversalTime());
            return verificationTime >= notBefore && verificationTime <= notAfter;
        }
    }

    internal static class WindowsSignatureVerifier
    {
        private static readonly Guid WinTrustActionGenericVerifyV2 =
            new("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");

        internal static SignatureVerificationResult VerifyFile(string filePath)
        {
            if (!OperatingSystem.IsWindows())
            {
                return SignatureVerificationResult.Failure(
                    "Authenticode verification is only available on Windows.");
            }

            if (string.IsNullOrWhiteSpace(filePath))
            {
                return SignatureVerificationResult.Failure(
                    "No Authenticode verification target was provided.");
            }

            string resolvedPath;
            try
            {
                resolvedPath = Path.GetFullPath(filePath);
            }
            catch (Exception ex) when (
                ex is ArgumentException or NotSupportedException or PathTooLongException)
            {
                return SignatureVerificationResult.Failure(
                    $"The Authenticode verification path is invalid: {ex.Message}");
            }

            if (!File.Exists(resolvedPath))
            {
                return SignatureVerificationResult.Failure(
                    $"The Authenticode verification target does not exist: {resolvedPath}");
            }

            using var trustData = new WinTrustData(resolvedPath)
            {
                StateAction = WinTrustDataStateAction.Verify
            };

            int policyResult = WinVerifyTrust(
                new IntPtr(-1),
                WinTrustActionGenericVerifyV2,
                trustData);

            var certificates = new List<X509Certificate2>();
            try
            {
                if (trustData.GetSecondarySignatureCount() != 0)
                {
                    return SignatureVerificationResult.Failure(
                        "Release artifacts must contain exactly one Authenticode signature.");
                }

                IntPtr providerData = WTHelperProvDataFromStateData(trustData.StateData);
                if (providerData == IntPtr.Zero)
                {
                    return SignatureVerificationResult.Failure(
                        $"Windows returned no Authenticode provider data for '{resolvedPath}'.");
                }

                IntPtr providerSigner = WTHelperGetProvSignerFromChain(
                    providerData,
                    signerIndex: 0,
                    counterSigner: false,
                    counterSignerIndex: 0);
                if (providerSigner == IntPtr.Zero)
                {
                    return SignatureVerificationResult.Failure(
                        $"Windows returned no Authenticode signer for '{resolvedPath}'.");
                }

                CryptProviderSigner signer =
                    Marshal.PtrToStructure<CryptProviderSigner>(providerSigner);
                if (!TryLoadLeafCertificate(
                        signer,
                        certificates,
                        out X509Certificate2? signerCertificate,
                        out string certificateError))
                {
                    return SignatureVerificationResult.Failure(certificateError);
                }

                if (!TryReadPrimarySignerInfo(
                        signer.SignerInfo,
                        out string primaryHashAlgorithmOid,
                        out byte[] primaryEncryptedHash,
                        out IReadOnlyList<byte[]> rfc3161TokenValues,
                        out string signerInfoError))
                {
                    return SignatureVerificationResult.Failure(signerInfoError);
                }

                var rfc3161Tokens = new List<Rfc3161TokenEvidence>();
                foreach (byte[] tokenValue in rfc3161TokenValues)
                {
                    if (!TryVerifyRfc3161Token(
                            tokenValue,
                            primaryEncryptedHash,
                            out Rfc3161TokenEvidence? token,
                            out string tokenError))
                    {
                        return SignatureVerificationResult.Failure(tokenError);
                    }

                    rfc3161Tokens.Add(token!);
                }

                var timestamps = new List<TimestampPolicyEvidence>();
                for (uint index = 0; index < signer.CounterSignerCount; index++)
                {
                    IntPtr providerCounterSigner = WTHelperGetProvSignerFromChain(
                        providerData,
                        signerIndex: 0,
                        counterSigner: true,
                        counterSignerIndex: index);
                    if (providerCounterSigner == IntPtr.Zero)
                    {
                        return SignatureVerificationResult.Failure(
                            $"Windows could not inspect Authenticode countersigner {index}.");
                    }

                    CryptProviderSigner counterSigner =
                        Marshal.PtrToStructure<CryptProviderSigner>(providerCounterSigner);
                    if (!TryLoadLeafCertificate(
                            counterSigner,
                            certificates,
                            out X509Certificate2? timestampCertificate,
                            out certificateError))
                    {
                        return SignatureVerificationResult.Failure(certificateError);
                    }

                    if (!TryConvertFileTime(
                            counterSigner.VerifyAsOf,
                            out DateTimeOffset verificationTime))
                    {
                        return SignatureVerificationResult.Failure(
                            "Windows returned an invalid timestamp signing time.");
                    }

                    timestamps.Add(new TimestampPolicyEvidence(
                        counterSigner.SignerType,
                        counterSigner.Error,
                        ReadChainErrorStatus(counterSigner),
                        ReadCertificateEvidence(counterSigner),
                        timestampCertificate!,
                        verificationTime));
                }

                var evidence = new SignaturePolicyEvidence(
                    policyResult,
                    signer.Error,
                    ReadChainErrorStatus(signer),
                    signer.CertificateChainCount,
                    ReadCertificateEvidence(signer),
                    signerCertificate!,
                    primaryHashAlgorithmOid,
                    primaryEncryptedHash,
                    rfc3161Tokens,
                    timestamps);
                return WindowsSignaturePolicy.Evaluate(evidence, DateTimeOffset.UtcNow);
            }
            catch (Exception ex) when (
                ex is CryptographicException or
                    ExternalException or
                    ArgumentException or
                    OverflowException)
            {
                return SignatureVerificationResult.Failure(
                    $"Could not inspect the Authenticode signature: {ex.Message}");
            }
            finally
            {
                foreach (X509Certificate2 certificate in certificates)
                {
                    certificate.Dispose();
                }

                if (trustData.StateData != IntPtr.Zero)
                {
                    trustData.StateAction = WinTrustDataStateAction.Close;
                    _ = WinVerifyTrust(
                        new IntPtr(-1),
                        WinTrustActionGenericVerifyV2,
                        trustData);
                }
            }
        }

        private static bool TryLoadLeafCertificate(
            CryptProviderSigner signer,
            List<X509Certificate2> certificates,
            out X509Certificate2? certificate,
            out string error)
        {
            certificate = null;
            error = "";
            if (signer.CertificateChain == IntPtr.Zero || signer.CertificateChainCount == 0)
            {
                error = "Windows returned an empty Authenticode certificate chain.";
                return false;
            }

            CryptProviderCertificate providerCertificate =
                Marshal.PtrToStructure<CryptProviderCertificate>(signer.CertificateChain);
            if (providerCertificate.CertificateContext == IntPtr.Zero)
            {
                error = "Windows returned no Authenticode leaf certificate.";
                return false;
            }

#pragma warning disable SYSLIB0057
            using var contextCertificate =
                new X509Certificate2(providerCertificate.CertificateContext);
#pragma warning restore SYSLIB0057
            certificate = X509CertificateLoader.LoadCertificate(contextCertificate.RawData);
            certificates.Add(certificate);
            return true;
        }

        private static IReadOnlyList<CertificatePolicyEvidence> ReadCertificateEvidence(
            CryptProviderSigner signer)
        {
            var certificates = new List<CertificatePolicyEvidence>();
            int certificateSize = Marshal.SizeOf<CryptProviderCertificate>();
            for (uint index = 0; index < signer.CertificateChainCount; index++)
            {
                IntPtr certificatePointer = IntPtr.Add(
                    signer.CertificateChain,
                    checked((int)index * certificateSize));
                CryptProviderCertificate certificate =
                    Marshal.PtrToStructure<CryptProviderCertificate>(certificatePointer);
                certificates.Add(
                    new CertificatePolicyEvidence(
                        certificate.Error,
                        certificate.ControlError));
            }

            return certificates;
        }

        private static uint ReadChainErrorStatus(CryptProviderSigner signer)
        {
            if (signer.ChainContext == IntPtr.Zero)
            {
                throw new CryptographicException(
                    "Windows returned no Authenticode certificate-chain context.");
            }

            CertChainContext chain =
                Marshal.PtrToStructure<CertChainContext>(signer.ChainContext);
            return chain.TrustStatus.ErrorStatus;
        }

        private static bool TryReadPrimarySignerInfo(
            IntPtr signerInfoPointer,
            out string hashAlgorithmOid,
            out byte[] encryptedHash,
            out IReadOnlyList<byte[]> rfc3161TokenValues,
            out string error)
        {
            hashAlgorithmOid = "";
            encryptedHash = Array.Empty<byte>();
            rfc3161TokenValues = Array.Empty<byte[]>();
            error = "";
            if (signerInfoPointer == IntPtr.Zero)
            {
                error = "Windows returned no primary Authenticode signer information.";
                return false;
            }

            CmsgSignerInfo signerInfo =
                Marshal.PtrToStructure<CmsgSignerInfo>(signerInfoPointer);
            hashAlgorithmOid =
                Marshal.PtrToStringAnsi(signerInfo.HashAlgorithm.ObjectIdentifier) ?? "";
            if (!TryCopyBlob(signerInfo.EncryptedHash, out encryptedHash))
            {
                error = "The primary Authenticode signature contains an invalid signature blob.";
                return false;
            }

            CryptAttributes attributes = signerInfo.UnauthenticatedAttributes;
            if (attributes.Count == 0 || attributes.Attributes == IntPtr.Zero)
            {
                error = "The Authenticode signature has no RFC 3161 timestamp attribute.";
                return true;
            }

            const uint maximumReasonableAttributeCount = 256;
            if (attributes.Count > maximumReasonableAttributeCount)
            {
                throw new CryptographicException(
                    "The Authenticode signature contains an invalid attribute count.");
            }

            var tokenValues = new List<byte[]>();
            int attributeSize = Marshal.SizeOf<CryptAttribute>();
            for (uint index = 0; index < attributes.Count; index++)
            {
                IntPtr attributePointer = IntPtr.Add(
                    attributes.Attributes,
                    checked((int)index * attributeSize));
                CryptAttribute attribute =
                    Marshal.PtrToStructure<CryptAttribute>(attributePointer);
                string? oid = Marshal.PtrToStringAnsi(attribute.ObjectIdentifier);
                if (!string.Equals(
                        oid,
                        WindowsSignaturePolicy.Rfc3161CounterSignatureOid,
                        StringComparison.Ordinal))
                {
                    continue;
                }

                if (attribute.ValueCount == 0 ||
                    attribute.ValueCount > 16 ||
                    attribute.Values == IntPtr.Zero)
                {
                    error = "The RFC 3161 attribute contains an invalid value count.";
                    return false;
                }

                int blobSize = Marshal.SizeOf<CryptDataBlob>();
                for (uint valueIndex = 0; valueIndex < attribute.ValueCount; valueIndex++)
                {
                    IntPtr valuePointer = IntPtr.Add(
                        attribute.Values,
                        checked((int)valueIndex * blobSize));
                    CryptDataBlob value =
                        Marshal.PtrToStructure<CryptDataBlob>(valuePointer);
                    if (!TryCopyBlob(value, out byte[] encodedToken))
                    {
                        error = "The RFC 3161 attribute contains an invalid content blob.";
                        return false;
                    }

                    tokenValues.Add(encodedToken);
                }
            }

            rfc3161TokenValues = tokenValues;
            return true;
        }

        private static bool TryVerifyRfc3161Token(
            byte[] encodedToken,
            byte[] primaryEncryptedHash,
            out Rfc3161TokenEvidence? token,
            out string error)
        {
            token = null;
            error = "";
            IntPtr timestampContext = IntPtr.Zero;
            IntPtr timestampSigner = IntPtr.Zero;
            IntPtr timestampStore = IntPtr.Zero;
            try
            {
                if (!CryptVerifyTimeStampSignature(
                        encodedToken,
                        (uint)encodedToken.Length,
                        primaryEncryptedHash,
                        (uint)primaryEncryptedHash.Length,
                        IntPtr.Zero,
                        out timestampContext,
                        out timestampSigner,
                        out timestampStore))
                {
                    error =
                        "Crypt32 rejected the RFC 3161 token or its binding to the " +
                        $"primary Authenticode signature (Win32 error {Marshal.GetLastWin32Error()}).";
                    return false;
                }

                if (timestampContext == IntPtr.Zero || timestampSigner == IntPtr.Zero)
                {
                    error = "Crypt32 returned incomplete RFC 3161 verification evidence.";
                    return false;
                }

                CryptTimestampContext context =
                    Marshal.PtrToStructure<CryptTimestampContext>(timestampContext);
                if (context.TimestampInfo == IntPtr.Zero)
                {
                    error = "Crypt32 returned no RFC 3161 TSTInfo.";
                    return false;
                }

                CryptTimestampInfo info =
                    Marshal.PtrToStructure<CryptTimestampInfo>(context.TimestampInfo);
                string hashAlgorithmOid =
                    Marshal.PtrToStringAnsi(info.HashAlgorithm.ObjectIdentifier) ?? "";
                if (!TryCopyBlob(info.HashedMessage, out byte[] messageImprint) ||
                    !TryConvertFileTime(info.Time, out DateTimeOffset generationTime))
                {
                    error = "Crypt32 returned malformed RFC 3161 message-imprint metadata.";
                    return false;
                }

#pragma warning disable SYSLIB0057
                using var contextCertificate = new X509Certificate2(timestampSigner);
#pragma warning restore SYSLIB0057
                byte[] timestampCertificateHash =
                    contextCertificate.GetCertHash(HashAlgorithmName.SHA256);
                token = new Rfc3161TokenEvidence(
                    hashAlgorithmOid,
                    messageImprint,
                    generationTime,
                    timestampCertificateHash);
                return true;
            }
            finally
            {
                if (timestampContext != IntPtr.Zero)
                {
                    CryptMemFree(timestampContext);
                }

                if (timestampSigner != IntPtr.Zero)
                {
                    _ = CertFreeCertificateContext(timestampSigner);
                }

                if (timestampStore != IntPtr.Zero)
                {
                    _ = CertCloseStore(timestampStore, 0);
                }
            }
        }

        private static bool TryCopyBlob(CryptDataBlob blob, out byte[] bytes)
        {
            bytes = Array.Empty<byte>();
            const uint maximumReasonableBlobSize = 16 * 1024 * 1024;
            if (blob.Size == 0 ||
                blob.Size > maximumReasonableBlobSize ||
                blob.Data == IntPtr.Zero)
            {
                return false;
            }

            bytes = new byte[blob.Size];
            Marshal.Copy(blob.Data, bytes, 0, checked((int)blob.Size));
            return true;
        }

        private static bool TryConvertFileTime(
            System.Runtime.InteropServices.ComTypes.FILETIME fileTime,
            out DateTimeOffset value)
        {
            value = default;
            long ticks =
                ((long)(uint)fileTime.dwHighDateTime << 32) |
                (uint)fileTime.dwLowDateTime;
            if (ticks <= 0)
            {
                return false;
            }

            try
            {
                value = new DateTimeOffset(DateTime.FromFileTimeUtc(ticks));
                return true;
            }
            catch (ArgumentOutOfRangeException)
            {
                return false;
            }
        }

        [DllImport(
            "wintrust.dll",
            ExactSpelling = true,
            SetLastError = true,
            CharSet = CharSet.Unicode)]
        private static extern int WinVerifyTrust(
            IntPtr hwnd,
            [MarshalAs(UnmanagedType.LPStruct)] Guid actionId,
            [In, Out] WinTrustData trustData);

        [DllImport("wintrust.dll", ExactSpelling = true)]
        private static extern IntPtr WTHelperProvDataFromStateData(IntPtr stateData);

        [DllImport("wintrust.dll", ExactSpelling = true)]
        private static extern IntPtr WTHelperGetProvSignerFromChain(
            IntPtr providerData,
            uint signerIndex,
            [MarshalAs(UnmanagedType.Bool)] bool counterSigner,
            uint counterSignerIndex);

        [DllImport("crypt32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CryptVerifyTimeStampSignature(
            [In] byte[] timestampContentInfo,
            uint timestampContentInfoSize,
            [In] byte[] data,
            uint dataSize,
            IntPtr additionalStore,
            out IntPtr timestampContext,
            out IntPtr timestampSigner,
            out IntPtr timestampStore);

        [DllImport("crypt32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CertFreeCertificateContext(IntPtr certificateContext);

        [DllImport("crypt32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CertCloseStore(IntPtr certificateStore, uint flags);

        [DllImport("crypt32.dll")]
        private static extern void CryptMemFree(IntPtr buffer);

        private enum WinTrustDataUiChoice : uint
        {
            None = 2
        }

        private enum WinTrustDataRevocationChecks : uint
        {
            WholeChain = 1
        }

        private enum WinTrustDataChoice : uint
        {
            File = 1
        }

        private enum WinTrustDataStateAction : uint
        {
            Ignore = 0,
            Verify = 1,
            Close = 2
        }

        [Flags]
        private enum WinTrustDataProvFlags : uint
        {
            RevocationCheckChainExcludeRoot = 0x00000080,
            DisableMd2Md4 = 0x00002000
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct CryptProviderSigner
        {
            public uint StructSize;
            public System.Runtime.InteropServices.ComTypes.FILETIME VerifyAsOf;
            public uint CertificateChainCount;
            public IntPtr CertificateChain;
            public uint SignerType;
            public IntPtr SignerInfo;
            public int Error;
            public uint CounterSignerCount;
            public IntPtr CounterSigners;
            public IntPtr ChainContext;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct CryptProviderCertificate
        {
            public uint StructSize;
            public IntPtr CertificateContext;
            [MarshalAs(UnmanagedType.Bool)]
            public bool Commercial;
            [MarshalAs(UnmanagedType.Bool)]
            public bool TrustedRoot;
            [MarshalAs(UnmanagedType.Bool)]
            public bool SelfSigned;
            [MarshalAs(UnmanagedType.Bool)]
            public bool TestCertificate;
            public uint RevokedReason;
            public uint Confidence;
            public int Error;
            public IntPtr TrustListContext;
            [MarshalAs(UnmanagedType.Bool)]
            public bool TrustListSignerCertificate;
            public IntPtr ControlContext;
            public int ControlError;
            [MarshalAs(UnmanagedType.Bool)]
            public bool IsCyclic;
            public IntPtr ChainElement;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct CryptDataBlob
        {
            public uint Size;
            public IntPtr Data;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct CryptAlgorithmIdentifier
        {
            public IntPtr ObjectIdentifier;
            public CryptDataBlob Parameters;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct CryptAttributes
        {
            public uint Count;
            public IntPtr Attributes;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct CryptAttribute
        {
            public IntPtr ObjectIdentifier;
            public uint ValueCount;
            public IntPtr Values;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct CmsgSignerInfo
        {
            public uint Version;
            public CryptDataBlob Issuer;
            public CryptDataBlob SerialNumber;
            public CryptAlgorithmIdentifier HashAlgorithm;
            public CryptAlgorithmIdentifier HashEncryptionAlgorithm;
            public CryptDataBlob EncryptedHash;
            public CryptAttributes AuthenticatedAttributes;
            public CryptAttributes UnauthenticatedAttributes;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct CryptTimestampContext
        {
            public uint EncodedSize;
            public IntPtr Encoded;
            public IntPtr TimestampInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct CryptTimestampInfo
        {
            public uint Version;
            public IntPtr TsaPolicyIdentifier;
            public CryptAlgorithmIdentifier HashAlgorithm;
            public CryptDataBlob HashedMessage;
            public CryptDataBlob SerialNumber;
            public System.Runtime.InteropServices.ComTypes.FILETIME Time;
            public IntPtr Accuracy;
            [MarshalAs(UnmanagedType.Bool)]
            public bool Ordering;
            public CryptDataBlob Nonce;
            public CryptDataBlob Tsa;
            public uint ExtensionCount;
            public IntPtr Extensions;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct CertTrustStatus
        {
            public uint ErrorStatus;
            public uint InfoStatus;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct CertChainContext
        {
            public uint StructSize;
            public CertTrustStatus TrustStatus;
            public uint ChainCount;
            public IntPtr Chains;
            public uint LowerQualityChainContextCount;
            public IntPtr LowerQualityChainContexts;
            [MarshalAs(UnmanagedType.Bool)]
            public bool HasRevocationFreshnessTime;
            public uint RevocationFreshnessTime;
            public uint CreateFlags;
            public Guid ChainId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct WinTrustSignatureSettings
        {
            public uint StructSize;
            public uint Index;
            public uint Flags;
            public uint SecondarySignatureCount;
            public uint VerifiedSignatureIndex;
            public IntPtr CryptoPolicy;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private sealed class WinTrustFileInfo
        {
            public uint StructSize = (uint)Marshal.SizeOf<WinTrustFileInfo>();
            [MarshalAs(UnmanagedType.LPWStr)]
            public string FilePath;
            public IntPtr FileHandle = IntPtr.Zero;
            public IntPtr KnownSubject = IntPtr.Zero;

            public WinTrustFileInfo(string filePath)
            {
                FilePath = filePath;
            }
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private sealed class WinTrustData : IDisposable
        {
            private const uint GetSecondarySignatureCountFlag = 0x00000002;

            public uint StructSize = (uint)Marshal.SizeOf<WinTrustData>();
            public IntPtr PolicyCallbackData = IntPtr.Zero;
            public IntPtr SipClientData = IntPtr.Zero;
            public WinTrustDataUiChoice UiChoice = WinTrustDataUiChoice.None;
            public WinTrustDataRevocationChecks RevocationChecks =
                WinTrustDataRevocationChecks.WholeChain;
            public WinTrustDataChoice UnionChoice = WinTrustDataChoice.File;
            public IntPtr FileInfoPtr;
            public WinTrustDataStateAction StateAction = WinTrustDataStateAction.Ignore;
            public IntPtr StateData = IntPtr.Zero;
            public IntPtr UrlReference = IntPtr.Zero;
            public WinTrustDataProvFlags ProvFlags =
                WinTrustDataProvFlags.RevocationCheckChainExcludeRoot |
                WinTrustDataProvFlags.DisableMd2Md4;
            public uint UiContext = 0;
            public IntPtr SignatureSettings;

            public WinTrustData(string filePath)
            {
                var fileInfo = new WinTrustFileInfo(filePath);
                FileInfoPtr = Marshal.AllocHGlobal(Marshal.SizeOf<WinTrustFileInfo>());
                Marshal.StructureToPtr(fileInfo, FileInfoPtr, fDeleteOld: false);

                var signatureSettings = new WinTrustSignatureSettings
                {
                    StructSize = (uint)Marshal.SizeOf<WinTrustSignatureSettings>(),
                    Flags = GetSecondarySignatureCountFlag
                };
                SignatureSettings = Marshal.AllocHGlobal(
                    Marshal.SizeOf<WinTrustSignatureSettings>());
                Marshal.StructureToPtr(
                    signatureSettings,
                    SignatureSettings,
                    fDeleteOld: false);
            }

            public uint GetSecondarySignatureCount()
            {
                if (SignatureSettings == IntPtr.Zero)
                {
                    throw new CryptographicException(
                        "Windows returned no Authenticode signature settings.");
                }

                WinTrustSignatureSettings settings =
                    Marshal.PtrToStructure<WinTrustSignatureSettings>(SignatureSettings);
                return settings.SecondarySignatureCount;
            }

            public void Dispose()
            {
                if (FileInfoPtr != IntPtr.Zero)
                {
                    Marshal.DestroyStructure<WinTrustFileInfo>(FileInfoPtr);
                    Marshal.FreeHGlobal(FileInfoPtr);
                    FileInfoPtr = IntPtr.Zero;
                }

                if (SignatureSettings != IntPtr.Zero)
                {
                    Marshal.DestroyStructure<WinTrustSignatureSettings>(
                        SignatureSettings);
                    Marshal.FreeHGlobal(SignatureSettings);
                    SignatureSettings = IntPtr.Zero;
                }

                GC.SuppressFinalize(this);
            }
        }
    }
}
