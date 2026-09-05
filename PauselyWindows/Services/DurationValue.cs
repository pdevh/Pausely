using System.Globalization;

namespace PauselyWindows.Services;

internal static class DurationValue
{
    internal const int Maximum = 86_400;

    internal static bool IsValid(double seconds) =>
        double.IsFinite(seconds) && seconds >= 1 && seconds <= Maximum && Math.Truncate(seconds) == seconds;

    // Bare numbers are seconds; colon notation is m:ss or h:mm:ss.
    internal static int? Parse(string text)
    {
        string[] parts = text.Trim().Split(':');
        if (parts.Length is < 1 or > 3) return null;
        int total = 0;
        for (int i = 0; i < parts.Length; i++)
        {
            if (parts[i].Length == 0 || parts[i].Any(c => c < '0' || c > '9') ||
                !int.TryParse(parts[i], NumberStyles.None, CultureInfo.InvariantCulture, out int number) ||
                number > Maximum || (i > 0 && number >= 60)) return null;
            total = total * 60 + number;
        }
        return total is >= 1 and <= Maximum ? total : null;
    }

    internal static string Clock(int seconds) => seconds >= 3600
        ? $"{seconds / 3600}:{seconds / 60 % 60:D2}:{seconds % 60:D2}"
        : $"{seconds / 60}:{seconds % 60:D2}";

    internal static string Label(int seconds)
    {
        var parts = new List<string>();
        if (seconds >= 3600) parts.Add($"{seconds / 3600}h");
        if (seconds / 60 % 60 > 0) parts.Add($"{seconds / 60 % 60}m");
        if (seconds % 60 > 0) parts.Add($"{seconds % 60}s");
        return string.Join(" ", parts);
    }
}

// All controls derive their value from the current text, including invalid drafts.
internal sealed class DurationDraft(int seconds)
{
    internal string Text { get; set; } = seconds.ToString(CultureInfo.InvariantCulture);
    internal int? Seconds => DurationValue.Parse(Text);

    internal bool CanAdjust(int delta) => Seconds is int value && value + delta is >= 1 and <= DurationValue.Maximum;

    internal void Adjust(int delta)
    {
        if (Seconds is int value && CanAdjust(delta))
            Text = (value + delta).ToString(CultureInfo.InvariantCulture);
    }
}
