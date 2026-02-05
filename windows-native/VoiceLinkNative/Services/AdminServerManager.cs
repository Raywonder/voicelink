using System.ComponentModel;
using System.Net.Http;
using System.Net.Http.Json;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;

namespace VoiceLinkNative.Services;

public class AdminServerManager : INotifyPropertyChanged
{
    private readonly HttpClient _httpClient;
    private string _serverBaseUrl = ServerManager.MainServerUrl;

    private bool _isAdmin;
    public bool IsAdmin
    {
        get => _isAdmin;
        private set { _isAdmin = value; OnPropertyChanged(); }
    }

    private bool _isLoading;
    public bool IsLoading
    {
        get => _isLoading;
        private set { _isLoading = value; OnPropertyChanged(); }
    }

    private string? _errorMessage;
    public string? ErrorMessage
    {
        get => _errorMessage;
        private set { _errorMessage = value; OnPropertyChanged(); }
    }

    // Server Stats
    private int _totalUsers;
    public int TotalUsers
    {
        get => _totalUsers;
        private set { _totalUsers = value; OnPropertyChanged(); }
    }

    private int _activeRooms;
    public int ActiveRooms
    {
        get => _activeRooms;
        private set { _activeRooms = value; OnPropertyChanged(); }
    }

    private int _onlineUsers;
    public int OnlineUsers
    {
        get => _onlineUsers;
        private set { _onlineUsers = value; OnPropertyChanged(); }
    }

    private TimeSpan _uptime;
    public TimeSpan Uptime
    {
        get => _uptime;
        private set { _uptime = value; OnPropertyChanged(); }
    }

    // Data lists
    private List<AdminUser> _users = new();
    public List<AdminUser> Users
    {
        get => _users;
        private set { _users = value; OnPropertyChanged(); }
    }

    private List<AdminRoom> _rooms = new();
    public List<AdminRoom> Rooms
    {
        get => _rooms;
        private set { _rooms = value; OnPropertyChanged(); }
    }

    private ServerConfig _serverConfig = new();
    public ServerConfig Config
    {
        get => _serverConfig;
        private set { _serverConfig = value; OnPropertyChanged(); }
    }

    private List<LinkedNode> _linkedNodes = new();
    public List<LinkedNode> LinkedNodes
    {
        get => _linkedNodes;
        private set { _linkedNodes = value; OnPropertyChanged(); }
    }

    public AdminServerManager()
    {
        _httpClient = new HttpClient();
        _httpClient.Timeout = TimeSpan.FromSeconds(30);
    }

    public void SetServerUrl(string url)
    {
        _serverBaseUrl = url.TrimEnd('/');
    }

    public async Task CheckAdminStatusAsync(string? authToken = null)
    {
        try
        {
            IsLoading = true;

            var request = new HttpRequestMessage(HttpMethod.Get, $"{_serverBaseUrl}/api/admin/status");
            if (!string.IsNullOrEmpty(authToken))
            {
                request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", authToken);
            }

            var response = await _httpClient.SendAsync(request);
            if (response.IsSuccessStatusCode)
            {
                var data = await response.Content.ReadFromJsonAsync<AdminStatusResponse>();
                IsAdmin = data?.IsAdmin ?? false;
            }
            else
            {
                IsAdmin = false;
            }
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Failed to check admin status: {ex.Message}";
            IsAdmin = false;
        }
        finally
        {
            IsLoading = false;
        }
    }

    public async Task FetchServerStatsAsync()
    {
        try
        {
            IsLoading = true;

            var response = await _httpClient.GetAsync($"{_serverBaseUrl}/api/admin/stats");
            if (response.IsSuccessStatusCode)
            {
                var data = await response.Content.ReadFromJsonAsync<ServerStatsResponse>();
                if (data != null)
                {
                    TotalUsers = data.TotalUsers;
                    ActiveRooms = data.ActiveRooms;
                    OnlineUsers = data.OnlineUsers;
                    Uptime = TimeSpan.FromSeconds(data.UptimeSeconds);
                }
            }
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Failed to fetch stats: {ex.Message}";
        }
        finally
        {
            IsLoading = false;
        }
    }

    public async Task FetchUsersAsync()
    {
        try
        {
            IsLoading = true;

            var response = await _httpClient.GetAsync($"{_serverBaseUrl}/api/admin/users");
            if (response.IsSuccessStatusCode)
            {
                var data = await response.Content.ReadFromJsonAsync<List<AdminUser>>();
                Users = data ?? new List<AdminUser>();
            }
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Failed to fetch users: {ex.Message}";
        }
        finally
        {
            IsLoading = false;
        }
    }

    public async Task FetchRoomsAsync()
    {
        try
        {
            IsLoading = true;

            var response = await _httpClient.GetAsync($"{_serverBaseUrl}/api/admin/rooms");
            if (response.IsSuccessStatusCode)
            {
                var data = await response.Content.ReadFromJsonAsync<List<AdminRoom>>();
                Rooms = data ?? new List<AdminRoom>();
            }
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Failed to fetch rooms: {ex.Message}";
        }
        finally
        {
            IsLoading = false;
        }
    }

    public async Task FetchServerConfigAsync()
    {
        try
        {
            IsLoading = true;

            var response = await _httpClient.GetAsync($"{_serverBaseUrl}/api/admin/config");
            if (response.IsSuccessStatusCode)
            {
                var data = await response.Content.ReadFromJsonAsync<ServerConfig>();
                Config = data ?? new ServerConfig();
            }
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Failed to fetch config: {ex.Message}";
        }
        finally
        {
            IsLoading = false;
        }
    }

    public async Task<bool> UpdateServerConfigAsync(ServerConfig config)
    {
        try
        {
            IsLoading = true;

            var json = JsonSerializer.Serialize(config);
            var content = new StringContent(json, Encoding.UTF8, "application/json");

            var response = await _httpClient.PostAsync($"{_serverBaseUrl}/api/admin/config", content);
            if (response.IsSuccessStatusCode)
            {
                Config = config;
                return true;
            }

            var error = await response.Content.ReadAsStringAsync();
            ErrorMessage = $"Failed to update config: {error}";
            return false;
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Failed to update config: {ex.Message}";
            return false;
        }
        finally
        {
            IsLoading = false;
        }
    }

    public async Task<bool> KickUserAsync(string odId, string? reason = null)
    {
        try
        {
            var data = new { odId, reason };
            var json = JsonSerializer.Serialize(data);
            var content = new StringContent(json, Encoding.UTF8, "application/json");

            var response = await _httpClient.PostAsync($"{_serverBaseUrl}/api/admin/users/kick", content);
            return response.IsSuccessStatusCode;
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Failed to kick user: {ex.Message}";
            return false;
        }
    }

    public async Task<bool> BanUserAsync(string odId, string? reason = null, int? duration = null)
    {
        try
        {
            var data = new { odId, reason, duration };
            var json = JsonSerializer.Serialize(data);
            var content = new StringContent(json, Encoding.UTF8, "application/json");

            var response = await _httpClient.PostAsync($"{_serverBaseUrl}/api/admin/users/ban", content);
            return response.IsSuccessStatusCode;
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Failed to ban user: {ex.Message}";
            return false;
        }
    }

    public async Task<bool> CloseRoomAsync(string roomId)
    {
        try
        {
            var data = new { roomId };
            var json = JsonSerializer.Serialize(data);
            var content = new StringContent(json, Encoding.UTF8, "application/json");

            var response = await _httpClient.PostAsync($"{_serverBaseUrl}/api/admin/rooms/close", content);
            return response.IsSuccessStatusCode;
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Failed to close room: {ex.Message}";
            return false;
        }
    }

    // Remote Node Management
    public async Task FetchLinkedNodesAsync()
    {
        try
        {
            IsLoading = true;

            var response = await _httpClient.GetAsync($"{_serverBaseUrl}/api/nodes");
            if (response.IsSuccessStatusCode)
            {
                var data = await response.Content.ReadFromJsonAsync<NodesResponse>();
                LinkedNodes = data?.Nodes ?? new List<LinkedNode>();
            }
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Failed to fetch nodes: {ex.Message}";
        }
        finally
        {
            IsLoading = false;
        }
    }

    public async Task<bool> RestartNodeAsync(string nodeId)
    {
        try
        {
            var response = await _httpClient.PostAsync($"{_serverBaseUrl}/api/nodes/{nodeId}/restart", null);
            return response.IsSuccessStatusCode;
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Failed to restart node: {ex.Message}";
            return false;
        }
    }

    public async Task<bool> ScheduleNodeRestartAsync(string nodeId, int delayMinutes = 10)
    {
        try
        {
            var data = new { delayMinutes, reason = "Scheduled via admin panel" };
            var json = JsonSerializer.Serialize(data);
            var content = new StringContent(json, Encoding.UTF8, "application/json");

            var response = await _httpClient.PostAsync($"{_serverBaseUrl}/api/nodes/{nodeId}/schedule-restart", content);
            return response.IsSuccessStatusCode;
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Failed to schedule restart: {ex.Message}";
            return false;
        }
    }

    public async Task<bool> BroadcastToNodesAsync(string eventName, object data, string? nodeType = null)
    {
        try
        {
            var broadcastData = new { eventName, data, nodeType };
            var json = JsonSerializer.Serialize(broadcastData);
            var content = new StringContent(json, Encoding.UTF8, "application/json");

            var response = await _httpClient.PostAsync($"{_serverBaseUrl}/api/nodes/broadcast", content);
            return response.IsSuccessStatusCode;
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Failed to broadcast: {ex.Message}";
            return false;
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    protected virtual void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}

// Response Models
public class AdminStatusResponse
{
    public bool IsAdmin { get; set; }
    public string? Role { get; set; }
}

public class ServerStatsResponse
{
    public int TotalUsers { get; set; }
    public int ActiveRooms { get; set; }
    public int OnlineUsers { get; set; }
    public double UptimeSeconds { get; set; }
}

public class AdminUser
{
    public string OdId { get; set; } = "";
    public string Username { get; set; } = "";
    public string Email { get; set; } = "";
    public bool IsOnline { get; set; }
    public DateTime? LastSeen { get; set; }
    public string? CurrentRoom { get; set; }
    public bool IsBanned { get; set; }
}

public class AdminRoom
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public int UserCount { get; set; }
    public bool IsPrivate { get; set; }
    public string? Owner { get; set; }
    public DateTime CreatedAt { get; set; }
}

public class ServerConfig
{
    public string ServerName { get; set; } = "VoiceLink Server";
    public int MaxUsersPerRoom { get; set; } = 50;
    public int MaxRooms { get; set; } = 100;
    public bool AllowGuestAccess { get; set; } = true;
    public bool RequireEmailVerification { get; set; } = false;
    public bool FederationEnabled { get; set; } = false;
    public string? WelcomeMessage { get; set; }
}

public class LinkedNode
{
    public string NodeId { get; set; } = "";
    public string Url { get; set; } = "";
    public string Name { get; set; } = "";
    public string Type { get; set; } = "";
    public string Status { get; set; } = "unknown";
    public DateTime? LastSeen { get; set; }
}

public class NodesResponse
{
    public List<LinkedNode> Nodes { get; set; } = new();
}
