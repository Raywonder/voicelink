using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using Microsoft.UI.Dispatching;
using VoiceLink_WinUI.Services;

namespace VoiceLink_WinUI.ViewModels;

public sealed class MainViewModel : INotifyPropertyChanged
{
    private readonly VoiceLinkServerClient _serverClient;
    private readonly AccessibilityAnnouncer _announcer;
    private string _status = "Online, waiting for a connection";
    private string _serverUrl = VoiceLinkServerClient.MainServerUrl;
    private string _messageText = "";
    private RoomItem? _selectedRoom;

    public MainViewModel(DispatcherQueue dispatcherQueue, AccessibilityAnnouncer announcer)
    {
        _announcer = announcer;
        _serverClient = new VoiceLinkServerClient(dispatcherQueue);
        _serverClient.StatusChanged += (_, message) =>
        {
            Status = message;
            _announcer.Announce(message);
        };
        _serverClient.MessageReceived += (_, message) =>
        {
            Messages.Add(message);
            _announcer.Announce(message);
        };
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public ObservableCollection<ServerItem> Servers => _serverClient.Servers;
    public ObservableCollection<RoomItem> Rooms => _serverClient.Rooms;
    public ObservableCollection<string> Messages { get; } = [];

    public string Status
    {
        get => _status;
        private set => SetProperty(ref _status, value);
    }

    public string ServerUrl
    {
        get => _serverUrl;
        set => SetProperty(ref _serverUrl, value);
    }

    public string MessageText
    {
        get => _messageText;
        set => SetProperty(ref _messageText, value);
    }

    public RoomItem? SelectedRoom
    {
        get => _selectedRoom;
        set => SetProperty(ref _selectedRoom, value);
    }

    public async Task ConnectMainAsync() => await _serverClient.ConnectToMainServerAsync();
    public async Task ConnectLocalAsync() => await _serverClient.ConnectToLocalServerAsync();
    public async Task ConnectCustomAsync() => await _serverClient.ConnectAsync(ServerUrl);
    public async Task DisconnectAsync() => await _serverClient.DisconnectAsync();
    public async Task RefreshRoomsAsync() => await _serverClient.RefreshRoomsAsync();

    public async Task JoinSelectedRoomAsync()
    {
        if (SelectedRoom == null)
        {
            _announcer.Announce("Choose a room first");
            return;
        }

        await _serverClient.JoinRoomAsync(SelectedRoom);
    }

    public async Task SendMessageAsync()
    {
        if (SelectedRoom == null)
        {
            _announcer.Announce("Choose a room before sending a message");
            return;
        }

        await _serverClient.SendMessageAsync(SelectedRoom.Id, MessageText);
        MessageText = "";
    }

    public void AnnounceReady()
    {
        _announcer.Announce(Status);
    }

    private void SetProperty<T>(ref T field, T value, [CallerMemberName] string propertyName = "")
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return;
        }

        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}
