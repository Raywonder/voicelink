import SwiftUI
import AppKit
import LinkPresentation
import AVFoundation

struct ChatConversationSidebar: View {
    let visibleRoomUsers: [RoomUser]
    let selectedDirectMessageUserId: String?
    let unreadCounts: [String: Int]
    let onSelectMainRoomChat: () -> Void
    let onOpenDirectMessage: (RoomUser) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Conversations")
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            Menu {
                Button("Send to Main Room") {
                    onSelectMainRoomChat()
                }
                if !visibleRoomUsers.isEmpty {
                    Divider()
                    ForEach(visibleRoomUsers) { user in
                        Button("Send to \(user.displayName ?? user.username)") {
                            onOpenDirectMessage(user)
                        }
                    }
                }
            } label: {
                HStack {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                    Text("Main Room Chat")
                    Spacer()
                }
                .padding(10)
                .background(selectedDirectMessageUserId == nil ? Color.blue.opacity(0.25) : Color.white.opacity(0.05))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .accessibilityHint("Choose whether messages go to the main room or a selected user.")

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(visibleRoomUsers) { user in
                        Button(action: {
                            onOpenDirectMessage(user)
                        }) {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(user.isBot ? Color.orange.opacity(0.7) : Color.blue.opacity(0.7))
                                    .frame(width: 24, height: 24)
                                    .overlay(
                                        Text(String((user.displayName ?? user.username).prefix(1)).uppercased())
                                            .font(.caption2)
                                            .foregroundColor(.white)
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(user.displayName ?? user.username)
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    if user.isBot, let status = user.statusMessage, !status.isEmpty {
                                        Text(status)
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                            .lineLimit(2)
                                    } else {
                                        Text(user.isBot ? "Bot conversation" : "Direct messages")
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                    }
                                }
                                Spacer()
                                if let count = unreadCounts[user.odId], count > 0 {
                                    Text("\(count)")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.red)
                                        .cornerRadius(10)
                                }
                            }
                            .padding(10)
                            .background(selectedDirectMessageUserId == user.odId ? Color.blue.opacity(0.25) : Color.white.opacity(0.05))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .frame(minWidth: 180, idealWidth: 220, maxWidth: 240)
        .background(Color.black.opacity(0.24))
    }
}

struct ChatConversationPanel: View {
    @ObservedObject private var messagingManager = MessagingManager.shared
    let chatTitle: String
    let selectedDirectMessageUserId: String?
    let selectedDirectMessageUserName: String?
    let totalUnreadCount: Int
    let canLoadOlderMessages: Bool
    let currentHistoryStatus: String
    let currentChatMessages: [MessagingManager.ChatMessage]
    let currentChatPlaceholder: String
    let isOnline: Bool
    let hasCurrentRoom: Bool
    let isSharing: Bool
    let directTransferStatusText: String?
    let directTransferProgressValue: Double?
    @Binding var messageText: String
    let onBack: () -> Void
    let onLoadOlder: () -> Void
    let onSkipToLatest: () -> Void
    let onSelectAttachment: () -> Void
    let onSendMessage: () -> Void
    let onReplyToMessage: (MessagingManager.ChatMessage) -> Void
    let onSendFileToSender: (MessagingManager.ChatMessage) -> (() -> Void)?
    let onDirectMessageSender: (MessagingManager.ChatMessage) -> (() -> Void)?
    let onViewSenderProfile: (MessagingManager.ChatMessage) -> (() -> Void)?
    @State private var selectedMessageId: String?
    @State private var editingMessageId: String?
    @State private var editDraft = ""
    @State private var pendingDeleteThreadRoot: MessagingManager.ChatMessage?
    @State private var removeThreadAttachments = false
    @State private var replyingToMessage: MessagingManager.ChatMessage?

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            messageListSection
            replyBarSection
            inputBarSection
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatReplyToLatest)) { _ in
            if let target = currentChatMessages.last(where: { $0.type != .system }) {
                selectedMessageId = target.id
                replyingToMessage = target
                onReplyToMessage(target)
            }
        }
        .sheet(item: Binding(
            get: { pendingDeleteThreadRoot },
            set: { newValue, _ in pendingDeleteThreadRoot = newValue }
        )) { root in
            VStack(alignment: .leading, spacing: 14) {
                Text("Delete Thread")
                    .font(.headline)
                Text("This removes \(messagingManager.threadMessages(for: root.id, inDirectMessage: selectedDirectMessageUserId).count) message(s) in the thread.")
                    .font(.subheadline)
                Toggle("Also remove attached files and links", isOn: $removeThreadAttachments)
                Text("If off, attachments are kept but marked removed in chat history.")
                    .font(.caption)
                    .foregroundColor(.gray)
                HStack {
                    Spacer()
                    Button("Cancel") {
                        pendingDeleteThreadRoot = nil
                    }
                    Button("Delete Thread", role: .destructive) {
                        messagingManager.deleteThread(
                            rootMessageId: root.id,
                            inDirectMessage: selectedDirectMessageUserId,
                            removeAttachments: removeThreadAttachments
                        )
                        pendingDeleteThreadRoot = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(width: 420)
        }
        .sheet(item: editingMessageBinding) { (message: MessagingManager.ChatMessage) in
            VStack(alignment: .leading, spacing: 14) {
                Text("Edit Message")
                    .font(.headline)
                TextEditor(text: $editDraft)
                    .frame(minHeight: 140)
                HStack {
                    Spacer()
                    Button("Cancel") {
                        editingMessageId = nil
                    }
                    Button("Save") {
                        messagingManager.editMessage(message.id, inDirectMessage: selectedDirectMessageUserId, newContent: editDraft)
                        editingMessageId = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 420)
        }
    }

    private func canEdit(_ message: MessagingManager.ChatMessage) -> Bool {
        message.senderId == (UserDefaults().string(forKey: "clientId") ?? "")
    }

    private var editingMessageBinding: Binding<MessagingManager.ChatMessage?> {
        Binding<MessagingManager.ChatMessage?>(
            get: {
                guard let id = editingMessageId else { return nil }
                return messagingManager.message(withId: id, inDirectMessage: selectedDirectMessageUserId)
            },
            set: { newValue, _ in
                editingMessageId = newValue?.id
            }
        )
    }

    private func replyPreview(for message: MessagingManager.ChatMessage) -> MessagingManager.ChatMessage? {
        guard let replyId = message.replyToId else { return nil }
        return messagingManager.message(withId: replyId, inDirectMessage: selectedDirectMessageUserId)
    }

    private var headerSection: some View {
        HStack {
            if selectedDirectMessageUserId != nil {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
            } else {
                Image(systemName: "bubble.left.and.bubble.right.fill")
            }

            Text(chatTitle)
                .font(.headline)
            Spacer()
            if totalUnreadCount > 0 {
                Text("\(totalUnreadCount)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.red)
                    .cornerRadius(10)
            }
        }
        .padding()
        .background(Color.black.opacity(0.3))
    }

    private var messageListSection: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 8) {
                Text("Messages")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal)
                    .accessibilityAddTraits(.isHeader)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if canLoadOlderMessages {
                            Button("Load Older Messages", action: onLoadOlder)
                                .buttonStyle(.bordered)
                        }

                        if !currentHistoryStatus.isEmpty {
                            Text(currentHistoryStatus)
                                .font(.caption)
                                .foregroundColor(.gray)
                        }

                        if let name = selectedDirectMessageUserName, selectedDirectMessageUserId != nil {
                            Text("Messages between You and \(name) are shown here, separate from the room's public chat.")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }

                        ForEach(currentChatMessages) { message in
                            messageRow(for: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .accessibilityLabel("Messages list")
                .accessibilityHint("Browse room or direct messages.")
            }
            .onChange(of: currentChatMessages.count) { _ in
                if let lastMessage = currentChatMessages.last {
                    withAnimation {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var replyBarSection: some View {
        if let replyingToMessage {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Replying to \(replyingToMessage.senderName)")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                    Text(replyingToMessage.content)
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    self.replyingToMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .background(Color.black.opacity(0.2))
        }
    }

    private var inputBarSection: some View {
        HStack(spacing: 8) {
            Button("Latest", action: onSkipToLatest)
                .buttonStyle(.bordered)

            Button(action: onSelectAttachment) {
                Image(systemName: "paperclip")
            }
            .buttonStyle(.bordered)
            .disabled(!isOnline || !hasCurrentRoom || isSharing)

            TextField(isOnline ? currentChatPlaceholder : "Connect to send messages", text: $messageText)
                .textFieldStyle(.roundedBorder)
                .disabled(!isOnline || !hasCurrentRoom)
                .submitLabel(.send)
                .accessibilityLabel(selectedDirectMessageUserId == nil ? "Type message to room" : "Type direct message")
                .accessibilityHint("Press Return to send.")
                .onSubmit {
                    onSendMessage()
                    replyingToMessage = nil
                }

            Button(action: onSendMessage) {
                HStack(spacing: 4) {
                    Text("Send")
                        .fontWeight(.medium)
                    Image(systemName: "paperplane.fill")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .simultaneousGesture(TapGesture().onEnded {
                replyingToMessage = nil
            })
            .disabled(messageText.isEmpty || !isOnline || !hasCurrentRoom)
            .buttonStyle(.borderedProminent)
            .tint((messageText.isEmpty || !isOnline) ? .gray : .blue)

            if let directTransferStatusText {
                HStack(spacing: 6) {
                    if let directTransferProgressValue {
                        ProgressView(value: min(max(directTransferProgressValue, 0), 1))
                            .frame(width: 84)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(directTransferStatusText)
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
                .frame(maxWidth: 240, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(directTransferStatusText)
            }
        }
        .padding()
        .background(Color.black.opacity(0.3))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message composer")
        .accessibilityHint("Type a message, attach a file, or send the current draft.")
    }

    private func messageRow(for message: MessagingManager.ChatMessage) -> some View {
        ChatMessageRow(
            message: message,
            replyPreview: replyPreview(for: message),
            isSelected: selectedMessageId == message.id,
            onSelect: { selectedMessageId = message.id },
            onReply: {
                replyingToMessage = message
                onReplyToMessage(message)
            },
            onEdit: canEdit(message) ? {
                editingMessageId = message.id
                editDraft = message.content
            } : nil,
            onFlattenThread: message.replyToId != nil ? {
                messagingManager.flattenThread(rootMessageId: message.id, inDirectMessage: selectedDirectMessageUserId)
            } : nil,
            onDeleteThread: {
                pendingDeleteThreadRoot = message
                removeThreadAttachments = false
            },
            onSendFileToSender: onSendFileToSender(message),
            onDirectMessageSender: onDirectMessageSender(message),
            onViewSenderProfile: onViewSenderProfile(message)
        )
    }
}

struct ChatMessageRow: View {
    let message: MessagingManager.ChatMessage
    var replyPreview: MessagingManager.ChatMessage? = nil
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil
    var onReply: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onFlattenThread: (() -> Void)? = nil
    var onDeleteThread: (() -> Void)? = nil
    var onSendFileToSender: (() -> Void)? = nil
    var onDirectMessageSender: (() -> Void)? = nil
    var onViewSenderProfile: (() -> Void)? = nil
    @State private var copiedNotice = false
    @State private var previewURL: URL?
    @State private var showFullURLSheet = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Avatar placeholder
            Circle()
                .fill(avatarColor)
                .frame(width: 32, height: 32)
                .overlay(
                    Text(String(message.senderName.prefix(1)).uppercased())
                        .font(.caption)
                        .foregroundColor(.white)
                )

            VStack(alignment: .leading, spacing: 2) {
                if let replyPreview {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrowshape.turn.up.left")
                                .font(.caption2)
                            Text("Reply to \(replyPreview.senderName)")
                                .font(.caption2)
                        }
                        .foregroundColor(.gray)
                        Text(replyPreview.content)
                            .font(.caption2)
                            .foregroundColor(.gray.opacity(0.9))
                            .lineLimit(2)
                    }
                    .padding(.bottom, 2)
                }
                if isActionMessage {
                    HStack(spacing: 6) {
                        Text(actionDisplayText)
                            .font(.body)
                            .italic()
                            .foregroundColor(message.type == .system ? .gray : .white)
                            .textSelection(.enabled)
                        Text(formatTime(message.timestamp))
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                } else {
                    HStack {
                        Text(message.senderName)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(message.type == .system ? .gray : .white)

                        Text(formatTime(message.timestamp))
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }

                    if shouldUsePreviewOnlyText, let previewDisplayText {
                        Text(previewDisplayText)
                            .font(.body)
                            .foregroundColor(message.type == .system ? .gray : .white)
                            .textSelection(.enabled)
                    } else {
                        Text(linkifiedContent)
                            .font(.body)
                            .foregroundColor(message.type == .system ? .gray : .white)
                            .textSelection(.enabled)
                    }
                }

                if let previewURL {
                    LinkPreviewCard(url: previewURL)
                        .padding(.top, 4)
                }

                if message.attachmentRemoved {
                    Label("Attached file is no longer available.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                } else if message.attachmentName != nil || message.attachmentURL != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(message.attachmentName ?? "Attachment", systemImage: "paperclip")
                            .font(.caption)
                            .foregroundColor(.blue.opacity(0.95))

                        if let caption = message.attachmentCaption, !caption.isEmpty {
                            Text(caption)
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }

                        if let expiresAt = message.attachmentExpiresAt {
                            Text("Expires \(relativeExpirationText(expiresAt))")
                                .font(.caption2)
                                .foregroundColor(.orange.opacity(0.9))
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isSelected ? Color.blue.opacity(0.12) : Color.clear)
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect?()
        }
        .contextMenu {
            if let onReply, message.type != .system {
                Button("Reply") {
                    onReply()
                }
            }
            Button("Copy Message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.content, forType: .string)
                copiedNotice = true
            }

            if let onEdit {
                Button("Edit Message") {
                    onEdit()
                }
            }

            if let onFlattenThread {
                Button("Flatten Thread") {
                    onFlattenThread()
                }
            }

            if let onDeleteThread {
                Button("Delete Thread") {
                    onDeleteThread()
                }
            }

            if let onSendFileToSender, message.type != .system {
                Button("Send File to Sender...") {
                    onSendFileToSender()
                }
            }

            if let onDirectMessageSender, message.type != .system {
                Button("Direct Message Sender") {
                    onDirectMessageSender()
                }
            }

            if let onViewSenderProfile, message.type != .system {
                Button("View Sender Profile") {
                    onViewSenderProfile()
                }
            }

            if let linkURL = previewURL {
                Divider()

                Button("Open Link") {
                    NSWorkspace.shared.open(linkURL)
                }

                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(linkURL.absoluteString, forType: .string)
                }

                Button("Show Full URL") {
                    showFullURLSheet = true
                }
            }

            if let attachmentURL = message.attachmentURL,
               let url = URL(string: attachmentURL),
               !message.attachmentRemoved {
                Button("Open Attachment") {
                    NSWorkspace.shared.open(url)
                }

                Button("Copy Attachment Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(attachmentURL, forType: .string)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint("Message sent at \(formatTime(message.timestamp)). Open context menu for actions.")
        .alert("Full URL", isPresented: $showFullURLSheet) {
            Button("Copy URL") {
                if let previewURL {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(previewURL.absoluteString, forType: .string)
                }
            }
            Button("Open") {
                if let previewURL {
                    NSWorkspace.shared.open(previewURL)
                }
            }
            Button("Close", role: .cancel) {}
        } message: {
            Text(previewURL?.absoluteString ?? "No link available.")
        }
        .onAppear {
            previewURL = firstPreviewURL(in: message.content)
        }
        .onChange(of: message.content) { newValue in
            previewURL = firstPreviewURL(in: newValue)
        }
    }

    private var avatarColor: Color {
        if message.type == .system {
            return .gray
        }
        // Generate consistent color from sender ID
        let hash = message.senderId.hashValue
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan]
        return colors[abs(hash) % colors.count]
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var accessibilitySummary: String {
        var parts = ["\(message.senderName). \(message.content)"]

        if message.attachmentRemoved {
            parts.append("Attached file removed.")
        } else if let attachmentName = message.attachmentName ?? message.attachmentURL {
            parts.append("Attachment: \(attachmentName).")
            if let expiresAt = message.attachmentExpiresAt {
                parts.append("Expires \(relativeExpirationText(expiresAt)).")
            }
        }

        return parts.joined(separator: " ")
    }

    private func relativeExpirationText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func firstPreviewURL(in text: String) -> URL? {
        guard message.attachmentURL == nil else { return nil }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = detector?.matches(in: text, options: [], range: range).first,
           let url = match.url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return url
        }

        guard let bare = firstBareDomain(in: text) else { return nil }
        return URL(string: "https://\(bare)")
    }

    private var linkifiedContent: AttributedString {
        var attributed = AttributedString(message.content)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let nsRange = NSRange(message.content.startIndex..<message.content.endIndex, in: message.content)
        let matches = detector?.matches(in: message.content, options: [], range: nsRange) ?? []

        for match in matches {
            guard let url = match.url,
                  let range = Range(match.range, in: message.content),
                  let attributedRange = Range(NSRange(range, in: message.content), in: attributed),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                continue
            }

            attributed[attributedRange].link = url
            attributed[attributedRange].foregroundColor = .blue
            attributed[attributedRange].underlineStyle = .single
        }

        let domainRegex = #"\b(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}(?:/[^\s<>"']*)?"#
        if let regex = try? NSRegularExpression(pattern: domainRegex, options: [.caseInsensitive]) {
            let matches = regex.matches(in: message.content, options: [], range: nsRange)
            for match in matches {
                guard let range = Range(match.range, in: message.content) else { continue }
                let raw = String(message.content[range]).replacingOccurrences(of: #"[),.!?;:]+$"#, with: "", options: .regularExpression)
                if raw.contains("@") || raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") {
                    continue
                }
                guard let url = URL(string: "https://\(raw)"),
                      let attributedRange = Range(NSRange(range, in: message.content), in: attributed) else {
                    continue
                }
                attributed[attributedRange].link = url
                attributed[attributedRange].foregroundColor = .blue
                attributed[attributedRange].underlineStyle = .single
            }
        }

        return attributed
    }

    private var isActionMessage: Bool {
        guard message.type == .text else { return false }
        let sender = message.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sender.isEmpty, !content.isEmpty else { return false }
        return content.lowercased().hasPrefix("\(sender.lowercased()) ")
    }

    private var actionDisplayText: String {
        let sender = message.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isActionMessage else { return content }
        let prefixCount = sender.count + 1
        guard content.count > prefixCount else { return content }
        let actionBody = String(content.dropFirst(prefixCount)).trimmingCharacters(in: .whitespacesAndNewlines)
        return actionBody.isEmpty ? content : "\(sender) \(actionBody)"
    }

    private func firstBareDomain(in text: String) -> String? {
        let domainRegex = #"\b(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}(?:/[^\s<>"']*)?"#
        guard let regex = try? NSRegularExpression(pattern: domainRegex, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.matches(in: text, options: [], range: range).first,
              let matchRange = Range(match.range, in: text) else {
            return nil
        }
        let raw = String(text[matchRange]).replacingOccurrences(of: #"[),.!?;:]+$"#, with: "", options: .regularExpression)
        if raw.contains("@") {
            return nil
        }
        return raw
    }

    private var shouldUsePreviewOnlyText: Bool {
        previewURL != nil && !isActionMessage
    }

    private var previewDisplayText: String? {
        let stripped = stripURLs(from: message.content).trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty {
            return "Shared a link"
        }
        return stripped
    }

    private func stripURLs(from text: String) -> String {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var cleaned = text
        let matches = detector?.matches(in: text, options: [], range: range) ?? []
        for match in matches.reversed() {
            guard let foundRange = Range(match.range, in: cleaned) else { continue }
            cleaned.removeSubrange(foundRange)
        }

        let domainRegex = #"\b(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}(?:/[^\s<>"']*)?"#
        cleaned = cleaned.replacingOccurrences(of: domainRegex, with: "", options: [.regularExpression, .caseInsensitive])
        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return cleaned
    }
}

struct LinkPreviewCard: View {
    let url: URL
    @State private var title: String?
    @State private var summary: String?
    @State private var resolvedURL: URL?
    @State private var showFullURL = false
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var isMuted = false
    @State private var duration: Double = 0
    @State private var currentTime: Double = 0
    @State private var isSeeking = false
    @State private var timeObserverToken: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                NSWorkspace.shared.open(resolvedURL ?? url)
            }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title ?? fallbackTitle)
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .lineLimit(2)

                    if let summary, !summary.isEmpty {
                        Text(summary)
                            .font(.caption2)
                            .foregroundColor(.gray)
                            .lineLimit(3)
                    }

                    Text((resolvedURL ?? url).host ?? fallbackTitle)
                        .font(.caption2)
                        .foregroundColor(.blue.opacity(0.9))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if isPlayableMediaLink {
                Divider().overlay(Color.white.opacity(0.12))
                HStack(spacing: 8) {
                    Button(isPlaying ? "Pause" : "Play") {
                        togglePlayback()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Stop") {
                        stopPlayback()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(isMuted ? "Unmute" : "Mute") {
                        toggleMute()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Slider(
                    value: Binding(
                        get: { currentTime },
                        set: { newValue in
                            isSeeking = true
                            currentTime = newValue
                        }
                    ),
                    in: 0...max(duration, 1),
                    onEditingChanged: { editing in
                        if !editing {
                            seek(to: currentTime)
                            isSeeking = false
                        }
                    }
                )
                .controlSize(.small)

                HStack {
                    Text(formatTime(currentTime))
                    Spacer()
                    Text(formatTime(duration))
                }
                .font(.caption2)
                .foregroundColor(.gray)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .cornerRadius(8)
        .contextMenu {
            Button("Open Link") {
                NSWorkspace.shared.open(resolvedURL ?? url)
            }

            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString((resolvedURL ?? url).absoluteString, forType: .string)
            }

            Button("Show Full URL") {
                showFullURL = true
            }
        }
        .alert("Full URL", isPresented: $showFullURL) {
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString((resolvedURL ?? url).absoluteString, forType: .string)
            }
            Button("Open") {
                NSWorkspace.shared.open(resolvedURL ?? url)
            }
            Button("Close", role: .cancel) {}
        } message: {
            Text((resolvedURL ?? url).absoluteString)
        }
        .task(id: url.absoluteString) {
            await loadMetadata()
        }
        .onDisappear {
            teardownPlayer()
        }
        .accessibilityLabel("Link preview for \(title ?? fallbackTitle)")
        .accessibilityHint("Opens \(resolvedURL?.absoluteString ?? url.absoluteString)")
    }

    private var fallbackTitle: String {
        let host = (resolvedURL ?? url).host ?? url.host ?? url.absoluteString
        if host.isEmpty { return url.absoluteString }
        let cleaned = host.replacingOccurrences(of: "www.", with: "")
        return cleaned
            .split(separator: ".")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private var isPlayableMediaLink: Bool {
        let candidate = resolvedURL ?? url
        let ext = candidate.pathExtension.lowercased()
        if ["mp3", "m4a", "aac", "wav", "ogg", "flac", "mp4", "m3u8", "mov", "webm"].contains(ext) {
            return true
        }
        let host = candidate.host?.lowercased() ?? ""
        if host.contains("youtube.com") || host.contains("youtu.be") || host.contains("soundcloud.com") || host.contains("vimeo.com") {
            return true
        }
        return false
    }

    @MainActor
    private func loadMetadata() async {
        resolvedURL = url
        title = fallbackTitle
        summary = (resolvedURL ?? url).host ?? url.host

        if let fastTitle = await fetchFastTitle(for: url), !fastTitle.isEmpty {
            title = fastTitle
        }

        let provider = LPMetadataProvider()
        provider.timeout = 5
        do {
            let metadata = try await provider.startFetchingMetadata(for: url)
            title = metadata.title ?? title ?? fallbackTitle
            resolvedURL = metadata.originalURL ?? metadata.url ?? url
            summary = metadata.url?.host ?? metadata.originalURL?.host ?? summary
        } catch {
            if title == nil {
                title = fallbackTitle
            }
            if resolvedURL == nil {
                resolvedURL = url
            }
        }
    }

    private func fetchFastTitle(for url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (VoiceLink)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) else {
                return nil
            }
            guard let html = String(data: data, encoding: .utf8) else {
                return nil
            }
            if let ogTitle = firstMatch(in: html, pattern: #"<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']"#) {
                return decodeHTMLEntities(ogTitle)
            }
            if let title = firstMatch(in: html, pattern: #"<title[^>]*>([^<]+)</title>"#) {
                return decodeHTMLEntities(title)
            }
            return nil
        } catch {
            return nil
        }
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func togglePlayback() {
        if player == nil {
            preparePlayer()
        }
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func stopPlayback() {
        guard let player else { return }
        player.pause()
        player.seek(to: .zero)
        isPlaying = false
        currentTime = 0
    }

    private func toggleMute() {
        guard let player else { return }
        isMuted.toggle()
        player.isMuted = isMuted
    }

    private func seek(to time: Double) {
        guard let player else { return }
        let target = CMTime(seconds: max(0, min(time, duration)), preferredTimescale: 600)
        player.seek(to: target)
    }

    private func preparePlayer() {
        guard player == nil else { return }
        let targetURL = resolvedURL ?? url
        let newPlayer = AVPlayer(url: targetURL)
        newPlayer.isMuted = isMuted
        player = newPlayer

        if let token = timeObserverToken {
            newPlayer.removeTimeObserver(token)
            timeObserverToken = nil
        }

        timeObserverToken = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { time in
            guard !isSeeking else { return }
            currentTime = time.seconds.isFinite ? time.seconds : 0
            if let item = newPlayer.currentItem {
                let seconds = item.duration.seconds
                duration = seconds.isFinite && seconds > 0 ? seconds : duration
            }
        }
    }

    private func teardownPlayer() {
        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
        }
        timeObserverToken = nil
        player?.pause()
        player = nil
        isPlaying = false
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let mins = total / 60
        let secs = total % 60
        return "\(mins):" + String(format: "%02d", secs)
    }
}

struct UserRow: View {
    let userId: String
    let username: String
    let isMuted: Bool
    let isDeafened: Bool
    let isSpeaking: Bool
    var isCurrentUser: Bool = false
    var roomUser: RoomUser? = nil
    var roomName: String? = nil
    var connectedServerName: String? = nil

    @State private var showControls = false
    @State private var showMonitoringWarning = false
    @State private var showProfileSheet = false
    @State private var userVolume: Double = 1.0
    @State private var pendingSharedFiles: [URL] = []
    @State private var showShareFileSheet = false
    @State private var shareKeepForever = false
    @State private var shareCaption = ""
    @State private var shareExpiryHours = 24
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var audioControl = UserAudioControlManager.shared
    @ObservedObject private var monitor = LocalMonitorManager.shared
    @ObservedObject private var serverManager = ServerManager.shared
    @ObservedObject private var adminManager = AdminServerManager.shared
    @State private var shareInProgress = false

    private var resolvedVolume: Double {
        if isCurrentUser {
            return settings.inputVolume
        }
        return Double(audioControl.getVolume(for: userId))
    }

    private var resolvedPan: Double {
        if isCurrentUser {
            return 0
        }
        return Double(audioControl.getPan(for: userId))
    }

    private var isUserMuted: Bool {
        if isCurrentUser { return false }
        return audioControl.isMuted(userId)
    }

    private var isSoloed: Bool {
        if isCurrentUser { return monitor.isMonitoring }
        return audioControl.isSolo(userId)
    }

    private var isRoomAudioActive: Bool {
        serverManager.activeRoomId != nil || serverManager.isAudioTransmitting
    }

    private var hasAudioControls: Bool {
        if isCurrentUser { return true }
        return roomUser?.hasAudioControls ?? !(roomUser?.isBot ?? false)
    }

    private var displayStatusText: String? {
        guard settings.showUserStatusesInRoomList else { return nil }
        let rawStatus = roomUser?.status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawStatus.isEmpty else { return nil }
        return rawStatus
    }

    private var canManageServerUser: Bool {
        !isCurrentUser && (adminManager.isAdmin || adminManager.adminRole.canManageUsers)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main row
            HStack {
                // Speaking indicator
                Circle()
                    .fill(isSpeaking ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 10, height: 10)

                HStack(spacing: 6) {
                    Text(username)
                        .foregroundColor(.white)
                    if let displayStatusText {
                        Text("(\(displayStatusText))")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if isMuted {
                    Image(systemName: "mic.slash.fill")
                        .foregroundColor(.red)
                }
                if isDeafened {
                    Image(systemName: "speaker.slash.fill")
                        .foregroundColor(.red)
                }

                // Expand/collapse button with explicit accessible labels.
                Button(action: { showControls.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: showControls ? "chevron.up" : "chevron.down")
                            .foregroundColor(.white.opacity(0.7))
                        Text(showControls ? "Hide Audio Controls for User" : "Show Audio Controls for User")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.75))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showControls ? "Hide Audio Controls for User" : "Show Audio Controls for User")
                .accessibilityHint("Toggles per-user audio controls for \(username)")
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.05))
            .contextMenu {
                Button(action: {
                    // TODO: Implement whisper mode
                    print("Whisper to \(username)")
                }) {
                    Label("Whisper", systemImage: "mic.badge.plus")
                }

                Button(action: {
                    NotificationCenter.default.post(
                        name: .openDirectMessage,
                        object: nil,
                        userInfo: ["userId": userId, "userName": username]
                    )
                }) {
                    Label("Send Direct Message", systemImage: "message")
                }

                Button(action: {
                    selectFileForSharing()
                }) {
                    Label("Send File...", systemImage: "doc.badge.plus")
                }
                .disabled(shareInProgress)

                Divider()

                Button(action: {
                    showProfileSheet = true
                }) {
                    Label("View Profile", systemImage: "person.circle")
                }

                if canManageServerUser {
                    Divider()

                    Button(action: {
                        Task {
                            _ = await adminManager.updateUserRole(
                                userId,
                                role: "moderator",
                                accountId: roomUser?.id,
                                email: roomUser?.email,
                                username: roomUser?.username,
                                displayName: roomUser?.displayName
                            )
                            await adminManager.fetchConnectedUsers()
                        }
                    }) {
                        Label("Grant Moderator", systemImage: "person.badge.shield.checkmark")
                    }

                    Button(action: {
                        Task {
                            _ = await adminManager.updateUserRole(
                                userId,
                                role: "admin",
                                accountId: roomUser?.id,
                                email: roomUser?.email,
                                username: roomUser?.username,
                                displayName: roomUser?.displayName
                            )
                            await adminManager.fetchConnectedUsers()
                        }
                    }) {
                        Label("Grant Admin", systemImage: "person.crop.circle.badge.checkmark")
                    }

                    Button(action: {
                        Task {
                            _ = await adminManager.revokeUserRole(
                                userId,
                                accountId: roomUser?.id,
                                email: roomUser?.email,
                                username: roomUser?.username
                            )
                            await adminManager.fetchConnectedUsers()
                        }
                    }) {
                        Label("Revoke Elevated Access", systemImage: "person.crop.circle.badge.minus")
                    }

                    Button(role: .destructive, action: {
                        Task {
                            _ = await adminManager.kickUser(userId, reason: "Removed by room administrator")
                            await adminManager.fetchConnectedUsers()
                        }
                    }) {
                        Label("Kick From Room", systemImage: "person.badge.minus")
                    }
                }
            }

            // Expandable audio controls
            if showControls {
                VStack(spacing: 8) {
                    if hasAudioControls {
                        if isCurrentUser {
                            Text("You cannot mute yourself from the room user list. Use the main room mute controls.")
                                .font(.caption2)
                                .foregroundColor(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        HStack {
                            Image(systemName: "speaker.wave.2")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                            Slider(
                                value: Binding(
                                    get: { resolvedVolume },
                                    set: { newValue in
                                        if isCurrentUser {
                                            settings.inputVolume = newValue
                                            settings.saveSettings()
                                            LocalMonitorManager.shared.setInputGain(newValue)
                                        } else {
                                            audioControl.setVolume(for: userId, volume: Float(newValue))
                                        }
                                    }
                                ),
                                in: 0...1
                            )
                                .frame(maxWidth: .infinity)
                            Text("\(Int(resolvedVolume * 100))%")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                                .frame(width: 35)
                        }

                        if !isCurrentUser {
                            HStack {
                                Image(systemName: "arrow.left.and.right")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.7))
                                Slider(
                                    value: Binding(
                                        get: { resolvedPan },
                                        set: { newValue in
                                            audioControl.setPan(for: userId, pan: Float(newValue))
                                        }
                                    ),
                                    in: -1...1,
                                    step: 0.05
                                )
                                .frame(maxWidth: .infinity)
                                Text(panStatusText)
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.7))
                                    .frame(width: 52)
                            }

                            Text("Pan this user left or right. 0 keeps centered stereo.")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }

                        if isCurrentUser {
                            Text("This slider controls your microphone input level.")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }

                        HStack(spacing: 12) {
                            if !isCurrentUser {
                                Button(action: {
                                    audioControl.toggleMute(for: userId)
                                }) {
                                    HStack {
                                        Image(systemName: isUserMuted ? "speaker.slash.fill" : "speaker.fill")
                                        Text(isUserMuted ? "Unmute" : "Mute")
                                    }
                                    .font(.caption)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(isUserMuted ? Color.red.opacity(0.3) : Color.gray.opacity(0.2))
                                    .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }

                            Button(action: {
                                if isCurrentUser {
                                    if monitor.isMonitoring {
                                        monitor.toggleMonitoring()
                                    } else {
                                        showMonitoringWarning = true
                                    }
                                } else {
                                    audioControl.toggleSolo(for: userId)
                                }
                            }) {
                                HStack {
                                    Image(systemName: isSoloed ? "ear.fill" : "ear")
                                    Text(isCurrentUser ? (isSoloed ? "Stop Monitor" : "Monitor") : (isSoloed ? "Unsolo" : "Solo"))
                                }
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(isSoloed ? Color.yellow.opacity(0.3) : Color.gray.opacity(0.2))
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                        if isCurrentUser {
                            Text("Monitor lets you hear your current input device and may cause feedback if speakers are active.")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    } else {
                        Text("This bot does not expose audio controls. Use chat commands or room controls to interact with it.")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.02))
            }
        }
        .cornerRadius(8)
        .confirmationDialog(
            "Enable self monitoring?",
            isPresented: $showMonitoringWarning,
            titleVisibility: .visible
        ) {
            Button("Enable Monitoring") {
                monitor.toggleMonitoring()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This plays your current input device back to your selected output device. Use headphones to avoid feedback.")
        }
        .sheet(isPresented: $showProfileSheet) {
            UserProfileSheet(
                userId: userId,
                username: username,
                isCurrentUser: isCurrentUser,
                roomUser: roomUser,
                roomName: roomName,
                connectedServerName: connectedServerName,
                isRoomAudioActive: isRoomAudioActive,
                isUserMuted: isUserMuted,
                isSoloed: isSoloed,
                monitorIsActive: monitor.isMonitoring,
                onDirectMessage: {
                    NotificationCenter.default.post(
                        name: .openDirectMessage,
                        object: nil,
                        userInfo: ["userId": userId, "userName": username]
                    )
                },
                onSendFile: {
                    selectFileForSharing()
                },
                onToggleMute: {
                    if !isCurrentUser {
                        audioControl.toggleMute(for: userId)
                    }
                },
                onToggleSolo: {
                    if !isCurrentUser {
                        audioControl.toggleSolo(for: userId)
                    }
                },
                onToggleMonitor: {
                    if isCurrentUser {
                        if monitor.isMonitoring {
                            monitor.toggleMonitoring()
                        } else {
                            showMonitoringWarning = true
                        }
                    }
                },
                onGrantModerator: canManageServerUser ? {
                    Task {
                        _ = await adminManager.updateUserRole(
                            userId,
                            role: "moderator",
                            accountId: roomUser?.id,
                            email: roomUser?.email,
                            username: roomUser?.username,
                            displayName: roomUser?.displayName
                        )
                        await adminManager.fetchConnectedUsers()
                    }
                } : nil,
                onGrantAdmin: canManageServerUser ? {
                    Task {
                        _ = await adminManager.updateUserRole(
                            userId,
                            role: "admin",
                            accountId: roomUser?.id,
                            email: roomUser?.email,
                            username: roomUser?.username,
                            displayName: roomUser?.displayName
                        )
                        await adminManager.fetchConnectedUsers()
                    }
                } : nil,
                onRevokeElevatedAccess: canManageServerUser ? {
                    Task {
                        _ = await adminManager.revokeUserRole(
                            userId,
                            accountId: roomUser?.id,
                            email: roomUser?.email,
                            username: roomUser?.username
                        )
                        await adminManager.fetchConnectedUsers()
                    }
                } : nil,
                onKickFromRoom: canManageServerUser ? {
                    Task {
                        _ = await adminManager.kickUser(userId, reason: "Removed by room administrator")
                        await adminManager.fetchConnectedUsers()
                    }
                } : nil
            )
        }
        .sheet(isPresented: $showShareFileSheet, onDismiss: resetShareDraft) {
            if !pendingSharedFiles.isEmpty {
                ProtectedFileShareSheet(
                    fileURLs: pendingSharedFiles,
                    recipientName: username,
                    keepForever: $shareKeepForever,
                    caption: $shareCaption,
                    expiryHours: $shareExpiryHours,
                    isSending: shareInProgress,
                    onCancel: {
                        showShareFileSheet = false
                    },
                    onSend: {
                        shareSelectedFileToUser()
                    }
                )
            }
        }
        .accessibilityAction(named: Text(showControls ? "Hide Audio Controls for User" : "Show Audio Controls for User")) {
            showControls.toggle()
        }
    }

    private func selectFileForSharing() {
        FileTransferManager.shared.showFilePicker(allowsMultipleSelection: true) { urls in
            guard !urls.isEmpty else { return }
            pendingSharedFiles = urls
            shareCaption = ""
            shareKeepForever = false
            shareExpiryHours = max(1, min(24 * 60, CopyPartyManager.shared.config.defaultExternalLinkExpiryHours))
            showShareFileSheet = true
        }
    }

    private func shareSelectedFileToUser() {
        guard !pendingSharedFiles.isEmpty else { return }
        shareInProgress = true
        let keepForever = shareKeepForever
        let expiryHours = keepForever ? nil : max(1, min(24 * 60, shareExpiryHours))
        let caption = shareCaption.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedFiles = pendingSharedFiles
        let isSelfTransfer = userId == (AuthenticationManager.shared.currentUser?.id ?? "")
        let onlineOtherDevices = LicensingManager.shared.devices.filter { device in
            let isCurrent = device.id == LicensingManager.shared.currentDeviceUUID
                || (device.platform == LicensingManager.shared.currentDevicePlatform
                    && device.name == LicensingManager.shared.currentDeviceName)
            guard !isCurrent else { return false }
            let formatter = ISO8601DateFormatter()
            guard let lastSeen = formatter.date(from: device.lastSeen) else { return false }
            return Date().timeIntervalSince(lastSeen) <= 300
        }

        Task {
            defer {
                DispatchQueue.main.async { shareInProgress = false }
            }
            do {
                let attachmentName = selectedFiles.count > 1
                    ? "\(selectedFiles.count) files"
                    : selectedFiles[0].lastPathComponent
                let link: CopyPartyManager.ProtectedShareLink
                if selectedFiles.count > 1 {
                    link = try await CopyPartyManager.shared.uploadFilesAndCreateProtectedLink(
                        from: selectedFiles,
                        to: "/uploads/\(username)",
                        folderName: "VoiceLink-\(username)-Files",
                        keepForever: keepForever,
                        expiryHours: expiryHours
                    )
                } else {
                    link = try await CopyPartyManager.shared.uploadFileAndCreateProtectedLink(
                        from: selectedFiles[0],
                        to: "/uploads/\(username)",
                        keepForever: keepForever,
                        expiryHours: expiryHours
                    )
                }
                DispatchQueue.main.async {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.url, forType: .string)
                    MessagingManager.shared.sendDirectAttachment(
                        to: self.userId,
                        username: self.username,
                        content: isSelfTransfer
                            ? (selectedFiles.count > 1 ? "Saved \(selectedFiles.count) files for later." : "Saved file for later: \(attachmentName)")
                            : (selectedFiles.count > 1 ? "Shared \(selectedFiles.count) files." : "Shared file: \(attachmentName)"),
                        attachmentName: attachmentName,
                        attachmentURL: link.url,
                        caption: caption,
                        expiresAt: link.expiresAt
                    )
                    MessagingManager.shared.sendSystemMessage(
                        {
                            if isSelfTransfer {
                                let availability = onlineOtherDevices.isEmpty
                                    ? "No other signed-in devices are online right now. The protected link was saved for later use."
                                    : "Available now on \(onlineOtherDevices.count) other signed-in device\(onlineOtherDevices.count == 1 ? "" : "s")."
                                return keepForever
                                    ? "Saved \(attachmentName) for later with a persistent link. \(availability)"
                                    : "Saved \(attachmentName) for later. Link expires \(link.expiresAt?.formatted(date: .abbreviated, time: .shortened) ?? "later"). \(availability)"
                            }
                            return keepForever
                                ? "Shared \(attachmentName) with \(self.username) using a persistent link."
                                : "Shared \(attachmentName) with \(self.username). Link expires \(link.expiresAt?.formatted(date: .abbreviated, time: .shortened) ?? "later")."
                        }()
                    )
                    showShareFileSheet = false
                }
            } catch {
                DispatchQueue.main.async {
                    MessagingManager.shared.sendSystemMessage("Protected link share failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func resetShareDraft() {
        pendingSharedFiles = []
        shareCaption = ""
        shareKeepForever = false
        shareExpiryHours = 24
    }

    private var panStatusText: String {
        let pan = audioControl.getPan(for: userId)
        let percent = Int(abs(pan) * 100)
        if percent == 0 { return "0 / Stereo" }
        return pan < 0 ? "\(percent)L" : "\(percent)R"
    }
}

struct ProtectedFileShareSheet: View {
    let fileURLs: [URL]
    let recipientName: String
    @Binding var keepForever: Bool
    @Binding var caption: String
    @Binding var expiryHours: Int
    let isSending: Bool
    let onCancel: () -> Void
    let onSend: () -> Void

    private let quickExpiryOptions = [1, 24, 72, 24 * 7, 24 * 30, 24 * 60]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Send File")
                .font(.title2.weight(.semibold))

            Text(summaryText)
                .foregroundColor(.secondary)

            Toggle("Keep this link available until manually removed", isOn: $keepForever)

            if !keepForever {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Link Expiry")
                        .font(.headline)
                    Picker("Link Expiry", selection: $expiryHours) {
                        ForEach(quickExpiryOptions, id: \.self) { hours in
                            Text(expiryLabel(for: hours)).tag(hours)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("Supported quick options range from 1 hour to 60 days.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Caption")
                    .font(.headline)
                TextField("Optional details about this file", text: $caption, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSending)
                Button(isSending ? "Sending..." : "Send", action: onSend)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSending)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var summaryText: String {
        if fileURLs.count == 1, let fileURL = fileURLs.first {
            return "Share \(fileURL.lastPathComponent) with \(recipientName). Choose whether the link expires or stays available until you remove it."
        }
        return "Share \(fileURLs.count) files with \(recipientName). Multiple files will be bundled into a zip archive before upload."
    }

    private func expiryLabel(for hours: Int) -> String {
        switch hours {
        case 1:
            return "1 hour"
        case 24:
            return "1 day"
        case 72:
            return "3 days"
        case 24 * 7:
            return "7 days"
        case 24 * 30:
            return "30 days"
        case 24 * 60:
            return "60 days"
        default:
            return "\(hours) hours"
        }
    }
}
