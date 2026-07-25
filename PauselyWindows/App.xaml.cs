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
        private CursorWarningWindow _cursorWarningWindow;
        private bool _isShuttingDown;
        private bool _updateInstallInProgress;
        private RoutedEventHandler _updateBalloonClickHandler;

        private void Application_Startup(object sender, StartupEventArgs e)
        {
            Logger.Info("Pausely Windows application starting up...");

            if (e.Args.Length == 2 &&
                e.Args[0].Equals(
                    "--verify-update-signature",
                    StringComparison.OrdinalIgnoreCase))
            {
                SignatureVerificationResult result =
                    WindowsSignatureVerifier.VerifyFile(e.Args[1]);
                if (!result.IsValid)
                {
                    Logger.Error($"Signature verification failed: {result.Error}");
                }
                Shutdown(result.IsValid ? 0 : 1);
                return;
            }

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
                Icon = LoadApplicationIcon(),
                ToolTipText = "Pausely",
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
            _cursorWarningWindow = new CursorWarningWindow();
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
            UpdateIntervalCheckmarks();

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
                UpdateCursorWarning();
                UpdateIntervalCheckmarks();
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
                    else if (_breakManager.Status == BreakStatus.Paused)
                    {
                        string timeFormatted = $"{_breakManager.TimeRemaining / 60:D2}:{_breakManager.TimeRemaining % 60:D2}";
                        statusItem.Header = $"Breaks paused · {timeFormatted} left";
                        _taskbarIcon.ToolTipText = $"Breaks paused · {timeFormatted} left";
                    }
                    else
                    {
                        string timeFormatted = $"{_breakManager.TimeRemaining / 60:D2}:{_breakManager.TimeRemaining % 60:D2}";
                        statusItem.Header = $"Next break in {timeFormatted}";
                        _taskbarIcon.ToolTipText = $"Next break in {timeFormatted}";
                    }

                    if (statusItem.Icon is Wpf.Ui.Controls.ProgressRing progressRing)
                    {
                        double progress = _breakManager.Status == BreakStatus.Working
                            ? 1.0 - ((double)_breakManager.TimeRemaining / _breakManager.WorkInterval)
                            : 0.0;
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
                        else if (menuItem.Name == "HostSessionMenuItem")
                        {
                            menuItem.Visibility = _breakManager.IsSyncedSession ? Visibility.Collapsed : Visibility.Visible;
                            menuItem.IsEnabled = _breakManager.Status == BreakStatus.Working;
                        }
                        else if (menuItem.Name == "CopySessionCodeMenuItem")
                        {
                            menuItem.Visibility = _breakManager.IsSyncedSession ? Visibility.Visible : Visibility.Collapsed;
                        }
                        else if (menuItem.Name == "PauseBreaksMenuItem")
                        {
                            menuItem.Visibility = _breakManager.Status == BreakStatus.Paused ? Visibility.Collapsed : Visibility.Visible;
                            menuItem.IsEnabled = !_breakManager.IsSyncedSession && _breakManager.Status == BreakStatus.Working;
                            menuItem.Header = $"Pause Breaks ({FormatFriendlyDuration(_breakManager.SuggestedPauseDuration)})";
                        }
                        else if (menuItem.Name == "ResumeBreaksMenuItem")
                        {
                            menuItem.Visibility = _breakManager.Status == BreakStatus.Paused ? Visibility.Visible : Visibility.Collapsed;
                        }
                        else if (menuItem.Name == "WorkIntervalMenuItem" || menuItem.Name == "BreakDurationMenuItem")
                        {
                            menuItem.IsEnabled = !_breakManager.IsSyncedSession;
                        }
                    }
                }
            });
        }

        private void UpdateCursorWarning()
        {
            if (_breakManager.Status == BreakStatus.Working &&
                !_breakManager.IsScreenLocked &&
                _breakManager.TimeRemaining > 0 && _breakManager.TimeRemaining <= 10)
            {
                _cursorWarningWindow.ShowCountdown(_breakManager.TimeRemaining);
            }
            else if (_breakManager.IsScreenLocked ||
                     _breakManager.Status != BreakStatus.Working ||
                     _breakManager.TimeRemaining > 10)
            {
                _cursorWarningWindow.HideCountdown();
            }
        }

        private static string FormatFriendlyDuration(double seconds)
        {
            if (seconds >= 3600 && seconds % 3600 == 0) return $"{seconds / 3600:0}h";
            if (seconds >= 60 && seconds % 60 == 0) return $"{seconds / 60:0}m";
            return $"{seconds:0}s";
        }

        private void UpdateIntervalCheckmarks()
        {
            SetTaggedMenuCheckmarks((System.Windows.Controls.MenuItem)FindElementByName(_taskbarIcon.ContextMenu, "WorkIntervalMenuItem"), _breakManager.WorkInterval);
            SetTaggedMenuCheckmarks((System.Windows.Controls.MenuItem)FindElementByName(_taskbarIcon.ContextMenu, "BreakDurationMenuItem"), _breakManager.BreakDuration);
        }

        private static void SetTaggedMenuCheckmarks(System.Windows.Controls.MenuItem parent, double selectedValue)
        {
            if (parent == null) return;
            foreach (object item in parent.Items)
            {
                if (item is System.Windows.Controls.MenuItem menuItem &&
                    double.TryParse(menuItem.Tag?.ToString(), out double value))
                {
                    menuItem.IsChecked = Math.Abs(value - selectedValue) < 0.001;
                }
            }
        }

        private void BreakManager_BreakTriggered(object sender, EventArgs e)
        {
            Dispatcher.Invoke(() =>
            {
                _cursorWarningWindow.HideCountdown();
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

        private void PauseBreaks_Click(object sender, RoutedEventArgs e)
        {
            _breakManager.PauseBreaks();
        }

        private void ResumeBreaks_Click(object sender, RoutedEventArgs e)
        {
            _breakManager.ResumeBreaks();
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

        private void HostSession_Click(object sender, RoutedEventArgs e)
        {
            CopySessionCode_Click(sender, e);
            UpdateStatusMenu();
            _taskbarIcon.ShowBalloonTip(
                "Session ready",
                "The invite code was copied to your clipboard.",
                BalloonIcon.Info);
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

        private async void CheckForUpdates_Click(object sender, RoutedEventArgs e)
        {
            bool? updateAvailable = await UpdateService.Shared.CheckForUpdateAsync(delayAtStartup: false);
            if (updateAvailable == false)
            {
                _taskbarIcon.ShowBalloonTip(
                    "Pausely is up to date",
                    $"You’re running the latest version ({UpdateService.GetCurrentVersion()}).",
                    BalloonIcon.Info);
            }
            else if (updateAvailable == null)
            {
                _taskbarIcon.ShowBalloonTip(
                    "Couldn’t check for updates",
                    "Check your internet connection and try again.",
                    BalloonIcon.Warning);
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
            string updateDescription =
                $"Pausely v{info.Version} is available. Click to install.";
            Logger.Info(
                $"Update check completed: New version v{info.Version} is available.");
            Dispatcher.Invoke(() =>
            {
                if (_updateBalloonClickHandler != null)
                {
                    _taskbarIcon.TrayBalloonTipClicked -= _updateBalloonClickHandler;
                }

                RoutedEventHandler clickHandler = null;
                clickHandler = async (s, e) =>
                {
                    _taskbarIcon.TrayBalloonTipClicked -= clickHandler;
                    if (ReferenceEquals(_updateBalloonClickHandler, clickHandler))
                    {
                        _updateBalloonClickHandler = null;
                    }

                    if (_updateInstallInProgress)
                    {
                        Logger.Info("Ignored a duplicate update balloon click while installation is already starting.");
                        return;
                    }

                    _updateInstallInProgress = true;
                    try
                    {
                        Logger.Info($"User clicked update balloon tip for v{info.Version}. Initiating download...");
                        bool success = await UpdateService.Shared.DownloadAndApplyUpdateAsync(info);
                        if (success)
                        {
                            Logger.Info("Verified installer started. Windows Installer will close and relaunch Pausely.");
                        }
                        else
                        {
                            Logger.Error("Failed to apply update.");
                            _taskbarIcon.ShowBalloonTip(
                                "Update not installed",
                                "Pausely kept running because the installer could not be verified or started.",
                                BalloonIcon.Warning);
                        }
                    }
                    catch (Exception ex)
                    {
                        Logger.Error("Exception occurred while handling update balloon tip click", ex);
                    }
                    finally
                    {
                        _updateInstallInProgress = false;
                    }
                };
                _updateBalloonClickHandler = clickHandler;
                _taskbarIcon.TrayBalloonTipClicked += clickHandler;

                _taskbarIcon.ShowBalloonTip(
                    "Update Available",
                    updateDescription,
                    BalloonIcon.Info);
            });
        }

        private void Quit_Click(object sender, RoutedEventArgs e)
        {
            ShutdownApplication("tray Quit selected");
        }

        private void ShutdownApplication(string reason)
        {
            if (_isShuttingDown)
            {
                return;
            }

            _isShuttingDown = true;
            Logger.Info($"Pausely Windows application shutting down: {reason}.");

            try
            {
                _breakManager?.StopTimer();
                _cursorWarningWindow?.Close();
                foreach (var window in _overlayWindows)
                {
                    window.Close();
                }
                _overlayWindows.Clear();
                _taskbarIcon?.Dispose();
            }
            finally
            {
                Current.Shutdown();
            }
        }

        private static System.Drawing.Icon LoadApplicationIcon()
        {
            try
            {
                var iconUri = new Uri("pack://application:,,,/Pausely.ico");
                var streamInfo = System.Windows.Application.GetResourceStream(iconUri);
                if (streamInfo != null)
                {
                    return new System.Drawing.Icon(streamInfo.Stream);
                }
            }
            catch (Exception ex)
            {
                Logger.Error("Failed to load application icon resource, falling back to default.", ex);
            }
            return SystemIcons.Application;
        }
    }
}
