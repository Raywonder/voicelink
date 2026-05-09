using System;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Drawing;
using System.Diagnostics;
using System.Windows.Threading;
using System.Windows.Interop;
using Microsoft.Extensions.DependencyInjection;
using Forms = System.Windows.Forms;
using VoiceLinkNative.Services;
using VoiceLinkNative.ViewModels;
using VoiceLinkNative.Views;

namespace VoiceLinkNative
{
    public partial class App : System.Windows.Application
    {
        private static IServiceProvider? _services;
        private Forms.NotifyIcon? _trayIcon;
        private bool _allowMinimizeToTray;
        private bool _mainWindowRendered;
        private static readonly string StartupLogPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "VoiceLink",
            "logs",
            "startup.log");
        public static IServiceProvider Services => _services ?? throw new InvalidOperationException("Services not initialized");

        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);
            HookGlobalLogging();
            AppendStartupLog("OnStartup entered.");

            // Configure services
            var serviceCollection = new ServiceCollection();
            ConfigureServices(serviceCollection);
            _services = serviceCollection.BuildServiceProvider();
            AppendStartupLog("Services configured.");

            _ = ServerManager.Instance.EnsureLocalApiRunningAsync();

            MainWindow mainWindow = new MainWindow();
            AppendStartupLog("MainWindow constructed.");
            MainWindow = mainWindow;
            mainWindow.SourceInitialized += (_, _) => AppendStartupLog("MainWindow SourceInitialized.");
            mainWindow.Loaded += (_, _) => AppendStartupLog("MainWindow Loaded.");
            mainWindow.ContentRendered += (_, _) =>
            {
                _mainWindowRendered = true;
                AppendStartupLog("MainWindow ContentRendered.");
            };
            ConfigureTray(mainWindow);
            AppendStartupLog("Tray configured.");
            mainWindow.Show();
            AppendStartupLog($"MainWindow.Show called. Visible={mainWindow.IsVisible} State={mainWindow.WindowState}");
            mainWindow.WindowState = WindowState.Normal;
            if (!mainWindow.IsVisible)
            {
                mainWindow.Show();
                AppendStartupLog("MainWindow.Show called a second time because it was hidden.");
            }
            mainWindow.Activate();
            mainWindow.Topmost = true;
            mainWindow.Topmost = false;
            mainWindow.Focus();
            Dispatcher.BeginInvoke(new Action(() =>
            {
                _allowMinimizeToTray = true;
                AppendStartupLog("ApplicationIdle reached; enabling minimize-to-tray.");
                ShowMainWindow(mainWindow);
            }), DispatcherPriority.ApplicationIdle);
            ScheduleStartupDiagnostics(mainWindow);
        }

        protected override void OnExit(ExitEventArgs e)
        {
            if (_trayIcon is not null)
            {
                _trayIcon.Visible = false;
                _trayIcon.Dispose();
                _trayIcon = null;
            }
            base.OnExit(e);
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

        private void ConfigureTray(MainWindow mainWindow)
        {
            _trayIcon = new Forms.NotifyIcon
            {
                Text = "VoiceLink",
                Icon = SystemIcons.Application,
                Visible = true
            };

            var contextMenu = new Forms.ContextMenuStrip();
            contextMenu.Items.Add("Open VoiceLink", null, (_, _) => ShowMainWindow(mainWindow));
            contextMenu.Items.Add("Exit", null, (_, _) =>
            {
                _trayIcon!.Visible = false;
                Shutdown();
            });
            _trayIcon.ContextMenuStrip = contextMenu;
            _trayIcon.DoubleClick += (_, _) => ShowMainWindow(mainWindow);

            mainWindow.StateChanged += (_, _) =>
            {
                AppendStartupLog($"MainWindow StateChanged: {mainWindow.WindowState}, Visible={mainWindow.IsVisible}");
                if (_allowMinimizeToTray && mainWindow.WindowState == WindowState.Minimized)
                {
                    AppendStartupLog("MainWindow hidden to tray after minimize.");
                    mainWindow.Hide();
                }
            };

            mainWindow.Closing += (_, eventArgs) =>
            {
                AppendStartupLog("MainWindow Closing intercepted.");
                if (ShutdownMode == ShutdownMode.OnMainWindowClose)
                {
                    eventArgs.Cancel = true;
                    mainWindow.Hide();
                    AppendStartupLog("MainWindow hidden instead of closing.");
                }
            };
        }

        private static void ShowMainWindow(MainWindow mainWindow)
        {
            AppendStartupLog($"ShowMainWindow invoked. Visible={mainWindow.IsVisible} State={mainWindow.WindowState}");
            if (!mainWindow.IsVisible)
            {
                mainWindow.Show();
                AppendStartupLog("ShowMainWindow called Show().");
            }
            mainWindow.WindowState = WindowState.Normal;
            mainWindow.Activate();
            mainWindow.Topmost = true;
            mainWindow.Topmost = false;
            mainWindow.Focus();
            AppendStartupLog("ShowMainWindow completed.");
        }

        private void HookGlobalLogging()
        {
            DispatcherUnhandledException += (_, args) =>
            {
                AppendStartupLog($"DispatcherUnhandledException: {args.Exception}");
            };
            AppDomain.CurrentDomain.UnhandledException += (_, args) =>
            {
                AppendStartupLog($"UnhandledException: {args.ExceptionObject}");
            };
        }

        private static void AppendStartupLog(string message)
        {
            try
            {
                var directory = Path.GetDirectoryName(StartupLogPath);
                if (!string.IsNullOrWhiteSpace(directory))
                {
                    Directory.CreateDirectory(directory);
                }
                File.AppendAllText(StartupLogPath, $"{DateTime.Now:O} {message}{Environment.NewLine}");
            }
            catch
            {
                // Logging must never break startup.
            }
        }

        private void ScheduleStartupDiagnostics(MainWindow mainWindow)
        {
            var timer = new DispatcherTimer
            {
                Interval = TimeSpan.FromSeconds(6)
            };
            timer.Tick += async (_, _) =>
            {
                timer.Stop();
                var handle = new WindowInteropHelper(mainWindow).Handle;
                var startupFailed = !_mainWindowRendered || handle == IntPtr.Zero || !mainWindow.IsVisible;
                AppendStartupLog($"Startup diagnostic check. Rendered={_mainWindowRendered} Visible={mainWindow.IsVisible} Handle={handle}");
                if (!startupFailed)
                {
                    return;
                }
                await SubmitStartupFailureReportAsync(mainWindow, handle, _mainWindowRendered);
            };
            timer.Start();
        }

        private static async Task SubmitStartupFailureReportAsync(MainWindow mainWindow, IntPtr handle, bool rendered)
        {
            try
            {
                var logText = File.Exists(StartupLogPath) ? File.ReadAllText(StartupLogPath) : "startup.log missing";
                var process = Process.GetCurrentProcess();
                var processPath = Environment.ProcessPath ?? process.MainModule?.FileName ?? "unknown";
                var machineDetails = new
                {
                    machineName = Environment.MachineName,
                    userName = Environment.UserName,
                    userDomain = Environment.UserDomainName,
                    osVersion = Environment.OSVersion.VersionString,
                    is64BitOperatingSystem = Environment.Is64BitOperatingSystem,
                    is64BitProcess = Environment.Is64BitProcess,
                    processorCount = Environment.ProcessorCount,
                    currentDirectory = Environment.CurrentDirectory,
                    processId = process.Id,
                    sessionId = process.SessionId,
                    processPath,
                    mainWindowHandle = handle.ToInt64(),
                    mainWindowVisible = mainWindow.IsVisible,
                    mainWindowState = mainWindow.WindowState.ToString(),
                    mainWindowRendered = rendered,
                    userInteractive = Environment.UserInteractive
                };
                var payload = new
                {
                    title = "Windows startup UI failure",
                    description = "VoiceLink launched but the main window did not render visibly after startup.",
                    category = "startup",
                    severity = "high",
                    anonymous = false,
                    submittedBy = Environment.UserName,
                    displayName = Environment.UserName,
                    appVersion = System.Reflection.Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "unknown",
                    platform = $"Windows {Environment.OSVersion.VersionString}",
                    currentRoom = (string?)null,
                    diagnosticsSummary = $"windowVisible={mainWindow.IsVisible} rendered={rendered} handle={handle} sessionId={process.SessionId} processPath={processPath}",
                    machineDetails,
                    localMonitorDiagnostics = logText,
                    submittedAt = DateTimeOffset.UtcNow.ToString("O"),
                    recentCrashReports = Array.Empty<string>()
                };

                var json = JsonSerializer.Serialize(payload);
                using var httpClient = new HttpClient
                {
                    Timeout = TimeSpan.FromSeconds(10)
                };
                foreach (var baseUrl in new[]
                {
                    ServerManager.MainServerUrl,
                    ServerManager.LocalServerUrl
                })
                {
                    try
                    {
                        var response = await httpClient.PostAsync(
                            $"{baseUrl.TrimEnd('/')}/api/bugs/submit",
                            new StringContent(json, Encoding.UTF8, "application/json"));
                        AppendStartupLog($"Startup diagnostics submit -> {baseUrl} status={(int)response.StatusCode}");
                        if (response.IsSuccessStatusCode)
                        {
                            return;
                        }
                    }
                    catch (Exception ex)
                    {
                        AppendStartupLog($"Startup diagnostics submit failed for {baseUrl}: {ex.Message}");
                    }
                }
            }
            catch (Exception ex)
            {
                AppendStartupLog($"SubmitStartupFailureReportAsync failed: {ex}");
            }
        }
    }
}
