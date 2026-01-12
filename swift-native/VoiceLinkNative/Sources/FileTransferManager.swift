import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// File Transfer Manager for VoiceLink
/// Handles file uploads, downloads, and transfers between users
class FileTransferManager: ObservableObject {
    static let shared = FileTransferManager()

    // MARK: - State

    @Published var activeTransfers: [FileTransfer] = []
    @Published var completedTransfers: [FileTransfer] = []
    @Published var failedTransfers: [FileTransfer] = []

    // MARK: - Types

    struct FileTransfer: Identifiable, Equatable {
        let id: String
        let fileName: String
        let fileSize: Int64
        let fileType: String
        let senderId: String
        let senderName: String
        let recipientId: String?       // nil = room transfer
        let recipientName: String?
        var progress: Double           // 0.0 - 1.0
        var status: TransferStatus
        var localURL: URL?
        var remoteURL: String?
        let createdAt: Date
        var completedAt: Date?
        var error: String?

        enum TransferStatus: String {
            case pending
            case uploading
            case downloading
            case paused
            case completed
            case failed
            case cancelled
        }

        var isIncoming: Bool {
            return senderId != FileTransferManager.shared.getCurrentUserId()
        }

        var formattedSize: String {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: fileSize)
        }

        var formattedProgress: String {
            return "\(Int(progress * 100))%"
        }
    }

    // MARK: - Constants

    static let maxFileSize: Int64 = 100 * 1024 * 1024  // 100 MB
    static let allowedFileTypes = [
        "public.image",
        "public.audio",
        "public.movie",
        "public.text",
        "public.pdf",
        "public.archive",
        "public.data"
    ]

    // MARK: - Initialization

    init() {
        setupNotifications()
        loadHistory()
    }

    // MARK: - Sending Files

    /// Send a file to the current room
    func sendFileToRoom(url: URL) {
        sendFile(url: url, recipientId: nil, recipientName: nil)
    }

    /// Send a file to a specific user
    func sendFileToDirect(url: URL, recipientId: String, recipientName: String) {
        sendFile(url: url, recipientId: recipientId, recipientName: recipientName)
    }

    private func sendFile(url: URL, recipientId: String?, recipientName: String?) {
        // Validate file
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? Int64 else {
            showError("Could not read file")
            return
        }

        guard fileSize <= FileTransferManager.maxFileSize else {
            showError("File too large (max \(FileTransferManager.maxFileSize / 1024 / 1024) MB)")
            return
        }

        let transfer = FileTransfer(
            id: UUID().uuidString,
            fileName: url.lastPathComponent,
            fileSize: fileSize,
            fileType: url.pathExtension,
            senderId: getCurrentUserId(),
            senderName: getCurrentUsername(),
            recipientId: recipientId,
            recipientName: recipientName,
            progress: 0,
            status: .pending,
            localURL: url,
            remoteURL: nil,
            createdAt: Date(),
            completedAt: nil,
            error: nil
        )

        activeTransfers.append(transfer)
        startUpload(transfer)
    }

    private func startUpload(_ transfer: FileTransfer) {
        guard let index = activeTransfers.firstIndex(where: { $0.id == transfer.id }) else { return }
        activeTransfers[index].status = .uploading

        // Simulate upload (in production, use URLSession with multipart form data)
        simulateTransfer(transferId: transfer.id, isUpload: true)

        // Play sound
        AppSoundManager.shared.playSound(.buttonClick)

        // Notify server
        NotificationCenter.default.post(
            name: .startFileUpload,
            object: nil,
            userInfo: [
                "transferId": transfer.id,
                "fileName": transfer.fileName,
                "fileSize": transfer.fileSize,
                "recipientId": transfer.recipientId as Any
            ]
        )
    }

    // MARK: - Receiving Files

    /// Handle incoming file transfer notification
    func handleIncomingTransfer(_ data: [String: Any]) {
        guard let transferId = data["transferId"] as? String,
              let fileName = data["fileName"] as? String,
              let fileSize = data["fileSize"] as? Int64,
              let senderId = data["senderId"] as? String,
              let senderName = data["senderName"] as? String else { return }

        let transfer = FileTransfer(
            id: transferId,
            fileName: fileName,
            fileSize: fileSize,
            fileType: (fileName as NSString).pathExtension,
            senderId: senderId,
            senderName: senderName,
            recipientId: getCurrentUserId(),
            recipientName: getCurrentUsername(),
            progress: 0,
            status: .pending,
            localURL: nil,
            remoteURL: data["remoteURL"] as? String,
            createdAt: Date(),
            completedAt: nil,
            error: nil
        )

        activeTransfers.append(transfer)

        // Play incoming sound
        AppSoundManager.shared.playSound(.notification)

        // Show notification
        showIncomingFileNotification(transfer)
    }

    /// Accept and download a file
    func acceptTransfer(_ transferId: String) {
        guard let index = activeTransfers.firstIndex(where: { $0.id == transferId }) else { return }
        activeTransfers[index].status = .downloading

        // Simulate download
        simulateTransfer(transferId: transferId, isUpload: false)
    }

    /// Decline a transfer
    func declineTransfer(_ transferId: String) {
        guard let index = activeTransfers.firstIndex(where: { $0.id == transferId }) else { return }
        var transfer = activeTransfers.remove(at: index)
        transfer.status = .cancelled
        failedTransfers.append(transfer)

        NotificationCenter.default.post(
            name: .declineFileTransfer,
            object: nil,
            userInfo: ["transferId": transferId]
        )
    }

    // MARK: - Transfer Control

    /// Pause a transfer
    func pauseTransfer(_ transferId: String) {
        guard let index = activeTransfers.firstIndex(where: { $0.id == transferId }) else { return }
        activeTransfers[index].status = .paused
    }

    /// Resume a transfer
    func resumeTransfer(_ transferId: String) {
        guard let index = activeTransfers.firstIndex(where: { $0.id == transferId }) else { return }
        let transfer = activeTransfers[index]
        activeTransfers[index].status = transfer.isIncoming ? .downloading : .uploading
        simulateTransfer(transferId: transferId, isUpload: !transfer.isIncoming)
    }

    /// Cancel a transfer
    func cancelTransfer(_ transferId: String) {
        guard let index = activeTransfers.firstIndex(where: { $0.id == transferId }) else { return }
        var transfer = activeTransfers.remove(at: index)
        transfer.status = .cancelled
        failedTransfers.append(transfer)

        NotificationCenter.default.post(
            name: .cancelFileTransfer,
            object: nil,
            userInfo: ["transferId": transferId]
        )
    }

    // MARK: - Progress Simulation

    private func simulateTransfer(transferId: String, isUpload: Bool) {
        // In production, replace with actual URLSession upload/download
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            guard let index = self.activeTransfers.firstIndex(where: { $0.id == transferId }) else {
                timer.invalidate()
                return
            }

            var transfer = self.activeTransfers[index]

            // Check if paused or cancelled
            if transfer.status == .paused || transfer.status == .cancelled {
                timer.invalidate()
                return
            }

            // Update progress
            transfer.progress += 0.05
            if transfer.progress >= 1.0 {
                transfer.progress = 1.0
                transfer.status = .completed
                transfer.completedAt = Date()

                // Move to completed
                self.activeTransfers.remove(at: index)
                self.completedTransfers.insert(transfer, at: 0)

                // Play completion sound
                AppSoundManager.shared.playSound(.fileTransferComplete)

                timer.invalidate()

                // Save history
                self.saveHistory()
            } else {
                self.activeTransfers[index] = transfer
            }
        }
    }

    // MARK: - File Picker

    /// Show file picker for sending
    func showFilePicker(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.data, .image, .audio, .movie, .pdf, .text, .archive]

        panel.begin { response in
            if response == .OK {
                completion(panel.url)
            } else {
                completion(nil)
            }
        }
    }

    /// Save file to downloads
    func saveToDownloads(_ transfer: FileTransfer) {
        guard let sourceURL = transfer.localURL else { return }

        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let destURL = downloadsURL.appendingPathComponent(transfer.fileName)

        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            NSWorkspace.shared.selectFile(destURL.path, inFileViewerRootedAtPath: downloadsURL.path)
        } catch {
            showError("Failed to save file: \(error.localizedDescription)")
        }
    }

    // MARK: - Notifications

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleServerTransferUpdate),
            name: .fileTransferUpdate,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleIncomingTransferNotification),
            name: .incomingFileTransfer,
            object: nil
        )
    }

    @objc private func handleServerTransferUpdate(_ notification: Notification) {
        guard let data = notification.userInfo,
              let transferId = data["transferId"] as? String,
              let progress = data["progress"] as? Double else { return }

        DispatchQueue.main.async {
            if let index = self.activeTransfers.firstIndex(where: { $0.id == transferId }) {
                self.activeTransfers[index].progress = progress
            }
        }
    }

    @objc private func handleIncomingTransferNotification(_ notification: Notification) {
        guard let data = notification.userInfo else { return }
        handleIncomingTransfer(data)
    }

    private func showIncomingFileNotification(_ transfer: FileTransfer) {
        // Post notification for UI
        NotificationCenter.default.post(
            name: .showFileTransferAlert,
            object: nil,
            userInfo: ["transfer": transfer]
        )
    }

    // MARK: - Persistence

    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: "completedTransfers"),
           let decoded = try? JSONDecoder().decode([TransferHistory].self, from: data) {
            completedTransfers = decoded.map { $0.toFileTransfer() }
        }
    }

    private func saveHistory() {
        let history = completedTransfers.prefix(50).map { TransferHistory(from: $0) }
        if let encoded = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(encoded, forKey: "completedTransfers")
        }
    }

    // Simplified transfer for persistence
    struct TransferHistory: Codable {
        let id: String
        let fileName: String
        let fileSize: Int64
        let fileType: String
        let senderName: String
        let recipientName: String?
        let completedAt: Date

        init(from transfer: FileTransfer) {
            self.id = transfer.id
            self.fileName = transfer.fileName
            self.fileSize = transfer.fileSize
            self.fileType = transfer.fileType
            self.senderName = transfer.senderName
            self.recipientName = transfer.recipientName
            self.completedAt = transfer.completedAt ?? Date()
        }

        func toFileTransfer() -> FileTransfer {
            return FileTransfer(
                id: id,
                fileName: fileName,
                fileSize: fileSize,
                fileType: fileType,
                senderId: "",
                senderName: senderName,
                recipientId: nil,
                recipientName: recipientName,
                progress: 1.0,
                status: .completed,
                localURL: nil,
                remoteURL: nil,
                createdAt: completedAt,
                completedAt: completedAt,
                error: nil
            )
        }
    }

    // MARK: - Helpers

    private func getCurrentUserId() -> String {
        return UserDefaults.standard.string(forKey: "clientId") ?? UUID().uuidString
    }

    private func getCurrentUsername() -> String {
        return UserDefaults.standard.string(forKey: "username") ?? "User"
    }

    private func showError(_ message: String) {
        NotificationCenter.default.post(
            name: .fileTransferError,
            object: nil,
            userInfo: ["message": message]
        )
    }

    // MARK: - Cleanup

    func clearHistory() {
        completedTransfers.removeAll()
        failedTransfers.removeAll()
        UserDefaults.standard.removeObject(forKey: "completedTransfers")
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let startFileUpload = Notification.Name("startFileUpload")
    static let fileTransferUpdate = Notification.Name("fileTransferUpdate")
    static let incomingFileTransfer = Notification.Name("incomingFileTransfer")
    static let declineFileTransfer = Notification.Name("declineFileTransfer")
    static let cancelFileTransfer = Notification.Name("cancelFileTransfer")
    static let showFileTransferAlert = Notification.Name("showFileTransferAlert")
    static let fileTransferError = Notification.Name("fileTransferError")
}

// MARK: - SwiftUI Views

/// Transfer row item
struct FileTransferRow: View {
    let transfer: FileTransferManager.FileTransfer
    let onAccept: (() -> Void)?
    let onDecline: (() -> Void)?
    let onCancel: (() -> Void)?
    let onSave: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            // File icon
            Image(systemName: iconForFileType(transfer.fileType))
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                // File name
                Text(transfer.fileName)
                    .font(.headline)
                    .lineLimit(1)

                // Size and sender
                HStack {
                    Text(transfer.formattedSize)
                        .font(.caption)
                        .foregroundColor(.gray)

                    if transfer.isIncoming {
                        Text("from \(transfer.senderName)")
                            .font(.caption)
                            .foregroundColor(.gray)
                    } else if let recipient = transfer.recipientName {
                        Text("to \(recipient)")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }

                // Progress bar
                if transfer.status == .uploading || transfer.status == .downloading {
                    ProgressView(value: transfer.progress)
                        .progressViewStyle(.linear)

                    Text("\(transfer.formattedProgress) - \(transfer.status.rawValue.capitalized)")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }

            Spacer()

            // Actions
            HStack(spacing: 8) {
                switch transfer.status {
                case .pending:
                    if transfer.isIncoming {
                        Button("Accept") { onAccept?() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                        Button("Decline") { onDecline?() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }

                case .uploading, .downloading:
                    Button(action: { onCancel?() }) {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)

                case .completed:
                    if transfer.isIncoming {
                        Button("Save") { onSave?() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }

                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)

                case .failed, .cancelled:
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.red)

                case .paused:
                    Image(systemName: "pause.circle.fill")
                        .foregroundColor(.yellow)
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }

    private func iconForFileType(_ type: String) -> String {
        switch type.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return "photo"
        case "mp3", "wav", "m4a", "aac", "flac": return "music.note"
        case "mp4", "mov", "avi", "mkv": return "film"
        case "pdf": return "doc.richtext"
        case "txt", "md": return "doc.text"
        case "zip", "tar", "gz", "7z": return "archivebox"
        default: return "doc"
        }
    }
}

/// File transfers panel
struct FileTransfersPanel: View {
    @ObservedObject var transferManager = FileTransferManager.shared
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Tabs
            Picker("", selection: $selectedTab) {
                Text("Active (\(transferManager.activeTransfers.count))").tag(0)
                Text("Completed").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()

            // Content
            ScrollView {
                LazyVStack(spacing: 8) {
                    if selectedTab == 0 {
                        if transferManager.activeTransfers.isEmpty {
                            Text("No active transfers")
                                .foregroundColor(.gray)
                                .padding()
                        } else {
                            ForEach(transferManager.activeTransfers) { transfer in
                                FileTransferRow(
                                    transfer: transfer,
                                    onAccept: { transferManager.acceptTransfer(transfer.id) },
                                    onDecline: { transferManager.declineTransfer(transfer.id) },
                                    onCancel: { transferManager.cancelTransfer(transfer.id) },
                                    onSave: nil
                                )
                            }
                        }
                    } else {
                        if transferManager.completedTransfers.isEmpty {
                            Text("No completed transfers")
                                .foregroundColor(.gray)
                                .padding()
                        } else {
                            ForEach(transferManager.completedTransfers) { transfer in
                                FileTransferRow(
                                    transfer: transfer,
                                    onAccept: nil,
                                    onDecline: nil,
                                    onCancel: nil,
                                    onSave: { transferManager.saveToDownloads(transfer) }
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }

            Divider()

            // Send file button
            HStack {
                Button(action: {
                    transferManager.showFilePicker { url in
                        if let url = url {
                            transferManager.sendFileToRoom(url: url)
                        }
                    }
                }) {
                    Label("Send File", systemImage: "paperclip")
                }
                .buttonStyle(.bordered)

                Spacer()

                if !transferManager.completedTransfers.isEmpty {
                    Button("Clear History") {
                        transferManager.clearHistory()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.gray)
                }
            }
            .padding()
        }
    }
}

/// Compact file transfer button for toolbar
struct FileTransferButton: View {
    @ObservedObject var transferManager = FileTransferManager.shared
    @State private var showPanel = false

    var activeCount: Int {
        transferManager.activeTransfers.count
    }

    var body: some View {
        Button(action: { showPanel.toggle() }) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "paperclip")

                if activeCount > 0 {
                    Text("\(activeCount)")
                        .font(.caption2.bold())
                        .foregroundColor(.white)
                        .padding(4)
                        .background(Color.blue)
                        .clipShape(Circle())
                        .offset(x: 8, y: -8)
                }
            }
        }
        .buttonStyle(.plain)
        .help("File Transfers")
        .popover(isPresented: $showPanel) {
            FileTransfersPanel()
                .frame(width: 350, height: 400)
        }
    }
}
