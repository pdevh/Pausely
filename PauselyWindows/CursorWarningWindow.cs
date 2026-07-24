using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using DrawingPoint = System.Drawing.Point;
using WpfBrushes = System.Windows.Media.Brushes;
using WpfColor = System.Windows.Media.Color;
using WpfFontFamily = System.Windows.Media.FontFamily;
using WpfHorizontalAlignment = System.Windows.HorizontalAlignment;
using WpfOrientation = System.Windows.Controls.Orientation;
using WpfPoint = System.Windows.Point;

namespace PauselyWindows
{
    /// <summary>
    /// A non-activating, click-through countdown that follows the pointer for
    /// the final ten seconds before a break. SetWindowPos uses device pixels,
    /// so tracking remains correct across mixed-DPI monitors.
    /// </summary>
    public sealed class CursorWarningWindow : Window
    {
        private const int GWL_EXSTYLE = -20;
        private const int WS_EX_TRANSPARENT = 0x00000020;
        private const int WS_EX_NOACTIVATE = 0x08000000;
        private const uint SWP_NOSIZE = 0x0001;
        private const uint SWP_NOACTIVATE = 0x0010;
        private const uint SWP_SHOWWINDOW = 0x0040;

        private readonly TextBlock _countdownText;
        private readonly DispatcherTimer _cursorTimer;
        private DispatcherTimer? _hideTimer;
        private IntPtr _handle;

        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")]
        private static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")]
        private static extern IntPtr SetWindowLongPtr64(IntPtr hWnd, int nIndex, IntPtr value);

        [DllImport("user32.dll", EntryPoint = "GetWindowLong")]
        private static extern int GetWindowLong32(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll", EntryPoint = "SetWindowLong")]
        private static extern int SetWindowLong32(IntPtr hWnd, int nIndex, int value);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);

        public CursorWarningWindow()
        {
            Width = 220;
            Height = 80;
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = WpfBrushes.Transparent;
            Topmost = true;
            ShowInTaskbar = false;
            ShowActivated = false;
            ResizeMode = ResizeMode.NoResize;
            IsHitTestVisible = false;
            Opacity = 0;

            var brandBlue = WpfColor.FromRgb(63, 155, 255);
            var brandYellow = WpfColor.FromRgb(255, 214, 0);

            var hourglass = new TextBlock
            {
                Text = "⌛",
                FontFamily = new WpfFontFamily("Segoe UI Symbol"),
                FontSize = 16,
                Foreground = WpfBrushes.White,
                HorizontalAlignment = WpfHorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                RenderTransformOrigin = new WpfPoint(0.5, 0.5),
                RenderTransform = new RotateTransform(0)
            };
            ((RotateTransform)hourglass.RenderTransform).BeginAnimation(
                RotateTransform.AngleProperty,
                new DoubleAnimation(0, 180, TimeSpan.FromSeconds(1.5))
                {
                    AutoReverse = true,
                    RepeatBehavior = RepeatBehavior.Forever,
                    EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut }
                });

            var icon = new Border
            {
                Width = 28,
                Height = 28,
                CornerRadius = new CornerRadius(14),
                Background = new LinearGradientBrush(brandBlue, brandYellow, 35),
                Child = hourglass
            };

            _countdownText = new TextBlock
            {
                FontFamily = new WpfFontFamily("Segoe UI Variable Text, Segoe UI"),
                FontSize = 15,
                FontWeight = FontWeights.SemiBold,
                Foreground = WpfBrushes.White,
                VerticalAlignment = VerticalAlignment.Center
            };

            var content = new StackPanel { Orientation = WpfOrientation.Horizontal };
            content.Children.Add(icon);
            content.Children.Add(new Border { Width = 10 });
            content.Children.Add(_countdownText);

            var capsule = new Border
            {
                HorizontalAlignment = WpfHorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(20),
                Padding = new Thickness(12, 9, 16, 9),
                CornerRadius = new CornerRadius(24),
                Background = new SolidColorBrush(WpfColor.FromArgb(232, 20, 25, 34)),
                BorderBrush = new LinearGradientBrush(brandBlue, brandYellow, 35),
                BorderThickness = new Thickness(1),
                Child = content,
                Effect = new System.Windows.Media.Effects.DropShadowEffect
                {
                    Color = brandBlue,
                    Opacity = 0.22,
                    BlurRadius = 10,
                    ShadowDepth = 6
                }
            };
            Content = capsule;

            SourceInitialized += (_, _) =>
            {
                _handle = new WindowInteropHelper(this).Handle;
                if (IntPtr.Size == 8)
                {
                    long style = GetWindowLongPtr64(_handle, GWL_EXSTYLE).ToInt64();
                    SetWindowLongPtr64(_handle, GWL_EXSTYLE, new IntPtr(style | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE));
                }
                else
                {
                    int style = GetWindowLong32(_handle, GWL_EXSTYLE);
                    SetWindowLong32(_handle, GWL_EXSTYLE, style | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE);
                }
            };

            // Polling exists only for the ten-second warning and is more
            // dependable than mouse events when another process has focus.
            _cursorTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(16) };
            _cursorTimer.Tick += (_, _) => UpdatePosition();
            Closed += (_, _) =>
            {
                _cursorTimer.Stop();
                _hideTimer?.Stop();
            };
        }

        public void ShowCountdown(int seconds)
        {
            _countdownText.Text = $"Break in {seconds}s";
            _hideTimer?.Stop();
            _hideTimer = null;
            if (!IsVisible)
            {
                Show();
                BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(220)));
            }
            _cursorTimer.Start();
            UpdatePosition();
        }

        public void HideCountdown()
        {
            _cursorTimer.Stop();
            if (!IsVisible) return;
            BeginAnimation(OpacityProperty, new DoubleAnimation(Opacity, 0, TimeSpan.FromMilliseconds(180)));
            _hideTimer?.Stop();
            _hideTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(190) };
            _hideTimer.Tick += (_, _) =>
            {
                _hideTimer?.Stop();
                _hideTimer = null;
                Hide();
            };
            _hideTimer.Start();
        }

        private void UpdatePosition()
        {
            if (_handle == IntPtr.Zero) return;
            DrawingPoint cursor = System.Windows.Forms.Cursor.Position;
            SetWindowPos(_handle, IntPtr.Zero, cursor.X, cursor.Y, 0, 0,
                SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
        }
    }
}
