using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace VoiceLink_WinUI.Services;

public sealed class AccessibilityAnnouncer
{
    private readonly NvdaControllerClient? _nvda = NvdaControllerClient.TryCreate();
    private TextBlock? _liveRegion;

    public void AttachLiveRegion(TextBlock liveRegion)
    {
        _liveRegion = liveRegion;
    }

    public void Announce(string message)
    {
        if (string.IsNullOrWhiteSpace(message))
        {
            return;
        }

        _liveRegion ??= new TextBlock();
        _liveRegion.Text = message;

        if (_nvda?.Speak(message) == true)
        {
            return;
        }

        var peer = FrameworkElementAutomationPeer.FromElement(_liveRegion)
            ?? FrameworkElementAutomationPeer.CreatePeerForElement(_liveRegion);

        peer?.RaiseNotificationEvent(
            AutomationNotificationKind.ActionCompleted,
            AutomationNotificationProcessing.ImportantMostRecent,
            message,
            "VoiceLink.Announcement");
    }

    private sealed class NvdaControllerClient
    {
        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        private delegate int NvdaControllerSpeakTextDelegate(
            [MarshalAs(UnmanagedType.LPWStr)] string text);

        private readonly nint _libraryHandle;
        private readonly NvdaControllerSpeakTextDelegate _speakText;

        private NvdaControllerClient(nint libraryHandle, NvdaControllerSpeakTextDelegate speakText)
        {
            _libraryHandle = libraryHandle;
            _speakText = speakText;
        }

        ~NvdaControllerClient()
        {
            if (_libraryHandle != 0)
            {
                NativeLibrary.Free(_libraryHandle);
            }
        }

        public static NvdaControllerClient? TryCreate()
        {
            foreach (var candidate in GetDllCandidates())
            {
                if (!NativeLibrary.TryLoad(candidate, out var handle))
                {
                    continue;
                }

                if (!NativeLibrary.TryGetExport(handle, "nvdaController_speakText", out var speakTextPointer))
                {
                    NativeLibrary.Free(handle);
                    continue;
                }

                var speakText = Marshal.GetDelegateForFunctionPointer<NvdaControllerSpeakTextDelegate>(speakTextPointer);
                return new NvdaControllerClient(handle, speakText);
            }

            return null;
        }

        public bool Speak(string message)
        {
            try
            {
                return _speakText(message) == 0;
            }
            catch
            {
                return false;
            }
        }

        private static IEnumerable<string> GetDllCandidates()
        {
            var baseDirectory = AppContext.BaseDirectory;
            yield return Path.Combine(baseDirectory, "nvdaControllerClient64.dll");
            yield return Path.Combine(baseDirectory, "nvdaController64.dll");
            yield return Path.Combine(baseDirectory, "nvdaController.dll");
            yield return "nvdaControllerClient64.dll";
            yield return "nvdaController64.dll";
            yield return "nvdaController.dll";
        }
    }
}
