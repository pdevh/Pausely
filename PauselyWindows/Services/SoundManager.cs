using System;
using System.IO;
using System.Media;
using Microsoft.Win32;

namespace PauselyWindows.Services
{
    public static class SoundManager
    {
        public static void PlayStartSound()
        {
            try
            {
                // Try reading user's default notification sound from registry
                string registryKey = @"AppEvents\Schemes\Apps\.Default\Notification.Default\.Current";
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(registryKey))
                {
                    if (key != null)
                    {
                        object val = key.GetValue("");
                        if (val != null && val is string soundPath && !string.IsNullOrWhiteSpace(soundPath))
                        {
                            if (File.Exists(soundPath))
                            {
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
            catch
            {
                // Ignore errors and proceed to fallbacks
            }

            // Fallback 1: Windows Background.wav
            string winBackgroundPath = @"C:\Windows\Media\Windows Background.wav";
            if (File.Exists(winBackgroundPath))
            {
                try
                {
                    using (SoundPlayer player = new SoundPlayer(winBackgroundPath))
                    {
                        player.Play();
                        return;
                    }
                }
                catch { }
            }

            // Final Fallback: SystemSounds.Asterisk
            SystemSounds.Asterisk.Play();
        }

        public static void PlayEndSound()
        {
            SystemSounds.Asterisk.Play();
        }
    }
}
