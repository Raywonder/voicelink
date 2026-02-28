using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using VoiceLinkNative.Services;

namespace VoiceLinkNative.ViewModels;

public class LoginViewModel : INotifyPropertyChanged
{
    private readonly AuthenticationManager _authManager;
    private string _mastodonInstance = "";
    private string _authorizationCode = "";
    private string _accountProvider = "local";
    private string _accountIdentity = "";
    private string _accountPassword = "";
    private string _accountTwoFactorCode = "";
    private string _email = "";
    private string _verificationCode = "";
    private string _inviteToken = "";
    private string _inviteServerUrl = ServerManager.MainServerUrl;
    private string _inviteEmail = "";
    private string _inviteUsername = "";
    private string _inviteDisplayName = "";
    private string _invitePassword = "";
    private bool _isLoading;
    private string? _statusMessage;
    private string? _errorMessage;
    private bool _showAuthCodeInput;
    private bool _showAccountTwoFactorInput;
    private bool _showEmailCodeInput;
    private bool _showInviteActivation;
    private string? _authUrl;

    public event PropertyChangedEventHandler? PropertyChanged;
    public event EventHandler? LoginCompleted;

    public LoginViewModel()
    {
        _authManager = AuthenticationManager.Instance;
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

    public string AccountProvider
    {
        get => _accountProvider;
        set
        {
            _accountProvider = value;
            OnPropertyChanged();
        }
    }

    public string AccountIdentity
    {
        get => _accountIdentity;
        set
        {
            _accountIdentity = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(CanAccountSignIn));
        }
    }

    public string AccountPassword
    {
        get => _accountPassword;
        set
        {
            _accountPassword = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(CanAccountSignIn));
        }
    }

    public string AccountTwoFactorCode
    {
        get => _accountTwoFactorCode;
        set
        {
            _accountTwoFactorCode = value;
            OnPropertyChanged();
        }
    }

    public string Email
    {
        get => _email;
        set
        {
            _email = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(CanRequestEmailCode));
        }
    }

    public string VerificationCode
    {
        get => _verificationCode;
        set
        {
            _verificationCode = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(CanVerifyEmailCode));
        }
    }

    public string InviteToken
    {
        get => _inviteToken;
        set
        {
            _inviteToken = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(CanLoadInvite));
            OnPropertyChanged(nameof(CanActivateInvite));
        }
    }

    public string InviteServerUrl
    {
        get => _inviteServerUrl;
        set
        {
            _inviteServerUrl = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(CanLoadInvite));
            OnPropertyChanged(nameof(CanActivateInvite));
        }
    }

    public string InviteEmail
    {
        get => _inviteEmail;
        set
        {
            _inviteEmail = value;
            OnPropertyChanged();
        }
    }

    public string InviteUsername
    {
        get => _inviteUsername;
        set
        {
            _inviteUsername = value;
            OnPropertyChanged();
            if (string.IsNullOrWhiteSpace(InviteDisplayName))
            {
                InviteDisplayName = value;
            }
            OnPropertyChanged(nameof(CanActivateInvite));
        }
    }

    public string InviteDisplayName
    {
        get => _inviteDisplayName;
        set
        {
            _inviteDisplayName = value;
            OnPropertyChanged();
        }
    }

    public string InvitePassword
    {
        get => _invitePassword;
        set
        {
            _invitePassword = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(CanActivateInvite));
        }
    }

    public bool IsLoading
    {
        get => _isLoading;
        set
        {
            _isLoading = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(CanLogin));
            OnPropertyChanged(nameof(CanAccountSignIn));
            OnPropertyChanged(nameof(CanCompleteLogin));
            OnPropertyChanged(nameof(CanRequestEmailCode));
            OnPropertyChanged(nameof(CanVerifyEmailCode));
            OnPropertyChanged(nameof(CanLoadInvite));
            OnPropertyChanged(nameof(CanActivateInvite));
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

    public bool ShowEmailCodeInput
    {
        get => _showEmailCodeInput;
        set
        {
            _showEmailCodeInput = value;
            OnPropertyChanged();
        }
    }

    public bool ShowInviteActivation
    {
        get => _showInviteActivation;
        set
        {
            _showInviteActivation = value;
            OnPropertyChanged();
        }
    }

    public bool ShowAccountTwoFactorInput
    {
        get => _showAccountTwoFactorInput;
        set
        {
            _showAccountTwoFactorInput = value;
            OnPropertyChanged();
        }
    }

    public bool CanLogin => !string.IsNullOrWhiteSpace(MastodonInstance) && !IsLoading;
    public bool CanAccountSignIn => !string.IsNullOrWhiteSpace(AccountIdentity) && !string.IsNullOrWhiteSpace(AccountPassword) && !IsLoading;
    public bool CanCompleteLogin => !string.IsNullOrWhiteSpace(AuthorizationCode) && !IsLoading;
    public bool CanRequestEmailCode => !string.IsNullOrWhiteSpace(Email) && !IsLoading;
    public bool CanVerifyEmailCode => !string.IsNullOrWhiteSpace(VerificationCode) && !IsLoading;
    public bool CanLoadInvite => !string.IsNullOrWhiteSpace(InviteToken) && !string.IsNullOrWhiteSpace(InviteServerUrl) && !IsLoading;
    public bool CanActivateInvite =>
        !string.IsNullOrWhiteSpace(InviteToken) &&
        !string.IsNullOrWhiteSpace(InviteServerUrl) &&
        !string.IsNullOrWhiteSpace(InviteUsername) &&
        InvitePassword.Length >= 8 &&
        !IsLoading;
    public bool HasStatusMessage => !string.IsNullOrEmpty(StatusMessage);
    public bool HasError => !string.IsNullOrEmpty(ErrorMessage);

    public async Task StartLoginAsync()
    {
        try
        {
            IsLoading = true;
            ErrorMessage = null;
            StatusMessage = "Opening Mastodon authorization...";

            _authUrl = await _authManager.GetMastodonAuthUrlAsync(MastodonInstance);
            if (_authUrl == null)
            {
                ErrorMessage = _authManager.ErrorMessage ?? "Failed to start OAuth flow";
                StatusMessage = null;
                return;
            }

            Process.Start(new ProcessStartInfo
            {
                FileName = _authUrl,
                UseShellExecute = true
            });

            StatusMessage = "Authorize in your browser, then paste the code here.";
            ShowAuthCodeInput = true;
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Login failed: {ex.Message}";
            StatusMessage = null;
        }
        finally
        {
            IsLoading = false;
        }
    }

    public async Task SignInWithAccountAsync()
    {
        try
        {
            IsLoading = true;
            ErrorMessage = null;
            StatusMessage = ShowAccountTwoFactorInput ? "Verifying 2FA..." : "Signing in...";

            var result = await _authManager.SignInWithAccountAsync(
                AccountIdentity,
                AccountPassword,
                AccountProvider,
                null,
                ShowAccountTwoFactorInput ? AccountTwoFactorCode : null);

            if (result.Success)
            {
                StatusMessage = "Login successful.";
                await Task.Delay(300);
                LoginCompleted?.Invoke(this, EventArgs.Empty);
                return;
            }

            if (result.RequiresTwoFactor)
            {
                ShowAccountTwoFactorInput = true;
                StatusMessage = result.Error ?? "Two-factor authentication code required.";
                return;
            }

            ErrorMessage = result.Error ?? _authManager.ErrorMessage ?? "Account sign-in failed";
            StatusMessage = null;
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Account sign-in failed: {ex.Message}";
            StatusMessage = null;
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
            StatusMessage = "Completing Mastodon authentication...";

            var success = await _authManager.HandleMastodonCallbackAsync(AuthorizationCode);
            if (success)
            {
                StatusMessage = "Login successful.";
                await Task.Delay(300);
                LoginCompleted?.Invoke(this, EventArgs.Empty);
                return;
            }

            ErrorMessage = _authManager.ErrorMessage ?? "Authentication failed";
            StatusMessage = null;
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

    public async Task RequestEmailCodeAsync()
    {
        try
        {
            IsLoading = true;
            ErrorMessage = null;
            StatusMessage = "Sending verification code...";

            var success = await _authManager.RequestEmailVerificationAsync(Email);
            if (success)
            {
                ShowEmailCodeInput = true;
                StatusMessage = "Check your email for the verification code.";
                return;
            }

            ErrorMessage = _authManager.ErrorMessage ?? "Failed to send verification code";
            StatusMessage = null;
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Email sign-in failed: {ex.Message}";
            StatusMessage = null;
        }
        finally
        {
            IsLoading = false;
        }
    }

    public async Task VerifyEmailCodeAsync()
    {
        try
        {
            IsLoading = true;
            ErrorMessage = null;
            StatusMessage = "Verifying code...";

            var success = await _authManager.VerifyEmailCodeAsync(VerificationCode);
            if (success)
            {
                StatusMessage = "Email login successful.";
                await Task.Delay(300);
                LoginCompleted?.Invoke(this, EventArgs.Empty);
                return;
            }

            ErrorMessage = _authManager.ErrorMessage ?? "Verification failed";
            StatusMessage = null;
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Verification failed: {ex.Message}";
            StatusMessage = null;
        }
        finally
        {
            IsLoading = false;
        }
    }

    public async Task LoadInviteAsync()
    {
        try
        {
            IsLoading = true;
            ErrorMessage = null;
            StatusMessage = "Loading admin invite...";

            var success = await _authManager.FetchAdminInviteAsync(InviteToken, InviteServerUrl);
            if (success)
            {
                ShowInviteActivation = true;
                InviteEmail = _authManager.PendingAdminInviteEmail ?? InviteEmail;
                StatusMessage = $"Invite loaded for {_authManager.PendingAdminInviteRole ?? "admin"} access.";
                return;
            }

            ErrorMessage = _authManager.ErrorMessage ?? "Invite is invalid or expired";
            StatusMessage = null;
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Invite load failed: {ex.Message}";
            StatusMessage = null;
        }
        finally
        {
            IsLoading = false;
        }
    }

    public async Task ActivateInviteAsync()
    {
        try
        {
            IsLoading = true;
            ErrorMessage = null;
            StatusMessage = "Activating admin invite...";

            var success = await _authManager.AcceptAdminInviteAsync(
                InviteToken,
                InviteEmail,
                InviteUsername,
                string.IsNullOrWhiteSpace(InviteDisplayName) ? InviteUsername : InviteDisplayName,
                InvitePassword,
                InviteServerUrl);

            if (success)
            {
                StatusMessage = "Admin invite activated.";
                await Task.Delay(300);
                LoginCompleted?.Invoke(this, EventArgs.Empty);
                return;
            }

            ErrorMessage = _authManager.ErrorMessage ?? "Activation failed";
            StatusMessage = null;
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Invite activation failed: {ex.Message}";
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
