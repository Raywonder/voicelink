using System.Windows.Controls;
using Microsoft.Extensions.DependencyInjection;
using VoiceLinkNative.ViewModels;

namespace VoiceLinkNative.Views;

public partial class SettingsView : Page
{
    public SettingsView()
    {
        InitializeComponent();
        DataContext = App.Services.GetRequiredService<SettingsViewModel>();
    }
}
