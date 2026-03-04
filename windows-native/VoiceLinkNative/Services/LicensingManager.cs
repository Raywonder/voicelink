using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Net.Http;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;

namespace VoiceLinkNative.Services
{
    public class LicensingManager : INotifyPropertyChanged
    {
        private static LicensingManager? _instance;
        public static LicensingManager Instance => _instance ??= new LicensingManager();

        private readonly string _apiBaseUrl;
        private readonly DeviceInfo _deviceInfo;
        private readonly string _deviceId;

        private string? _licenseKey;
        private string _licenseStatus = "unknown";
        private int _activatedDevices;
        private int _maxDevices = 3;
        private int _remainingSlots = 3;
        private bool _activationRequired;
        private bool _isChecking;
        private string? _errorMessage;
        private string? _primaryEmail;
        private string? _lastEvictedDeviceName;
        private string? _latestLicenseNotice;
        private List<ActivatedDevice> _devices = new();
        private List<RecentMachine> _recentMachines = new();

        public event PropertyChangedEventHandler? PropertyChanged;

        public string? LicenseKey { get => _licenseKey; private set => SetProperty(ref _licenseKey, value); }
        public string LicenseStatus { get => _licenseStatus; private set => SetProperty(ref _licenseStatus, value); }
        public int ActivatedDevices { get => _activatedDevices; private set => SetProperty(ref _activatedDevices, value); }
        public int MaxDevices { get => _maxDevices; private set => SetProperty(ref _maxDevices, value); }
        public int RemainingSlots { get => _remainingSlots; private set => SetProperty(ref _remainingSlots, value); }
        public bool ActivationRequired { get => _activationRequired; private set => SetProperty(ref _activationRequired, value); }
        public bool IsChecking { get => _isChecking; private set => SetProperty(ref _isChecking, value); }
        public string? ErrorMessage { get => _errorMessage; private set => SetProperty(ref _errorMessage, value); }
        public string? PrimaryEmail { get => _primaryEmail; private set => SetProperty(ref _primaryEmail, value); }
        public string? LastEvictedDeviceName { get => _lastEvictedDeviceName; private set => SetProperty(ref _lastEvictedDeviceName, value); }
        public string? LatestLicenseNotice { get => _latestLicenseNotice; private set => SetProperty(ref _latestLicenseNotice, value); }
        public IReadOnlyList<ActivatedDevice> Devices => _devices;
        public IReadOnlyList<RecentMachine> RecentMachines => _recentMachines;

        private LicensingManager()
        {
            _instance = this;
            _apiBaseUrl = $"{ServerManager.MainServerUrl.TrimEnd('/')}/api/licensing";
            _deviceInfo = GenerateDeviceInfo();
            _deviceId = GenerateDeviceId(_deviceInfo);
        }

        public async Task SyncEntitlementsFromCurrentUserAsync()
        {
            var identity = CurrentIdentity();
            if (identity == null)
            {
                return;
            }

            try
            {
                await ApiRequestAsync("/sync-entitlements", HttpMethod.Post, new Dictionary<string, object?>
                {
                    ["identity"] = identity.Identity,
                    ["userId"] = identity.UserId,
                    ["username"] = identity.Username,
                    ["displayName"] = identity.DisplayName,
                    ["email"] = identity.Email,
                    ["authProvider"] = identity.AuthProvider,
                    ["authMethod"] = identity.AuthMethod,
                    ["platform"] = _deviceInfo.Platform,
                    ["osVersion"] = _deviceInfo.OsVersion,
                    ["model"] = _deviceInfo.Model
                }, identity.AccessToken);
            }
            catch (Exception ex)
            {
                ErrorMessage = ex.Message;
            }
        }

        public async Task RefreshForCurrentUserAsync()
        {
            var identity = CurrentIdentity();
            if (identity == null)
            {
                Clear();
                return;
            }

            IsChecking = true;
            ErrorMessage = null;

            try
            {
                var result = await ApiRequestAsync(
                    "/me",
                    HttpMethod.Get,
                    new Dictionary<string, object?>
                    {
                        ["identity"] = identity.Identity,
                        ["userId"] = identity.UserId,
                        ["username"] = identity.Username,
                        ["displayName"] = identity.DisplayName,
                        ["email"] = identity.Email,
                        ["authProvider"] = identity.AuthProvider,
                        ["authMethod"] = identity.AuthMethod,
                        ["platform"] = _deviceInfo.Platform,
                        ["osVersion"] = _deviceInfo.OsVersion,
                        ["model"] = _deviceInfo.Model,
                        ["deviceId"] = _deviceId,
                        ["deviceName"] = _deviceInfo.Name
                    },
                    identity.AccessToken);

                ApplyLicenseState(result);
            }
            catch (Exception ex)
            {
                ErrorMessage = ex.Message;
                LicenseStatus = "error";
            }
            finally
            {
                IsChecking = false;
            }
        }

        public async Task<bool> ActivateCurrentDeviceAsync()
        {
            var identity = CurrentIdentity();
            if (identity == null)
            {
                ErrorMessage = "Sign in before activating this device.";
                return false;
            }

            IsChecking = true;
            ErrorMessage = null;

            try
            {
                var result = await ApiRequestAsync("/activate", HttpMethod.Post, new Dictionary<string, object?>
                {
                    ["identity"] = identity.Identity,
                    ["userId"] = identity.UserId,
                    ["username"] = identity.Username,
                    ["displayName"] = identity.DisplayName,
                    ["email"] = identity.Email,
                    ["authProvider"] = identity.AuthProvider,
                    ["authMethod"] = identity.AuthMethod,
                    ["deviceId"] = _deviceId,
                    ["deviceInfo"] = new Dictionary<string, object?>
                    {
                        ["name"] = _deviceInfo.Name,
                        ["platform"] = _deviceInfo.Platform,
                        ["uuid"] = _deviceInfo.Uuid,
                        ["model"] = _deviceInfo.Model,
                        ["osVersion"] = _deviceInfo.OsVersion
                    }
                }, identity.AccessToken);

                ApplyLicenseState(result);
                return true;
            }
            catch (Exception ex)
            {
                ErrorMessage = ex.Message;
                return false;
            }
            finally
            {
                IsChecking = false;
            }
        }

        public void Clear()
        {
            LicenseKey = null;
            LicenseStatus = "unknown";
            ActivatedDevices = 0;
            MaxDevices = 3;
            RemainingSlots = 3;
            ActivationRequired = false;
            PrimaryEmail = null;
            LastEvictedDeviceName = null;
            LatestLicenseNotice = null;
            _devices = new List<ActivatedDevice>();
            _recentMachines = new List<RecentMachine>();
            OnPropertyChanged(nameof(Devices));
            OnPropertyChanged(nameof(RecentMachines));
        }

        private void ApplyLicenseState(JsonElement root)
        {
            string? GetString(string name)
            {
                return root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
                    ? value.GetString()
                    : null;
            }

            int GetInt(string name, int fallback = 0)
            {
                return root.TryGetProperty(name, out var value) && value.TryGetInt32(out var intValue)
                    ? intValue
                    : fallback;
            }

            bool GetBool(string name, bool fallback = false)
            {
                return root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.True
                    ? true
                    : root.TryGetProperty(name, out value) && value.ValueKind == JsonValueKind.False
                        ? false
                        : fallback;
            }

            LicenseKey = GetString("licenseKey") ?? GetString("license") ?? LicenseKey;
            LicenseStatus = GetString("status") ?? (GetBool("licensed") ? "licensed" : LicenseStatus);
            ActivatedDevices = GetInt("activatedDevices", ActivatedDevices);
            MaxDevices = GetInt("maxDevices", MaxDevices);
            RemainingSlots = GetInt("remainingSlots", Math.Max(0, MaxDevices - ActivatedDevices));
            ActivationRequired = GetBool("activationRequired", false);
            PrimaryEmail = GetString("primaryEmail") ?? GetString("email");
            LatestLicenseNotice = GetString("message") ?? GetString("notice");

            if (root.TryGetProperty("lastEvictedDevice", out var evicted) && evicted.ValueKind == JsonValueKind.Object)
            {
                LastEvictedDeviceName = evicted.TryGetProperty("name", out var name) && name.ValueKind == JsonValueKind.String
                    ? name.GetString()
                    : null;
            }
            else
            {
                LastEvictedDeviceName = null;
            }

            if (root.TryGetProperty("devices", out var devices) && devices.ValueKind == JsonValueKind.Array)
            {
                var nextDevices = new List<ActivatedDevice>();
                foreach (var item in devices.EnumerateArray())
                {
                    nextDevices.Add(new ActivatedDevice
                    {
                        Id = item.TryGetProperty("id", out var id) ? id.GetString() ?? Guid.NewGuid().ToString() : Guid.NewGuid().ToString(),
                        Name = item.TryGetProperty("name", out var name) ? name.GetString() ?? "Device" : "Device",
                        Platform = item.TryGetProperty("platform", out var platform) ? platform.GetString() ?? "Unknown" : "Unknown",
                        ActivatedAt = item.TryGetProperty("activatedAt", out var activatedAt) ? activatedAt.GetString() ?? "" : "",
                        LastSeen = item.TryGetProperty("lastSeen", out var lastSeen) ? lastSeen.GetString() ?? "" : ""
                    });
                }
                _devices = nextDevices;
                OnPropertyChanged(nameof(Devices));
            }

            if (root.TryGetProperty("recentMachines", out var machines) && machines.ValueKind == JsonValueKind.Array)
            {
                var nextMachines = new List<RecentMachine>();
                foreach (var item in machines.EnumerateArray())
                {
                    nextMachines.Add(new RecentMachine
                    {
                        Id = item.TryGetProperty("id", out var id) ? id.GetString() ?? Guid.NewGuid().ToString() : Guid.NewGuid().ToString(),
                        Name = item.TryGetProperty("name", out var name) ? name.GetString() ?? "Machine" : "Machine",
                        Platform = item.TryGetProperty("platform", out var platform) ? platform.GetString() ?? "Unknown" : "Unknown",
                        OsVersion = item.TryGetProperty("osVersion", out var osVersion) ? osVersion.GetString() : null,
                        Model = item.TryGetProperty("model", out var model) ? model.GetString() : null,
                        State = item.TryGetProperty("state", out var state) ? state.GetString() ?? "seen" : "seen",
                        LastSeen = item.TryGetProperty("lastSeen", out var lastSeen) ? lastSeen.GetString() ?? "" : "",
                        LastActivatedAt = item.TryGetProperty("lastActivatedAt", out var lastActivatedAt) ? lastActivatedAt.GetString() : null
                    });
                }
                _recentMachines = nextMachines;
                OnPropertyChanged(nameof(RecentMachines));
            }
        }

        private async Task<JsonElement> ApiRequestAsync(string endpoint, HttpMethod method, Dictionary<string, object?> payload, string? accessToken)
        {
            using var client = new HttpClient();
            var builder = new UriBuilder($"{_apiBaseUrl.TrimEnd('/')}{endpoint}");
            HttpContent? content = null;

            if (method == HttpMethod.Get)
            {
                var query = new List<string>();
                foreach (var item in payload)
                {
                    if (item.Value == null) continue;
                    query.Add($"{Uri.EscapeDataString(item.Key)}={Uri.EscapeDataString(Convert.ToString(item.Value) ?? string.Empty)}");
                }
                builder.Query = string.Join("&", query);
            }
            else
            {
                content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json");
            }

            using var request = new HttpRequestMessage(method, builder.Uri);
            if (!string.IsNullOrWhiteSpace(accessToken))
            {
                request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", accessToken);
            }
            request.Headers.TryAddWithoutValidation("X-Client-ID", GetOrCreateClientId());
            if (content != null)
            {
                request.Content = content;
            }

            var response = await client.SendAsync(request);
            var body = await response.Content.ReadAsStringAsync();
            using var document = JsonDocument.Parse(string.IsNullOrWhiteSpace(body) ? "{}" : body);
            var root = document.RootElement.Clone();

            if (!response.IsSuccessStatusCode)
            {
                var message = root.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.String
                    ? error.GetString()
                    : body;
                throw new InvalidOperationException(string.IsNullOrWhiteSpace(message) ? "License request failed." : message);
            }

            return root;
        }

        private LicensingIdentity? CurrentIdentity()
        {
            var user = AuthenticationManager.Instance.CurrentUser;
            if (user == null || string.IsNullOrWhiteSpace(user.UserId))
            {
                return null;
            }

            var email = string.IsNullOrWhiteSpace(user.Email) ? null : user.Email!.Trim();
            var username = string.IsNullOrWhiteSpace(user.Username) ? (email ?? user.UserId) : user.Username.Trim();
            return new LicensingIdentity
            {
                Identity = email ?? username,
                UserId = user.UserId,
                Username = username,
                DisplayName = string.IsNullOrWhiteSpace(user.DisplayName) ? username : user.DisplayName!.Trim(),
                Email = email,
                AuthProvider = string.IsNullOrWhiteSpace(user.AuthProvider) ? user.AuthMethod : user.AuthProvider!,
                AuthMethod = string.IsNullOrWhiteSpace(user.AuthMethod) ? "unknown" : user.AuthMethod,
                AccessToken = user.AccessToken
            };
        }

        private static DeviceInfo GenerateDeviceInfo()
        {
            return new DeviceInfo
            {
                Name = Environment.MachineName,
                Platform = "windows",
                Uuid = GetOrCreateClientId(),
                Model = Environment.OSVersion.Platform.ToString(),
                OsVersion = Environment.OSVersion.VersionString
            };
        }

        private static string GenerateDeviceId(DeviceInfo info)
        {
            var raw = $"{info.Name}|{info.Platform}|{info.Uuid}|{info.Model}|{info.OsVersion}";
            var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(raw));
            return Convert.ToHexString(bytes).ToLowerInvariant();
        }

        private static string GetOrCreateClientId()
        {
            try
            {
                var appDataPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "VoiceLinkNative");
                Directory.CreateDirectory(appDataPath);
                var clientIdPath = Path.Combine(appDataPath, "client-id.txt");
                if (File.Exists(clientIdPath))
                {
                    var existing = File.ReadAllText(clientIdPath).Trim();
                    if (!string.IsNullOrWhiteSpace(existing))
                    {
                        return existing;
                    }
                }

                var generated = $"win_{Guid.NewGuid():N}";
                File.WriteAllText(clientIdPath, generated);
                return generated;
            }
            catch
            {
                return $"win_{Guid.NewGuid():N}";
            }
        }

        private void SetProperty<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
        {
            if (EqualityComparer<T>.Default.Equals(field, value))
            {
                return;
            }

            field = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        }

        private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        }

        private sealed class LicensingIdentity
        {
            public string Identity { get; set; } = "";
            public string UserId { get; set; } = "";
            public string Username { get; set; } = "";
            public string DisplayName { get; set; } = "";
            public string? Email { get; set; }
            public string AuthProvider { get; set; } = "";
            public string AuthMethod { get; set; } = "";
            public string? AccessToken { get; set; }
        }

        private sealed class DeviceInfo
        {
            public string Name { get; set; } = "";
            public string Platform { get; set; } = "";
            public string Uuid { get; set; } = "";
            public string Model { get; set; } = "";
            public string OsVersion { get; set; } = "";
        }

        public sealed class ActivatedDevice
        {
            public string Id { get; set; } = "";
            public string Name { get; set; } = "";
            public string Platform { get; set; } = "";
            public string ActivatedAt { get; set; } = "";
            public string LastSeen { get; set; } = "";
        }

        public sealed class RecentMachine
        {
            public string Id { get; set; } = "";
            public string Name { get; set; } = "";
            public string Platform { get; set; } = "";
            public string? OsVersion { get; set; }
            public string? Model { get; set; }
            public string State { get; set; } = "";
            public string LastSeen { get; set; } = "";
            public string? LastActivatedAt { get; set; }
        }
    }
}
