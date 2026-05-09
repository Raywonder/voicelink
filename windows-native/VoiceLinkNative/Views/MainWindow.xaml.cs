using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;

namespace VoiceLinkNative.Views
{
    public partial class MainWindow : Window
    {
        private const uint SpiGetScreenReader = 0x0046;

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SystemParametersInfo(uint uiAction, uint uiParam, out bool pvParam, uint fWinIni);

        public MainWindow()
        {
            InitializeComponent();
            Loaded += OnLoaded;
        }

        private void OnLoaded(object sender, RoutedEventArgs e)
        {
            var readerName = DetectScreenReader();
            if (string.IsNullOrWhiteSpace(readerName))
            {
                return;
            }

            var announcement = readerName == "ScreenReader"
                ? "Screen reader detected. VoiceLink window is ready."
                : $"{readerName} screen reader detected. VoiceLink window is ready.";
            ScreenReaderStatusText.Text = announcement;
            var peer = UIElementAutomationPeer.CreatePeerForElement(ScreenReaderStatusText)
                ?? UIElementAutomationPeer.FromElement(ScreenReaderStatusText)
                ?? new FrameworkElementAutomationPeer(ScreenReaderStatusText);
            peer.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
        }

        private static string? DetectScreenReader()
        {
            if (IsProcessRunning("nvda"))
            {
                return "NVDA";
            }

            if (IsProcessRunning("jfw") || IsProcessRunning("jaws"))
            {
                return "JAWS";
            }

            if (IsProcessRunning("fsreader"))
            {
                return "Freedom Scientific";
            }

            return IsScreenReaderEnabled() ? "ScreenReader" : null;
        }

        private static bool IsProcessRunning(string processName)
        {
            try
            {
                return Process.GetProcessesByName(processName).Length > 0;
            }
            catch
            {
                return false;
            }
        }

        private static bool IsScreenReaderEnabled()
        {
            try
            {
                return SystemParametersInfo(SpiGetScreenReader, 0, out var screenReaderEnabled, 0) && screenReaderEnabled;
            }
            catch
            {
                return false;
            }
        }

        private void Connect_Click(object sender, RoutedEventArgs e)
        {
            System.Windows.MessageBox.Show("Windows build complete!", "VoiceLink", MessageBoxButton.OK, MessageBoxImage.Information);
        }

        private void Login_Click(object sender, RoutedEventArgs e)
        {
            System.Windows.MessageBox.Show("Mastodon authentication ready for implementation", "VoiceLink", MessageBoxButton.OK, MessageBoxImage.Information);
        }

        private void Exit_Click(object sender, RoutedEventArgs e)
        {
            System.Windows.Application.Current.Shutdown();
        }
    }
}
