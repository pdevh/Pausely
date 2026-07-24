using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;
using PauselyWindows;

namespace PauselyWindows.Services
{
    public class UpdateInfo
    {
        public string Version { get; set; } = "";
        public string DownloadUrl { get; set; } = "";
        public string ReleaseNotes { get; set; } = "";
        public long AssetSize { get; set; }
        public string AssetDigest { get; set; } = "";
        public bool IsInstallerMigration { get; set; }
    }

    public class UpdateService
    {
        public static UpdateService Shared { get; } = new UpdateService();

        private const string GitHubApiUrl = "https://api.github.com/repos/pdevh/Pausely/releases/latest";
        private const string InstallerAssetName = "Pausely-Windows-Setup.exe";
        private const string InstallerAppId = "{B11BB514-5C60-4D64-BCB6-046F49AC2F92}_is1";
        private const string CodeSigningEku = "1.3.6.1.5.5.7.3.3";
        private const string ReleaseCertificateSha256 =
            "75A3947C8623E4EAD6C840D11A64B9A303AA8929548B30F7B14AAED37018A1C7";
        private const string UpdateTempDirectoryName = "PauselyUpdate";
        private static readonly TimeSpan StaleUpdateAge = TimeSpan.FromDays(1);
        private static readonly HttpClient HttpClient = new();
        private readonly SemaphoreSlim _installLock = new(1, 1);

        public event Action<UpdateInfo>? UpdateAvailable;

        private UpdateService()
        {
            HttpClient.DefaultRequestHeaders.Add("User-Agent", "Pausely-Updater");
            CleanupStaleAttemptDirectories();
        }

        /// <summary>
        /// Returns the current application version from assembly metadata.
        /// Falls back to "0.0.0" if not set.
        /// </summary>
        public static string GetCurrentVersion()
        {
            var version = Assembly.GetExecutingAssembly().GetName().Version;
            return version != null ? $"{version.Major}.{version.Minor}.{version.Build}" : "0.0.0";
        }

        /// <summary>
        /// Checks the latest GitHub release for a newer signed installer. A portable
        /// build is also offered the current release so existing ZIP installations
        /// can migrate into the installer-managed location without waiting for
        /// another version.
        /// </summary>
        public async Task<bool?> CheckForUpdateAsync(bool delayAtStartup = true)
        {
            try
            {
                Logger.Info("Checking for application updates from GitHub releases...");
                if (delayAtStartup)
                {
                    await Task.Delay(5000);
                }

                using var response = await HttpClient.GetAsync(GitHubApiUrl);
                if (!response.IsSuccessStatusCode)
                {
                    Logger.Warn($"Update check HTTP request failed. Status code: {response.StatusCode}");
                    return null;
                }

                var json = await response.Content.ReadAsStringAsync();
                using var doc = JsonDocument.Parse(json);
                var root = doc.RootElement;

                string tagName = root.GetProperty("tag_name").GetString() ?? "";
                string remoteVersion = tagName.TrimStart('v');
                string currentVersion = GetCurrentVersion();
                if (!Version.TryParse(remoteVersion, out var parsedRemoteVersion) ||
                    !Version.TryParse(currentVersion, out var parsedCurrentVersion))
                {
                    Logger.Warn(
                        $"Update metadata contains an invalid version. " +
                        $"Current: '{currentVersion}', remote: '{remoteVersion}'.");
                    return null;
                }

                bool isInstallerManaged = IsInstallerManagedInstallation();
                bool isNewer = parsedRemoteVersion > parsedCurrentVersion;
                bool needsInstallerMigration =
                    !isInstallerManaged && parsedRemoteVersion >= parsedCurrentVersion;

                Logger.Info(
                    $"Current version: {currentVersion}. Remote version: {remoteVersion}. " +
                    $"Installer managed: {isInstallerManaged}.");

                if (!isNewer && !needsInstallerMigration)
                {
                    Logger.Info("No new update or installer migration is available.");
                    return false;
                }

                string downloadUrl = "";
                long assetSize = 0;
                string assetDigest = "";

                if (root.TryGetProperty("assets", out var assets))
                {
                    foreach (var asset in assets.EnumerateArray())
                    {
                        string name = asset.GetProperty("name").GetString() ?? "";
                        if (name.Equals(InstallerAssetName, StringComparison.OrdinalIgnoreCase))
                        {
                            downloadUrl = asset.GetProperty("browser_download_url").GetString() ?? "";
                            assetSize = asset.GetProperty("size").GetInt64();
                            assetDigest = asset.TryGetProperty("digest", out var digest)
                                ? digest.GetString() ?? ""
                                : "";
                            break;
                        }
                    }
                }

                if (string.IsNullOrEmpty(downloadUrl))
                {
                    Logger.Warn($"No matching release asset '{InstallerAssetName}' was found.");
                    return null;
                }

                if (!TryParseSha256Digest(assetDigest, out _))
                {
                    Logger.Warn(
                        $"Release asset '{InstallerAssetName}' has no supported SHA-256 digest; " +
                        "refusing the update.");
                    return null;
                }

                string releaseNotes = root.TryGetProperty("body", out var body)
                    ? body.GetString() ?? ""
                    : "";

                var updateInfo = new UpdateInfo
                {
                    Version = remoteVersion,
                    DownloadUrl = downloadUrl,
                    ReleaseNotes = releaseNotes,
                    AssetSize = assetSize,
                    AssetDigest = assetDigest,
                    IsInstallerMigration = needsInstallerMigration && !isNewer
                };

                Logger.Info(
                    $"Installer update details fetched. Size: {assetSize} bytes. " +
                    $"Migration: {updateInfo.IsInstallerMigration}.");
                UpdateAvailable?.Invoke(updateInfo);
                return true;
            }
            catch (Exception ex)
            {
                Logger.Error("Error checking for updates.", ex);
                return null;
            }
        }

        /// <summary>
        /// Downloads, verifies, and starts the signed per-user installer. The caller
        /// leaves Pausely running so Inno Setup's Restart Manager can close and
        /// relaunch it only when installation is ready to proceed.
        /// </summary>
        public async Task<bool> DownloadAndApplyUpdateAsync(UpdateInfo updateInfo)
        {
            if (!await _installLock.WaitAsync(0))
            {
                Logger.Warn("An update installation is already in progress.");
                return false;
            }

            string? attemptDirectory = null;
            try
            {
                Logger.Info($"Downloading signed installer for version v{updateInfo.Version}...");
                attemptDirectory = CreateUniqueAttemptDirectory();
                string installerPath = Path.Combine(attemptDirectory, InstallerAssetName);

                using var response = await HttpClient.GetAsync(updateInfo.DownloadUrl);
                if (!response.IsSuccessStatusCode)
                {
                    Logger.Error($"Installer download failed with HTTP status {response.StatusCode}.");
                    return false;
                }

                await using (var fileStream = File.Create(installerPath))
                {
                    await response.Content.CopyToAsync(fileStream);
                    await fileStream.FlushAsync();
                }

                long downloadedSize = new FileInfo(installerPath).Length;
                if (updateInfo.AssetSize > 0 && downloadedSize != updateInfo.AssetSize)
                {
                    Logger.Error(
                        $"Installer size validation failed. Expected {updateInfo.AssetSize}, " +
                        $"downloaded {downloadedSize}.");
                    return false;
                }

                if (!TryParseSha256Digest(updateInfo.AssetDigest, out var expectedDigest))
                {
                    Logger.Error("Update metadata has no supported SHA-256 digest.");
                    return false;
                }

                await using (var downloadedInstaller = File.OpenRead(installerPath))
                {
                    byte[] actualDigest = await SHA256.HashDataAsync(downloadedInstaller);
                    if (!CryptographicOperations.FixedTimeEquals(actualDigest, expectedDigest))
                    {
                        Logger.Error("SHA-256 validation failed for the downloaded installer.");
                        return false;
                    }
                }

                if (!VerifyReleaseInstallerSignature(installerPath))
                {
                    Logger.Error(
                        "Authenticode integrity or pinned release-certificate validation failed " +
                        "for the installer.");
                    return false;
                }

                string logDirectory = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "Pausely",
                    "Logs");
                Directory.CreateDirectory(logDirectory);
                string installerLogPath = Path.Combine(logDirectory, "installer-update.log");

                var startInfo = new ProcessStartInfo
                {
                    FileName = installerPath,
                    WorkingDirectory = attemptDirectory,
                    UseShellExecute = true
                };
                startInfo.ArgumentList.Add("/VERYSILENT");
                startInfo.ArgumentList.Add("/SUPPRESSMSGBOXES");
                startInfo.ArgumentList.Add("/NORESTART");
                startInfo.ArgumentList.Add("/CLOSEAPPLICATIONS");
                startInfo.ArgumentList.Add("/SP-");
                startInfo.ArgumentList.Add("/PAUSELYAUTOUPDATE=1");
                startInfo.ArgumentList.Add($"/PAUSELYRUNNINGEXE={GetCurrentExecutablePath()}");
                startInfo.ArgumentList.Add($"/LOG={installerLogPath}");

                Process? installerProcess = Process.Start(startInfo);
                if (installerProcess == null)
                {
                    Logger.Error("Windows did not start the verified installer.");
                    return false;
                }

                Logger.Info(
                    $"Verified installer started successfully with PID {installerProcess.Id}. " +
                    "Restart Manager will coordinate application shutdown and relaunch.");
                attemptDirectory = null;
                return true;
            }
            catch (Exception ex)
            {
                Logger.Error("Exception occurred while preparing the installer update.", ex);
                return false;
            }
            finally
            {
                if (attemptDirectory != null)
                {
                    TryDeleteAttemptDirectory(attemptDirectory);
                }
                _installLock.Release();
            }
        }

        private static bool IsInstallerManagedInstallation()
        {
            try
            {
                const string uninstallPath = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\";
                using var key = Registry.CurrentUser.OpenSubKey(uninstallPath + InstallerAppId);
                string? installLocation = key?.GetValue("InstallLocation") as string;
                if (string.IsNullOrWhiteSpace(installLocation))
                {
                    return false;
                }

                string currentDirectory = Path.GetFullPath(
                    Path.GetDirectoryName(GetCurrentExecutablePath()) ?? "");
                string registeredDirectory = Path.GetFullPath(installLocation);
                return string.Equals(
                    currentDirectory.TrimEnd(Path.DirectorySeparatorChar),
                    registeredDirectory.TrimEnd(Path.DirectorySeparatorChar),
                    StringComparison.OrdinalIgnoreCase);
            }
            catch (Exception ex)
            {
                Logger.Warn($"Could not determine installer state: {ex.Message}");
                return false;
            }
        }

        private static string GetCurrentExecutablePath()
        {
            return Process.GetCurrentProcess().MainModule?.FileName
                ?? throw new InvalidOperationException("Unable to determine the current executable path.");
        }

        private static string CreateUniqueAttemptDirectory()
        {
            string root = GetUpdateTempRoot();
            Directory.CreateDirectory(root);
            string attemptDirectory = Path.Combine(root, Path.GetRandomFileName());
            Directory.CreateDirectory(attemptDirectory);
            return attemptDirectory;
        }

        private static string GetUpdateTempRoot()
        {
            return Path.GetFullPath(Path.Combine(Path.GetTempPath(), UpdateTempDirectoryName));
        }

        private static void CleanupStaleAttemptDirectories()
        {
            try
            {
                var root = new DirectoryInfo(GetUpdateTempRoot());
                if (!root.Exists)
                {
                    return;
                }

                DateTime cutoff = DateTime.UtcNow - StaleUpdateAge;
                foreach (var directory in root.EnumerateDirectories())
                {
                    if (directory.LastWriteTimeUtc >= cutoff)
                    {
                        continue;
                    }

                    TryDeleteAttemptDirectory(directory.FullName);
                }
            }
            catch (Exception ex)
            {
                Logger.Warn($"Could not clean stale update downloads: {ex.Message}");
            }
        }

        private static void TryDeleteAttemptDirectory(string attemptDirectory)
        {
            try
            {
                if (Directory.Exists(attemptDirectory))
                {
                    Directory.Delete(attemptDirectory, recursive: true);
                }
            }
            catch (Exception ex)
            {
                Logger.Warn($"Could not remove failed update directory '{attemptDirectory}': {ex.Message}");
            }
        }

        internal static bool VerifyReleaseInstallerSignature(string installerPath)
        {
            if (!OperatingSystem.IsWindows())
            {
                return false;
            }

            if (!WinTrustVerifier.TryGetVerifiedSigner(installerPath, out var installerCertificate))
            {
                return false;
            }

            try
            {
                using (installerCertificate)
                {
                    byte[] expectedCertificateHash =
                        Convert.FromHexString(ReleaseCertificateSha256);
                    byte[] actualCertificateHash = installerCertificate.GetCertHash(
                        HashAlgorithmName.SHA256);
                    if (!CryptographicOperations.FixedTimeEquals(
                            actualCertificateHash,
                            expectedCertificateHash))
                    {
                        Logger.Error(
                            $"Installer signing certificate '{installerCertificate.Subject}' " +
                            "does not match Pausely's pinned Windows release identity.");
                        return false;
                    }

                    bool hasCodeSigningEku = false;
                    foreach (var extension in installerCertificate.Extensions)
                    {
                        if (extension is not X509EnhancedKeyUsageExtension enhancedKeyUsage)
                        {
                            continue;
                        }

                        foreach (var usage in enhancedKeyUsage.EnhancedKeyUsages)
                        {
                            if (usage.Value == CodeSigningEku)
                            {
                                hasCodeSigningEku = true;
                                break;
                            }
                        }
                    }

                    if (!hasCodeSigningEku)
                    {
                        Logger.Error("Installer signer certificate is not valid for code signing.");
                        return false;
                    }

                    Logger.Info(
                        $"Installer Authenticode signature is intact and matches the pinned " +
                        $"release identity '{installerCertificate.Subject}'.");
                    return true;
                }
            }
            catch (CryptographicException ex)
            {
                Logger.Error("Could not inspect Authenticode signer certificates.", ex);
                return false;
            }
        }

        private static bool TryParseSha256Digest(string digest, out byte[] digestBytes)
        {
            digestBytes = Array.Empty<byte>();
            const string prefix = "sha256:";

            if (string.IsNullOrWhiteSpace(digest) ||
                !digest.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }

            string hex = digest[prefix.Length..];
            if (hex.Length != 64)
            {
                return false;
            }

            try
            {
                digestBytes = Convert.FromHexString(hex);
                return digestBytes.Length == 32;
            }
            catch (FormatException)
            {
                digestBytes = Array.Empty<byte>();
                return false;
            }
        }

        private static class WinTrustVerifier
        {
            private static readonly Guid WinTrustActionGenericVerifyV2 =
                new("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");
            private const int CertEUntrustedRoot = unchecked((int)0x800B0109);

            public static bool TryGetVerifiedSigner(
                string filePath,
                out X509Certificate2 signerCertificate)
            {
                signerCertificate = null!;
                using var trustData = new WinTrustData(filePath)
                {
                    StateAction = WinTrustDataStateAction.Verify
                };

                int result = WinVerifyTrust(
                    new IntPtr(-1),
                    WinTrustActionGenericVerifyV2,
                    trustData);
                try
                {
                    if (result != 0 && result != CertEUntrustedRoot)
                    {
                        Logger.Error(
                            $"WinVerifyTrust rejected '{filePath}' with HRESULT 0x{result:X8}.");
                        return false;
                    }

                    IntPtr providerData = WTHelperProvDataFromStateData(trustData.StateData);
                    if (providerData == IntPtr.Zero)
                    {
                        Logger.Error($"WinVerifyTrust returned no provider data for '{filePath}'.");
                        return false;
                    }

                    IntPtr providerSigner = WTHelperGetProvSignerFromChain(
                        providerData,
                        signerIndex: 0,
                        counterSigner: false,
                        counterSignerIndex: 0);
                    if (providerSigner == IntPtr.Zero)
                    {
                        Logger.Error($"WinVerifyTrust returned no signer chain for '{filePath}'.");
                        return false;
                    }

                    var signer = Marshal.PtrToStructure<CryptProviderSigner>(providerSigner);
                    if (signer.CertificateChain == IntPtr.Zero || signer.CertificateChainCount == 0)
                    {
                        Logger.Error($"WinVerifyTrust returned an empty signer chain for '{filePath}'.");
                        return false;
                    }

                    var providerCertificate =
                        Marshal.PtrToStructure<CryptProviderCertificate>(signer.CertificateChain);
                    if (providerCertificate.CertificateContext == IntPtr.Zero)
                    {
                        Logger.Error($"WinVerifyTrust returned no leaf certificate for '{filePath}'.");
                        return false;
                    }

#pragma warning disable SYSLIB0057
                    using var contextCertificate =
                        new X509Certificate2(providerCertificate.CertificateContext);
#pragma warning restore SYSLIB0057
                    signerCertificate =
                        X509CertificateLoader.LoadCertificate(contextCertificate.RawData);
                    if (result == CertEUntrustedRoot)
                    {
                        Logger.Info(
                            $"Windows verified the Authenticode signature on '{filePath}', " +
                            "but its intentionally self-signed root is not in the system trust store.");
                    }
                    return true;
                }
                finally
                {
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

            [DllImport("wintrust.dll", ExactSpelling = true, SetLastError = true, CharSet = CharSet.Unicode)]
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
                RevocationCheckChainExcludeRoot = 0x00000080
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
                public uint Error;
                public uint CounterSignerCount;
                public IntPtr CounterSigners;
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
                public uint Error;
                public IntPtr TrustListContext;
                [MarshalAs(UnmanagedType.Bool)]
                public bool TrustListSignerCertificate;
                public IntPtr ControlContext;
                public uint ControlError;
                [MarshalAs(UnmanagedType.Bool)]
                public bool IsCyclic;
                public IntPtr ChainElement;
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
                    WinTrustDataProvFlags.RevocationCheckChainExcludeRoot;
                public uint UiContext = 0;
                public IntPtr SignatureSettings = IntPtr.Zero;

                public WinTrustData(string filePath)
                {
                    var fileInfo = new WinTrustFileInfo(filePath);
                    FileInfoPtr = Marshal.AllocHGlobal(Marshal.SizeOf<WinTrustFileInfo>());
                    Marshal.StructureToPtr(fileInfo, FileInfoPtr, fDeleteOld: false);
                }

                public void Dispose()
                {
                    if (FileInfoPtr != IntPtr.Zero)
                    {
                        Marshal.DestroyStructure<WinTrustFileInfo>(FileInfoPtr);
                        Marshal.FreeHGlobal(FileInfoPtr);
                        FileInfoPtr = IntPtr.Zero;
                    }
                    GC.SuppressFinalize(this);
                }
            }
        }
    }
}
