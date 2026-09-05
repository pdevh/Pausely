using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Application = System.Windows.Application;
using Button = System.Windows.Controls.Button;
using TextBox = System.Windows.Controls.TextBox;
using System.Windows.Threading;
using PauselyWindows;

internal static class Program
{
    [STAThread]
    private static int Main()
    {
        // Load the application's native theme without starting its tray/updater lifecycle.
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.Resources = (ResourceDictionary)System.Windows.Markup.XamlReader.Parse("""
            <ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                                xmlns:ui="http://schemas.lepo.co/wpfui/2022/xaml">
                <ResourceDictionary.MergedDictionaries>
                    <ui:ThemesDictionary Theme="Dark" />
                    <ui:ControlsDictionary />
                </ResourceDictionary.MergedDictionaries>
            </ResourceDictionary>
            """);
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
        Console.WriteLine($"{name}: {window.ActualWidth} × {window.ActualHeight}");
        string? directory = Environment.GetEnvironmentVariable("PAUSELY_UI_SNAPSHOT_DIR");
        if (directory == null) return;
        Directory.CreateDirectory(directory);
        // Capture the composed native window, including Mica and system controls.
        window.Dispatcher.Invoke(() => { }, DispatcherPriority.ContextIdle);
        System.Threading.Thread.Sleep(150);
        var origin = window.PointToScreen(new System.Windows.Point(0, 0));
        var dpi = VisualTreeHelper.GetDpi(window);
        using var bitmap = new System.Drawing.Bitmap((int)Math.Ceiling(window.ActualWidth * dpi.DpiScaleX),
            (int)Math.Ceiling(window.ActualHeight * dpi.DpiScaleY));
        using (var graphics = System.Drawing.Graphics.FromImage(bitmap))
            graphics.CopyFromScreen((int)origin.X, (int)origin.Y, 0, 0, bitmap.Size);
        bitmap.Save(Path.Combine(directory, name + ".png"), System.Drawing.Imaging.ImageFormat.Png);
        Check(window.ActualWidth <= 420 && window.ActualHeight <= 400, "Compact dialog bounds");
    }
}
