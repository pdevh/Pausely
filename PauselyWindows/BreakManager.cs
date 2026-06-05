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

        private static readonly char[] Base32Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".ToCharArray();

        private string EncodeBase32(int value)
        {
            var result = new char[6];
            int temp = value;
            for (int i = 5; i >= 0; i--)
            {
                int index = temp & 0x1F;
                result[i] = Base32Alphabet[index];
                temp >>= 5;
            }
            return new string(result);
        }

        private int? DecodeBase32(string s)
        {
            if (s.Length != 6) return null;
            int result = 0;
            string upper = s.ToUpperInvariant();
            for (int i = 0; i < 6; i++)
            {
                int index = Array.IndexOf(Base32Alphabet, upper[i]);
                if (index < 0) return null;
                result = (result << 5) | index;
            }
            return result;
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
            
            double[] workIntervals = { 15, 600, 1200, 1800 };
            double[] breakDurations = { 5, 15, 20, 60 };
            
            int wIndex = Array.IndexOf(workIntervals, WorkInterval);
            if (wIndex < 0) wIndex = 2;
            int bIndex = Array.IndexOf(breakDurations, BreakDuration);
            if (bIndex < 0) bIndex = 2;
            
            int timestampModulo = (int)_anchorTimestamp % 4194304;
            int combined = (wIndex << 26) | (bIndex << 22) | timestampModulo;
            
            return EncodeBase32(combined);
        }

        public void JoinSession(string code)
        {
            string cleanCode = code.Trim();
            
            double[] workIntervals = { 15, 600, 1200, 1800 };
            double[] breakDurations = { 5, 15, 20, 60 };
            
            double w = 1200;
            double b = 20;
            double a = 0;
            
            int? combined = DecodeBase32(cleanCode);
            if (cleanCode.Length == 6 && combined.HasValue)
            {
                int modulo = combined.Value & 0x3FFFFF;
                int wIndex = (combined.Value >> 26) & 0x0F;
                int bIndex = (combined.Value >> 22) & 0x0F;
                
                w = (wIndex >= 0 && wIndex < workIntervals.Length) ? workIntervals[wIndex] : 1200;
                b = (bIndex >= 0 && bIndex < breakDurations.Length) ? breakDurations[bIndex] : 20;
                
                int current = (int)GetCurrentUnixTime();
                int window = 4194304;
                int currentModulo = current % window;
                int diff = modulo - currentModulo;
                
                if (diff > window / 2) diff -= window;
                else if (diff < -window / 2) diff += window;
                
                a = current + diff;
            }
            else
            {
                try
                {
                    var base64EncodedBytes = Convert.FromBase64String(cleanCode);
                    var payload = System.Text.Encoding.UTF8.GetString(base64EncodedBytes);
                    var parts = payload.Split(':');
                    if (parts.Length == 3)
                    {
                        w = double.Parse(parts[0], System.Globalization.CultureInfo.InvariantCulture);
                        b = double.Parse(parts[1], System.Globalization.CultureInfo.InvariantCulture);
                        a = double.Parse(parts[2], System.Globalization.CultureInfo.InvariantCulture);
                    }
                    else
                    {
                        return;
                    }
                }
                catch
                {
                    return; // Invalid code
                }
            }
            
            if (!IsSyncedSession)
            {
                _previousWorkInterval = WorkInterval;
                _previousBreakDuration = BreakDuration;
            }

            _isApplyingSync = true;
            WorkInterval = w;
            BreakDuration = b;
            _isApplyingSync = false;

            _anchorTimestamp = a;
            IsSyncedSession = true;
            _skippedCycleIndices.Clear();
            _snoozeEndTime = null;
            SnoozesLeft = 4;

            if (Status == BreakStatus.InBreak)
            {
                BreakEnded?.Invoke(this, EventArgs.Empty);
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
