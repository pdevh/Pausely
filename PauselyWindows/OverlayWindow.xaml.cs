using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;

namespace PauselyWindows
{
    public partial class OverlayWindow : Wpf.Ui.Controls.FluentWindow
    {
        private BreakManager _breakManager;
        private bool _isIntermission;

        [DllImport("user32.dll")]
        public static extern bool LockWorkStation();

        public OverlayWindow(bool isIntermission = false)
        {
            InitializeComponent();
            Logger.Info($"OverlayWindow initializing (IsIntermission = {isIntermission}).");
            try
            {
                Wpf.Ui.Appearance.SystemThemeWatcher.Watch(this, Wpf.Ui.Controls.WindowBackdropType.Acrylic);
            }
            catch (Exception ex)
            {
                Logger.Warn($"Failed to setup system theme watcher acrylic backdrop. Exception: {ex.Message}");
            }
            
            _breakManager = BreakManager.Shared;
            _isIntermission = isIntermission;
            _breakManager.TimerTicked += BreakManager_TimerTicked;
            _breakManager.BreakEnding += BreakManager_BreakEnding;
            UpdateTimerText();
            SetupIntermissionUI();
        }



        private void Window_Loaded(object sender, RoutedEventArgs e)
        {
            Logger.Info("OverlayWindow loaded. Beginning fade-in animation.");
            // Fade in animation
            var animation = new DoubleAnimation
            {
                From = 0.0,
                To = 1.0,
                Duration = TimeSpan.FromSeconds(0.5)
            };
            this.BeginAnimation(Window.OpacityProperty, animation);
        }

        private void BreakManager_TimerTicked(object? sender, EventArgs e)
        {
            UpdateTimerText();
        }

        private void BreakManager_BreakEnding(object? sender, EventArgs e)
        {
            if (!this.IsLoaded || !this.IsVisible) return;
            Dispatcher.Invoke(() =>
            {
                // Fade out animation
                var animation = new DoubleAnimation
                {
                    From = 1.0,
                    To = 0.0,
                    Duration = TimeSpan.FromSeconds(1.0)
                };
                this.BeginAnimation(Window.OpacityProperty, animation);
            });
        }

        private void UpdateTimerText()
        {
            if (!this.IsLoaded) return;
            Dispatcher.Invoke(() =>
            {
                if (TimerText == null) return;
                int remaining = _isIntermission ? _breakManager.IntermissionTimeRemaining : _breakManager.TimeRemaining;
                if (remaining >= 60)
                {
                    TimerText.Text = $"{remaining / 60:D2}:{remaining % 60:D2}";
                }
                else
                {
                    TimerText.Text = remaining.ToString();
                }
            });
        }

        private void SetupIntermissionUI()
        {
            if (_isIntermission)
            {
                // Change title text for voluntary break
                var titleBlock = FindName("TitleText") as System.Windows.Controls.TextBlock;
                if (titleBlock != null)
                {
                    titleBlock.Text = "Voluntary break";
                }

                // Replace Snooze button with End Early button
                var snoozeButton = FindName("SnoozeButton") as System.Windows.Controls.Button;
                if (snoozeButton != null)
                {
                    snoozeButton.Content = "End Early";
                    snoozeButton.Click -= Snooze_Click;
                    snoozeButton.Click += EndEarly_Click;
                }
            }
        }

        private void Snooze_Click(object sender, RoutedEventArgs e)
        {
            _breakManager.SnoozeBreak();
        }

        private void EndEarly_Click(object sender, RoutedEventArgs e)
        {
            _breakManager.EndIntermission(wasPremature: true);
        }

        private void LockScreen_Click(object sender, RoutedEventArgs e)
        {
            Logger.Info("LockScreen clicked inside OverlayWindow. Locking workstation.");
            LockWorkStation();
        }

        protected override void OnClosed(EventArgs e)
        {
            Logger.Info("OverlayWindow closed. Cleaning up event listeners.");
            _breakManager.TimerTicked -= BreakManager_TimerTicked;
            _breakManager.BreakEnding -= BreakManager_BreakEnding;
            base.OnClosed(e);
        }
    }
}
