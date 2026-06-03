using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Net.Http;
using Microsoft.UI.Dispatching;
using SocketIOClient;

namespace VoiceLink_WinUI.Services;

public sealed class VoiceLinkServerClient
{
    public const string MainServerUrl = "https://voicelink.devinecreations.net";
    public const string LocalServerUrl = "http://localhost:3010";

    public static readonly string[] MainServerFallbackUrls =
    {
        MainServerUrl,
        "https://64.20.46.178",
        "https://64.20.46.179"
    };

    private readonly DispatcherQueue _dispatcherQueue;
    private SocketIOClient.SocketIO? _socket;

    public VoiceLinkServerClient(DispatcherQueue dispatcherQueue)
    {
        _dispatcherQueue = dispatcherQueue;
    }

    public event EventHandler<string>? StatusChanged;
    public event EventHandler<string>? MessageReceived;
    public event EventHandler? Connected;
    public event EventHandler? Disconnected;

    public ObservableCollection<ServerItem> Servers { get; } =
    [
        new("Main VoiceLink", MainServerUrl, "Default public VoiceLink server"),
        new("Local VoiceLink", LocalServerUrl, "Local development server")
    ];

    public ObservableCollection<RoomItem> Rooms { get; } = [];
    public string CurrentServerUrl { get; private set; } = MainServerUrl;
    public bool IsConnected => _socket?.Connected ?? false;

    public async Task ConnectToMainServerAsync()
    {
        _ = EnsureLocalApiRunningAsync();
        await ConnectAsync(await ResolveBestMainServerAsync());
    }

    public async Task ConnectToLocalServerAsync()
    {
        _ = EnsureLocalApiRunningAsync();
        await ConnectAsync(LocalServerUrl);
    }

    public async Task ConnectAsync(string serverUrl)
    {
        if (string.IsNullOrWhiteSpace(serverUrl))
        {
            return;
        }

        CurrentServerUrl = serverUrl.TrimEnd('/');
        OnStatusChanged("Connecting");

        if (_socket != null)
        {
            await _socket.DisconnectAsync();
            _socket.Dispose();
        }

        _socket = new SocketIOClient.SocketIO(CurrentServerUrl, new SocketIOOptions
        {
            Reconnection = true,
            ReconnectionAttempts = 10,
            ReconnectionDelay = 1000
        });

        _socket.OnConnected += (_, _) =>
        {
            OnStatusChanged("Connected");
            Connected?.Invoke(this, EventArgs.Empty);
            _ = _socket.EmitAsync("get-rooms");
        };

        _socket.OnDisconnected += (_, _) =>
        {
            OnStatusChanged("Disconnected");
            Disconnected?.Invoke(this, EventArgs.Empty);
        };

        _socket.OnReconnectAttempt += (_, _) => OnStatusChanged("Reconnecting");

        _socket.On("room-list", response =>
        {
            var rooms = response.GetValue<List<RoomItem>>() ?? [];
            _dispatcherQueue.TryEnqueue(() =>
            {
                Rooms.Clear();
                foreach (var room in rooms)
                {
                    Rooms.Add(room);
                }
            });
        });

        _socket.On("joined-room", response =>
        {
            var room = response.GetValue<RoomItem>();
            OnStatusChanged(room is null ? "Joined room" : $"Joined {room.Name}");
        });

        _socket.On("chat-message", response =>
        {
            var message = response.GetValue<MessagePayload>();
            OnMessageReceived(message?.Content ?? message?.Message ?? "New message");
        });

        _socket.On("direct-message", response =>
        {
            var message = response.GetValue<MessagePayload>();
            OnMessageReceived(message?.Content ?? message?.Message ?? "New direct message");
        });

        try
        {
            await _socket.ConnectAsync();
        }
        catch (Exception ex)
        {
            OnStatusChanged($"Connection failed: {ex.Message}");
        }
    }

    public async Task DisconnectAsync()
    {
        if (_socket != null)
        {
            await _socket.DisconnectAsync();
        }
    }

    public async Task RefreshRoomsAsync()
    {
        if (_socket != null)
        {
            await _socket.EmitAsync("get-rooms");
        }
    }

    public async Task JoinRoomAsync(RoomItem room)
    {
        if (_socket != null)
        {
            await _socket.EmitAsync("join-room", new { roomId = room.Id, username = Environment.UserName, userName = Environment.UserName });
        }
    }

    public async Task SendMessageAsync(string roomId, string content)
    {
        if (_socket != null && !string.IsNullOrWhiteSpace(content))
        {
            await _socket.EmitAsync("chat-message", new { roomId, message = content, content, userName = Environment.UserName });
        }
    }

    private void OnStatusChanged(string message)
    {
        _dispatcherQueue.TryEnqueue(() => StatusChanged?.Invoke(this, message));
    }

    private void OnMessageReceived(string message)
    {
        _dispatcherQueue.TryEnqueue(() => MessageReceived?.Invoke(this, message));
    }

    private static async Task<string> ResolveBestMainServerAsync()
    {
        using var httpClient = new HttpClient { Timeout = TimeSpan.FromSeconds(3) };
        foreach (var candidate in MainServerFallbackUrls)
        {
            try
            {
                var response = await httpClient.GetAsync($"{candidate}/api/health");
                if ((int)response.StatusCode < 500)
                {
                    return candidate;
                }
            }
            catch
            {
                // Try the next candidate.
            }
        }

        return MainServerUrl;
    }

    private static async Task EnsureLocalApiRunningAsync()
    {
        if (await IsEndpointReachableAsync(LocalServerUrl))
        {
            return;
        }

        if (TryStartLocalApiProcess())
        {
            for (var i = 0; i < 20; i++)
            {
                if (await IsEndpointReachableAsync(LocalServerUrl))
                {
                    return;
                }

                await Task.Delay(1000);
            }
        }
    }

    private static async Task<bool> IsEndpointReachableAsync(string endpoint)
    {
        using var httpClient = new HttpClient { Timeout = TimeSpan.FromSeconds(3) };
        try
        {
            var response = await httpClient.GetAsync($"{endpoint}/api/health");
            return (int)response.StatusCode < 500;
        }
        catch
        {
            return false;
        }
    }

    private static bool TryStartLocalApiProcess()
    {
        var launch = ResolveLocalApiLaunch();
        if (launch == null)
        {
            return false;
        }

        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = "node",
                Arguments = $"\"{launch.Value.ScriptPath}\"",
                WorkingDirectory = launch.Value.RootPath,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            });
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static (string RootPath, string ScriptPath)? ResolveLocalApiLaunch()
    {
        foreach (var root in CandidateRoots())
        {
            var scriptPath = Path.Combine(root, "server", "routes", "local-server.js");
            if (File.Exists(scriptPath))
            {
                return (root, scriptPath);
            }
        }

        return null;
    }

    private static IEnumerable<string> CandidateRoots()
    {
        yield return AppContext.BaseDirectory;
        var probe = new DirectoryInfo(AppContext.BaseDirectory);
        for (var i = 0; i < 8 && probe != null; i++)
        {
            yield return probe.FullName;
            probe = probe.Parent;
        }

        yield return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "git", "voicelink");
        yield return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "git", "Raywonder", "voicelink");
    }
}

public sealed record ServerItem(string Name, string Url, string Description);

public sealed class RoomItem
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Description { get; set; } = "";
    public int Users { get; set; }
    public int MaxUsers { get; set; } = 50;
    public bool HasPassword { get; set; }
    public string Visibility { get; set; } = "public";
}

public sealed class MessagePayload
{
    public string Content { get; set; } = "";
    public string Message { get; set; } = "";
    public string SenderName { get; set; } = "";
    public string UserName { get; set; } = "";
}
