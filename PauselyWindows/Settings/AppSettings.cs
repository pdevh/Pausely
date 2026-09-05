using System;
using System.IO;
using System.Text.Json;
using PauselyWindows;
using PauselyWindows.Services;

namespace PauselyWindows.Settings
{
    public class AppSettings
    {
        private static readonly string SettingsDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Pausely");
        private static readonly string SettingsFile = Path.Combine(SettingsDir, "settings.json");

        public static AppSettings Shared { get; } = new AppSettings();

        private readonly object _lock = new();
        private readonly string _settingsFile;

        public bool AutoUpdateEnabled { get; set; } = false;
        public bool RunOnStartup { get; set; } = false;
        public double WorkInterval { get; set; } = 1200;
        public double BreakDuration { get; set; } = 20;

        private AppSettings() : this(SettingsFile) { }

        internal AppSettings(string settingsFile)
        {
            _settingsFile = settingsFile;
            Load();
        }

        public void Load()
        {
            lock (_lock)
            {
                try
                {
                    if (File.Exists(_settingsFile))
                    {
                        Logger.Info($"Loading settings from {_settingsFile}...");
                        string json = File.ReadAllText(_settingsFile);
                        var data = JsonSerializer.Deserialize<SettingsData>(json);
                        if (data != null)
                        {
                            AutoUpdateEnabled = data.AutoUpdateEnabled;
                            RunOnStartup = data.RunOnStartup;
                            if (DurationValue.IsValid(data.WorkInterval)) WorkInterval = data.WorkInterval;
                            if (DurationValue.IsValid(data.BreakDuration)) BreakDuration = data.BreakDuration;
                            Logger.Info("Settings loaded successfully.");
                        }
                    }
                    else
                    {
                        Logger.Info($"Settings file {_settingsFile} not found, using default settings.");
                    }
                }
                catch (Exception ex)
                {
                    // Corrupted settings file — use defaults
                    Logger.Error($"Failed to load app settings from {_settingsFile}, using defaults.", ex);
                }
            }
        }

        public void Save()
        {
            lock (_lock)
            {
                try
                {
                    Logger.Info($"Saving settings to {_settingsFile}...");
                    Directory.CreateDirectory(Path.GetDirectoryName(_settingsFile)!);
                    var data = new SettingsData
                    {
                        AutoUpdateEnabled = this.AutoUpdateEnabled,
                        RunOnStartup = this.RunOnStartup,
                        WorkInterval = this.WorkInterval,
                        BreakDuration = this.BreakDuration
                    };
                    string json = JsonSerializer.Serialize(data, new JsonSerializerOptions
                    {
                        WriteIndented = true
                    });
                    File.WriteAllText(_settingsFile, json);
                    Logger.Info("Settings saved successfully.");
                }
                catch (Exception ex)
                {
                    // Best-effort persistence — don't crash the app
                    Logger.Error($"Failed to save app settings to {_settingsFile}", ex);
                }
            }
        }

        private class SettingsData
        {
            public bool AutoUpdateEnabled { get; set; }
            public bool RunOnStartup { get; set; }
            public double WorkInterval { get; set; } = 1200;
            public double BreakDuration { get; set; } = 20;
        }
    }
}
