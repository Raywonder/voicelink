using System.Windows.Controls;
using Microsoft.Extensions.DependencyInjection;
using VoiceLinkNative.ViewModels;

namespace VoiceLinkNative.Views;

public partial class RoomsView : Page
{
    public RoomsView()
    {
        InitializeComponent();
        DataContext = App.Services.GetRequiredService<RoomsViewModel>();
    }
}
