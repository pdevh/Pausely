using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Reflection;
using System.Text.Json;
using System.Threading.Tasks;
using PauselyWindows;

namespace PauselyWindows.Services
{
    public class UpdateInfo
    {
        public string Version { get; set; } = "";
        public string DownloadUrl { get; set; } = "";
        public string ReleaseNotes { get; set; } = "";
        public long AssetSize { get; set; }
    }

    public class UpdateService
    {
        public static UpdateService Shared { get; } = new UpdateService();

        private const string GitHubApiUrl = "https://api.github.com/repos/pdevh/Pausely/releases/latest";
        private const string AssetName = "Pausely-Windows.zip";
        private static readonly HttpClient _httpClient = new();

        public event Action<UpdateInfo>? UpdateAvailable;

        private UpdateService()
        {
            _httpClient.DefaultRequestHeaders.Add("User-Agent", "Pausely-Updater");
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
        /// Checks for updates after a delay. Called on app startup when auto-update is enabled.
        /// </summary>
        public async Task CheckForUpdateAsync()
        {
            try
            {
                Logger.Info("Checking for application updates from GitHub releases...");
                // Delay 5 seconds to not block app launch
                await Task.Delay(5000);

                var response = await _httpClient.GetAsync(GitHubApiUrl);
                if (!response.IsSuccessStatusCode)
                {
                    Logger.Warn($"Update check HTTP request failed. Status code: {response.StatusCode}");
                    return;
                }

                var json = await response.Content.ReadAsStringAsync();
                using var doc = JsonDocument.Parse(json);
                var root = doc.RootElement;

                // Extract tag_name (e.g., "v1.0.42")
                string tagName = root.GetProperty("tag_name").GetString() ?? "";
                string remoteVersion = tagName.TrimStart('v');

                string currentVersion = GetCurrentVersion();
                Logger.Info($"Current version: {currentVersion}. Remote version: {remoteVersion}");

                if (!IsNewerVersion(remoteVersion, currentVersion))
                {
                    Logger.Info("No new update available.");
                    return;
                }

                // Find the correct asset
                string downloadUrl = "";
                long assetSize = 0;

                if (root.TryGetProperty("assets", out var assets))
                {
                    foreach (var asset in assets.EnumerateArray())
                    {
                        string name = asset.GetProperty("name").GetString() ?? "";
                        if (name.Equals(AssetName, StringComparison.OrdinalIgnoreCase))
                        {
                            downloadUrl = asset.GetProperty("browser_download_url").GetString() ?? "";
                            assetSize = asset.GetProperty("size").GetInt64();
                            break;
                        }
                    }
                }

                if (string.IsNullOrEmpty(downloadUrl))
                {
                    Logger.Warn($"No matching release asset '{AssetName}' found on GitHub remote release.");
                    return;
                }

                string releaseNotes = root.TryGetProperty("body", out var body) 
                    ? body.GetString() ?? "" 
                    : "";

                var updateInfo = new UpdateInfo
                {
                    Version = remoteVersion,
                    DownloadUrl = downloadUrl,
                    ReleaseNotes = releaseNotes,
                    AssetSize = assetSize
                };

                Logger.Info($"New update details fetched. Size: {assetSize} bytes. URL: {downloadUrl}");
                UpdateAvailable?.Invoke(updateInfo);
            }
            catch (Exception ex)
            {
                // Graceful failure — no crash, no UI disruption on network errors
                Logger.Error("Error checking for updates.", ex);
            }
        }

        /// <summary>
        /// Downloads the update ZIP, extracts it, and launches a batch script
        /// that replaces the exe after this process exits, then relaunches.
        /// </summary>
        public async Task<bool> DownloadAndApplyUpdateAsync(UpdateInfo updateInfo)
        {
            try
            {
                Logger.Info($"Downloading and applying update version v{updateInfo.Version}...");
                string tempDir = Path.Combine(Path.GetTempPath(), "PauselyUpdate");
                string zipPath = Path.Combine(tempDir, AssetName);
                string extractDir = Path.Combine(tempDir, "extracted");

                Logger.Info($"Cleaning and preparing temporary update directory: {tempDir}...");
                // Clean up any previous update attempt
                if (Directory.Exists(tempDir))
                    Directory.Delete(tempDir, true);
                Directory.CreateDirectory(tempDir);

                // Download the ZIP
                Logger.Info($"Downloading update ZIP package from {updateInfo.DownloadUrl}...");
                var response = await _httpClient.GetAsync(updateInfo.DownloadUrl);
                if (!response.IsSuccessStatusCode)
                {
                    Logger.Error($"Download request failed with HTTP Status: {response.StatusCode}");
                    return false;
                }

                await using var fileStream = File.Create(zipPath);
                await response.Content.CopyToAsync(fileStream);
                await fileStream.FlushAsync();
                fileStream.Close();

                // Verify file size
                var downloadedSize = new FileInfo(zipPath).Length;
                Logger.Info($"Download complete. Size: {downloadedSize} bytes.");
                if (updateInfo.AssetSize > 0 && downloadedSize != updateInfo.AssetSize)
                {
                    Logger.Error($"Size validation failed. Expected: {updateInfo.AssetSize}, Downloaded: {downloadedSize}");
                    return false;
                }

                // Extract
                Logger.Info($"Extracting zip content to {extractDir}...");
                if (Directory.Exists(extractDir))
                    Directory.Delete(extractDir, true);
                ZipFile.ExtractToDirectory(zipPath, extractDir);

                // Get current exe location — this is the original published exe path,
                // not the extracted single-file runtime temp directory
                string? currentExePath = Process.GetCurrentProcess().MainModule?.FileName;
                if (string.IsNullOrEmpty(currentExePath))
                {
                    Logger.Error("Unable to retrieve current process executable path.");
                    return false;
                }

                string installDir = Path.GetDirectoryName(currentExePath)!;
                string currentPid = Process.GetCurrentProcess().Id.ToString();

                // Write the updater batch script
                string batchPath = Path.Combine(tempDir, "PauselyUpdater.bat");
                Logger.Info($"Writing temporary batch updater script to {batchPath}...");
                string batchContent = $"""
                    @echo off
                    echo Waiting for Pausely to exit...
                    :wait
                    tasklist /FI "PID eq {currentPid}" 2>NUL | find /I "{currentPid}" >NUL
                    if not errorlevel 1 (
                        timeout /t 1 /nobreak >NUL
                        goto wait
                    )
                    echo Applying update...
                    xcopy /E /Y /Q "{extractDir}\*" "{installDir}\"
                    echo Relaunching Pausely...
                    start "" "{currentExePath}"
                    echo Cleaning up...
                    rmdir /S /Q "{extractDir}"
                    del "{zipPath}"
                    (goto) 2>nul & del "%~f0"
                    """;

                File.WriteAllText(batchPath, batchContent);

                // Launch the batch script detached
                Logger.Info("Launching batch update script detached...");
                var startInfo = new ProcessStartInfo
                {
                    FileName = "cmd.exe",
                    Arguments = $"/c \"{batchPath}\"",
                    CreateNoWindow = true,
                    UseShellExecute = false,
                    WindowStyle = ProcessWindowStyle.Hidden
                };
                Process.Start(startInfo);

                Logger.Info("Updater script launched. Ready to exit and apply update.");
                return true;
            }
            catch (Exception ex)
            {
                Logger.Error("Exception occurred during update downloading/application.", ex);
                return false;
            }
        }

        /// <summary>
        /// Compares two version strings (e.g., "1.0.42" vs "1.0.41").
        /// Returns true if remote is strictly newer than current.
        /// </summary>
        private static bool IsNewerVersion(string remote, string current)
        {
            if (Version.TryParse(remote, out var remoteVer) && Version.TryParse(current, out var currentVer))
            {
                return remoteVer > currentVer;
            }
            return false;
        }
    }
}
