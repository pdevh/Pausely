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

        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        private static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);

        private const int SPI_GETDESKWALLPAPER = 0x0073;
        private const int MAX_PATH = 260;

        public OverlayWindow()
        {
            InitializeComponent();
            _breakManager = BreakManager.Shared;
            _breakManager.TimerTicked += BreakManager_TimerTicked;
            _breakManager.BreakEnding += BreakManager_BreakEnding;
            UpdateTimerText();
            SetBackground();
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

        private void BreakManager_TimerTicked(object sender, EventArgs e)
        {
            UpdateTimerText();
        }

        private void BreakManager_BreakEnding(object sender, EventArgs e)
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
                int remaining = _breakManager.TimeRemaining;
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

        private void Snooze_Click(object sender, RoutedEventArgs e)
        {
            _breakManager.SnoozeBreak();
        }

        private void Skip_Click(object sender, RoutedEventArgs e)
        {
            _breakManager.SkipBreak();
        }

        protected override void OnClosed(EventArgs e)
        {
            _breakManager.TimerTicked -= BreakManager_TimerTicked;
            _breakManager.BreakEnding -= BreakManager_BreakEnding;
            base.OnClosed(e);
        }
    }
}
