using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using System.Windows;
using VoiceLinkNative.Services;

namespace VoiceLinkNative.ViewModels;

public class LoginViewModel : INotifyPropertyChanged
{
    private readonly AuthenticationManager _authManager;
    private string _mastodonInstance = "";
    private string _authorizationCode = "";
    private bool _isLoading;
    private string? _statusMessage;
    private string? _errorMessage;
    private bool _showAuthCodeInput;
    private string? _authUrl;

    public event PropertyChangedEventHandler? PropertyChanged;
    public event EventHandler? LoginCompleted;

    public LoginViewModel()
    {
        _authManager = new AuthenticationManager();
    }

    public string MastodonInstance
    {
        get => _mastodonInstance;
        set
        {
            _mastodonInstance = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(CanLogin));
        }
    }

    public string AuthorizationCode
    {
        get => _authorizationCode;
        set
        {
            _authorizationCode = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(CanCompleteLogin));
        }
    }

    public bool IsLoading
    {
        get => _isLoading;
        set
        {
            _isLoading = value;
            OnPropertyChanged();
        }
    }

    public string? StatusMessage
    {
        get => _statusMessage;
        set
        {
            _statusMessage = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(HasStatusMessage));
        }
    }

    public string? ErrorMessage
    {
        get => _errorMessage;
        set
        {
            _errorMessage = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(HasError));
        }
    }

    public bool ShowAuthCodeInput
    {
        get => _showAuthCodeInput;
        set
        {
            _showAuthCodeInput = value;
            OnPropertyChanged();
        }
    }

    public bool CanLogin => !string.IsNullOrWhiteSpace(MastodonInstance) && !IsLoading;
    public bool CanCompleteLogin => !string.IsNullOrWhiteSpace(AuthorizationCode) && !IsLoading;
    public bool HasStatusMessage => !string.IsNullOrEmpty(StatusMessage);
    public bool HasError => !string.IsNullOrEmpty(ErrorMessage);

    public async Task StartLoginAsync()
    {
        try
        {
            IsLoading = true;
            ErrorMessage = null;
            StatusMessage = "Registering OAuth app with Mastodon instance...";

            // Get the OAuth authorization URL
            _authUrl = await _authManager.GetMastodonAuthUrlAsync(MastodonInstance);

            if (_authUrl == null)
            {
                ErrorMessage = _authManager.ErrorMessage ?? "Failed to start OAuth flow";
                return;
            }

            // Open the authorization URL in the default browser
            StatusMessage = "Opening browser for authorization...";
            Process.Start(new ProcessStartInfo
            {
                FileName = _authUrl,
                UseShellExecute = true
            });

            // Show the authorization code input
            StatusMessage = "Complete the authorization in your browser, then paste the code here.";
            ShowAuthCodeInput = true;
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Login failed: {ex.Message}";
        }
        finally
        {
            IsLoading = false;
        }
    }

    public async Task CompleteLoginAsync()
    {
        try
        {
            IsLoading = true;
            ErrorMessage = null;
            StatusMessage = "Completing authentication...";

            var success = await _authManager.HandleMastodonCallbackAsync(AuthorizationCode);

            if (success)
            {
                StatusMessage = "Login successful!";
                await Task.Delay(500); // Brief delay to show success message
                LoginCompleted?.Invoke(this, EventArgs.Empty);
            }
            else
            {
                ErrorMessage = _authManager.ErrorMessage ?? "Authentication failed";
                StatusMessage = null;
            }
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Authentication failed: {ex.Message}";
            StatusMessage = null;
        }
        finally
        {
            IsLoading = false;
        }
    }

    protected void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}
