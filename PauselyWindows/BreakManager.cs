using System;
using System.Collections.Generic;
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

        public bool IsSyncedSession { get; private set; } = false;
        public bool IsInIntermission { get; private set; } = false;
        public int IntermissionTimeRemaining { get; private set; } = 0;
        private double _anchorTimestamp = 0;
        private HashSet<int> _skippedCycleIndices = new HashSet<int>();
        private bool _isApplyingSync = false;
        private DateTime? _snoozeEndTime = null;
        private DateTime _lastBreakDisplayedTime = DateTime.Now;

        private double _previousWorkInterval = 1200;
        private double _previousBreakDuration = 20;

        private double GetCurrentUnixTime() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;

        private double _workInterval = 1200; // 20 minutes
        public double WorkInterval
        {
            get => _workInterval;
            set
            {
                _workInterval = value;
                if (!_isApplyingSync) IsSyncedSession = false;
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
                if (!_isApplyingSync) IsSyncedSession = false;
                if (Status == BreakStatus.InBreak)
                {
                    TimeRemaining = (int)_breakDuration;
                    OnPropertyChanged();
                }
            }
        }

        private DispatcherTimer? _timer;
        private bool _isEnding = false;

        public event EventHandler? StatusChanged;
        public event EventHandler? TimerTicked;
        public event EventHandler? BreakTriggered;
        public event EventHandler? BreakEnding;
        public event EventHandler? BreakEnded;
        public event EventHandler? IntermissionTriggered;
        public event EventHandler? IntermissionEnded;

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

        public void StopTimer()
        {
            _timer?.Stop();
        }

        private void Tick()
        {
            // Handle intermission countdown independently
            if (IsInIntermission)
            {
                if (IntermissionTimeRemaining > 0)
                {
                    IntermissionTimeRemaining -= 1;
                    TimerTicked?.Invoke(this, EventArgs.Empty);
                }
                else
                {
                    EndIntermission();
                }
            }

            if (_isEnding) return;

            if (IsSyncedSession)
            {
                double cycleDuration = WorkInterval + BreakDuration;
                double elapsed = Math.Max(0, GetCurrentUnixTime() - _anchorTimestamp);
                int currentCycleIndex = (int)(elapsed / cycleDuration);
                double cyclePosition = elapsed % cycleDuration;

                BreakStatus newStatus = BreakStatus.Working;
                double newTimeRemaining = 0;

                if (cyclePosition < WorkInterval)
                {
                    newStatus = BreakStatus.Working;
                    newTimeRemaining = WorkInterval - cyclePosition;
                }
                else
                {
                    if (_skippedCycleIndices.Contains(currentCycleIndex))
                    {
                        newStatus = BreakStatus.Working;
                        newTimeRemaining = (cycleDuration - cyclePosition) + WorkInterval;
                    }
                    else
                    {
                        newStatus = BreakStatus.InBreak;
                        newTimeRemaining = cycleDuration - cyclePosition;
                    }
                }

                if (_snoozeEndTime.HasValue)
                {
                    if (DateTime.Now < _snoozeEndTime.Value)
                    {
                        newStatus = BreakStatus.Working;
                        newTimeRemaining = (_snoozeEndTime.Value - DateTime.Now).TotalSeconds;
                    }
                    else
                    {
                        _snoozeEndTime = null;
                        if (newStatus == BreakStatus.InBreak)
                        {
                            _skippedCycleIndices.Add(currentCycleIndex);
                            newStatus = BreakStatus.Working;
                            newTimeRemaining = (cycleDuration - cyclePosition) + WorkInterval;
                        }
                    }
                }

                BreakStatus oldStatus = Status;
                Status = newStatus;
                TimeRemaining = (int)Math.Ceiling(newTimeRemaining);

                if (oldStatus == BreakStatus.Working && newStatus == BreakStatus.InBreak)
                {
                    TriggerBreak();
                }
                else if (oldStatus == BreakStatus.InBreak && newStatus == BreakStatus.Working)
                {
                    EndBreak();
                }
                else
                {
                    OnPropertyChanged();
                }
            }
            else
            {
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
        }

        public void TriggerBreak()
        {
            if (_isEnding) return;
            Status = BreakStatus.InBreak;
            _lastBreakDisplayedTime = DateTime.Now;
            if (!IsSyncedSession)
            {
                TimeRemaining = (int)BreakDuration;
            }
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
                if (!IsSyncedSession)
                {
                    TimeRemaining = (int)WorkInterval;
                }
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

                int snoozeDuration = WorkInterval <= TEST_MODE_THRESHOLD ? TEST_MODE_SNOOZE_DURATION : STANDARD_SNOOZE_DURATION;

                if (IsSyncedSession)
                {
                    _snoozeEndTime = DateTime.Now.AddSeconds(snoozeDuration);
                }
                else
                {
                    TimeRemaining = snoozeDuration;
                }

                OnPropertyChanged();
                BreakEnded?.Invoke(this, EventArgs.Empty);
            };
            endTimer.Start();
        }

        public void SkipBreak()
        {
            if (IsSyncedSession)
            {
                double cycleDuration = WorkInterval + BreakDuration;
                double elapsed = Math.Max(0, GetCurrentUnixTime() - _anchorTimestamp);
                int currentCycleIndex = (int)(elapsed / cycleDuration);
                _skippedCycleIndices.Add(currentCycleIndex);
            }
            EndBreak();
        }

        public void StartIntermission()
        {
            if (IsInIntermission) return;
            IsInIntermission = true;
            IntermissionTimeRemaining = (int)BreakDuration;
            OnPropertyChanged();
            IntermissionTriggered?.Invoke(this, EventArgs.Empty);
        }

        public void EndIntermission()
        {
            IsInIntermission = false;
            IntermissionTimeRemaining = 0;

            BreakEnding?.Invoke(this, EventArgs.Empty);

            var endTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(REVERSE_ANIMATION_DURATION_SECONDS) };
            endTimer.Tick += (s, e) =>
            {
                endTimer.Stop();
                OnPropertyChanged();
                IntermissionEnded?.Invoke(this, EventArgs.Empty);
            };
            endTimer.Start();
        }

        public string GenerateSessionCode()
        {
            if (!IsSyncedSession)
            {
                if (Status == BreakStatus.Working)
                {
                    double elapsed = WorkInterval - TimeRemaining;
                    _anchorTimestamp = GetCurrentUnixTime() - elapsed;
                }
                else
                {
                    double elapsed = (WorkInterval + BreakDuration) - TimeRemaining;
                    _anchorTimestamp = GetCurrentUnixTime() - elapsed;
                }
                IsSyncedSession = true;
            }
            
            string payload = $"{(int)WorkInterval}:{(int)BreakDuration}:{(long)_anchorTimestamp}";
            var plainTextBytes = System.Text.Encoding.UTF8.GetBytes(payload);
            return Convert.ToBase64String(plainTextBytes);
        }

        public void JoinSession(string code)
        {
            try
            {
                var base64EncodedBytes = Convert.FromBase64String(code);
                var payload = System.Text.Encoding.UTF8.GetString(base64EncodedBytes);
                var parts = payload.Split(':');
                if (parts.Length == 3)
                {
                    if (!IsSyncedSession)
                    {
                        _previousWorkInterval = WorkInterval;
                        _previousBreakDuration = BreakDuration;
                    }

                    _isApplyingSync = true;
                    WorkInterval = double.Parse(parts[0], System.Globalization.CultureInfo.InvariantCulture);
                    BreakDuration = double.Parse(parts[1], System.Globalization.CultureInfo.InvariantCulture);
                    _isApplyingSync = false;

                    _anchorTimestamp = double.Parse(parts[2], System.Globalization.CultureInfo.InvariantCulture);
                    IsSyncedSession = true;
                    _skippedCycleIndices.Clear();
                    _snoozeEndTime = null;
                    SnoozesLeft = 4;

                    // If they were in break locally but the code puts them in work, ensure overlays close
                    if (Status == BreakStatus.InBreak)
                    {
                        BreakEnded?.Invoke(this, EventArgs.Empty);
                    }
                }
            }
            catch
            {
                // Invalid code
            }
        }

        public void LeaveSession()
        {
            if (!IsSyncedSession) return;
            IsSyncedSession = false;

            _isApplyingSync = true;
            WorkInterval = _previousWorkInterval;
            BreakDuration = _previousBreakDuration;
            _isApplyingSync = false;

            // Re-anchor based on the last break that was displayed to the user
            double elapsed = (DateTime.Now - _lastBreakDisplayedTime).TotalSeconds;
            if (elapsed >= _previousWorkInterval)
            {
                // Overdue for a break — trigger immediately
                TimeRemaining = 0;
            }
            else
            {
                TimeRemaining = (int)(_previousWorkInterval - elapsed);
            }
            Status = BreakStatus.Working;

            // Clean up sync state
            _skippedCycleIndices.Clear();
            _snoozeEndTime = null;
            SnoozesLeft = 4;

            OnPropertyChanged();
        }

        private void OnPropertyChanged()
        {
            StatusChanged?.Invoke(this, EventArgs.Empty);
            TimerTicked?.Invoke(this, EventArgs.Empty);
        }
    }
}
