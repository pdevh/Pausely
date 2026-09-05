using System.Windows;
using System.Windows.Controls;
using PauselyWindows.Services;

namespace PauselyWindows;

public partial class CustomDurationWindow : Wpf.Ui.Controls.FluentWindow
{
    private readonly DurationDraft _draft;
    public int? SelectedSeconds { get; private set; }

    public CustomDurationWindow(bool isWorkInterval, int seconds)
    {
        _draft = new(seconds);
        InitializeComponent();
        Title = Heading.Text = isWorkInterval ? "Custom Work Interval" : "Custom Break Duration";
        Explanation.Text = isWorkInterval ? "Time to focus between breaks." : "Time to rest during each break.";
        DurationInput.Text = _draft.Text;
        Loaded += (_, _) => { DurationInput.Focus(); DurationInput.SelectAll(); };
    }

    private void DurationInput_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (SaveButton == null) return;
        _draft.Text = DurationInput.Text;
        Preview.Text = _draft.Seconds is int seconds ? DurationValue.Clock(seconds) : "–:––";
        PreviewLabel.Text = _draft.Seconds is int value ? DurationValue.Label(value) : "Enter a valid duration";
        SaveButton.IsEnabled = _draft.Seconds.HasValue;
        Validation.Text = _draft.Seconds.HasValue
            ? "From 1 second to 24 hours. Changes apply when saved."
            : "Use a whole-second duration from 1 second to 24 hours.";
        foreach (System.Windows.Controls.Button button in Adjustments.Children)
            button.IsEnabled = _draft.CanAdjust(int.Parse((string)button.Tag));
    }

    private void Adjust_Click(object sender, RoutedEventArgs e)
    {
        _draft.Adjust(int.Parse((string)((System.Windows.Controls.Button)sender).Tag));
        DurationInput.Text = _draft.Text;
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        if (_draft.Seconds is not int seconds) return;
        SelectedSeconds = seconds;
        DialogResult = true;
    }
}
