using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;

namespace PauselyWindows.Services
{
    public class UpdateInfo
    {
        public string Version { get; set; } = "";
        public string DownloadUrl { get; set; } = "";
        public string ReleaseNotes { get; set; } = "";
        public long AssetSize { get; set; }
        public string AssetDigest { get; set; } = "";
    }

    public class UpdateService
    {
        public static UpdateService Shared { get; } = new();

        private const string GitHubApiUrl =
            "https://api.github.com/repos/pdevh/Pausely/releases/latest";
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

        public static string GetCurrentVersion()
        {
            Version? version = Assembly.GetExecutingAssembly().GetName().Version;
            return version != null
                ? $"{version.Major}.{version.Minor}.{version.Build}"
                : "0.0.0";
        }

        /// <summary>
        /// Checks the latest GitHub release for a newer signed installer.
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

                using HttpResponseMessage response = await HttpClient.GetAsync(GitHubApiUrl);
                if (!response.IsSuccessStatusCode)
                {
                    Logger.Warn(
                        $"Update check HTTP request failed. Status code: {response.StatusCode}");
                    return null;
                }

                string currentVersion = GetCurrentVersion();
                if (!ReleaseMetadataParser.TryParseSemanticVersion(
                        currentVersion,
                        out Version parsedCurrentVersion,
                        out _))
                {
                    Logger.Warn(
                        $"The running application version '{currentVersion}' is invalid.");
                    return null;
                }

                string json = await response.Content.ReadAsStringAsync();
                if (!ReleaseMetadataParser.TryParseLatestRelease(
                        json,
                        out ReleaseMetadata? release,
                        out string metadataError))
                {
                    Logger.Warn($"Update metadata was rejected: {metadataError}");
                    return null;
                }

                Logger.Info(
                    $"Current version: {currentVersion}. Remote version: {release!.VersionText}.");
                if (release.Version <= parsedCurrentVersion)
                {
                    Logger.Info("No new update is available.");
                    return false;
                }

                var updateInfo = new UpdateInfo
                {
                    Version = release.VersionText,
                    DownloadUrl = release.Installer.DownloadUri.AbsoluteUri,
                    ReleaseNotes = release.ReleaseNotes,
                    AssetSize = release.Installer.Size,
                    AssetDigest = release.Installer.Digest
                };

                Logger.Info(
                    $"Installer update details fetched. Size: {updateInfo.AssetSize} bytes.");
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
                Logger.Info(
                    $"Downloading signed installer for version v{updateInfo.Version}...");
                attemptDirectory = CreateUniqueAttemptDirectory();
                string installerPath = Path.Combine(
                    attemptDirectory,
                    ReleaseMetadataParser.InstallerAssetName);

                using HttpResponseMessage response =
                    await HttpClient.GetAsync(updateInfo.DownloadUrl);
                if (!response.IsSuccessStatusCode)
                {
                    Logger.Error(
                        $"Installer download failed with HTTP status {response.StatusCode}.");
                    return false;
                }

                await using (FileStream fileStream = File.Create(installerPath))
                {
                    await response.Content.CopyToAsync(fileStream);
                    await fileStream.FlushAsync();
                }

                long downloadedSize = new FileInfo(installerPath).Length;
                if (updateInfo.AssetSize <= 0 || downloadedSize != updateInfo.AssetSize)
                {
                    Logger.Error(
                        $"Installer size validation failed. Expected {updateInfo.AssetSize}, " +
                        $"downloaded {downloadedSize}.");
                    return false;
                }

                if (!ReleaseMetadataParser.TryParseSha256Digest(
                        updateInfo.AssetDigest,
                        out byte[] expectedDigest))
                {
                    Logger.Error("Update metadata has no supported SHA-256 digest.");
                    return false;
                }

                await using (FileStream downloadedInstaller = File.OpenRead(installerPath))
                {
                    byte[] actualDigest = await SHA256.HashDataAsync(downloadedInstaller);
                    if (!CryptographicOperations.FixedTimeEquals(
                            actualDigest,
                            expectedDigest))
                    {
                        Logger.Error(
                            "SHA-256 validation failed for the downloaded installer.");
                        return false;
                    }
                }

                SignatureVerificationResult signatureResult =
                    WindowsSignatureVerifier.VerifyFile(installerPath);
                if (!signatureResult.IsValid)
                {
                    Logger.Error(
                        "Authenticode validation failed for the installer: " +
                        signatureResult.Error);
                    return false;
                }

                if (!ReleaseMetadataParser.TryParseSemanticVersion(
                        updateInfo.Version,
                        out Version expectedVersion,
                        out _) ||
                    !InstallerFileVersionMatches(installerPath, expectedVersion))
                {
                    Logger.Error(
                        "The signed installer's embedded file version does not match " +
                        $"release v{updateInfo.Version}.");
                    return false;
                }

                string logDirectory = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "Pausely",
                    "Logs");
                Directory.CreateDirectory(logDirectory);
                string installerLogPath = Path.Combine(
                    logDirectory,
                    "installer-update.log");

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
                startInfo.ArgumentList.Add(
                    $"/PAUSELYRUNNINGEXE={GetCurrentExecutablePath()}");
                startInfo.ArgumentList.Add($"/LOG={installerLogPath}");

                Process? installerProcess = Process.Start(startInfo);
                if (installerProcess == null)
                {
                    Logger.Error("Windows did not start the verified installer.");
                    return false;
                }

                Logger.Info(
                    $"Verified installer started successfully with PID " +
                    $"{installerProcess.Id}. Restart Manager will coordinate " +
                    "application shutdown and relaunch.");
                attemptDirectory = null;
                return true;
            }
            catch (Exception ex)
            {
                Logger.Error(
                    "Exception occurred while preparing the installer update.",
                    ex);
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

        private static string GetCurrentExecutablePath()
        {
            return Process.GetCurrentProcess().MainModule?.FileName
                ?? throw new InvalidOperationException(
                    "Unable to determine the current executable path.");
        }

        private static bool InstallerFileVersionMatches(
            string installerPath,
            Version expectedVersion)
        {
            FileVersionInfo version = FileVersionInfo.GetVersionInfo(installerPath);
            return version.FileMajorPart == expectedVersion.Major &&
                version.FileMinorPart == expectedVersion.Minor &&
                version.FileBuildPart == expectedVersion.Build &&
                version.FilePrivatePart == 0;
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
            return Path.GetFullPath(
                Path.Combine(Path.GetTempPath(), UpdateTempDirectoryName));
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
                foreach (DirectoryInfo directory in root.EnumerateDirectories())
                {
                    if (directory.LastWriteTimeUtc < cutoff)
                    {
                        TryDeleteAttemptDirectory(directory.FullName);
                    }
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
                Logger.Warn(
                    $"Could not remove failed update directory " +
                    $"'{attemptDirectory}': {ex.Message}");
            }
        }
    }
}
