import SwiftUI

@main
struct VoiceLinkiOSApp: App {
    @AppStorage("voicelink.serverURL") private var serverURL = "https://voicelink.devinecreations.net"
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(serverURL: $serverURL)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                IOSDiagnosticsManager.shared.markSceneActive()
            case .background:
                IOSDiagnosticsManager.shared.markSceneBackground()
            default:
                break
            }
        }
    }
}
