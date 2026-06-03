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
            _taskbarIcon = new TaskbarIcon
            {
                Icon = SystemIcons.Application,
                ToolTipText = "Pausely MVP",
                ContextMenu = (System.Windows.Controls.ContextMenu)FindResource("SysTrayMenu")
            };

            _breakManager = BreakManager.Shared;
            _breakManager.StatusChanged += BreakManager_StatusChanged;
            _breakManager.TimerTicked += BreakManager_TimerTicked;
            _breakManager.BreakTriggered += BreakManager_BreakTriggered;
            _breakManager.BreakEnded += BreakManager_BreakEnded;
            _breakManager.IntermissionTriggered += BreakManager_IntermissionTriggered;
            _breakManager.IntermissionEnded += BreakManager_IntermissionEnded;

            UpdateStatusMenu();

            // Set initial toggle states
            var contextMenu = _taskbarIcon.ContextMenu;
            var autoUpdateItem = (System.Windows.Controls.MenuItem)contextMenu.FindName("AutoUpdateMenuItem");
            if (autoUpdateItem != null) autoUpdateItem.IsChecked = AppSettings.Shared.AutoUpdateEnabled;
            
            var runOnStartupItem = (System.Windows.Controls.MenuItem)contextMenu.FindName("RunOnStartupMenuItem");
            if (runOnStartupItem != null) runOnStartupItem.IsChecked = AppSettings.Shared.RunOnStartup;

            // Startup features
            StartupService.Shared.Reconcile(AppSettings.Shared);
            
            UpdateService.Shared.UpdateAvailable += UpdateService_UpdateAvailable;
            if (AppSettings.Shared.AutoUpdateEnabled)
            {
                _ = UpdateService.Shared.CheckForUpdateAsync();
            }
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
                
                var headerItem = (System.Windows.Controls.MenuItem)contextMenu.Items[0];
                headerItem.Header = _breakManager.IsSyncedSession ? "Pausely MVP (Synced)" : "Pausely MVP";

                var statusItem = (System.Windows.Controls.MenuItem)contextMenu.Items[1];
                
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
                // Play Sound
                System.Media.SystemSounds.Exclamation.Play();

                _overlayWindows.Clear();
                foreach (var screen in System.Windows.Forms.Screen.AllScreens)
                {
                    var window = new OverlayWindow();
                    window.Left = screen.Bounds.Left;
                    window.Top = screen.Bounds.Top;
                    window.Width = screen.Bounds.Width;
                    window.Height = screen.Bounds.Height;
                    window.Show();
                    _overlayWindows.Add(window);
                }
            });
        }

        private void BreakManager_BreakEnded(object sender, EventArgs e)
        {
            Dispatcher.Invoke(() =>
            {
                // Play Sound
                System.Media.SystemSounds.Asterisk.Play();

                foreach (var window in _overlayWindows)
                {
                    window.Close();
                }
                _overlayWindows.Clear();
            });
        }

        private void StartBreak_Click(object sender, RoutedEventArgs e)
        {
            _breakManager.StartIntermission();
        }

        private void LeaveSession_Click(object sender, RoutedEventArgs e)
        {
            _breakManager.LeaveSession();
        }

        private void BreakManager_IntermissionTriggered(object sender, EventArgs e)
        {
            Dispatcher.Invoke(() =>
            {
                System.Media.SystemSounds.Exclamation.Play();

                _overlayWindows.Clear();
                foreach (var screen in System.Windows.Forms.Screen.AllScreens)
                {
                    var window = new OverlayWindow(isIntermission: true);
                    window.Left = screen.Bounds.Left;
                    window.Top = screen.Bounds.Top;
                    window.Width = screen.Bounds.Width;
                    window.Height = screen.Bounds.Height;
                    window.Show();
                    _overlayWindows.Add(window);
                }
            });
        }

        private void BreakManager_IntermissionEnded(object sender, EventArgs e)
        {
            Dispatcher.Invoke(() =>
            {
                System.Media.SystemSounds.Asterisk.Play();

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
            foreach (System.Windows.Controls.MenuItem item in parent.Items) item.IsChecked = false;
            menuItem.IsChecked = true;

            if (int.TryParse(menuItem.Tag.ToString(), out int seconds))
            {
                _breakManager.WorkInterval = seconds;
            }
        }

        private void BreakDuration_Click(object sender, RoutedEventArgs e)
        {
            var menuItem = (System.Windows.Controls.MenuItem)sender;
            var parent = (System.Windows.Controls.MenuItem)menuItem.Parent;
            foreach (System.Windows.Controls.MenuItem item in parent.Items) item.IsChecked = false;
            menuItem.IsChecked = true;

            if (int.TryParse(menuItem.Tag.ToString(), out int seconds))
            {
                _breakManager.BreakDuration = seconds;
            }
        }

        private void CopySessionCode_Click(object sender, RoutedEventArgs e)
        {
            string code = _breakManager.GenerateSessionCode();
            System.Windows.Clipboard.SetText(code);
        }

        private void JoinSession_Click(object sender, RoutedEventArgs e)
        {
            var dialog = new System.Windows.Window
            {
                Title = "Join Collaborative Session",
                Width = 350,
                Height = 150,
                WindowStartupLocation = WindowStartupLocation.CenterScreen,
                ResizeMode = ResizeMode.NoResize
            };

            var stackPanel = new System.Windows.Controls.StackPanel { Margin = new Thickness(15) };
            var textBox = new System.Windows.Controls.TextBox { Margin = new Thickness(0, 10, 0, 10) };
            var button = new System.Windows.Controls.Button { Content = "Join", Width = 80, HorizontalAlignment = System.Windows.HorizontalAlignment.Right, Padding = new Thickness(5) };

            button.Click += (s, args) =>
            {
                string code = textBox.Text.Trim();
                if (!string.IsNullOrWhiteSpace(code))
                {
                    _breakManager.JoinSession(code);
                }
                dialog.Close();
            };

            stackPanel.Children.Add(new System.Windows.Controls.TextBlock { Text = "Paste the session code below:" });
            stackPanel.Children.Add(textBox);
            stackPanel.Children.Add(button);

            dialog.Content = stackPanel;
            dialog.ShowDialog();
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
                    _taskbarIcon.TrayBalloonTipClicked -= OnTrayBalloonTipClicked;
                    await UpdateService.Shared.DownloadAndApplyUpdateAsync(info);
                }
            });
        }

        private void Quit_Click(object sender, RoutedEventArgs e)
        {
            _taskbarIcon?.Dispose();
            Current.Shutdown();
        }
    }
}
