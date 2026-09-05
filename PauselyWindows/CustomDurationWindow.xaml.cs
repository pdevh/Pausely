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
        Title = isWorkInterval ? "Work interval" : "Break duration";
        Heading.Content = Title;
        System.Windows.Automation.AutomationProperties.SetName(DurationInput, Title);
        DurationInput.Text = _draft.Text;
        Loaded += (_, _) => { DurationInput.Focus(); DurationInput.SelectAll(); };
    }

    private void DurationInput_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (SaveButton == null) return;
        _draft.Text = DurationInput.Text;
        SaveButton.IsEnabled = _draft.Seconds.HasValue;
        Validation.Text = _draft.Seconds.HasValue
            ? "" : _draft.Text.Length == 0 ? "Enter seconds, m:ss, or h:mm:ss."
            : "Enter seconds or h:mm:ss, from 1s to 24h.";
        foreach (StackPanel group in Adjustments.Children)
            foreach (System.Windows.Controls.Button button in ((StackPanel)group.Children[1]).Children)
                button.IsEnabled = _draft.CanAdjust(int.Parse((string)button.Tag));
    }

    private void DurationInput_LostKeyboardFocus(object sender, System.Windows.Input.KeyboardFocusChangedEventArgs e)
    {
        _draft.Normalize();
        DurationInput.Text = _draft.Text;
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
