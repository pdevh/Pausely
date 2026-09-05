using System.Windows;
using System.Windows.Controls;
using PauselyWindows.Services;

namespace PauselyWindows;

public partial class JoinSessionWindow : Wpf.Ui.Controls.FluentWindow
{
    public JoinSessionWindow()
    {
        InitializeComponent();
        Loaded += (_, _) => CodeInput.Focus();
    }

    private void CodeInput_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (JoinButton == null) return;
        var schedule = SessionCode.Decode(CodeInput.Text, DateTimeOffset.UtcNow.ToUnixTimeSeconds());
        Preview.Text = schedule == null
            ? "Enter a 6- or 11-character code. Legacy codes also work."
            : $"Work {DurationValue.Label(schedule.Work)} · Break {DurationValue.Label(schedule.Rest)}";
        JoinButton.IsEnabled = !string.IsNullOrWhiteSpace(CodeInput.Text);
    }

    private void Join_Click(object sender, RoutedEventArgs e)
    {
        if (BreakManager.Shared.JoinSession(CodeInput.Text)) DialogResult = true;
        else Preview.Text = "Check the code and try again.";
    }
}
