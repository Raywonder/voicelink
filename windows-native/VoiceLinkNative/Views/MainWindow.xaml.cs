using System;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using System.Windows;
using VoiceLinkNative.Services;

namespace VoiceLinkNative.Views
{
    public partial class MainWindow : Window, INotifyPropertyChanged
    {
        private readonly AuthenticationManager _auth = AuthenticationManager.Instance;
        private readonly ServerManager _server = ServerManager.Instance;
        private readonly LicensingManager _licensing = LicensingManager.Instance;

        private string _authSummary = "Signed out";
        private string _authDetail = "Sign in to unlock licensing and server ownership features.";
        private string _serverSummary = "Disconnected";
        private string _serverDetail = "No active VoiceLink server connection.";
        private string _licenseSummary = "License not loaded";
        private string _licenseDetail = "Sign in to refresh your license and device activation state.";
        private string _latestNotice = "No license notices yet.";
        private string _errorMessage = "";

        public event PropertyChangedEventHandler? PropertyChanged;

        public string AuthSummary { get => _authSummary; private set => SetProperty(ref _authSummary, value); }
        public string AuthDetail { get => _authDetail; private set => SetProperty(ref _authDetail, value); }
        public string ServerSummary { get => _serverSummary; private set => SetProperty(ref _serverSummary, value); }
        public string ServerDetail { get => _serverDetail; private set => SetProperty(ref _serverDetail, value); }
        public string LicenseSummary { get => _licenseSummary; private set => SetProperty(ref _licenseSummary, value); }
        public string LicenseDetail { get => _licenseDetail; private set => SetProperty(ref _licenseDetail, value); }
        public string LatestNotice { get => _latestNotice; private set => SetProperty(ref _latestNotice, value); }
        public string ErrorMessage { get => _errorMessage; private set => SetProperty(ref _errorMessage, value); }

        public ObservableCollection<LicensingManager.RecentMachine> RecentMachines { get; } = new();
        public ObservableCollection<LicensingManager.ActivatedDevice> Devices { get; } = new();

        public MainWindow()
        {
            InitializeComponent();
            DataContext = this;

            _auth.PropertyChanged += HandleStateChanged;
            _server.PropertyChanged += HandleStateChanged;
            _licensing.PropertyChanged += HandleStateChanged;

            RefreshFromState();
            _ = RefreshLicenseIfAuthenticatedAsync();
        }

        private void HandleStateChanged(object? sender, PropertyChangedEventArgs e)
        {
            Dispatcher.Invoke(RefreshFromState);
        }

        private void RefreshFromState()
        {
            if (_auth.IsAuthenticated && _auth.CurrentUser != null)
            {
                var user = _auth.CurrentUser;
                AuthSummary = $"Signed in as {user.DisplayName ?? user.Username}";
                AuthDetail = $"Provider: {user.AuthProvider ?? user.AuthMethod}  Role: {user.Role ?? "user"}  Email: {user.Email ?? "not supplied"}";
            }
            else
            {
                AuthSummary = "Signed out";
                AuthDetail = "Sign in with email, WHMCS, Mastodon, or other supported auth methods.";
            }

            ServerSummary = _server.ServerStatus;
            ServerDetail = string.IsNullOrWhiteSpace(_server.ConnectedServer)
                ? "No active VoiceLink server connection."
                : $"Connected to {_server.ConnectedServer}";

            LicenseSummary = _licensing.ActivationRequired
                ? $"Activation required for this device ({_licensing.ActivatedDevices}/{_licensing.MaxDevices} in use)"
                : $"License: {_licensing.LicenseStatus} ({_licensing.ActivatedDevices}/{_licensing.MaxDevices} devices)";
            LicenseDetail = $"Key: {_licensing.LicenseKey ?? "not assigned"}  Email: {_licensing.PrimaryEmail ?? "not assigned"}  Slots left: {_licensing.RemainingSlots}";
            LatestNotice = _licensing.LatestLicenseNotice ?? (_licensing.LastEvictedDeviceName != null
                ? $"Oldest device replaced: {_licensing.LastEvictedDeviceName}"
                : "No license notices yet.");
            ErrorMessage = _licensing.ErrorMessage ?? _auth.ErrorMessage ?? string.Empty;

            RecentMachines.Clear();
            foreach (var machine in _licensing.RecentMachines)
            {
                RecentMachines.Add(machine);
            }

            Devices.Clear();
            foreach (var device in _licensing.Devices)
            {
                Devices.Add(device);
            }
        }

        private async Task RefreshLicenseIfAuthenticatedAsync()
        {
            if (!_auth.IsAuthenticated)
            {
                return;
            }

            await _licensing.SyncEntitlementsFromCurrentUserAsync();
            await _licensing.RefreshForCurrentUserAsync();
            RefreshFromState();
        }

        private void OpenServers_Click(object sender, RoutedEventArgs e)
        {
            var window = new Window
            {
                Title = "VoiceLink Servers",
                Width = 980,
                Height = 760,
                Content = new ServersView(),
                Owner = this
            };
            window.Show();
        }

        private void OpenSettings_Click(object sender, RoutedEventArgs e)
        {
            var window = new Window
            {
                Title = "VoiceLink Settings",
                Width = 920,
                Height = 760,
                Content = new SettingsView(),
                Owner = this
            };
            window.Show();
        }

        private async void RefreshLicense_Click(object sender, RoutedEventArgs e)
        {
            await RefreshLicenseIfAuthenticatedAsync();
        }

        private async void ActivateDevice_Click(object sender, RoutedEventArgs e)
        {
            if (!_auth.IsAuthenticated)
            {
                MessageBox.Show("Sign in before activating this device.", "VoiceLink", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            var ok = await _licensing.ActivateCurrentDeviceAsync();
            RefreshFromState();
            if (!ok)
            {
                MessageBox.Show(_licensing.ErrorMessage ?? "Device activation failed.", "VoiceLink", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private void Logout_Click(object sender, RoutedEventArgs e)
        {
            _auth.Logout();
            RefreshFromState();
        }

        private void SetProperty<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
        {
            if (Equals(field, value))
            {
                return;
            }

            field = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        }
    }
}
