import SwiftUI
import UIKit
import UserNotifications
import AVFoundation

struct ContentView: View {
    @Binding var serverURL: String
    @State private var selectedTab: Tab = .servers
    @StateObject private var roomState = IOSRoomMessagingState()
    @State private var showProfile = false

    var body: some View {
        TabView(selection: $selectedTab) {
            ServersTab(serverURL: $serverURL, roomState: roomState, openProfile: { showProfile = true })
                .tabItem {
                    Label("Servers", systemImage: "server.rack")
                }
                .tag(Tab.servers)

            SettingsTab(roomState: roomState, openServers: { selectedTab = .servers })
                .tabItem {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
                .tag(Tab.settings)
        }
        .onReceive(NotificationCenter.default.publisher(for: .iosOpenMessagesTab)) { notification in
            roomState.handleOpenMessagesRequest(notification.userInfo)
            showProfile = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .iosShowUserProfile)) { notification in
            roomState.handleProfileRequest(notification.userInfo)
            showProfile = true
        }
        .sheet(isPresented: $showProfile) {
            MessagesTab(serverURL: $serverURL, roomState: roomState, openServers: { selectedTab = .servers })
        }
    }
}

private enum Tab {
    case servers
    case settings
}

private enum ServerScreenTab: String, CaseIterable, Identifiable {
    case servers
    case federation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .servers: return "Servers"
        case .federation: return "Federated Rooms"
        }
    }
}

struct IOSDirectMessageTarget: Identifiable, Hashable {
    let id: String
    let name: String
    var isMuted: Bool = false
    var isDeafened: Bool = false
    var isSpeaking: Bool = false
    var transmitEnabled: Bool = true
    var isBot: Bool = false
    var hasAudioControls: Bool = true
    var deviceName: String = ""
    var deviceType: String = ""
    var clientVersion: String = ""
    var botType: String = ""
    var statusMessage: String = ""
    var authProvider: String = ""
    var role: String = ""
}

struct IOSRoomMessageItem: Identifiable, Hashable {
    let id: String
    let roomId: String
    let roomName: String
    let author: String
    let body: String
    let type: String
    let timestamp: Date

    var isSystemMessage: Bool {
        type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "system"
            || author.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "system"
    }

    var isBotMessage: Bool {
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedType == "bot"
            || normalizedAuthor.contains("bot")
            || normalizedAuthor == "sapphire"
            || normalizedAuthor == "sophia"
            || normalizedAuthor == "voicelink"
    }
}

struct IOSRoomTranscriptItem: Identifiable, Hashable {
    let id: String
    let roomId: String
    let roomName: String
    let speaker: String
    let body: String
    let timestamp: Date
}

@MainActor
final class IOSRoomMessagingState: ObservableObject {
    @Published var isInRoom = false
    @Published var activeRoomId = ""
    @Published var activeRoomName = ""
    @Published var roomMessages: [IOSRoomMessageItem] = []
    @Published var roomTranscripts: [IOSRoomTranscriptItem] = []
    @Published var directTargets: [IOSDirectMessageTarget] = []
    @Published var selectedDirectTarget: IOSDirectMessageTarget?
    @Published var selectedProfileName: String?
    @Published var statusText = ""
    private let announcementManager = IOSRoomAnnouncementManager.shared
    private var recentSystemMessageKeys: [String: Date] = [:]

    init() {
        NotificationCenter.default.addObserver(
            forName: .iosRoomJoined,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleRoomJoined(notification.userInfo)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .iosRoomLeft,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleRoomLeft(notification.userInfo)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .iosRoomUsersUpdated,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleRoomUsers(notification.userInfo)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .iosRoomMessageEvent,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleRoomMessage(notification.userInfo)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .iosDirectMessageEvent,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleDirectMessage(notification.userInfo)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .iosRoomTranscriptEvent,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleRoomTranscript(notification.userInfo)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .iosRoomUserJoined,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleRoomUserJoined(notification.userInfo)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .iosRoomUserLeft,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleRoomUserLeft(notification.userInfo)
            }
        }
    }

    func requestLeaveActiveRoom() {
        guard isInRoom else { return }
        NotificationCenter.default.post(
            name: .iosRequestLeaveRoom,
            object: nil,
            userInfo: ["roomId": activeRoomId]
        )
    }

    func sendDirectMessage(_ text: String) {
        guard isInRoom else {
            statusText = "Join a room first to send direct messages."
            return
        }
        guard let target = selectedDirectTarget else {
            statusText = "Select a user first."
            return
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        NotificationCenter.default.post(
            name: .iosSendDirectMessage,
            object: nil,
            userInfo: [
                "roomId": activeRoomId,
                "roomName": activeRoomName,
                "userId": target.id,
                "userName": target.name,
                "body": body
            ]
        )
        statusText = "Sent to \(target.name)."
    }

    func handleOpenMessagesRequest(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        if let roomId = info["roomId"] as? String, !roomId.isEmpty {
            activeRoomId = roomId
        }
        if let roomName = info["roomName"] as? String, !roomName.isEmpty {
            activeRoomName = roomName
        }
        if let userId = info["userId"] as? String, !userId.isEmpty {
            let userName = (info["userName"] as? String ?? "User")
            selectedDirectTarget = IOSDirectMessageTarget(id: userId, name: userName)
            upsertDirectTarget(selectedDirectTarget!)
        }
    }

    func handleProfileRequest(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        if let userName = info["userName"] as? String, !userName.isEmpty {
            selectedProfileName = userName
            statusText = "Profile viewed: \(userName)"
        }
    }

    private func handleRoomJoined(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        let roomId = (info["roomId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let roomName = (info["roomName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let switchingRooms = !activeRoomId.isEmpty
            && !roomId.isEmpty
            && normalizedIOSRoomIdentity(activeRoomId) != normalizedIOSRoomIdentity(roomId)
        if switchingRooms {
            directTargets.removeAll()
            roomMessages.removeAll()
        }
        if !roomId.isEmpty {
            activeRoomId = roomId
            isInRoom = true
            roomTranscripts.removeAll()
        }
        if !roomName.isEmpty {
            activeRoomName = roomName
        }
        statusText = roomName.isEmpty ? "Joined room." : "Joined \(roomName)."
        appendSystemRoomMessage(
            roomId: roomId.isEmpty ? activeRoomId : roomId,
            roomName: roomName.isEmpty ? activeRoomName : roomName,
            body: roomName.isEmpty ? "You joined the room." : "You joined \(roomName)."
        )
        let seededUsers = iosUsersArray(from: info)
        if !seededUsers.isEmpty {
            handleRoomUsers([
                "roomId": roomId.isEmpty ? activeRoomId : roomId,
                "users": seededUsers
            ])
        } else if let joinedUser = iosUserDictionary(from: info["user"]) {
            handleRoomUsers([
                "roomId": roomId.isEmpty ? activeRoomId : roomId,
                "users": [joinedUser]
            ])
        } else {
            let displayName = normalizedIOSSocketValue(info["displayName"], fallback: "")
            if !displayName.isEmpty {
                handleRoomUsers([
                    "roomId": roomId.isEmpty ? activeRoomId : roomId,
                    "users": [[
                        "id": "local:\(displayName.lowercased())",
                        "userId": "local:\(displayName.lowercased())",
                        "name": displayName,
                        "displayName": displayName,
                        "deviceName": UIDevice.current.name,
                        "deviceType": "ios"
                    ]]
                ])
            }
        }
        for message in iosMessagesArray(from: info) {
            handleRoomMessage(message)
        }
    }

    private func handleRoomLeft(_ info: [AnyHashable: Any]?) {
        let roomId = (info?["roomId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if roomId.isEmpty || roomId == activeRoomId {
            let previousRoomId = activeRoomId
            let previousRoomName = activeRoomName
            isInRoom = false
            activeRoomId = ""
            activeRoomName = ""
            selectedDirectTarget = nil
            statusText = "Left room."
            appendSystemRoomMessage(
                roomId: previousRoomId,
                roomName: previousRoomName,
                body: previousRoomName.isEmpty ? "You left the room." : "You left \(previousRoomName)."
            )
            roomTranscripts.removeAll()
            directTargets.removeAll()
        }
    }

    private func handleRoomUsers(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        let roomId = normalizedIOSSocketValue(info["roomId"], fallback: activeRoomId)
        let roomName = normalizedIOSSocketValue(
            info["roomName"] ?? (info["room"] as? [String: Any])?["name"] ?? (info["room"] as? NSDictionary)?["name"],
            fallback: activeRoomName
        )
        if activeRoomId.isEmpty, !roomId.isEmpty {
            activeRoomId = roomId
            isInRoom = true
        }
        let roomMatchesActive = roomId.isEmpty
            || activeRoomId.isEmpty
            || normalizedIOSRoomIdentity(roomId) == normalizedIOSRoomIdentity(activeRoomId)
            || (!roomName.isEmpty && normalizedIOSRoomIdentity(roomName) == normalizedIOSRoomIdentity(activeRoomName))
        guard roomMatchesActive else { return }
        let rawUsers = iosUsersArray(from: info)
        guard !rawUsers.isEmpty || !directTargets.isEmpty else { return }
        let mapped = rawUsers.enumerated().compactMap { index, entry -> IOSDirectMessageTarget? in
            let user = iosUserDictionary(from: entry) ?? [:]
            guard !user.isEmpty else { return nil }
            let id = normalizedIOSSocketValue(user["id"] ?? user["userId"], fallback: "")
            let rawName = normalizedIOSSocketValue(
                user["name"] ?? user["userName"] ?? user["displayName"] ?? user["username"],
                fallback: ""
            )
            let resolvedId = id.isEmpty
                ? "\(roomId.isEmpty ? activeRoomId : roomId)|\(rawName.isEmpty ? "user-\(index)" : rawName.lowercased())"
                : id
            let fallbackName = resolvedId.count > 8 ? "User \(resolvedId.prefix(8))" : "User \(resolvedId)"
            let name = rawName.isEmpty ? fallbackName : rawName
            return IOSDirectMessageTarget(
                id: resolvedId,
                name: name,
                isMuted: (user["muted"] as? Bool) ?? (user["isMuted"] as? Bool) ?? false,
                isDeafened: (user["deafened"] as? Bool) ?? (user["isDeafened"] as? Bool) ?? false,
                isSpeaking: (user["speaking"] as? Bool) ?? (user["isSpeaking"] as? Bool) ?? false,
                transmitEnabled: (user["transmitEnabled"] as? Bool) ?? true,
                isBot: (user["isBot"] as? Bool) ?? false,
                hasAudioControls: (user["hasAudioControls"] as? Bool) ?? ((user["isBot"] as? Bool) != true),
                deviceName: normalizedIOSSocketValue(user["deviceName"], fallback: ""),
                deviceType: normalizedIOSSocketValue(user["deviceType"], fallback: ""),
                clientVersion: normalizedIOSSocketValue(user["clientVersion"], fallback: ""),
                botType: normalizedIOSSocketValue(user["botType"], fallback: ""),
                statusMessage: normalizedIOSSocketValue(user["statusMessage"], fallback: ""),
                authProvider: normalizedIOSSocketValue(user["authProvider"], fallback: ""),
                role: normalizedIOSSocketValue(user["role"], fallback: "")
            )
        }
        if mapped.isEmpty, isInRoom, !directTargets.isEmpty {
            return
        }
        var stabilizedMapped = mapped
        let mappedHasHumanUsers = stabilizedMapped.contains { !$0.isBot }
        if isInRoom && !mappedHasHumanUsers {
            for existing in directTargets where !existing.isBot {
                if !stabilizedMapped.contains(where: { $0.id == existing.id || $0.name.caseInsensitiveCompare(existing.name) == .orderedSame }) {
                    stabilizedMapped.append(existing)
                }
            }
        }
        if isInRoom || !mapped.isEmpty {
            directTargets = stabilizedMapped.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        } else {
            for target in stabilizedMapped {
                upsertDirectTarget(target)
            }
        }
        if let selected = selectedDirectTarget, !directTargets.contains(selected) {
            selectedDirectTarget = directTargets.first
        }
        if isInRoom {
            let humanCount = directTargets.filter { !$0.isBot }.count
            let botCount = directTargets.filter(\.isBot).count
            if humanCount > 0 || botCount > 0 {
                var parts: [String] = []
                if humanCount > 0 {
                    parts.append("\(humanCount) \(humanCount == 1 ? "person" : "people")")
                }
                if botCount > 0 {
                    parts.append("\(botCount) \(botCount == 1 ? "bot" : "bots")")
                }
                statusText = "\(parts.joined(separator: ", ")) in the room."
            }
        }
    }

    private func handleRoomUserJoined(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        let roomId = normalizedIOSSocketValue(info["roomId"], fallback: activeRoomId)
        let roomName = normalizedIOSSocketValue(info["roomName"], fallback: activeRoomName)
        let roomMatchesActive = activeRoomId.isEmpty
            || normalizedIOSRoomIdentity(roomId) == normalizedIOSRoomIdentity(activeRoomId)
            || (!roomName.isEmpty && normalizedIOSRoomIdentity(roomName) == normalizedIOSRoomIdentity(activeRoomName))
        guard roomMatchesActive || (activeRoomId.isEmpty && !roomId.isEmpty) else { return }
        if activeRoomId.isEmpty, !roomId.isEmpty {
            activeRoomId = roomId
            isInRoom = true
        }
        if let user = iosUserDictionary(from: info["user"]) {
            let mapped = mapIOSRoomUser(user, roomId: roomId, index: directTargets.count)
            upsertDirectTarget(mapped)
            statusText = "\(mapped.name) joined \(activeRoomName.isEmpty ? "the room" : activeRoomName)."
            appendSystemRoomMessage(
                roomId: roomId.isEmpty ? activeRoomId : roomId,
                roomName: roomName.isEmpty ? activeRoomName : roomName,
                body: "\(mapped.name) joined the room."
            )
            if !mapped.isBot {
                announcementManager.announce("\(mapped.name) joined the room.")
            }
        }
    }

    private func handleRoomUserLeft(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        let roomId = normalizedIOSSocketValue(info["roomId"], fallback: activeRoomId)
        let roomName = normalizedIOSSocketValue(info["roomName"], fallback: activeRoomName)
        let roomMatchesActive = roomId.isEmpty
            || normalizedIOSRoomIdentity(roomId) == normalizedIOSRoomIdentity(activeRoomId)
            || (!roomName.isEmpty && normalizedIOSRoomIdentity(roomName) == normalizedIOSRoomIdentity(activeRoomName))
        guard roomMatchesActive else { return }
        let userId = normalizedIOSSocketValue(info["userId"], fallback: "")
        let userName = normalizedIOSSocketValue(info["userName"], fallback: "User")
        if !userId.isEmpty {
            directTargets.removeAll { $0.id == userId }
        } else if !userName.isEmpty {
            directTargets.removeAll { $0.name.caseInsensitiveCompare(userName) == .orderedSame }
        }
        statusText = "\(userName) left \(activeRoomName.isEmpty ? "the room" : activeRoomName)."
        appendSystemRoomMessage(
            roomId: roomId.isEmpty ? activeRoomId : roomId,
            roomName: roomName.isEmpty ? activeRoomName : roomName,
            body: "\(userName) left the room."
        )
        announcementManager.announce("\(userName) left the room.")
    }

    private func handleRoomMessage(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        let incomingRoomId = normalizedIOSSocketValue(info["roomId"], fallback: "")
        let roomName = normalizedIOSSocketValue(info["roomName"], fallback: activeRoomName)
        let roomId = incomingRoomId.isEmpty ? activeRoomId : incomingRoomId
        let senderId = normalizedIOSSocketValue(info["userId"], fallback: "")
        let author = normalizedIOSSocketValue(
            info["author"] ?? info["userName"] ?? info["senderName"] ?? info["botName"] ?? info["name"],
            fallback: "User"
        )
        let body = normalizedIOSSocketValue(
            info["body"] ?? info["message"] ?? info["content"] ?? info["text"],
            fallback: ""
        )
        let incomingType = normalizedIOSSocketValue(info["type"], fallback: "")
        let type = incomingType.isEmpty && (info["isBot"] as? Bool) == true ? "bot" : (incomingType.isEmpty ? "text" : incomingType)
        let ts = normalizedIOSMessageTimestamp(info["timestamp"])
        let roomMatchesActive = activeRoomId.isEmpty
            || normalizedIOSRoomIdentity(roomId) == normalizedIOSRoomIdentity(activeRoomId)
            || (!roomName.isEmpty && normalizedIOSRoomIdentity(roomName) == normalizedIOSRoomIdentity(activeRoomName))
        guard !roomId.isEmpty, !body.isEmpty, roomMatchesActive else { return }
        if shouldSuppressRepeatedSystemMessage(
            roomId: roomId,
            author: author.isEmpty ? "User" : author,
            body: body,
            type: type.isEmpty ? "text" : type
        ) {
            return
        }
        if roomMessages.contains(where: {
            normalizedIOSRoomIdentity($0.roomId) == normalizedIOSRoomIdentity(roomId)
                && $0.author.caseInsensitiveCompare(author.isEmpty ? "User" : author) == .orderedSame
                && $0.body == body
                && $0.type.caseInsensitiveCompare(type.isEmpty ? "text" : type) == .orderedSame
                && abs($0.timestamp.timeIntervalSince1970 - ts) < 2
        }) {
            return
        }
        if ((info["isBot"] as? Bool) == true || type == "bot" || type == "system"), !senderId.isEmpty {
            upsertDirectTarget(
                IOSDirectMessageTarget(
                    id: senderId,
                    name: author.isEmpty ? "System" : author,
                    isMuted: false,
                    isDeafened: false,
                    isSpeaking: false,
                    transmitEnabled: false,
                    isBot: true,
                    hasAudioControls: false,
                    deviceName: type == "system" ? "Server" : "VoiceLink",
                    deviceType: "bot",
                    clientVersion: "",
                    botType: type == "system" ? "system" : "text",
                    statusMessage: type == "system" ? "Server system message." : "Use direct message or mentions to interact.",
                    authProvider: type == "system" ? "system" : "voicelink_bot",
                    role: type == "system" ? "system" : "bot"
                )
            )
            if activeRoomId.isEmpty {
                activeRoomId = roomId
            }
        }
        roomMessages.append(
            IOSRoomMessageItem(
                id: UUID().uuidString,
                roomId: roomId,
                roomName: roomName.isEmpty ? "Room" : roomName,
                author: author.isEmpty ? "User" : author,
                body: body,
                type: type.isEmpty ? "text" : type,
                timestamp: Date(timeIntervalSince1970: ts)
            )
        )
        if roomMessages.count > 400 {
            roomMessages = Array(roomMessages.suffix(400))
        }
        if type.caseInsensitiveCompare("text") == .orderedSame,
           !isLikelyLocalMessage(author: author, senderId: senderId) {
            IOSActionSoundPlayer.playMessageReceived()
        }
        let isActiveRoomMessage = normalizedIOSRoomIdentity(roomId) == normalizedIOSRoomIdentity(activeRoomId)
        let isLocalMessage = isLikelyLocalMessage(author: author, senderId: senderId)
        if isActiveRoomMessage, !isLocalMessage {
            if type.caseInsensitiveCompare("system") == .orderedSame || type.caseInsensitiveCompare("bot") == .orderedSame {
                announcementManager.announceSystemMessage(body, author: author)
            } else {
                announcementManager.announceRoomMessage(body, author: author)
            }
        }
    }

    private func appendSystemRoomMessage(roomId: String, roomName: String, body: String) {
        let resolvedRoomId = roomId.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedRoomId.isEmpty, !resolvedBody.isEmpty else { return }
        handleRoomMessage([
            "roomId": resolvedRoomId,
            "roomName": roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Room" : roomName,
            "author": "System",
            "body": resolvedBody,
            "type": "system",
            "timestamp": Date().timeIntervalSince1970
        ])
    }

    private func shouldSuppressRepeatedSystemMessage(roomId: String, author: String, body: String, type: String) -> Bool {
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedType == "system" || normalizedAuthor == "system" else { return false }

        let now = Date()
        recentSystemMessageKeys = recentSystemMessageKeys.filter { now.timeIntervalSince($0.value) < 90 }
        let normalizedBody = body
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
        guard !normalizedBody.isEmpty else { return false }

        let key = [
            normalizedIOSRoomIdentity(roomId),
            normalizedAuthor.isEmpty ? "system" : normalizedAuthor,
            normalizedBody
        ].joined(separator: "|")
        if let lastSeen = recentSystemMessageKeys[key], now.timeIntervalSince(lastSeen) < 45 {
            return true
        }
        recentSystemMessageKeys[key] = now
        return false
    }

    private func handleDirectMessage(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        let userId = normalizedIOSSocketValue(info["userId"], fallback: "")
        let userName = normalizedIOSSocketValue(info["userName"], fallback: "User")
        guard !userId.isEmpty else { return }
        let target = IOSDirectMessageTarget(id: userId, name: userName.isEmpty ? "User" : userName)
        upsertDirectTarget(target)
        if !isLikelyLocalMessage(author: userName, senderId: userId) {
            IOSActionSoundPlayer.playMessageReceived()
        }
        if selectedDirectTarget == nil {
            selectedDirectTarget = target
        }
    }

    private func handleRoomTranscript(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        let incomingRoomId = normalizedIOSSocketValue(info["roomId"], fallback: "")
        let roomName = normalizedIOSSocketValue(info["roomName"], fallback: activeRoomName)
        let roomId = incomingRoomId.isEmpty ? activeRoomId : incomingRoomId
        let speaker = normalizedIOSSocketValue(
            info["speaker"] ?? info["userName"] ?? info["author"],
            fallback: "Speaker"
        )
        let body = normalizedIOSSocketValue(info["body"] ?? info["text"], fallback: "")
        let ts = normalizedIOSMessageTimestamp(info["timestamp"])
        let roomMatchesActive = activeRoomId.isEmpty
            || normalizedIOSRoomIdentity(roomId) == normalizedIOSRoomIdentity(activeRoomId)
            || (!roomName.isEmpty && normalizedIOSRoomIdentity(roomName) == normalizedIOSRoomIdentity(activeRoomName))
        guard !roomId.isEmpty, !body.isEmpty, roomMatchesActive else { return }
        roomTranscripts.append(
            IOSRoomTranscriptItem(
                id: UUID().uuidString,
                roomId: roomId,
                roomName: roomName.isEmpty ? "Room" : roomName,
                speaker: speaker.isEmpty ? "Speaker" : speaker,
                body: body,
                timestamp: Date(timeIntervalSince1970: ts)
            )
        )
        if roomTranscripts.count > 400 {
            roomTranscripts = Array(roomTranscripts.suffix(400))
        }
    }

    private func upsertDirectTarget(_ target: IOSDirectMessageTarget) {
        if let idx = directTargets.firstIndex(where: { $0.id == target.id }) {
            directTargets[idx] = target
        } else {
            directTargets.append(target)
        }
        directTargets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func isLikelyLocalMessage(author: String, senderId: String) -> Bool {
        let normalizedAuthor = author
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedSenderId = senderId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let defaults = UserDefaults.standard
        let localNames = [
            defaults.string(forKey: "voicelink.displayName"),
            defaults.string(forKey: "voicelink.accountDisplayName"),
            defaults.string(forKey: "voicelink.userName")
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }
        let localUserId = (defaults.string(forKey: "voicelink.userId") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if !normalizedSenderId.isEmpty, normalizedSenderId == localUserId {
            return true
        }
        return !normalizedAuthor.isEmpty && localNames.contains(normalizedAuthor)
    }

    private func mapIOSRoomUser(_ user: [String: Any], roomId: String, index: Int) -> IOSDirectMessageTarget {
        let id = normalizedIOSSocketValue(user["id"] ?? user["userId"], fallback: "")
        let rawName = normalizedIOSSocketValue(
            user["name"] ?? user["userName"] ?? user["displayName"] ?? user["username"],
            fallback: ""
        )
        let resolvedId = id.isEmpty
            ? "\(roomId)|\(rawName.isEmpty ? "user-\(index)" : rawName.lowercased())"
            : id
        let fallbackName = resolvedId.count > 8 ? "User \(resolvedId.prefix(8))" : "User \(resolvedId)"
        let name = rawName.isEmpty ? fallbackName : rawName
        return IOSDirectMessageTarget(
            id: resolvedId,
            name: name,
            isMuted: (user["muted"] as? Bool) ?? (user["isMuted"] as? Bool) ?? false,
            isDeafened: (user["deafened"] as? Bool) ?? (user["isDeafened"] as? Bool) ?? false,
            isSpeaking: (user["speaking"] as? Bool) ?? (user["isSpeaking"] as? Bool) ?? false,
            transmitEnabled: (user["transmitEnabled"] as? Bool) ?? true,
            isBot: (user["isBot"] as? Bool) ?? false,
            hasAudioControls: (user["hasAudioControls"] as? Bool) ?? ((user["isBot"] as? Bool) != true),
            deviceName: normalizedIOSSocketValue(user["deviceName"], fallback: ""),
            deviceType: normalizedIOSSocketValue(user["deviceType"], fallback: ""),
            clientVersion: normalizedIOSSocketValue(user["clientVersion"], fallback: ""),
            botType: normalizedIOSSocketValue(user["botType"], fallback: ""),
            statusMessage: normalizedIOSSocketValue(user["statusMessage"], fallback: ""),
            authProvider: normalizedIOSSocketValue(user["authProvider"], fallback: ""),
            role: normalizedIOSSocketValue(user["role"], fallback: "")
        )
    }
}

private func normalizedIOSSocketValue(_ value: Any?, fallback: String) -> String {
    if value == nil || value is NSNull {
        return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let text = String(describing: value ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let lowered = text.lowercased()
    if text.isEmpty || lowered == "null" || lowered == "<null>" || lowered == "nil" {
        return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return text
}

private func normalizedIOSMessageTimestamp(_ value: Any?) -> TimeInterval {
    if let time = value as? TimeInterval {
        return time > 10_000_000_000 ? time / 1000.0 : time
    }
    let text = normalizedIOSSocketValue(value, fallback: "")
    if let doubleValue = Double(text) {
        return doubleValue > 10_000_000_000 ? doubleValue / 1000.0 : doubleValue
    }
    if let date = ISO8601DateFormatter().date(from: text) {
        return date.timeIntervalSince1970
    }
    return Date().timeIntervalSince1970
}

func normalizedIOSRoomIdentity(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

private func iosUsersArray(from info: [AnyHashable: Any]) -> [Any] {
    if let users = info["users"] as? [Any] {
        return users
    }
    if let users = info["users"] as? NSArray {
        return users.compactMap { $0 }
    }
    if let roomUsers = info["roomUsers"] as? [Any] {
        return roomUsers
    }
    if let roomUsers = info["roomUsers"] as? NSArray {
        return roomUsers.compactMap { $0 }
    }
    if let payloadUsers = info["payload"] as? [String: Any], let users = payloadUsers["users"] as? [Any] {
        return users
    }
    if let payloadUsers = info["payload"] as? [AnyHashable: Any], let users = payloadUsers["users"] as? [Any] {
        return users
    }
    if let payloadUsers = info["payload"] as? NSDictionary, let users = payloadUsers["users"] as? [Any] {
        return users
    }
    if let room = info["room"] as? [String: Any], let users = room["users"] as? [Any] {
        return users
    }
    if let room = info["room"] as? [AnyHashable: Any], let users = room["users"] as? [Any] {
        return users
    }
    if let room = info["room"] as? NSDictionary, let users = room["users"] as? [Any] {
        return users
    }
    if let room = info["room"] as? NSDictionary, let members = room["members"] as? [Any] {
        return members
    }
    if let room = info["room"] as? NSDictionary, let participants = room["participants"] as? [Any] {
        return participants
    }
    if let members = info["members"] as? [Any] {
        return members
    }
    if let participants = info["participants"] as? [Any] {
        return participants
    }
    return []
}

private func iosMessagesArray(from info: [AnyHashable: Any]) -> [[AnyHashable: Any]] {
    func normalizeArray(_ values: [Any]) -> [[AnyHashable: Any]] {
        values.compactMap { value in
            if let dict = value as? [AnyHashable: Any] {
                return dict
            }
            if let dict = value as? [String: Any] {
                var normalized: [AnyHashable: Any] = [:]
                dict.forEach { normalized[$0.key] = $0.value }
                return normalized
            }
            if let dict = value as? NSDictionary {
                var normalized: [AnyHashable: Any] = [:]
                for (key, value) in dict {
                    if let hashableKey = key as? AnyHashable {
                        normalized[hashableKey] = value
                    }
                }
                return normalized
            }
            return nil
        }
    }

    func extractMessages(from payload: Any?) -> [[AnyHashable: Any]] {
        if let messages = payload as? [Any] {
            return normalizeArray(messages)
        }
        if let messages = payload as? NSArray {
            return normalizeArray(messages.compactMap { $0 })
        }
        return []
    }

    if let messages = info["messages"] as? [Any] {
        return normalizeArray(messages)
    }
    if let messages = info["messages"] as? NSArray {
        return normalizeArray(messages.compactMap { $0 })
    }
    let directFallbackKeys: [AnyHashable] = ["history", "items", "entries"]
    for key in directFallbackKeys {
        let resolved = extractMessages(from: info[key])
        if !resolved.isEmpty {
            return resolved
        }
    }
    if let payload = info["payload"] as? [String: Any], let messages = payload["messages"] as? [Any] {
        return normalizeArray(messages)
    }
    if let payload = info["payload"] as? [AnyHashable: Any], let messages = payload["messages"] as? [Any] {
        return normalizeArray(messages)
    }
    if let payload = info["payload"] as? NSDictionary, let messages = payload["messages"] as? [Any] {
        return normalizeArray(messages)
    }
    if let payload = info["payload"] as? [String: Any] {
        for key in ["history", "items", "entries"] {
            let resolved = extractMessages(from: payload[key])
            if !resolved.isEmpty {
                return resolved
            }
        }
    }
    if let payload = info["payload"] as? [AnyHashable: Any] {
        for key in ["history", "items", "entries"] {
            let resolved = extractMessages(from: payload[key])
            if !resolved.isEmpty {
                return resolved
            }
        }
    }
    if let payload = info["payload"] as? NSDictionary {
        for key in ["history", "items", "entries"] {
            let resolved = extractMessages(from: payload[key])
            if !resolved.isEmpty {
                return resolved
            }
        }
    }
    if let room = info["room"] as? [String: Any], let messages = room["messages"] as? [Any] {
        return normalizeArray(messages)
    }
    if let room = info["room"] as? [AnyHashable: Any], let messages = room["messages"] as? [Any] {
        return normalizeArray(messages)
    }
    if let room = info["room"] as? NSDictionary, let messages = room["messages"] as? [Any] {
        return normalizeArray(messages)
    }
    if let room = info["room"] as? [String: Any] {
        for key in ["history", "items", "entries"] {
            let resolved = extractMessages(from: room[key])
            if !resolved.isEmpty {
                return resolved
            }
        }
    }
    if let room = info["room"] as? [AnyHashable: Any] {
        for key in ["history", "items", "entries"] {
            let resolved = extractMessages(from: room[key])
            if !resolved.isEmpty {
                return resolved
            }
        }
    }
    if let room = info["room"] as? NSDictionary {
        for key in ["history", "items", "entries"] {
            let resolved = extractMessages(from: room[key])
            if !resolved.isEmpty {
                return resolved
            }
        }
    }
    return []
}

private func iosUserDictionary(from value: Any?) -> [String: Any]? {
    if let user = value as? [String: Any] {
        return user
    }
    if let user = value as? [AnyHashable: Any] {
        var normalized: [String: Any] = [:]
        for (key, value) in user {
            normalized[String(describing: key)] = value
        }
        return normalized
    }
    if let user = value as? NSDictionary {
        var normalized: [String: Any] = [:]
        for (key, value) in user {
            normalized[String(describing: key)] = value
        }
        return normalized
    }
    return nil
}

@MainActor
private final class IOSRoomAnnouncementManager {
    static let shared = IOSRoomAnnouncementManager()

    private lazy var synthesizer = AVSpeechSynthesizer()

    func announce(_ message: String, interrupt: Bool = false) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
        guard shouldUseSpeechSynthesizer else { return }
        if interrupt, synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        if synthesizer.isSpeaking && !interrupt {
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.48
        utterance.pitchMultiplier = 1.0
        utterance.volume = 0.85
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier == "en" ? "en-US" : nil)
        synthesizer.speak(utterance)
    }

    func announceSystemMessage(_ body: String, author: String) {
        guard shouldSpeakSystemMessages else { return }
        let prefix = author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "System" : author
        announce("\(prefix). \(body)", interrupt: false)
    }

    func announceRoomMessage(_ body: String, author: String) {
        let prefix = author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Message" : "\(author) says"
        announce("\(prefix). \(body)", interrupt: false)
    }

    private var announcementsEnabled: Bool {
        if UserDefaults.standard.object(forKey: "voicelink.ios.ttsAnnouncementsEnabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "voicelink.ios.ttsAnnouncementsEnabled")
    }

    private var shouldUseSpeechSynthesizer: Bool {
        guard announcementsEnabled else { return false }
        if UIAccessibility.isVoiceOverRunning {
            return false
        }
        return true
    }

    private var shouldSpeakSystemMessages: Bool {
        if UserDefaults.standard.object(forKey: "voicelink.ios.systemAnnouncementsEnabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "voicelink.ios.systemAnnouncementsEnabled")
    }
}

private enum RoomSortMode: String, CaseIterable, Identifiable {
    case activity
    case recent
    case name

    var id: String { rawValue }

    var label: String {
        switch self {
        case .activity: return "Activity"
        case .recent: return "Recent"
        case .name: return "Name"
        }
    }
}

struct RoomSummary: Identifiable, Decodable, Hashable {
    struct LiveBroadcastSummary: Decodable, Hashable {
        let enabled: Bool
        let isLive: Bool
        let status: String
        let provider: String
        let providerName: String
        let shareURL: String

        private enum CodingKeys: String, CodingKey {
            case enabled, isLive, status, provider, providerName, shareUrl
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = (try? container.decode(Bool.self, forKey: .enabled)) ?? false
            isLive = (try? container.decode(Bool.self, forKey: .isLive)) ?? false
            status = (try? container.decode(String.self, forKey: .status)) ?? "idle"
            provider = (try? container.decode(String.self, forKey: .provider)) ?? "aaastreamer"
            providerName = (try? container.decode(String.self, forKey: .providerName)) ?? "AAAStreamer"
            shareURL = (try? container.decode(String.self, forKey: .shareUrl)) ?? ""
        }
    }

    struct MotdSettings: Decodable, Hashable {
        let enabled: Bool
        let showBeforeJoin: Bool
        let showInRoom: Bool
    }

    struct ServerRulesAppliesTo: Decodable, Hashable {
        let account: Bool
        let guest: Bool
    }

    struct ServerUsefulLink: Decodable, Hashable, Identifiable {
        let label: String
        let url: String

        var id: String { "\(label)|\(url)" }
    }

    struct ServerRulesSummary: Decodable, Hashable {
        let enabled: Bool
        let title: String
        let body: String
        let requireAgreement: Bool
        let version: String
        let appliesTo: ServerRulesAppliesTo
        let privacyPolicyUrl: String
        let usefulLinks: [ServerUsefulLink]
    }

    let id: String
    let name: String
    let description: String
    let userCount: Int
    let botCount: Int
    let totalVisible: Int
    let visibility: String
    let accessType: String
    let locked: Bool
    let serverSource: String
    let serverTitle: String
    let serverApiBase: String
    let serverDomain: String
    let serverDescription: String
    let federated: Bool
    let federationTier: String
    let backgroundStream: String
    let streamVolume: Double
    let liveBroadcast: LiveBroadcastSummary?
    let showChatInIOS: Bool
    let iosChatMessageOrder: String
    let iosChatMessageLimit: Int
    let motd: String
    let motdSettings: MotdSettings
    let serverRules: ServerRulesSummary

    init(
        id: String,
        name: String,
        description: String,
        userCount: Int,
        botCount: Int,
        totalVisible: Int,
        visibility: String,
        accessType: String,
        locked: Bool,
        serverSource: String,
        serverTitle: String,
        serverApiBase: String,
        serverDomain: String,
        serverDescription: String,
        federated: Bool,
        federationTier: String,
        backgroundStream: String,
        streamVolume: Double,
        liveBroadcast: LiveBroadcastSummary?,
        showChatInIOS: Bool,
        iosChatMessageOrder: String,
        iosChatMessageLimit: Int,
        motd: String,
        motdSettings: MotdSettings,
        serverRules: ServerRulesSummary
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.userCount = userCount
        self.botCount = max(0, botCount)
        self.totalVisible = max(userCount + max(0, botCount), totalVisible)
        self.visibility = visibility
        self.accessType = accessType
        self.locked = locked
        self.serverSource = serverSource
        self.serverTitle = serverTitle
        self.serverApiBase = serverApiBase
        self.serverDomain = serverDomain
        self.serverDescription = serverDescription
        self.federated = federated
        self.federationTier = federationTier
        self.backgroundStream = backgroundStream
        self.streamVolume = streamVolume
        self.liveBroadcast = liveBroadcast
        self.showChatInIOS = showChatInIOS
        self.iosChatMessageOrder = iosChatMessageOrder
        self.iosChatMessageLimit = iosChatMessageLimit
        self.motd = motd
        self.motdSettings = motdSettings
        self.serverRules = serverRules
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, users, userCount, memberCount, botCount, totalVisible, visibility, accessType, locked, serverSource, serverTitle, serverApiBase, serverDomain, serverDescription, federated, federationTier, backgroundStream, streamVolume, liveBroadcast, showChatInIOS, iosChatMessageOrder, iosChatMessageLimit, motd, motdSettings, serverRules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = RoomSummary.decodeString(container, forKey: .id) ?? UUID().uuidString
        name = (try? container.decode(String.self, forKey: .name)) ?? "Untitled Room"
        description = (try? container.decode(String.self, forKey: .description)) ?? ""
        let users = RoomSummary.decodeUserCount(container, forKey: .users)
        let explicitUserCount = RoomSummary.decodeInt(container, forKey: .userCount)
        let memberCount = RoomSummary.decodeInt(container, forKey: .memberCount)
        userCount = explicitUserCount ?? users ?? memberCount ?? 0
        botCount = RoomSummary.decodeInt(container, forKey: .botCount) ?? 0
        totalVisible = max(userCount + botCount, RoomSummary.decodeInt(container, forKey: .totalVisible) ?? 0)
        visibility = (try? container.decode(String.self, forKey: .visibility)) ?? "public"
        accessType = (try? container.decode(String.self, forKey: .accessType)) ?? "open"
        locked = (try? container.decode(Bool.self, forKey: .locked)) ?? false
        serverSource = (try? container.decode(String.self, forKey: .serverSource)) ?? "unknown"
        serverTitle = (try? container.decode(String.self, forKey: .serverTitle)) ?? ""
        serverApiBase = (try? container.decode(String.self, forKey: .serverApiBase)) ?? ""
        serverDomain = (try? container.decode(String.self, forKey: .serverDomain)) ?? ""
        serverDescription = (try? container.decode(String.self, forKey: .serverDescription)) ?? ""
        federated = (try? container.decode(Bool.self, forKey: .federated)) ?? false
        federationTier = (try? container.decode(String.self, forKey: .federationTier)) ?? "none"
        backgroundStream = (try? container.decode(String.self, forKey: .backgroundStream)) ?? ""
        streamVolume = (try? container.decode(Double.self, forKey: .streamVolume))
            ?? Double((try? container.decode(Int.self, forKey: .streamVolume)) ?? 30)
        liveBroadcast = try? container.decode(LiveBroadcastSummary.self, forKey: .liveBroadcast)
        showChatInIOS = (try? container.decode(Bool.self, forKey: .showChatInIOS)) ?? true
        let decodedOrder = (try? container.decode(String.self, forKey: .iosChatMessageOrder))?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "newest-first"
        iosChatMessageOrder = ["oldest-first", "newest-first"].contains(decodedOrder) ? decodedOrder : "newest-first"
        let decodedLimit = (try? container.decode(Int.self, forKey: .iosChatMessageLimit)) ?? 50
        iosChatMessageLimit = [20, 50].contains(decodedLimit) ? decodedLimit : 50
        motd = (try? container.decode(String.self, forKey: .motd)) ?? ""
        motdSettings = (try? container.decode(MotdSettings.self, forKey: .motdSettings)) ?? MotdSettings(enabled: true, showBeforeJoin: true, showInRoom: true)
        serverRules = (try? container.decode(ServerRulesSummary.self, forKey: .serverRules)) ?? ServerRulesSummary(
            enabled: true,
            title: "Server Rules",
            body: "",
            requireAgreement: true,
            version: "",
            appliesTo: ServerRulesAppliesTo(account: true, guest: true),
            privacyPolicyUrl: "",
            usefulLinks: []
        )
    }

    private static func decodeString(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> String? {
        if let value = try? container.decode(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Int.self, forKey: key) {
            return String(value)
        }
        return nil
    }

    private static func decodeInt(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(String.self, forKey: key), let intValue = Int(value) {
            return intValue
        }
        return nil
    }

    private static func decodeUserCount(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Int? {
        if let intValue = decodeInt(container, forKey: key) {
            return intValue
        }
        if let users = try? container.decode([[String: String]].self, forKey: key) {
            return users.count
        }
        if let users = try? container.decode([[String: AnyRoomUserValue]].self, forKey: key) {
            return users.count
        }
        if let users = try? container.decode([String].self, forKey: key) {
            return users.count
        }
        return nil
    }
}

private extension RoomSummary {
    func normalizedForFetchedBase(_ baseURL: String) -> RoomSummary {
        let normalizedBase = normalizeBaseURL(serverApiBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? baseURL : serverApiBase)
        let configured = configuredServerPresentation(baseURL: normalizedBase)
        let resolvedTitle = configured?.name ?? serverTitle
        let resolvedDescription = configured?.description
            ?? (configured != nil && serverDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "\(resolvedTitle) server."
                : serverDescription)

        return RoomSummary(
            id: id,
            name: name,
            description: description,
            userCount: userCount,
            botCount: botCount,
            totalVisible: totalVisible,
            visibility: visibility,
            accessType: accessType,
            locked: locked,
            serverSource: serverSource,
            serverTitle: resolvedTitle,
            serverApiBase: normalizedBase,
            serverDomain: configured?.domain ?? serverDomain,
            serverDescription: resolvedDescription,
            federated: federated,
            federationTier: federationTier,
            backgroundStream: backgroundStream,
            streamVolume: streamVolume,
            liveBroadcast: liveBroadcast,
            showChatInIOS: showChatInIOS,
            iosChatMessageOrder: iosChatMessageOrder,
            iosChatMessageLimit: iosChatMessageLimit,
            motd: motd,
            motdSettings: motdSettings,
            serverRules: serverRules
        )
    }
}

private struct AnyRoomUserValue: Decodable, Hashable {
    let rawValue: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            rawValue = value
        } else if let value = try? container.decode(Int.self) {
            rawValue = String(value)
        } else if let value = try? container.decode(Bool.self) {
            rawValue = value ? "true" : "false"
        } else if let value = try? container.decode(Double.self) {
            rawValue = String(value)
        } else {
            rawValue = ""
        }
    }
}

private struct FederatedRoomChoice: Identifiable, Hashable {
    let id: String
    let room: RoomSummary
    let serverLabel: String
    let baseURL: String
}

private struct RoomDetailsDestination: Identifiable, Hashable {
    let id: String
    let room: RoomSummary
    let serverLabel: String
    let baseURL: String
}

private struct IOSSupportContext: Identifiable, Hashable {
    let id: String
    let serverURL: String
    let serverName: String
    let roomId: String
    let roomName: String
    let sourceContext: String

    static func server(baseURL: String, serverName: String) -> IOSSupportContext {
        IOSSupportContext(
            id: "\(normalizeBaseURL(baseURL))|server-support",
            serverURL: normalizeBaseURL(baseURL),
            serverName: serverName,
            roomId: "",
            roomName: "",
            sourceContext: "ios-server-support"
        )
    }

    static func room(baseURL: String, serverName: String, room: RoomSummary) -> IOSSupportContext {
        IOSSupportContext(
            id: "\(normalizeBaseURL(baseURL))|\(room.id)|room-support",
            serverURL: normalizeBaseURL(baseURL),
            serverName: serverName,
            roomId: room.id,
            roomName: room.name,
            sourceContext: "ios-room-support"
        )
    }
}

private struct IOSSupportTicketSummary: Identifiable, Decodable {
    let id: String
    let subject: String
    let status: String
    let category: String
    let priority: String
    let serverName: String?
    let roomName: String?
    let updatedAt: Double?
}

private struct FederatedRoomGroup: Identifiable, Hashable {
    let id: String
    let displayName: String
    let totalUsers: Int
    let totalBots: Int
    let totalVisible: Int
    let choices: [FederatedRoomChoice]
}

private func normalizedFederatedRoomGroupKey(_ rawName: String) -> String {
    let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let collapsedWhitespace = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    return collapsedWhitespace
        .replacingOccurrences(of: "[^\\p{L}\\p{N} ]+", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func stablePolicyDigest(_ rawValue: String) -> String {
    let bytes = Array(rawValue.utf8)
    var hash: UInt64 = 1469598103934665603
    for byte in bytes {
        hash ^= UInt64(byte)
        hash &*= 1099511628211
    }
    return String(hash, radix: 16)
}

private struct ClientVisibilitySettings: Equatable {
    let desktop: Bool
    let ios: Bool
    let web: Bool
    let frontendOpen: Bool

    static let allVisible = ClientVisibilitySettings(
        desktop: true,
        ios: true,
        web: true,
        frontendOpen: true
    )
}

private struct ServersTab: View {
    @AppStorage("voicelink.ios.serverScreenTab") private var storedTab = ServerScreenTab.federation.rawValue
    @Binding var serverURL: String
    @ObservedObject var roomState: IOSRoomMessagingState
    let openProfile: () -> Void

    private var selectedTabBinding: Binding<ServerScreenTab> {
        Binding(
            get: {
                ServerScreenTab(rawValue: storedTab) ?? .servers
            },
            set: { storedTab = $0.rawValue }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Server Screen", selection: selectedTabBinding) {
                ForEach(ServerScreenTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top])
            .accessibilityLabel("Server screen")

            switch selectedTabBinding.wrappedValue {
            case .servers:
                HomeTab(
                    serverURL: $serverURL,
                    roomState: roomState,
                    openProfile: openProfile,
                    openServers: { storedTab = ServerScreenTab.federation.rawValue }
                )
            case .federation:
                FederationTab(serverURL: $serverURL, roomState: roomState)
            }
        }
    }
}

private struct HomeTab: View {
    @Environment(\.openURL) private var openURL
    @AppStorage("voicelink.showWebFrontendShortcutOnHome") private var showWebFrontendShortcutOnHome = false
    @AppStorage("voicelink.authToken") private var authToken = ""
    @AppStorage("voicelink.displayName") private var displayName = ""
    @AppStorage("voicelink.authProvider") private var authProvider = ""
    @AppStorage("voicelink.authUserJSON") private var authUserJSON = ""
    @Binding var serverURL: String
    @ObservedObject var roomState: IOSRoomMessagingState
    let openProfile: () -> Void
    let openServers: () -> Void
    @State private var rooms: [RoomSummary] = []
    @State private var isLoading = false
    @State private var errorMessage = ""
    @State private var activeSession: RoomSessionDestination?
    @State private var activePreview: RoomPreviewDestination?
    @State private var activeDetails: RoomDetailsDestination?
    @State private var activeServer: HomeServerSummary?
    @State private var activeSupportContext: IOSSupportContext?
    @State private var pendingGuestJoinRoom: RoomSummary?
    @State private var pendingServerPolicyJoinRoom: RoomSummary?
    @State private var showGuestJoinPrompt = false
    @State private var showServerPolicyPrompt = false
    @State private var isAdmin = false
    @State private var canManageRooms = false
    @State private var showAdmin = false
    @State private var roomSortMode: RoomSortMode = .activity
    @State private var clientVisibility: ClientVisibilitySettings = .allVisible
    @State private var searchText = ""
    @State private var showNativeAccountSignIn = false
    @State private var authRequiredServerURL = ""

    private var normalizedBaseURL: String { normalizeBaseURL(serverURL) }
    private var roomsEndpoint: String { "\(normalizedBaseURL)/api/rooms?source=app&sort=\(roomSortMode.rawValue)" }
    private var filteredServerSummaries: [HomeServerSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let summaries = groupedServerSummaries
        guard !query.isEmpty else { return summaries }
        return summaries.filter { server in
            server.name.lowercased().contains(query)
            || server.description.lowercased().contains(query)
            || server.baseURL.lowercased().contains(query)
            || server.rooms.contains(where: { room in
                room.name.lowercased().contains(query)
                || room.description.lowercased().contains(query)
                || room.serverTitle.lowercased().contains(query)
                || room.serverDomain.lowercased().contains(query)
                || room.serverSource.lowercased().contains(query)
            })
        }
    }

    private var groupedServerSummaries: [HomeServerSummary] {
        let grouped = Dictionary(grouping: rooms) { room in
            canonicalServerIdentity(
                baseURL: room.serverApiBase.isEmpty ? normalizedBaseURL : room.serverApiBase,
                room: room
            )
        }

        return grouped.compactMap { key, serverRooms in
            guard let first = serverRooms.first else { return nil }
            let resolvedBase = normalizeBaseURL(first.serverApiBase.isEmpty ? normalizedBaseURL : first.serverApiBase)
            let sortedRooms = serverRooms.sorted { lhs, rhs in
                if lhs.userCount == rhs.userCount {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.userCount > rhs.userCount
            }
            return HomeServerSummary(
                id: key,
                name: displayServerName(room: first, fallbackBase: resolvedBase),
                description: first.serverDescription.trimmingCharacters(in: .whitespacesAndNewlines),
                baseURL: resolvedBase,
                roomCount: sortedRooms.count,
                totalUsers: sortedRooms.reduce(0) { $0 + $1.userCount },
                totalBots: sortedRooms.reduce(0) { $0 + $1.botCount },
                totalVisible: sortedRooms.reduce(0) { $0 + max($1.totalVisible, $1.userCount + $1.botCount) },
                rooms: sortedRooms
            )
        }
        .sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !errorMessage.isEmpty {
                    Section("Status") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section("Room") {
                    if roomState.isInRoom {
                        Text("Active room: \(roomState.activeRoomName.isEmpty ? "Unknown Room" : roomState.activeRoomName)")
                        HStack {
                            Button("Profile") {
                                openProfile()
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Leave Room") {
                                roomState.requestLeaveActiveRoom()
                            }
                            .buttonStyle(.bordered)
                        }
                    } else {
                        Text("Tap a room to join.")
                            .foregroundStyle(.secondary)
                    }
                }

                if showWebFrontendShortcutOnHome {
                    Section("Client Access") {
                        if clientVisibility.ios {
                            Text("iOS client access is enabled for this server.")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("This server has iOS visibility disabled by server policy.")
                                .foregroundStyle(.orange)
                        }

                        HStack {
                            Text("Web Frontend")
                            Spacer()
                            Text(clientVisibility.frontendOpen ? "Open" : "Closed")
                                .foregroundStyle(clientVisibility.frontendOpen ? .green : .secondary)
                        }

                        Button("Open Web Frontend") {
                            guard let url = URL(string: normalizedBaseURL) else { return }
                            openURL(url)
                        }
                        .disabled(!clientVisibility.frontendOpen)
                    }
                }

                Section("Servers") {
                    Text("Tap a server to browse only that server’s rooms. Use Federated Rooms for one combined room browser across all trusted servers.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    TextField("Search servers or room names", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search rooms or servers")

                    HStack {
                        Button("Profile") {
                            openProfile()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Menu {
                        ForEach(RoomSortMode.allCases) { mode in
                            Button(mode.label) {
                                roomSortMode = mode
                            }
                        }
                    } label: {
                        Label("Sort Rooms: \(roomSortMode.label)", systemImage: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Sort rooms")
                    .accessibilityValue(roomSortMode.label)

                    if !clientVisibility.ios {
                        Text("Rooms are hidden on iOS by server settings.")
                            .foregroundStyle(.secondary)
                    } else if isLoading {
                        HStack {
                            ProgressView()
                            Text("Loading rooms…")
                                .foregroundStyle(.secondary)
                        }
                    } else if filteredServerSummaries.isEmpty {
                        Text("No servers found yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredServerSummaries) { server in
                            Button {
                                activeServer = server
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(server.name)
                                        .font(.headline)
                                    Text(server.baseURL)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(displayOptionalDescription(server.description))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text("\(server.roomCount) room\(server.roomCount == 1 ? "" : "s") • \(occupancySummary(users: server.totalUsers, bots: server.totalBots, totalVisible: server.totalVisible))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(server.name), \(server.baseURL), \(server.roomCount) rooms, \(occupancySummary(users: server.totalUsers, bots: server.totalBots, totalVisible: server.totalVisible))")
                            .accessibilityHint("Double tap to browse rooms on this server.")
                        }
                    }
                }
            }
            .navigationTitle("Servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isAdmin || canManageRooms {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showAdmin = true
                        } label: {
                            Label("Admin", systemImage: "gearshape.2.fill")
                        }
                    }
                }
            }
            .onAppear {
                Task {
                    await refreshRooms()
                    await refreshAdminAccess()
                }
            }
            .refreshable {
                await refreshRooms()
                await refreshAdminAccess()
            }
            .onChange(of: roomSortMode) { _ in
                Task { await refreshRooms() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .iosRoomJoined)) { _ in
                Task { await refreshRooms() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .iosRoomLeft)) { _ in
                Task { await refreshRooms() }
            }
            .sheet(item: $activeSession) { session in
                RoomSessionView(destination: session, roomState: roomState)
            }
            .sheet(item: $activePreview) { preview in
                RoomPreviewView(destination: preview)
            }
            .sheet(item: $activeDetails) { details in
                RoomDetailsView(destination: details)
            }
            .sheet(item: $activeServer) { server in
                HomeServerRoomsView(
                    server: server,
                    clientVisibleOnIOS: clientVisibility.ios,
                    canManageRooms: isAdmin || canManageRooms,
                    onJoinRoom: { room in
                        activeServer = nil
                        openRoom(room, action: "join")
                    },
                    onShareRoom: { room in shareRoom(room) },
                    onOpenServerAdmin: {
                        activeServer = nil
                        showAdmin = true
                    },
                    onContactSupport: { context in
                        activeServer = nil
                        activeSupportContext = context
                    }
                )
            }
            .sheet(item: $activeSupportContext) { context in
                IOSSupportTicketSheet(context: context)
            }
            .sheet(isPresented: $showGuestJoinPrompt) {
                GuestJoinPromptView(
                    displayName: $displayName,
                    openServers: openServers,
                    continueJoin: {
                        guard let room = pendingGuestJoinRoom else { return }
                        pendingGuestJoinRoom = nil
                        showGuestJoinPrompt = false
                        openRoom(room, action: "join", bypassGuestPrompt: true)
                    }
                )
            }
            .sheet(isPresented: $showServerPolicyPrompt) {
                ServerJoinPolicyPromptView(
                    room: pendingServerPolicyJoinRoom,
                    serverName: pendingServerPolicyJoinRoom.map {
                        displayServerName(room: $0, fallbackBase: $0.serverApiBase.isEmpty ? normalizedBaseURL : normalizeBaseURL($0.serverApiBase))
                    } ?? "VoiceLink Server",
                    isSignedIn: !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    agree: {
                        guard let room = pendingServerPolicyJoinRoom else { return }
                        markServerPolicyAccepted(for: room, fallbackBase: normalizedBaseURL, signedIn: !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        pendingServerPolicyJoinRoom = nil
                        showServerPolicyPrompt = false
                        openRoom(room, action: "join", bypassServerPolicyPrompt: true)
                    },
                    disagree: {
                        pendingServerPolicyJoinRoom = nil
                        showServerPolicyPrompt = false
                    }
                )
            }
            .sheet(isPresented: $showAdmin) {
                AdminTabView(serverURL: $serverURL)
            }
            .sheet(isPresented: $showNativeAccountSignIn) {
                IOSAccountSignInView(serverURL: authRequiredServerURL.isEmpty ? normalizedBaseURL : normalizeBaseURL(authRequiredServerURL))
            }
        }
    }

    private func openRoom(_ room: RoomSummary, action: String, bypassGuestPrompt: Bool = false, bypassServerPolicyPrompt: Bool = false) {
        guard clientVisibility.ios else { return }
        guard activeSession == nil, activePreview == nil, activeDetails == nil else { return }
        let resolvedRoomBase = room.serverApiBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? normalizedBaseURL
            : normalizeBaseURL(room.serverApiBase)
        if action == "details" {
            activeSession = nil
            activePreview = nil
            activeDetails = RoomDetailsDestination(
                id: "\(resolvedRoomBase)|\(room.id)|details",
                room: room,
                serverLabel: displayServerName(room: room, fallbackBase: resolvedRoomBase),
                baseURL: resolvedRoomBase
            )
            return
        }
        if action == "join" {
            let signedIn = !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !bypassServerPolicyPrompt && shouldPromptForServerPolicy(room: room, fallbackBase: resolvedRoomBase, signedIn: signedIn) {
                pendingServerPolicyJoinRoom = room
                showServerPolicyPrompt = true
                return
            }
            if !bypassGuestPrompt && authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !iosHasValidGuestDisplayName(displayName) {
                pendingGuestJoinRoom = room
                showGuestJoinPrompt = true
                return
            }
            activePreview = nil
            activeSession = RoomSessionDestination(
                roomId: room.id,
                roomName: room.name,
                roomDescription: room.description,
                baseURL: resolvedRoomBase,
                displayName: iosHasValidGuestDisplayName(displayName)
                    ? displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    : "Guest",
                backgroundStream: room.backgroundStream,
                backgroundStreamVolume: room.streamVolume,
                showChatByDefault: room.showChatInIOS,
                chatMessageOrder: room.iosChatMessageOrder,
                chatMessageLimit: room.iosChatMessageLimit,
                canManageRooms: isAdmin || canManageRooms
            )
            return
        }

        activeSession = nil
        activeDetails = nil
        activePreview = RoomPreviewDestination(
            roomId: room.id,
            roomName: room.name,
            roomDescription: room.description,
            baseURL: resolvedRoomBase,
            room: room
        )
    }

    private func shareRoom(_ room: RoomSummary) {
        let resolvedBase = room.serverApiBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? normalizedBaseURL
            : normalizeBaseURL(room.serverApiBase)
        let shareBase = room.serverDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? normalizedBaseURL
            : "https://\(room.serverDomain)"
        guard let url = URL(string: "\(room.serverDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? resolvedBase : shareBase)/?room=\(room.id)") else { return }
        openURL(url)
    }

    @MainActor
    private func refreshRooms() async {
        clientVisibility = await fetchClientVisibility(baseURL: normalizedBaseURL)
        guard clientVisibility.ios else {
            rooms = []
            errorMessage = "iOS client access is disabled for this server."
            return
        }

        if !isLoading {
            isLoading = true
        }
        errorMessage = ""
        do {
            let bases = await fetchVisibleFederationBases(preferredBase: normalizedBaseURL)
            rooms = deduplicateHomeRooms(
                try await fetchRoomsAcrossVisibleServers(bases: bases, sortMode: roomSortMode),
                fallbackBase: normalizedBaseURL
            )
        } catch let error as IOSRoomsAuthenticationRequired {
            rooms = []
            authRequiredServerURL = error.baseURL
            errorMessage = "This server requires sign-in before rooms can be listed. Sign in with any available method."
            showNativeAccountSignIn = true
        } catch {
            rooms = []
            errorMessage = "Could not load rooms. Check server URL and network."
        }
        isLoading = false
    }

    private func deduplicateHomeRooms(_ allRooms: [RoomSummary], fallbackBase: String) -> [RoomSummary] {
        var dedupedByExactKey: [String: RoomSummary] = [:]
        for room in allRooms {
            let resolvedBase = room.serverApiBase.isEmpty ? fallbackBase : normalizeBaseURL(room.serverApiBase)
            let exactKey = "\(resolvedBase)|\(room.id)"
            let existing = dedupedByExactKey[exactKey]
            if existing == nil || homeRoomScore(room, fallbackBase: fallbackBase) >= homeRoomScore(existing!, fallbackBase: fallbackBase) {
                dedupedByExactKey[exactKey] = room
            }
        }

        return Array(dedupedByExactKey.values).sorted { lhs, rhs in
            if lhs.userCount == rhs.userCount {
                let lhsServer = displayServerName(
                    room: lhs,
                    fallbackBase: lhs.serverApiBase.isEmpty ? fallbackBase : normalizeBaseURL(lhs.serverApiBase)
                )
                let rhsServer = displayServerName(
                    room: rhs,
                    fallbackBase: rhs.serverApiBase.isEmpty ? fallbackBase : normalizeBaseURL(rhs.serverApiBase)
                )
                if lhsServer == rhsServer {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhsServer.localizedCaseInsensitiveCompare(rhsServer) == .orderedAscending
            }
            return lhs.userCount > rhs.userCount
        }
    }

    private func homeRoomScore(_ room: RoomSummary, fallbackBase: String) -> Int {
        var score = 0
        let resolvedBase = room.serverApiBase.isEmpty ? fallbackBase : normalizeBaseURL(room.serverApiBase)
        if resolvedBase == normalizedBaseURL {
            score += 4
        }
        if room.serverSource.localizedCaseInsensitiveContains("main") || room.serverTitle.localizedCaseInsensitiveContains("main") {
            score += 2
        }
        if room.visibility.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "public" {
            score += 1
        }
        return score
    }

    private func shouldPromptForServerPolicy(room: RoomSummary, fallbackBase: String, signedIn: Bool) -> Bool {
        let rulesBody = room.serverRules.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let motdBody = room.motd.trimmingCharacters(in: .whitespacesAndNewlines)
        let applies = signedIn ? room.serverRules.appliesTo.account : room.serverRules.appliesTo.guest
        let needsRules = room.serverRules.enabled && room.serverRules.requireAgreement && applies && !rulesBody.isEmpty
        let showsMotd = room.motdSettings.enabled && room.motdSettings.showBeforeJoin && !motdBody.isEmpty
        guard needsRules || showsMotd else { return false }
        return !UserDefaults.standard.bool(forKey: serverPolicyAcceptanceKey(for: room, fallbackBase: fallbackBase, signedIn: signedIn))
    }

    private func markServerPolicyAccepted(for room: RoomSummary, fallbackBase: String, signedIn: Bool) {
        UserDefaults.standard.set(true, forKey: serverPolicyAcceptanceKey(for: room, fallbackBase: fallbackBase, signedIn: signedIn))
    }

    private func serverPolicyAcceptanceKey(for room: RoomSummary, fallbackBase: String, signedIn: Bool) -> String {
        let resolvedBase = room.serverApiBase.isEmpty ? fallbackBase : normalizeBaseURL(room.serverApiBase)
        let identity = canonicalServerIdentity(baseURL: resolvedBase, room: room)
        let rulesVersion = room.serverRules.version.trimmingCharacters(in: .whitespacesAndNewlines)
        let policyVersion = rulesVersion.isEmpty
            ? stablePolicyDigest("\(room.serverRules.title)\n\(room.serverRules.body)\n\(room.motd)")
            : rulesVersion
        return "voicelink.ios.serverPolicyAccepted.\(signedIn ? "account" : "guest").\(stablePolicyDigest(identity)).\(stablePolicyDigest(policyVersion))"
    }

    @MainActor
    private func refreshAdminAccess() async {
        guard let url = URL(string: "\(normalizedBaseURL)/api/admin/status") else {
            isAdmin = false
            canManageRooms = false
            return
        }
        do {
            var request = iosServerPresenceRequest(url: url, timeout: 12)
            let token = (UserDefaults.standard.string(forKey: "voicelink.authToken") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue(token, forHTTPHeaderField: "x-session-token")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                isAdmin = false
                canManageRooms = false
                return
            }
            let json = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            isAdmin = (json["isAdmin"] as? Bool) ?? false
            let permissions = json["permissions"] as? [String: Bool]
            canManageRooms = ((json["canManageRooms"] as? Bool) ?? (permissions?["rooms"] ?? false)) || isAdmin
        } catch {
            isAdmin = false
        }
    }
}

private struct RoomRow: View {
    let room: RoomSummary

    private var liveBroadcastLabel: String? {
        guard let live = room.liveBroadcast, live.isLive else { return nil }
        return "Live on \(live.providerName)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(room.name)
                .font(.headline)
            Text(displayOptionalDescription(room.description))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("\(occupancySummary(room)) • \(displayRoomLockLabel(room.locked)) • \(displayVisibilityLabel(room.visibility)) • \(displayAccessTypeLabel(room.accessType))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let liveBroadcastLabel {
                Text(liveBroadcastLabel)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(room.name), \(occupancySummary(room)), \(displayRoomLockLabel(room.locked)), \(displayVisibilityLabel(room.visibility)), \(displayAccessTypeLabel(room.accessType))\(liveBroadcastLabel.map { ", \($0)" } ?? "")")
        .accessibilityHint("Double tap for room details. Swipe down for preview, join, and share actions.")
    }
}

private struct HomeServerSummary: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let baseURL: String
    let roomCount: Int
    let totalUsers: Int
    let totalBots: Int
    let totalVisible: Int
    let rooms: [RoomSummary]
}

private struct HomeServerRoomsView: View {
    @Environment(\.dismiss) private var dismiss
    let server: HomeServerSummary
    let clientVisibleOnIOS: Bool
    let canManageRooms: Bool
    let onJoinRoom: (RoomSummary) -> Void
    let onShareRoom: (RoomSummary) -> Void
    let onOpenServerAdmin: () -> Void
    let onContactSupport: (IOSSupportContext) -> Void
    @State private var activePreview: RoomPreviewDestination?
    @State private var activeDetails: RoomDetailsDestination?

    var body: some View {
        NavigationStack {
            List {
                Section("Server") {
                    LabeledContent("Name", value: server.name)
                    LabeledContent("Address", value: server.baseURL)
                    LabeledContent("Rooms", value: "\(server.roomCount)")
                    LabeledContent("Users and Bots", value: occupancySummary(users: server.totalUsers, bots: server.totalBots, totalVisible: server.totalVisible))
                    Text(displayOptionalDescription(server.description))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Contact Server Support") {
                        onContactSupport(.server(baseURL: server.baseURL, serverName: server.name))
                    }
                    .accessibilityHint("Opens a private support ticket for this server.")
                }

                if canManageRooms {
                    Section("Server Actions") {
                        Button("Create Room") {
                            dismiss()
                            onOpenServerAdmin()
                        }
                        .accessibilityHint("Opens the server administration tools to create a room.")

                        Button("Edit Rooms") {
                            dismiss()
                            onOpenServerAdmin()
                        }
                        .accessibilityHint("Opens the server administration tools to edit and remove rooms.")
                    }
                }

                Section("Rooms") {
                    if !clientVisibleOnIOS {
                        Text("Rooms are hidden on iOS by this server's policy.")
                            .foregroundStyle(.secondary)
                    } else if server.rooms.isEmpty {
                        Text("No rooms are visible on this server right now.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(server.rooms) { room in
                            Button {
                                showDetails(for: room)
                            } label: {
                                RoomRow(room: room)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Room Details") { showDetails(for: room) }
                                Button("Join Room") { onJoinRoom(room) }
                                Button("Preview Room") { showPreview(for: room) }
                                Button("Share Room") { onShareRoom(room) }
                                Button("Contact Server Support") {
                                    onContactSupport(.room(baseURL: server.baseURL, serverName: server.name, room: room))
                                }
                            }
                            .accessibilityHint("Double tap for room details. Extra actions are available for preview, join, and sharing.")
                            .accessibilityAction(named: Text("Room Details")) { showDetails(for: room) }
                            .accessibilityAction(named: Text("Join Room")) { onJoinRoom(room) }
                            .accessibilityAction(named: Text("Preview Room")) { showPreview(for: room) }
                            .accessibilityAction(named: Text("Share Room")) { onShareRoom(room) }
                            .accessibilityAction(named: Text("Contact Server Support")) {
                                onContactSupport(.room(baseURL: server.baseURL, serverName: server.name, room: room))
                            }
                        }
                    }
                }
            }
            .sheet(item: $activePreview) { preview in
                RoomPreviewView(destination: preview)
            }
            .sheet(item: $activeDetails) { details in
                RoomDetailsView(destination: details)
            }
            .navigationTitle(server.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func showDetails(for room: RoomSummary) {
        activeDetails = RoomDetailsDestination(
            id: "\(server.baseURL)|\(room.id)|details",
            room: room,
            serverLabel: server.name,
            baseURL: resolvedBaseURL(for: room)
        )
    }

    private func showPreview(for room: RoomSummary) {
        activePreview = RoomPreviewDestination(
            roomId: room.id,
            roomName: room.name,
            roomDescription: room.description,
            baseURL: resolvedBaseURL(for: room),
            room: room
        )
    }

    private func resolvedBaseURL(for room: RoomSummary) -> String {
        let roomBase = room.serverApiBase.trimmingCharacters(in: .whitespacesAndNewlines)
        return roomBase.isEmpty ? server.baseURL : normalizeBaseURL(roomBase)
    }
}

private struct RoomDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var activeSupportContext: IOSSupportContext?
    let destination: RoomDetailsDestination

    private var liveBroadcastStatus: String? {
        guard let live = destination.room.liveBroadcast, live.isLive else { return nil }
        return "Live on \(live.providerName)"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Room") {
                    LabeledContent("Name", value: destination.room.name)
                    LabeledContent("Server", value: destination.serverLabel)
                    LabeledContent("Users and Bots", value: occupancySummary(destination.room))
                    LabeledContent("Lock Status", value: displayRoomLockLabel(destination.room.locked))
                    LabeledContent("Visibility", value: displayVisibilityLabel(destination.room.visibility))
                    LabeledContent("Access Type", value: displayAccessTypeLabel(destination.room.accessType))
                    if let liveBroadcastStatus {
                        LabeledContent("Broadcast", value: liveBroadcastStatus)
                    }
                    Text(displayOptionalDescription(destination.room.description))
                        .font(.body)
                }

                if let live = destination.room.liveBroadcast, live.isLive {
                    Section("Live Broadcast") {
                        LabeledContent("Provider", value: live.providerName)
                        LabeledContent("Status", value: live.status.capitalized)
                        if !live.shareURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           let url = URL(string: live.shareURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            Link(destination: url) {
                                Text(live.shareURL)
                                    .font(.footnote)
                            }
                            .accessibilityLabel("Open live broadcast link")
                        }
                    }
                }

                Section("Server Details") {
                    LabeledContent("Server", value: destination.serverLabel)
                    if !destination.room.serverDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(destination.room.serverDescription)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if destination.room.serverRules.enabled,
                   !destination.room.serverRules.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section(destination.room.serverRules.title.isEmpty ? "Server Rules" : destination.room.serverRules.title) {
                        Text(destination.room.serverRules.body)
                            .font(.body)
                    }
                }

                if destination.room.motdSettings.enabled,
                   !destination.room.motd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("Message of the Day") {
                        Text(destination.room.motd)
                            .font(.body)
                    }
                }

                ServerPolicyLinksSection(rules: destination.room.serverRules)

                Section("Support") {
                    Button("Contact Server Support") {
                        activeSupportContext = .room(
                            baseURL: destination.baseURL,
                            serverName: destination.serverLabel,
                            room: destination.room
                        )
                    }
                    .accessibilityHint("Opens a private support ticket for this server and room.")
                }
            }
            .navigationTitle("Room Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .sheet(item: $activeSupportContext) { context in
                IOSSupportTicketSheet(context: context)
            }
        }
    }
}

private struct IOSSupportTicketSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("voicelink.authToken") private var authToken = ""
    @AppStorage("voicelink.displayName") private var displayName = ""
    @AppStorage("voicelink.authUserJSON") private var authUserJSON = ""
    let context: IOSSupportContext

    @State private var userEmail = ""
    @State private var subject = ""
    @State private var description = ""
    @State private var category = "technical"
    @State private var tickets: [IOSSupportTicketSummary] = []
    @State private var statusMessage = ""
    @State private var isLoadingTickets = false
    @State private var isSubmitting = false

    private var signedInUserId: String {
        iosAuthUserValue(authUserJSON, keys: ["id", "userId", "clientId", "email"])
    }

    private var signedInEmail: String {
        iosAuthUserValue(authUserJSON, keys: ["email", "userEmail"])
    }

    private var isSignedIn: Bool {
        !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSubmit: Bool {
        let hasDescription = !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasGuestEmail = isSignedIn || !userEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasDescription && hasGuestEmail && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Support Context") {
                    LabeledContent("Server", value: context.serverName.isEmpty ? displayServerName(baseURL: context.serverURL) : context.serverName)
                    LabeledContent("Address", value: context.serverURL)
                    if !context.roomName.isEmpty {
                        LabeledContent("Room", value: context.roomName)
                    }
                }

                Section("Request") {
                    TextField("Subject", text: $subject)
                        .textInputAutocapitalization(.sentences)
                        .accessibilityLabel("Subject")
                    TextField("Email", text: $userEmail)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .accessibilityLabel("Email")
                    Picker("Category", selection: $category) {
                        Text("Technical Support").tag("technical")
                        Text("Account Issues").tag("account")
                        Text("Bug Report").tag("bug-report")
                        Text("General Inquiry").tag("general")
                    }
                    TextEditor(text: $description)
                        .frame(minHeight: 140)
                        .accessibilityLabel("Issue description")
                    Text("Ticket details stay private between you and support staff.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Existing Tickets") {
                    if !isSignedIn {
                        Text("Sign in to view your existing tickets for this server.")
                            .foregroundStyle(.secondary)
                    } else if isLoadingTickets {
                        ProgressView("Loading tickets...")
                    } else if tickets.isEmpty {
                        Text("No tickets found for this server or room.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(tickets) { ticket in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ticket.subject)
                                    .font(.headline)
                                Text("\(displaySupportStatus(ticket.status)) • \(displaySupportCategory(ticket.category))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let roomName = ticket.roomName, !roomName.isEmpty {
                                    Text(roomName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                if !statusMessage.isEmpty {
                    Section("Status") {
                        Text(statusMessage)
                            .foregroundStyle(statusMessage.hasPrefix("Ticket created") ? .green : .secondary)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
            }
            .navigationTitle("Server Support")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSubmitting ? "Sending" : "Send") {
                        Task { await submitTicket() }
                    }
                    .disabled(!canSubmit)
                }
            }
            .onAppear {
                if userEmail.isEmpty {
                    userEmail = signedInEmail
                }
                if subject.isEmpty {
                    subject = context.roomName.isEmpty
                        ? "Support request for \(context.serverName)"
                        : "Support request for \(context.roomName)"
                }
                Task { await loadTickets() }
            }
        }
    }

    @MainActor
    private func loadTickets() async {
        guard isSignedIn, !signedInUserId.isEmpty else { return }
        guard var components = URLComponents(string: "\(context.serverURL)/api/support/tickets/user/\(signedInUserId)") else { return }
        components.queryItems = [
            URLQueryItem(name: "serverUrl", value: context.serverURL),
            URLQueryItem(name: "roomId", value: context.roomId)
        ].filter { !($0.value ?? "").isEmpty }
        guard let url = components.url else { return }

        isLoadingTickets = true
        defer { isLoadingTickets = false }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            request.setValue(authToken, forHTTPHeaderField: "x-session-token")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return
            }
            tickets = (try? JSONDecoder().decode([IOSSupportTicketSummary].self, from: data)) ?? []
        } catch {
            tickets = []
        }
    }

    @MainActor
    private func submitTicket() async {
        guard canSubmit, let url = URL(string: "\(context.serverURL)/api/support/tickets") else { return }
        isSubmitting = true
        statusMessage = "Creating ticket..."
        defer { isSubmitting = false }

        let resolvedUserId = signedInUserId.isEmpty ? "ios-guest-\(UUID().uuidString)" : signedInUserId
        let resolvedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "iOS User" : displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedEmail = userEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "VoiceLink support request" : subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let issue = description.trimmingCharacters(in: .whitespacesAndNewlines)

        let payload: [String: Any] = [
            "userId": resolvedUserId,
            "userName": resolvedName,
            "userEmail": resolvedEmail,
            "subject": resolvedSubject,
            "description": issue,
            "category": category,
            "priority": "medium",
            "channel": "ios",
            "serverUrl": context.serverURL,
            "serverName": context.serverName,
            "roomId": context.roomId,
            "roomName": context.roomName,
            "sourceContext": context.sourceContext,
            "platform": "ios",
            "metadata": [
                "serverUrl": context.serverURL,
                "serverName": context.serverName,
                "roomId": context.roomId,
                "roomName": context.roomName,
                "sourceContext": context.sourceContext,
                "platform": "ios",
                "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            ]
        ]

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if isSignedIn {
                request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
                request.setValue(authToken, forHTTPHeaderField: "x-session-token")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  (json["success"] as? Bool) != false else {
                statusMessage = (json["error"] as? String) ?? "Unable to create ticket."
                return
            }
            let ticketId = (json["ticketId"] as? String) ?? (json["ticket"] as? [String: Any])?["id"] as? String ?? "support"
            statusMessage = "Ticket created: \(ticketId)"
            description = ""
            await loadTickets()
        } catch {
            statusMessage = "Unable to create ticket."
        }
    }
}

private struct FederationTab: View {
    @Environment(\.openURL) private var openURL
    @AppStorage("voicelink.displayName") private var displayName = ""
    @Binding var serverURL: String
    @ObservedObject var roomState: IOSRoomMessagingState
    @State private var roomGroups: [FederatedRoomGroup] = []
    @State private var isLoading = false
    @State private var errorMessage = ""
    @State private var activeSession: RoomSessionDestination?
    @State private var activePreview: RoomPreviewDestination?
    @State private var activeDetails: RoomDetailsDestination?
    @State private var activeGroup: FederatedRoomGroup?
    @State private var activeSupportContext: IOSSupportContext?
    @State private var clientVisibility: ClientVisibilitySettings = .allVisible
    @State private var searchText = ""
    @State private var showNativeAccountSignIn = false
    @State private var authRequiredServerURL = ""

    private var normalizedBaseURL: String { normalizeBaseURL(serverURL) }
    private var filteredRoomGroups: [FederatedRoomGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return roomGroups }
        return roomGroups.filter { group in
            group.displayName.lowercased().contains(query)
                || group.choices.contains { choice in
                    choice.serverLabel.lowercased().contains(query)
                        || choice.room.description.lowercased().contains(query)
                        || choice.room.serverDescription.lowercased().contains(query)
                        || choice.room.visibility.lowercased().contains(query)
                        || choice.room.accessType.lowercased().contains(query)
                }
        }
    }

    private func openGroupedRoom(_ group: FederatedRoomGroup, action: String) {
        guard let firstChoice = group.choices.first else { return }
        if group.choices.count == 1 {
            openRoom(firstChoice, action: action)
        } else {
            activeGroup = group
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !errorMessage.isEmpty {
                    Section("Status") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section("Search") {
                    TextField("Search federated rooms", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search federated rooms")
                }

                if isLoading {
                    ProgressView("Loading federated rooms…")
                } else {
                    if !clientVisibility.ios {
                        Section("Rooms") {
                            Text("Federated rooms are hidden on iOS by server settings.")
                                .foregroundStyle(.secondary)
                        }
                    } else if filteredRoomGroups.isEmpty {
                        Section("Rooms") {
                            Text("No federated rooms found.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Section("Rooms") {
                            ForEach(filteredRoomGroups) { group in
                                Button {
                                    openGroupedRoom(group, action: "details")
                                } label: {
                                    federatedRoomRow(for: group)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Choose Server") { activeGroup = group }
                                    if let firstChoice = group.choices.first {
                                        Button("Room Details") { openGroupedRoom(group, action: "details") }
                                        Button("Preview Room") { openGroupedRoom(group, action: "preview") }
                                        Button("Join Room") { openGroupedRoom(group, action: "join") }
                                        Button("Share Room") { shareChoice(firstChoice) }
                                        Button("Contact Server Support") {
                                            activeSupportContext = .room(
                                                baseURL: firstChoice.baseURL,
                                                serverName: firstChoice.serverLabel,
                                                room: firstChoice.room
                                            )
                                        }
                                    }
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("\(group.displayName), \(occupancySummary(users: group.totalUsers, bots: group.totalBots, totalVisible: group.totalVisible)) across \(group.choices.count) servers")
                                .accessibilityHint("Double tap to choose which server copy of this room to open.")
                                .accessibilityAction(named: Text("Choose Server")) { activeGroup = group }
                                .accessibilityAction(named: Text("Preview Room")) { openGroupedRoom(group, action: "preview") }
                                .accessibilityAction(named: Text("Join Room")) { openGroupedRoom(group, action: "join") }
                                .accessibilityAction(named: Text("Contact Server Support")) {
                                    guard let firstChoice = group.choices.first else { return }
                                    activeSupportContext = .room(
                                        baseURL: firstChoice.baseURL,
                                        serverName: firstChoice.serverLabel,
                                        room: firstChoice.room
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Federated Rooms")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { Task { await refreshRooms() } }
            .refreshable { await refreshRooms() }
            .sheet(item: $activeSession) { session in
                RoomSessionView(destination: session, roomState: roomState)
            }
            .sheet(item: $activePreview) { preview in
                RoomPreviewView(destination: preview)
            }
            .sheet(item: $activeDetails) { details in
                RoomDetailsView(destination: details)
            }
            .sheet(item: $activeGroup) { group in
                FederationRoomChoicesView(group: group, onOpen: openRoom, onContactSupport: { context in
                    activeGroup = nil
                    activeSupportContext = context
                })
            }
            .sheet(item: $activeSupportContext) { context in
                IOSSupportTicketSheet(context: context)
            }
            .sheet(isPresented: $showNativeAccountSignIn) {
                IOSAccountSignInView(serverURL: authRequiredServerURL.isEmpty ? normalizedBaseURL : normalizeBaseURL(authRequiredServerURL))
            }
        }
    }

    private func openRoom(_ choice: FederatedRoomChoice, action: String) {
        guard activeSession == nil, activePreview == nil, activeDetails == nil else { return }
        if action == "details" {
            activeSession = nil
            activePreview = nil
            activeDetails = RoomDetailsDestination(
                id: "\(choice.baseURL)|\(choice.room.id)|details",
                room: choice.room,
                serverLabel: choice.serverLabel,
                baseURL: choice.baseURL
            )
            return
        }
        if action == "join" {
            activePreview = nil
            activeSession = RoomSessionDestination(
                roomId: choice.room.id,
                roomName: choice.room.name,
                roomDescription: choice.room.description,
                baseURL: choice.baseURL,
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Guest" : displayName,
                backgroundStream: choice.room.backgroundStream,
                backgroundStreamVolume: choice.room.streamVolume,
                showChatByDefault: choice.room.showChatInIOS,
                chatMessageOrder: choice.room.iosChatMessageOrder,
                chatMessageLimit: choice.room.iosChatMessageLimit,
                canManageRooms: false
            )
            return
        }

        activeSession = nil
        activeDetails = nil
        activePreview = RoomPreviewDestination(
            roomId: choice.room.id,
            roomName: choice.room.name,
            roomDescription: choice.room.description,
            baseURL: choice.baseURL,
            room: choice.room
        )
    }

    @MainActor
    private func refreshRooms() async {
        clientVisibility = await fetchClientVisibility(baseURL: normalizedBaseURL)
        guard clientVisibility.ios else {
            roomGroups = []
            errorMessage = ""
            return
        }

        isLoading = true
        errorMessage = ""
        defer { isLoading = false }

        do {
            let bases = await fetchVisibleFederationBases(preferredBase: normalizedBaseURL)
            let allRooms = try await fetchRoomsAcrossVisibleServers(bases: bases, sortMode: .activity).map { room in
                (room, room.serverApiBase.isEmpty ? normalizedBaseURL : normalizeBaseURL(room.serverApiBase))
            }
            roomGroups = groupFederatedChoices(allRooms: allRooms, fallbackBase: normalizedBaseURL)
        } catch let error as IOSRoomsAuthenticationRequired {
            roomGroups = []
            authRequiredServerURL = error.baseURL
            errorMessage = "A federated server requires sign-in before rooms can be listed. Sign in with any available method."
            showNativeAccountSignIn = true
        } catch {
            roomGroups = []
            errorMessage = "Could not load federated rooms."
        }
    }

    private func shareChoice(_ choice: FederatedRoomChoice) {
        let shareBase = choice.room.serverDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? choice.baseURL
            : "https://\(choice.room.serverDomain)"
        guard let url = URL(string: "\(shareBase)/?room=\(choice.room.id)") else { return }
        openURL(url)
    }

    private func federatedRoomRow(for group: FederatedRoomGroup) -> some View {
        let firstChoice = group.choices.first
        return VStack(alignment: .leading, spacing: 6) {
            Text(group.displayName)
                .font(.headline)
            if let firstChoice {
                Text(displayOptionalDescription(firstChoice.room.description))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("\(occupancySummary(users: group.totalUsers, bots: group.totalBots, totalVisible: group.totalVisible)) • \(group.choices.count) servers")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let firstChoice {
                Text("\(displayRoomLockLabel(firstChoice.room.locked)) • \(displayVisibilityLabel(firstChoice.room.visibility)) • \(displayAccessTypeLabel(firstChoice.room.accessType))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func groupFederatedChoices(allRooms: [(RoomSummary, String)], fallbackBase: String) -> [FederatedRoomGroup] {
        var dedupedByExactKey: [String: (RoomSummary, String)] = [:]
        for (room, fetchedBase) in allRooms {
            let resolvedBase = room.serverApiBase.isEmpty ? fetchedBase : normalizeBaseURL(room.serverApiBase)
            let exactKey = "\(resolvedBase)|\(room.id)"
            dedupedByExactKey[exactKey] = (room, resolvedBase)
        }

        let choices = dedupedByExactKey.values.map { room, resolvedBase in
            let baseURL = resolvedBase.isEmpty ? fallbackBase : resolvedBase
            return FederatedRoomChoice(
                id: "\(baseURL)|\(room.id)",
                room: room,
                serverLabel: displayServerName(room: room, fallbackBase: baseURL),
                baseURL: baseURL
            )
        }

        let grouped = Dictionary(grouping: choices) { choice in
            normalizedFederatedRoomGroupKey(choice.room.name)
        }

        return grouped.values.compactMap { choices in
            let sortedChoices = choices.sorted { lhs, rhs in
                lhs.serverLabel.localizedCaseInsensitiveCompare(rhs.serverLabel) == .orderedAscending
            }
            guard let firstChoice = sortedChoices.first else { return nil }
            return FederatedRoomGroup(
                id: normalizedFederatedRoomGroupKey(firstChoice.room.name),
                displayName: firstChoice.room.name,
                totalUsers: sortedChoices.reduce(0) { $0 + $1.room.userCount },
                totalBots: sortedChoices.reduce(0) { $0 + $1.room.botCount },
                totalVisible: sortedChoices.reduce(0) { $0 + max($1.room.totalVisible, $1.room.userCount + $1.room.botCount) },
                choices: sortedChoices
            )
        }
        .sorted { lhs, rhs in
            if lhs.totalUsers == rhs.totalUsers {
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            return lhs.totalUsers > rhs.totalUsers
        }
    }
}

private struct FederationRoomChoicesView: View {
    let group: FederatedRoomGroup
    let onOpen: (FederatedRoomChoice, String) -> Void
    let onContactSupport: (IOSSupportContext) -> Void

    var body: some View {
        List {
            Section("Room") {
                LabeledContent("Name", value: group.displayName)
                LabeledContent("Servers", value: "\(group.choices.count)")
                LabeledContent("Users and Bots", value: occupancySummary(users: group.totalUsers, bots: group.totalBots, totalVisible: group.totalVisible))
            }

            Section("Choose Server") {
                ForEach(group.choices) { choice in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(choice.serverLabel)
                            .font(.headline)
                        Text(occupancySummary(choice.room))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Details") { onOpen(choice, "details") }
                                .buttonStyle(.borderedProminent)
                            Button("Join") { onOpen(choice, "join") }
                                .buttonStyle(.bordered)
                            Button("Preview") { onOpen(choice, "preview") }
                                .buttonStyle(.bordered)
                        }
                        Button("Contact Server Support") {
                            onContactSupport(.room(baseURL: choice.baseURL, serverName: choice.serverLabel, room: choice.room))
                        }
                    }
                    .contextMenu {
                        Button("Room Details") { onOpen(choice, "details") }
                        Button("Join Room") { onOpen(choice, "join") }
                        Button("Preview Room") { onOpen(choice, "preview") }
                        Button("Contact Server Support") {
                            onContactSupport(.room(baseURL: choice.baseURL, serverName: choice.serverLabel, room: choice.room))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(group.displayName) on \(choice.serverLabel), \(occupancySummary(choice.room))")
                    .accessibilityHint("Double tap for room details. Swipe down for preview and join actions.")
                    .accessibilityAction(named: Text("Room Details")) { onOpen(choice, "details") }
                    .accessibilityAction(named: Text("Join Room")) { onOpen(choice, "join") }
                    .accessibilityAction(named: Text("Preview Room")) { onOpen(choice, "preview") }
                    .accessibilityAction(named: Text("Contact Server Support")) {
                        onContactSupport(.room(baseURL: choice.baseURL, serverName: choice.serverLabel, room: choice.room))
                    }
                }
            }
        }
        .navigationTitle(group.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MessagesTab: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage("voicelink.authToken") private var authToken = ""
    @AppStorage("voicelink.displayName") private var displayName = ""
    @Binding var serverURL: String
    @ObservedObject var roomState: IOSRoomMessagingState
    @ObservedObject private var socketClient = IOSNativeRoomSocketClient.shared
    let openServers: () -> Void

    private var isSignedIn: Bool {
        !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleTargets: [IOSDirectMessageTarget] {
        iosMergedVisibleTargets(primary: roomState.directTargets, secondary: socketClient.roomUsers)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Profile") {
                    if isSignedIn {
                        LabeledContent(
                            "Display Name",
                            value: displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Signed In" : displayName
                        )
                        LabeledContent("Account", value: "Signed In")
                        if let profile = roomState.selectedProfileName {
                            Text("Last selected profile: \(profile)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("You are signed in. Room activity and recent messages appear below.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Guest" : displayName)
                        Text("Guests can browse and join with a name, or use Quick Pair / Sign In for a full account.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Sign In") {
                            openAuthAction("login")
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Device Pair") {
                            openServers()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Section(roomState.isInRoom ? "People in Room" : "Known People") {
                    if visibleTargets.isEmpty {
                        Text("No room users available yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleTargets) { target in
                            Button {
                                roomState.selectedDirectTarget = target
                                roomState.selectedProfileName = target.name
                                roomState.statusText = "Selected \(target.name)."
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: iosUserAudioIconName(target))
                                        .foregroundStyle(target.isSpeaking ? .green : .secondary)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(target.name)
                                        if let deviceSummary = iosUserDeviceSummary(target) {
                                            Text(deviceSummary)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if roomState.selectedDirectTarget?.id == target.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .accessibilityHidden(true)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(roomState.selectedDirectTarget?.id == target.id ? .isSelected : [])
                            .accessibilityHint("Double tap to select this user. Use the direct message field below to send a private message.")
                        }
                    }

                    if let selected = roomState.selectedDirectTarget {
                        Text("Selected: \(selected.name)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if !roomState.isInRoom {
                        Text("Join a room to see live people and room activity.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(roomState.isInRoom ? "Recent Room Messages" : "Recent Activity") {
                    if roomState.roomMessages.isEmpty {
                        Text(roomState.isInRoom ? "No room messages yet." : "Join a room to see activity.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(roomState.roomMessages.suffix(100).reversed()) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(message.author)
                                    .font(.subheadline.weight(.semibold))
                                Text(message.body)
                                    .font(.body)
                                Text(message.roomName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section(roomState.isInRoom ? "Live Transcripts" : "Recent Transcripts") {
                    if roomState.roomTranscripts.isEmpty {
                        Text(roomState.isInRoom ? "No transcripts yet." : "Join a room to receive live transcripts.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(roomState.roomTranscripts.suffix(25).reversed()) { transcript in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(transcript.speaker)
                                    .font(.subheadline.weight(.semibold))
                                Text(transcript.body)
                                    .font(.body)
                                Text(transcript.roomName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if !roomState.statusText.isEmpty {
                    Section("Status") {
                        Text(roomState.statusText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func openAuthAction(_ action: String) {
        guard let encoded = action.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://voicelinkapp.app/client/?open=\(encoded)") else {
            return
        }
        openURL(url)
    }
}

private struct GuestJoinPromptView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var displayName: String
    let openServers: () -> Void
    let continueJoin: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Join as Guest") {
                    TextField("Your name", text: $displayName)
                        .textInputAutocapitalization(.words)
                    Text("Guests can join with a name, or use Quick Pair / Sign In for a full account.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Actions") {
                    Button("Continue to Room") {
                        continueJoin()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!iosHasValidGuestDisplayName(displayName))

                    Button("Device Pair") {
                        dismiss()
                        openServers()
                    }

                    Link("Sign In", destination: URL(string: "https://voicelinkapp.app/client/?open=login")!)
                }
            }
            .navigationTitle("Guest Join")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct ServerJoinPolicyPromptView: View {
    @Environment(\.dismiss) private var dismiss
    let room: RoomSummary?
    let serverName: String
    let isSignedIn: Bool
    let agree: () -> Void
    let disagree: () -> Void

    private var rulesBody: String {
        room?.serverRules.body.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var motdBody: String {
        room?.motd.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    LabeledContent("Name", value: serverName)
                    if let room {
                        LabeledContent("Room", value: room.name)
                    }
                    Text(isSignedIn ? "These server terms apply to account users." : "These server terms apply to guest users.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !rulesBody.isEmpty {
                    Section(room?.serverRules.title.isEmpty == false ? room!.serverRules.title : "Server Rules") {
                        Text(rulesBody)
                    }
                }

                if !motdBody.isEmpty {
                    Section("Message of the Day") {
                        Text(motdBody)
                    }
                }

                if let rules = room?.serverRules {
                    ServerPolicyLinksSection(rules: rules)
                }

                Section("Agreement") {
                    Button("Agree and Join") {
                        agree()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Disagree") {
                        dismiss()
                        disagree()
                    }
                }
            }
            .navigationTitle("Server Terms")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                        disagree()
                    }
                }
            }
        }
    }
}

private struct ServerPolicyLinksSection: View {
    let rules: RoomSummary.ServerRulesSummary

    var body: some View {
        let privacyURL = rules.privacyPolicyUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let validLinks = rules.usefulLinks.filter {
            !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            URL(string: $0.url.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        }

        if !privacyURL.isEmpty || !validLinks.isEmpty {
            Section("Server Links") {
                if !privacyURL.isEmpty, let url = URL(string: privacyURL) {
                    Link("Privacy Policy", destination: url)
                }
                ForEach(validLinks) { link in
                    if let url = URL(string: link.url.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        Link(link.label, destination: url)
                    }
                }
            }
        }
    }
}

func iosHasValidGuestDisplayName(_ raw: String) -> Bool {
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return !normalized.isEmpty && !["guest", "user", "voicelink user"].contains(normalized)
}

func iosUserAudioIconName(_ target: IOSDirectMessageTarget) -> String {
    if target.isDeafened {
        return "speaker.slash.fill"
    }
    if target.isMuted || !target.transmitEnabled {
        return "mic.slash.fill"
    }
    if target.isSpeaking {
        return "waveform.circle.fill"
    }
    return target.isBot ? "sparkles" : "person.wave.2.fill"
}

func iosUserDeviceSummary(_ target: IOSDirectMessageTarget) -> String? {
    let deviceName = target.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    let deviceType = target.deviceType.trimmingCharacters(in: .whitespacesAndNewlines)
    let version = target.clientVersion.trimmingCharacters(in: .whitespacesAndNewlines)
    let summary = [deviceName, deviceType, version.isEmpty ? "" : "v\(version)"]
        .filter { !$0.isEmpty }
        .joined(separator: " • ")
    return summary.isEmpty ? nil : summary
}

func iosMergedVisibleTargets(primary: [IOSDirectMessageTarget], secondary: [IOSDirectMessageTarget]) -> [IOSDirectMessageTarget] {
    func normalizedKey(for target: IOSDirectMessageTarget) -> String {
        let id = target.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty {
            return id
        }
        let name = target.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            return name.lowercased()
        }
        return UUID().uuidString
    }

    let preferred = primary.isEmpty ? secondary : primary
    let fallback = primary.isEmpty ? [] : secondary
    var merged: [String: IOSDirectMessageTarget] = [:]

    preferred.forEach { merged[normalizedKey(for: $0)] = $0 }
    fallback.forEach { target in
        let key = normalizedKey(for: target)
        if merged[key] == nil {
            merged[key] = target
        }
    }

    return merged.values.sorted { lhs, rhs in
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

struct AdminTabView: View {
    @Binding var serverURL: String
    @AppStorage("voicelink.authToken") private var authToken = ""
    @State private var isLoading = false
    @State private var statusText = "Not checked"
    @State private var serverName = "Unknown"
    @State private var maxUsers = "—"
    @State private var maxRooms = "—"
    @State private var draftAdminURL = ""
    @State private var isAdmin = false
    @State private var adminRole = "user"
    @State private var canManageRooms = false
    @State private var adminAccessMessage = "Checking access..."
    @State private var backups: [IOSConfigBackup] = []
    @State private var backupLabel = ""
    @State private var includeFederationSnapshot = true
    @State private var includeLinkedServers = true
    @State private var selectedBackupID: String?
    @State private var backupStatus = ""
    @State private var isRunningBackupAction = false
    @State private var exportFile: IOSSharedFile?
    @State private var adminRooms: [RoomSummary] = []
    @State private var selectedAdminRoomID: String?
    @State private var roomDraftName = ""
    @State private var roomDraftDescription = ""
    @State private var roomDraftVisibility = "public"
    @State private var roomDraftAccessType = "hybrid"
    @State private var roomDraftMaxUsers = "10"
    @State private var roomDraftVisibleToGuests = true
    @State private var roomDraftShowInIOS = true
    @State private var roomOperationStatus = ""
    @State private var isRunningRoomAction = false

    private var normalizedBaseURL: String { normalizeBaseURL(serverURL) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Access") {
                    LabeledContent("Role", value: adminRole.capitalized)
                    LabeledContent("Admin Access", value: isAdmin ? "Granted" : "Restricted")
                    LabeledContent("Room Management", value: canManageRooms ? "Enabled" : "Restricted")
                    Text(adminAccessMessage)
                        .font(.footnote)
                        .foregroundColor((isAdmin || canManageRooms) ? .secondary : .orange)
                }

                if isAdmin {
                    Section("Server Configuration") {
                        TextField("Server URL", text: $draftAdminURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .submitLabel(.go)
                            .onSubmit { applyAdminServerURL() }
                        Button("Apply Server URL") {
                            applyAdminServerURL()
                        }
                    }
                }

                if canManageRooms {
                    Section("Rooms") {
                        if adminRooms.isEmpty {
                            Text("No rooms loaded from this server yet.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Selected Room", selection: $selectedAdminRoomID) {
                                Text("New Room").tag(String?.none)
                                ForEach(adminRooms) { room in
                                    Text(room.name).tag(Optional(room.id))
                                }
                            }
                            .onChange(of: selectedAdminRoomID) { _ in
                                loadSelectedRoomDraft()
                            }
                        }

                        TextField("Room name", text: $roomDraftName)
                            .textInputAutocapitalization(.words)
                        TextField("Room description", text: $roomDraftDescription, axis: .vertical)
                            .lineLimit(2...5)
                        TextField("Maximum users", text: $roomDraftMaxUsers)
                            .keyboardType(.numberPad)
                        Picker("Visibility", selection: $roomDraftVisibility) {
                            Text("Public").tag("public")
                            Text("Private").tag("private")
                            Text("Hidden").tag("hidden")
                        }
                        Picker("Access Type", selection: $roomDraftAccessType) {
                            Text("Hybrid").tag("hybrid")
                            Text("App Only").tag("app-only")
                            Text("Web Only").tag("web-only")
                            Text("Hidden").tag("hidden")
                        }
                        Toggle("Visible to Guests", isOn: $roomDraftVisibleToGuests)
                        Toggle("Show in iOS", isOn: $roomDraftShowInIOS)

                        HStack {
                            Button(selectedAdminRoomID == nil ? "Create Room" : "Save Room") {
                                Task { await saveRoomDraft() }
                            }
                            .disabled(isRunningRoomAction || roomDraftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            Button("New") {
                                clearRoomDraft()
                            }
                            .disabled(isRunningRoomAction)
                        }

                        HStack {
                            Button("Refresh Rooms") {
                                Task { await loadAdminRooms() }
                            }
                            .disabled(isRunningRoomAction)

                            Button("Delete Selected", role: .destructive) {
                                Task { await deleteSelectedRoom() }
                            }
                            .disabled(selectedAdminRoom == nil || isRunningRoomAction)
                        }

                        if !roomOperationStatus.isEmpty {
                            Text(roomOperationStatus)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if isAdmin {
                    Section("Backups") {
                        TextField("Optional backup label", text: $backupLabel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                        Toggle("Include federation snapshot", isOn: $includeFederationSnapshot)
                        Toggle("Include linked server list", isOn: $includeLinkedServers)

                        Button(isRunningBackupAction ? "Creating Backup…" : "Create Remote Backup") {
                            Task { await createBackup() }
                        }
                        .disabled(isRunningBackupAction)

                        if backups.isEmpty {
                            Text("No backups loaded for this server yet.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(backups) { backup in
                                Button {
                                    selectedBackupID = backup.id
                                } label: {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(backup.label?.isEmpty == false ? backup.label! : backup.filename)
                                                .foregroundStyle(.primary)
                                            Text(backup.filename)
                                                .font(.caption.monospaced())
                                                .foregroundStyle(.secondary)
                                            HStack(spacing: 10) {
                                                if let createdAt = backup.createdAt {
                                                    Text(createdAt)
                                                }
                                                if let size = backup.size {
                                                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                                }
                                            }
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if selectedBackupID == backup.id {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.tint)
                                                .accessibilityHidden(true)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(backup.label?.isEmpty == false ? backup.label! : backup.filename)
                                .accessibilityValue(selectedBackupID == backup.id ? "Selected" : "Not selected")
                            }
                        }

                        HStack {
                            Button("Refresh Backups") {
                                Task { await loadBackups() }
                            }
                            .disabled(isRunningBackupAction)

                            Button("Restore Selected", role: .destructive) {
                                Task { await restoreSelectedBackup() }
                            }
                            .disabled(selectedBackup == nil || isRunningBackupAction)
                        }

                        Button("Save Selected to Files") {
                            Task { await exportSelectedBackupToFiles() }
                        }
                        .disabled(selectedBackup == nil || isRunningBackupAction)

                        if !backupStatus.isEmpty {
                            Text(backupStatus)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Server Health") {
                    LabeledContent("Status", value: statusText)
                    Button("Refresh Status") { Task { await refreshStatus() } }
                        .disabled(isLoading)
                }

                Section("Server Config") {
                    LabeledContent("Name", value: serverName)
                    LabeledContent("Max Users", value: maxUsers)
                    LabeledContent("Max Rooms", value: maxRooms)
                }
            }
            .navigationTitle("Admin")
            .onAppear {
                draftAdminURL = serverURL
                Task { await refreshStatus() }
            }
            .sheet(item: $exportFile) { file in
                IOSShareSheet(items: [file.url])
            }
        }
    }

    private func applyAdminServerURL() {
        let trimmed = draftAdminURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        serverURL = trimmed
        Task { await refreshStatus() }
    }

    @MainActor
    private func refreshStatus() async {
        isLoading = true
        defer { isLoading = false }

        guard let healthURL = URL(string: "\(normalizedBaseURL)/api/health"),
              let configURL = URL(string: "\(normalizedBaseURL)/api/config"),
              let adminStatusURL = URL(string: "\(normalizedBaseURL)/api/admin/status") else {
            statusText = "Invalid server URL"
            return
        }

        do {
            let (_, response) = try await URLSession.shared.data(from: healthURL)
            if let http = response as? HTTPURLResponse {
                statusText = (200...299).contains(http.statusCode) ? "Online" : "HTTP \(http.statusCode)"
            } else {
                statusText = "Unknown"
            }
        } catch {
            statusText = "Offline"
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: configURL)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            let resolvedServerName = (
                (json["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? (json["displayName"] as? String)
                    : (json["serverName"] as? String)
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let resolvedServerName, !resolvedServerName.isEmpty {
                serverName = resolvedServerName
                cacheServerDisplayName(
                    resolvedServerName,
                    forBaseURL: serverURL,
                    publicURL: (json["publicUrl"] as? String)
                )
            }
            if let value = json["maxUsers"] as? Int { maxUsers = "\(value)" }
            if let value = json["maxRooms"] as? Int { maxRooms = "\(value)" }
        } catch {
            // keep previous values
        }

        do {
            var request = URLRequest(url: adminStatusURL)
            request.timeoutInterval = 12
            if !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
                request.setValue(authToken, forHTTPHeaderField: "x-session-token")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                isAdmin = false
                canManageRooms = false
                adminRole = "user"
                adminAccessMessage = "Not authenticated for admin API access."
                return
            }
            isAdmin = (json["isAdmin"] as? Bool) ?? false
            let permissions = json["permissions"] as? [String: Any]
            canManageRooms = (json["canManageRooms"] as? Bool) ?? (permissions?["rooms"] as? Bool) ?? isAdmin
            adminRole = String((json["role"] as? String) ?? "user")
            adminAccessMessage = isAdmin
                ? "Server API confirms this account can manage settings."
                : (canManageRooms ? "Community testing access allows room management for this signed-in account." : "Signed-in role is not admin.")
        } catch {
            isAdmin = false
            canManageRooms = false
            adminRole = "user"
            adminAccessMessage = "Could not verify admin role right now."
        }

        if canManageRooms {
            await loadAdminRooms()
        } else {
            adminRooms = []
            selectedAdminRoomID = nil
        }

        if isAdmin {
            await loadBackups()
        } else {
            backups = []
            selectedBackupID = nil
        }
    }

    @MainActor
    private func loadAdminRooms() async {
        guard let url = URL(string: "\(normalizedBaseURL)/api/rooms?source=app&client=ios&sort=name") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(for: authorizedAdminRequest(url: url))
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                roomOperationStatus = "Could not load rooms."
                return
            }
            adminRooms = try JSONDecoder().decode([RoomSummary].self, from: data)
            if let selectedAdminRoomID, adminRooms.contains(where: { $0.id == selectedAdminRoomID }) {
                loadSelectedRoomDraft()
            } else {
                selectedAdminRoomID = adminRooms.first?.id
                loadSelectedRoomDraft()
            }
            if adminRooms.isEmpty {
                clearRoomDraft()
            }
        } catch {
            roomOperationStatus = "Could not load rooms."
        }
    }

    @MainActor
    private func saveRoomDraft() async {
        let trimmedName = roomDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            roomOperationStatus = "Room name is required."
            return
        }
        let maxUsers = max(1, Int(roomDraftMaxUsers.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 10)
        let payload: [String: Any] = [
            "name": trimmedName,
            "description": roomDraftDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            "maxUsers": maxUsers,
            "visibility": roomDraftVisibility,
            "accessType": roomDraftAccessType,
            "visibleToGuests": roomDraftVisibleToGuests,
            "showInIOS": roomDraftShowInIOS,
            "isAuthenticated": true,
            "updatedBy": "VoiceLink iOS Admin"
        ]

        let endpoint: String
        let method: String
        if let selectedAdminRoomID,
           let encodedRoomId = selectedAdminRoomID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            endpoint = "\(normalizedBaseURL)/api/rooms/\(encodedRoomId)"
            method = "PUT"
        } else {
            endpoint = "\(normalizedBaseURL)/api/rooms"
            method = "POST"
        }

        guard let url = URL(string: endpoint) else { return }
        isRunningRoomAction = true
        defer { isRunningRoomAction = false }

        do {
            var request = authorizedAdminRequest(url: url)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                roomOperationStatus = "Room save failed."
                return
            }
            roomOperationStatus = selectedAdminRoomID == nil ? "Room created." : "Room updated."
            await loadAdminRooms()
        } catch {
            roomOperationStatus = "Room save failed."
        }
    }

    @MainActor
    private func deleteSelectedRoom() async {
        guard let selectedAdminRoom,
              let encodedRoomId = selectedAdminRoom.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(normalizedBaseURL)/api/rooms/\(encodedRoomId)") else {
            return
        }
        isRunningRoomAction = true
        defer { isRunningRoomAction = false }

        do {
            var request = authorizedAdminRequest(url: url)
            request.httpMethod = "DELETE"
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                roomOperationStatus = "Delete failed."
                return
            }
            roomOperationStatus = "Deleted \(selectedAdminRoom.name)."
            selectedAdminRoomID = nil
            clearRoomDraft()
            await loadAdminRooms()
        } catch {
            roomOperationStatus = "Delete failed."
        }
    }

    private func loadSelectedRoomDraft() {
        guard let selectedAdminRoom else {
            clearRoomDraft()
            return
        }
        roomDraftName = selectedAdminRoom.name
        roomDraftDescription = selectedAdminRoom.description
        roomDraftVisibility = normalizedRoomVisibility(selectedAdminRoom.visibility)
        roomDraftAccessType = normalizedRoomAccessType(selectedAdminRoom.accessType)
        roomDraftMaxUsers = "10"
        roomDraftVisibleToGuests = selectedAdminRoom.visibility != "private"
        roomDraftShowInIOS = true
    }

    private func clearRoomDraft() {
        selectedAdminRoomID = nil
        roomDraftName = ""
        roomDraftDescription = ""
        roomDraftVisibility = "public"
        roomDraftAccessType = "hybrid"
        roomDraftMaxUsers = "10"
        roomDraftVisibleToGuests = true
        roomDraftShowInIOS = true
    }

    private func authorizedAdminRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(token, forHTTPHeaderField: "x-session-token")
        }
        return request
    }

    @MainActor
    private func loadBackups() async {
        guard let url = URL(string: "\(normalizedBaseURL)/api/config/backups") else { return }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            if !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
                request.setValue(authToken, forHTTPHeaderField: "x-session-token")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return
            }
            let decoded = try JSONDecoder().decode(IOSConfigBackupEnvelope.self, from: data)
            backups = decoded.backups
            if selectedBackupID == nil {
                selectedBackupID = decoded.backups.first?.id
            }
        } catch {
            backupStatus = "Could not load backups right now."
        }
    }

    @MainActor
    private func createBackup() async {
        guard let url = URL(string: "\(normalizedBaseURL)/api/config/backup") else { return }
        isRunningBackupAction = true
        defer { isRunningBackupAction = false }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
                request.setValue(authToken, forHTTPHeaderField: "x-session-token")
            }
            let payload: [String: Any] = [
                "label": backupLabel.trimmingCharacters(in: .whitespacesAndNewlines),
                "includeFederationSnapshot": includeFederationSnapshot,
                "includeLinkedServers": includeLinkedServers
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                backupStatus = "Backup creation failed."
                return
            }
            backupLabel = ""
            backupStatus = "Remote backup created."
            await loadBackups()
        } catch {
            backupStatus = "Backup creation failed."
        }
    }

    @MainActor
    private func restoreSelectedBackup() async {
        guard let backup = selectedBackup,
              let url = URL(string: "\(normalizedBaseURL)/api/config/restore") else { return }
        isRunningBackupAction = true
        defer { isRunningBackupAction = false }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
                request.setValue(authToken, forHTTPHeaderField: "x-session-token")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: ["filename": backup.filename])
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                backupStatus = "Restore failed."
                return
            }
            backupStatus = "Restored \(backup.filename)."
            await refreshStatus()
        } catch {
            backupStatus = "Restore failed."
        }
    }

    @MainActor
    private func exportSelectedBackupToFiles() async {
        guard let backup = selectedBackup,
              let encodedFilename = backup.filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(normalizedBaseURL)/api/config/backups/\(encodedFilename)/download") else { return }
        isRunningBackupAction = true
        defer { isRunningBackupAction = false }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            if !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
                request.setValue(authToken, forHTTPHeaderField: "x-session-token")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                backupStatus = "Could not download the selected backup."
                return
            }
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(backup.filename)
            try? FileManager.default.removeItem(at: destination)
            try data.write(to: destination, options: .atomic)
            exportFile = IOSSharedFile(url: destination)
            backupStatus = "Backup ready to save to Files."
        } catch {
            backupStatus = "Could not download the selected backup."
        }
    }

    private var selectedBackup: IOSConfigBackup? {
        backups.first(where: { $0.id == selectedBackupID })
    }

    private var selectedAdminRoom: RoomSummary? {
        guard let selectedAdminRoomID else { return nil }
        return adminRooms.first(where: { $0.id == selectedAdminRoomID })
    }

    private func normalizedRoomVisibility(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["public", "private", "hidden"].contains(normalized) ? normalized : "public"
    }

    private func normalizedRoomAccessType(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["hybrid", "app-only", "web-only", "hidden"].contains(normalized) ? normalized : "hybrid"
    }
}

private struct IOSConfigBackupEnvelope: Codable {
    let backups: [IOSConfigBackup]
}

private struct IOSConfigBackup: Codable, Identifiable, Hashable {
    let filename: String
    let path: String?
    let createdAt: String?
    let label: String?
    let size: Int?
    let error: Bool?

    var id: String { filename }
}

private struct IOSSharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct IOSShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct SettingsTab: View {
    private static let voiceLinkAccessWhatsAppURL = URL(string: "https://chat.whatsapp.com/HesAnbKsTTN5neH11BxzSz?mode=gi_t")!

    @Environment(\.openURL) private var openURL
    @ObservedObject var roomState: IOSRoomMessagingState
    let openServers: () -> Void
    var onClose: (() -> Void)? = nil
    @AppStorage("voicelink.audio.inputGain") private var inputGain: Double = 1.0
    @AppStorage("voicelink.audio.outputGain") private var outputGain: Double = 1.0
    @AppStorage("voicelink.audio.mediaMuted") private var mediaMuted = false
    @AppStorage("showUserStatusesInRoomList") private var showUserStatusesInRoomList = true
    @AppStorage("voicelink.ios.showRoomRelayDebugDetails") private var showRoomRelayDebugDetails = false
    @AppStorage("allowVoiceInRoomPreview") private var allowVoiceInRoomPreview = true
    @AppStorage("systemActionNotifications") private var systemActionNotificationsEnabled = true
    @AppStorage("systemActionNotificationSound") private var systemActionNotificationSoundEnabled = true
    @AppStorage("voicelink.ios.ttsAnnouncementsEnabled") private var ttsAnnouncementsEnabled = true
    @AppStorage("voicelink.ios.systemAnnouncementsEnabled") private var systemAnnouncementsEnabled = true
    @AppStorage("voicelink.showWebFrontendShortcutOnHome") private var showWebFrontendShortcutOnHome = false
    @AppStorage("voicelink.authToken") private var authToken = ""
    @AppStorage("voicelink.displayName") private var displayName = ""
    @AppStorage("voicelink.authProvider") private var authProvider = ""
    @AppStorage("voicelink.authUserJSON") private var authUserJSON = ""
    @AppStorage("voicelink.autoSendDiagnostics") private var autoSendDiagnostics = true
    @AppStorage("voicelink.shareCrashReports") private var shareCrashReports = true
    @State private var diagnosticsStatus = ""
    @State private var submittingDiagnostics = false
    @State private var showAuthOptions = false
    @State private var showNativeAccountSignIn = false

    private var isSignedIn: Bool {
        !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Audio") {
                    Toggle("Mute Media Playback", isOn: $mediaMuted)
                    Slider(value: $inputGain, in: 0...3) {
                        Text("Input Level")
                    } minimumValueLabel: {
                        Text("0%")
                    } maximumValueLabel: {
                        Text("300%")
                    }
                    .accessibilityValue("\(Int(inputGain * 100)) percent")
                    .accessibilityAdjustableAction { direction in
                        adjustSettingsGain(&inputGain, direction: direction)
                    }

                    Slider(value: $outputGain, in: 0...3) {
                        Text("Output Level")
                    } minimumValueLabel: {
                        Text("0%")
                    } maximumValueLabel: {
                        Text("300%")
                    }
                    .accessibilityValue("\(Int(outputGain * 100)) percent")
                    .accessibilityAdjustableAction { direction in
                        adjustSettingsGain(&outputGain, direction: direction)
                    }

                    Button("Test Sound") {
                        if roomState.isInRoom {
                            NotificationCenter.default.post(name: .iosPlayTestSound, object: nil)
                        } else {
                            IOSActionSoundPlayer.playTest()
                        }
                    }
                    Text("Audio can be boosted up to 300 percent on iOS for quieter rooms or devices.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Interface") {
                    Toggle("Show User Statuses in Room Lists", isOn: $showUserStatusesInRoomList)
                    Toggle("Show Room Relay Debug Details", isOn: $showRoomRelayDebugDetails)
                    Toggle("Allow My Voice in Room Preview", isOn: $allowVoiceInRoomPreview)
                    Toggle("Show Web Frontend Shortcut on Home", isOn: $showWebFrontendShortcutOnHome)
                    Text("Room screens support VoiceOver actions. In a room, use two-finger double-tap to hear who is speaking.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Notifications") {
                    Toggle("Enable System Action Push Notifications", isOn: $systemActionNotificationsEnabled)
                        .onChange(of: systemActionNotificationsEnabled) { enabled in
                            if enabled {
                                requestNotificationAuthorizationIfNeeded()
                            }
                    }
                    Toggle("Play Sound for System Action Notifications", isOn: $systemActionNotificationSoundEnabled)
                    Toggle("Speak Room Announcements", isOn: $ttsAnnouncementsEnabled)
                    Toggle("Speak System Messages in Rooms", isOn: $systemAnnouncementsEnabled)
                    Text("Room join, leave, and system updates can be spoken aloud. Turn these off if you only want visual updates.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Diagnostics") {
                    Toggle("Auto-send diagnostics with bug reports", isOn: $autoSendDiagnostics)
                    Toggle("Include recent crash/session reports", isOn: $shareCrashReports)
                    Button(submittingDiagnostics ? "Sending…" : "Send Diagnostics Report") {
                        submitDiagnosticsReport()
                    }
                    .disabled(submittingDiagnostics)
                    if !diagnosticsStatus.isEmpty {
                        Text(diagnosticsStatus)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    let submissionEntries = UserDefaults.standard.stringArray(forKey: "voicelink.iosDiagnosticsSubmissionLog") ?? []
                    if !submissionEntries.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Recent Submission Activity")
                                .font(.subheadline.weight(.semibold))
                            ForEach(Array(submissionEntries.suffix(8).reversed()), id: \.self) { entry in
                                Text(entry)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                Section("Feedback") {
                    Button("Join VoiceLink Access WhatsApp Group") {
                        openURL(Self.voiceLinkAccessWhatsAppURL)
                    }
                    Text("Use this group for VoiceLink access feedback, beta coordination, and support discussion.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Client Account") {
                    if isSignedIn {
                        LabeledContent("Signed In As", value: displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Client Account" : displayName)
                        Button("Manage Client Account Sign In") {
                            showNativeAccountSignIn = true
                        }
                        Button("Sign Out", role: .destructive) {
                            authToken = ""
                            displayName = ""
                            authProvider = ""
                            authUserJSON = ""
                        }
                    } else {
                        Button("Client Account Sign In") {
                            showNativeAccountSignIn = true
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button(isSignedIn ? "Other Sign-In Methods" : "Quick Pair or Sign In") {
                        showAuthOptions = true
                    }
                    Text("Native Client Account sign-in now uses the server login API directly. Client Account sign-in stays local to the app, while Quick Pair and web sign-in are still available for other server flows.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Help and Policies") {
                    if let webURL = URL(string: "https://voicelinkapp.app") {
                        Link("Open Web Frontend", destination: webURL)
                    }
                    Link("VoiceLink Platform Docs", destination: URL(string: "https://voicelink.dev/docs/")!)
                    Link("Getting Started", destination: URL(string: "https://voicelink.dev/docs/getting-started.html")!)
                    Link("Privacy Policy", destination: URL(string: "https://voicelinkapp.app/docs/privacy-policy.html")!)
                    Link("User Privacy Choices", destination: URL(string: "https://voicelinkapp.app/docs/user-privacy-choices.html")!)
                    Link("Support and Contact", destination: URL(string: "https://voicelinkapp.app/docs/contact.html#live-chat")!)
                    Link("Download Access", destination: URL(string: "https://voicelinkapp.app/downloads/")!)
                    Button("Open Main Website") {
                        guard let url = URL(string: "https://voicelinkapp.app") else { return }
                        openURL(url)
                    }
                }

            }
            .navigationTitle("Settings")
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") {
                            onClose()
                        }
                    }
                }
            }
            .confirmationDialog("Choose a sign-in method", isPresented: $showAuthOptions, titleVisibility: .visible) {
                Button("Quick Pair") {
                    openServers()
                }
                Button("Server Web Sign In") {
                    openAuthAction("login")
                }
                Button("Mastodon") {
                    openAuthAction("mastodon")
                }
                Button("Admin Invite") {
                    openAuthAction("admin-invite")
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Quick Pair lets you link this device to another signed-in device or enter a server pairing or invite code from a server admin.")
            }
            .sheet(isPresented: $showNativeAccountSignIn) {
                IOSAccountSignInView(serverURL: normalizeBaseURL(UserDefaults.standard.string(forKey: "voicelink.serverURL") ?? "https://voicelinkapp.app"))
            }
        }
    }

    private func requestNotificationAuthorizationIfNeeded() {
        Task { @MainActor in
            await IOSPushNotificationManager.shared.syncRegistrationIfNeeded()
        }
    }

    private func openAuthAction(_ action: String) {
        guard let encoded = action.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://voicelinkapp.app/client/?open=\(encoded)") else {
            return
        }
        openURL(url)
    }

    private func submitDiagnosticsReport() {
        submittingDiagnostics = true
        diagnosticsStatus = ""
        IOSDiagnosticsManager.shared.submitBugReport(
            serverURL: normalizeBaseURL(UserDefaults.standard.string(forKey: "voicelink.serverURL") ?? "https://voicelinkapp.app"),
            title: "iOS diagnostics report",
            description: "Manual diagnostics report submitted from iOS settings.",
            category: "diagnostics",
            severity: "medium",
            anonymous: false,
            currentRoom: roomState.activeRoomName.isEmpty ? nil : roomState.activeRoomName,
            sessionStatus: roomState.statusText,
            displayName: displayName
        ) { result in
            submittingDiagnostics = false
            switch result {
            case .success:
                diagnosticsStatus = "Diagnostics report sent."
                UIAccessibility.post(notification: .announcement, argument: diagnosticsStatus)
            case .failure(let error):
                diagnosticsStatus = "Failed to send diagnostics: \(error.localizedDescription)"
                UIAccessibility.post(notification: .announcement, argument: diagnosticsStatus)
            }
        }
    }
}

private func adjustSettingsGain(_ value: inout Double, direction: AccessibilityAdjustmentDirection) {
    let step = 0.05
    switch direction {
    case .increment:
        value = min(3.0, value + step)
    case .decrement:
        value = max(0.0, value - step)
    @unknown default:
        break
    }
}

private struct IOSTwoFactorMethod: Identifiable, Hashable {
    let type: String
    let name: String
    let supportsDelivery: Bool

    var id: String { type }

    static func parse(_ raw: Any?) -> [IOSTwoFactorMethod] {
        guard let entries = raw as? [Any] else { return [] }
        return entries.compactMap { entry in
            guard let dict = entry as? [String: Any] else { return nil }
            let type = String(describing: dict["type"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !type.isEmpty else { return nil }
            let fallbackName = type.replacingOccurrences(of: "-", with: " ").capitalized
            return IOSTwoFactorMethod(
                type: type,
                name: String(describing: dict["name"] ?? fallbackName),
                supportsDelivery: (dict["supportsDelivery"] as? Bool) ?? ["email", "sms", "voice"].contains(type)
            )
        }
    }
}

private struct IOSAccountSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("voicelink.authToken") private var authToken = ""
    @AppStorage("voicelink.displayName") private var displayName = ""
    @AppStorage("voicelink.authProvider") private var authProvider = ""
    @AppStorage("voicelink.authUserJSON") private var authUserJSON = ""

    let serverURL: String

    @State private var identity = ""
    @State private var password = ""
    @State private var twoFactorCode = ""
    @State private var needsTwoFactor = false
    @State private var isLoading = false
    @State private var isSendingCode = false
    @State private var statusMessage = ""
    @State private var availableMethods: [IOSTwoFactorMethod] = []
    @State private var selectedMethod = "email"

    var body: some View {
        NavigationStack {
            Form {
                if isAuthenticated {
                    Section("Signed In") {
                        LabeledContent("Client Account", value: signedInAccountName)
                        if !authProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            LabeledContent("Provider", value: authProviderDisplayName)
                        }
                        Text("Client Account sign-in is confirmed on this device.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Client Account") {
                        TextField("Username or email", text: $identity)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .accessibilityLabel("Username or email")
                        SecureField("Password", text: $password)
                            .accessibilityLabel("Password")
                    }

                    if needsTwoFactor {
                        Section("Verification") {
                            if !availableMethods.isEmpty {
                                Picker("Delivery Method", selection: $selectedMethod) {
                                    ForEach(availableMethods) { method in
                                        Text(method.name).tag(method.type)
                                    }
                                }
                                .accessibilityLabel("Verification delivery method")
                            }

                            if availableMethods.contains(where: { $0.supportsDelivery }) {
                                Button(sendButtonTitle) {
                                    requestTwoFactorCode()
                                }
                                .disabled(identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || isSendingCode)
                            }

                            TextField("Verification code", text: $twoFactorCode)
                                .keyboardType(.numberPad)
                                .textContentType(.oneTimeCode)
                                .accessibilityLabel("Verification code")
                        }
                    }
                }

                if !statusMessage.isEmpty {
                    Section("Status") {
                        Text(statusMessage)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Sign-in status")
                    }
                }

                Section("Actions") {
                    if isAuthenticated {
                        Button("Sign Out", role: .destructive) {
                            signOut()
                        }
                    } else {
                        Button(needsTwoFactor ? "Verify and Sign In" : "Sign In") {
                            signIn()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || isLoading)
                    }
                }
            }
            .navigationTitle("Client Account Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var isAuthenticated: Bool {
        !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var signedInAccountName: String {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? "Client Account" : trimmedName
    }

    private var authProviderDisplayName: String {
        let normalizedProvider = authProvider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["whmcs", "local", "voicelink"].contains(normalizedProvider) {
            return "Client Account"
        }
        return normalizedProvider.replacingOccurrences(of: "-", with: " ").capitalized
    }

    private var sendButtonTitle: String {
        switch selectedMethod {
        case "voice":
            return "Call Me the Code"
        case "sms":
            return "Text Me the Code"
        default:
            return "Send Code"
        }
    }

    private func signIn() {
        isLoading = true
        statusMessage = needsTwoFactor ? "Verifying code..." : "Signing in..."
        attemptSignIn(providers: ["local", "whmcs"])
    }

    private func attemptSignIn(providers: [String]) {
        guard let provider = providers.first,
              let url = URL(string: "\(serverURL)/api/auth/\(provider)/login") else {
            isLoading = false
            statusMessage = "Invalid server URL."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "identity": identity,
            "password": password
        ]
        let trimmedCode = twoFactorCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCode.isEmpty {
            body["twoFactorCode"] = trimmedCode
        }
        if provider == "whmcs" {
            body["portalSite"] = "devine-creations.com"
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                if let error {
                    isLoading = false
                    statusMessage = error.localizedDescription
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    isLoading = false
                    statusMessage = "Authentication failed."
                    return
                }

                if (json["requires2FA"] as? Bool) == true {
                    isLoading = false
                    needsTwoFactor = true
                    availableMethods = IOSTwoFactorMethod.parse(json["availableMethods"])
                    if let first = availableMethods.first {
                        selectedMethod = first.type
                    }
                    statusMessage = (json["error"] as? String) ?? (json["message"] as? String) ?? "Verification code required."
                    return
                }

                if (json["success"] as? Bool) == true,
                   let user = json["user"] as? [String: Any] {
                    authToken = String(describing: json["token"] ?? json["accessToken"] ?? user["accessToken"] ?? "")
                    let resolvedName = String(
                        describing: user["displayName"] ?? user["fullName"] ?? user["username"] ?? user["email"] ?? "VoiceLink User"
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                    displayName = resolvedName
                    let resolvedProvider = String(describing: user["authProvider"] ?? provider)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    authProvider = resolvedProvider.isEmpty ? provider : resolvedProvider
                    authUserJSON = encodeAuthUserPayload(user)
                    statusMessage = "Signed in as \(resolvedName)."
                    identity = ""
                    password = ""
                    needsTwoFactor = false
                    twoFactorCode = ""
                    availableMethods = []
                    UIAccessibility.post(notification: .announcement, argument: statusMessage)
                    Task { @MainActor in
                        await IOSPushNotificationManager.shared.syncRegistrationIfNeeded()
                    }
                    isLoading = false
                    return
                }

                let message = (json["error"] as? String) ?? (json["message"] as? String) ?? "Authentication failed."
                let isRetryable = provider == "local" && providers.count > 1 && {
                    let lowered = message.lowercased()
                    return lowered.contains("invalid credentials")
                        || lowered.contains("account not found")
                        || lowered.contains("user not found")
                        || lowered.contains("unknown user")
                }()
                if isRetryable {
                    attemptSignIn(providers: Array(providers.dropFirst()))
                    return
                }

                isLoading = false
                statusMessage = message
            }
        }.resume()
    }

    private func signOut() {
        authToken = ""
        displayName = ""
        authProvider = ""
        authUserJSON = ""
        identity = ""
        password = ""
        twoFactorCode = ""
        availableMethods = []
        needsTwoFactor = false
        statusMessage = "Signed out."
        UIAccessibility.post(notification: .announcement, argument: statusMessage)
    }

    private func requestTwoFactorCode() {
        guard let url = URL(string: "\(serverURL)/api/auth/local/2fa/challenge") else {
            statusMessage = "Invalid server URL."
            return
        }

        isSendingCode = true
        statusMessage = "Sending verification code..."

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "identity": identity,
            "password": password,
            "method": selectedMethod
        ])

        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                isSendingCode = false
                if let error {
                    statusMessage = error.localizedDescription
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    statusMessage = "Unable to send verification code."
                    return
                }

                availableMethods = IOSTwoFactorMethod.parse(json["availableMethods"])
                if (json["success"] as? Bool) == true {
                    let hint = String(describing: json["hint"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if hint.isEmpty {
                        statusMessage = "\(sendButtonTitle) requested."
                    } else {
                        statusMessage = "\(sendButtonTitle) requested for \(hint)."
                    }
                } else {
                    statusMessage = (json["error"] as? String) ?? (json["message"] as? String) ?? "Unable to send verification code."
                }
            }
        }.resume()
    }
}

private func normalizeBaseURL(_ rawURL: String) -> String {
    let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return "https://voicelinkapp.app"
    }
    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
        let normalized = trimmed.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        if let url = URL(string: normalized),
           let host = url.host?.lowercased(),
           let scheme = url.scheme?.lowercased(),
           let port = url.port,
           [3010, 3011, 3012].contains(port) {
            return "\(scheme)://\(host):\(port)"
        }
        if let url = URL(string: normalized),
           let host = url.host?.lowercased(),
           ["node2.voicelink.devinecreations.net", "voicelink.dev"].contains(host) {
            return "https://community.voicelinkapp.app"
        }
        if let url = URL(string: normalized),
           let host = url.host?.lowercased(),
           host == "voicelink.devinecreations.net" {
            return "https://voicelinkapp.app"
        }
        if let url = URL(string: normalized),
           let host = url.host?.lowercased(),
           [
               "voicelinkapp.app",
               "community.voicelinkapp.app",
               "tappedin.fm"
           ].contains(host) {
            return "https://\(host)"
        }
        return normalized
    }
    if let port = Int(trimmed.split(separator: ":").last ?? ""),
       [3010, 3011, 3012].contains(port) {
        return "http://\(trimmed)"
    }
    return "https://\(trimmed)"
}

private func iOSMainAPIBaseCandidates(preferredBase: String) -> [String] {
    var candidates: [String] = []
    let preferred = normalizeBaseURL(preferredBase)
    if !preferred.isEmpty {
        candidates.append(preferred)
    }
    candidates.append("https://voicelinkapp.app")
    candidates.append("https://community.voicelinkapp.app")
    candidates.append("https://devine-creations.com/voicelink")
    candidates.append("https://devinecreations.net")

    var seen = Set<String>()
    return candidates.filter { seen.insert(canonicalServerIdentity(baseURL: $0, room: nil)).inserted }
}

private struct IOSRoomsAuthenticationRequired: Error, LocalizedError {
    let baseURL: String

    var errorDescription: String? {
        "Authentication required for \(displayServerName(baseURL: baseURL))."
    }
}

private struct IOSRoomFetchBatch {
    let rooms: [RoomSummary]
    let authRequiredBase: String?
}

private func fetchRoomsWithFallback(sortMode: RoomSortMode, preferredBase: String) async throws -> ([RoomSummary], String) {
    var lastError: Error?
    for base in iOSMainAPIBaseCandidates(preferredBase: preferredBase) {
        let endpoint = "\(normalizeBaseURL(base))/api/rooms?source=app&client=ios&sort=\(sortMode.rawValue)"
        guard let url = URL(string: endpoint) else { continue }
        let request = iosServerPresenceRequest(url: url, timeout: 12)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                if http.statusCode == 401 || http.statusCode == 403 {
                    lastError = IOSRoomsAuthenticationRequired(baseURL: normalizeBaseURL(base))
                }
                continue
            }
            let decodedRooms = try JSONDecoder().decode([RoomSummary].self, from: data)
                .map { $0.normalizedForFetchedBase(base) }
            return (decodedRooms, normalizeBaseURL(base))
        } catch {
            lastError = error
        }
    }
    throw lastError ?? URLError(.cannotConnectToHost)
}

private func fetchVisibleFederationBases(preferredBase: String) async -> [String] {
    var discovered = iOSMainAPIBaseCandidates(preferredBase: preferredBase)
    var index = 0

    while index < discovered.count {
        let base = discovered[index]
        index += 1

        guard let statusURL = URL(string: "\(base)/api/federation/status") else {
            continue
        }

        let request = iosServerPresenceRequest(url: statusURL, timeout: 8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                continue
            }
            let raw = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            if let directory = raw["serverDirectory"] as? [[String: Any]] {
                for entry in directory {
                    let apiURL = (entry["apiUrl"] as? String) ?? (entry["url"] as? String) ?? ""
                    let normalized = normalizeBaseURL(apiURL)
                    if !normalized.isEmpty, !discovered.contains(normalized) {
                        discovered.append(normalized)
                    }
                    if let name = entry["name"] as? String, !name.isEmpty {
                        cacheServerDisplayName(name, forBaseURL: normalized)
                    }
                }
            }
            let trusted = (raw["trustedServers"] as? [String]) ?? []
            for entry in trusted {
                let normalizedTrusted = normalizeBaseURL(entry)
                if !discovered.contains(normalizedTrusted) {
                    discovered.append(normalizedTrusted)
                }
            }
            if let discoveryURL = URL(string: "\(base)/api/discovery/servers") {
                let discoveryRequest = iosServerPresenceRequest(url: discoveryURL, timeout: 8)
                let (discoveryData, discoveryResponse) = try await URLSession.shared.data(for: discoveryRequest)
                if let discoveryHTTP = discoveryResponse as? HTTPURLResponse, (200...299).contains(discoveryHTTP.statusCode),
                   let discoveryRaw = (try JSONSerialization.jsonObject(with: discoveryData) as? [String: Any]),
                   let servers = discoveryRaw["servers"] as? [[String: Any]] {
                    for server in servers {
                        if (server["listedInDirectory"] as? Bool) == false && (server["revealRequired"] as? Bool) == true {
                            continue
                        }
                        let apiURL = (server["apiUrl"] as? String) ?? (server["url"] as? String) ?? ""
                        let normalized = normalizeBaseURL(apiURL)
                        if !normalized.isEmpty, !discovered.contains(normalized) {
                            discovered.append(normalized)
                        }
                        if let name = server["name"] as? String, !name.isEmpty {
                            cacheServerDisplayName(name, forBaseURL: normalized, publicURL: server["siteUrl"] as? String)
                        }
                    }
                }
            }
        } catch {
            continue
        }
    }

    var visibleBases: [String] = []
    for base in discovered {
        let visibility = await fetchClientVisibility(baseURL: base)
        if visibility.ios {
            visibleBases.append(normalizeBaseURL(base))
        }
    }

    if visibleBases.isEmpty {
        visibleBases = [normalizeBaseURL(preferredBase)]
    }

    var seen = Set<String>()
    return visibleBases
        .filter { seen.insert(canonicalServerIdentity(baseURL: $0, room: nil)).inserted }
        .sorted {
            displayServerName(baseURL: $0).localizedCaseInsensitiveCompare(displayServerName(baseURL: $1)) == .orderedAscending
        }
}

private func fetchRoomsAcrossVisibleServers(bases: [String], sortMode: RoomSortMode) async throws -> [RoomSummary] {
    try await withThrowingTaskGroup(of: IOSRoomFetchBatch.self) { group in
        for base in bases {
            group.addTask {
                let endpoint = "\(normalizeBaseURL(base))/api/rooms?source=app&client=ios&sort=\(sortMode.rawValue)"
                guard let url = URL(string: endpoint) else { return IOSRoomFetchBatch(rooms: [], authRequiredBase: nil) }
                let request = iosServerPresenceRequest(url: url, timeout: 12)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    return IOSRoomFetchBatch(rooms: [], authRequiredBase: nil)
                }
                if http.statusCode == 401 || http.statusCode == 403 {
                    return IOSRoomFetchBatch(rooms: [], authRequiredBase: normalizeBaseURL(base))
                }
                guard (200...299).contains(http.statusCode) else {
                    return IOSRoomFetchBatch(rooms: [], authRequiredBase: nil)
                }
                let rooms = try JSONDecoder().decode([RoomSummary].self, from: data)
                    .map { $0.normalizedForFetchedBase(base) }
                return IOSRoomFetchBatch(rooms: rooms, authRequiredBase: nil)
            }
        }

        var rooms: [RoomSummary] = []
        var firstAuthRequiredBase: String?
        for try await batch in group {
            rooms.append(contentsOf: batch.rooms)
            if firstAuthRequiredBase == nil {
                firstAuthRequiredBase = batch.authRequiredBase
            }
        }
        if rooms.isEmpty, let firstAuthRequiredBase {
            throw IOSRoomsAuthenticationRequired(baseURL: firstAuthRequiredBase)
        }
        return rooms
    }
}

private func canonicalRoomName(_ name: String) -> String {
    let lowered = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return lowered.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
}

private let serverDisplayNameDefaultsKey = "voicelink.serverDisplayNameMap"

private struct ConfiguredServerPresentation {
    let name: String
    let domain: String
    let description: String
}

private func configuredServerPresentation(baseURL: String) -> ConfiguredServerPresentation? {
    guard let url = URL(string: normalizeBaseURL(baseURL)),
          let host = url.host?.lowercased(),
          !host.isEmpty else {
        return nil
    }

    let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    switch host {
    case "voicelinkapp.app", "www.voicelinkapp.app", "64.20.46.178":
        return ConfiguredServerPresentation(
            name: "VoiceLink Main",
            domain: "voicelinkapp.app",
            description: "Official VoiceLink server."
        )
    case "community.voicelinkapp.app", "www.community.voicelinkapp.app", "64.20.46.179":
        return ConfiguredServerPresentation(
            name: "VoiceLink Community",
            domain: "community.voicelinkapp.app",
            description: "Community server for rooms, testing, and federation."
        )
    case "devine-creations.com", "www.devine-creations.com":
        guard path == "voicelink" || path.isEmpty else { return nil }
        return ConfiguredServerPresentation(
            name: "DevineCreations VoiceLink from DevineCreations on devine-creations.com",
            domain: "devine-creations.com",
            description: "DevineCreations VoiceLink server for devine-creations.com."
        )
    case "devinecreations.net", "www.devinecreations.net":
        guard path == "voicelink" || path.isEmpty else { return nil }
        return ConfiguredServerPresentation(
            name: "DevineCreations VoiceLink from DevineCreations on devinecreations.net",
            domain: "devinecreations.net",
            description: "DevineCreations VoiceLink community server for devinecreations.net."
        )
    default:
        return nil
    }
}

private func cachedServerDisplayName(forBaseURL baseURL: String) -> String? {
    let identity = canonicalServerIdentity(baseURL: baseURL, room: nil)
    guard !identity.isEmpty,
          let mapping = UserDefaults.standard.dictionary(forKey: serverDisplayNameDefaultsKey) as? [String: String],
          let value = mapping[identity]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else {
        return nil
    }
    return value
}

private func cacheServerDisplayName(_ displayName: String, forBaseURL baseURL: String, publicURL: String? = nil) {
    let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedDisplayName.isEmpty else { return }
    var mapping = UserDefaults.standard.dictionary(forKey: serverDisplayNameDefaultsKey) as? [String: String] ?? [:]
    let identities = [
        canonicalServerIdentity(baseURL: baseURL, room: nil),
        canonicalServerIdentity(baseURL: publicURL ?? "", room: nil)
    ].filter { !$0.isEmpty }
    for identity in identities {
        mapping[identity] = trimmedDisplayName
    }
    UserDefaults.standard.set(mapping, forKey: serverDisplayNameDefaultsKey)
}

private func fallbackServerLabel(baseURL: String) -> String {
    if let host = URL(string: normalizeBaseURL(baseURL))?.host,
       !host.isEmpty,
       !isIPAddressValue(host) {
        return host
    }
    return "Unknown Server"
}

private func displayServerName(room: RoomSummary, fallbackBase: String) -> String {
    let roomBase = room.serverApiBase.isEmpty ? fallbackBase : room.serverApiBase
    if let configured = configuredServerPresentation(baseURL: roomBase) {
        return configured.name
    }
    let trimmedTitle = room.serverTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedTitle.isEmpty {
        cacheServerDisplayName(trimmedTitle, forBaseURL: roomBase)
        return trimmedTitle
    }
    if let cached = cachedServerDisplayName(forBaseURL: roomBase) {
        return cached
    }
    let trimmedDomain = room.serverDomain.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedDomain.isEmpty, !isIPAddressValue(trimmedDomain) {
        return trimmedDomain
    }
    if let host = URL(string: fallbackBase)?.host, !host.isEmpty, !isIPAddressValue(host) {
        return host
    }
    return room.serverSource.isEmpty ? fallbackServerLabel(baseURL: fallbackBase) : room.serverSource.capitalized
}

private func displayServerName(baseURL: String) -> String {
    if let configured = configuredServerPresentation(baseURL: baseURL) {
        return configured.name
    }
    if let cached = cachedServerDisplayName(forBaseURL: baseURL) {
        return cached
    }
    return fallbackServerLabel(baseURL: baseURL)
}

private func displayOptionalDescription(_ rawDescription: String) -> String {
    let trimmed = rawDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "No room description available." : trimmed
}

private func canonicalServerIdentity(baseURL: String, room: RoomSummary?) -> String {
    let normalizedBase = normalizeBaseURL(baseURL)
    let baseURLValue = URL(string: normalizedBase)
    let baseHost = baseURLValue?.host?.lowercased() ?? ""
    let basePath = baseURLValue?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() ?? ""
    let baseIdentity = [baseHost, basePath]
        .filter { !$0.isEmpty }
        .joined(separator: "/")
    let roomDomain = room?.serverDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    let roomTitle = room?.serverTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    let roomSource = room?.serverSource.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

    if ["64.20.46.178", "voicelinkapp.app", "www.voicelinkapp.app"].contains(baseHost) {
        return "voicelinkapp.app"
    }
    if ["64.20.46.179", "community.voicelinkapp.app", "www.community.voicelinkapp.app"].contains(baseHost) {
        return "community.voicelinkapp.app"
    }
    if !baseHost.isEmpty, !isIPAddressValue(baseHost) {
        return baseIdentity.isEmpty ? baseHost : baseIdentity
    }

    let candidates = [roomDomain, roomTitle, roomSource].filter { !$0.isEmpty }
    if candidates.contains(where: { $0.contains("voicelink main") }) {
        return "voicelinkapp.app"
    }
    if candidates.contains(where: { $0.contains("voicelink community") }) {
        return "community.voicelinkapp.app"
    }
    if !roomDomain.isEmpty, !isIPAddressValue(roomDomain) {
        return roomDomain
    }
    if !roomSource.isEmpty {
        return roomSource
    }
    return normalizedBase
}

private func isIPAddressValue(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.range(of: #"^\d{1,3}(?:\.\d{1,3}){3}$"#, options: .regularExpression) != nil
}

private func displayVisibilityLabel(_ raw: String) -> String {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "public":
        return "Public"
    case "private":
        return "Private"
    case "unlisted":
        return "Unlisted"
    default:
        return raw.isEmpty ? "Public" : raw.capitalized
    }
}

private func displayRoomLockLabel(_ locked: Bool) -> String {
    locked ? "Locked" : "Unlocked"
}

private func displayAccessTypeLabel(_ raw: String) -> String {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "hybrid":
        return "Desktop, iOS, Web"
    case "app-only":
        return "Desktop, iOS"
    case "web-only":
        return "Web"
    case "hidden":
        return "Hidden"
    default:
        return raw.isEmpty ? "Desktop, iOS, Web" : raw.capitalized
    }
}

private func displaySupportStatus(_ raw: String) -> String {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "open":
        return "Open"
    case "in_progress":
        return "In Progress"
    case "waiting_user":
        return "Waiting on You"
    case "waiting_support":
        return "Waiting on Support"
    case "resolved":
        return "Resolved"
    case "closed":
        return "Closed"
    default:
        return raw.isEmpty ? "Open" : raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private func displaySupportCategory(_ raw: String) -> String {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "technical":
        return "Technical Support"
    case "account":
        return "Account Issues"
    case "bug-report":
        return "Bug Report"
    case "feature-request":
        return "Feature Request"
    case "billing":
        return "Billing"
    case "general":
        return "General Inquiry"
    default:
        return raw.isEmpty ? "General Inquiry" : raw.replacingOccurrences(of: "-", with: " ").capitalized
    }
}

private func iosAuthUserValue(_ rawJSON: String, keys: [String]) -> String {
    guard let data = rawJSON.data(using: .utf8),
          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return ""
    }
    for key in keys {
        if let value = payload[key] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let value = payload[key] as? Int {
            return String(value)
        }
    }
    return ""
}

private func fetchClientVisibility(baseURL: String) async -> ClientVisibilitySettings {
    guard let url = URL(string: "\(normalizeBaseURL(baseURL))/api/config") else {
        return .allVisible
    }

    let request = iosServerPresenceRequest(url: url, timeout: 10)

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return .allVisible
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let visibility = json["serverVisibility"] as? [String: Any]
        else {
            return .allVisible
        }

        return ClientVisibilitySettings(
            desktop: (visibility["desktop"] as? Bool) ?? true,
            ios: (visibility["ios"] as? Bool) ?? true,
            web: (visibility["web"] as? Bool) ?? true,
            frontendOpen: (visibility["frontendOpen"] as? Bool) ?? true
        )
    } catch {
        return .allVisible
    }
}

private func occupancySummary(_ room: RoomSummary) -> String {
    occupancySummary(users: room.userCount, bots: room.botCount, totalVisible: room.totalVisible)
}

private func occupancySummary(users: Int, bots: Int, totalVisible: Int) -> String {
    let safeUsers = max(0, users)
    let safeBots = max(0, bots)
    let safeVisible = max(totalVisible, safeUsers + safeBots)
    var parts = ["\(safeUsers) \(safeUsers == 1 ? "user" : "users")"]
    if safeBots > 0 {
        parts.append("\(safeBots) \(safeBots == 1 ? "bot" : "bots")")
    }
    if safeVisible > safeUsers + safeBots {
        parts.append("\(safeVisible) visible")
    }
    return parts.joined(separator: " • ")
}

private func iosServerPresenceRequest(url: URL, timeout: TimeInterval) -> URLRequest {
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    request.setValue("ios", forHTTPHeaderField: "x-voicelink-client")
    request.setValue("presence", forHTTPHeaderField: "x-voicelink-connection-mode")
    let defaults = UserDefaults.standard
    let token = (defaults.string(forKey: "voicelink.authToken") ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if !token.isEmpty {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(token, forHTTPHeaderField: "x-session-token")
        request.setValue("account", forHTTPHeaderField: "x-voicelink-auth-level")
    } else {
        let displayName = (defaults.string(forKey: "voicelink.displayName") ?? "Guest")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        request.setValue("guest", forHTTPHeaderField: "x-voicelink-auth-level")
        request.setValue(displayName.isEmpty ? "Guest" : displayName, forHTTPHeaderField: "x-voicelink-user")
    }
    return request
}

private func encodeAuthUserPayload(_ payload: [String: Any]) -> String {
    guard JSONSerialization.isValidJSONObject(payload),
          let data = try? JSONSerialization.data(withJSONObject: payload),
          let json = String(data: data, encoding: .utf8) else {
        return ""
    }
    return json
}
