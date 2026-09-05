using System.Text;
using System.Text.Json;
using PauselyWindows.Services;

internal static class TimerTests
{
    internal static void SettingsPersistence()
    {
        string directory = Path.Combine(Path.GetTempPath(), "pausely-settings-" + Guid.NewGuid());
        string file = Path.Combine(directory, "settings.json");
        try
        {
            var settings = new PauselyWindows.Settings.AppSettings(file) { WorkInterval = 1517, BreakDuration = 37 };
            settings.Save();
            var reloaded = new PauselyWindows.Settings.AppSettings(file);
            Assert.Equal(1517.0, reloaded.WorkInterval);
            Assert.Equal(37.0, reloaded.BreakDuration);
            File.WriteAllText(file, "{\"WorkInterval\":0,\"BreakDuration\":86401}");
            var invalid = new PauselyWindows.Settings.AppSettings(file);
            Assert.Equal(1200.0, invalid.WorkInterval);
            Assert.Equal(20.0, invalid.BreakDuration);
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true); }
    }

    internal static void InputAndFormatting()
    {
        foreach (var (text, seconds) in new[] { ("37", 37), (" 37\n", 37), ("2:37", 157), ("1:02:37", 3757),
            ("00:01", 1), ("86400", 86400), ("24:00:00", 86400), ("1440:00", 86400) })
        {
            Assert.True(DurationValue.Parse(text) == seconds, text);
            Assert.True(DurationValue.Parse(DurationValue.Clock(seconds)) == seconds);
        }
        Assert.Equal("37s", DurationValue.Label(37));
        Assert.Equal("2m 37s", DurationValue.Label(157));
        Assert.Equal("1h 2m 37s", DurationValue.Label(3757));
        Assert.Equal("24:00:00", DurationValue.Clock(86400));
        foreach (string text in new[] { "", " ", "0", "-1", "+37", "1.5", "NaN", "Infinity", "1e2", "86401", "24:00:01",
            "1:60", "1:00:60", ":37", "1:", "1:2:3:4", "1 :20", "٣٧", new string('9', 100) })
            Assert.True(DurationValue.Parse(text) == null, text);
        foreach (double seconds in new[] { 0, -1, 0.5, 86401, double.NaN, double.PositiveInfinity, double.NegativeInfinity })
            Assert.False(DurationValue.IsValid(seconds));
    }

    internal static void EditorSynchronization()
    {
        var draft = new DurationDraft(20) { Text = "0:37" };
        Assert.True(draft.Seconds == 37);
        draft.Adjust(60);
        Assert.Equal("1:37", draft.Text);
        Assert.True(draft.Seconds == 97);
        draft.Adjust(-1);
        Assert.True(draft.Seconds == 96);
        draft.Text = "";
        Assert.True(draft.Seconds == null);
        Assert.False(draft.CanAdjust(1));
        draft.Adjust(60);
        Assert.Equal("", draft.Text);
        draft.Text = "1";
        draft.Adjust(-1);
        Assert.True(draft.Seconds == 1);
        draft.Text = "86400";
        draft.Adjust(1);
        Assert.True(draft.Seconds == 86400);
    }

    internal static void EditableClockAndHours()
    {
        var draft = new DurationDraft(3757);
        Assert.Equal("1:02:37", draft.Text);
        draft.Text = "3599";
        draft.Normalize();
        Assert.Equal("59:59", draft.Text);
        draft.Adjust(1);
        Assert.Equal("1:00:00", draft.Text);
        draft.Adjust(3600);
        Assert.Equal("2:00:00", draft.Text);
        draft.Adjust(-3600);
        Assert.True(draft.Seconds == 3600);
        draft.Text = "1:60";
        draft.Normalize();
        Assert.Equal("1:60", draft.Text);
        Assert.False(draft.CanAdjust(3600));
        draft.Text = "24:00:00";
        Assert.False(draft.CanAdjust(1));
        Assert.False(draft.CanAdjust(60));
        Assert.False(draft.CanAdjust(3600));
        draft.Adjust(-1);
        Assert.Equal("23:59:59", draft.Text);
    }

    internal static void CycleBoundaries()
    {
        int remaining = 37;
        for (int i = 0; i < 36; i++) remaining = TimerTiming.Countdown(remaining);
        Assert.Equal(1, remaining);
        Assert.Equal(0, TimerTiming.Countdown(remaining));
        Assert.Equal(0, TimerTiming.Countdown(0));
        foreach (var (offset, cycle, isBreak, left) in new[] { (0.0, 0L, false, 37), (36.25, 0L, false, 1),
            (37.0, 0L, true, 13), (49.5, 0L, true, 1), (50.0, 1L, false, 37), (87.0, 1L, true, 13) })
        {
            var position = TimerTiming.At(37, 13, 2000, 2000 + offset);
            Assert.Equal(cycle, position.Cycle);
            Assert.Equal(isBreak, position.IsBreak);
            Assert.Equal(left, position.Remaining);
        }
        Assert.True(TimerTiming.At(1, 1, 0, 1).IsBreak);
        Assert.False(TimerTiming.At(1, 1, 0, 2).IsBreak);
    }

    internal static void CrossPlatformVectors()
    {
        using var json = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "session-codes.json")));
        foreach (var vector in json.RootElement.EnumerateArray())
        {
            int work = vector.GetProperty("work").GetInt32();
            int rest = vector.GetProperty("rest").GetInt32();
            double anchor = vector.GetProperty("anchor").GetDouble();
            string code = vector.GetProperty("code").GetString()!;
            Assert.Equal(code, SessionCode.Encode(work, rest, anchor));
            foreach (double now in new[] { anchor, anchor + 123, anchor + 2_097_151 })
            {
                var decoded = SessionCode.Decode(code, now);
                Assert.NotNull(decoded);
                Assert.Equal(work, decoded!.Work);
                Assert.Equal(rest, decoded.Rest);
                Assert.Equal(anchor, decoded.Anchor);
            }
            string grouped = code.Length == 11 ? code[..5] + "-" + code[5..] : code;
            Assert.NotNull(SessionCode.Decode(" \n" + grouped.ToLowerInvariant() + "\n", anchor));
        }
    }

    internal static void EveryCustomSecond()
    {
        for (int seconds = 1; seconds <= DurationValue.Maximum; seconds++)
        {
            foreach (var (work, rest) in new[] { (seconds, 37), (37, seconds) })
            {
                string code = SessionCode.Encode(work, rest, 1_788_600_000);
                var decoded = SessionCode.Decode(code, 1_788_600_001);
                Assert.NotNull(decoded);
                Assert.Equal(work, decoded!.Work);
                Assert.Equal(rest, decoded.Rest);
            }
        }
    }

    internal static void LegacyAndInvalidCodes()
    {
        static string Legacy(string payload) => Convert.ToBase64String(Encoding.UTF8.GetBytes(payload));
        var valid = SessionCode.Decode(Legacy("37:13:1788600000"), 1_788_600_000);
        Assert.NotNull(valid);
        Assert.Equal(37, valid!.Work);
        Assert.Equal(13, valid.Rest);
        Assert.Equal(1_788_600_000.0, valid.Anchor);
        foreach (string code in new[] { "", "ABCDE", "ABCDEFG", "AAAAAAAAAA", "AAAAAAAAAAAA", "AAAAA0", "AAAAA!",
            "777777", "77777777777", Legacy("0:13:1788600000"), Legacy("37:NaN:1788600000"),
            Legacy("37:13:Infinity"), Legacy("37:13:-1"), Legacy("86401:13:1788600000"),
            Legacy("1.5:13:1788600000"), Legacy("37:13"), Legacy("37:13:1788600000:extra") })
            Assert.True(SessionCode.Decode(code, 1_788_600_000) == null, code);
    }
}
