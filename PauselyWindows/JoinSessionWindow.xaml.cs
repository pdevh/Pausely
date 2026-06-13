using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace PauselyWindows
{
    public partial class JoinSessionWindow : Wpf.Ui.Controls.FluentWindow
    {
        private Border[] _boxes;
        private TextBlock[] _texts;

        public JoinSessionWindow()
        {
            InitializeComponent();
            _boxes = new[] { Box0, Box1, Box2, Box3, Box4, Box5 };
            _texts = new[] { Text0, Text1, Text2, Text3, Text4, Text5 };
            
            this.Loaded += (s, e) => {
                HiddenInput.Focus();
                UpdateHighlights();
            };
        }

        private void Container_MouseDown(object sender, MouseButtonEventArgs e)
        {
            HiddenInput.Focus();
        }

        private void HiddenInput_GotFocus(object sender, RoutedEventArgs e)
        {
            UpdateHighlights();
        }

        private void HiddenInput_LostFocus(object sender, RoutedEventArgs e)
        {
            UpdateHighlights();
        }

        private void HiddenInput_TextChanged(object sender, TextChangedEventArgs e)
        {
            string upper = new string(HiddenInput.Text.ToUpperInvariant().Where(c => "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".Contains(c)).ToArray());
            
            if (upper.Length > 6) upper = upper.Substring(0, 6);

            if (HiddenInput.Text != upper)
            {
                HiddenInput.Text = upper;
                HiddenInput.CaretIndex = upper.Length;
                return;
            }

            for (int i = 0; i < 6; i++)
            {
                _texts[i].Text = i < upper.Length ? upper[i].ToString() : "";
            }

            UpdateHighlights();

            JoinButton.IsEnabled = upper.Length == 6;
        }

        private void UpdateHighlights()
        {
            int activeIndex = Math.Min(HiddenInput.Text.Length, 5);
            var defaultBrush = TryFindResource("ControlStrokeColorDefaultBrush") as System.Windows.Media.Brush ?? System.Windows.Media.Brushes.Gray;
            var activeBrush = TryFindResource("SystemAccentColorPrimaryBrush") as System.Windows.Media.Brush ?? System.Windows.Media.Brushes.DodgerBlue;

            for (int i = 0; i < 6; i++)
            {
                if ((i == activeIndex && HiddenInput.IsFocused) || (HiddenInput.Text.Length == 6 && i == 5 && HiddenInput.IsFocused))
                {
                    _boxes[i].BorderBrush = activeBrush;
                    _boxes[i].BorderThickness = new Thickness(2.5);
                }
                else
                {
                    _boxes[i].BorderBrush = defaultBrush;
                    _boxes[i].BorderThickness = new Thickness(1);
                }
            }
        }

        protected override void OnActivated(EventArgs e)
        {
            base.OnActivated(e);
            UpdateHighlights();
        }

        protected override void OnDeactivated(EventArgs e)
        {
            base.OnDeactivated(e);
            UpdateHighlights();
        }

        private void Cancel_Click(object sender, RoutedEventArgs e)
        {
            this.Close();
        }

        private void Join_Click(object sender, RoutedEventArgs e)
        {
            string code = HiddenInput.Text;
            if (code.Length == 6)
            {
                BreakManager.Shared.JoinSession(code);
                this.Close();
            }
        }
    }
}
