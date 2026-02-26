using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Runtime.CompilerServices;
using System.Threading;
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
        private CancellationTokenSource? _domainRecoveryCts;

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
                StartDomainRecoveryMonitor(serverUrl);
                // Request rooms on connect
                _socket.EmitAsync("get-rooms");
            };

            _socket.OnDisconnected += (s, e) =>
            {
                Console.WriteLine("Disconnected from server");
                StopDomainRecoveryMonitor();
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
            _ = EnsureLocalApiRunningAsync();
            var resolvedUrl = await ResolveBestMainServerAsync();
            await ConnectAsync(resolvedUrl);
        }

        public async Task ConnectToLocalServerAsync()
        {
            _ = EnsureLocalApiRunningAsync();
            await ConnectAsync(LocalServerUrl);
        }

        public async Task ConnectToUrlAsync(string url)
        {
            await ConnectAsync(url);
        }

        public async Task EnsureLocalApiRunningAsync()
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

        public void Disconnect()
        {
            _socket?.DisconnectAsync();
            StopDomainRecoveryMonitor();
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
            foreach (var baseUrl in MainServerFallbackUrls)
            {
                var normalized = baseUrl.Trim().TrimEnd('/');
                if (!results.Contains(normalized, StringComparer.OrdinalIgnoreCase))
                {
                    results.Add(normalized);
                }
            }

            if (!string.IsNullOrWhiteSpace(preferred))
            {
                var normalizedPreferred = preferred.Trim().TrimEnd('/');
                if (!results.Contains(normalizedPreferred, StringComparer.OrdinalIgnoreCase))
                {
                    results.Add(normalizedPreferred);
                }
            }

            return results;
        }

        private static async Task<string> ResolveBestMainServerAsync()
        {
            using var httpClient = new HttpClient { Timeout = TimeSpan.FromSeconds(3) };
            var candidates = GetApiBaseCandidates();
            foreach (var candidate in candidates)
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

            await RequestMainServerStartAsync(candidates);

            foreach (var candidate in candidates)
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

        private void StartDomainRecoveryMonitor(string activeServerUrl)
        {
            StopDomainRecoveryMonitor();
            if (!activeServerUrl.StartsWith("https://64.20.46.", StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            _domainRecoveryCts = new CancellationTokenSource();
            var token = _domainRecoveryCts.Token;

            _ = Task.Run(async () =>
            {
                while (!token.IsCancellationRequested)
                {
                    try
                    {
                        await Task.Delay(TimeSpan.FromSeconds(45), token);
                        if (token.IsCancellationRequested)
                        {
                            break;
                        }

                        if (await IsEndpointReachableAsync(MainServerUrl) &&
                            !string.Equals(_serverUrl, MainServerUrl, StringComparison.OrdinalIgnoreCase))
                        {
                            await ConnectAsync(MainServerUrl);
                            break;
                        }
                    }
                    catch (TaskCanceledException)
                    {
                        break;
                    }
                    catch
                    {
                        // Keep retrying.
                    }
                }
            }, token);
        }

        private void StopDomainRecoveryMonitor()
        {
            if (_domainRecoveryCts != null)
            {
                _domainRecoveryCts.Cancel();
                _domainRecoveryCts.Dispose();
                _domainRecoveryCts = null;
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

        private static async Task RequestMainServerStartAsync(IReadOnlyList<string> candidates)
        {
            using var httpClient = new HttpClient { Timeout = TimeSpan.FromSeconds(4) };

            foreach (var baseUrl in candidates)
            {
                var normalized = baseUrl.TrimEnd('/');
                foreach (var path in new[] { "/api/service/voicelink/start", "/api/admin/start" })
                {
                    try
                    {
                        var response = await httpClient.PostAsync($"{normalized}{path}", content: null);
                        if ((int)response.StatusCode < 500)
                        {
                            await Task.Delay(2000);
                            return;
                        }
                    }
                    catch
                    {
                        // Try next endpoint.
                    }
                }
            }
        }

        private static bool TryStartLocalApiProcess()
        {
            var customCommand = Environment.GetEnvironmentVariable("VOICELINK_LOCAL_API_COMMAND");
            if (!string.IsNullOrWhiteSpace(customCommand))
            {
                return StartCommand("cmd.exe", $"/c {customCommand}");
            }

            var launch = ResolveLocalApiLaunch();
            if (launch == null)
            {
                return false;
            }

            var resolvedLaunch = launch.Value;
            return StartCommand("node", $"\"{resolvedLaunch.ScriptPath}\"", resolvedLaunch.RootPath);
        }

        private static (string RootPath, string ScriptPath)? ResolveLocalApiLaunch()
        {
            foreach (var root in CandidateRoots())
            {
                try
                {
                    var scriptPath = Path.Combine(root, "server", "routes", "local-server.js");
                    if (File.Exists(scriptPath))
                    {
                        return (root, scriptPath);
                    }
                }
                catch
                {
                    // Ignore malformed path candidates.
                }
            }

            return null;
        }

        private static IEnumerable<string> CandidateRoots()
        {
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var roots = new List<string>();

            void AddCandidate(string? value)
            {
                if (string.IsNullOrWhiteSpace(value))
                {
                    return;
                }

                var trimmed = value.Trim();
                if (seen.Add(trimmed))
                {
                    roots.Add(trimmed);
                }
            }

            AddCandidate(Environment.GetEnvironmentVariable("VOICELINK_ROOT"));
            AddCandidate(Environment.CurrentDirectory);
            AddCandidate(AppContext.BaseDirectory);

            var probe = new DirectoryInfo(AppContext.BaseDirectory);
            for (var i = 0; i < 8 && probe != null; i++)
            {
                AddCandidate(probe.FullName);
                probe = probe.Parent;
            }

            var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            AddCandidate(Path.Combine(userProfile, "git", "raywonder", "voicelink-main"));
            AddCandidate(Path.Combine(userProfile, "git", "raywonder", "voicelink"));
            AddCandidate(Path.Combine(userProfile, "git", "raywonder", ".github", "voicelink-windows-builder"));

            return roots;
        }

        private static bool StartCommand(string fileName, string arguments, string? workingDirectory = null)
        {
            try
            {
                var startInfo = new ProcessStartInfo
                {
                    FileName = fileName,
                    Arguments = arguments,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden
                };

                if (!string.IsNullOrWhiteSpace(workingDirectory))
                {
                    startInfo.WorkingDirectory = workingDirectory;
                }

                Process.Start(startInfo);
                return true;
            }
            catch
            {
                return false;
            }
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
