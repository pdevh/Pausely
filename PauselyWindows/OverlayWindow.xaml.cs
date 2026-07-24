using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using PauselyWindows.Services;

namespace PauselyWindows
{
    public partial class OverlayWindow : Window
    {
        private BreakManager _breakManager;
        private bool _isIntermission;
        private DispatcherTimer? _clockTimer;
        private DateTime? _lastEscapePressTime;

        [DllImport("user32.dll")]
        public static extern bool LockWorkStation();

        // ── Animation timing constants (matching macOS spec) ──
        private static readonly TimeSpan Phase0Duration = TimeSpan.FromSeconds(0.50);
        private static readonly TimeSpan Phase1Duration = TimeSpan.FromSeconds(0.70);
        private static readonly TimeSpan Phase2Duration = TimeSpan.FromSeconds(0.50);
        private static readonly TimeSpan Phase3Duration = TimeSpan.FromSeconds(0.50);
        private static readonly TimeSpan Phase4Duration = TimeSpan.FromSeconds(0.40);

        private static readonly TimeSpan Phase0Delay = TimeSpan.Zero;
        private static readonly TimeSpan Phase1Delay = TimeSpan.FromSeconds(0.54);
        private static readonly TimeSpan Phase2Delay = TimeSpan.FromSeconds(1.24);
        private static readonly TimeSpan Phase3Delay = TimeSpan.FromSeconds(1.24);
        private static readonly TimeSpan Phase4Delay = TimeSpan.FromSeconds(1.84);

        private static readonly IEasingFunction EaseOut = new QuadraticEase { EasingMode = EasingMode.EaseOut };

        public OverlayWindow(bool isIntermission = false)
        {
            InitializeComponent();
            Logger.Info($"OverlayWindow initializing (IsIntermission = {isIntermission}).");

            _breakManager = BreakManager.Shared;
            _isIntermission = isIntermission;
            _breakManager.TimerTicked += BreakManager_TimerTicked;
            _breakManager.BreakEnding += BreakManager_BreakEnding;

            // Load wallpaper images
            var wallpaperService = WallpaperCaptureService.Shared;
            if (wallpaperService.CrispWallpaper != null)
            {
                CrispWallpaperImage.Source = wallpaperService.CrispWallpaper;
                BlurredWallpaperImage.Source = wallpaperService.BlurredWallpaper;
            }

            UpdateTimerText();
            UpdateSnoozeCount();
            SetupIntermissionUI();
            SetupPromptUI();
            SetupClockTimer();
        }

        private void Window_Loaded(object sender, RoutedEventArgs e)
        {
            Logger.Info("OverlayWindow loaded. Beginning staggered entrance animation.");
            PlayForwardAnimation();
        }

        // ═══════════════════════════════════════════════════════════
        // Forward Animation — staggered 5-phase entrance
        // ═══════════════════════════════════════════════════════════

        private void PlayForwardAnimation()
        {
            bool hasWallpaper = CrispWallpaperImage.Source != null;

            // Phase 0: Background wallpaper (or black fallback) fades in
            if (hasWallpaper)
            {
                AnimateOpacity(CrispWallpaperImage, 0, 1, Phase0Duration, Phase0Delay);
                AnimateOpacity(BlurredWallpaperImage, 0, 1, Phase0Duration, Phase0Delay);
            }
            else
            {
                AnimateOpacity(BlackFallback, 0, 1, Phase0Duration, Phase0Delay);
            }
            // Dim overlay for text readability (subtle)
            AnimateOpacity(DimOverlay, 0, 0.25, Phase0Duration, Phase0Delay);

            // Phase 1: Title slides down + fades in
            AnimateOpacity(TitleText, 0, 1, Phase1Duration, Phase1Delay);
            AnimateTranslateY(TitleTranslate, -30, 0, Phase1Duration, Phase1Delay);

            // Phase 2: Subtitle fades in + slides up slightly
            AnimateOpacity(SubtitleText, 0, 1, Phase2Duration, Phase2Delay);
            AnimateTranslateY(SubtitleTranslate, 12, 0, Phase2Duration, Phase2Delay);

            // Phase 3: Divider, timer, controls fade in + slide up
            AnimateOpacity(Divider, 0, 1, Phase3Duration, Phase3Delay);
            AnimateOpacity(TimerContainer, 0, 1, Phase3Duration, Phase3Delay);
            AnimateTranslateY(TimerTranslate, 16, 0, Phase3Duration, Phase3Delay);
            AnimateOpacity(ControlsPanel, 0, 1, Phase3Duration, Phase3Delay);
            AnimateTranslateY(ControlsTranslate, 12, 0, Phase3Duration, Phase3Delay);

            // Phase 4: Clock slides down from above
            AnimateOpacity(ClockPanel, 0, 1, Phase4Duration, Phase4Delay);
            AnimateTranslateY(ClockTranslate, -80, 0, Phase4Duration, Phase4Delay);
        }

        // ═══════════════════════════════════════════════════════════
        // Reverse Animation — all elements animate out simultaneously
        // ═══════════════════════════════════════════════════════════

        private void PlayReverseAnimation()
        {
            bool hasWallpaper = CrispWallpaperImage.Source != null;

            // Background
            if (hasWallpaper)
            {
                AnimateOpacity(CrispWallpaperImage, 1, 0, Phase0Duration, TimeSpan.Zero);
                AnimateOpacity(BlurredWallpaperImage, 1, 0, Phase0Duration, TimeSpan.Zero);
            }
            else
            {
                AnimateOpacity(BlackFallback, 1, 0, Phase0Duration, TimeSpan.Zero);
            }
            AnimateOpacity(DimOverlay, null, 0, Phase0Duration, TimeSpan.Zero);

            // Title
            AnimateOpacity(TitleText, null, 0, Phase1Duration, TimeSpan.Zero);
            AnimateTranslateY(TitleTranslate, 0, -30, Phase1Duration, TimeSpan.Zero);

            // Subtitle
            AnimateOpacity(SubtitleText, null, 0, Phase2Duration, TimeSpan.Zero);
            AnimateTranslateY(SubtitleTranslate, 0, 12, Phase2Duration, TimeSpan.Zero);

            // Divider, timer, controls
            AnimateOpacity(Divider, null, 0, Phase2Duration, TimeSpan.Zero);
            AnimateOpacity(TimerContainer, null, 0, Phase2Duration, TimeSpan.Zero);
            AnimateTranslateY(TimerTranslate, 0, 16, Phase2Duration, TimeSpan.Zero);
            AnimateOpacity(ControlsPanel, null, 0, Phase2Duration, TimeSpan.Zero);
            AnimateTranslateY(ControlsTranslate, 0, 12, Phase2Duration, TimeSpan.Zero);

            // Clock
            AnimateOpacity(ClockPanel, null, 0, Phase4Duration, TimeSpan.Zero);
            AnimateTranslateY(ClockTranslate, 0, -80, Phase4Duration, TimeSpan.Zero);
        }

        // ═══════════════════════════════════════════════════════════
        // Animation helpers
        // ═══════════════════════════════════════════════════════════

        private void AnimateOpacity(UIElement target, double? from, double to, TimeSpan duration, TimeSpan delay)
        {
            var anim = new DoubleAnimation
            {
                To = to,
                Duration = new Duration(duration),
                BeginTime = delay,
                EasingFunction = EaseOut
            };
            if (from.HasValue)
                anim.From = from.Value;
            target.BeginAnimation(UIElement.OpacityProperty, anim);
        }

        private void AnimateTranslateY(TranslateTransform target, double from, double to, TimeSpan duration, TimeSpan delay)
        {
            var anim = new DoubleAnimation
            {
                From = from,
                To = to,
                Duration = new Duration(duration),
                BeginTime = delay,
                EasingFunction = EaseOut
            };
            target.BeginAnimation(TranslateTransform.YProperty, anim);
        }

        // ═══════════════════════════════════════════════════════════
        // Timer & UI updates
        // ═══════════════════════════════════════════════════════════

        private void BreakManager_TimerTicked(object? sender, EventArgs e)
        {
            if (!this.IsLoaded) return;
            Dispatcher.Invoke(() =>
            {
                UpdateTimerText();
                UpdateSnoozeCount();
            });
        }

        private void BreakManager_BreakEnding(object? sender, EventArgs e)
        {
            if (!this.IsLoaded || !this.IsVisible) return;
            Dispatcher.Invoke(() =>
            {
                PlayReverseAnimation();
            });
        }

        private void UpdateTimerText()
        {
            if (TimerText == null) return;
            int remaining = _isIntermission ? _breakManager.IntermissionTimeRemaining : _breakManager.TimeRemaining;
            TimerText.Text = $"{remaining / 60:D2}:{remaining % 60:D2}";
        }

        private void UpdateSnoozeCount()
        {
            if (SnoozeCountText == null) return;
            if (_isIntermission) return; // Intermission doesn't show snooze count
            SnoozeCountText.Text = $"{_breakManager.SnoozesLeft} snoozes available";
            SnoozeButton.IsEnabled = _breakManager.SnoozesLeft > 0;
        }

        // ═══════════════════════════════════════════════════════════
        // Current time clock
        // ═══════════════════════════════════════════════════════════

        private void SetupClockTimer()
        {
            UpdateCurrentTime();
            _clockTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            _clockTimer.Tick += (s, e) => UpdateCurrentTime();
            _clockTimer.Start();
        }

        private void UpdateCurrentTime()
        {
            if (CurrentTimeText == null) return;
            CurrentTimeText.Text = DateTime.Now.ToString("HH:mm");
        }

        // ═══════════════════════════════════════════════════════════
        // Intermission mode setup
        // ═══════════════════════════════════════════════════════════

        private void SetupIntermissionUI()
        {
            if (_isIntermission)
            {
                TitleText.Text = "Voluntary break";
                SubtitleText.Text = "Take a moment to rest your eyes";

                // Replace Snooze with End Early
                SnoozeButton.Click -= Snooze_Click;
                SnoozeButton.Click += EndEarly_Click;
                // Update button content
                var sp = new System.Windows.Controls.StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
                var icon = new System.Windows.Controls.TextBlock { Text = "✕", FontSize = 14, Margin = new Thickness(0, 0, 6, 0) };
                var label = new System.Windows.Controls.TextBlock { Text = "End Early" };
                sp.Children.Add(icon);
                sp.Children.Add(label);
                SnoozeButton.Content = sp;

                // Update hint and hide snooze count
                SnoozeCountText.Visibility = Visibility.Collapsed;
                EscHintText.Text = "Press Esc twice to end early";
            }
        }

        private void SetupPromptUI()
        {
            if (_isIntermission)
            {
                SubtitleText.Text = _breakManager.CurrentIntermissionPrompt ?? "Take a moment to rest your eyes";
                return;
            }

            if (_breakManager.CurrentBreakPrompt is BreakPrompt prompt)
            {
                TitleText.Text = prompt.Title;
                SubtitleText.Text = prompt.Message;
            }
        }

        // ═══════════════════════════════════════════════════════════
        // Button handlers
        // ═══════════════════════════════════════════════════════════

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

        // ═══════════════════════════════════════════════════════════
        // Escape key double-press handling
        // ═══════════════════════════════════════════════════════════

        private void Window_PreviewKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
        {
            if (e.Key == Key.Escape)
            {
                var now = DateTime.Now;
                if (_lastEscapePressTime.HasValue && (now - _lastEscapePressTime.Value).TotalSeconds < 0.5)
                {
                    // Double press!
                    if (_isIntermission)
                    {
                        _breakManager.EndIntermission(wasPremature: true);
                    }
                    else
                    {
                        _breakManager.SnoozeBreak();
                    }
                    _lastEscapePressTime = null;
                }
                else
                {
                    _lastEscapePressTime = now;
                }
                e.Handled = true; // Swallow
            }
        }

        // ═══════════════════════════════════════════════════════════
        // Cleanup
        // ═══════════════════════════════════════════════════════════

        protected override void OnClosed(EventArgs e)
        {
            Logger.Info("OverlayWindow closed. Cleaning up event listeners.");
            _clockTimer?.Stop();
            if (_breakManager != null)
            {
                _breakManager.TimerTicked -= BreakManager_TimerTicked;
                _breakManager.BreakEnding -= BreakManager_BreakEnding;
            }
            base.OnClosed(e);
        }
    }
}
