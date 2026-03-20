import SwiftUI

@main
struct VoiceLinkiOSApp: App {
    @UIApplicationDelegateAdaptor(IOSPushNotificationManager.self) private var pushDelegate
    @AppStorage("voicelink.serverURL") private var serverURL = "https://voicelink.devinecreations.net"

    var body: some Scene {
        WindowGroup {
            ContentView(serverURL: $serverURL)
                .task {
                    await IOSPushNotificationManager.shared.syncRegistrationIfNeeded()
                }
        }
    }
}
