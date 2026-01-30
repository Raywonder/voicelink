using System.Windows.Controls;
using Microsoft.Extensions.DependencyInjection;
using VoiceLinkNative.ViewModels;

namespace VoiceLinkNative.Views;

public partial class ServersView : Page
{
    public ServersView()
    {
        InitializeComponent();
        DataContext = App.Services.GetRequiredService<ServersViewModel>();
    }
}
