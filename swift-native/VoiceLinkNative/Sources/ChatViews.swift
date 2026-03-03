import SwiftUI
import AppKit
import LinkPresentation

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

            Button(action: onSelectMainRoomChat) {
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
    @Binding var messageText: String
    let onBack: () -> Void
    let onLoadOlder: () -> Void
    let onSkipToLatest: () -> Void
    let onSelectAttachment: () -> Void
    let onSendMessage: () -> Void
    let onSendFileToSender: (MessagingManager.ChatMessage) -> (() -> Void)?
    let onDirectMessageSender: (MessagingManager.ChatMessage) -> (() -> Void)?
    let onViewSenderProfile: (MessagingManager.ChatMessage) -> (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
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

            ScrollViewReader { proxy in
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
                            ChatMessageRow(
                                message: message,
                                onSendFileToSender: onSendFileToSender(message),
                                onDirectMessageSender: onDirectMessageSender(message),
                                onViewSenderProfile: onViewSenderProfile(message)
                            )
                            .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: currentChatMessages.count) { _ in
                    if let lastMessage = currentChatMessages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

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
                    .onSubmit {
                        onSendMessage()
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
                .disabled(messageText.isEmpty || !isOnline || !hasCurrentRoom)
                .buttonStyle(.borderedProminent)
                .tint((messageText.isEmpty || !isOnline) ? .gray : .blue)
            }
            .padding()
            .background(Color.black.opacity(0.3))
        }
    }
}

struct ChatMessageRow: View {
    let message: MessagingManager.ChatMessage
    var onSendFileToSender: (() -> Void)? = nil
    var onDirectMessageSender: (() -> Void)? = nil
    var onViewSenderProfile: (() -> Void)? = nil
    @State private var copiedNotice = false
    @State private var previewURL: URL?

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
                HStack {
                    Text(message.senderName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(message.type == .system ? .gray : .white)

                    Text(formatTime(message.timestamp))
                        .font(.caption2)
                        .foregroundColor(.gray)
                }

                Text(message.content)
                    .font(.body)
                    .foregroundColor(message.type == .system ? .gray : .white)

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
        .contextMenu {
            Button("Copy Message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.content, forType: .string)
                copiedNotice = true
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
        let match = detector?.matches(in: text, options: [], range: range).first
        guard let url = match?.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        return url
    }
}

struct LinkPreviewCard: View {
    let url: URL
    @State private var title: String?
    @State private var summary: String?
    @State private var resolvedURL: URL?

    var body: some View {
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

                Text((resolvedURL ?? url).absoluteString)
                    .font(.caption2)
                    .foregroundColor(.blue.opacity(0.9))
                    .lineLimit(1)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .task(id: url.absoluteString) {
            await loadMetadata()
        }
        .accessibilityLabel("Link preview for \(title ?? fallbackTitle)")
        .accessibilityHint("Opens \(resolvedURL?.absoluteString ?? url.absoluteString)")
    }

    private var fallbackTitle: String {
        url.host ?? url.absoluteString
    }

    @MainActor
    private func loadMetadata() async {
        let provider = LPMetadataProvider()
        provider.timeout = 5
        do {
            let metadata = try await provider.startFetchingMetadata(for: url)
            title = metadata.title ?? fallbackTitle
            resolvedURL = metadata.originalURL ?? metadata.url ?? url
            summary = metadata.url?.host ?? metadata.originalURL?.host
        } catch {
            title = fallbackTitle
            resolvedURL = url
            summary = nil
        }
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
    @State private var shareInProgress = false

    private var resolvedVolume: Double {
        if isCurrentUser {
            return settings.inputVolume
        }
        return Double(audioControl.getVolume(for: userId))
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

    var body: some View {
        VStack(spacing: 0) {
            // Main row
            HStack {
                // Speaking indicator
                Circle()
                    .fill(isSpeaking ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 10, height: 10)

                Text(username)
                    .foregroundColor(.white)

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
            }

            // Expandable audio controls
            if showControls {
                VStack(spacing: 8) {
                    if hasAudioControls {
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

                        if isCurrentUser {
                            Text("This slider controls your microphone input level.")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }

                        HStack(spacing: 12) {
                            Button(action: {
                                if !isCurrentUser {
                                    audioControl.toggleMute(for: userId)
                                }
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
                            .disabled(isCurrentUser)

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
                            Text("You cannot mute yourself in this list. Use main room mute controls. Monitor lets you hear your current input device and may cause feedback if speakers are active.")
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
                }
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
                        content: selectedFiles.count > 1 ? "Shared \(selectedFiles.count) files." : "Shared file: \(attachmentName)",
                        attachmentName: attachmentName,
                        attachmentURL: link.url,
                        caption: caption,
                        expiresAt: link.expiresAt
                    )
                    MessagingManager.shared.sendSystemMessage(
                        keepForever
                            ? "Shared \(attachmentName) with \(self.username) using a persistent link."
                            : "Shared \(attachmentName) with \(self.username). Link expires \(link.expiresAt?.formatted(date: .abbreviated, time: .shortened) ?? "later")."
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
