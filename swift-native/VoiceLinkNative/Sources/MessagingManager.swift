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

        init(senderId: String, senderName: String, content: String, type: MessageType = .text) {
            self.id = UUID().uuidString
            self.senderId = senderId
            self.senderName = senderName
            self.content = content
            self.timestamp = Date()
            self.type = type
            self.isRead = false
            self.attachmentId = nil
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
        guard !content.isEmpty else { return }
        guard content.count <= MessagingManager.maxMessageLength else { return }

        let userId = getCurrentUserId()
        let username = getCurrentUsername()

        let message = ChatMessage(
            senderId: userId,
            senderName: username,
            content: content,
            type: .text
        )

        // Add to local messages
        addMessage(message)

        // Play sound
        AppSoundManager.shared.playSound(.buttonClick)

        // Send to server
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
        guard !content.isEmpty else { return }
        guard content.count <= MessagingManager.maxMessageLength else { return }

        let myId = getCurrentUserId()
        let myName = getCurrentUsername()

        let message = ChatMessage(
            senderId: myId,
            senderName: myName,
            content: content,
            type: .text
        )

        // Add to DM thread
        addDirectMessage(message, with: userId)

        // Play sound
        AppSoundManager.shared.playSound(.buttonClick)

        // Send to server
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
    }

    // MARK: - Replies & Reactions

    /// Send a reply to a message
    func sendReply(to messageId: String, content: String) {
        guard !content.isEmpty else { return }

        let userId = getCurrentUserId()
        let username = getCurrentUsername()

        var message = ChatMessage(
            senderId: userId,
            senderName: username,
            content: content,
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

        NotificationCenter.default.post(name: .sendMessageToServer, object: nil, userInfo: info)
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
    }

    @objc private func handleIncomingMessage(_ notification: Notification) {
        guard let data = notification.userInfo,
              let senderId = data["senderId"] as? String,
              let senderName = data["senderName"] as? String,
              let content = data["content"] as? String else { return }

        let typeRaw = data["type"] as? String ?? "text"
        let type = ChatMessage.MessageType(rawValue: typeRaw) ?? .text

        let message = ChatMessage(
            senderId: senderId,
            senderName: senderName,
            content: content,
            type: type
        )

        addMessage(message)

        // Play incoming sound
        AppSoundManager.shared.playSound(.messageIncoming)
    }

    @objc private func handleIncomingDM(_ notification: Notification) {
        guard let data = notification.userInfo,
              let senderId = data["senderId"] as? String,
              let senderName = data["senderName"] as? String,
              let content = data["content"] as? String else { return }

        let message = ChatMessage(
            senderId: senderId,
            senderName: senderName,
            content: content,
            type: .text
        )

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

    // MARK: - Cleanup

    func clearMessages() {
        messages.removeAll()
    }

    func clearDirectMessages(with userId: String) {
        directMessages[userId]?.removeAll()
        unreadCounts[userId] = 0
        updateTotalUnread()
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
                .onChange(of: text) { _, newValue in
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
                .onChange(of: messages.count) { _, _ in
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
