using System;
using System.Collections.Generic;
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
        private string? _pendingAdminInviteToken;
        private string? _pendingAdminInviteServerUrl;
        private string? _pendingAdminInviteEmail;
        private string? _pendingAdminInviteRole;
        private string? _errorMessage;

        public event PropertyChangedEventHandler? PropertyChanged;

        public string? ErrorMessage
        {
            get => _errorMessage;
            private set { _errorMessage = value; OnPropertyChanged(); }
        }

        public string? PendingAdminInviteToken
        {
            get => _pendingAdminInviteToken;
            private set { _pendingAdminInviteToken = value; OnPropertyChanged(); }
        }

        public string? PendingAdminInviteServerUrl
        {
            get => _pendingAdminInviteServerUrl;
            private set { _pendingAdminInviteServerUrl = value; OnPropertyChanged(); }
        }

        public string? PendingAdminInviteEmail
        {
            get => _pendingAdminInviteEmail;
            private set { _pendingAdminInviteEmail = value; OnPropertyChanged(); }
        }

        public string? PendingAdminInviteRole
        {
            get => _pendingAdminInviteRole;
            private set { _pendingAdminInviteRole = value; OnPropertyChanged(); }
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

        private static string NormalizeServerUrl(string? serverUrl)
        {
            var trimmed = serverUrl?.Trim() ?? "";
            if (string.IsNullOrWhiteSpace(trimmed))
            {
                trimmed = ServerManager.MainServerUrl;
            }

            if (!trimmed.StartsWith("http://", StringComparison.OrdinalIgnoreCase) &&
                !trimmed.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            {
                trimmed = $"https://{trimmed}";
            }

            return trimmed.TrimEnd('/');
        }

        private static bool IsLocalhostUrl(string? serverUrl)
        {
            if (string.IsNullOrWhiteSpace(serverUrl))
            {
                return true;
            }

            return serverUrl.Contains("localhost", StringComparison.OrdinalIgnoreCase) ||
                   serverUrl.Contains("127.0.0.1", StringComparison.OrdinalIgnoreCase);
        }

        private static string GetPreferredServerUrl(string? explicitServerUrl = null)
        {
            if (!string.IsNullOrWhiteSpace(explicitServerUrl))
            {
                return NormalizeServerUrl(explicitServerUrl);
            }

            var active = ServerManager.Instance.ServerUrl;
            if (!IsLocalhostUrl(active))
            {
                return NormalizeServerUrl(active);
            }

            return NormalizeServerUrl(ServerManager.MainServerUrl);
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
            ErrorMessage = null;

            try
            {
                using var client = new HttpClient();
                var content = new StringContent(
                    JsonSerializer.Serialize(new { email }),
                    Encoding.UTF8,
                    "application/json");

                var response = await client.PostAsync(
                    $"{GetPreferredServerUrl()}/api/auth/email/request",
                    content);

                if (response.IsSuccessStatusCode)
                {
                    CurrentState = AuthState.Unauthenticated;
                    return true;
                }

                ErrorMessage = await response.Content.ReadAsStringAsync();
                CurrentState = AuthState.Error;
                return false;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Email request error: {ex.Message}");
                ErrorMessage = ex.Message;
                CurrentState = AuthState.Unauthenticated;
                return false;
            }
        }

        // Verify email code
        public async Task<bool> VerifyEmailCodeAsync(string code)
        {
            if (string.IsNullOrEmpty(_pendingEmail))
            {
                ErrorMessage = "No pending email verification";
                return false;
            }

            try
            {
                using var client = new HttpClient();
                var content = new StringContent(
                    JsonSerializer.Serialize(new { email = _pendingEmail, code }),
                    Encoding.UTF8,
                    "application/json");

                var response = await client.PostAsync(
                    $"{GetPreferredServerUrl()}/api/auth/email/verify",
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

                CurrentState = AuthState.Error;
                ErrorMessage = await response.Content.ReadAsStringAsync();
                return false;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Email verify error: {ex.Message}");
                ErrorMessage = ex.Message;
                CurrentState = AuthState.Error;
                return false;
            }
        }

        public async Task<(bool Success, bool RequiresTwoFactor, string? Error)> SignInWithAccountAsync(
            string identity,
            string password,
            string provider,
            string? serverUrl = null,
            string? twoFactorCode = null)
        {
            var normalizedIdentity = identity?.Trim() ?? "";
            var normalizedPassword = password ?? "";
            if (string.IsNullOrWhiteSpace(normalizedIdentity) || string.IsNullOrEmpty(normalizedPassword))
            {
                return (false, false, "Identity and password are required");
            }

            var normalizedProvider = string.Equals(provider, "whmcs", StringComparison.OrdinalIgnoreCase) ? "whmcs" : "local";
            var resolvedServerUrl = GetPreferredServerUrl(serverUrl);
            CurrentState = AuthState.Authenticating;
            ErrorMessage = null;

            try
            {
                using var client = new HttpClient();
                var payload = new Dictionary<string, object?>
                {
                    ["identity"] = normalizedIdentity,
                    ["password"] = normalizedPassword,
                    ["twoFactorCode"] = string.IsNullOrWhiteSpace(twoFactorCode) ? null : twoFactorCode.Trim()
                };
                if (normalizedProvider == "whmcs")
                {
                    payload["portalSite"] = "devine-creations.com";
                }

                using var content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8);
                content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/json");

                var response = await client.PostAsync(
                    $"{resolvedServerUrl}/api/auth/{normalizedProvider}/login",
                    content);

                var body = await response.Content.ReadAsStringAsync();
                using var document = JsonDocument.Parse(string.IsNullOrWhiteSpace(body) ? "{}" : body);
                var root = document.RootElement;

                if (root.TryGetProperty("requires2FA", out var requires2FAElement) && requires2FAElement.GetBoolean())
                {
                    CurrentState = AuthState.Unauthenticated;
                    ErrorMessage = root.TryGetProperty("error", out var twoFactorError)
                        ? twoFactorError.GetString()
                        : (root.TryGetProperty("message", out var twoFactorMessage) ? twoFactorMessage.GetString() : "Two-factor authentication code required");
                    return (false, true, ErrorMessage);
                }

                var success = root.TryGetProperty("success", out var successElement) && successElement.GetBoolean();
                if (!response.IsSuccessStatusCode || !success)
                {
                    CurrentState = AuthState.Error;
                    ErrorMessage = root.TryGetProperty("error", out var errorElement)
                        ? errorElement.GetString()
                        : (root.TryGetProperty("message", out var messageElement) ? messageElement.GetString() : body);
                    return (false, false, ErrorMessage);
                }

                var userToken = root.TryGetProperty("token", out var tokenElement)
                    ? tokenElement.GetString()
                    : (root.TryGetProperty("accessToken", out var accessTokenElement) ? accessTokenElement.GetString() : null);
                var authMethod = normalizedProvider == "whmcs" ? "whmcs" : "email";
                CurrentUser = ParseAuthenticatedUser(root.TryGetProperty("user", out var userElement) ? userElement : default, userToken, authMethod);
                CurrentState = AuthState.Authenticated;
                return (true, false, null);
            }
            catch (Exception ex)
            {
                CurrentState = AuthState.Error;
                ErrorMessage = ex.Message;
                return (false, false, ex.Message);
            }
        }

        public void StageAdminInvite(string token, string? serverUrl)
        {
            PendingAdminInviteToken = token;
            PendingAdminInviteServerUrl = GetPreferredServerUrl(serverUrl);
            ErrorMessage = null;
        }

        private static AuthenticatedUser ParseAuthenticatedUser(JsonElement userElement, string? accessToken, string authMethod)
        {
            string? GetString(string name)
            {
                return userElement.ValueKind == JsonValueKind.Object && userElement.TryGetProperty(name, out var value)
                    ? value.GetString()
                    : null;
            }

            var user = new AuthenticatedUser
            {
                UserId = GetString("id") ?? Guid.NewGuid().ToString(),
                Username = GetString("username") ?? GetString("email") ?? "user",
                DisplayName = GetString("displayName") ?? GetString("display_name") ?? GetString("username") ?? "User",
                Email = GetString("email"),
                MastodonInstance = GetString("mastodonInstance"),
                AccessToken = GetString("accessToken") ?? GetString("token") ?? accessToken,
                AuthMethod = authMethod,
                AuthProvider = GetString("authProvider"),
                Role = GetString("role")
            };

            if (userElement.ValueKind == JsonValueKind.Object &&
                userElement.TryGetProperty("permissions", out var permissionsElement) &&
                permissionsElement.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in permissionsElement.EnumerateArray())
                {
                    if (item.ValueKind == JsonValueKind.String && item.GetString() is { } permission)
                    {
                        user.Permissions.Add(permission);
                    }
                }
            }

            return user;
        }

        public async Task<bool> FetchAdminInviteAsync(string token, string? serverUrl = null)
        {
            var normalizedToken = token?.Trim();
            if (string.IsNullOrWhiteSpace(normalizedToken))
            {
                ErrorMessage = "Invite token is required";
                return false;
            }

            var resolvedServerUrl = GetPreferredServerUrl(serverUrl);
            PendingAdminInviteToken = normalizedToken;
            PendingAdminInviteServerUrl = resolvedServerUrl;
            ErrorMessage = null;

            try
            {
                using var client = new HttpClient();
                var response = await client.GetAsync(
                    $"{resolvedServerUrl}/api/auth/local/admin-invite/{Uri.EscapeDataString(normalizedToken)}");

                var payload = await response.Content.ReadAsStringAsync();
                if (!response.IsSuccessStatusCode)
                {
                    ErrorMessage = payload;
                    return false;
                }

                using var document = JsonDocument.Parse(payload);
                var root = document.RootElement;

                if (!root.TryGetProperty("success", out var successElement) || !successElement.GetBoolean())
                {
                    ErrorMessage = root.TryGetProperty("error", out var errorElement)
                        ? errorElement.GetString()
                        : "Invite is invalid or expired";
                    return false;
                }

                PendingAdminInviteEmail = root.TryGetProperty("email", out var emailElement)
                    ? emailElement.GetString()
                    : null;
                PendingAdminInviteRole = root.TryGetProperty("role", out var roleElement)
                    ? roleElement.GetString()
                    : null;
                CurrentState = AuthState.Unauthenticated;
                return true;
            }
            catch (Exception ex)
            {
                ErrorMessage = ex.Message;
                return false;
            }
        }

        public async Task<bool> AcceptAdminInviteAsync(
            string token,
            string email,
            string username,
            string displayName,
            string password,
            string? serverUrl = null)
        {
            var normalizedToken = token?.Trim();
            if (string.IsNullOrWhiteSpace(normalizedToken) ||
                string.IsNullOrWhiteSpace(username) ||
                string.IsNullOrWhiteSpace(password))
            {
                ErrorMessage = "Token, username, and password are required";
                return false;
            }

            CurrentState = AuthState.Authenticating;
            ErrorMessage = null;
            var resolvedServerUrl = GetPreferredServerUrl(serverUrl);

            try
            {
                using var client = new HttpClient();
                var content = new StringContent(
                    JsonSerializer.Serialize(new
                    {
                        token = normalizedToken,
                        email = string.IsNullOrWhiteSpace(email) ? null : email.Trim(),
                        username = username.Trim(),
                        displayName = string.IsNullOrWhiteSpace(displayName) ? username.Trim() : displayName.Trim(),
                        password
                    }),
                    Encoding.UTF8,
                    "application/json");

                var response = await client.PostAsync(
                    $"{resolvedServerUrl}/api/auth/local/admin-invite/accept",
                    content);

                var payload = await response.Content.ReadAsStringAsync();
                if (!response.IsSuccessStatusCode)
                {
                    CurrentState = AuthState.Error;
                    ErrorMessage = payload;
                    return false;
                }

                using var document = JsonDocument.Parse(payload);
                var root = document.RootElement;
                if (!root.TryGetProperty("success", out var successElement) || !successElement.GetBoolean())
                {
                    CurrentState = AuthState.Error;
                    ErrorMessage = root.TryGetProperty("error", out var errorElement)
                        ? errorElement.GetString()
                        : "Failed to activate invite";
                    return false;
                }

                var accessToken = root.TryGetProperty("accessToken", out var accessTokenElement)
                    ? accessTokenElement.GetString()
                    : null;
                var user = root.TryGetProperty("user", out var userElement) ? userElement : default;

                CurrentUser = new AuthenticatedUser
                {
                    UserId = user.ValueKind == JsonValueKind.Object && user.TryGetProperty("id", out var idElement)
                        ? idElement.GetString() ?? Guid.NewGuid().ToString()
                        : Guid.NewGuid().ToString(),
                    Username = user.ValueKind == JsonValueKind.Object && user.TryGetProperty("username", out var usernameElement)
                        ? usernameElement.GetString() ?? username.Trim()
                        : username.Trim(),
                    DisplayName = user.ValueKind == JsonValueKind.Object && user.TryGetProperty("displayName", out var displayNameElement)
                        ? displayNameElement.GetString() ?? username.Trim()
                        : (string.IsNullOrWhiteSpace(displayName) ? username.Trim() : displayName.Trim()),
                    Email = user.ValueKind == JsonValueKind.Object && user.TryGetProperty("email", out var emailElement)
                        ? emailElement.GetString() ?? email.Trim()
                        : email.Trim(),
                    AccessToken = accessToken,
                    AuthMethod = "email"
                };

                CurrentState = AuthState.Authenticated;
                PendingAdminInviteToken = null;
                PendingAdminInviteServerUrl = null;
                PendingAdminInviteEmail = null;
                PendingAdminInviteRole = null;
                return true;
            }
            catch (Exception ex)
            {
                CurrentState = AuthState.Error;
                ErrorMessage = ex.Message;
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
            PendingAdminInviteToken = null;
            PendingAdminInviteServerUrl = null;
            PendingAdminInviteEmail = null;
            PendingAdminInviteRole = null;
            ErrorMessage = null;
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
        public string? AuthProvider { get; set; }
        public string? Role { get; set; }
        public List<string> Permissions { get; set; } = new();
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
