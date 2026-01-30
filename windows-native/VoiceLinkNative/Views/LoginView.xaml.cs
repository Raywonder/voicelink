using System.Windows;
using VoiceLinkNative.ViewModels;

namespace VoiceLinkNative.Views;

public partial class LoginView : Window
{
    private readonly LoginViewModel _viewModel;

    public LoginView()
    {
        InitializeComponent();
        _viewModel = new LoginViewModel();
        DataContext = _viewModel;

        _viewModel.LoginCompleted += (s, e) =>
        {
            DialogResult = true;
            Close();
        };
    }

    private async void LoginButton_Click(object sender, RoutedEventArgs e)
    {
        await _viewModel.StartLoginAsync();
    }

    private async void CompleteLoginButton_Click(object sender, RoutedEventArgs e)
    {
        await _viewModel.CompleteLoginAsync();
    }

    private void BackButton_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
        Close();
    }
}
