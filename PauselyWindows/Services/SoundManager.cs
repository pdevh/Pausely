using System;
using System.IO;
using System.Media;
using Microsoft.Win32;
using PauselyWindows;

namespace PauselyWindows.Services
{
    public static class SoundManager
    {
        public static void PlayStartSound()
        {
            try
            {
                Logger.Info("Attempting to play break start sound...");
                // Try reading user's default notification sound from registry
                string registryKey = @"AppEvents\Schemes\Apps\.Default\Notification.Default\.Current";
                using (RegistryKey? key = Registry.CurrentUser.OpenSubKey(registryKey))
                {
                    if (key != null)
                    {
                        object? val = key.GetValue("");
                        if (val != null && val is string soundPath && !string.IsNullOrWhiteSpace(soundPath))
                        {
                            if (File.Exists(soundPath))
                            {
                                Logger.Info($"Playing notification sound from registry: {soundPath}");
                                using (SoundPlayer player = new SoundPlayer(soundPath))
                                {
                                    player.Play();
                                    return;
                                }
                            }
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                // Ignore errors and proceed to fallbacks
                Logger.Warn($"Failed to read/play notification sound from registry, attempting fallback. Exception: {ex.Message}");
            }

            // Fallback 1: Windows Background.wav
            string winBackgroundPath = @"C:\Windows\Media\Windows Background.wav";
            if (File.Exists(winBackgroundPath))
            {
                try
                {
                    Logger.Info($"Attempting to play fallback sound: {winBackgroundPath}");
                    using (SoundPlayer player = new SoundPlayer(winBackgroundPath))
                    {
                        player.Play();
                        return;
                    }
                }
                catch (Exception ex)
                {
                    Logger.Warn($"Failed to play fallback sound: {winBackgroundPath}. Exception: {ex.Message}");
                }
            }

            // Final Fallback: SystemSounds.Asterisk
            Logger.Info("Playing final fallback SystemSounds.Asterisk...");
            SystemSounds.Asterisk.Play();
        }

        public static void PlayEndSound()
        {
            Logger.Info("Playing break end sound (SystemSounds.Asterisk)...");
            SystemSounds.Asterisk.Play();
        }
    }
}
