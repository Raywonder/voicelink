import SwiftUI

@main
struct VoiceLinkiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(IOSPushNotificationManager.self) private var pushDelegate
    @AppStorage("voicelink.serverURL") private var serverURL = "https://voicelinkapp.app"

    var body: some Scene {
        WindowGroup {
            ContentView(serverURL: $serverURL)
                .onAppear {
                    if scenePhase == .active {
                        IOSLaunchCoordinator.shared.scheduleStartupWorkIfNeeded()
                    }
                }
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .active {
                        IOSLaunchCoordinator.shared.scheduleStartupWorkIfNeeded()
                        IOSLaunchCoordinator.shared.refreshPublicDirectory(reason: "scene-active")
                    }
                }
        }
    }
}

@MainActor
private final class IOSLaunchCoordinator {
    static let shared = IOSLaunchCoordinator()

    private var didScheduleStartupWork = false

    func scheduleStartupWorkIfNeeded() {
        guard !didScheduleStartupWork else { return }
        didScheduleStartupWork = true
        refreshPublicDirectory(reason: "launch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.refreshPublicDirectory(reason: "launch-followup")
        }
    }

    func refreshPublicDirectory(reason: String) {
        NotificationCenter.default.post(name: .iosRefreshPublicDirectory, object: reason)
    }
}
