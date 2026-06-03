using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Reflection;
using System.Text.Json;
using System.Threading.Tasks;

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
                // Delay 5 seconds to not block app launch
                await Task.Delay(5000);

                var response = await _httpClient.GetAsync(GitHubApiUrl);
                if (!response.IsSuccessStatusCode)
                    return;

                var json = await response.Content.ReadAsStringAsync();
                using var doc = JsonDocument.Parse(json);
                var root = doc.RootElement;

                // Extract tag_name (e.g., "v1.0.42")
                string tagName = root.GetProperty("tag_name").GetString() ?? "";
                string remoteVersion = tagName.TrimStart('v');

                string currentVersion = GetCurrentVersion();

                if (!IsNewerVersion(remoteVersion, currentVersion))
                    return;

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
                    return;

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

                UpdateAvailable?.Invoke(updateInfo);
            }
            catch
            {
                // Graceful failure — no crash, no UI disruption on network errors
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
                string tempDir = Path.Combine(Path.GetTempPath(), "PauselyUpdate");
                string zipPath = Path.Combine(tempDir, AssetName);
                string extractDir = Path.Combine(tempDir, "extracted");

                // Clean up any previous update attempt
                if (Directory.Exists(tempDir))
                    Directory.Delete(tempDir, true);
                Directory.CreateDirectory(tempDir);

                // Download the ZIP
                var response = await _httpClient.GetAsync(updateInfo.DownloadUrl);
                if (!response.IsSuccessStatusCode)
                    return false;

                await using var fileStream = File.Create(zipPath);
                await response.Content.CopyToAsync(fileStream);
                await fileStream.FlushAsync();
                fileStream.Close();

                // Verify file size
                var downloadedSize = new FileInfo(zipPath).Length;
                if (updateInfo.AssetSize > 0 && downloadedSize != updateInfo.AssetSize)
                    return false;

                // Extract
                if (Directory.Exists(extractDir))
                    Directory.Delete(extractDir, true);
                ZipFile.ExtractToDirectory(zipPath, extractDir);

                // Get current exe location — this is the original published exe path,
                // not the extracted single-file runtime temp directory
                string? currentExePath = Process.GetCurrentProcess().MainModule?.FileName;
                if (string.IsNullOrEmpty(currentExePath))
                    return false;

                string installDir = Path.GetDirectoryName(currentExePath)!;
                string currentPid = Process.GetCurrentProcess().Id.ToString();

                // Write the updater batch script
                string batchPath = Path.Combine(tempDir, "PauselyUpdater.bat");
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
                var startInfo = new ProcessStartInfo
                {
                    FileName = "cmd.exe",
                    Arguments = $"/c \"{batchPath}\"",
                    CreateNoWindow = true,
                    UseShellExecute = false,
                    WindowStyle = ProcessWindowStyle.Hidden
                };
                Process.Start(startInfo);

                return true;
            }
            catch
            {
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
