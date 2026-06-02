#nullable disable

using System;
using System.Drawing;
using System.Windows;
using System.Windows.Controls;
using Hardcodet.Wpf.TaskbarNotification;
using System.Collections.Generic;

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

            UpdateStatusMenu();
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
            _breakManager.TriggerBreak();
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

        private void Quit_Click(object sender, RoutedEventArgs e)
        {
            _taskbarIcon?.Dispose();
            Current.Shutdown();
        }
    }
}
