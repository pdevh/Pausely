using System;
using System.Windows.Threading;

namespace PauselyWindows
{
    public enum BreakStatus
    {
        Working,
        InBreak
    }

    public class BreakManager
    {
        public static BreakManager Shared { get; } = new BreakManager();

        public BreakStatus Status { get; private set; } = BreakStatus.Working;
        public int TimeRemaining { get; private set; } = 1200; // 20 minutes
        public int SnoozesLeft { get; private set; } = 4;

        private double _workInterval = 1200; // 20 minutes
        public double WorkInterval
        {
            get => _workInterval;
            set
            {
                _workInterval = value;
                if (Status == BreakStatus.Working)
                {
                    TimeRemaining = (int)_workInterval;
                    OnPropertyChanged();
                }
            }
        }

        private double _breakDuration = 20; // 20 seconds
        public double BreakDuration
        {
            get => _breakDuration;
            set
            {
                _breakDuration = value;
                if (Status == BreakStatus.InBreak)
                {
                    TimeRemaining = (int)_breakDuration;
                    OnPropertyChanged();
                }
            }
        }

        private DispatcherTimer _timer;
        private bool _isEnding = false;

        public event EventHandler StatusChanged;
        public event EventHandler TimerTicked;
        public event EventHandler BreakTriggered;
        public event EventHandler BreakEnding;
        public event EventHandler BreakEnded;

        private const double REVERSE_ANIMATION_DURATION_SECONDS = 1.15;
        private const double TEST_MODE_THRESHOLD = 15;
        private const int TEST_MODE_SNOOZE_DURATION = 10;
        private const int STANDARD_SNOOZE_DURATION = 300;

        private BreakManager()
        {
            TimeRemaining = (int)WorkInterval;
            StartTimer();
        }

        public void StartTimer()
        {
            _timer?.Stop();
            _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            _timer.Tick += (s, e) => Tick();
            _timer.Start();
        }

        private void Tick()
        {
            if (_isEnding) return;
            if (TimeRemaining > 0)
            {
                TimeRemaining -= 1;
                TimerTicked?.Invoke(this, EventArgs.Empty);
            }
            else
            {
                if (Status == BreakStatus.Working)
                {
                    TriggerBreak();
                }
                else
                {
                    EndBreak();
                }
            }
        }

        public void TriggerBreak()
        {
            Status = BreakStatus.InBreak;
            TimeRemaining = (int)BreakDuration;
            OnPropertyChanged();
            BreakTriggered?.Invoke(this, EventArgs.Empty);
        }

        public void EndBreak()
        {
            if (_isEnding) return;
            _isEnding = true;

            BreakEnding?.Invoke(this, EventArgs.Empty);

            var endTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(REVERSE_ANIMATION_DURATION_SECONDS) };
            endTimer.Tick += (s, e) =>
            {
                endTimer.Stop();
                _isEnding = false;
                Status = BreakStatus.Working;
                TimeRemaining = (int)WorkInterval;
                SnoozesLeft = 4;
                OnPropertyChanged();
                BreakEnded?.Invoke(this, EventArgs.Empty);
            };
            endTimer.Start();
        }

        public void SnoozeBreak()
        {
            if (SnoozesLeft <= 0 || _isEnding) return;
            SnoozesLeft -= 1;
            _isEnding = true;

            BreakEnding?.Invoke(this, EventArgs.Empty);

            var endTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(REVERSE_ANIMATION_DURATION_SECONDS) };
            endTimer.Tick += (s, e) =>
            {
                endTimer.Stop();
                _isEnding = false;
                Status = BreakStatus.Working;

                if (WorkInterval <= TEST_MODE_THRESHOLD)
                {
                    TimeRemaining = TEST_MODE_SNOOZE_DURATION;
                }
                else
                {
                    TimeRemaining = STANDARD_SNOOZE_DURATION;
                }

                OnPropertyChanged();
                BreakEnded?.Invoke(this, EventArgs.Empty);
            };
            endTimer.Start();
        }

        public void SkipBreak()
        {
            EndBreak();
        }

        private void OnPropertyChanged()
        {
            StatusChanged?.Invoke(this, EventArgs.Empty);
            TimerTicked?.Invoke(this, EventArgs.Empty);
        }
    }
}
