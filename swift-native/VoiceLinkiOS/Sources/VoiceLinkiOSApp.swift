import SwiftUI

@main
struct VoiceLinkiOSApp: App {
    @AppStorage("voicelink.serverURL") private var serverURL = "https://voicelink.devinecreations.net"

    var body: some Scene {
        WindowGroup {
            ContentView(serverURL: $serverURL)
        }
    }
}
