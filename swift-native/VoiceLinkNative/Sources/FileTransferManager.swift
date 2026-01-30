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

    // MARK: - Settings

    struct FileTransferSettings: Codable, Equatable {
        var maxFileSizeGB: Double = 100.0           // 100 GB max (configurable via API)
        var autoAcceptFromContacts: Bool = true     // Auto-accept from known users
        var autoAcceptUnderMB: Int = 10             // Auto-accept files under this size
        var saveLocation: SaveLocation = .downloads
        var askBeforeOverwrite: Bool = true
        var compressImages: Bool = false
        var compressImageQuality: Double = 0.8      // 80% quality
        var allowedFileTypes: [String] = ["*"]      // All types by default
        var blockedFileTypes: [String] = [".exe", ".bat", ".cmd", ".scr"]
        var showNotifications: Bool = true
        var playSound: Bool = true
        var keepHistoryDays: Int = 30

        enum SaveLocation: String, Codable, CaseIterable {
            case downloads = "Downloads"
            case documents = "Documents"
            case desktop = "Desktop"
            case custom = "Custom"
        }

        var maxFileSizeBytes: Int64 {
            return Int64(maxFileSizeGB * 1024 * 1024 * 1024)
        }

        var formattedMaxSize: String {
            if maxFileSizeGB >= 1 {
                return "\(Int(maxFileSizeGB)) GB"
            } else {
                return "\(Int(maxFileSizeGB * 1024)) MB"
            }
        }
    }

    @Published var settings = FileTransferSettings()

    // MARK: - Constants

    static var maxFileSize: Int64 {
        return FileTransferManager.shared.settings.maxFileSizeBytes
    }

    static let defaultAllowedTypes = [
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
        loadSettings()
        setupNotifications()
        loadHistory()
    }

    // MARK: - Settings Management

    func updateSettings(_ newSettings: FileTransferSettings) {
        settings = newSettings
        saveSettings()
    }

    func updateMaxFileSize(gb: Double) {
        settings.maxFileSizeGB = min(100.0, max(0.001, gb)) // 1MB to 100GB
        saveSettings()
    }

    private func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: "fileTransferSettings"),
           let decoded = try? JSONDecoder().decode(FileTransferSettings.self, from: data) {
            settings = decoded
        }
    }

    private func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: "fileTransferSettings")
        }
    }

    func getSettingsForAPI() -> [String: Any] {
        return [
            "maxFileSizeGB": settings.maxFileSizeGB,
            "maxFileSizeBytes": settings.maxFileSizeBytes,
            "autoAcceptFromContacts": settings.autoAcceptFromContacts,
            "autoAcceptUnderMB": settings.autoAcceptUnderMB,
            "saveLocation": settings.saveLocation.rawValue,
            "compressImages": settings.compressImages,
            "blockedFileTypes": settings.blockedFileTypes
        ]
    }

    func applySettingsFromAPI(_ data: [String: Any]) {
        if let maxGB = data["maxFileSizeGB"] as? Double {
            settings.maxFileSizeGB = min(100.0, max(0.001, maxGB))
        }
        if let autoAccept = data["autoAcceptFromContacts"] as? Bool {
            settings.autoAcceptFromContacts = autoAccept
        }
        if let autoAcceptMB = data["autoAcceptUnderMB"] as? Int {
            settings.autoAcceptUnderMB = autoAcceptMB
        }
        if let location = data["saveLocation"] as? String,
           let loc = FileTransferSettings.SaveLocation(rawValue: location) {
            settings.saveLocation = loc
        }
        if let compress = data["compressImages"] as? Bool {
            settings.compressImages = compress
        }
        if let blocked = data["blockedFileTypes"] as? [String] {
            settings.blockedFileTypes = blocked
        }
        saveSettings()
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

        guard fileSize <= settings.maxFileSizeBytes else {
            showError("File too large (max \(settings.formattedMaxSize))")
            return
        }

        // Check for blocked file types
        let fileExt = "." + url.pathExtension.lowercased()
        if settings.blockedFileTypes.contains(fileExt) {
            showError("File type \(fileExt) is blocked")
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
        guard let data = notification.userInfo as? [String: Any] else { return }
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

// MARK: - CopyParty Backend Integration

/// CopyParty file server manager for high-speed transfers
class CopyPartyManager: ObservableObject {
    static let shared = CopyPartyManager()

    @Published var isRunning = false
    @Published var serverURL: String?
    @Published var uploadProgress: Double = 0
    @Published var downloadProgress: Double = 0

    private var copypartyProcess: Process?
    private var port: Int = 3921

    struct CopyPartyConfig: Codable {
        var enabled: Bool = true
        var port: Int = 3921
        var uploadPath: String = "~/Downloads/VoiceLink/uploads"
        var maxUploadSize: Int64 = 100 * 1024 * 1024 * 1024  // 100 GB
        var requireAuth: Bool = true
        var allowAnonymousDownload: Bool = false
    }

    @Published var config = CopyPartyConfig()

    // MARK: - Server Control

    func startServer() {
        guard !isRunning else { return }

        // Create upload directory
        let uploadPath = NSString(string: config.uploadPath).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: uploadPath, withIntermediateDirectories: true)

        // Start copyparty process
        copypartyProcess = Process()
        copypartyProcess?.executableURL = URL(fileURLWithPath: "/usr/local/bin/copyparty")
        copypartyProcess?.arguments = [
            "-p", "\(config.port)",
            "-v", "\(uploadPath):uploads:rwmd",
            "--th-maxage", "0"
        ]

        do {
            try copypartyProcess?.run()
            isRunning = true
            serverURL = "http://localhost:\(config.port)"
            print("[CopyParty] Server started on port \(config.port)")
        } catch {
            print("[CopyParty] Failed to start: \(error)")
        }
    }

    func stopServer() {
        copypartyProcess?.terminate()
        copypartyProcess = nil
        isRunning = false
        serverURL = nil
        print("[CopyParty] Server stopped")
    }

    func restartServer() {
        stopServer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.startServer()
        }
    }

    // MARK: - File Operations

    func uploadFile(url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        guard let serverURL = serverURL else {
            completion(.failure(NSError(domain: "CopyParty", code: -1, userInfo: [NSLocalizedDescriptionKey: "Server not running"])))
            return
        }

        let uploadURL = URL(string: "\(serverURL)/uploads/")!
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Build multipart body
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(url.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)

        if let fileData = try? Data(contentsOf: url) {
            body.append(fileData)
        }
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let task = URLSession.shared.uploadTask(with: request, from: body) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                let downloadURL = "\(serverURL)/uploads/\(url.lastPathComponent)"
                completion(.success(downloadURL))
            } else {
                completion(.failure(NSError(domain: "CopyParty", code: -2, userInfo: [NSLocalizedDescriptionKey: "Upload failed"])))
            }
        }

        // Track progress
        let observation = task.progress.observe(\.fractionCompleted) { progress, _ in
            DispatchQueue.main.async {
                self.uploadProgress = progress.fractionCompleted
            }
        }

        task.resume()
    }

    func downloadFile(from urlString: String, to destination: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: "CopyParty", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
            return
        }

        let task = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let tempURL = tempURL else {
                completion(.failure(NSError(domain: "CopyParty", code: -4, userInfo: [NSLocalizedDescriptionKey: "Download failed"])))
                return
            }

            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tempURL, to: destination)
                completion(.success(destination))
            } catch {
                completion(.failure(error))
            }
        }

        task.resume()
    }

    // MARK: - Pause/Resume/Cancel

    private var activeTasks: [String: URLSessionTask] = [:]

    func pauseTransfer(id: String) {
        activeTasks[id]?.suspend()
    }

    func resumeTransfer(id: String) {
        activeTasks[id]?.resume()
    }

    func cancelTransfer(id: String) {
        activeTasks[id]?.cancel()
        activeTasks.removeValue(forKey: id)
    }
}

// MARK: - File Transfer Settings View

struct FileTransferSettingsView: View {
    @ObservedObject var transferManager = FileTransferManager.shared
    @ObservedObject var copyparty = CopyPartyManager.shared
    @State private var localSettings: FileTransferManager.FileTransferSettings

    init() {
        _localSettings = State(initialValue: FileTransferManager.shared.settings)
    }

    var body: some View {
        Form {
            Section("File Size Limits") {
                HStack {
                    Text("Maximum file size:")
                    Slider(value: $localSettings.maxFileSizeGB, in: 0.01...100, step: 1)
                    Text(localSettings.formattedMaxSize)
                        .frame(width: 60)
                }
                .help("Maximum file size allowed for transfers (up to 100 GB)")

                HStack {
                    Text("Auto-accept under:")
                    Stepper("\(localSettings.autoAcceptUnderMB) MB", value: $localSettings.autoAcceptUnderMB, in: 0...1000, step: 10)
                }
            }

            Section("Auto-Accept") {
                Toggle("Auto-accept from contacts", isOn: $localSettings.autoAcceptFromContacts)
                    .help("Automatically accept file transfers from users you've contacted before")
            }

            Section("Save Location") {
                Picker("Save to:", selection: $localSettings.saveLocation) {
                    ForEach(FileTransferManager.FileTransferSettings.SaveLocation.allCases, id: \.self) { loc in
                        Text(loc.rawValue).tag(loc)
                    }
                }

                Toggle("Ask before overwriting", isOn: $localSettings.askBeforeOverwrite)
            }

            Section("Image Handling") {
                Toggle("Compress images before sending", isOn: $localSettings.compressImages)

                if localSettings.compressImages {
                    HStack {
                        Text("Quality:")
                        Slider(value: $localSettings.compressImageQuality, in: 0.1...1.0, step: 0.1)
                        Text("\(Int(localSettings.compressImageQuality * 100))%")
                            .frame(width: 40)
                    }
                }
            }

            Section("Security") {
                VStack(alignment: .leading) {
                    Text("Blocked file types:")
                        .font(.caption)
                    Text(localSettings.blockedFileTypes.joined(separator: ", "))
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            Section("Notifications") {
                Toggle("Show notifications", isOn: $localSettings.showNotifications)
                Toggle("Play sounds", isOn: $localSettings.playSound)
            }

            Section("CopyParty Server") {
                HStack {
                    Circle()
                        .fill(copyparty.isRunning ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                    Text(copyparty.isRunning ? "Running" : "Stopped")

                    Spacer()

                    if copyparty.isRunning {
                        Button("Stop") { copyparty.stopServer() }
                        Button("Restart") { copyparty.restartServer() }
                    } else {
                        Button("Start") { copyparty.startServer() }
                    }
                }

                if let url = copyparty.serverURL {
                    Text("Server: \(url)")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            Section("History") {
                HStack {
                    Text("Keep history for:")
                    Stepper("\(localSettings.keepHistoryDays) days", value: $localSettings.keepHistoryDays, in: 1...365, step: 7)
                }

                Button("Clear Transfer History") {
                    transferManager.clearHistory()
                }
                .foregroundColor(.red)
            }
        }
        .formStyle(.grouped)
        .onChange(of: localSettings) { newValue in
            transferManager.updateSettings(newValue)
        }
    }
}

// MARK: - Admin File Transfer Settings

struct AdminFileTransferSettingsView: View {
    @State private var serverMaxSizeGB: Double = 100
    @State private var allowGuestUploads = false
    @State private var requireAuth = true
    @State private var enableVirusScan = false

    var body: some View {
        Form {
            Section("Server Limits") {
                HStack {
                    Text("Max upload size (server):")
                    Slider(value: $serverMaxSizeGB, in: 1...100, step: 1)
                    Text("\(Int(serverMaxSizeGB)) GB")
                        .frame(width: 50)
                }
                .help("Maximum file size the server will accept")
            }

            Section("Access Control") {
                Toggle("Require authentication", isOn: $requireAuth)
                Toggle("Allow guest uploads", isOn: $allowGuestUploads)
            }

            Section("Security") {
                Toggle("Enable virus scanning", isOn: $enableVirusScan)
                    .help("Scan uploaded files for malware (requires ClamAV)")
            }

            Section("API Endpoint") {
                Text("POST /api/settings/file-transfer")
                    .font(.caption.monospaced())
                    .foregroundColor(.gray)

                Text("GET /api/settings/file-transfer")
                    .font(.caption.monospaced())
                    .foregroundColor(.gray)
            }
        }
        .formStyle(.grouped)
    }
}
