using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VoiceLink_WinUI.Services;
using VoiceLink_WinUI.ViewModels;

namespace VoiceLink_WinUI;

public sealed partial class MainPage : Page
{
    private readonly AccessibilityAnnouncer _announcer = new();

    public MainViewModel ViewModel { get; }

    public MainPage()
    {
        ViewModel = new MainViewModel(DispatcherQueue, _announcer);
        InitializeComponent();
        _announcer.AttachLiveRegion(LiveRegion);
        Loaded += (_, _) =>
        {
            RootNavigation.SelectedItem = RootNavigation.MenuItems[0];
            ViewModel.AnnounceReady();
        };
    }

    private async void ConnectMain_Click(object sender, RoutedEventArgs e) => await ViewModel.ConnectMainAsync();
    private async void ConnectLocal_Click(object sender, RoutedEventArgs e) => await ViewModel.ConnectLocalAsync();
    private async void ConnectCustom_Click(object sender, RoutedEventArgs e) => await ViewModel.ConnectCustomAsync();
    private async void Disconnect_Click(object sender, RoutedEventArgs e) => await ViewModel.DisconnectAsync();
    private async void RefreshRooms_Click(object sender, RoutedEventArgs e) => await ViewModel.RefreshRoomsAsync();
    private async void JoinRoom_Click(object sender, RoutedEventArgs e) => await ViewModel.JoinSelectedRoomAsync();
    private async void SendMessage_Click(object sender, RoutedEventArgs e) => await ViewModel.SendMessageAsync();

    private async void Server_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ServerItem server)
        {
            ViewModel.ServerUrl = server.Url;
            await ViewModel.ConnectCustomAsync();
        }
    }

    private void RootNavigation_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        var selectedTag = (args.SelectedItem as NavigationViewItem)?.Tag as string ?? "Servers";
        ServersPanel.Visibility = selectedTag == "Servers" ? Visibility.Visible : Visibility.Collapsed;
        RoomsPanel.Visibility = selectedTag == "Rooms" ? Visibility.Visible : Visibility.Collapsed;
        MessagesPanel.Visibility = selectedTag == "Messages" ? Visibility.Visible : Visibility.Collapsed;
        AdminPanel.Visibility = selectedTag == "Admin" ? Visibility.Visible : Visibility.Collapsed;
        SettingsPanel.Visibility = selectedTag == "Settings" ? Visibility.Visible : Visibility.Collapsed;
    }
}
