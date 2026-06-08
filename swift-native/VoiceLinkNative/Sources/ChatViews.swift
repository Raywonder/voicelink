import SwiftUI
import AppKit

struct ChatConversationSidebar: View {
    let visibleRoomUsers: [RoomUser]
    let selectedDirectMessageUserId: String?
    let unreadCounts: [String: Int]
    let onSelectMainRoomChat: () -> Void
    let onOpenDirectMessage: (RoomUser) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Chats")
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .accessibilityAddTraits(.isHeader)

            Button(action: onSelectMainRoomChat) {
                HStack {
                    Label("Main Room Chat", systemImage: "bubble.left.and.bubble.right.fill")
                    Spacer()
                }
                .padding(10)
                .background(selectedDirectMessageUserId == nil ? Color.blue.opacity(0.25) : Color.white.opacity(0.05))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .accessibilityLabel("Main room chat")
            .accessibilityHint("Open the shared room conversation.")

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(visibleRoomUsers) { user in
                        let unread = unreadCounts[user.odId] ?? 0
                        Button(action: { onOpenDirectMessage(user) }) {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(Color.blue.opacity(0.7))
                                    .frame(width: 24, height: 24)
                                    .overlay(
                                        Text(String(user.username.prefix(1)).uppercased())
                                            .font(.caption2)
                                            .foregroundColor(.white)
                                    )

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(user.username)
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    Text("Direct messages")
                                        .font(.caption2)
                                        .foregroundColor(.gray)
                                }

                                Spacer()

                                if unread > 0 {
                                    Text("\(unread)")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.red)
                                        .foregroundColor(.white)
                                        .cornerRadius(10)
                                }
                            }
                            .padding(10)
                            .background(selectedDirectMessageUserId == user.odId ? Color.blue.opacity(0.25) : Color.white.opacity(0.05))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(user.username) direct messages")
                        .accessibilityHint("Open direct messages with \(user.username).")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .frame(minWidth: 180, idealWidth: 220, maxWidth: 240)
        .background(Color.black.opacity(0.24))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat sidebar")
    }
}

private struct MessageComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isEnabled: Bool
    let onSend: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .bezelBorder

        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.onSend = onSend
        textView.placeholder = placeholder
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.minSize = NSSize(width: 0, height: 34)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Message")

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }
        context.coordinator.parent = self
        textView.onSend = onSend
        textView.placeholder = placeholder
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        if textView.string != text {
            textView.string = text
        }
        textView.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MessageComposerTextView

        init(_ parent: MessageComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

private final class ComposerNSTextView: NSTextView {
    var onSend: (() -> Void)?
    var placeholder: String = ""

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.shift) {
                insertNewline(nil)
            } else {
                onSend?()
            }
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        ]
        NSAttributedString(string: placeholder, attributes: attributes)
            .draw(at: NSPoint(x: textContainerInset.width + 3, y: textContainerInset.height))
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
    let canSendMessages: Bool
    let isSharing: Bool
    @Binding var messageText: String
    @Binding var replyingToMessage: MessagingManager.ChatMessage?
    @Binding var selectedMessageId: String?
    let onBack: () -> Void
    let onLoadOlder: () -> Void
    let onSkipToLatest: () -> Void
    let onSelectAttachment: () -> Void
    let onSendMessage: () -> Void
    let onReplyToMessage: (MessagingManager.ChatMessage) -> Void
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
                    .accessibilityHint("Return to the main room chat.")
                } else {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .foregroundColor(.white)
                }

                Text(chatTitle)
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()

                if totalUnreadCount > 0 {
                    Text("\(totalUnreadCount)")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .accessibilityLabel("\(totalUnreadCount) unread messages")
                }
            }
            .padding()
            .background(Color.black.opacity(0.3))

            if canLoadOlderMessages || !currentHistoryStatus.isEmpty {
                VStack(spacing: 8) {
                    if canLoadOlderMessages {
                        Button("Load Older Messages", action: onLoadOlder)
                            .buttonStyle(.bordered)
                    }
                    if !currentHistoryStatus.isEmpty {
                        Text(currentHistoryStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 10)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if currentChatMessages.isEmpty {
                            Text(currentChatPlaceholder)
                                .font(.caption)
                                .foregroundColor(.gray)
                                .padding()
                        }

                        ForEach(currentChatMessages) { message in
                            chatMessageRow(message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: currentChatMessages.count) { _ in
                    if let last = currentChatMessages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            if let replyingToMessage {
                HStack {
                    Text("Replying to \(replyingToMessage.senderName)")
                        .font(.caption)
                        .foregroundColor(.white)
                    Spacer()
                    Button("Clear") {
                        self.replyingToMessage = nil
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.15))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Replying to \(replyingToMessage.senderName)")
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button(action: onSelectAttachment) {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.bordered)
                .disabled(isSharing || !canSendMessages)
                .accessibilityLabel("Attach file")

                MessageComposerTextView(
                    text: $messageText,
                    placeholder: currentChatPlaceholder,
                    isEnabled: canSendMessages && !isSharing,
                    onSend: onSendMessage
                )
                    .frame(minHeight: 34, idealHeight: 42, maxHeight: 112)
                    .disabled(!canSendMessages || isSharing)
                    .accessibilityLabel("Message")

                Button("Send", action: onSendMessage)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSendMessages || isSharing || messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .background(Color.black.opacity(0.18))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation panel")
    }

    @ViewBuilder
    private func chatMessageRow(_ message: MessagingManager.ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(message.senderName)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.gray)
                Spacer()
            }

            Text(message.content)
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Reply") {
                    selectedMessageId = message.id
                    onReplyToMessage(message)
                }
                .buttonStyle(.borderless)

                if let directMessageAction = onDirectMessageSender(message) {
                    Button("Message Sender", action: directMessageAction)
                        .buttonStyle(.borderless)
                }

                if let profileAction = onViewSenderProfile(message) {
                    Button("View Profile", action: profileAction)
                        .buttonStyle(.borderless)
                }

                if let sendFileAction = onSendFileToSender(message) {
                    Button("Send File", action: sendFileAction)
                        .buttonStyle(.borderless)
                }
            }
            .font(.caption)
        }
        .padding(10)
        .background(selectedMessageId == message.id ? Color.blue.opacity(0.2) : Color.white.opacity(0.06))
        .cornerRadius(8)
        .contextMenu {
            Button("Reply") {
                selectedMessageId = message.id
                onReplyToMessage(message)
            }
            if let directMessageAction = onDirectMessageSender(message) {
                Button("Message Sender", action: directMessageAction)
            }
            if let profileAction = onViewSenderProfile(message) {
                Button("View Profile", action: profileAction)
            }
            if let sendFileAction = onSendFileToSender(message) {
                Button("Send File", action: sendFileAction)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.senderName), \(message.content)")
        .accessibilityHint("Open actions for this message from the context menu.")
    }
}
