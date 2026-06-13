#nullable disable

using System;
using System.Drawing;
using System.Windows;
using System.Windows.Controls;
using Hardcodet.Wpf.TaskbarNotification;
using System.Collections.Generic;
using PauselyWindows.Settings;
using PauselyWindows.Services;

namespace PauselyWindows
{
    public partial class App : System.Windows.Application
    {
        private TaskbarIcon _taskbarIcon;
        private BreakManager _breakManager;
        private List<OverlayWindow> _overlayWindows = new List<OverlayWindow>();

        private void Application_Startup(object sender, StartupEventArgs e)
        {
            Logger.Info("Pausely Windows application starting up...");

            DispatcherUnhandledException += (s, args) =>
            {
                Logger.Error("Unhandled Dispatcher Exception", args.Exception);
                args.Handled = true;
            };
            AppDomain.CurrentDomain.UnhandledException += (s, args) =>
            {
                Logger.Fatal("Unhandled AppDomain Exception", args.ExceptionObject as Exception);
            };
            System.Threading.Tasks.TaskScheduler.UnobservedTaskException += (s, args) =>
            {
                Logger.Error("Unobserved Task Exception", args.Exception);
                args.SetObserved();
            };
            _taskbarIcon = new TaskbarIcon
            {
                Icon = SystemIcons.Application,
                ToolTipText = "Pausely MVP",
                ContextMenu = (System.Windows.Controls.ContextMenu)FindResource("SysTrayMenu")
            };
            _taskbarIcon.TrayLeftMouseUp += (s, args) =>
            {
                if (_taskbarIcon.ContextMenu != null)
                {
                    _taskbarIcon.ContextMenu.IsOpen = true;
                }
            };

            _breakManager = BreakManager.Shared;
            _breakManager.WorkInterval = AppSettings.Shared.WorkInterval;
            _breakManager.BreakDuration = AppSettings.Shared.BreakDuration;
            _breakManager.StatusChanged += BreakManager_StatusChanged;
            _breakManager.TimerTicked += BreakManager_TimerTicked;
            _breakManager.BreakTriggered += BreakManager_BreakTriggered;
            _breakManager.BreakEnded += BreakManager_BreakEnded;
            _breakManager.IntermissionTriggered += BreakManager_IntermissionTriggered;
            _breakManager.IntermissionEnded += BreakManager_IntermissionEnded;

            UpdateStatusMenu();

            // Set initial toggle states
            var contextMenu = _taskbarIcon.ContextMenu;
            var autoUpdateItem = (System.Windows.Controls.MenuItem)FindElementByName(contextMenu, "AutoUpdateMenuItem");
            if (autoUpdateItem != null) autoUpdateItem.IsChecked = AppSettings.Shared.AutoUpdateEnabled;
            
            var runOnStartupItem = (System.Windows.Controls.MenuItem)FindElementByName(contextMenu, "RunOnStartupMenuItem");
            if (runOnStartupItem != null) runOnStartupItem.IsChecked = AppSettings.Shared.RunOnStartup;

            // Startup features
            StartupService.Shared.Reconcile(AppSettings.Shared);
            
            UpdateService.Shared.UpdateAvailable += UpdateService_UpdateAvailable;
            if (AppSettings.Shared.AutoUpdateEnabled)
            {
                _ = UpdateService.Shared.CheckForUpdateAsync();
            }
        }

        private object FindElementByName(System.Windows.Controls.ItemsControl parent, string name)
        {
            if (parent == null) return null;

            foreach (var item in parent.Items)
            {
                if (item is FrameworkElement fe && fe.Name == name) return fe;
                
                if (item is System.Windows.Controls.MenuItem mi)
                {
                    if (mi.Header is FrameworkElement headerFe && headerFe.Name == name) return headerFe;
                    
                    if (mi.Items.Count > 0)
                    {
                        var found = FindElementByName(mi, name);
                        if (found != null) return found;
                    }
                }
            }
            return null;
        }

        private void BreakManager_StatusChanged(object sender, EventArgs e)
        {
            UpdateStatusMenu();
        }

        private void BreakManager_TimerTicked(object sender, EventArgs e)
        {
            UpdateStatusMenu();
        }

        private void UpdateStatusMenu()
        {
            Dispatcher.Invoke(() =>
            {
                var contextMenu = _taskbarIcon.ContextMenu;
                if (contextMenu == null) return;
                
                var statusItem = (System.Windows.Controls.MenuItem)FindElementByName(contextMenu, "StatusMenuItem");
                
                if (statusItem != null)
                {
                    if (_breakManager.Status == BreakStatus.InBreak)
                    {
                        statusItem.Header = "Break in progress";
                        _taskbarIcon.ToolTipText = "Break in progress";
                    }
                    else
                    {
                        string timeFormatted = $"{_breakManager.TimeRemaining / 60:D2}:{_breakManager.TimeRemaining % 60:D2}";
                        statusItem.Header = $"Next break in {timeFormatted}";
                        _taskbarIcon.ToolTipText = $"Next break in {timeFormatted}";
                    }

                    if (statusItem.Icon is Wpf.Ui.Controls.ProgressRing progressRing)
                    {
                        double progress = 1.0 - ((double)_breakManager.TimeRemaining / _breakManager.WorkInterval);
                        progressRing.Progress = Math.Max(0.0, Math.Min(100.0, progress * 100));
                    }
                }

                var startBreakButton = (System.Windows.Controls.Button)FindElementByName(contextMenu, "StartBreakButton");
                if (startBreakButton != null)
                {
                    startBreakButton.Content = _breakManager.IsSyncedSession ? "Start Intermission" : "Start Break Now";
                }

                // Dynamically show/hide Leave Session and enable/disable settings
                foreach (object item in contextMenu.Items)
                {
                    if (item is System.Windows.Controls.MenuItem menuItem)
                    {
                        if (menuItem.Name == "LeaveSessionMenuItem")
                        {
                            menuItem.Visibility = _breakManager.IsSyncedSession ? Visibility.Visible : Visibility.Collapsed;
                        }
                        else if (menuItem.Name == "WorkIntervalMenuItem" || menuItem.Name == "BreakDurationMenuItem")
                        {
                            menuItem.IsEnabled = !_breakManager.IsSyncedSession;
                        }
                    }
                }
            });
        }

        private void BreakManager_BreakTriggered(object sender, EventArgs e)
        {
            Dispatcher.Invoke(() =>
            {
                // Capture current wallpaper before showing overlay
                WallpaperCaptureService.Shared.Refresh();

                // Play Sound
                SoundManager.PlayStartSound();

                foreach (var window in _overlayWindows)
                {
                    window.Close();
                }
                _overlayWindows.Clear();

                foreach (var screen in System.Windows.Forms.Screen.AllScreens)
                {
                    var window = new OverlayWindow();
                    var dpiScale = System.Windows.Media.VisualTreeHelper.GetDpi(window);
                    window.Left = screen.Bounds.Left / dpiScale.DpiScaleX;
                    window.Top = screen.Bounds.Top / dpiScale.DpiScaleY;
                    window.Width = screen.Bounds.Width / dpiScale.DpiScaleX;
                    window.Height = screen.Bounds.Height / dpiScale.DpiScaleY;
                    window.Show();
                    _overlayWindows.Add(window);
                }
            });
        }

        private void BreakManager_BreakEnded(object sender, BreakEndedEventArgs e)
        {
            Dispatcher.Invoke(() =>
            {
                // Play Sound
                if (e.PlaySound)
                {
                    SoundManager.PlayEndSound();
                }

                foreach (var window in _overlayWindows)
                {
                    window.Close();
                }
                _overlayWindows.Clear();
            });
        }

        private void StartBreak_Click(object sender, RoutedEventArgs e)
        {
            if (_taskbarIcon?.ContextMenu != null)
            {
                _taskbarIcon.ContextMenu.IsOpen = false;
            }

            if (_breakManager.IsSyncedSession)
            {
                _breakManager.StartIntermission();
            }
            else
            {
                _breakManager.TriggerBreak();
            }
        }

        private void LeaveSession_Click(object sender, RoutedEventArgs e)
        {
            _breakManager.LeaveSession();
        }

        private void BreakManager_IntermissionTriggered(object sender, EventArgs e)
        {
            Dispatcher.Invoke(() =>
            {
                // Capture current wallpaper before showing overlay
                WallpaperCaptureService.Shared.Refresh();

                SoundManager.PlayStartSound();

                foreach (var window in _overlayWindows)
                {
                    window.Close();
                }
                _overlayWindows.Clear();

                foreach (var screen in System.Windows.Forms.Screen.AllScreens)
                {
                    var window = new OverlayWindow(isIntermission: true);
                    var dpiScale = System.Windows.Media.VisualTreeHelper.GetDpi(window);
                    window.Left = screen.Bounds.Left / dpiScale.DpiScaleX;
                    window.Top = screen.Bounds.Top / dpiScale.DpiScaleY;
                    window.Width = screen.Bounds.Width / dpiScale.DpiScaleX;
                    window.Height = screen.Bounds.Height / dpiScale.DpiScaleY;
                    window.Show();
                    _overlayWindows.Add(window);
                }
            });
        }

        private void BreakManager_IntermissionEnded(object sender, BreakEndedEventArgs e)
        {
            Dispatcher.Invoke(() =>
            {
                if (e.PlaySound)
                {
                    SoundManager.PlayEndSound();
                }

                foreach (var window in _overlayWindows)
                {
                    window.Close();
                }
                _overlayWindows.Clear();
            });
        }

        private void WorkInterval_Click(object sender, RoutedEventArgs e)
        {
            var menuItem = (System.Windows.Controls.MenuItem)sender;
            var parent = (System.Windows.Controls.MenuItem)menuItem.Parent;
            foreach (var item in parent.Items)
            {
                if (item is System.Windows.Controls.MenuItem mi) mi.IsChecked = false;
            }
            menuItem.IsChecked = true;

            if (menuItem.Tag != null && int.TryParse(menuItem.Tag.ToString(), out int seconds))
            {
                Logger.Info($"User set work interval to {seconds} seconds.");
                _breakManager.WorkInterval = seconds;
                AppSettings.Shared.WorkInterval = seconds;
                AppSettings.Shared.Save();
            }
        }

        private void BreakDuration_Click(object sender, RoutedEventArgs e)
        {
            var menuItem = (System.Windows.Controls.MenuItem)sender;
            var parent = (System.Windows.Controls.MenuItem)menuItem.Parent;
            foreach (var item in parent.Items)
            {
                if (item is System.Windows.Controls.MenuItem mi) mi.IsChecked = false;
            }
            menuItem.IsChecked = true;

            if (menuItem.Tag != null && int.TryParse(menuItem.Tag.ToString(), out int seconds))
            {
                Logger.Info($"User set break duration to {seconds} seconds.");
                _breakManager.BreakDuration = seconds;
                AppSettings.Shared.BreakDuration = seconds;
                AppSettings.Shared.Save();
            }
        }

        private void CopySessionCode_Click(object sender, RoutedEventArgs e)
        {
            string code = _breakManager.GenerateSessionCode();
            Logger.Info($"Generated session code for sync: {code}");
            try
            {
                System.Windows.Clipboard.SetText(code);
                Logger.Info("Session code copied to clipboard successfully.");
            }
            catch (System.Runtime.InteropServices.COMException ex)
            {
                Logger.Warn($"Failed to copy session code to clipboard: Clipboard locked by another process. Exception: {ex.Message}");
            }
        }

        private void JoinSession_Click(object sender, RoutedEventArgs e)
        {
            var window = new JoinSessionWindow();
            window.ShowDialog();
        }

        private void AutoUpdate_Click(object sender, RoutedEventArgs e)
        {
            if (sender is System.Windows.Controls.MenuItem menuItem)
            {
                AppSettings.Shared.AutoUpdateEnabled = menuItem.IsChecked;
                AppSettings.Shared.Save();
            }
        }

        private void RunOnStartup_Click(object sender, RoutedEventArgs e)
        {
            if (sender is System.Windows.Controls.MenuItem menuItem)
            {
                AppSettings.Shared.RunOnStartup = menuItem.IsChecked;
                AppSettings.Shared.Save();
                StartupService.Shared.Reconcile(AppSettings.Shared);
            }
        }

        private void UpdateService_UpdateAvailable(UpdateInfo info)
        {
            Logger.Info($"Update check completed: New version v{info.Version} is available.");
            Dispatcher.Invoke(() =>
            {
                _taskbarIcon.ShowBalloonTip(
                    "Update Available", 
                    $"Pausely v{info.Version} is available. Click to install.", 
                    BalloonIcon.Info);

                _taskbarIcon.TrayBalloonTipClicked -= OnTrayBalloonTipClicked; // Prevent multiple handlers
                _taskbarIcon.TrayBalloonTipClicked += OnTrayBalloonTipClicked;

                async void OnTrayBalloonTipClicked(object s, RoutedEventArgs e)
                {
                    try
                    {
                        Logger.Info($"User clicked update balloon tip for v{info.Version}. Initiating download...");
                        _taskbarIcon.TrayBalloonTipClicked -= OnTrayBalloonTipClicked;
                        bool success = await UpdateService.Shared.DownloadAndApplyUpdateAsync(info);
                        if (success)
                        {
                            Logger.Info("Update applied successfully. Shutting down application for restart...");
                            _taskbarIcon?.Dispose();
                            Current.Shutdown();
                        }
                        else
                        {
                            Logger.Error("Failed to apply update.");
                        }
                    }
                    catch (Exception ex)
                    {
                        Logger.Error("Exception occurred while handling update balloon tip click", ex);
                    }
                }
            });
        }

        private void Quit_Click(object sender, RoutedEventArgs e)
        {
            Logger.Info("Pausely Windows application shutting down via Tray Quit click...");
            _breakManager.StopTimer();
            foreach (var window in _overlayWindows)
            {
                window.Close();
            }
            _overlayWindows.Clear();
            _taskbarIcon?.Dispose();
            Current.Shutdown();
        }
    }
}
