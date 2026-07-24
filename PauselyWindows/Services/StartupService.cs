using System;
using System.Diagnostics;
using Microsoft.Win32;
using PauselyWindows;

namespace PauselyWindows.Services
{
    public class StartupService
    {
        public static StartupService Shared { get; } = new StartupService();

        private const string AppName = "Pausely";
        private const string RunKeyPath = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run";

        private StartupService() { }

        /// <summary>
        /// Returns the path to the currently running executable.
        /// For single-file published apps, this is the original exe, not the extracted temp path.
        /// </summary>
        private static string GetExePath()
        {
            return Process.GetCurrentProcess().MainModule?.FileName
                ?? throw new InvalidOperationException("Unable to determine executable path.");
        }

        /// <summary>
        /// Registers the app to run on system startup via HKCU\...\Run.
        /// No admin/elevation required.
        /// </summary>
        public void Register()
        {
            try
            {
                Logger.Info("Registering application for Windows startup...");
                using var key = Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true);
                string exePath = GetExePath();
                key.SetValue(AppName, $"\"{exePath}\"");
                Logger.Info($"Registered startup entry. Path: {exePath}");
            }
            catch (Exception ex)
            {
                // Best-effort — registry write may fail in sandboxed environments
                Logger.Error("Failed to register startup registry entry.", ex);
            }
        }

        /// <summary>
        /// Removes the app from system startup.
        /// </summary>
        public void Deregister()
        {
            try
            {
                Logger.Info("Removing application from Windows startup registry...");
                using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true);
                key?.DeleteValue(AppName, throwOnMissingValue: false);
                Logger.Info("Startup registry entry removed successfully.");
            }
            catch (Exception ex)
            {
                // Best-effort
                Logger.Error("Failed to deregister startup registry entry.", ex);
            }
        }

        /// <summary>
        /// Checks whether the app is currently registered for startup.
        /// </summary>
        public bool IsRegistered()
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath);
                string? registeredCommand = key?.GetValue(AppName) as string;
                if (string.IsNullOrWhiteSpace(registeredCommand))
                {
                    Logger.Info("Checked startup registry status: Not Registered");
                    return false;
                }

                string expectedCommand = $"\"{GetExePath()}\"";
                bool matchesCurrentExecutable = string.Equals(
                    registeredCommand.Trim(),
                    expectedCommand,
                    StringComparison.OrdinalIgnoreCase);
                Logger.Info(
                    matchesCurrentExecutable
                        ? "Checked startup registry status: Registered to the current executable"
                        : $"Startup registry path is stale. Registered: {registeredCommand}; expected: {expectedCommand}");
                return matchesCurrentExecutable;
            }
            catch (Exception ex)
            {
                Logger.Error("Failed to query startup registry key status.", ex);
                return false;
            }
        }

        /// <summary>
        /// Reconciles the persisted setting with the actual OS state.
        /// Call on app startup to handle cases where the user manually removed
        /// the startup entry via Task Manager.
        /// </summary>
        public void Reconcile(Settings.AppSettings settings)
        {
            bool osRegistered = IsRegistered();

            if (settings.RunOnStartup && !osRegistered)
            {
                // Setting says enabled, but registry entry is missing — re-register
                Register();
            }
            else if (!settings.RunOnStartup)
            {
                // Remove both current and stale registrations when the setting is disabled.
                Deregister();
            }
        }
    }
}
