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
        .onAppear {
            IOSActionSoundPlayer.playStartupIntroIfNeeded()
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
        let switchingRooms = !activeRoomId.isEmpty && !roomId.isEmpty && activeRoomId != roomId
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
            isInRoom = false
            activeRoomId = ""
            activeRoomName = ""
            selectedDirectTarget = nil
            statusText = "Left room."
            roomTranscripts.removeAll()
            directTargets.removeAll()
            roomMessages.removeAll()
        }
    }

    private func handleRoomUsers(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        let roomId = normalizedIOSSocketValue(info["roomId"], fallback: activeRoomId)
        if activeRoomId.isEmpty, !roomId.isEmpty {
            activeRoomId = roomId
            isInRoom = true
        }
        guard roomId.isEmpty || roomId == activeRoomId || activeRoomId.isEmpty else { return }
        let rawUsers = iosUsersArray(from: info)
        guard !rawUsers.isEmpty || !directTargets.isEmpty else { return }
        let mapped = rawUsers.enumerated().compactMap { index, entry -> IOSDirectMessageTarget? in
            let user = (entry as? [String: Any]) ?? ((entry as? NSDictionary) as? [String: Any]) ?? [:]
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
        if isInRoom || !mapped.isEmpty {
            directTargets = mapped.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        } else {
            for target in mapped {
                upsertDirectTarget(target)
            }
        }
        if let selected = selectedDirectTarget, !directTargets.contains(selected) {
            selectedDirectTarget = directTargets.first
        }
        if isInRoom {
            let visibleCount = directTargets.count
            if visibleCount > 0 {
                statusText = "\(visibleCount) room user\(visibleCount == 1 ? "" : "s") available."
            }
        }
    }

    private func handleRoomUserJoined(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        let roomId = normalizedIOSSocketValue(info["roomId"], fallback: activeRoomId)
        guard roomId == activeRoomId || (activeRoomId.isEmpty && !roomId.isEmpty) else { return }
        if activeRoomId.isEmpty, !roomId.isEmpty {
            activeRoomId = roomId
            isInRoom = true
        }
        if let user = iosUserDictionary(from: info["user"]) {
            let mapped = mapIOSRoomUser(user, roomId: roomId, index: directTargets.count)
            upsertDirectTarget(mapped)
            statusText = "\(mapped.name) joined \(activeRoomName.isEmpty ? "the room" : activeRoomName)."
            if !mapped.isBot {
                announcementManager.announce("\(mapped.name) joined the room.")
            }
        }
    }

    private func handleRoomUserLeft(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        let roomId = normalizedIOSSocketValue(info["roomId"], fallback: activeRoomId)
        guard roomId == activeRoomId || roomId.isEmpty else { return }
        let userId = normalizedIOSSocketValue(info["userId"], fallback: "")
        let userName = normalizedIOSSocketValue(info["userName"], fallback: "User")
        if !userId.isEmpty {
            directTargets.removeAll { $0.id == userId }
        } else if !userName.isEmpty {
            directTargets.removeAll { $0.name.caseInsensitiveCompare(userName) == .orderedSame }
        }
        statusText = "\(userName) left \(activeRoomName.isEmpty ? "the room" : activeRoomName)."
        announcementManager.announce("\(userName) left the room.")
    }

    private func handleRoomMessage(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        let roomId = normalizedIOSSocketValue(info["roomId"], fallback: activeRoomId)
        let roomName = normalizedIOSSocketValue(info["roomName"], fallback: activeRoomName)
        let senderId = normalizedIOSSocketValue(info["userId"], fallback: "")
        let author = normalizedIOSSocketValue(info["author"], fallback: "User")
        let body = normalizedIOSSocketValue(info["body"], fallback: "")
        let incomingType = normalizedIOSSocketValue(info["type"], fallback: "")
        let type = incomingType.isEmpty && (info["isBot"] as? Bool) == true ? "bot" : (incomingType.isEmpty ? "text" : incomingType)
        let ts = info["timestamp"] as? TimeInterval ?? Date().timeIntervalSince1970
        guard !roomId.isEmpty, !body.isEmpty else { return }
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
        if roomId == activeRoomId, type == "system" || type == "bot" {
            announcementManager.announceSystemMessage(body, author: author)
        }
    }

    private func handleDirectMessage(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        let userId = normalizedIOSSocketValue(info["userId"], fallback: "")
        let userName = normalizedIOSSocketValue(info["userName"], fallback: "User")
        guard !userId.isEmpty else { return }
        let target = IOSDirectMessageTarget(id: userId, name: userName.isEmpty ? "User" : userName)
        upsertDirectTarget(target)
        if selectedDirectTarget == nil {
            selectedDirectTarget = target
        }
    }

    private func handleRoomTranscript(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        let roomId = normalizedIOSSocketValue(info["roomId"], fallback: activeRoomId)
        let roomName = normalizedIOSSocketValue(info["roomName"], fallback: activeRoomName)
        let speaker = normalizedIOSSocketValue(
            info["speaker"] ?? info["userName"] ?? info["author"],
            fallback: "Speaker"
        )
        let body = normalizedIOSSocketValue(info["body"] ?? info["text"], fallback: "")
        let ts = info["timestamp"] as? TimeInterval ?? Date().timeIntervalSince1970
        guard !roomId.isEmpty, !body.isEmpty else { return }
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

    if let messages = info["messages"] as? [Any] {
        return normalizeArray(messages)
    }
    if let messages = info["messages"] as? NSArray {
        return normalizeArray(messages.compactMap { $0 })
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
    if let room = info["room"] as? [String: Any], let messages = room["messages"] as? [Any] {
        return normalizeArray(messages)
    }
    if let room = info["room"] as? [AnyHashable: Any], let messages = room["messages"] as? [Any] {
        return normalizeArray(messages)
    }
    if let room = info["room"] as? NSDictionary, let messages = room["messages"] as? [Any] {
        return normalizeArray(messages)
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

    private let synthesizer = AVSpeechSynthesizer()

    func announce(_ message: String, interrupt: Bool = false) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
        guard announcementsEnabled else { return }
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

    private var announcementsEnabled: Bool {
        if UserDefaults.standard.object(forKey: "voicelink.ios.ttsAnnouncementsEnabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "voicelink.ios.ttsAnnouncementsEnabled")
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
    let id: String
    let name: String
    let description: String
    let userCount: Int
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
    let showChatInIOS: Bool
    let iosChatMessageOrder: String
    let iosChatMessageLimit: Int

    private enum CodingKeys: String, CodingKey {
        case id, name, description, users, userCount, memberCount, visibility, accessType, locked, serverSource, serverTitle, serverApiBase, serverDomain, serverDescription, federated, federationTier, backgroundStream, streamVolume, showChatInIOS, iosChatMessageOrder, iosChatMessageLimit
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
        showChatInIOS = (try? container.decode(Bool.self, forKey: .showChatInIOS)) ?? true
        let decodedOrder = (try? container.decode(String.self, forKey: .iosChatMessageOrder))?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "newest-first"
        iosChatMessageOrder = ["oldest-first", "newest-first"].contains(decodedOrder) ? decodedOrder : "newest-first"
        let decodedLimit = (try? container.decode(Int.self, forKey: .iosChatMessageLimit)) ?? 50
        iosChatMessageLimit = [20, 50].contains(decodedLimit) ? decodedLimit : 50
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

private struct FederatedRoomGroup: Identifiable, Hashable {
    let id: String
    let displayName: String
    let totalUsers: Int
    let choices: [FederatedRoomChoice]
}

private func normalizedFederatedRoomGroupKey(_ rawName: String) -> String {
    let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let collapsedWhitespace = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    return collapsedWhitespace
        .replacingOccurrences(of: "[^\\p{L}\\p{N} ]+", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
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
    @AppStorage("voicelink.ios.serverScreenTab") private var storedTab = ServerScreenTab.servers.rawValue
    @Binding var serverURL: String
    @ObservedObject var roomState: IOSRoomMessagingState
    let openProfile: () -> Void

    private var selectedTabBinding: Binding<ServerScreenTab> {
        Binding(
            get: { ServerScreenTab(rawValue: storedTab) ?? .servers },
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

            switch ServerScreenTab(rawValue: storedTab) ?? .servers {
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
    @State private var pendingGuestJoinRoom: RoomSummary?
    @State private var showGuestJoinPrompt = false
    @State private var isAdmin = false
    @State private var showAdmin = false
    @State private var roomSortMode: RoomSortMode = .activity
    @State private var clientVisibility: ClientVisibilitySettings = .allVisible
    @State private var searchText = ""

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

                    Picker("Sort Rooms", selection: $roomSortMode) {
                        ForEach(RoomSortMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

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
                            NavigationLink(value: server) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(server.name)
                                        .font(.headline)
                                    if !server.description.isEmpty {
                                        Text(server.description)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("\(server.roomCount) room\(server.roomCount == 1 ? "" : "s") • \(server.totalUsers) users")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                            .accessibilityLabel("\(server.name), \(server.roomCount) rooms, \(server.totalUsers) users")
                            .accessibilityHint("Double tap to browse rooms on this server.")
                        }
                    }
                }
            }
            .navigationTitle("Servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isAdmin {
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
            .onReceive(NotificationCenter.default.publisher(for: .iosRoomUsersUpdated)) { _ in
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
            .sheet(isPresented: $showAdmin) {
                AdminTabView(serverURL: $serverURL)
            }
            .navigationDestination(for: HomeServerSummary.self) { server in
                HomeServerRoomsView(
                    server: server,
                    clientVisibleOnIOS: clientVisibility.ios,
                    onOpenRoom: { room, action in openRoom(room, action: action) },
                    onShareRoom: { room in shareRoom(room) }
                )
            }
        }
    }

    private func openRoom(_ room: RoomSummary, action: String, bypassGuestPrompt: Bool = false) {
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
                chatMessageLimit: room.iosChatMessageLimit
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

    @MainActor
    private func refreshAdminAccess() async {
        guard let url = URL(string: "\(normalizedBaseURL)/api/admin/status") else {
            isAdmin = false
            return
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            let token = (UserDefaults.standard.string(forKey: "voicelink.authToken") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue(token, forHTTPHeaderField: "x-session-token")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                isAdmin = false
                return
            }
            let json = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            isAdmin = (json["isAdmin"] as? Bool) ?? false
        } catch {
            isAdmin = false
        }
    }
}

private struct RoomRow: View {
    let room: RoomSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(room.name)
                .font(.headline)
            if !room.description.isEmpty {
                Text(room.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("\(room.userCount) users • \(displayRoomLockLabel(room.locked)) • \(displayVisibilityLabel(room.visibility)) • \(displayAccessTypeLabel(room.accessType))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(room.name), \(room.userCount) users, \(displayRoomLockLabel(room.locked)), \(displayVisibilityLabel(room.visibility)), \(displayAccessTypeLabel(room.accessType))")
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
    let rooms: [RoomSummary]
}

private struct HomeServerRoomsView: View {
    let server: HomeServerSummary
    let clientVisibleOnIOS: Bool
    let onOpenRoom: (RoomSummary, String) -> Void
    let onShareRoom: (RoomSummary) -> Void

    var body: some View {
        List {
            Section("Server") {
                LabeledContent("Name", value: server.name)
                LabeledContent("Rooms", value: "\(server.roomCount)")
                LabeledContent("Users", value: "\(server.totalUsers)")
            }

            Section("Rooms") {
                if !clientVisibleOnIOS {
                    Text("Rooms are hidden on iOS by this server’s policy.")
                        .foregroundStyle(.secondary)
                } else if server.rooms.isEmpty {
                    Text("No rooms are visible on this server right now.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(server.rooms) { room in
                        Button {
                            onOpenRoom(room, "details")
                        } label: {
                            RoomRow(room: room)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Room Details") { onOpenRoom(room, "details") }
                            Button("Join Room") { onOpenRoom(room, "join") }
                            Button("Preview Room") { onOpenRoom(room, "preview") }
                            Button("Share Room") { onShareRoom(room) }
                        }
                        .accessibilityHint("Double tap for room details. Extra actions are available for preview, join, and sharing.")
                        .accessibilityAction(named: Text("Room Details")) { onOpenRoom(room, "details") }
                        .accessibilityAction(named: Text("Join Room")) { onOpenRoom(room, "join") }
                        .accessibilityAction(named: Text("Preview Room")) { onOpenRoom(room, "preview") }
                        .accessibilityAction(named: Text("Share Room")) { onShareRoom(room) }
                    }
                }
            }
        }
        .navigationTitle(server.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RoomDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    let destination: RoomDetailsDestination

    var body: some View {
        NavigationStack {
            List {
                Section("Room") {
                    LabeledContent("Name", value: destination.room.name)
                    LabeledContent("Server", value: destination.serverLabel)
                    LabeledContent("Users", value: "\(destination.room.userCount)")
                    LabeledContent("Lock Status", value: displayRoomLockLabel(destination.room.locked))
                    LabeledContent("Visibility", value: displayVisibilityLabel(destination.room.visibility))
                    LabeledContent("Access Type", value: displayAccessTypeLabel(destination.room.accessType))
                    if !destination.room.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(destination.room.description)
                            .font(.body)
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
    @State private var clientVisibility: ClientVisibilitySettings = .allVisible
    @State private var searchText = ""

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
                                    }
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("\(group.displayName), \(group.totalUsers) users across \(group.choices.count) servers")
                                .accessibilityHint("Double tap to choose which server copy of this room to open.")
                                .accessibilityAction(named: Text("Choose Server")) { activeGroup = group }
                                .accessibilityAction(named: Text("Preview Room")) { openGroupedRoom(group, action: "preview") }
                                .accessibilityAction(named: Text("Join Room")) { openGroupedRoom(group, action: "join") }
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
                FederationRoomChoicesView(group: group, onOpen: openRoom)
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
                chatMessageLimit: choice.room.iosChatMessageLimit
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
            if let firstChoice, !firstChoice.room.description.isEmpty {
                Text(firstChoice.room.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("\(group.totalUsers) users • \(group.choices.count) servers")
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

    var body: some View {
        List {
            Section("Room") {
                LabeledContent("Name", value: group.displayName)
                LabeledContent("Servers", value: "\(group.choices.count)")
                LabeledContent("Users", value: "\(group.totalUsers)")
            }

            Section("Choose Server") {
                ForEach(group.choices) { choice in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(choice.serverLabel)
                            .font(.headline)
                        Text("\(choice.room.userCount) users")
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
                    }
                    .contextMenu {
                        Button("Room Details") { onOpen(choice, "details") }
                        Button("Join Room") { onOpen(choice, "join") }
                        Button("Preview Room") { onOpen(choice, "preview") }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(group.displayName) on \(choice.serverLabel), \(choice.room.userCount) users")
                    .accessibilityHint("Double tap for room details. Swipe down for preview and join actions.")
                    .accessibilityAction(named: Text("Room Details")) { onOpen(choice, "details") }
                    .accessibilityAction(named: Text("Join Room")) { onOpen(choice, "join") }
                    .accessibilityAction(named: Text("Preview Room")) { onOpen(choice, "preview") }
                }
            }
        }
        .navigationTitle(group.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MessagesTab: View {
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
        var merged: [String: IOSDirectMessageTarget] = [:]
        socketClient.roomUsers.forEach { merged[$0.id] = $0 }
        roomState.directTargets.forEach { merged[$0.id] = $0 }
        return merged.values.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
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
                        ForEach(roomState.roomMessages.suffix(25).reversed()) { message in
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
        }
    }

    private func openAuthAction(_ action: String) {
        guard let encoded = action.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://voicelink.devinecreations.net/?open=\(encoded)") else {
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

                    Link("Sign In", destination: URL(string: "https://voicelink.devinecreations.net/?open=login")!)
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

private struct AdminTabView: View {
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
    @State private var adminAccessMessage = "Checking access..."
    @State private var backups: [IOSConfigBackup] = []
    @State private var backupLabel = ""
    @State private var includeFederationSnapshot = true
    @State private var includeLinkedServers = true
    @State private var selectedBackupID: String?
    @State private var backupStatus = ""
    @State private var isRunningBackupAction = false
    @State private var exportFile: IOSSharedFile?

    private var normalizedBaseURL: String { normalizeBaseURL(serverURL) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Access") {
                    LabeledContent("Role", value: adminRole.capitalized)
                    LabeledContent("Admin Access", value: isAdmin ? "Granted" : "Restricted")
                    Text(adminAccessMessage)
                        .font(.footnote)
                        .foregroundColor(isAdmin ? .secondary : .orange)
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
            serverName = (json["serverName"] as? String) ?? serverName
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
                adminRole = "user"
                adminAccessMessage = "Not authenticated for admin API access."
                return
            }
            isAdmin = (json["isAdmin"] as? Bool) ?? false
            adminRole = String((json["role"] as? String) ?? "user")
            adminAccessMessage = isAdmin
                ? "Server API confirms this account can manage settings."
                : "Signed-in role is not admin."
        } catch {
            isAdmin = false
            adminRole = "user"
            adminAccessMessage = "Could not verify admin role right now."
        }

        if isAdmin {
            await loadBackups()
        } else {
            backups = []
            selectedBackupID = nil
        }
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
    @Environment(\.openURL) private var openURL
    @ObservedObject var roomState: IOSRoomMessagingState
    let openServers: () -> Void
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

                Section("Account") {
                    if isSignedIn {
                        LabeledContent("Signed In As", value: displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "VoiceLink Account" : displayName)
                        Button("Manage Account Sign In") {
                            showNativeAccountSignIn = true
                        }
                        Button("Sign Out", role: .destructive) {
                            authToken = ""
                            displayName = ""
                            authProvider = ""
                            authUserJSON = ""
                        }
                    } else {
                        Button("Account Sign In") {
                            showNativeAccountSignIn = true
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button(isSignedIn ? "Other Sign-In Methods" : "Quick Pair or Sign In") {
                        showAuthOptions = true
                    }
                    Text("Native account sign-in now uses the server login API directly. VoiceLink account sign-in stays local to the app, while Quick Pair and web sign-in are still available for other server flows.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Help and Policies") {
                    if let webURL = URL(string: "https://voicelink.devinecreations.net") {
                        Link("Open Web Frontend", destination: webURL)
                    }
                    Link("Privacy Policy", destination: URL(string: "https://voicelink.devinecreations.net/docs/privacy-policy.html")!)
                    Link("User Privacy Choices", destination: URL(string: "https://voicelink.devinecreations.net/docs/user-privacy-choices.html")!)
                    Link("Support and Contact", destination: URL(string: "https://voicelink.devinecreations.net/docs/contact.html#live-chat")!)
                    Link("Downloads and Getting Started", destination: URL(string: "https://voicelink.devinecreations.net/downloads/")!)
                    Button("Open Main Website") {
                        guard let url = URL(string: "https://voicelink.devinecreations.net") else { return }
                        openURL(url)
                    }
                }

            }
            .navigationTitle("Settings")
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
                IOSAccountSignInView(serverURL: normalizeBaseURL(UserDefaults.standard.string(forKey: "voicelink.serverURL") ?? "https://voicelink.devinecreations.net"))
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
              let url = URL(string: "https://voicelink.devinecreations.net/?open=\(encoded)") else {
            return
        }
        openURL(url)
    }

    private func submitDiagnosticsReport() {
        submittingDiagnostics = true
        diagnosticsStatus = ""
        IOSDiagnosticsManager.shared.submitBugReport(
            serverURL: normalizeBaseURL(UserDefaults.standard.string(forKey: "voicelink.serverURL") ?? "https://voicelink.devinecreations.net"),
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
                Section("VoiceLink Account") {
                    TextField("Email, username, or portal account", text: $identity)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .accessibilityLabel("Identity")
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

                if !statusMessage.isEmpty {
                    Section("Status") {
                        Text(statusMessage)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Actions") {
                    Button(needsTwoFactor ? "Verify and Sign In" : "Sign In") {
                        signIn()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || isLoading)

                    if !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Sign Out", role: .destructive) {
                            authToken = ""
                            displayName = ""
                            authProvider = ""
                            authUserJSON = ""
                            statusMessage = "Signed out."
                            needsTwoFactor = false
                            twoFactorCode = ""
                        }
                    }
                }
            }
            .navigationTitle("Account Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
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
                    needsTwoFactor = false
                    twoFactorCode = ""
                    availableMethods = []
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
        return "https://voicelink.devinecreations.net"
    }
    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
        let normalized = trimmed.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        if let url = URL(string: normalized),
           let host = url.host?.lowercased(),
           [
               "voicelink.devinecreations.net",
               "node2.voicelink.devinecreations.net",
               "voicelink.tappedin.fm",
               "tappedin.fm"
           ].contains(host) {
            return "https://\(host)"
        }
        return normalized
    }
    return "https://\(trimmed)"
}

private func iOSMainAPIBaseCandidates(preferredBase: String) -> [String] {
    var candidates: [String] = []
    let preferred = normalizeBaseURL(preferredBase)
    if !preferred.isEmpty {
        candidates.append(preferred)
    }
    candidates.append("https://node2.voicelink.devinecreations.net")
    candidates.append("https://voicelink.devinecreations.net")

    var seen = Set<String>()
    return candidates.filter { seen.insert(canonicalServerIdentity(baseURL: $0, room: nil)).inserted }
}

private func fetchRoomsWithFallback(sortMode: RoomSortMode, preferredBase: String) async throws -> ([RoomSummary], String) {
    var lastError: Error?
    for base in iOSMainAPIBaseCandidates(preferredBase: preferredBase) {
        let endpoint = "\(normalizeBaseURL(base))/api/rooms?source=app&client=ios&sort=\(sortMode.rawValue)"
        guard let url = URL(string: endpoint) else { continue }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                continue
            }
            let decodedRooms = try JSONDecoder().decode([RoomSummary].self, from: data)
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

        var request = URLRequest(url: statusURL)
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                continue
            }
            let raw = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let trusted = (raw["trustedServers"] as? [String]) ?? []
            for entry in trusted {
                let normalizedTrusted = normalizeBaseURL(entry)
                if !discovered.contains(normalizedTrusted) {
                    discovered.append(normalizedTrusted)
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
    try await withThrowingTaskGroup(of: [RoomSummary].self) { group in
        for base in bases {
            group.addTask {
                let endpoint = "\(normalizeBaseURL(base))/api/rooms?source=app&client=ios&sort=\(sortMode.rawValue)"
                guard let url = URL(string: endpoint) else { return [] }
                var request = URLRequest(url: url)
                request.timeoutInterval = 12
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    return []
                }
                return try JSONDecoder().decode([RoomSummary].self, from: data)
            }
        }

        var rooms: [RoomSummary] = []
        for try await serverRooms in group {
            rooms.append(contentsOf: serverRooms)
        }
        return rooms
    }
}

private func canonicalRoomName(_ name: String) -> String {
    let lowered = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return lowered.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
}

private func displayServerName(room: RoomSummary, fallbackBase: String) -> String {
    let trimmedTitle = room.serverTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedTitle.isEmpty, !isIPAddressValue(trimmedTitle) {
        return trimmedTitle
    }
    let trimmedDomain = room.serverDomain.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedDomain.isEmpty, !isIPAddressValue(trimmedDomain) {
        return trimmedDomain
    }
    let canonical = canonicalServerIdentity(baseURL: fallbackBase, room: room)
    switch canonical {
    case "voicelink.devinecreations.net":
        return "VoiceLink Main"
    case "node2.voicelink.devinecreations.net":
        return "VoiceLink Community"
    default:
        if let host = URL(string: fallbackBase)?.host, !host.isEmpty, !isIPAddressValue(host) {
            return host
        }
        if let host = URL(string: canonical)?.host, !host.isEmpty, !isIPAddressValue(host) {
            return host
        }
    }
    return room.serverSource.isEmpty ? "Unknown Server" : room.serverSource.capitalized
}

private func displayServerName(baseURL: String) -> String {
    switch canonicalServerIdentity(baseURL: baseURL, room: nil) {
    case "voicelink.devinecreations.net":
        return "VoiceLink Main"
    case "node2.voicelink.devinecreations.net":
        return "VoiceLink Community"
    default:
        if let host = URL(string: normalizeBaseURL(baseURL))?.host,
           !host.isEmpty,
           !isIPAddressValue(host) {
            return host
        }
        return "Unknown Server"
    }
}

private func canonicalServerIdentity(baseURL: String, room: RoomSummary?) -> String {
    let baseHost = URL(string: normalizeBaseURL(baseURL))?.host?.lowercased() ?? ""
    let roomDomain = room?.serverDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    let roomTitle = room?.serverTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    let roomSource = room?.serverSource.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

    let candidates = [baseHost, roomDomain, roomTitle, roomSource].filter { !$0.isEmpty }
    if candidates.contains(where: { ["64.20.46.178", "voicelink.devinecreations.net", "devinecreations.net"].contains($0) || $0.contains("voicelink main") }) {
        return "voicelink.devinecreations.net"
    }
    if candidates.contains(where: { ["64.20.46.179", "node2.voicelink.devinecreations.net"].contains($0) || $0.contains("community") || $0.contains("node2") }) {
        return "node2.voicelink.devinecreations.net"
    }

    if !roomDomain.isEmpty, !isIPAddressValue(roomDomain) {
        return roomDomain
    }
    if !baseHost.isEmpty, !isIPAddressValue(baseHost) {
        return baseHost
    }
    if !roomSource.isEmpty {
        return roomSource
    }
    return normalizeBaseURL(baseURL)
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

private func fetchClientVisibility(baseURL: String) async -> ClientVisibilitySettings {
    guard let url = URL(string: "\(normalizeBaseURL(baseURL))/api/config") else {
        return .allVisible
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 10

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

private func encodeAuthUserPayload(_ payload: [String: Any]) -> String {
    guard JSONSerialization.isValidJSONObject(payload),
          let data = try? JSONSerialization.data(withJSONObject: payload),
          let json = String(data: data, encoding: .utf8) else {
        return ""
    }
    return json
}
