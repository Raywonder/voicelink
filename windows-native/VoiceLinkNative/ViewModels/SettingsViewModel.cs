using System;
using System.Windows;

namespace VoiceLinkNative.ViewModels
{
    public class SettingsViewModel : System.ComponentModel.INotifyPropertyChanged
    {
        private string _mastodonInstance;
        private bool _isAuthenticated;

        public string MastodonInstance
        {
            get => _mastodonInstance;
            set 
            { 
                _mastodonInstance = value;
                OnPropertyChanged(nameof(MastodonInstance));
            }
        }

        public bool IsAuthenticated
        {
            get => _isAuthenticated;
            set 
            { 
                _isAuthenticated = value;
                OnPropertyChanged(nameof(IsAuthenticated));
            }
        }

        public event System.ComponentModel.PropertyChangedEventHandler? PropertyChanged;

        protected virtual void OnPropertyChanged(string propertyName)
        {
            PropertyChanged?.Invoke(this, new System.ComponentModel.PropertyChangedEventArgs(propertyName));
        }

        public void LoginWithAuthCode()
        {
            if (!string.IsNullOrEmpty(MastodonInstance))
            {
                System.Windows.MessageBox.Show("Please enter Mastodon instance", "Error");
                return;
            }

            IsAuthenticated = true;
            System.Windows.MessageBox.Show("Successfully logged in!", "Success");
        }

        public void Logout()
        {
            IsAuthenticated = false;
            MastodonInstance = string.Empty;
        }
    }
}