import Foundation
import SwiftUI
import Combine

/// Messaging Manager for VoiceLink
/// Handles text messages between users in rooms and direct messages
class MessagingManager: ObservableObject {
    static let shared = MessagingManager()

    // MARK: - State

    @Published var messages: [ChatMessage] = []
    @Published var directMessages: [String: [ChatMessage]] = [:]  // odId -> messages
    @Published var unreadCounts: [String: Int] = [:]              // odId -> unread count
    @Published var totalUnreadCount: Int = 0
    @Published var isTyping: [String: Bool] = [:]                 // odId -> isTyping
    @Published var currentRoomId: String?
    @Published var roomHasMoreMessages: Bool = false
    @Published var directMessageHasMore: [String: Bool] = [:]
    @Published var roomHistoryStatus: String = ""
    @Published var directHistoryStatus: [String: String] = [:]

    private struct PendingOutgoingMessage {
        let senderId: String
        let senderName: String
        let content: String
        let timestamp: Date
    }

    private var pendingOutgoingMessages: [PendingOutgoingMessage] = []
    private let roomHistoryPageSize = 20
    private let dmHistoryPageSize = 20

    // MARK: - Types

    struct ChatMessage: Identifiable, Codable, Equatable {
        let id: String
        let senderId: String
        let senderName: String
        let content: String
        let timestamp: Date
        let type: MessageType
        var isRead: Bool
        var attachmentId: String?       // For file attachments
        var attachmentName: String?
        var attachmentURL: String?
        var attachmentCaption: String?
        var attachmentExpiresAt: Date?
        var attachmentRemoved: Bool
        var replyToId: String?          // For replies
        var reactions: [String: [String]]  // emoji -> [userIds]

        enum MessageType: String, Codable {
            case text
            case system          // Join/leave/etc
            case file
            case image
            case audio
            case reply
        }

        init(
            id: String = UUID().uuidString,
            senderId: String,
            senderName: String,
            content: String,
            timestamp: Date = Date(),
            type: MessageType = .text
        ) {
            self.id = id
            self.senderId = senderId
            self.senderName = senderName
            self.content = content
            self.timestamp = timestamp
            self.type = type
            self.isRead = false
            self.attachmentId = nil
            self.attachmentName = nil
            self.attachmentURL = nil
            self.attachmentCaption = nil
            self.attachmentExpiresAt = nil
            self.attachmentRemoved = false
            self.replyToId = nil
            self.reactions = [:]
        }
    }

    // MARK: - Constants

    static let maxMessageLength = 2000
    static let maxMessagesInMemory = 500

    // MARK: - Initialization

    init() {
        setupNotifications()
        loadRecentMessages()
    }

    // MARK: - Room Messages

    /// Send a message to the current room
    func sendRoomMessage(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed.count <= MessagingManager.maxMessageLength else { return }

        let userId = getCurrentUserId()
        let username = getCurrentUsername()
        let normalizedContent = normalizeOutgoingRoomContent(trimmed, username: username)

        let message = ChatMessage(
            senderId: userId,
            senderName: username,
            content: normalizedContent,
            type: .text
        )

        // Add to local messages
        registerPendingOutgoing(message)
        addMessage(message)

        // Send to server
        sendToServer(message, isDirect: false, recipientId: nil)
    }

    func sendRoomAttachment(
        content: String,
        attachmentName: String,
        attachmentURL: String,
        caption: String? = nil,
        expiresAt: Date? = nil,
        attachmentId: String? = nil
    ) {
        let body = normalizedAttachmentBody(content, attachmentName: attachmentName)
        var message = ChatMessage(
            senderId: getCurrentUserId(),
            senderName: getCurrentUsername(),
            content: body,
            type: messageType(forAttachmentName: attachmentName)
        )
        message.attachmentId = attachmentId
        message.attachmentName = attachmentName
        message.attachmentURL = attachmentURL
        message.attachmentCaption = normalizedAttachmentCaption(caption)
        message.attachmentExpiresAt = expiresAt
        message.attachmentRemoved = false

        registerPendingOutgoing(message)
        addMessage(message)
        sendToServer(message, isDirect: false, recipientId: nil)
    }

    /// Send a system message (join, leave, etc.)
    func sendSystemMessage(_ content: String) {
        let message = ChatMessage(
            senderId: "system",
            senderName: "System",
            content: content,
            type: .system
        )
        addMessage(message)
    }

    // MARK: - Direct Messages

    /// Send a direct message to a specific user
    func sendDirectMessage(to userId: String, username: String, content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed.count <= MessagingManager.maxMessageLength else { return }

        let myId = getCurrentUserId()
        let myName = getCurrentUsername()

        let message = ChatMessage(
            senderId: myId,
            senderName: myName,
            content: trimmed,
            type: .text
        )

        // Add to DM thread
        addDirectMessage(message, with: userId)

        // Play sound
        AppSoundManager.shared.playSound(.buttonClick)

        // Send to server
        sendToServer(message, isDirect: true, recipientId: userId)
    }

    func sendDirectAttachment(
        to userId: String,
        username: String,
        content: String,
        attachmentName: String,
        attachmentURL: String,
        caption: String? = nil,
        expiresAt: Date? = nil,
        attachmentId: String? = nil
    ) {
        let body = normalizedAttachmentBody(content, attachmentName: attachmentName)
        var message = ChatMessage(
            senderId: getCurrentUserId(),
            senderName: getCurrentUsername(),
            content: body,
            type: messageType(forAttachmentName: attachmentName)
        )
        message.attachmentId = attachmentId
        message.attachmentName = attachmentName
        message.attachmentURL = attachmentURL
        message.attachmentCaption = normalizedAttachmentCaption(caption)
        message.attachmentExpiresAt = expiresAt
        message.attachmentRemoved = false

        addDirectMessage(message, with: userId)
        AppSoundManager.shared.playSound(.buttonClick)
        sendToServer(message, isDirect: true, recipientId: userId)
    }

    /// Get DM thread with a user
    func getDirectMessages(with userId: String) -> [ChatMessage] {
        return directMessages[userId] ?? []
    }

    /// Mark DMs as read
    func markAsRead(userId: String) {
        if var msgs = directMessages[userId] {
            for i in 0..<msgs.count {
                msgs[i].isRead = true
            }
            directMessages[userId] = msgs
        }
        unreadCounts[userId] = 0
        updateTotalUnread()
        Task {
            await markMessagesAsReadOnServer(otherUserId: userId)
        }
    }

    @MainActor
    func beginRoomSession(roomId: String) {
        currentRoomId = roomId
        messages.removeAll()
        roomHasMoreMessages = false
        roomHistoryStatus = "Loading latest room messages..."
        Task {
            await loadRoomHistory(roomId: roomId, reset: true)
        }
    }

    @MainActor
    func endRoomSession() {
        currentRoomId = nil
        messages.removeAll()
        roomHasMoreMessages = false
        roomHistoryStatus = ""
    }

    @MainActor
    func loadRoomHistory(roomId: String, reset: Bool, before: String? = nil, limit: Int? = nil) async {
        guard let url = roomHistoryURL(roomId: roomId, before: before, limit: limit ?? initialRoomHistoryCount()) else {
            roomHistoryStatus = "Room history is unavailable."
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                await MainActor.run { self.roomHistoryStatus = "Failed to load room history." }
                return
            }

            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let rawMessages = payload?["messages"] as? [[String: Any]] ?? []
            let parsed = rawMessages.compactMap(Self.chatMessage(from:))
            let hasMore = (payload?["hasMore"] as? Bool) ?? (parsed.count >= (limit ?? initialRoomHistoryCount()))

            await MainActor.run {
                if reset {
                    self.messages = parsed
                } else {
                    let existing = self.messages
                    self.messages = Self.mergeMessages(parsed + existing)
                }
                self.roomHasMoreMessages = hasMore
                self.roomHistoryStatus = self.messages.isEmpty ? "No room messages yet." : ""
            }
        } catch {
            await MainActor.run {
                self.roomHistoryStatus = "Failed to load room history."
            }
        }
    }

    @MainActor
    func loadOlderRoomMessages() async {
        guard let roomId = currentRoomId, let firstId = messages.first?.id else { return }
        roomHistoryStatus = "Loading older room messages..."
        await loadRoomHistory(roomId: roomId, reset: false, before: firstId, limit: roomHistoryPageSize)
    }

    @MainActor
    func skipToLatestRoomMessages() async {
        guard let roomId = currentRoomId else { return }
        roomHistoryStatus = "Loading latest room messages..."
        await loadRoomHistory(roomId: roomId, reset: true, limit: initialRoomHistoryCount())
    }

    @MainActor
    func loadDirectHistory(with userId: String, reset: Bool, before: String? = nil, limit: Int? = nil) async {
        guard let url = directHistoryURL(otherUserId: userId, before: before, limit: limit ?? dmHistoryPageSize) else {
            directHistoryStatus[userId] = "Direct message history is unavailable."
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                await MainActor.run { self.directHistoryStatus[userId] = "Failed to load direct messages." }
                return
            }

            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let rawMessages = payload?["messages"] as? [[String: Any]] ?? []
            let parsed = rawMessages.compactMap(Self.chatMessage(from:))
            let hasMore = (payload?["hasMore"] as? Bool) ?? (parsed.count >= (limit ?? dmHistoryPageSize))

            await MainActor.run {
                if reset {
                    self.directMessages[userId] = parsed
                } else {
                    let existing = self.directMessages[userId] ?? []
                    self.directMessages[userId] = Self.mergeMessages(parsed + existing)
                }
                self.directMessageHasMore[userId] = hasMore
                self.directHistoryStatus[userId] = (self.directMessages[userId]?.isEmpty ?? true) ? "No direct messages yet." : ""
                self.markAsRead(userId: userId)
            }
        } catch {
            await MainActor.run {
                self.directHistoryStatus[userId] = "Failed to load direct messages."
            }
        }
    }

    @MainActor
    func loadOlderDirectMessages(with userId: String) async {
        guard let firstId = directMessages[userId]?.first?.id else { return }
        directHistoryStatus[userId] = "Loading older direct messages..."
        await loadDirectHistory(with: userId, reset: false, before: firstId, limit: dmHistoryPageSize)
    }

    @MainActor
    func skipToLatestDirectMessages(with userId: String) async {
        directHistoryStatus[userId] = "Loading latest direct messages..."
        await loadDirectHistory(with: userId, reset: true, limit: dmHistoryPageSize)
    }

    // MARK: - Replies & Reactions

    /// Send a reply to a message
    func sendReply(to messageId: String, content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let userId = getCurrentUserId()
        let username = getCurrentUsername()
        let normalizedContent = normalizeOutgoingRoomContent(trimmed, username: username)

        var message = ChatMessage(
            senderId: userId,
            senderName: username,
            content: normalizedContent,
            type: .reply
        )
        message.replyToId = messageId

        addMessage(message)
        sendToServer(message, isDirect: false, recipientId: nil)
    }

    /// Add a reaction to a message
    func addReaction(to messageId: String, emoji: String) {
        let userId = getCurrentUserId()

        if let index = messages.firstIndex(where: { $0.id == messageId }) {
            var msg = messages[index]
            if msg.reactions[emoji] == nil {
                msg.reactions[emoji] = []
            }
            if !msg.reactions[emoji]!.contains(userId) {
                msg.reactions[emoji]!.append(userId)
            }
            messages[index] = msg

            // Send to server
            NotificationCenter.default.post(
                name: .sendReactionToServer,
                object: nil,
                userInfo: ["messageId": messageId, "emoji": emoji, "userId": userId]
            )
        }
    }

    /// Remove a reaction from a message
    func removeReaction(from messageId: String, emoji: String) {
        let userId = getCurrentUserId()

        if let index = messages.firstIndex(where: { $0.id == messageId }) {
            var msg = messages[index]
            msg.reactions[emoji]?.removeAll { $0 == userId }
            if msg.reactions[emoji]?.isEmpty == true {
                msg.reactions.removeValue(forKey: emoji)
            }
            messages[index] = msg

            // Send to server
            NotificationCenter.default.post(
                name: .removeReactionFromServer,
                object: nil,
                userInfo: ["messageId": messageId, "emoji": emoji, "userId": userId]
            )
        }
    }

    // MARK: - Typing Indicator

    /// Start typing indicator
    func startTyping() {
        NotificationCenter.default.post(name: .sendTypingIndicator, object: nil, userInfo: ["typing": true])
    }

    /// Stop typing indicator
    func stopTyping() {
        NotificationCenter.default.post(name: .sendTypingIndicator, object: nil, userInfo: ["typing": false])
    }

    // MARK: - Private Methods

    private func addMessage(_ message: ChatMessage) {
        DispatchQueue.main.async {
            self.prunePendingOutgoingMessages()
            if self.isLikelyDuplicate(message) {
                return
            }
            self.messages.append(message)

            // Trim if too many messages
            if self.messages.count > MessagingManager.maxMessagesInMemory {
                self.messages.removeFirst(100)
            }
        }
    }

    private func addDirectMessage(_ message: ChatMessage, with odId: String) {
        DispatchQueue.main.async {
            if self.directMessages[odId] == nil {
                self.directMessages[odId] = []
            }
            self.directMessages[odId]?.append(message)

            // Trim if too many
            if let count = self.directMessages[odId]?.count, count > MessagingManager.maxMessagesInMemory {
                self.directMessages[odId]?.removeFirst(100)
            }
        }
    }

    private func sendToServer(_ message: ChatMessage, isDirect: Bool, recipientId: String?) {
        var info: [String: Any] = [
            "messageId": message.id,
            "content": message.content,
            "type": message.type.rawValue,
            "isDirect": isDirect
        ]
        if let recipient = recipientId {
            info["recipientId"] = recipient
        }
        if let replyTo = message.replyToId {
            info["replyToId"] = replyTo
        }
        if let attachmentId = message.attachmentId {
            info["attachmentId"] = attachmentId
        }
        if let attachmentName = message.attachmentName {
            info["attachmentName"] = attachmentName
        }
        if let attachmentURL = message.attachmentURL {
            info["attachmentURL"] = attachmentURL
        }
        if let attachmentCaption = message.attachmentCaption {
            info["attachmentCaption"] = attachmentCaption
        }
        if let attachmentExpiresAt = message.attachmentExpiresAt {
            info["attachmentExpiresAt"] = attachmentExpiresAt.timeIntervalSince1970
        }
        info["attachmentRemoved"] = message.attachmentRemoved

        NotificationCenter.default.post(name: .sendMessageToServer, object: nil, userInfo: info)
    }

    private func normalizedAttachmentBody(_ content: String, attachmentName: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Shared file: \(attachmentName)" : trimmed
    }

    private func normalizedAttachmentCaption(_ caption: String?) -> String? {
        let trimmed = caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func messageType(forAttachmentName fileName: String) -> ChatMessage.MessageType {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic":
            return .image
        case "mp3", "wav", "aac", "m4a", "flac", "ogg":
            return .audio
        default:
            return .file
        }
    }

    private func updateTotalUnread() {
        totalUnreadCount = unreadCounts.values.reduce(0, +)
    }

    // MARK: - Notifications

    private func setupNotifications() {
        // Incoming room message
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleIncomingMessage),
            name: .incomingChatMessage,
            object: nil
        )

        // Incoming DM
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleIncomingDM),
            name: .incomingDirectMessage,
            object: nil
        )

        // Typing indicator
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTypingIndicator),
            name: .userTypingIndicator,
            object: nil
        )

        NotificationCenter.default.addObserver(
            forName: .roomJoined,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let payload = notification.object as? [String: Any]
            let roomId = payload?["roomId"] as? String ?? payload?["id"] as? String
            guard let roomId else { return }
            Task { @MainActor in
                self.beginRoomSession(roomId: roomId)
            }
        }

        NotificationCenter.default.addObserver(
            forName: .roomLeft,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.endRoomSession()
            }
        }
    }

    @objc private func handleIncomingMessage(_ notification: Notification) {
        guard let data = notification.userInfo,
              let senderId = data["senderId"] as? String,
              let senderName = data["senderName"] as? String,
              let content = data["content"] as? String else { return }

        let typeRaw = data["type"] as? String ?? "text"
        let type = ChatMessage.MessageType(rawValue: typeRaw) ?? .text
        let messageId = (data["messageId"] as? String) ?? UUID().uuidString
        let timestamp: Date = {
            if let value = data["timestamp"] as? Date { return value }
            if let value = data["timestamp"] as? TimeInterval { return Date(timeIntervalSince1970: value) }
            if let value = data["timestamp"] as? String, let parsed = ISO8601DateFormatter().date(from: value) { return parsed }
            return Date()
        }()

        let message = ChatMessage(
            id: messageId,
            senderId: senderId,
            senderName: senderName,
            content: normalizedIncomingContent(content, senderName: senderName),
            timestamp: timestamp,
            type: type
        )

        var enrichedMessage = message
        enrichedMessage.attachmentId = data["attachmentId"] as? String
        enrichedMessage.attachmentName = data["attachmentName"] as? String
        enrichedMessage.attachmentURL = data["attachmentURL"] as? String ?? data["attachmentUrl"] as? String
        enrichedMessage.attachmentCaption = data["attachmentCaption"] as? String ?? data["caption"] as? String
        enrichedMessage.attachmentRemoved = data["attachmentRemoved"] as? Bool ?? false
        if let expiresValue = data["attachmentExpiresAt"] {
            enrichedMessage.attachmentExpiresAt = Self.parseDate(expiresValue)
        }

        addMessage(enrichedMessage)

        // Play incoming sound only for other users' messages.
        if senderId != getCurrentUserId() {
            AppSoundManager.shared.playSound(.messageIncoming)
        }
    }

    @objc private func handleIncomingDM(_ notification: Notification) {
        guard let data = notification.userInfo,
              let senderId = data["senderId"] as? String,
              let senderName = data["senderName"] as? String,
              let content = data["content"] as? String else { return }

        let typeRaw = data["type"] as? String ?? "text"
        let type = ChatMessage.MessageType(rawValue: typeRaw) ?? .text
        let messageId = (data["messageId"] as? String) ?? UUID().uuidString
        let timestamp: Date = {
            if let value = data["timestamp"] { return Self.parseDate(value) ?? Date() }
            return Date()
        }()

        var message = ChatMessage(
            id: messageId,
            senderId: senderId,
            senderName: senderName,
            content: normalizedIncomingContent(content, senderName: senderName),
            timestamp: timestamp,
            type: type
        )
        message.attachmentId = data["attachmentId"] as? String
        message.attachmentName = data["attachmentName"] as? String
        message.attachmentURL = data["attachmentURL"] as? String ?? data["attachmentUrl"] as? String
        message.attachmentCaption = data["attachmentCaption"] as? String ?? data["caption"] as? String
        message.attachmentRemoved = data["attachmentRemoved"] as? Bool ?? false
        if let expiresValue = data["attachmentExpiresAt"] {
            message.attachmentExpiresAt = Self.parseDate(expiresValue)
        }

        addDirectMessage(message, with: senderId)

        // Update unread count
        unreadCounts[senderId] = (unreadCounts[senderId] ?? 0) + 1
        updateTotalUnread()

        // Play incoming sound
        AppSoundManager.shared.playSound(.messageReceived)
    }

    @objc private func handleTypingIndicator(_ notification: Notification) {
        guard let data = notification.userInfo,
              let userId = data["userId"] as? String,
              let typing = data["typing"] as? Bool else { return }

        DispatchQueue.main.async {
            self.isTyping[userId] = typing
        }
    }

    // MARK: - Persistence

    private func loadRecentMessages() {
        // Load from UserDefaults or local storage
        if let data = UserDefaults.standard.data(forKey: "recentMessages"),
           let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            messages = decoded
        }
    }

    func saveRecentMessages() {
        // Save last 100 messages
        let toSave = Array(messages.suffix(100))
        if let encoded = try? JSONEncoder().encode(toSave) {
            UserDefaults.standard.set(encoded, forKey: "recentMessages")
        }
    }

    // MARK: - Helpers

    private func getCurrentUserId() -> String {
        return UserDefaults.standard.string(forKey: "clientId") ?? UUID().uuidString
    }

    private func getCurrentUsername() -> String {
        return UserDefaults.standard.string(forKey: "username") ?? "User"
    }

    private func registerPendingOutgoing(_ message: ChatMessage) {
        let pending = PendingOutgoingMessage(
            senderId: canonicalSenderId(message.senderId),
            senderName: canonicalSenderName(message.senderName),
            content: normalizedMessageBody(message.content),
            timestamp: message.timestamp
        )
        pendingOutgoingMessages.append(pending)
        prunePendingOutgoingMessages()
    }

    private func prunePendingOutgoingMessages() {
        let cutoff = Date().addingTimeInterval(-8)
        pendingOutgoingMessages.removeAll { $0.timestamp < cutoff }
    }

    private func canonicalSenderId(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func canonicalSenderName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedMessageBody(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func isCurrentUserIdentity(senderId: String, senderName: String) -> Bool {
        let currentId = canonicalSenderId(getCurrentUserId())
        let ids = Set([currentId, "self", "me", ""])
        let currentNames = Set([
            canonicalSenderName(getCurrentUsername()),
            canonicalSenderName(UserDefaults.standard.string(forKey: "displayName") ?? ""),
            "you"
        ])
        let candidateId = canonicalSenderId(senderId)
        let candidateName = canonicalSenderName(senderName)
        return ids.contains(candidateId) || currentNames.contains(candidateName)
    }

    private func isLikelyDuplicate(_ message: ChatMessage) -> Bool {
        if messages.contains(where: { $0.id == message.id }) {
            return true
        }

        let normalizedContent = normalizedMessageBody(message.content)
        let messageSenderId = canonicalSenderId(message.senderId)
        let messageSenderName = canonicalSenderName(message.senderName)
        let isCurrentUserMessage = isCurrentUserIdentity(senderId: message.senderId, senderName: message.senderName)

        if messages.contains(where: { existing in
            let existingContent = normalizedMessageBody(existing.content)
            let sameBody = existingContent == normalizedContent
            let closeInTime = abs(existing.timestamp.timeIntervalSince(message.timestamp)) < 4
            let senderMatches =
                canonicalSenderId(existing.senderId) == messageSenderId ||
                canonicalSenderName(existing.senderName) == messageSenderName ||
                (isCurrentUserMessage && isCurrentUserIdentity(senderId: existing.senderId, senderName: existing.senderName))
            return sameBody && closeInTime && senderMatches
        }) {
            return true
        }

        if isCurrentUserMessage,
           pendingOutgoingMessages.contains(where: { pending in
               pending.content == normalizedContent &&
               abs(pending.timestamp.timeIntervalSince(message.timestamp)) < 6 &&
               (pending.senderId == messageSenderId ||
                pending.senderName == messageSenderName ||
                messageSenderId.isEmpty ||
                messageSenderName == "you")
           }) {
            return true
        }

        return false
    }

    private func normalizedIncomingContent(_ content: String, senderName: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return content }

        let prefixes = [
            "\(senderName):",
            "\(senderName) :",
            "You:",
            "You :"
        ]

        for prefix in prefixes where trimmed.hasPrefix(prefix) {
            let stripped = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty {
                return stripped
            }
        }

        return trimmed
    }

    private func normalizeOutgoingRoomContent(_ content: String, username: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("/me ") {
            let action = trimmed.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !action.isEmpty else { return trimmed }
            return "\(username) \(action)"
        }

        if lowered == "/bot" {
            return "@VoiceLink Bot help"
        }

        if lowered.hasPrefix("/bot ") {
            let remainder = trimmed.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.isEmpty ? "@VoiceLink Bot help" : "@VoiceLink Bot \(remainder)"
        }

        return trimmed
    }

    // MARK: - Cleanup

    func clearMessages() {
        messages.removeAll()
    }

    func clearDirectMessages(with userId: String) {
        directMessages[userId]?.removeAll()
        unreadCounts[userId] = 0
        directMessageHasMore[userId] = false
        directHistoryStatus[userId] = ""
        updateTotalUnread()
    }

    private func initialRoomHistoryCount() -> Int {
        let configured = ServerManager.shared.serverConfig?.messageSettings.initialLoadCount ?? roomHistoryPageSize
        return min(max(configured, 1), 200)
    }

    private func roomHistoryURL(roomId: String, before: String?, limit: Int) -> URL? {
        guard let baseURL = ServerManager.shared.baseURL,
              let encodedRoomId = roomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              var components = URLComponents(string: "\(baseURL)/api/rooms/\(encodedRoomId)/messages") else {
            return nil
        }

        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let before, !before.isEmpty {
            items.append(URLQueryItem(name: "before", value: before))
        }
        components.queryItems = items
        return components.url
    }

    private func directHistoryURL(otherUserId: String, before: String?, limit: Int) -> URL? {
        let currentUserId = getCurrentUserId()
        guard let baseURL = ServerManager.shared.baseURL,
              let user1 = currentUserId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let user2 = otherUserId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              var components = URLComponents(string: "\(baseURL)/api/messages/dm/\(user1)/\(user2)") else {
            return nil
        }

        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let before, !before.isEmpty {
            items.append(URLQueryItem(name: "before", value: before))
        }
        components.queryItems = items
        return components.url
    }

    private func markMessagesAsReadOnServer(otherUserId: String) async {
        let currentUserId = getCurrentUserId()
        guard let baseURL = ServerManager.shared.baseURL,
              let user1 = currentUserId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let user2 = otherUserId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseURL)/api/messages/dm/\(user1)/\(user2)/read") else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        _ = try? await URLSession.shared.data(for: request)
    }

    private static func mergeMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        var merged: [ChatMessage] = []
        var seen = Set<String>()

        for message in messages.sorted(by: { $0.timestamp < $1.timestamp }) {
            if seen.contains(message.id) { continue }
            seen.insert(message.id)
            merged.append(message)
        }

        return merged
    }

    private static func chatMessage(from raw: [String: Any]) -> ChatMessage? {
        let senderId = raw["senderId"] as? String ?? raw["userId"] as? String ?? ""
        let senderName = raw["senderName"] as? String ?? raw["userName"] as? String ?? "Unknown"
        let content = raw["content"] as? String ?? raw["message"] as? String ?? ""
        let messageId = raw["messageId"] as? String ?? raw["id"] as? String ?? UUID().uuidString
        let type = ChatMessage.MessageType(rawValue: raw["type"] as? String ?? "text") ?? .text
        let timestamp = parseDate(raw["timestamp"] ?? raw["createdAt"] ?? raw["sentAt"]) ?? Date()

        var message = ChatMessage(
            id: messageId,
            senderId: senderId,
            senderName: senderName,
            content: content,
            timestamp: timestamp,
            type: type
        )
        message.isRead = raw["read"] as? Bool ?? false
        message.replyToId = raw["replyToId"] as? String ?? raw["replyTo"] as? String
        message.attachmentId = raw["attachmentId"] as? String
        message.attachmentName = raw["attachmentName"] as? String
        message.attachmentURL = raw["attachmentURL"] as? String ?? raw["attachmentUrl"] as? String
        message.attachmentCaption = raw["attachmentCaption"] as? String ?? raw["caption"] as? String
        message.attachmentRemoved = raw["attachmentRemoved"] as? Bool ?? false
        message.reactions = Self.decodeReactions(raw["reactions"])
        if let expiresValue = raw["attachmentExpiresAt"] {
            message.attachmentExpiresAt = parseDate(expiresValue)
        }
        return message
    }

    private static func decodeReactions(_ value: Any?) -> [String: [String]] {
        if let map = value as? [String: [String]] {
            return map
        }
        if let array = value as? [[String: Any]] {
            var grouped: [String: [String]] = [:]
            for entry in array {
                guard let reaction = entry["reaction"] as? String else { continue }
                let userId = entry["userId"] as? String ?? UUID().uuidString
                grouped[reaction, default: []].append(userId)
            }
            return grouped
        }
        return [:]
    }

    private static func parseDate(_ value: Any?) -> Date? {
        switch value {
        case let date as Date:
            return date
        case let interval as TimeInterval:
            if interval > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: interval / 1000)
            }
            return Date(timeIntervalSince1970: interval)
        case let number as NSNumber:
            let interval = number.doubleValue
            if interval > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: interval / 1000)
            }
            return Date(timeIntervalSince1970: interval)
        case let string as String:
            if let parsed = ISO8601DateFormatter().date(from: string) {
                return parsed
            }
            if let seconds = Double(string) {
                if seconds > 1_000_000_000_000 {
                    return Date(timeIntervalSince1970: seconds / 1000)
                }
                return Date(timeIntervalSince1970: seconds)
            }
            return nil
        default:
            return nil
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let sendMessageToServer = Notification.Name("sendMessageToServer")
    static let incomingChatMessage = Notification.Name("incomingChatMessage")
    static let incomingDirectMessage = Notification.Name("incomingDirectMessage")
    static let sendTypingIndicator = Notification.Name("sendTypingIndicator")
    static let userTypingIndicator = Notification.Name("userTypingIndicator")
    static let sendReactionToServer = Notification.Name("sendReactionToServer")
    static let removeReactionFromServer = Notification.Name("removeReactionFromServer")
}

// MARK: - SwiftUI Views

/// Chat message bubble
struct ChatBubble: View {
    let message: MessagingManager.ChatMessage
    let isOwnMessage: Bool
    var onReply: (() -> Void)?
    var onReact: ((String) -> Void)?

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isOwnMessage { Spacer() }

            VStack(alignment: isOwnMessage ? .trailing : .leading, spacing: 4) {
                // Reply indicator
                if let replyId = message.replyToId {
                    HStack(spacing: 4) {
                        Image(systemName: "arrowshape.turn.up.left")
                            .font(.caption2)
                        Text("Reply")
                            .font(.caption2)
                    }
                    .foregroundColor(.gray)
                }

                // Sender name (not for own messages)
                if !isOwnMessage && message.type != .system {
                    Text(message.senderName)
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                // Message content
                Text(message.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)
                    .foregroundColor(bubbleTextColor)
                    .cornerRadius(16)

                // Reactions
                if !message.reactions.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(message.reactions.keys), id: \.self) { emoji in
                            HStack(spacing: 2) {
                                Text(emoji)
                                Text("\(message.reactions[emoji]?.count ?? 0)")
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(10)
                        }
                    }
                }

                // Timestamp
                Text(formatTime(message.timestamp))
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
            .contextMenu {
                Button(action: { onReply?() }) {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
                Menu("React") {
                    ForEach(["👍", "❤️", "😂", "😮", "😢", "🎉"], id: \.self) { emoji in
                        Button(emoji) { onReact?(emoji) }
                    }
                }
                Button(action: { copyToClipboard(message.content) }) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }

            if !isOwnMessage { Spacer() }
        }
        .padding(.horizontal)
        .padding(.vertical, 2)
    }

    var bubbleBackground: Color {
        if message.type == .system {
            return Color.gray.opacity(0.3)
        }
        return isOwnMessage ? Color.blue : Color.gray.opacity(0.3)
    }

    var bubbleTextColor: Color {
        if message.type == .system {
            return .gray
        }
        return isOwnMessage ? .white : .primary
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Chat input field
struct ChatInputField: View {
    @Binding var text: String
    let placeholder: String
    let onSend: () -> Void
    @ObservedObject var messagingManager = MessagingManager.shared

    @State private var typingTimer: Timer?

    var body: some View {
        HStack(spacing: 12) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .onChange(of: text) { newValue in
                    // Typing indicator
                    typingTimer?.invalidate()
                    if !newValue.isEmpty {
                        messagingManager.startTyping()
                        typingTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
                            messagingManager.stopTyping()
                        }
                    }
                }
                .onSubmit {
                    if !text.isEmpty {
                        onSend()
                        text = ""
                        messagingManager.stopTyping()
                    }
                }

            Button(action: {
                if !text.isEmpty {
                    onSend()
                    text = ""
                    messagingManager.stopTyping()
                }
            }) {
                Image(systemName: "paperplane.fill")
                    .foregroundColor(text.isEmpty ? .gray : .blue)
            }
            .buttonStyle(.plain)
            .disabled(text.isEmpty)
        }
        .padding()
    }
}

/// Chat view for room or DM
struct ChatView: View {
    let isDirect: Bool
    let recipientId: String?
    let recipientName: String?

    @ObservedObject var messagingManager = MessagingManager.shared
    @State private var messageText = ""
    @State private var replyingTo: MessagingManager.ChatMessage?

    var messages: [MessagingManager.ChatMessage] {
        if isDirect, let odId = recipientId {
            return messagingManager.getDirectMessages(with: odId)
        }
        return messagingManager.messages
    }

    var body: some View {
        VStack(spacing: 0) {
            // Messages list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(messages) { message in
                            ChatBubble(
                                message: message,
                                isOwnMessage: message.senderId == getCurrentUserId(),
                                onReply: { replyingTo = message },
                                onReact: { emoji in
                                    messagingManager.addReaction(to: message.id, emoji: emoji)
                                }
                            )
                            .id(message.id)
                        }
                    }
                }
                .onChange(of: messages.count) { _ in
                    if let lastId = messages.last?.id {
                        withAnimation {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Reply indicator
            if let reply = replyingTo {
                HStack {
                    Text("Replying to \(reply.senderName)")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Spacer()
                    Button(action: { replyingTo = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }

            // Typing indicator
            if let typing = messagingManager.isTyping.first(where: { $0.value == true }) {
                HStack {
                    Text("Someone is typing...")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .italic()
                    Spacer()
                }
                .padding(.horizontal)
            }

            // Input
            ChatInputField(text: $messageText, placeholder: isDirect ? "Message \(recipientName ?? "user")..." : "Message room...") {
                if let reply = replyingTo {
                    messagingManager.sendReply(to: reply.id, content: messageText)
                    replyingTo = nil
                } else if isDirect, let odId = recipientId {
                    messagingManager.sendDirectMessage(to: odId, username: recipientName ?? "User", content: messageText)
                } else {
                    messagingManager.sendRoomMessage(messageText)
                }
            }
        }
        .onAppear {
            if isDirect, let odId = recipientId {
                messagingManager.markAsRead(userId: odId)
            }
        }
    }

    private func getCurrentUserId() -> String {
        return UserDefaults.standard.string(forKey: "clientId") ?? ""
    }
}

/// Unread badge
struct UnreadBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.caption2.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red)
                .cornerRadius(10)
        }
    }
}
