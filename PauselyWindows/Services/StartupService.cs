using System;
using System.Diagnostics;
using Microsoft.Win32;

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
                using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true);
                key?.SetValue(AppName, $"\"{GetExePath()}\"");
            }
            catch
            {
                // Best-effort — registry write may fail in sandboxed environments
            }
        }

        /// <summary>
        /// Removes the app from system startup.
        /// </summary>
        public void Deregister()
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true);
                key?.DeleteValue(AppName, throwOnMissingValue: false);
            }
            catch
            {
                // Best-effort
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
                return key?.GetValue(AppName) != null;
            }
            catch
            {
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
            else if (!settings.RunOnStartup && osRegistered)
            {
                // Setting says disabled, but registry entry exists — deregister
                Deregister();
            }
        }
    }
}
