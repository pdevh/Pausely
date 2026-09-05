using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using PauselyWindows;

internal static class Program
{
    [STAThread]
    private static int Main()
    {
        var app = new App();
        app.InitializeComponent();
        try
        {
            Exercise(37, window =>
            {
                var input = Find<TextBox>(window, "DurationInput");
                Check(input.Text == "0:37", "Initial clock display");
                Snapshot(window, "custom-37");
                Click(window, "AddHour");
                Check(input.Text == "1:00:37", "Hour adjustment updates display");
                input.Text = "3757";
                Click(window, "AddSecond");
                Check(input.Text == "1:02:38", "Typing and clicks share the current value");
                input.Text = "1:60";
                Check(!Find<Button>(window, "SaveButton").IsEnabled, "Invalid Save disabled");
                foreach (string name in new[] { "AddHour", "SubtractHour", "AddMinute", "SubtractMinute", "AddSecond", "SubtractSecond" })
                    Check(!Find<Button>(window, name).IsEnabled, name + " disabled for invalid input");
                Snapshot(window, "custom-invalid");
                window.DialogResult = false;
                Check(window.SelectedSeconds == null, "Cancel applies no value");
            });
            Exercise(3757, window =>
            {
                Snapshot(window, "custom-hour");
                Find<TextBox>(window, "DurationInput").Text = "37";
                Click(window, "SaveButton");
                Check(window.SelectedSeconds == 37, "Save commits typed seconds");
            });
            Exercise(86400, window =>
            {
                Check(Find<TextBox>(window, "DurationInput").Text == "24:00:00", "Maximum clock display");
                foreach (string name in new[] { "AddHour", "AddMinute", "AddSecond" })
                    Check(!Find<Button>(window, name).IsEnabled, name + " disabled at maximum");
                Snapshot(window, "custom-24h");
                Click(window, "SubtractSecond");
                Check(Find<TextBox>(window, "DurationInput").Text == "23:59:59", "Second adjustment crosses hour boundary");
                window.DialogResult = false;
            });
            Console.WriteLine("PASS native Windows duration dialog interaction and rendering tests");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
        finally { app.Shutdown(); }
    }

    private static void Exercise(int seconds, Action<CustomDurationWindow> action)
    {
        var window = new CustomDurationWindow(true, seconds);
        Exception? failure = null;
        window.Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(() =>
        {
            try { action(window); }
            catch (Exception error) { failure = error; window.Close(); }
        }));
        window.ShowDialog();
        if (failure != null) throw failure;
    }

    private static T Find<T>(Window window, string name) where T : class =>
        window.FindName(name) as T ?? throw new InvalidOperationException("Missing control: " + name);

    private static void Click(Window window, string name) =>
        Find<Button>(window, name).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void Snapshot(Window window, string name)
    {
        window.UpdateLayout();
        Check(window.ActualWidth <= 420 && window.ActualHeight <= 400, "Compact dialog bounds");
        string? directory = Environment.GetEnvironmentVariable("PAUSELY_UI_SNAPSHOT_DIR");
        if (directory == null) return;
        Directory.CreateDirectory(directory);
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth),
            (int)Math.Ceiling(window.ActualHeight), 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(window);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var file = File.Create(Path.Combine(directory, name + ".png"));
        encoder.Save(file);
    }
}
