namespace PauselyWindows.Services;

internal static class TimerTiming
{
    // Transition on the tick that reaches zero, not one tick later.
    internal static int Countdown(int remaining) => Math.Max(0, remaining - 1);

    internal readonly record struct Position(long Cycle, bool IsBreak, int Remaining);

    internal static Position At(double work, double rest, double anchor, double now)
    {
        double duration = work + rest;
        double elapsed = Math.Max(0, now - anchor);
        double position = elapsed % duration;
        return new((long)(elapsed / duration), position >= work,
            (int)Math.Ceiling(position < work ? work - position : duration - position));
    }
}
