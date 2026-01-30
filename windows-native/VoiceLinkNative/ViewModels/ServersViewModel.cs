using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Input;
using CommunityToolkit.Mvvm.Input;
using VoiceLinkNative.Services;

namespace VoiceLinkNative.ViewModels;

public class ServersViewModel : INotifyPropertyChanged
{
    private readonly ServerManager _serverManager;
    private readonly AuthenticationManager _authManager;

    // Custom server URL
    private string _customServerUrl = "";
    public string CustomServerUrl
    {
        get => _customServerUrl;
        set { _customServerUrl = value; OnPropertyChanged(); }
    }

    // Pairing
    private string _pairingCode = "";
    public string PairingCode
    {
        get => _pairingCode;
        set { _pairingCode = value; OnPropertyChanged(); }
    }

    private bool _showPairingDialog;
    public bool ShowPairingDialog
    {
        get => _showPairingDialog;
        set { _showPairingDialog = value; OnPropertyChanged(); }
    }

    // Email auth
    private string _email = "";
    public string Email
    {
        get => _email;
        set { _email = value; OnPropertyChanged(); }
    }

    private string _verificationCode = "";
    public string VerificationCode
    {
        get => _verificationCode;
        set { _verificationCode = value; OnPropertyChanged(); }
    }

    private bool _showEmailVerification;
    public bool ShowEmailVerification
    {
        get => _showEmailVerification;
        set { _showEmailVerification = value; OnPropertyChanged(); }
    }

    // Mastodon auth
    private string _mastodonInstance = "";
    public string MastodonInstance
    {
        get => _mastodonInstance;
        set { _mastodonInstance = value; OnPropertyChanged(); }
    }

    // Status bindings
    public bool IsConnected => _serverManager.IsConnected;
    public string ServerStatus => _serverManager.ServerStatus;
    public string ConnectedServer => _serverManager.ConnectedServer;

    // Auth status
    public bool IsAuthenticated => _authManager.CurrentState == AuthenticationManager.AuthState.Authenticated;
    public string? AuthenticatedUsername => _authManager.CurrentUser?.Username;

    // Commands
    public ICommand ConnectMainCommand { get; }
    public ICommand ConnectLocalCommand { get; }
    public ICommand ConnectCustomCommand { get; }
    public ICommand DisconnectCommand { get; }
    public ICommand StartPairingCommand { get; }
    public ICommand SubmitPairingCodeCommand { get; }
    public ICommand CancelPairingCommand { get; }
    public ICommand RequestEmailVerificationCommand { get; }
    public ICommand SubmitEmailCodeCommand { get; }
    public ICommand StartMastodonAuthCommand { get; }
    public ICommand LogoutCommand { get; }

    public ServersViewModel(ServerManager serverManager, AuthenticationManager authManager)
    {
        _serverManager = serverManager;
        _authManager = authManager;

        // Subscribe to changes
        _serverManager.PropertyChanged += (s, e) =>
        {
            OnPropertyChanged(nameof(IsConnected));
            OnPropertyChanged(nameof(ServerStatus));
            OnPropertyChanged(nameof(ConnectedServer));
        };

        _authManager.PropertyChanged += (s, e) =>
        {
            OnPropertyChanged(nameof(IsAuthenticated));
            OnPropertyChanged(nameof(AuthenticatedUsername));
        };

        // Initialize commands
        ConnectMainCommand = new AsyncRelayCommand(async () => await _serverManager.ConnectToMainServerAsync());
        ConnectLocalCommand = new AsyncRelayCommand(async () => await _serverManager.ConnectToLocalServerAsync());
        ConnectCustomCommand = new AsyncRelayCommand(ConnectCustomAsync);
        DisconnectCommand = new RelayCommand(() => _serverManager.Disconnect());

        StartPairingCommand = new RelayCommand(() => ShowPairingDialog = true);
        SubmitPairingCodeCommand = new AsyncRelayCommand(SubmitPairingCodeAsync);
        CancelPairingCommand = new RelayCommand(() =>
        {
            ShowPairingDialog = false;
            PairingCode = "";
        });

        RequestEmailVerificationCommand = new AsyncRelayCommand(RequestEmailVerificationAsync);
        SubmitEmailCodeCommand = new AsyncRelayCommand(SubmitEmailCodeAsync);

        StartMastodonAuthCommand = new RelayCommand(StartMastodonAuth);
        LogoutCommand = new RelayCommand(() => _authManager.Logout());
    }

    private async Task ConnectCustomAsync()
    {
        if (!string.IsNullOrEmpty(CustomServerUrl))
        {
            await _serverManager.ConnectToUrlAsync(CustomServerUrl);
        }
    }

    private async Task SubmitPairingCodeAsync()
    {
        if (!string.IsNullOrEmpty(PairingCode))
        {
            var success = await _authManager.AuthenticateWithPairingCodeAsync(PairingCode);
            if (success)
            {
                ShowPairingDialog = false;
                PairingCode = "";
            }
        }
    }

    private async Task RequestEmailVerificationAsync()
    {
        if (!string.IsNullOrEmpty(Email))
        {
            var success = await _authManager.RequestEmailVerificationAsync(Email);
            if (success)
            {
                ShowEmailVerification = true;
            }
        }
    }

    private async Task SubmitEmailCodeAsync()
    {
        if (!string.IsNullOrEmpty(VerificationCode))
        {
            var success = await _authManager.VerifyEmailCodeAsync(VerificationCode);
            if (success)
            {
                ShowEmailVerification = false;
                VerificationCode = "";
                Email = "";
            }
        }
    }

    private void StartMastodonAuth()
    {
        if (!string.IsNullOrEmpty(MastodonInstance))
        {
            var authUrl = _authManager.GetMastodonAuthUrl(MastodonInstance);
            // Open browser for OAuth
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = authUrl,
                UseShellExecute = true
            });
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    protected virtual void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}
