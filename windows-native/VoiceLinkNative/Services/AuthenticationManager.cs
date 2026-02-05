using System;
using System.ComponentModel;
using System.Net.Http;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;

namespace VoiceLinkNative.Services
{
    public class AuthenticationManager : INotifyPropertyChanged
    {
        private static AuthenticationManager? _instance;
        public static AuthenticationManager Instance => _instance ??= new AuthenticationManager();

        private AuthState _currentState = AuthState.Unauthenticated;
        private AuthenticatedUser? _currentUser;
        private string? _mastodonInstance;
        private string? _mastodonClientId;
        private string? _mastodonClientSecret;
        private string? _pendingEmail;
        private string? _errorMessage;

        public event PropertyChangedEventHandler? PropertyChanged;

        public string? ErrorMessage
        {
            get => _errorMessage;
            private set { _errorMessage = value; OnPropertyChanged(); }
        }

        public enum AuthState
        {
            Unauthenticated,
            Authenticating,
            Authenticated,
            Error
        }

        public AuthState CurrentState
        {
            get => _currentState;
            private set { _currentState = value; OnPropertyChanged(); }
        }

        public AuthenticatedUser? CurrentUser
        {
            get => _currentUser;
            private set { _currentUser = value; OnPropertyChanged(); OnPropertyChanged(nameof(IsAuthenticated)); }
        }

        public bool IsAuthenticated => CurrentState == AuthState.Authenticated;

        public AuthenticationManager()
        {
            _instance = this;
        }

        protected virtual void OnPropertyChanged([CallerMemberName] string? propertyName = null)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        }

        // Get the Mastodon OAuth URL for authentication
        public static string GetMastodonAuthUrl(string instance)
        {
            // Clean instance name
            instance = instance.ToLowerInvariant().Trim();
            if (instance.StartsWith("https://"))
                instance = instance.Substring(8);
            if (instance.StartsWith("http://"))
                instance = instance.Substring(7);

            return $"https://{instance}/oauth/authorize?client_id=voicelink&redirect_uri=voicelink://oauth/callback&response_type=code&scope=read+write";
        }

        // Async version that stores instance for later callback
        public async Task<string?> GetMastodonAuthUrlAsync(string instance)
        {
            try
            {
                // Clean instance name
                _mastodonInstance = instance.ToLowerInvariant().Trim();
                if (_mastodonInstance.StartsWith("https://"))
                    _mastodonInstance = _mastodonInstance.Substring(8);
                if (_mastodonInstance.StartsWith("http://"))
                    _mastodonInstance = _mastodonInstance.Substring(7);

                // TODO: Register OAuth app with instance first if needed
                // For now, return the auth URL directly
                return $"https://{_mastodonInstance}/oauth/authorize?client_id=voicelink&redirect_uri=voicelink://oauth/callback&response_type=code&scope=read+write";
            }
            catch (Exception ex)
            {
                ErrorMessage = ex.Message;
                return null;
            }
        }

        // Handle callback with just the code (uses stored instance)
        public async Task<bool> HandleMastodonCallbackAsync(string code)
        {
            if (string.IsNullOrEmpty(_mastodonInstance))
            {
                ErrorMessage = "No Mastodon instance set";
                return false;
            }
            return await HandleMastodonCallback(_mastodonInstance, code);
        }

        // Authenticate with pairing code
        public async Task<bool> AuthenticateWithPairingCodeAsync(string pairingCode)
        {
            CurrentState = AuthState.Authenticating;

            try
            {
                using var client = new HttpClient();
                var content = new StringContent(
                    JsonSerializer.Serialize(new { code = pairingCode }),
                    Encoding.UTF8,
                    "application/json");

                var response = await client.PostAsync(
                    $"{ServerManager.Instance.ServerUrl}/api/auth/pair",
                    content);

                if (response.IsSuccessStatusCode)
                {
                    var json = await response.Content.ReadAsStringAsync();
                    var result = JsonSerializer.Deserialize<AuthResult>(json);

                    if (result?.Success == true)
                    {
                        CurrentUser = new AuthenticatedUser
                        {
                            Username = result.Username ?? "User",
                            UserId = result.UserId ?? Guid.NewGuid().ToString(),
                            AuthMethod = "pairing"
                        };
                        CurrentState = AuthState.Authenticated;
                        return true;
                    }
                }

                CurrentState = AuthState.Error;
                return false;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Pairing auth error: {ex.Message}");
                CurrentState = AuthState.Error;
                return false;
            }
        }

        // Request email verification code
        public async Task<bool> RequestEmailVerificationAsync(string email)
        {
            CurrentState = AuthState.Authenticating;
            _pendingEmail = email;

            try
            {
                using var client = new HttpClient();
                var content = new StringContent(
                    JsonSerializer.Serialize(new { email }),
                    Encoding.UTF8,
                    "application/json");

                var response = await client.PostAsync(
                    $"{ServerManager.Instance.ServerUrl}/api/auth/email/request",
                    content);

                return response.IsSuccessStatusCode;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Email request error: {ex.Message}");
                CurrentState = AuthState.Unauthenticated;
                return false;
            }
        }

        // Verify email code
        public async Task<bool> VerifyEmailCodeAsync(string code)
        {
            if (string.IsNullOrEmpty(_pendingEmail))
                return false;

            try
            {
                using var client = new HttpClient();
                var content = new StringContent(
                    JsonSerializer.Serialize(new { email = _pendingEmail, code }),
                    Encoding.UTF8,
                    "application/json");

                var response = await client.PostAsync(
                    $"{ServerManager.Instance.ServerUrl}/api/auth/email/verify",
                    content);

                if (response.IsSuccessStatusCode)
                {
                    var json = await response.Content.ReadAsStringAsync();
                    var result = JsonSerializer.Deserialize<AuthResult>(json);

                    if (result?.Success == true)
                    {
                        CurrentUser = new AuthenticatedUser
                        {
                            Username = _pendingEmail,
                            UserId = result.UserId ?? Guid.NewGuid().ToString(),
                            Email = _pendingEmail,
                            AuthMethod = "email"
                        };
                        CurrentState = AuthState.Authenticated;
                        _pendingEmail = null;
                        return true;
                    }
                }

                return false;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Email verify error: {ex.Message}");
                return false;
            }
        }

        // Handle Mastodon OAuth callback
        public async Task<bool> HandleMastodonCallback(string instance, string code)
        {
            CurrentState = AuthState.Authenticating;
            _mastodonInstance = instance;

            try
            {
                using var client = new HttpClient();

                // Exchange code for token
                var tokenContent = new StringContent(
                    JsonSerializer.Serialize(new
                    {
                        client_id = _mastodonClientId ?? "voicelink",
                        client_secret = _mastodonClientSecret ?? "",
                        redirect_uri = "voicelink://oauth/callback",
                        grant_type = "authorization_code",
                        code,
                        scope = "read write"
                    }),
                    Encoding.UTF8,
                    "application/json");

                var tokenResponse = await client.PostAsync(
                    $"https://{instance}/oauth/token",
                    tokenContent);

                if (tokenResponse.IsSuccessStatusCode)
                {
                    var tokenJson = await tokenResponse.Content.ReadAsStringAsync();
                    var tokenResult = JsonSerializer.Deserialize<MastodonTokenResult>(tokenJson);

                    if (!string.IsNullOrEmpty(tokenResult?.AccessToken))
                    {
                        // Get user info
                        client.DefaultRequestHeaders.Authorization =
                            new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", tokenResult.AccessToken);

                        var userResponse = await client.GetAsync(
                            $"https://{instance}/api/v1/accounts/verify_credentials");

                        if (userResponse.IsSuccessStatusCode)
                        {
                            var userJson = await userResponse.Content.ReadAsStringAsync();
                            var userInfo = JsonSerializer.Deserialize<MastodonUser>(userJson);

                            CurrentUser = new AuthenticatedUser
                            {
                                Username = userInfo?.Username ?? "unknown",
                                UserId = userInfo?.Id ?? Guid.NewGuid().ToString(),
                                DisplayName = userInfo?.DisplayName ?? userInfo?.Username ?? "User",
                                MastodonInstance = instance,
                                AccessToken = tokenResult.AccessToken,
                                AuthMethod = "mastodon"
                            };
                            CurrentState = AuthState.Authenticated;
                            return true;
                        }
                    }
                }

                CurrentState = AuthState.Error;
                return false;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Mastodon auth error: {ex.Message}");
                CurrentState = AuthState.Error;
                return false;
            }
        }

        // Logout
        public void Logout()
        {
            CurrentUser = null;
            CurrentState = AuthState.Unauthenticated;
            _mastodonInstance = null;
            _pendingEmail = null;
        }
    }

    public class AuthenticatedUser
    {
        public string Username { get; set; } = "";
        public string UserId { get; set; } = "";
        public string? DisplayName { get; set; }
        public string? Email { get; set; }
        public string? MastodonInstance { get; set; }
        public string? AccessToken { get; set; }
        public string AuthMethod { get; set; } = "";
    }

    public class AuthResult
    {
        public bool Success { get; set; }
        public string? Username { get; set; }
        public string? UserId { get; set; }
        public string? Error { get; set; }
    }

    public class MastodonTokenResult
    {
        [System.Text.Json.Serialization.JsonPropertyName("access_token")]
        public string? AccessToken { get; set; }

        [System.Text.Json.Serialization.JsonPropertyName("token_type")]
        public string? TokenType { get; set; }
    }

    public class MastodonUser
    {
        [System.Text.Json.Serialization.JsonPropertyName("id")]
        public string? Id { get; set; }

        [System.Text.Json.Serialization.JsonPropertyName("username")]
        public string? Username { get; set; }

        [System.Text.Json.Serialization.JsonPropertyName("display_name")]
        public string? DisplayName { get; set; }
    }
}
