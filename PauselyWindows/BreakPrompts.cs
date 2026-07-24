using System;

namespace PauselyWindows
{
    public sealed record BreakPrompt(string Title, string Message);

    public static class BreakPrompts
    {
        private static readonly BreakPrompt[] FullBreaks =
        {
            new("Step away", "Let your brain work in the background. Step away from the computer and think about something unrelated."),
            new("Blink", "Blink rapidly for a few seconds to refresh the tear film and clear dust from the eye surface."),
            new("Move", "Try marching in place, stretching, or doing a few desk push-ups."),
            new("Notice", "Daydreaming or having trouble focusing can be a sign that you need this break."),
            new("Focus change", "Focus on something nearby, then slowly shift your focus to an object in the distance."),
            new("Declutter", "Use this pause to clear one small thing from your desk and reset your attention."),
            new("Slow breathing", "Breathe in slowly through your nose, pause, and exhale gently. Repeat a few times."),
            new("Wrist and forearm", "Extend your arms with palms facing you, then slowly rotate your hands in both directions.")
        };

        private static readonly string[] Microbreaks =
        {
            "Slowly look all the way left, then right.",
            "Slowly look all the way up, then down.",
            "Close your eyes and take a few deep breaths.",
            "Stand up and stretch your legs.",
            "Refocus your eyes on an object at least 20 meters away.",
            "Relax your shoulders and correct your sitting posture.",
            "Take a moment to think about something you appreciate.",
            "Shake your hands out and gently stretch your fingers."
        };

        public static BreakPrompt RandomBreak() => FullBreaks[Random.Shared.Next(FullBreaks.Length)];

        public static string RandomMicrobreak() => Microbreaks[Random.Shared.Next(Microbreaks.Length)];
    }
}
