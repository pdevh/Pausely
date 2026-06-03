using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;

namespace PauselyWindows
{
    public partial class OverlayWindow : Window
    {
        private BreakManager _breakManager;
        private bool _isIntermission;

        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        private static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);

        [DllImport("user32.dll")]
        public static extern bool LockWorkStation();

        private const int SPI_GETDESKWALLPAPER = 0x0073;
        private const int MAX_PATH = 260;

        public OverlayWindow(bool isIntermission = false)
        {
            InitializeComponent();
            _breakManager = BreakManager.Shared;
            _isIntermission = isIntermission;
            _breakManager.TimerTicked += BreakManager_TimerTicked;
            _breakManager.BreakEnding += BreakManager_BreakEnding;
            UpdateTimerText();
            SetBackground();
            SetupIntermissionUI();
        }

        private void SetBackground()
        {
            try
            {
                string wallpaperPath = new string('\0', MAX_PATH);
                SystemParametersInfo(SPI_GETDESKWALLPAPER, MAX_PATH, wallpaperPath, 0);
                wallpaperPath = wallpaperPath.Substring(0, wallpaperPath.IndexOf('\0'));

                if (!string.IsNullOrEmpty(wallpaperPath))
                {
                    var bitmap = new BitmapImage(new Uri(wallpaperPath));
                    var brush = new ImageBrush(bitmap)
                    {
                        Stretch = Stretch.UniformToFill
                    };
                    
                    // Darken the wallpaper slightly
                    this.Background = brush;
                }
            }
            catch
            {
                // Fallback is defined in XAML
            }
        }

        private void Window_Loaded(object sender, RoutedEventArgs e)
        {
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
            Dispatcher.Invoke(() =>
            {
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
            _breakManager.EndIntermission();
        }

        private void LockScreen_Click(object sender, RoutedEventArgs e)
        {
            LockWorkStation();
        }

        protected override void OnClosed(EventArgs e)
        {
            _breakManager.TimerTicked -= BreakManager_TimerTicked;
            _breakManager.BreakEnding -= BreakManager_BreakEnding;
            base.OnClosed(e);
        }
    }
}
