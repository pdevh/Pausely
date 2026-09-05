using System.Globalization;
using System.Text;

namespace PauselyWindows.Services;

internal sealed record SessionSchedule(int Work, int Rest, double Anchor);

internal static class SessionCode
{
    internal static readonly int[] WorkPresets = [15, 600, 1200, 1800];
    internal static readonly int[] BreakPresets = [5, 15, 20, 60];
    private const string Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    private const long Window = 4_194_304;
    private const long Radix = 86_400;

    internal static string Encode(int work, int rest, double anchor)
    {
        if (!DurationValue.IsValid(work) || !DurationValue.IsValid(rest) ||
            !double.IsFinite(anchor) || anchor < 0 || anchor >= 253_402_300_800)
            throw new ArgumentOutOfRangeException(nameof(work), "Invalid session schedule.");
        long timestamp = (long)anchor % Window;
        int w = Array.IndexOf(WorkPresets, work);
        int b = Array.IndexOf(BreakPresets, rest);
        bool preset = w >= 0 && b >= 0;
        long value = preset
            ? ((long)w << 26) | ((long)b << 22) | timestamp
            : (((work - 1) * Radix + rest - 1) << 22) | timestamp;
        var result = new char[preset ? 6 : 11];
        for (int i = result.Length - 1; i >= 0; i--)
        {
            result[i] = Alphabet[(int)(value & 31)];
            value >>= 5;
        }
        return new string(result);
    }

    internal static SessionSchedule? Decode(string text, double now)
    {
        if (!double.IsFinite(now) || now < 0 || now >= 253_402_300_800) return null;
        string raw = text.Trim();
        string code = new(raw.ToUpperInvariant().Where(c => !char.IsWhiteSpace(c) && c != '-').ToArray());
        if (code.Length is 6 or 11)
        {
            long value = 0;
            foreach (char character in code)
            {
                int index = Alphabet.IndexOf(character);
                if (index < 0) return null;
                value = (value << 5) | (uint)index;
            }
            int work, rest;
            if (code.Length == 6)
            {
                int w = (int)((value >> 26) & 15);
                int b = (int)((value >> 22) & 15);
                if (w >= WorkPresets.Length || b >= BreakPresets.Length) return null;
                work = WorkPresets[w];
                rest = BreakPresets[b];
            }
            else
            {
                long settings = value >> 22;
                if (settings >= Radix * Radix) return null;
                work = (int)(settings / Radix) + 1;
                rest = (int)(settings % Radix) + 1;
            }
            long current = (long)now;
            long difference = (value & (Window - 1)) - current % Window;
            if (difference > Window / 2) difference -= Window;
            else if (difference < -Window / 2) difference += Window;
            return new(work, rest, current + difference);
        }

        try
        {
            string[] parts = Encoding.UTF8.GetString(Convert.FromBase64String(raw)).Split(':');
            if (parts.Length != 3 ||
                !double.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out double work) || !DurationValue.IsValid(work) ||
                !double.TryParse(parts[1], NumberStyles.Float, CultureInfo.InvariantCulture, out double rest) || !DurationValue.IsValid(rest) ||
                !double.TryParse(parts[2], NumberStyles.Float, CultureInfo.InvariantCulture, out double anchor) ||
                !double.IsFinite(anchor) || anchor < 0 || anchor >= 253_402_300_800) return null;
            return new((int)work, (int)rest, anchor);
        }
        catch (FormatException) { return null; }
    }
}
