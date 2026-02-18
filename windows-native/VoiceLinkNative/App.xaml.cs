using System;
using System.Windows;
using Microsoft.Extensions.DependencyInjection;
using VoiceLinkNative.Services;
using VoiceLinkNative.ViewModels;
using VoiceLinkNative.Views;

namespace VoiceLinkNative
{
    public partial class App : Application
    {
        private static IServiceProvider? _services;
        public static IServiceProvider Services => _services ?? throw new InvalidOperationException("Services not initialized");

        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);

            // Configure services
            var serviceCollection = new ServiceCollection();
            ConfigureServices(serviceCollection);
            _services = serviceCollection.BuildServiceProvider();

            MainWindow mainWindow = new MainWindow();
            mainWindow.Show();
        }

        private void ConfigureServices(IServiceCollection services)
        {
            // Services (singletons)
            services.AddSingleton<ServerManager>(ServerManager.Instance);
            services.AddSingleton<AuthenticationManager>(AuthenticationManager.Instance);
            services.AddSingleton<SyncManager>(SyncManager.Instance);
            services.AddSingleton<AdminServerManager>();

            // ViewModels
            services.AddTransient<MainViewModel>();
            services.AddTransient<SettingsViewModel>();
            services.AddTransient<RoomsViewModel>();
            services.AddTransient<ServersViewModel>(sp =>
                new ServersViewModel(
                    sp.GetRequiredService<ServerManager>(),
                    sp.GetRequiredService<AuthenticationManager>()));
            services.AddTransient<AdminViewModel>();
            services.AddTransient<LoginViewModel>();
        }
    }
}
