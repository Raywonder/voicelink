using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Input;
using CommunityToolkit.Mvvm.Input;
using VoiceLinkNative.Services;

namespace VoiceLinkNative.ViewModels;

public class AdminViewModel : INotifyPropertyChanged
{
    private readonly AdminServerManager _adminManager;

    // Tab navigation
    private string _currentTab = "Overview";
    public string CurrentTab
    {
        get => _currentTab;
        set { _currentTab = value; OnPropertyChanged(); }
    }

    // Status bindings
    public bool IsAdmin => _adminManager.IsAdmin;
    public bool IsLoading => _adminManager.IsLoading;
    public string? ErrorMessage => _adminManager.ErrorMessage;

    // Stats
    public int TotalUsers => _adminManager.TotalUsers;
    public int ActiveRooms => _adminManager.ActiveRooms;
    public int OnlineUsers => _adminManager.OnlineUsers;
    public string UptimeFormatted => FormatUptime(_adminManager.Uptime);

    // Data collections
    public ObservableCollection<AdminUser> Users { get; } = new();
    public ObservableCollection<AdminRoom> Rooms { get; } = new();
    public ObservableCollection<LinkedNode> LinkedNodes { get; } = new();

    // Server config
    public ServerConfig Config => _adminManager.Config;

    // Editable config fields
    private string _serverName = "";
    public string ServerName
    {
        get => _serverName;
        set { _serverName = value; OnPropertyChanged(); }
    }

    private int _maxUsersPerRoom = 50;
    public int MaxUsersPerRoom
    {
        get => _maxUsersPerRoom;
        set { _maxUsersPerRoom = value; OnPropertyChanged(); }
    }

    private bool _allowGuestAccess = true;
    public bool AllowGuestAccess
    {
        get => _allowGuestAccess;
        set { _allowGuestAccess = value; OnPropertyChanged(); }
    }

    private bool _federationEnabled;
    public bool FederationEnabled
    {
        get => _federationEnabled;
        set { _federationEnabled = value; OnPropertyChanged(); }
    }

    // Selected items
    private AdminUser? _selectedUser;
    public AdminUser? SelectedUser
    {
        get => _selectedUser;
        set { _selectedUser = value; OnPropertyChanged(); }
    }

    private AdminRoom? _selectedRoom;
    public AdminRoom? SelectedRoom
    {
        get => _selectedRoom;
        set { _selectedRoom = value; OnPropertyChanged(); }
    }

    private LinkedNode? _selectedNode;
    public LinkedNode? SelectedNode
    {
        get => _selectedNode;
        set { _selectedNode = value; OnPropertyChanged(); }
    }

    // Commands
    public ICommand NavigateTabCommand { get; }
    public ICommand RefreshStatsCommand { get; }
    public ICommand RefreshUsersCommand { get; }
    public ICommand RefreshRoomsCommand { get; }
    public ICommand RefreshNodesCommand { get; }
    public ICommand KickUserCommand { get; }
    public ICommand BanUserCommand { get; }
    public ICommand CloseRoomCommand { get; }
    public ICommand SaveConfigCommand { get; }
    public ICommand RestartNodeCommand { get; }
    public ICommand ScheduleRestartCommand { get; }

    public AdminViewModel(AdminServerManager adminManager)
    {
        _adminManager = adminManager;

        // Subscribe to property changes
        _adminManager.PropertyChanged += (s, e) =>
        {
            OnPropertyChanged(nameof(IsAdmin));
            OnPropertyChanged(nameof(IsLoading));
            OnPropertyChanged(nameof(ErrorMessage));
            OnPropertyChanged(nameof(TotalUsers));
            OnPropertyChanged(nameof(ActiveRooms));
            OnPropertyChanged(nameof(OnlineUsers));
            OnPropertyChanged(nameof(UptimeFormatted));
            OnPropertyChanged(nameof(Config));

            if (e.PropertyName == nameof(AdminServerManager.Users))
                UpdateUsers();
            if (e.PropertyName == nameof(AdminServerManager.Rooms))
                UpdateRooms();
            if (e.PropertyName == nameof(AdminServerManager.LinkedNodes))
                UpdateNodes();
            if (e.PropertyName == nameof(AdminServerManager.Config))
                LoadConfigFields();
        };

        // Initialize commands
        NavigateTabCommand = new RelayCommand<string>(tab => CurrentTab = tab ?? "Overview");
        RefreshStatsCommand = new AsyncRelayCommand(async () => await _adminManager.FetchServerStatsAsync());
        RefreshUsersCommand = new AsyncRelayCommand(async () => await _adminManager.FetchUsersAsync());
        RefreshRoomsCommand = new AsyncRelayCommand(async () => await _adminManager.FetchRoomsAsync());
        RefreshNodesCommand = new AsyncRelayCommand(async () => await _adminManager.FetchLinkedNodesAsync());
        KickUserCommand = new AsyncRelayCommand(KickSelectedUserAsync);
        BanUserCommand = new AsyncRelayCommand(BanSelectedUserAsync);
        CloseRoomCommand = new AsyncRelayCommand(CloseSelectedRoomAsync);
        SaveConfigCommand = new AsyncRelayCommand(SaveConfigAsync);
        RestartNodeCommand = new AsyncRelayCommand(RestartSelectedNodeAsync);
        ScheduleRestartCommand = new AsyncRelayCommand(ScheduleSelectedNodeRestartAsync);
    }

    public async Task InitializeAsync()
    {
        await _adminManager.CheckAdminStatusAsync();
        if (IsAdmin)
        {
            await _adminManager.FetchServerStatsAsync();
            await _adminManager.FetchServerConfigAsync();
        }
    }

    private void UpdateUsers()
    {
        Users.Clear();
        foreach (var user in _adminManager.Users)
        {
            Users.Add(user);
        }
    }

    private void UpdateRooms()
    {
        Rooms.Clear();
        foreach (var room in _adminManager.Rooms)
        {
            Rooms.Add(room);
        }
    }

    private void UpdateNodes()
    {
        LinkedNodes.Clear();
        foreach (var node in _adminManager.LinkedNodes)
        {
            LinkedNodes.Add(node);
        }
    }

    private void LoadConfigFields()
    {
        ServerName = Config.ServerName;
        MaxUsersPerRoom = Config.MaxUsersPerRoom;
        AllowGuestAccess = Config.AllowGuestAccess;
        FederationEnabled = Config.FederationEnabled;
    }

    private async Task KickSelectedUserAsync()
    {
        if (SelectedUser != null)
        {
            await _adminManager.KickUserAsync(SelectedUser.OdId);
            await _adminManager.FetchUsersAsync();
        }
    }

    private async Task BanSelectedUserAsync()
    {
        if (SelectedUser != null)
        {
            await _adminManager.BanUserAsync(SelectedUser.OdId);
            await _adminManager.FetchUsersAsync();
        }
    }

    private async Task CloseSelectedRoomAsync()
    {
        if (SelectedRoom != null)
        {
            await _adminManager.CloseRoomAsync(SelectedRoom.Id);
            await _adminManager.FetchRoomsAsync();
        }
    }

    private async Task SaveConfigAsync()
    {
        var newConfig = new ServerConfig
        {
            ServerName = ServerName,
            MaxUsersPerRoom = MaxUsersPerRoom,
            AllowGuestAccess = AllowGuestAccess,
            FederationEnabled = FederationEnabled,
            MaxRooms = Config.MaxRooms,
            RequireEmailVerification = Config.RequireEmailVerification,
            WelcomeMessage = Config.WelcomeMessage
        };

        await _adminManager.UpdateServerConfigAsync(newConfig);
    }

    private async Task RestartSelectedNodeAsync()
    {
        if (SelectedNode != null)
        {
            await _adminManager.RestartNodeAsync(SelectedNode.NodeId);
        }
    }

    private async Task ScheduleSelectedNodeRestartAsync()
    {
        if (SelectedNode != null)
        {
            await _adminManager.ScheduleNodeRestartAsync(SelectedNode.NodeId, 10);
        }
    }

    private static string FormatUptime(TimeSpan uptime)
    {
        if (uptime.TotalDays >= 1)
            return $"{(int)uptime.TotalDays}d {uptime.Hours}h {uptime.Minutes}m";
        if (uptime.TotalHours >= 1)
            return $"{(int)uptime.TotalHours}h {uptime.Minutes}m";
        return $"{uptime.Minutes}m {uptime.Seconds}s";
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    protected virtual void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}
