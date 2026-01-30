using System;
using System.Threading.Tasks;
using System.Windows;

namespace VoiceLinkNative.Services
{
    public class NotificationService
    {
        public static NotificationService Instance { get; private set; } = new NotificationService();

        public void ShowNotification(string title, string message)
        {
            // Simple notification without toolkit dependencies
            MessageBox.Show(message, title, MessageBoxButton.OK, MessageBoxImage.Information);
        }

        public void ShowError(string title, string message)
        {
            MessageBox.Show(message, title, MessageBoxButton.OK, MessageBoxImage.Error);
        }

        public void ShowSuccess(string title, string message)
        {
            MessageBox.Show(message, title, MessageBoxButton.OK, MessageBoxImage.Information);
        }
    }
}