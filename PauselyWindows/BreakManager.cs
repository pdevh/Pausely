using System;
using PauselyWindows.Services;
using System.Collections.Generic;
using System.Windows.Threading;
using Microsoft.Win32;

namespace PauselyWindows
{
    public class BreakEndedEventArgs : EventArgs
    {
        public bool IsSnoozed { get; }
        public bool PlaySound { get; }
        public BreakEndedEventArgs(bool isSnoozed, bool playSound = true)
        {
            IsSnoozed = isSnoozed;
            PlaySound = playSound;
        }
    }

    public enum BreakStatus
    {
        Working,
        InBreak,
        Paused
    }

    public class BreakManager
    {
        public static BreakManager Shared { get; } = new BreakManager();

        public BreakStatus Status { get; private set; } = BreakStatus.Working;
        public int TimeRemaining { get; private set; } = 1200; // 20 minutes
        public int SnoozesLeft { get; private set; } = 4;
        public BreakPrompt? CurrentBreakPrompt { get; private set; }
        public string? CurrentIntermissionPrompt { get; private set; }

        public bool IsSyncedSession { get; private set; } = false;
        public bool IsInIntermission { get; private set; } = false;
        public int IntermissionTimeRemaining { get; private set; } = 0;
        private double _anchorTimestamp = 0;
        private HashSet<long> _skippedCycleIndices = new HashSet<long>();
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
                if (!DurationValue.IsValid(value)) return;
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
                if (!DurationValue.IsValid(value)) return;
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
        private bool _isScreenLocked = false;
        public bool IsScreenLocked => _isScreenLocked;

        public event EventHandler? StatusChanged;
        public event EventHandler? TimerTicked;
        public event EventHandler? BreakTriggered;
        public event EventHandler? BreakEnding;
        public event EventHandler<BreakEndedEventArgs>? BreakEnded;
        public event EventHandler? IntermissionTriggered;
        public event EventHandler<BreakEndedEventArgs>? IntermissionEnded;

        private const double REVERSE_ANIMATION_DURATION_SECONDS = 1.15;
        private const double TEST_MODE_THRESHOLD = 15;
        private const int TEST_MODE_SNOOZE_DURATION = 10;
        private const int STANDARD_SNOOZE_DURATION = 300;

        private BreakManager()
        {
            TimeRemaining = (int)WorkInterval;
            StartTimer();
            SystemEvents.SessionSwitch += SessionSwitch;
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
            // Handle intermission countdown independently.
            if (IsInIntermission)
            {
                IntermissionTimeRemaining = TimerTiming.Countdown(IntermissionTimeRemaining);
                if (IntermissionTimeRemaining == 0) EndIntermission();
                TimerTicked?.Invoke(this, EventArgs.Empty);
            }

            if (_isEnding) return;

            if (IsSyncedSession)
            {
                var position = TimerTiming.At(WorkInterval, BreakDuration, _anchorTimestamp, GetCurrentUnixTime());
                long currentCycleIndex = position.Cycle;
                BreakStatus newStatus = position.IsBreak ? BreakStatus.InBreak : BreakStatus.Working;
                double newTimeRemaining = position.Remaining;
                if (position.IsBreak && _skippedCycleIndices.Contains(currentCycleIndex))
                {
                    newStatus = BreakStatus.Working;
                    newTimeRemaining += WorkInterval;
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
                            newTimeRemaining = position.Remaining + WorkInterval;
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
                TimeRemaining = TimerTiming.Countdown(TimeRemaining);
                if (TimeRemaining == 0)
                {
                    if (Status == BreakStatus.Paused) ResumeBreaks();
                    else if (Status == BreakStatus.Working) TriggerBreak();
                    else EndBreak();
                }
                TimerTicked?.Invoke(this, EventArgs.Empty);
            }
        }

        public void TriggerBreak()
        {
            if (_isEnding) return;
            Logger.Info("Triggering break.");
            Status = BreakStatus.InBreak;
            _lastBreakDisplayedTime = DateTime.Now;
            CurrentBreakPrompt = BreakDuration >= 60
                ? BreakPrompts.RandomBreak()
                : new BreakPrompt("Take a breather", BreakPrompts.RandomMicrobreak());
            if (!IsSyncedSession)
            {
                TimeRemaining = (int)BreakDuration;
            }
            OnPropertyChanged();
            BreakTriggered?.Invoke(this, EventArgs.Empty);
        }

        public void EndBreak(bool wasPremature = false)
        {
            if (_isEnding) return;
            Logger.Info("Ending break.");
            _isEnding = true;

            BreakEnding?.Invoke(this, EventArgs.Empty);

            var endTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(IsSyncedSession ? Math.Min(REVERSE_ANIMATION_DURATION_SECONDS, WorkInterval / 2) : REVERSE_ANIMATION_DURATION_SECONDS) };
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
                BreakEnded?.Invoke(this, new BreakEndedEventArgs(isSnoozed: false, playSound: !wasPremature));
            };
            endTimer.Start();
        }

        public void SnoozeBreak()
        {
            if (SnoozesLeft <= 0 || _isEnding) return;
            Logger.Info($"Snoozing break. Snoozes remaining: {SnoozesLeft - 1}");
            SnoozesLeft -= 1;
            _isEnding = true;

            BreakEnding?.Invoke(this, EventArgs.Empty);

            var endTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(IsSyncedSession ? Math.Min(REVERSE_ANIMATION_DURATION_SECONDS, WorkInterval / 2) : REVERSE_ANIMATION_DURATION_SECONDS) };
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
                BreakEnded?.Invoke(this, new BreakEndedEventArgs(isSnoozed: true, playSound: false));
            };
            endTimer.Start();
        }

        public void SkipBreak()
        {
            Logger.Info("Skipping break.");
            if (IsSyncedSession)
            {
                double cycleDuration = WorkInterval + BreakDuration;
                double elapsed = Math.Max(0, GetCurrentUnixTime() - _anchorTimestamp);
                long currentCycleIndex = (long)(elapsed / cycleDuration);
                _skippedCycleIndices.Add(currentCycleIndex);
            }
            EndBreak(wasPremature: true);
        }

        public double SuggestedPauseDuration
        {
            get
            {
                double raw = 2 * (WorkInterval + BreakDuration);
                const double fifteenMinutes = 900;
                double rounded = Math.Round(raw / fifteenMinutes) * fifteenMinutes;
                return rounded > 0 ? rounded : raw;
            }
        }

        public void PauseBreaks()
        {
            if (IsSyncedSession || Status != BreakStatus.Working) return;
            Status = BreakStatus.Paused;
            TimeRemaining = (int)SuggestedPauseDuration;
            OnPropertyChanged();
        }

        public void ResumeBreaks()
        {
            if (Status != BreakStatus.Paused) return;
            Status = BreakStatus.Working;
            TimeRemaining = (int)WorkInterval;
            OnPropertyChanged();
        }

        public void StartIntermission()
        {
            if (IsInIntermission) return;
            Logger.Info("Starting intermission.");
            IsInIntermission = true;
            IntermissionTimeRemaining = (int)BreakDuration;
            CurrentIntermissionPrompt = BreakPrompts.RandomMicrobreak();
            OnPropertyChanged();
            IntermissionTriggered?.Invoke(this, EventArgs.Empty);
        }

        public void EndIntermission(bool wasPremature = false)
        {
            Logger.Info("Ending intermission.");
            IsInIntermission = false;
            IntermissionTimeRemaining = 0;

            BreakEnding?.Invoke(this, EventArgs.Empty);

            var endTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(IsSyncedSession ? Math.Min(REVERSE_ANIMATION_DURATION_SECONDS, WorkInterval / 2) : REVERSE_ANIMATION_DURATION_SECONDS) };
            endTimer.Tick += (s, e) =>
            {
                endTimer.Stop();
                OnPropertyChanged();
                IntermissionEnded?.Invoke(this, new BreakEndedEventArgs(isSnoozed: false, playSound: !wasPremature));
            };
            endTimer.Start();
        }

        public string GenerateSessionCode()
        {
            if (!IsSyncedSession)
            {
                _previousWorkInterval = WorkInterval;
                _previousBreakDuration = BreakDuration;
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
                _anchorTimestamp = Math.Floor(_anchorTimestamp);
                IsSyncedSession = true;
            }
            
            return SessionCode.Encode((int)WorkInterval, (int)BreakDuration, _anchorTimestamp);
        }

        public bool JoinSession(string code)
        {
            var schedule = SessionCode.Decode(code, GetCurrentUnixTime());
            if (schedule == null) return false;

            if (!IsSyncedSession)
            {
                _previousWorkInterval = WorkInterval;
                _previousBreakDuration = BreakDuration;
            }

            _isApplyingSync = true;
            WorkInterval = schedule.Work;
            BreakDuration = schedule.Rest;
            _isApplyingSync = false;

            _anchorTimestamp = schedule.Anchor;
            IsSyncedSession = true;
            _skippedCycleIndices.Clear();
            _snoozeEndTime = null;
            SnoozesLeft = 4;

            Logger.Info("Successfully joined sync session.");

            if (Status == BreakStatus.InBreak)
            {
                BreakEnded?.Invoke(this, new BreakEndedEventArgs(isSnoozed: false, playSound: false));
            }
            Status = BreakStatus.Working;
            if (!_isScreenLocked) Tick();
            OnPropertyChanged();
            return true;
        }

        public void LeaveSession()
        {
            if (!IsSyncedSession) return;
            Logger.Info("Leaving sync session and restoring previous intervals.");
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

            Logger.Info($"Restored intervals. WorkInterval: {WorkInterval}, BreakDuration: {BreakDuration}, TimeRemaining: {TimeRemaining}");

            OnPropertyChanged();
        }

        private void OnPropertyChanged()
        {
            StatusChanged?.Invoke(this, EventArgs.Empty);
            TimerTicked?.Invoke(this, EventArgs.Empty);
        }

        private void SessionSwitch(object sender, SessionSwitchEventArgs e)
        {
            Logger.Info($"SessionSwitch event triggered: {e.Reason}");
            System.Windows.Application.Current?.Dispatcher.Invoke(() =>
            {
                if (e.Reason == SessionSwitchReason.SessionLock)
                {
                    Logger.Info("Session locked. Pausing timer and discarding active breaks/intermissions.");
                    _isScreenLocked = true;
                    _timer?.Stop();
                    OnPropertyChanged();

                    if (Status == BreakStatus.InBreak)
                    {
                        _isEnding = false;
                        Status = BreakStatus.Working;
                        if (!IsSyncedSession)
                        {
                            TimeRemaining = (int)WorkInterval;
                        }
                        SnoozesLeft = 4;
                        OnPropertyChanged();
                        BreakEnded?.Invoke(this, new BreakEndedEventArgs(isSnoozed: false, playSound: false));
                    }
                    if (Status == BreakStatus.Paused)
                    {
                        Status = BreakStatus.Working;
                        TimeRemaining = (int)WorkInterval;
                        OnPropertyChanged();
                    }
                    if (IsInIntermission)
                    {
                        IsInIntermission = false;
                        IntermissionTimeRemaining = 0;
                        OnPropertyChanged();
                        IntermissionEnded?.Invoke(this, new BreakEndedEventArgs(isSnoozed: false, playSound: false));
                    }
                }
                else if (e.Reason == SessionSwitchReason.SessionUnlock)
                {
                    Logger.Info("Session unlocked. Resuming timer.");
                    if (_isScreenLocked)
                    {
                        _isScreenLocked = false;
                        _timer?.Start();
                    }
                }
            });
        }
    }
}
