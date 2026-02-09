using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Net.Http;
using System.Runtime.CompilerServices;
using SocketIOClient;

namespace VoiceLinkNative.Services
{
    public class ServerManager : INotifyPropertyChanged
    {
        private static ServerManager? _instance;
        public static ServerManager Instance => _instance ??= new ServerManager();

        private SocketIOClient.SocketIO? _socket;
        private string _serverUrl = "http://localhost:3010";
        private string _connectedServer = "";
        private string _serverStatus = "Disconnected";

        public const string MainServerUrl = "https://voicelink.devinecreations.net";
        public const string LocalServerUrl = "http://localhost:3010";
        public static readonly string[] MainServerFallbackUrls =
        {
            MainServerUrl,
            "https://64.20.46.178",
            "https://64.20.46.179"
        };

        public event EventHandler<SyncPushData>? SyncPushReceived;
        public event EventHandler? Connected;
        public event EventHandler? Disconnected;
        public event EventHandler? Reconnecting;
        public event PropertyChangedEventHandler? PropertyChanged;

        public bool IsConnected => _socket?.Connected ?? false;
        public string ServerUrl => _serverUrl;

        public string ConnectedServer
        {
            get => _connectedServer;
            private set { _connectedServer = value; OnPropertyChanged(); }
        }

        public string ServerStatus
        {
            get => _serverStatus;
            private set { _serverStatus = value; OnPropertyChanged(); }
        }

        public ObservableCollection<RoomInfo> Rooms { get; } = new();

        public ServerManager()
        {
            _instance = this;
        }

        protected virtual void OnPropertyChanged([CallerMemberName] string? propertyName = null)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        }

        public async Task ConnectAsync(string serverUrl)
        {
            _serverUrl = serverUrl;
            ServerStatus = "Connecting...";

            if (_socket != null)
            {
                await _socket.DisconnectAsync();
                _socket.Dispose();
            }

            _socket = new SocketIOClient.SocketIO(serverUrl, new SocketIOOptions
            {
                Reconnection = true,
                ReconnectionAttempts = 10,
                ReconnectionDelay = 1000
            });

            _socket.OnConnected += (s, e) =>
            {
                Console.WriteLine("Connected to server");
                ServerStatus = "Connected";
                ConnectedServer = serverUrl;
                OnPropertyChanged(nameof(IsConnected));
                Connected?.Invoke(this, EventArgs.Empty);
                // Request rooms on connect
                _socket.EmitAsync("get-rooms");
            };

            _socket.OnDisconnected += (s, e) =>
            {
                Console.WriteLine("Disconnected from server");
                ServerStatus = "Disconnected";
                OnPropertyChanged(nameof(IsConnected));
                Disconnected?.Invoke(this, EventArgs.Empty);
            };

            _socket.OnReconnectAttempt += (s, e) =>
            {
                Console.WriteLine("Reconnecting to server...");
                ServerStatus = "Reconnecting...";
                Reconnecting?.Invoke(this, EventArgs.Empty);
            };

            _socket.On("room-list", response =>
            {
                var rooms = response.GetValue<List<RoomInfo>>();
                System.Windows.Application.Current.Dispatcher.Invoke(() =>
                {
                    Rooms.Clear();
                    foreach (var room in rooms)
                    {
                        Rooms.Add(room);
                    }
                });
            });

            _socket.On("sync-push", response =>
            {
                var data = response.GetValue<SyncPushData>();
                SyncPushReceived?.Invoke(this, data);
            });

            await _socket.ConnectAsync();
        }

        public async Task ConnectToMainServerAsync()
        {
            var resolvedUrl = await ResolveBestMainServerAsync();
            await ConnectAsync(resolvedUrl);
        }

        public async Task ConnectToLocalServerAsync()
        {
            await ConnectAsync(LocalServerUrl);
        }

        public async Task ConnectToUrlAsync(string url)
        {
            await ConnectAsync(url);
        }

        public void Disconnect()
        {
            _socket?.DisconnectAsync();
            ServerStatus = "Disconnected";
            ConnectedServer = "";
            OnPropertyChanged(nameof(IsConnected));
        }

        public async Task DisconnectAsync()
        {
            if (_socket != null)
            {
                await _socket.DisconnectAsync();
            }
        }

        public async Task JoinRoom(string roomId, string? password = null)
        {
            if (_socket == null) return;
            await _socket.EmitAsync("join-room", new { roomId, password });
        }

        public async Task LeaveRoom(string roomId)
        {
            if (_socket == null) return;
            await _socket.EmitAsync("leave-room", new { roomId });
        }

        public async Task SendMessage(string roomId, string message, string? targetUserId = null)
        {
            if (_socket == null) return;
            await _socket.EmitAsync("chat-message", new { roomId, message, targetUserId });
        }

        public async Task RefreshRooms()
        {
            if (_socket == null) return;
            await _socket.EmitAsync("get-rooms");
        }

        public static void OnReconnecting()
        {
            Console.WriteLine("Reconnecting to server...");
        }

        public static void OnConnected()
        {
            Console.WriteLine("Connected to server");
        }

        public static IReadOnlyList<string> GetApiBaseCandidates(string? preferred = null)
        {
            var results = new List<string>();
            if (!string.IsNullOrWhiteSpace(preferred))
            {
                results.Add(preferred.Trim().TrimEnd('/'));
            }

            foreach (var baseUrl in MainServerFallbackUrls)
            {
                var normalized = baseUrl.Trim().TrimEnd('/');
                if (!results.Contains(normalized, StringComparer.OrdinalIgnoreCase))
                {
                    results.Add(normalized);
                }
            }

            return results;
        }

        private static async Task<string> ResolveBestMainServerAsync()
        {
            using var httpClient = new HttpClient { Timeout = TimeSpan.FromSeconds(3) };
            foreach (var candidate in GetApiBaseCandidates())
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
                    // Try next candidate.
                }
            }

            return MainServerUrl;
        }
    }

    public class RoomInfo
    {
        public string Id { get; set; } = "";
        public string Name { get; set; } = "";
        public string Description { get; set; } = "";
        public int Users { get; set; }
        public int MaxUsers { get; set; } = 50;
        public bool HasPassword { get; set; }
        public string Visibility { get; set; } = "public";
        public bool VisibleToGuests { get; set; } = true;
        public bool IsDefault { get; set; }
        public bool Locked { get; set; }
    }
}
