using System.Windows.Controls;
using Microsoft.Extensions.DependencyInjection;
using VoiceLinkNative.ViewModels;

namespace VoiceLinkNative.Views;

public partial class AdminView : Page
{
    private readonly AdminViewModel _viewModel;

    public AdminView()
    {
        InitializeComponent();
        _viewModel = App.Services.GetRequiredService<AdminViewModel>();
        DataContext = _viewModel;

        Loaded += AdminView_Loaded;
    }

    private async void AdminView_Loaded(object sender, System.Windows.RoutedEventArgs e)
    {
        await _viewModel.InitializeAsync();
    }
}
