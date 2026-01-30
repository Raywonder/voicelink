using System;
using System.Windows;

namespace VoiceLinkNative.Views
{
    public partial class MainWindow : Window
    {
        public MainWindow()
        {
            InitializeComponent();
        }

        private void Connect_Click(object sender, RoutedEventArgs e)
        {
            MessageBox.Show("Windows Native Build Complete!", "VoiceLink Native", MessageBoxButton.OK, MessageBoxImage.Information);
        }

        private void Login_Click(object sender, RoutedEventArgs e)
        {
            MessageBox.Show("Mastodon authentication ready for implementation", "VoiceLink Native", MessageBoxButton.OK, MessageBoxImage.Information);
        }

        private void Exit_Click(object sender, RoutedEventArgs e)
        {
            Application.Current.Shutdown();
        }
    }
}