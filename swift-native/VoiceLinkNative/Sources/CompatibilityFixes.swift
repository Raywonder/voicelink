import Foundation
import SwiftUI

extension Notification.Name {
    static let serverConfigurationChanged = Notification.Name("serverConfigurationChanged")
    static let roomConfigurationChanged = Notification.Name("roomConfigurationChanged")
}

@MainActor
extension AppState {
    func closeAdminScreen() {
        currentScreen = .mainMenu
    }

    func openHiddenRoom(roomId: String, roomName: String?) {
        currentRoom = Room(
            id: roomId,
            name: roomName ?? "Support Room",
            description: "Private support room",
            userCount: 0,
            isPrivate: true
        )
        minimizedRoom = nil
        focusedRoomId = roomId
        currentScreen = .voiceChat
    }
}

enum HandoffPromptMode: String, CaseIterable, Identifiable {
    case serverRecommended
    case alwaysAsk
    case autoAccept
    case disabled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .serverRecommended: return "Server recommended"
        case .alwaysAsk: return "Always ask"
        case .autoAccept: return "Auto accept"
        case .disabled: return "Disabled"
        }
    }

    var description: String {
        switch self {
        case .serverRecommended:
            return "Use the server recommended handoff behavior."
        case .alwaysAsk:
            return "Prompt before accepting handoff requests."
        case .autoAccept:
            return "Accept trusted handoff requests automatically."
        case .disabled:
            return "Do not allow handoff prompts from this server."
        }
    }
}

struct ManagedFederationServer: Identifiable, Hashable {
    let id: String
    let name: String
    let url: String
    let description: String
}

extension SettingsManager {
    static var managedFederationServers: [ManagedFederationServer] {
        [
            ManagedFederationServer(id: "tappedin", name: "TappedIn", url: "https://voicelink.tappedin.fm", description: "Primary TappedIn VoiceLink federation peer."),
            ManagedFederationServer(id: "devinecreations", name: "Devine Creations", url: "https://voicelink.devinecreations.net", description: "Primary Devine Creations VoiceLink federation peer.")
        ]
    }
}

struct CurrentRoomMediaState {
    var active: Bool
    var streamURL: String
}

extension ServerManager {
    var currentRoomMedia: CurrentRoomMediaState? { nil }
    var isCurrentRoomMediaMuted: Bool { false }
    func stopCurrentRoomMedia() {}
    func toggleCurrentRoomMediaMuted() {}
}

extension LicensingManager {
    func syncEntitlementsFromCurrentUser() async {}
    func refreshForCurrentUser() async {}
}
