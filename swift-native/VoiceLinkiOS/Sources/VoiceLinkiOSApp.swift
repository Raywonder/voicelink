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
                        IOSLaunchCoordinator.shared.scheduleStartupWorkIfNeeded(serverURL: serverURL)
                    }
                }
                .onOpenURL { url in
                    IOSLaunchCoordinator.shared.handleIncomingURL(url)
                }
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .active {
                        IOSLaunchCoordinator.shared.scheduleStartupWorkIfNeeded(serverURL: serverURL)
                        IOSLaunchCoordinator.shared.refreshPublicDirectory(reason: "scene-active")
                    }
                }
        }
    }
}

@MainActor
private final class IOSLaunchCoordinator {
    static let shared = IOSLaunchCoordinator()

    private let automaticDiagnosticsInterval: TimeInterval = 15 * 60
    private var didScheduleStartupWork = false
    private var diagnosticsTimer: Timer?
    private var automaticDiagnosticsServerURL = "https://voicelinkapp.app"

    func scheduleStartupWorkIfNeeded(serverURL: String) {
        startAutomaticDiagnostics(serverURL: serverURL)
        guard !didScheduleStartupWork else { return }
        didScheduleStartupWork = true
        refreshPublicDirectory(reason: "launch")
        IOSDiagnosticsManager.shared.submitFirstLaunchDiagnosticsIfNeeded(serverURL: normalizedBaseURL(serverURL))
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.refreshPublicDirectory(reason: "launch-followup")
            IOSDiagnosticsManager.shared.submitAutomaticDiagnosticsIfDue(
                serverURL: self?.automaticDiagnosticsServerURL ?? "https://voicelinkapp.app",
                reason: "launch-followup",
                minimumInterval: self?.automaticDiagnosticsInterval ?? 900
            )
        }
    }

    func refreshPublicDirectory(reason: String) {
        NotificationCenter.default.post(name: .iosRefreshPublicDirectory, object: reason)
    }

    func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "voicelink" else { return }
        let urlString = url.absoluteString
        let delays: [TimeInterval] = [0, 0.4, 1.2, 2.5]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NotificationCenter.default.post(
                    name: .iosOpenURL,
                    object: nil,
                    userInfo: ["url": urlString]
                )
            }
        }
    }

    private func startAutomaticDiagnostics(serverURL: String) {
        automaticDiagnosticsServerURL = normalizedBaseURL(serverURL)
        if diagnosticsTimer != nil { return }
        diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: automaticDiagnosticsInterval, repeats: true) { _ in
            Task { @MainActor in
                IOSDiagnosticsManager.shared.submitAutomaticDiagnosticsIfDue(
                    serverURL: IOSLaunchCoordinator.shared.automaticDiagnosticsServerURL,
                    reason: "scheduled-active",
                    minimumInterval: IOSLaunchCoordinator.shared.automaticDiagnosticsInterval
                )
            }
        }
    }

    private func normalizedBaseURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            ? trimmed
            : "https://\(trimmed)"
        return withScheme.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }
}

extension Notification.Name {
    static let iosOpenURL = Notification.Name("iosOpenURL")
}
