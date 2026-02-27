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

    private async void RequestEmailCodeButton_Click(object sender, RoutedEventArgs e)
    {
        await _viewModel.RequestEmailCodeAsync();
    }

    private async void VerifyEmailCodeButton_Click(object sender, RoutedEventArgs e)
    {
        await _viewModel.VerifyEmailCodeAsync();
    }

    private async void LoadInviteButton_Click(object sender, RoutedEventArgs e)
    {
        await _viewModel.LoadInviteAsync();
    }

    private async void ActivateInviteButton_Click(object sender, RoutedEventArgs e)
    {
        await _viewModel.ActivateInviteAsync();
    }

    private void InvitePasswordBox_PasswordChanged(object sender, RoutedEventArgs e)
    {
        _viewModel.InvitePassword = InvitePasswordBox.Password;
    }

    private void BackButton_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
        Close();
    }
}
