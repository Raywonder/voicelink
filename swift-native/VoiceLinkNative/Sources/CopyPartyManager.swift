import Foundation
import SwiftUI
import Combine

/// CopyParty Integration Manager for VoiceLink (v1.20.5 compatible)
/// Handles file sharing through CopyParty server and P2P through Headscale network
class CopyPartyManager: ObservableObject {
    static let shared = CopyPartyManager()

    // MARK: - Published State

    @Published var isConnected = false
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var currentUser: CopyPartyUser?
    @Published var availableShares: [CopyPartyShare] = []
    @Published var recentFiles: [CopyPartyFile] = []
    @Published var uploadQueue: [UploadTask] = []
    @Published var downloadQueue: [DownloadTask] = []
    @Published var syncStatus: SyncStatus = .idle
    @Published var headscalePeers: [HeadscalePeer] = []
    @Published var recentProtectedLinks: [ProtectedShareLink] = []
    @Published var config: CopyPartyConfig
    @Published private(set) var connectedServerBaseURL: String = ""

    // MARK: - Configuration

    struct CopyPartyConfig: Codable, Equatable {
        var primaryServer: String = "https://files.tappedin.fm"
        var directAccessIP: String = "64.20.46.178"
        var directAccessPort: Int = 3923
        var alternativeServers: [String] = [
            "https://files.raywonderis.me",
            "https://files.devinecreations.net"
        ]
        var username: String = ""
        var password: String = ""
        var autoSync: Bool = true
        var syncIntervalMinutes: Int = 5
        var maxUploadSizeMB: Int = 2048
        var chunkSizeMB: Int = 10
        var concurrentUploads: Int = 3
        var useHeadscaleP2P: Bool = true
        var backgroundSyncEnabled: Bool = true
        var requireProtectedExternalLinks: Bool = true
        var allowRawExternalLinksFallback: Bool = false
        var defaultExternalLinkExpiryHours: Int = 72
        var externalShareBaseURL: String = "https://voicelink.devinecreations.net"
    }

    // MARK: - Types

    enum ConnectionStatus: String {
        case disconnected = "Disconnected"
        case connecting = "Connecting..."
        case connected = "Connected"
        case error = "Connection Error"
        case headscaleP2P = "P2P Connected"
    }

    enum SyncStatus: String {
        case idle = "Idle"
        case syncing = "Syncing..."
        case uploading = "Uploading..."
        case downloading = "Downloading..."
        case error = "Sync Error"
    }

    struct CopyPartyUser: Codable, Identifiable {
        let id: String
        let username: String
        let accessLevel: String
        var homeDirectory: String?
        var defaultPaths: [String]
    }

    struct CopyPartyShare: Codable, Identifiable {
        let id: String
        let name: String
        let path: String
        let permissions: String
        var fileCount: Int?
        var totalSize: Int64?
    }

    struct CopyPartyFile: Codable, Identifiable {
        let id: String
        let name: String
        let path: String
        let size: Int64
        let mimeType: String
        let modifiedAt: Date
        let isDirectory: Bool
        var thumbnailURL: String?
        var downloadURL: String?

        var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
    }

    struct ProtectedShareLink: Identifiable, Codable {
        let id: String
        let filePath: String
        let url: String
        let token: String?
        let expiresAt: Date?
        let keepForever: Bool
        let createdAt: Date
    }

    enum ShareLinkError: LocalizedError {
        case notConnected
        case invalidPath
        case serverRejected
        case noProtectedEndpoint

        var errorDescription: String? {
            switch self {
            case .notConnected: return "CopyParty is not connected."
            case .invalidPath: return "The file path is invalid."
            case .serverRejected: return "Server rejected protected link generation."
            case .noProtectedEndpoint: return "No protected-link endpoint is available."
            }
        }
    }

    struct UploadTask: Identifiable {
        let id: String
        let localURL: URL
        let remotePath: String
        var progress: Double
        var status: TaskStatus
        var error: String?
        let startedAt: Date
        var completedAt: Date?
    }

    struct DownloadTask: Identifiable {
        let id: String
        let remoteURL: String
        let localURL: URL
        var progress: Double
        var status: TaskStatus
        var error: String?
        let startedAt: Date
        var completedAt: Date?
    }

    enum TaskStatus: String {
        case pending, uploading, downloading, paused, completed, failed, cancelled
    }

    struct HeadscalePeer: Identifiable, Codable {
        let id: String
        let name: String
        let ip: String
        let os: String
        var isOnline: Bool
        var lastSeen: Date?
        var canShareFiles: Bool
    }

    // MARK: - Private Properties

    private var urlSession: URLSession
    private var syncTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    private init() {
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 300
        self.urlSession = URLSession(configuration: sessionConfig)
        self.config = CopyPartyConfig()

        loadConfig()
        setupBackgroundSync()
        checkHeadscaleNetwork()
    }

    // MARK: - Configuration

    func loadConfig() {
        if let data = UserDefaults.standard.data(forKey: "copyPartyConfig"),
           let decoded = try? JSONDecoder().decode(CopyPartyConfig.self, from: data) {
            config = decoded
        }
        migrateLegacyServerDefaults()
    }

    func saveConfig() {
        if let encoded = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(encoded, forKey: "copyPartyConfig")
        }
    }

    private func migrateLegacyServerDefaults() {
        let invalidPrimaryHosts: Set<String> = [
            "https://files.raywonderis.me",
            "https://files.devinecreations.net"
        ]
        let normalizedPrimary = APIEndpointResolver.normalize(config.primaryServer)
        if invalidPrimaryHosts.contains(normalizedPrimary) {
            config.primaryServer = "https://files.tappedin.fm"
            var alternatives = config.alternativeServers.map(APIEndpointResolver.normalize)
            if !alternatives.contains(normalizedPrimary) {
                alternatives.insert(normalizedPrimary, at: 0)
            }
            if !alternatives.contains("https://files.devinecreations.net"), normalizedPrimary != "https://files.devinecreations.net" {
                alternatives.append("https://files.devinecreations.net")
            }
            config.alternativeServers = Array(NSOrderedSet(array: alternatives)) as? [String] ?? alternatives
            saveConfig()
        }
    }

    func updateCredentials(username: String, password: String) {
        config.username = username
        config.password = password
        saveConfig()
        connect()
    }

    // MARK: - Connection

    func connect() {
        connectionStatus = .connecting

        Task {
            // Try primary server first
            if await testConnection(to: config.primaryServer) {
                await MainActor.run {
                    self.isConnected = true
                    self.connectionStatus = .connected
                    self.connectedServerBaseURL = APIEndpointResolver.normalize(self.config.primaryServer)
                }
                await fetchShares()
                return
            }

            // Try direct IP access
            let directURL = "http://\(config.directAccessIP):\(config.directAccessPort)"
            if await testConnection(to: directURL) {
                await MainActor.run {
                    self.isConnected = true
                    self.connectionStatus = .connected
                    self.connectedServerBaseURL = APIEndpointResolver.normalize(directURL)
                }
                await fetchShares()
                return
            }

            // Try alternative servers
            for server in config.alternativeServers {
                if await testConnection(to: server) {
                    await MainActor.run {
                        self.isConnected = true
                        self.connectionStatus = .connected
                        self.connectedServerBaseURL = APIEndpointResolver.normalize(server)
                    }
                    await fetchShares()
                    return
                }
            }

            await MainActor.run {
                self.connectionStatus = .error
                self.connectedServerBaseURL = ""
            }
        }
    }

    private func testConnection(to server: String) async -> Bool {
        guard let url = URL(string: "\(server)/?j") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addAuthHeader(to: &request)

        do {
            let (_, response) = try await urlSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
        } catch {
            print("Connection test failed for \(server): \(error)")
        }
        return false
    }

    func disconnect() {
        isConnected = false
        connectionStatus = .disconnected
        connectedServerBaseURL = ""
        availableShares = []
        currentUser = nil
    }

    // MARK: - File Operations

    func fetchShares() async {
        guard isConnected else { return }

        let serverURL = effectiveServerBaseURL()
        guard let url = URL(string: "\(serverURL)/?j") else { return }

        var request = URLRequest(url: url)
        addAuthHeader(to: &request)

        do {
            let (data, _) = try await urlSession.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let shares = json["vols"] as? [[String: Any]] {
                let parsed = shares.compactMap { dict -> CopyPartyShare? in
                    guard let name = dict["name"] as? String,
                          let path = dict["vpath"] as? String else { return nil }
                    return CopyPartyShare(
                        id: path,
                        name: name,
                        path: path,
                        permissions: dict["flags"] as? String ?? "r"
                    )
                }
                await MainActor.run {
                    self.availableShares = parsed
                }
            }
        } catch {
            print("Failed to fetch shares: \(error)")
        }
    }

    func listFiles(at path: String) async -> [CopyPartyFile] {
        guard isConnected else { return [] }

        let serverURL = effectiveServerBaseURL()
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard let url = URL(string: "\(serverURL)\(encodedPath)?j") else { return [] }

        var request = URLRequest(url: url)
        addAuthHeader(to: &request)

        do {
            let (data, _) = try await urlSession.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let files = json["files"] as? [[String: Any]] {
                return files.compactMap { dict -> CopyPartyFile? in
                    guard let name = dict["name"] as? String else { return nil }
                    let isDir = (dict["ext"] as? String) == "d"
                    let size = dict["sz"] as? Int64 ?? 0
                    let mtime = dict["ts"] as? Double ?? Date().timeIntervalSince1970

                    return CopyPartyFile(
                        id: "\(path)/\(name)",
                        name: name,
                        path: "\(path)/\(name)",
                        size: size,
                        mimeType: dict["mime"] as? String ?? "application/octet-stream",
                        modifiedAt: Date(timeIntervalSince1970: mtime),
                        isDirectory: isDir,
                        thumbnailURL: isDir ? nil : "\(serverURL)\(path)/\(name)?th",
                        downloadURL: isDir ? nil : "\(serverURL)\(path)/\(name)"
                    )
                }
            }
        } catch {
            print("Failed to list files: \(error)")
        }
        return []
    }

    // MARK: - Upload

    func uploadFile(from localURL: URL, to remotePath: String) {
        let task = UploadTask(
            id: UUID().uuidString,
            localURL: localURL,
            remotePath: remotePath,
            progress: 0,
            status: .pending,
            error: nil,
            startedAt: Date(),
            completedAt: nil
        )
        uploadQueue.append(task)
        processUploadQueue()
    }

    func uploadFileAndCreateProtectedLink(
        from localURL: URL,
        to remoteDirectory: String = "/uploads",
        keepForever: Bool = false,
        expiryHours: Int? = nil
    ) async throws -> ProtectedShareLink {
        let safeName = localURL.lastPathComponent.replacingOccurrences(of: "/", with: "_")
        let normalizedDirectory = normalizedRemotePath(remoteDirectory)
        let remoteFilePath = "\(normalizedDirectory)/\(safeName)"
        try await uploadFileNow(from: localURL, to: remoteFilePath)
        return try await createProtectedExternalLink(
            filePath: remoteFilePath,
            keepForever: keepForever,
            expiryHours: expiryHours
        )
    }

    func uploadFilesAndCreateProtectedLink(
        from localURLs: [URL],
        to remoteDirectory: String = "/uploads",
        folderName: String? = nil,
        keepForever: Bool = false,
        expiryHours: Int? = nil
    ) async throws -> ProtectedShareLink {
        let validURLs = localURLs.filter { !$0.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !validURLs.isEmpty else {
            throw NSError(domain: "CopyParty", code: 4, userInfo: [NSLocalizedDescriptionKey: "No files selected"])
        }

        if validURLs.count == 1 {
            return try await uploadFileAndCreateProtectedLink(
                from: validURLs[0],
                to: remoteDirectory,
                keepForever: keepForever,
                expiryHours: expiryHours
            )
        }

        let normalizedDirectory = normalizedRemotePath(remoteDirectory)
        let safeFolderName = sanitizedRemoteComponent(
            folderName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? folderName!
                : "VoiceLink-\(UUID().uuidString.prefix(8))"
        )
        let remoteFolderPath = "\(normalizedDirectory)/\(safeFolderName)"

        for localURL in validURLs {
            let safeName = sanitizedRemoteComponent(localURL.lastPathComponent)
            let remoteFilePath = "\(remoteFolderPath)/\(safeName)"
            try await uploadFileNow(from: localURL, to: remoteFilePath)
        }

        return try await createProtectedExternalLink(
            filePath: remoteFolderPath,
            keepForever: keepForever,
            expiryHours: expiryHours
        )
    }

    private func uploadFileNow(from localURL: URL, to remoteFilePath: String) async throws {
        guard let fileData = try? Data(contentsOf: localURL) else {
            throw NSError(domain: "CopyParty", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read file"])
        }
        let serverURL = effectiveServerBaseURL()
        let encodedPath = remoteFilePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? remoteFilePath
        guard let url = URL(string: "\(serverURL)\(encodedPath)") else {
            throw NSError(domain: "CopyParty", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid upload URL"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        addAuthHeader(to: &request)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = fileData

        let (_, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "CopyParty", code: 3, userInfo: [NSLocalizedDescriptionKey: "Upload failed"])
        }
    }

    private func processUploadQueue() {
        let activeCount = uploadQueue.filter { $0.status == .uploading }.count
        guard activeCount < config.concurrentUploads else { return }

        guard let nextIndex = uploadQueue.firstIndex(where: { $0.status == .pending }) else { return }
        uploadQueue[nextIndex].status = .uploading

        let task = uploadQueue[nextIndex]
        performUpload(task)
    }

    private func performUpload(_ task: UploadTask) {
        Task {
            guard let fileData = try? Data(contentsOf: task.localURL) else {
                await updateUploadStatus(id: task.id, status: .failed, error: "Could not read file")
                return
            }

            let serverURL = effectiveServerBaseURL()
            let encodedPath = task.remotePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? task.remotePath
            guard let url = URL(string: "\(serverURL)\(encodedPath)") else {
                await updateUploadStatus(id: task.id, status: .failed, error: "Invalid URL")
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            addAuthHeader(to: &request)

            let boundary = UUID().uuidString
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(task.localURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(fileData)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

            request.httpBody = body

            do {
                let (_, response) = try await urlSession.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   (200...299).contains(httpResponse.statusCode) {
                    await updateUploadStatus(id: task.id, status: .completed, error: nil)
                } else {
                    await updateUploadStatus(id: task.id, status: .failed, error: "Upload failed")
                }
            } catch {
                await updateUploadStatus(id: task.id, status: .failed, error: error.localizedDescription)
            }

            processUploadQueue()
        }
    }

    @MainActor
    private func updateUploadStatus(id: String, status: TaskStatus, error: String?) {
        if let index = uploadQueue.firstIndex(where: { $0.id == id }) {
            uploadQueue[index].status = status
            uploadQueue[index].error = error
            if status == .completed || status == .failed {
                uploadQueue[index].completedAt = Date()
            }
        }
    }

    // MARK: - Download

    func downloadFile(from remoteURL: String, to localURL: URL) {
        let task = DownloadTask(
            id: UUID().uuidString,
            remoteURL: remoteURL,
            localURL: localURL,
            progress: 0,
            status: .pending,
            error: nil,
            startedAt: Date(),
            completedAt: nil
        )
        downloadQueue.append(task)
        processDownloadQueue()
    }

    private func processDownloadQueue() {
        guard let nextIndex = downloadQueue.firstIndex(where: { $0.status == .pending }) else { return }
        downloadQueue[nextIndex].status = .downloading

        let task = downloadQueue[nextIndex]
        performDownload(task)
    }

    private func performDownload(_ task: DownloadTask) {
        Task {
            guard let url = URL(string: task.remoteURL) else {
                await updateDownloadStatus(id: task.id, status: .failed, error: "Invalid URL")
                return
            }

            var request = URLRequest(url: url)
            addAuthHeader(to: &request)

            do {
                let (data, response) = try await urlSession.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   (200...299).contains(httpResponse.statusCode) {
                    try data.write(to: task.localURL)
                    await updateDownloadStatus(id: task.id, status: .completed, error: nil)
                } else {
                    await updateDownloadStatus(id: task.id, status: .failed, error: "Download failed")
                }
            } catch {
                await updateDownloadStatus(id: task.id, status: .failed, error: error.localizedDescription)
            }

            processDownloadQueue()
        }
    }

    @MainActor
    private func updateDownloadStatus(id: String, status: TaskStatus, error: String?) {
        if let index = downloadQueue.firstIndex(where: { $0.id == id }) {
            downloadQueue[index].status = status
            downloadQueue[index].error = error
            if status == .completed || status == .failed {
                downloadQueue[index].completedAt = Date()
            }
        }
    }

    // MARK: - Headscale P2P

    func checkHeadscaleNetwork() {
        guard config.useHeadscaleP2P else { return }

        Task {
            let tailscaleIPs = ["100.64.", "100.65.", "100.66.", "100.67.", "100.68.", "100.69.", "100.70."]

            var addresses = [String]()
            var ifaddr: UnsafeMutablePointer<ifaddrs>?
            if getifaddrs(&ifaddr) == 0 {
                var ptr = ifaddr
                while ptr != nil {
                    defer { ptr = ptr?.pointee.ifa_next }
                    guard let interface = ptr?.pointee else { continue }
                    let addrFamily = interface.ifa_addr.pointee.sa_family
                    if addrFamily == UInt8(AF_INET) {
                        var addr = interface.ifa_addr.pointee
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(&addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                    &hostname, socklen_t(hostname.count),
                                    nil, 0, NI_NUMERICHOST)
                        addresses.append(String(cString: hostname))
                    }
                }
                freeifaddrs(ifaddr)
            }

            let hasHeadscale = addresses.contains { ip in
                tailscaleIPs.contains { prefix in ip.hasPrefix(prefix) }
            }

            if hasHeadscale {
                await MainActor.run {
                    self.connectionStatus = .headscaleP2P
                }
                await discoverHeadscalePeers()
            }
        }
    }

    private func discoverHeadscalePeers() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/tailscale")
        process.arguments = ["status", "--json"]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let peers = json["Peer"] as? [String: [String: Any]] {
                let peerList = peers.compactMap { (key, value) -> HeadscalePeer? in
                    guard let name = value["HostName"] as? String,
                          let ips = value["TailscaleIPs"] as? [String],
                          let ip = ips.first,
                          let os = value["OS"] as? String else { return nil }
                    let online = value["Online"] as? Bool ?? false
                    return HeadscalePeer(
                        id: key,
                        name: name,
                        ip: ip,
                        os: os,
                        isOnline: online,
                        lastSeen: Date(),
                        canShareFiles: true
                    )
                }
                await MainActor.run {
                    self.headscalePeers = peerList
                }
            }
        } catch {
            print("Failed to get Tailscale status: \(error)")
        }
    }

    func sendFileToPeer(_ peer: HeadscalePeer, fileURL: URL) {
        Task {
            let peerEndpoint = "http://\(peer.ip):3010/api/file-transfer/receive"
            guard let url = URL(string: peerEndpoint) else { return }

            guard let fileData = try? Data(contentsOf: fileURL) else { return }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(fileURL.lastPathComponent, forHTTPHeaderField: "X-Filename")
            request.setValue(getCurrentUserId(), forHTTPHeaderField: "X-Sender-ID")
            request.httpBody = fileData

            do {
                let (_, response) = try await urlSession.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   (200...299).contains(httpResponse.statusCode) {
                    print("P2P transfer to \(peer.name) successful")
                }
            } catch {
                print("P2P transfer error: \(error)")
            }
        }
    }

    // MARK: - Background Sync

    private func setupBackgroundSync() {
        guard config.backgroundSyncEnabled else { return }

        syncTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(config.syncIntervalMinutes * 60), repeats: true) { [weak self] _ in
            self?.performBackgroundSync()
        }
    }

    func performBackgroundSync() {
        guard isConnected, config.autoSync else { return }

        syncStatus = .syncing

        Task {
            let files = await listFiles(at: "/uploads/")
            await MainActor.run {
                self.recentFiles = Array(files.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(50))
                self.syncStatus = .idle
            }
        }
    }

    func stopBackgroundSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    // MARK: - Helpers

    private func addAuthHeader(to request: inout URLRequest) {
        if !config.username.isEmpty {
            let credentials = "\(config.username):\(config.password)"
            if let credData = credentials.data(using: .utf8) {
                let base64 = credData.base64EncodedString()
                request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")
            }
        }
    }

    private func getCurrentUserId() -> String {
        return currentUser?.id ?? UserDefaults.standard.string(forKey: "userId") ?? "unknown"
    }

    private func effectiveServerBaseURL() -> String {
        let connected = APIEndpointResolver.normalize(connectedServerBaseURL)
        if !connected.isEmpty {
            return connected
        }
        return APIEndpointResolver.normalize(config.primaryServer)
    }

    // MARK: - Protected External Share Links

    func createProtectedExternalLink(
        filePath: String,
        keepForever: Bool = false,
        expiryHours: Int? = nil
    ) async throws -> ProtectedShareLink {
        guard isConnected else { throw ShareLinkError.notConnected }
        let normalizedPath = normalizedRemotePath(filePath)
        guard !normalizedPath.isEmpty else { throw ShareLinkError.invalidPath }

        if let protected = try await requestProtectedShareLink(
            filePath: normalizedPath,
            keepForever: keepForever,
            expiryHours: expiryHours
        ) {
            await MainActor.run {
                self.recentProtectedLinks.insert(protected, at: 0)
                self.recentProtectedLinks = Array(self.recentProtectedLinks.prefix(100))
            }
            return protected
        }

        if config.allowRawExternalLinksFallback && !config.requireProtectedExternalLinks {
            let fallback = ProtectedShareLink(
                id: UUID().uuidString,
                filePath: normalizedPath,
                url: rawExternalFileURL(path: normalizedPath),
                token: nil,
                expiresAt: nil,
                keepForever: keepForever,
                createdAt: Date()
            )
            await MainActor.run {
                self.recentProtectedLinks.insert(fallback, at: 0)
                self.recentProtectedLinks = Array(self.recentProtectedLinks.prefix(100))
            }
            return fallback
        }

        if config.requireProtectedExternalLinks {
            throw ShareLinkError.noProtectedEndpoint
        }
        throw ShareLinkError.serverRejected
    }

    private func requestProtectedShareLink(
        filePath: String,
        keepForever: Bool,
        expiryHours: Int?
    ) async throws -> ProtectedShareLink? {
        let expiry = keepForever ? nil : max(1, expiryHours ?? config.defaultExternalLinkExpiryHours)
        let expiresAtISO = expiry.map { Date().addingTimeInterval(TimeInterval($0 * 3600)).iso8601String }
        let apiPaths = [
            "/api/files/share-link",
            "/api/copyparty/share-link",
            "/api/share-link",
            "/api/share/create"
        ]
        let baseCandidates = [
            APIEndpointResolver.normalize(ServerManager.shared.baseURL ?? ""),
            APIEndpointResolver.normalize(config.externalShareBaseURL),
            effectiveServerBaseURL(),
            APIEndpointResolver.normalize(config.primaryServer)
        ].filter { !$0.isEmpty }

        for base in baseCandidates {
            for apiPath in apiPaths {
                guard let url = APIEndpointResolver.url(base: base, path: apiPath) else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                addAuthHeader(to: &request)

                var payload: [String: Any] = [
                    "path": filePath,
                    "requireToken": true,
                    "allowExternal": true,
                    "keepForever": keepForever
                ]
                if let expiresAtISO {
                    payload["expiresAt"] = expiresAtISO
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)

                do {
                    let (data, response) = try await urlSession.data(for: request)
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        continue
                    }
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        continue
                    }
                    let finalURL =
                        (json["url"] as? String) ??
                        (json["link"] as? String) ??
                        (json["downloadUrl"] as? String) ??
                        (json["download_url"] as? String)
                    guard let finalURL, !finalURL.isEmpty else { continue }
                    let token = json["token"] as? String
                    let parsedExpiry = parseExpiry(from: json) ?? expiry.map { Date().addingTimeInterval(TimeInterval($0 * 3600)) }

                    return ProtectedShareLink(
                        id: UUID().uuidString,
                        filePath: filePath,
                        url: finalURL,
                        token: token,
                        expiresAt: parsedExpiry,
                        keepForever: keepForever,
                        createdAt: Date()
                    )
                } catch {
                    continue
                }
            }
        }
        return nil
    }

    private func normalizedRemotePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    private func sanitizedRemoteComponent(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let cleaned = replaced.isEmpty ? "item" : replaced
        return cleaned
    }

    private func rawExternalFileURL(path: String) -> String {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "\(effectiveServerBaseURL())\(encodedPath)"
    }

    private func parseExpiry(from payload: [String: Any]) -> Date? {
        if let raw = payload["expiresAt"] as? String ?? payload["expires_at"] as? String {
            return ISO8601DateFormatter().date(from: raw)
        }
        if let unix = payload["expiresAtUnix"] as? Double ?? payload["expires_at_unix"] as? Double {
            return Date(timeIntervalSince1970: unix)
        }
        return nil
    }
}

private extension Date {
    var iso8601String: String {
        ISO8601DateFormatter().string(from: self)
    }
}

// MARK: - CopyParty Settings View

struct CopyPartySettingsView: View {
    @ObservedObject private var manager = CopyPartyManager.shared
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false

    var body: some View {
        Form {
            Section("Connection") {
                HStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    Text(manager.connectionStatus.rawValue)
                }

                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    if showPassword {
                        TextField("Password", text: $password)
                    } else {
                        SecureField("Password", text: $password)
                    }
                    Button(action: { showPassword.toggle() }) {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
                .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Connect") {
                        manager.updateCredentials(username: username, password: password)
                    }
                    .disabled(username.isEmpty)

                    Button("Disconnect") {
                        manager.disconnect()
                    }
                    .disabled(!manager.isConnected)
                }
            }

            Section("Sync Settings") {
                Toggle("Auto Sync", isOn: Binding(
                    get: { manager.config.autoSync },
                    set: { manager.config.autoSync = $0; manager.saveConfig() }
                ))
                Toggle("Background Sync", isOn: Binding(
                    get: { manager.config.backgroundSyncEnabled },
                    set: { manager.config.backgroundSyncEnabled = $0; manager.saveConfig() }
                ))
                Toggle("Use P2P over Headscale", isOn: Binding(
                    get: { manager.config.useHeadscaleP2P },
                    set: { manager.config.useHeadscaleP2P = $0; manager.saveConfig() }
                ))

                Stepper("Sync Interval: \(manager.config.syncIntervalMinutes) min",
                        value: Binding(
                            get: { manager.config.syncIntervalMinutes },
                            set: { manager.config.syncIntervalMinutes = $0; manager.saveConfig() }
                        ), in: 1...60)
            }

            if !manager.headscalePeers.isEmpty {
                Section("Headscale Peers") {
                    ForEach(manager.headscalePeers) { peer in
                        HStack {
                            Circle()
                                .fill(peer.isOnline ? Color.green : Color.gray)
                                .frame(width: 8, height: 8)
                            Text(peer.name)
                            Spacer()
                            Text(peer.os)
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                }
            }

            if !manager.availableShares.isEmpty {
                Section("Available Shares") {
                    ForEach(manager.availableShares) { share in
                        HStack {
                            Image(systemName: "folder.fill")
                            Text(share.name)
                            Spacer()
                            Text(share.permissions)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
        .onAppear {
            username = manager.config.username
            password = manager.config.password
        }
    }

    private var statusColor: Color {
        switch manager.connectionStatus {
        case .connected, .headscaleP2P: return .green
        case .connecting: return .yellow
        case .error: return .red
        case .disconnected: return .gray
        }
    }
}

// MARK: - File Browser View

struct CopyPartyFileBrowserView: View {
    @ObservedObject private var manager = CopyPartyManager.shared
    @State private var currentPath = "/"
    @State private var files: [CopyPartyManager.CopyPartyFile] = []
    @State private var isLoading = false

    var body: some View {
        VStack {
            HStack {
                Button(action: goUp) {
                    Image(systemName: "chevron.left")
                }
                .disabled(currentPath == "/")

                Text(currentPath)
                    .font(.headline)

                Spacer()

                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .padding()

            if isLoading {
                ProgressView("Loading...")
            } else if files.isEmpty {
                Text("No files")
                    .foregroundColor(.secondary)
            } else {
                List(files) { file in
                    HStack {
                        Image(systemName: file.isDirectory ? "folder.fill" : "doc.fill")
                            .foregroundColor(file.isDirectory ? .blue : .gray)
                        VStack(alignment: .leading) {
                            Text(file.name)
                            Text(file.formattedSize)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .onTapGesture {
                        if file.isDirectory {
                            navigateTo(file.path)
                        }
                    }
                }
            }
        }
        .onAppear {
            refresh()
        }
    }

    private func refresh() {
        isLoading = true
        Task {
            let result = await manager.listFiles(at: currentPath)
            await MainActor.run {
                files = result
                isLoading = false
            }
        }
    }

    private func navigateTo(_ path: String) {
        currentPath = path
        refresh()
    }

    private func goUp() {
        let components = currentPath.split(separator: "/")
        if components.count > 1 {
            currentPath = "/" + components.dropLast().joined(separator: "/")
        } else {
            currentPath = "/"
        }
        refresh()
    }
}
