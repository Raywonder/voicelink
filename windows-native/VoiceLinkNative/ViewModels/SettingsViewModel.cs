using System;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Input;
using WpfMessageBox = System.Windows.MessageBox;

namespace VoiceLinkNative.ViewModels
{
    public class SettingsViewModel : INotifyPropertyChanged
    {
        private string _mastodonInstance = string.Empty;
        private bool _isAuthenticated;
        private double _inputVolume = 85;
        private double _outputVolume = 90;
        private bool _noiseSuppression = true;
        private bool _echoCancellation = true;
        private bool _pushToTalk;
        private string _pushToTalkKey = "Ctrl+Space";
        private bool _playSounds = true;
        private bool _startMinimized;
        private bool _minimizeToTray;
        private bool _startWithWindows;
        private bool _screenReaderAnnouncements = true;
        private bool _announceWindowReady = true;
        private bool _announceUserJoin = true;
        private bool _announceUserLeave = true;
        private bool _announceRoomChanges = true;
        private bool _announceStatusChanges = true;
        private double _speechRate = 50;
        private string _username = string.Empty;
        private string _email = string.Empty;
        private string _authMethodDisplay = "Not authenticated";

        public SettingsViewModel()
        {
            TestAudioCommand = new RelayCommand(() =>
                WpfMessageBox.Show("Audio test is not wired yet.", "VoiceLink"));
            LogoutCommand = new RelayCommand(Logout);
            ResetSettingsCommand = new RelayCommand(ResetSettings);
        }

        public string MastodonInstance
        {
            get => _mastodonInstance;
            set => SetProperty(ref _mastodonInstance, value);
        }

        public bool IsAuthenticated
        {
            get => _isAuthenticated;
            set => SetProperty(ref _isAuthenticated, value);
        }

        public double InputVolume
        {
            get => _inputVolume;
            set => SetProperty(ref _inputVolume, value);
        }

        public double OutputVolume
        {
            get => _outputVolume;
            set => SetProperty(ref _outputVolume, value);
        }

        public bool NoiseSuppression
        {
            get => _noiseSuppression;
            set => SetProperty(ref _noiseSuppression, value);
        }

        public bool EchoCancellation
        {
            get => _echoCancellation;
            set => SetProperty(ref _echoCancellation, value);
        }

        public bool PushToTalk
        {
            get => _pushToTalk;
            set => SetProperty(ref _pushToTalk, value);
        }

        public string PushToTalkKey
        {
            get => _pushToTalkKey;
            set => SetProperty(ref _pushToTalkKey, value);
        }

        public bool PlaySounds
        {
            get => _playSounds;
            set => SetProperty(ref _playSounds, value);
        }

        public bool StartMinimized
        {
            get => _startMinimized;
            set => SetProperty(ref _startMinimized, value);
        }

        public bool MinimizeToTray
        {
            get => _minimizeToTray;
            set => SetProperty(ref _minimizeToTray, value);
        }

        public bool StartWithWindows
        {
            get => _startWithWindows;
            set => SetProperty(ref _startWithWindows, value);
        }

        public bool ScreenReaderAnnouncements
        {
            get => _screenReaderAnnouncements;
            set => SetProperty(ref _screenReaderAnnouncements, value);
        }

        public bool AnnounceWindowReady
        {
            get => _announceWindowReady;
            set => SetProperty(ref _announceWindowReady, value);
        }

        public bool AnnounceUserJoin
        {
            get => _announceUserJoin;
            set => SetProperty(ref _announceUserJoin, value);
        }

        public bool AnnounceUserLeave
        {
            get => _announceUserLeave;
            set => SetProperty(ref _announceUserLeave, value);
        }

        public bool AnnounceRoomChanges
        {
            get => _announceRoomChanges;
            set => SetProperty(ref _announceRoomChanges, value);
        }

        public bool AnnounceStatusChanges
        {
            get => _announceStatusChanges;
            set => SetProperty(ref _announceStatusChanges, value);
        }

        public double SpeechRate
        {
            get => _speechRate;
            set => SetProperty(ref _speechRate, value);
        }

        public string Username
        {
            get => _username;
            set => SetProperty(ref _username, value);
        }

        public string Email
        {
            get => _email;
            set => SetProperty(ref _email, value);
        }

        public string AuthMethodDisplay
        {
            get => _authMethodDisplay;
            set => SetProperty(ref _authMethodDisplay, value);
        }

        public ICommand TestAudioCommand { get; }
        public ICommand LogoutCommand { get; }
        public ICommand ResetSettingsCommand { get; }

        public event PropertyChangedEventHandler? PropertyChanged;

        public void LoginWithAuthCode()
        {
            if (string.IsNullOrEmpty(MastodonInstance))
            {
                WpfMessageBox.Show("Please enter Mastodon instance", "VoiceLink");
                return;
            }

            IsAuthenticated = true;
            Username = MastodonInstance;
            AuthMethodDisplay = "Mastodon";
            WpfMessageBox.Show("Successfully logged in!", "VoiceLink");
        }

        public void Logout()
        {
            IsAuthenticated = false;
            Username = string.Empty;
            Email = string.Empty;
            AuthMethodDisplay = "Not authenticated";
            MastodonInstance = string.Empty;
        }

        private void ResetSettings()
        {
            InputVolume = 85;
            OutputVolume = 90;
            NoiseSuppression = true;
            EchoCancellation = true;
            PushToTalk = false;
            PushToTalkKey = "Ctrl+Space";
            PlaySounds = true;
            StartMinimized = false;
            MinimizeToTray = false;
            StartWithWindows = false;
            ScreenReaderAnnouncements = true;
            AnnounceWindowReady = true;
            AnnounceUserJoin = true;
            AnnounceUserLeave = true;
            AnnounceRoomChanges = true;
            AnnounceStatusChanges = true;
            SpeechRate = 50;
        }

        protected virtual void OnPropertyChanged([CallerMemberName] string? propertyName = null)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        }

        private void SetProperty<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
        {
            if (Equals(field, value))
            {
                return;
            }

            field = value;
            OnPropertyChanged(propertyName);
        }
    }
}
