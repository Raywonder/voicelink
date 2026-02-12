import SwiftUI
import AVFoundation
import AVKit
import AppKit
import Combine

// MARK: - Jellyfin Server Configuration
struct JellyfinServer: Identifiable, Codable {
    let id: String
    var name: String
    var url: String
    var username: String
    var userId: String?
    var accessToken: String?
    var addedAt: Date
    var lastConnected: Date?
    var isActive: Bool

    init(id: String = UUID().uuidString, name: String, url: String, username: String) {
        self.id = id
        self.name = name
        self.url = url
        self.username = username
        self.addedAt = Date()
        self.isActive = false
    }
}

// MARK: - Media Library
struct MediaLibrary: Identifiable, Codable {
    let id: String
    let name: String
    let collectionType: String?
    let imageId: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case collectionType = "CollectionType"
        case imageId = "ImageTags"
    }

    var isAudioLibrary: Bool {
        return collectionType == "music" || collectionType == "audiobooks" || collectionType == "playlists"
    }

    var icon: String {
        switch collectionType {
        case "music": return "music.note.list"
        case "audiobooks": return "book.fill"
        case "playlists": return "music.note.list"
        default: return "folder.fill"
        }
    }
}

// MARK: - Media Item
struct MediaItem: Identifiable, Codable {
    let id: String
    let name: String
    let type: String
    let parentId: String?
    let albumArtist: String?
    let album: String?
    let artists: [String]?
    let runTimeTicks: Int64?
    let indexNumber: Int?
    let container: String?
    let primaryImageTag: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case parentId = "ParentId"
        case albumArtist = "AlbumArtist"
        case album = "Album"
        case artists = "Artists"
        case runTimeTicks = "RunTimeTicks"
        case indexNumber = "IndexNumber"
        case container = "Container"
        case primaryImageTag = "PrimaryImageItemId"
    }

    var duration: TimeInterval {
        guard let ticks = runTimeTicks else { return 0 }
        return TimeInterval(ticks) / 10_000_000
    }

    var displayDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var artistString: String {
        return artists?.joined(separator: ", ") ?? albumArtist ?? "Unknown Artist"
    }

    var isVideo: Bool {
        let normalized = type.lowercased()
        return normalized == "movie" || normalized == "episode" || normalized == "video"
    }
}

// MARK: - Browse Result
struct BrowseResult: Codable {
    let items: [MediaItem]
    let totalRecordCount: Int
    let startIndex: Int

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
        case startIndex = "StartIndex"
    }
}

// MARK: - Auth Response
struct AuthResponse: Codable {
    let user: UserInfo
    let accessToken: String
    let serverId: String

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
        case serverId = "ServerId"
    }

    struct UserInfo: Codable {
        let id: String
        let name: String

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case name = "Name"
        }
    }
}

// MARK: - Libraries Response
struct LibrariesResponse: Codable {
    let items: [MediaLibrary]

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

// MARK: - Playback Session
class PlaybackSession: ObservableObject {
    let id: String
    let serverId: String
    let mediaItem: MediaItem

    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var volume: Float = 0.7

    var audioPlayer: AVPlayer?
    var playerItem: AVPlayerItem?
    var timeObserver: Any?

    var isAmbient: Bool = false
    var roomId: String?

    init(id: String = UUID().uuidString, serverId: String, mediaItem: MediaItem) {
        self.id = id
        self.serverId = serverId
        self.mediaItem = mediaItem
        self.duration = mediaItem.duration
    }

    deinit {
        if let observer = timeObserver, let player = audioPlayer {
            player.removeTimeObserver(observer)
        }
    }
}

// MARK: - Ambient Settings
struct AmbientSettings {
    var enabled: Bool = true
    var volume: Float = 0.3
    var fadeInDuration: TimeInterval = 2.0
    var fadeOutDuration: TimeInterval = 1.5
    var shuffle: Bool = true
    var isPaused: Bool = false
    var stoppedByAdmin: Bool = false
    var stoppedByUser: Bool = false
}

// MARK: - Jellyfin Manager
class JellyfinManager: ObservableObject {
    static let shared = JellyfinManager()

    // Servers
    @Published var servers: [JellyfinServer] = []
    @Published var activeConnection: JellyfinServer?

    // Libraries
    @Published var libraries: [String: [MediaLibrary]] = [:]
    @Published var currentLibraryItems: [MediaItem] = []

    // Playback
    @Published var currentSession: PlaybackSession?
    @Published var playbackQueue: [MediaItem] = []
    @Published var currentPlaybackIndex: Int = 0

    // Ambient
    @Published var ambientSettings = AmbientSettings()

    // State
    @Published var isConnecting: Bool = false
    @Published var isBrowsing: Bool = false
    @Published var connectionError: String?

    // Admin mode
    @Published var isAdminMode: Bool = false

    // Device ID
    private var deviceId: String
    private var videoWindow: NSWindow?
    private var videoPlayerView: AVPlayerView?

    // API Endpoints
    private let apiEndpoints = APIEndpoints()

    struct APIEndpoints {
        let auth = "/Users/authenticatebyname"
        let userInfo = "/Users/{userId}"
        let libraries = "/UserViews"
        let items = "/Users/{userId}/Items"
        let playbackInfo = "/Items/{itemId}/PlaybackInfo"
        let mediaStream = "/Audio/{itemId}/stream"
        let videoStream = "/Videos/{itemId}/stream"
        let imageApi = "/Items/{itemId}/Images/Primary"
    }

    // Supported formats
    let supportedFormats = ["mp3", "flac", "ogg", "wav", "aac", "m4a", "opus"]

    init() {
        // Get or create device ID
        if let savedDeviceId = UserDefaults.standard.string(forKey: "jellyfin.deviceId") {
            deviceId = savedDeviceId
        } else {
            deviceId = "voicelink_\(UUID().uuidString)"
            UserDefaults.standard.set(deviceId, forKey: "jellyfin.deviceId")
        }

        loadServerConfigurations()
    }

    // MARK: - Server Management

    func addServer(name: String, url: String, username: String, password: String) async throws -> JellyfinServer {
        let serverUrl = normalizeServerUrl(url)

        // Authenticate
        let authResult = try await authenticateUser(serverUrl: serverUrl, username: username, password: password)

        var server = JellyfinServer(name: name, url: serverUrl, username: username)
        server.userId = authResult.user.id
        server.accessToken = authResult.accessToken
        server.lastConnected = Date()
        server.isActive = false

        await MainActor.run {
            servers.append(server)
            saveServerConfigurations()
        }

        print("Jellyfin server '\(name)' added successfully")
        return server
    }

    func removeServer(id: String) {
        servers.removeAll { $0.id == id }
        libraries.removeValue(forKey: id)

        if activeConnection?.id == id {
            disconnect()
        }

        saveServerConfigurations()
    }

    // MARK: - Authentication

    private func authenticateUser(serverUrl: String, username: String, password: String) async throws -> AuthResponse {
        let authUrl = URL(string: "\(serverUrl)\(apiEndpoints.auth)")!

        var request = URLRequest(url: authUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(buildAuthHeader(), forHTTPHeaderField: "X-Emby-Authorization")

        let payload: [String: String] = [
            "Username": username,
            "Pw": password
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw JellyfinError.authenticationFailed
        }

        return try JSONDecoder().decode(AuthResponse.self, from: data)
    }

    // MARK: - Connection

    func connectToServer(_ server: JellyfinServer) async throws {
        await MainActor.run {
            isConnecting = true
            connectionError = nil
        }

        guard let token = server.accessToken, let userId = server.userId else {
            await MainActor.run { isConnecting = false }
            throw JellyfinError.noCredentials
        }

        do {
            // Test connection
            let userUrl = "\(server.url)\(apiEndpoints.userInfo.replacingOccurrences(of: "{userId}", with: userId))"
            _ = try await fetchWithAuth(url: userUrl, token: token)

            // Load libraries
            let loadedLibraries = try await loadMediaLibraries(server: server)

            await MainActor.run {
                if let index = servers.firstIndex(where: { $0.id == server.id }) {
                    servers[index].isActive = true
                    servers[index].lastConnected = Date()
                }
                activeConnection = server
                libraries[server.id] = loadedLibraries
                isConnecting = false
            }

            print("Connected to Jellyfin server: \(server.name)")

        } catch {
            await MainActor.run {
                isConnecting = false
                connectionError = error.localizedDescription
            }
            throw error
        }
    }

    func disconnect() {
        // Stop playback
        stopPlayback()

        // Clear active connection
        if let active = activeConnection {
            if let index = servers.firstIndex(where: { $0.id == active.id }) {
                servers[index].isActive = false
            }
        }

        activeConnection = nil
        currentLibraryItems = []
    }

    // MARK: - Library Browsing

    private func loadMediaLibraries(server: JellyfinServer) async throws -> [MediaLibrary] {
        guard let token = server.accessToken else {
            throw JellyfinError.noCredentials
        }

        let librariesUrl = "\(server.url)\(apiEndpoints.libraries)"
        let data = try await fetchWithAuth(url: librariesUrl, token: token)

        let response = try JSONDecoder().decode(LibrariesResponse.self, from: data)

        // Filter to audio libraries unless admin mode
        if isAdminMode {
            return response.items
        } else {
            return response.items.filter { $0.isAudioLibrary }
        }
    }

    func browseLibrary(libraryId: String, options: BrowseOptions = BrowseOptions()) async throws -> BrowseResult {
        guard let server = activeConnection,
              let token = server.accessToken,
              let userId = server.userId else {
            throw JellyfinError.notConnected
        }

        await MainActor.run { isBrowsing = true }

        var components = URLComponents(string: "\(server.url)\(apiEndpoints.items.replacingOccurrences(of: "{userId}", with: userId))")!

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "parentId", value: libraryId),
            URLQueryItem(name: "includeItemTypes", value: "Audio"),
            URLQueryItem(name: "fields", value: "PrimaryImageAspectRatio,MediaSourceCount,DateCreated"),
            URLQueryItem(name: "startIndex", value: "\(options.startIndex)"),
            URLQueryItem(name: "limit", value: "\(options.limit)"),
            URLQueryItem(name: "sortBy", value: options.sortBy),
            URLQueryItem(name: "sortOrder", value: options.sortOrder)
        ]

        if let searchTerm = options.searchTerm {
            queryItems.append(URLQueryItem(name: "searchTerm", value: searchTerm))
        }

        components.queryItems = queryItems

        let data = try await fetchWithAuth(url: components.url!.absoluteString, token: token)

        await MainActor.run { isBrowsing = false }

        let result = try JSONDecoder().decode(BrowseResult.self, from: data)

        await MainActor.run {
            currentLibraryItems = result.items
        }

        return result
    }

    // MARK: - Playback

    func getStreamUrl(itemId: String) -> URL? {
        guard let server = activeConnection,
              let token = server.accessToken,
              let userId = server.userId else { return nil }

        var components = URLComponents(string: "\(server.url)\(apiEndpoints.mediaStream.replacingOccurrences(of: "{itemId}", with: itemId))")!

        components.queryItems = [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "deviceId", value: deviceId),
            URLQueryItem(name: "api_key", value: token),
            URLQueryItem(name: "container", value: "mp3,flac,ogg"),
            URLQueryItem(name: "audioCodec", value: "mp3,flac,opus"),
            URLQueryItem(name: "audioBitRate", value: "320000"),
            URLQueryItem(name: "audioSampleRate", value: "48000")
        ]

        return components.url
    }

    func getVideoStreamUrl(itemId: String) -> URL? {
        guard let server = activeConnection,
              let token = server.accessToken,
              let userId = server.userId else { return nil }

        var components = URLComponents(string: "\(server.url)\(apiEndpoints.videoStream.replacingOccurrences(of: "{itemId}", with: itemId))")!
        components.queryItems = [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "deviceId", value: deviceId),
            URLQueryItem(name: "api_key", value: token),
            URLQueryItem(name: "Static", value: "true")
        ]
        return components.url
    }

    func playMedia(_ item: MediaItem) async throws {
        guard let server = activeConnection else {
            throw JellyfinError.notConnected
        }

        let resolvedStreamUrl: URL?
        if item.isVideo {
            resolvedStreamUrl = getVideoStreamUrl(itemId: item.id) ?? getStreamUrl(itemId: item.id)
        } else {
            resolvedStreamUrl = getStreamUrl(itemId: item.id)
        }

        guard let streamUrl = resolvedStreamUrl else {
            throw JellyfinError.invalidStreamUrl
        }

        // Stop current playback
        stopPlayback()

        // Create new session
        let session = PlaybackSession(serverId: server.id, mediaItem: item)

        // Create player
        let playerItem = AVPlayerItem(url: streamUrl)
        let player = AVPlayer(playerItem: playerItem)

        session.audioPlayer = player
        session.playerItem = playerItem

        // Add time observer
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        session.timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak session] time in
            session?.currentTime = time.seconds
        }

        // Observe playback state
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { [weak self] _ in
            self?.playNextInQueue()
        }

        await MainActor.run {
            currentSession = session
            session.isPlaying = true
        }

        player.volume = session.volume
        player.play()

        print("Playing: \(item.name)")
    }

    func isCurrentMediaVideo() -> Bool {
        currentSession?.mediaItem.isVideo == true
    }

    @MainActor
    func showVideoWindow() {
        guard let session = currentSession,
              session.mediaItem.isVideo,
              let player = session.audioPlayer else {
            return
        }

        if let existingWindow = videoWindow {
            if let playerView = videoPlayerView {
                playerView.player = player
            }
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let playerView = AVPlayerView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
        playerView.controlsStyle = .floating
        playerView.player = player
        playerView.showsFullScreenToggleButton = true

        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = session.mediaItem.name
        window.contentView = playerView
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        videoPlayerView = playerView
        videoWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    func minimizeVideoWindow() {
        videoWindow?.miniaturize(nil)
    }

    @MainActor
    func toggleVideoFullscreen() {
        guard let window = videoWindow else {
            showVideoWindow()
            videoWindow?.toggleFullScreen(nil)
            return
        }
        window.toggleFullScreen(nil)
    }

    func pausePlayback() {
        guard let session = currentSession else { return }
        session.audioPlayer?.pause()
        session.isPlaying = false
    }

    func resumePlayback() {
        guard let session = currentSession else { return }
        session.audioPlayer?.play()
        session.isPlaying = true
    }

    func stopPlayback() {
        guard let session = currentSession else { return }

        session.audioPlayer?.pause()

        if let observer = session.timeObserver, let player = session.audioPlayer {
            player.removeTimeObserver(observer)
        }

        currentSession = nil
    }

    func seek(to time: TimeInterval) {
        guard let session = currentSession else { return }
        let cmTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        session.audioPlayer?.seek(to: cmTime)
    }

    func setVolume(_ volume: Float) {
        guard let session = currentSession else { return }
        session.audioPlayer?.volume = volume
        session.volume = volume
    }

    // MARK: - Queue Management

    func addToQueue(_ items: [MediaItem]) {
        playbackQueue.append(contentsOf: items)
    }

    func clearQueue() {
        playbackQueue.removeAll()
        currentPlaybackIndex = 0
    }

    func playNextInQueue() {
        guard !playbackQueue.isEmpty else { return }

        currentPlaybackIndex += 1
        if currentPlaybackIndex >= playbackQueue.count {
            currentPlaybackIndex = 0
        }

        Task {
            try? await playMedia(playbackQueue[currentPlaybackIndex])
        }
    }

    func playPreviousInQueue() {
        guard !playbackQueue.isEmpty else { return }

        currentPlaybackIndex -= 1
        if currentPlaybackIndex < 0 {
            currentPlaybackIndex = playbackQueue.count - 1
        }

        Task {
            try? await playMedia(playbackQueue[currentPlaybackIndex])
        }
    }

    // MARK: - Ambient Music

    func startAmbientMusic(roomId: String, libraryId: String? = nil) async {
        guard ambientSettings.enabled else {
            print("[Jellyfin] Ambient music disabled")
            return
        }

        guard currentSession == nil || ambientSettings.isPaused else {
            print("[Jellyfin] Music already playing")
            return
        }

        guard !ambientSettings.stoppedByAdmin else {
            print("[Jellyfin] Ambient music stopped by admin")
            return
        }

        do {
            let tracks = await getAmbientTracks(libraryId: libraryId)

            guard !tracks.isEmpty else {
                print("[Jellyfin] No ambient tracks found")
                return
            }

            let track: MediaItem
            if ambientSettings.shuffle {
                track = tracks.randomElement()!
            } else {
                track = tracks[0]
            }

            print("[Jellyfin] Starting ambient music: \(track.name)")

            try await playMedia(track)

            currentSession?.isAmbient = true
            currentSession?.roomId = roomId

            // Apply initial volume fade
            currentSession?.volume = 0
            fadeVolume(to: ambientSettings.volume, duration: ambientSettings.fadeInDuration)

        } catch {
            print("[Jellyfin] Failed to start ambient music: \(error)")
        }
    }

    func stopAmbientMusic(reason: String = "user") {
        guard let session = currentSession, session.isAmbient else { return }

        print("[Jellyfin] Stopping ambient music, reason: \(reason)")

        switch reason {
        case "admin":
            ambientSettings.stoppedByAdmin = true
        case "user":
            ambientSettings.stoppedByUser = true
        default:
            break
        }

        fadeVolume(to: 0, duration: ambientSettings.fadeOutDuration) { [weak self] in
            self?.stopPlayback()
        }
    }

    func pauseAmbientForPlayback() {
        guard let session = currentSession, session.isAmbient else { return }
        ambientSettings.isPaused = true
        fadeVolume(to: 0.05, duration: 1.0)
    }

    func resumeAmbientMusic() {
        guard let session = currentSession, session.isAmbient else { return }
        guard !ambientSettings.stoppedByAdmin && !ambientSettings.stoppedByUser else { return }

        ambientSettings.isPaused = false
        fadeVolume(to: ambientSettings.volume, duration: 1.0)
    }

    private func getAmbientTracks(libraryId: String? = nil) async -> [MediaItem] {
        guard activeConnection != nil else { return [] }

        do {
            if let libraryId = libraryId {
                let result = try await browseLibrary(libraryId: libraryId, options: BrowseOptions(limit: 100, sortBy: "Random"))
                return result.items
            }

            // Get from first music library
            if let serverId = activeConnection?.id,
               let libs = libraries[serverId],
               let musicLib = libs.first(where: { $0.collectionType == "music" }) {
                let result = try await browseLibrary(libraryId: musicLib.id, options: BrowseOptions(limit: 50, sortBy: "Random"))
                return result.items
            }

            return []
        } catch {
            print("[Jellyfin] Failed to get ambient tracks: \(error)")
            return []
        }
    }

    func setAmbientEnabled(_ enabled: Bool) {
        ambientSettings.enabled = enabled
        if !enabled {
            stopAmbientMusic(reason: "admin")
        }
    }

    func resetAmbientMusic() {
        ambientSettings.stoppedByAdmin = false
        ambientSettings.stoppedByUser = false
        ambientSettings.isPaused = false
    }

    // MARK: - Volume Fade

    private func fadeVolume(to targetVolume: Float, duration: TimeInterval, completion: (() -> Void)? = nil) {
        guard let session = currentSession, let player = session.audioPlayer else {
            completion?()
            return
        }

        let startVolume = player.volume
        let steps = 20
        let stepDuration = duration / Double(steps)
        let volumeStep = (targetVolume - startVolume) / Float(steps)

        var currentStep = 0

        Timer.scheduledTimer(withTimeInterval: stepDuration, repeats: true) { [weak self] timer in
            currentStep += 1
            let newVolume = startVolume + volumeStep * Float(currentStep)
            player.volume = newVolume
            self?.currentSession?.volume = newVolume

            if currentStep >= steps {
                timer.invalidate()
                completion?()
            }
        }
    }

    // MARK: - Image URL

    func getImageUrl(itemId: String, width: Int = 300) -> URL? {
        guard let server = activeConnection, let token = server.accessToken else { return nil }

        var components = URLComponents(string: "\(server.url)\(apiEndpoints.imageApi.replacingOccurrences(of: "{itemId}", with: itemId))")!
        components.queryItems = [
            URLQueryItem(name: "maxWidth", value: "\(width)"),
            URLQueryItem(name: "api_key", value: token)
        ]
        return components.url
    }

    // MARK: - Helpers

    private func normalizeServerUrl(_ url: String) -> String {
        var normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove trailing slash
        if normalized.hasSuffix("/") {
            normalized = String(normalized.dropLast())
        }

        // Ensure protocol
        if !normalized.hasPrefix("http://") && !normalized.hasPrefix("https://") {
            normalized = "https://\(normalized)"
        }

        return normalized
    }

    private func buildAuthHeader() -> String {
        return "MediaBrowser Client=\"VoiceLink\", Device=\"macOS\", DeviceId=\"\(deviceId)\", Version=\"1.0.0\""
    }

    private func fetchWithAuth(url: String, token: String) async throws -> Data {
        guard let requestUrl = URL(string: url) else {
            throw JellyfinError.invalidUrl
        }

        var request = URLRequest(url: requestUrl)
        request.setValue(buildAuthHeader(), forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw JellyfinError.requestFailed
        }

        return data
    }

    // MARK: - Persistence

    private func saveServerConfigurations() {
        // Don't save tokens in UserDefaults (use Keychain in production)
        var savedServers: [[String: Any]] = []
        for server in servers {
            savedServers.append([
                "id": server.id,
                "name": server.name,
                "url": server.url,
                "username": server.username,
                "userId": server.userId ?? "",
                "accessToken": server.accessToken ?? "", // In production, store in Keychain
                "addedAt": server.addedAt.timeIntervalSince1970
            ])
        }

        if let data = try? JSONSerialization.data(withJSONObject: savedServers) {
            UserDefaults.standard.set(data, forKey: "jellyfin.servers")
        }
    }

    private func loadServerConfigurations() {
        guard let data = UserDefaults.standard.data(forKey: "jellyfin.servers"),
              let savedServers = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return
        }

        servers = savedServers.compactMap { dict -> JellyfinServer? in
            guard let id = dict["id"] as? String,
                  let name = dict["name"] as? String,
                  let url = dict["url"] as? String,
                  let username = dict["username"] as? String else {
                return nil
            }

            var server = JellyfinServer(id: id, name: name, url: url, username: username)
            server.userId = dict["userId"] as? String
            server.accessToken = dict["accessToken"] as? String

            if let addedAt = dict["addedAt"] as? TimeInterval {
                server.addedAt = Date(timeIntervalSince1970: addedAt)
            }

            return server
        }
    }
}

// MARK: - Browse Options
struct BrowseOptions {
    var startIndex: Int = 0
    var limit: Int = 100
    var sortBy: String = "SortName"
    var sortOrder: String = "Ascending"
    var searchTerm: String?
}

// MARK: - Errors
enum JellyfinError: LocalizedError {
    case authenticationFailed
    case noCredentials
    case notConnected
    case invalidUrl
    case invalidStreamUrl
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .authenticationFailed: return "Authentication failed"
        case .noCredentials: return "No credentials available"
        case .notConnected: return "Not connected to server"
        case .invalidUrl: return "Invalid URL"
        case .invalidStreamUrl: return "Could not generate stream URL"
        case .requestFailed: return "Request failed"
        }
    }
}

// MARK: - Jellyfin View
struct JellyfinView: View {
    @ObservedObject var manager = JellyfinManager.shared
    @State private var showAddServer = false
    @State private var selectedLibrary: MediaLibrary?

    var body: some View {
        NavigationSplitView {
            // Sidebar - Servers and Libraries
            List {
                Section("Servers") {
                    ForEach(manager.servers) { server in
                        ServerRowView(server: server, selectedLibrary: $selectedLibrary)
                    }

                    Button(action: { showAddServer = true }) {
                        Label("Add Server", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("Jellyfin")
        } detail: {
            // Content area
            if let library = selectedLibrary {
                LibraryContentView(library: library)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "play.tv")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    Text("Select a Library")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .sheet(isPresented: $showAddServer) {
            AddJellyfinServerView()
        }
        .toolbar {
            if let session = manager.currentSession {
                ToolbarItem(placement: .navigation) {
                    NowPlayingMiniView(session: session)
                }
            }
        }
    }
}

// MARK: - Server Row View
struct ServerRowView: View {
    let server: JellyfinServer
    @Binding var selectedLibrary: MediaLibrary?
    @ObservedObject var manager = JellyfinManager.shared

    var serverLibraries: [MediaLibrary] {
        manager.libraries[server.id] ?? []
    }

    var body: some View {
        DisclosureGroup {
            if server.isActive {
                ForEach(serverLibraries) { library in
                    Button(action: { selectedLibrary = library }) {
                        Label(library.name, systemImage: library.icon)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(selectedLibrary?.id == library.id ? .accentColor : .primary)
                }
            } else {
                Button("Connect") {
                    Task {
                        try? await manager.connectToServer(server)
                    }
                }
            }
        } label: {
            HStack {
                Circle()
                    .fill(server.isActive ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(server.name)
            }
        }
    }
}

// MARK: - Library Content View
struct LibraryContentView: View {
    let library: MediaLibrary
    @ObservedObject var manager = JellyfinManager.shared
    @State private var searchText = ""

    var body: some View {
        VStack {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        Task {
                            try? await manager.browseLibrary(libraryId: library.id, options: BrowseOptions(searchTerm: searchText.isEmpty ? nil : searchText))
                        }
                    }
            }
            .padding(8)
            .background(Color(.textBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal)

            // Items grid
            if manager.isBrowsing {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if manager.currentLibraryItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No items found")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 16) {
                        ForEach(manager.currentLibraryItems) { item in
                            MediaItemCard(item: item)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(library.name)
        .task {
            try? await manager.browseLibrary(libraryId: library.id)
        }
    }
}

// MARK: - Media Item Card
struct MediaItemCard: View {
    let item: MediaItem
    @ObservedObject var manager = JellyfinManager.shared

    var body: some View {
        Button(action: playItem) {
            VStack(alignment: .leading, spacing: 8) {
                // Album art
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.2))
                        .aspectRatio(1, contentMode: .fit)

                    if let imageUrl = manager.getImageUrl(itemId: item.id) {
                        AsyncImage(url: imageUrl) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Image(systemName: "music.note")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Image(systemName: "music.note")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                    }

                    // Play overlay on hover
                    if manager.currentSession?.mediaItem.id == item.id {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.black.opacity(0.4))
                        Image(systemName: manager.currentSession?.isPlaying == true ? "pause.fill" : "play.fill")
                            .font(.title)
                            .foregroundColor(.white)
                    }
                }

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Text(item.artistString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    Text(item.displayDuration)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func playItem() {
        if manager.currentSession?.mediaItem.id == item.id {
            if manager.currentSession?.isPlaying == true {
                manager.pausePlayback()
            } else {
                manager.resumePlayback()
            }
        } else {
            Task {
                try? await manager.playMedia(item)
            }
        }
    }
}

// MARK: - Now Playing Mini View
struct NowPlayingMiniView: View {
    @ObservedObject var session: PlaybackSession
    @ObservedObject var manager = JellyfinManager.shared

    var body: some View {
        HStack(spacing: 8) {
            // Album art thumbnail
            if let imageUrl = manager.getImageUrl(itemId: session.mediaItem.id, width: 40) {
                AsyncImage(url: imageUrl) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.gray.opacity(0.2)
                }
                .frame(width: 32, height: 32)
                .cornerRadius(4)
            }

            // Track info
            VStack(alignment: .leading, spacing: 0) {
                Text(session.mediaItem.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(session.mediaItem.artistString)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 120, alignment: .leading)

            // Controls
            HStack(spacing: 4) {
                Button(action: { manager.playPreviousInQueue() }) {
                    Image(systemName: "backward.fill")
                }
                .buttonStyle(.plain)

                Button(action: togglePlayback) {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.plain)

                Button(action: { manager.playNextInQueue() }) {
                    Image(systemName: "forward.fill")
                }
                .buttonStyle(.plain)

                if manager.isCurrentMediaVideo() {
                    Button(action: {
                        Task { @MainActor in
                            manager.showVideoWindow()
                        }
                    }) {
                        Image(systemName: "rectangle.on.rectangle")
                    }
                    .buttonStyle(.plain)
                    .help("Show video window")

                    Button(action: {
                        Task { @MainActor in
                            manager.minimizeVideoWindow()
                        }
                    }) {
                        Image(systemName: "minus.rectangle")
                    }
                    .buttonStyle(.plain)
                    .help("Minimize video window")

                    Button(action: {
                        Task { @MainActor in
                            manager.toggleVideoFullscreen()
                        }
                    }) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.plain)
                    .help("Toggle full screen")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(6)
    }

    private func togglePlayback() {
        if session.isPlaying {
            manager.pausePlayback()
        } else {
            manager.resumePlayback()
        }
    }
}

// MARK: - Add Server View
struct AddJellyfinServerView: View {
    @ObservedObject var manager = JellyfinManager.shared
    @Environment(\.dismiss) var dismiss

    @State private var serverName = ""
    @State private var serverUrl = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Jellyfin Server")
                .font(.headline)

            Form {
                TextField("Server Name", text: $serverName)
                TextField("Server URL", text: $serverUrl)
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
            }

            if let error = error {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add Server") {
                    addServer()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(serverName.isEmpty || serverUrl.isEmpty || username.isEmpty || password.isEmpty || isConnecting)
            }
        }
        .padding()
        .frame(width: 400)
    }

    private func addServer() {
        isConnecting = true
        error = nil

        Task {
            do {
                _ = try await manager.addServer(name: serverName, url: serverUrl, username: username, password: password)
                await MainActor.run {
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    isConnecting = false
                }
            }
        }
    }
}
