import Foundation
import SwiftUI
import AppKit

/// VoiceLink URL Handler
/// Handles voicelink:// URLs for deep linking into the app
///
/// URL Formats:
/// - voicelink://join/{roomId}                    - Join a room by ID
/// - voicelink://join/{roomId}?server={url}      - Join room on specific server
/// - voicelink://server/{serverUrl}               - Connect to a server
/// - voicelink://room/{roomId}?action={join|view} - Room with action
/// - voicelink://invite/{code}                    - Join via invite code
/// - voicelink://settings                         - Open settings
/// - voicelink://license                          - Open license view
///
/// Query Parameters:
/// - server: Server URL to connect to
/// - action: join, view, preview
/// - web: true to open in web browser instead
/// - federated: true if this is a federated room
/// - owner: true if user owns this room

@MainActor
class URLHandler: ObservableObject {
    static let shared = URLHandler()

    @Published var pendingURL: URL?
    @Published var pendingAction: URLAction?
    @Published var showWebFallbackPrompt: Bool = false

    // User preferences
    @AppStorage("preferWebForFederated") var preferWebForFederated: Bool = false
    @AppStorage("preferWebForOwned") var preferWebForOwned: Bool = false
    @AppStorage("defaultURLAction") var defaultURLAction: String = "join"

    // Web UI base URL
    let webBaseURL = "https://voicelink.devinecreations.net/client"

    enum URLAction {
        case joinRoom(roomId: String, server: String?)
        case viewRoom(roomId: String, server: String?)
        case connectServer(serverUrl: String)
        case useInvite(code: String)
        case openSettings
        case openLicense
        case openWeb(url: URL)
        case oauthCallback(code: String)
    }

    struct ParsedURL {
        let action: URLAction
        let isFederated: Bool
        let isOwner: Bool
        let preferWeb: Bool
        let originalURL: URL
    }

    private init() {}

    /// Handle incoming URL
    func handleURL(_ url: URL) {
        guard url.scheme == "voicelink" else {
            print("[URLHandler] Invalid scheme: \(url.scheme ?? "nil")")
            return
        }

        print("[URLHandler] Handling URL: \(url)")

        guard let parsed = parseURL(url) else {
            print("[URLHandler] Failed to parse URL")
            return
        }

        // Check if we should use web UI instead
        if shouldUseWebUI(parsed: parsed) {
            openInWebBrowser(parsed: parsed)
            return
        }

        // Execute the action
        executeAction(parsed.action)
    }

    /// Parse a voicelink:// URL
    func parseURL(_ url: URL) -> ParsedURL? {
        guard let host = url.host else { return nil }

        let pathComponents = url.pathComponents.filter { $0 != "/" }
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        // Extract query parameters
        let serverParam = queryItems.first { $0.name == "server" }?.value
        let actionParam = queryItems.first { $0.name == "action" }?.value ?? defaultURLAction
        let webParam = queryItems.first { $0.name == "web" }?.value == "true"
        let federatedParam = queryItems.first { $0.name == "federated" }?.value == "true"
        let ownerParam = queryItems.first { $0.name == "owner" }?.value == "true"

        var action: URLAction?

        switch host.lowercased() {
        case "join":
            // voicelink://join/{roomId}
            if let roomId = pathComponents.first {
                if actionParam == "view" || actionParam == "preview" {
                    action = .viewRoom(roomId: roomId, server: serverParam)
                } else {
                    action = .joinRoom(roomId: roomId, server: serverParam)
                }
            }

        case "room":
            // voicelink://room/{roomId}?action=join
            if let roomId = pathComponents.first {
                if actionParam == "view" || actionParam == "preview" {
                    action = .viewRoom(roomId: roomId, server: serverParam)
                } else {
                    action = .joinRoom(roomId: roomId, server: serverParam)
                }
            }

        case "server":
            // voicelink://server/{encodedServerUrl}
            if let serverUrl = pathComponents.first?.removingPercentEncoding {
                action = .connectServer(serverUrl: serverUrl)
            } else if let serverUrl = serverParam {
                action = .connectServer(serverUrl: serverUrl)
            }

        case "invite":
            // voicelink://invite/{code}
            if let code = pathComponents.first {
                action = .useInvite(code: code)
            }

        case "settings":
            action = .openSettings

        case "license":
            action = .openLicense

        case "oauth":
            // voicelink://oauth/callback?code=xxx
            // Handle OAuth callbacks (Mastodon, etc.)
            if pathComponents.first == "callback",
               let code = queryItems.first(where: { $0.name == "code" })?.value {
                action = .oauthCallback(code: code)
            }

        default:
            // Try treating host as room ID for short URLs
            // voicelink://roomId
            action = .joinRoom(roomId: host, server: serverParam)
        }

        guard let finalAction = action else { return nil }

        return ParsedURL(
            action: finalAction,
            isFederated: federatedParam,
            isOwner: ownerParam,
            preferWeb: webParam,
            originalURL: url
        )
    }

    /// Check if we should open in web browser instead of native app
    func shouldUseWebUI(parsed: ParsedURL) -> Bool {
        // Explicit web preference in URL
        if parsed.preferWeb {
            return true
        }

        // User prefers web for federated rooms
        if parsed.isFederated && preferWebForFederated {
            return true
        }

        // User prefers web for rooms they own
        if parsed.isOwner && preferWebForOwned {
            return true
        }

        return false
    }

    /// Open the URL in web browser
    func openInWebBrowser(parsed: ParsedURL) {
        var webURL: URL?

        switch parsed.action {
        case .joinRoom(let roomId, let server):
            var urlString = "\(webBaseURL)/#/room/\(roomId)"
            if let server = server {
                urlString += "?server=\(server.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? server)"
            }
            webURL = URL(string: urlString)

        case .viewRoom(let roomId, let server):
            var urlString = "\(webBaseURL)/#/room/\(roomId)?action=preview"
            if let server = server {
                urlString += "&server=\(server.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? server)"
            }
            webURL = URL(string: urlString)

        case .connectServer(let serverUrl):
            let encoded = serverUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? serverUrl
            webURL = URL(string: "\(webBaseURL)/?server=\(encoded)")

        case .useInvite(let code):
            webURL = URL(string: "\(webBaseURL)/#/invite/\(code)")

        case .openSettings:
            webURL = URL(string: "\(webBaseURL)/#/settings")

        case .openLicense:
            webURL = URL(string: "https://voicelink.devinecreations.net/license")

        case .oauthCallback(_):
            return // OAuth callbacks are handled natively, not in browser

        case .openWeb(let url):
            webURL = url
        }

        if let url = webURL {
            NSWorkspace.shared.open(url)
        }
    }

    /// Execute an action in the native app
    func executeAction(_ action: URLAction) {
        pendingAction = action

        switch action {
        case .joinRoom(let roomId, let server):
            print("[URLHandler] Joining room: \(roomId) on server: \(server ?? "default")")
            NotificationCenter.default.post(
                name: .urlJoinRoom,
                object: ["roomId": roomId, "server": server as Any]
            )

        case .viewRoom(let roomId, let server):
            print("[URLHandler] Viewing room: \(roomId)")
            NotificationCenter.default.post(
                name: .urlViewRoom,
                object: ["roomId": roomId, "server": server as Any]
            )

        case .connectServer(let serverUrl):
            print("[URLHandler] Connecting to server: \(serverUrl)")
            NotificationCenter.default.post(
                name: .urlConnectServer,
                object: ["serverUrl": serverUrl]
            )

        case .useInvite(let code):
            print("[URLHandler] Using invite code: \(code)")
            NotificationCenter.default.post(
                name: .urlUseInvite,
                object: ["code": code]
            )

        case .openSettings:
            NotificationCenter.default.post(name: .urlOpenSettings, object: nil)

        case .openLicense:
            NotificationCenter.default.post(name: .urlOpenLicense, object: nil)

        case .openWeb(let url):
            NSWorkspace.shared.open(url)

        case .oauthCallback(let code):
            print("[URLHandler] OAuth callback received with code")
            NotificationCenter.default.post(
                name: .oauthCallback,
                object: ["code": code]
            )
        }
    }

    /// Generate a voicelink:// URL for sharing
    static func generateURL(
        roomId: String,
        server: String? = nil,
        action: String = "join",
        isFederated: Bool = false
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "voicelink"
        components.host = "join"
        components.path = "/\(roomId)"

        var queryItems: [URLQueryItem] = []

        if let server = server {
            queryItems.append(URLQueryItem(name: "server", value: server))
        }

        if action != "join" {
            queryItems.append(URLQueryItem(name: "action", value: action))
        }

        if isFederated {
            queryItems.append(URLQueryItem(name: "federated", value: "true"))
        }

        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        return components.url
    }

    /// Generate a web URL for sharing (fallback)
    static func generateWebURL(
        roomId: String,
        server: String? = nil
    ) -> URL? {
        var urlString = "https://voicelink.devinecreations.net/client/#/room/\(roomId)"
        if let server = server {
            urlString += "?server=\(server.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? server)"
        }
        return URL(string: urlString)
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let urlJoinRoom = Notification.Name("urlJoinRoom")
    static let urlViewRoom = Notification.Name("urlViewRoom")
    static let urlConnectServer = Notification.Name("urlConnectServer")
    static let urlUseInvite = Notification.Name("urlUseInvite")
    static let urlOpenSettings = Notification.Name("urlOpenSettings")
    static let urlOpenLicense = Notification.Name("urlOpenLicense")
    static let oauthCallback = Notification.Name("oauthCallback")
}

// MARK: - URL Settings View
struct URLSettingsView: View {
    @ObservedObject var urlHandler = URLHandler.shared

    var body: some View {
        Form {
            Section("Default Actions") {
                Picker("When opening room links:", selection: $urlHandler.defaultURLAction) {
                    Text("Join room").tag("join")
                    Text("Preview room").tag("view")
                }
                .pickerStyle(.radioGroup)
            }

            Section("Web UI Preferences") {
                Toggle("Use web UI for federated rooms", isOn: $urlHandler.preferWebForFederated)
                    .help("Open federated room links in browser instead of native app")

                Toggle("Use web UI for rooms I own", isOn: $urlHandler.preferWebForOwned)
                    .help("Open links to your own rooms in browser for full admin controls")
            }

            Section("Registered URLs") {
                Text("voicelink://join/{roomId}")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("voicelink://server/{serverUrl}")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("voicelink://invite/{code}")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}
