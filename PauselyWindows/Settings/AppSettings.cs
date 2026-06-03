using System;
using System.IO;
using System.Text.Json;

namespace PauselyWindows.Settings
{
    public class AppSettings
    {
        public static AppSettings Shared { get; } = new AppSettings();

        private static readonly string SettingsDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Pausely");
        private static readonly string SettingsFile = Path.Combine(SettingsDir, "settings.json");

        private readonly object _lock = new();

        public bool AutoUpdateEnabled { get; set; } = false;
        public bool RunOnStartup { get; set; } = false;

        private AppSettings()
        {
            Load();
        }

        public void Load()
        {
            lock (_lock)
            {
                try
                {
                    if (File.Exists(SettingsFile))
                    {
                        string json = File.ReadAllText(SettingsFile);
                        var data = JsonSerializer.Deserialize<SettingsData>(json);
                        if (data != null)
                        {
                            AutoUpdateEnabled = data.AutoUpdateEnabled;
                            RunOnStartup = data.RunOnStartup;
                        }
                    }
                }
                catch
                {
                    // Corrupted settings file — use defaults
                }
            }
        }

        public void Save()
        {
            lock (_lock)
            {
                try
                {
                    Directory.CreateDirectory(SettingsDir);
                    var data = new SettingsData
                    {
                        AutoUpdateEnabled = this.AutoUpdateEnabled,
                        RunOnStartup = this.RunOnStartup
                    };
                    string json = JsonSerializer.Serialize(data, new JsonSerializerOptions
                    {
                        WriteIndented = true
                    });
                    File.WriteAllText(SettingsFile, json);
                }
                catch
                {
                    // Best-effort persistence — don't crash the app
                }
            }
        }

        private class SettingsData
        {
            public bool AutoUpdateEnabled { get; set; }
            public bool RunOnStartup { get; set; }
        }
    }
}
