import Foundation
import AVFoundation
import AppKit

/// Centralized sound manager for VoiceLink app
/// Uses actual sound files from Resources/sounds directory
class AppSoundManager: ObservableObject {
    static let shared = AppSoundManager()
    struct SoundDownloadNotice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let isReminder: Bool
    }
    private let remoteSoundBaseURLDefaults = [
        "https://im.tappedin.fm/sounds",
        "https://im.tappedin.fm/assets/sounds",
        "https://im.tappedin.fm/copyparty/sounds",
        "https://im.tappedin.fm/cp/sounds",
        "https://voicelink.devinecreations.net/sounds",
        "https://voicelink.devinecreations.net/assets/sounds",
        "https://voicelink.devinecreations.net/downloads/sounds",
        "https://voicelink.devinecreations.net/voicelink/sounds",
        "https://dl.voicelink.devinecreations.net/sounds",
        "https://dl.voicelink.devinecreations.net/copyparty/sounds",
        "https://dl.voicelink.devinecreations.net/cp/sounds"
    ]
    
    private struct IndexedSound {
        let url: URL
        let fileNameLower: String
        let baseNameLower: String
        let relativePathLower: String
    }

    // Sound types with their file mappings
    enum SoundType: String, CaseIterable {
        // Connection sounds
        case connected = "connected"
        case disconnected = "connection lost"
        case reconnected = "reconnected"

        // UI feedback sounds
        case success = "success"
        case error = "error"
        case notification = "notification"
        case buttonClick = "button-click"

        // User activity sounds
        case userJoin = "user-join"
        case userLeave = "user-leave"

        // Whisper mode sounds
        case whisperStart = "Whisper-start"
        case whisperStop = "Whisper-Stop"

        // Peek into room sounds
        case peekIn = "Peek-In-To-Room-Raised-Fast"
        case peekOut = "Peek-Out-Of-Room-Blinds-Lowered-Fast"

        // Push-to-talk sounds
        case pttStart = "ptt-beep-high"
        case pttStop = "ptt-beep-low"

        // Message sounds
        case messageIncoming = "message-incoming-ding"
        case messageReceived = "message-receve"
        case messageSent = "message-sent"
        case doorbell = "Doorbell-Ding-Dong-Type-Single"

        // File transfer
        case fileTransferComplete = "file transfer complete"

        // Menu/UI transition sounds
        case menuOpen = "whoosh_fast1"
        case menuClose = "whoosh_fast2"
        case wooshFast = "whoosh_fast3"
        case wooshMedium = "whoosh_medium1"
        case wooshSlow = "whoosh_slow1"

        // UI animation sounds
        case uiAppear = "UI Animate Clean Beeps Appear (stereo)"
        case uiDisappear = "UI Animate Clean Beeps Disappear (stereo)"

        // Button toggle sounds
        case toggleOn = "switch_button_push_small_04"
        case toggleOff = "switch_button_push_small_05"

        // Test sounds
        case soundTest = "your-sound-test"

        var fileExtension: String {
            switch self {
            case .peekIn, .peekOut, .pttStart, .pttStop, .doorbell,
                 .uiAppear, .uiDisappear, .toggleOn, .toggleOff:
                return "flac"
            default:
                return "wav"
            }
        }

        var description: String {
            switch self {
            case .connected: return "Connected to server"
            case .disconnected: return "Disconnected from server"
            case .reconnected: return "Reconnected to server"
            case .success: return "Success"
            case .error: return "Error"
            case .notification: return "Notification"
            case .buttonClick: return "Button click"
            case .userJoin: return "User joined room"
            case .userLeave: return "User left room"
            case .whisperStart: return "Whisper mode started"
            case .whisperStop: return "Whisper mode ended"
            case .peekIn: return "Peeking into room"
            case .peekOut: return "Stopped peeking"
            case .pttStart: return "Push-to-talk started"
            case .pttStop: return "Push-to-talk ended"
            case .messageIncoming: return "Incoming message"
            case .messageReceived: return "Message received"
            case .messageSent: return "Message sent"
            case .doorbell: return "Doorbell"
            case .fileTransferComplete: return "File transfer complete"
            case .menuOpen: return "Menu opened"
            case .menuClose: return "Menu closed"
            case .wooshFast: return "Fast transition"
            case .wooshMedium: return "Medium transition"
            case .wooshSlow: return "Slow transition"
            case .uiAppear: return "UI element appeared"
            case .uiDisappear: return "UI element disappeared"
            case .toggleOn: return "Toggle on"
            case .toggleOff: return "Toggle off"
            case .soundTest: return "Sound test"
            }
        }
    }

    // Settings
    @Published var soundsEnabled: Bool = true
    @Published var volume: Float = 0.7
    @Published var startupIntroEnabled: Bool = true
    @Published var activeSoundDownloadNotice: SoundDownloadNotice?

    // Audio players cache
    private var audioPlayers: [SoundType: AVAudioPlayer] = [:]
    private var systemSounds: [SoundType: NSSound] = [:]
    private var startupIntroPlayer: AVAudioPlayer?
    private var indexedSounds: [IndexedSound] = []
    private var soundsRootURL: URL?
    private var isInitialized = false
    private var startupIntroPlayed = false
    private var inFlightDownloads: Set<String> = []
    private var downloadFailures: Set<String> = []
    private var pendingPlayAfterDownload: Set<SoundType> = []
    private var lastMissingAttemptAt: [SoundType: Date] = [:]
    private let missingRetryInterval: TimeInterval = 10
    private let verboseLogs = false
    private let ioQueue = DispatchQueue(label: "voicelink.sounds.download", qos: .utility)
    private var didPublishDownloadNoticeThisLaunch = false

    init() {
        loadSettings()
        isInitialized = true
        scheduleDeferredWarmup()
    }

    // MARK: - Preload Sounds

    private func preloadSounds() {
        // Kept for compatibility with existing call sites.
        scheduleDeferredWarmup()
    }

    private func scheduleDeferredWarmup() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.buildSoundLibraryIndex()
            let warmupTypes: [SoundType] = [
                .connected, .disconnected, .notification, .buttonClick,
                .userJoin, .userLeave, .toggleOn, .toggleOff
            ]
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for (index, soundType) in warmupTypes.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + (Double(index) * 0.05)) {
                        self.loadSound(soundType)
                    }
                }
                self.refreshDownloadReminderState()
                if self.verboseLogs {
                    print("AppSoundManager: Deferred warmup scheduled")
                }
            }
        }
    }

    private func loadSound(_ soundType: SoundType) {
        if let last = lastMissingAttemptAt[soundType],
           Date().timeIntervalSince(last) < missingRetryInterval,
           audioPlayers[soundType] == nil,
           systemSounds[soundType] == nil {
            return
        }

        if let smartURL = resolveMappedSoundURL(for: soundType) {
            if cachePlayableSound(for: soundType, url: smartURL) {
                return
            }
        }

        if soundType == .soundTest, let testURL = resolveSoundTestURL() {
            if cachePlayableSound(for: soundType, url: testURL) {
                return
            }
        }

        // Try multiple locations for sound files
        let locations = [
            ("sounds/ui-sounds", soundType.rawValue, soundType.fileExtension),
            ("sounds", soundType.rawValue, soundType.fileExtension),
            (nil, soundType.rawValue, soundType.fileExtension),
            ("sounds/ui-sounds", soundType.rawValue, "mp3"),
            ("sounds/ui-sounds", soundType.rawValue, "flac"),
            ("sounds", soundType.rawValue, "mp3"),
            ("sounds", soundType.rawValue, "flac")
        ]

        for (subdir, name, ext) in locations {
            var url: URL?
            if let sub = subdir {
                url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: sub)
            } else {
                url = Bundle.main.url(forResource: name, withExtension: ext)
            }

            if let soundURL = url {
                if cachePlayableSound(for: soundType, url: soundURL) {
                    return
                }
            }
        }
        lastMissingAttemptAt[soundType] = Date()
        queueBackgroundDownload(for: soundType, playWhenReady: false)
    }

    private func cachePlayableSound(for soundType: SoundType, url: URL) -> Bool {
        if let player = try? AVAudioPlayer(contentsOf: url) {
            player.prepareToPlay()
            player.volume = volume
            audioPlayers[soundType] = player
            systemSounds.removeValue(forKey: soundType)
            lastMissingAttemptAt[soundType] = nil
            return true
        }
        if let nsSound = NSSound(contentsOf: url, byReference: false) {
            nsSound.volume = volume
            systemSounds[soundType] = nsSound
            audioPlayers.removeValue(forKey: soundType)
            lastMissingAttemptAt[soundType] = nil
            return true
        }
        return false
    }
    
    private func buildSoundLibraryIndex() {
        guard let resourcesRoot = Bundle.main.resourceURL else { return }
        let soundsRoot = resourcesRoot.appendingPathComponent("sounds", isDirectory: true)
        var index: [IndexedSound] = []
        let roots = [soundsRoot, downloadedSoundsRoot()]
        for root in roots {
            guard let root else { continue }
            if let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let fileURL as URL in enumerator {
                    guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                          values.isRegularFile == true else { continue }
                    let ext = fileURL.pathExtension.lowercased()
                    guard ["wav", "flac", "mp3", "m4a", "aiff", "aif", "aifc", "caf", "ogg", "pcm"].contains(ext) else { continue }
                    let relative = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
                    let fileName = fileURL.lastPathComponent.lowercased()
                    let base = fileURL.deletingPathExtension().lastPathComponent.lowercased()
                    index.append(
                        IndexedSound(
                            url: fileURL,
                            fileNameLower: fileName,
                            baseNameLower: base,
                            relativePathLower: relative.lowercased()
                        )
                    )
                }
            }
        }

        let assign = {
            self.soundsRootURL = soundsRoot
            self.indexedSounds = index
        }
        if Thread.isMainThread {
            assign()
        } else {
            DispatchQueue.main.sync(execute: assign)
        }
    }
    
    private func resolveMappedSoundURL(for soundType: SoundType) -> URL? {
        if indexedSounds.isEmpty {
            buildSoundLibraryIndex()
        }
        guard !indexedSounds.isEmpty else { return nil }
        
        let targetBase = soundType.rawValue.lowercased()
        let preferredExt = soundType.fileExtension.lowercased()
        
        // 1) Exact name mapping wins.
        let exact = indexedSounds.filter { $0.baseNameLower == targetBase }
        if let direct = bestMatch(from: exact, preferredExt: preferredExt, soundType: soundType) {
            return direct.url
        }
        
        // 2) Smart keyword mapping from optional packs.
        let keywords = smartKeywords(for: soundType)
        guard !keywords.isEmpty else { return nil }
        let fuzzy = indexedSounds.filter { item in
            let haystack = "\(item.baseNameLower) \(item.relativePathLower)"
            return keywords.contains { haystack.contains($0) }
        }
        
        return bestMatch(from: fuzzy, preferredExt: preferredExt, soundType: soundType)?.url
    }
    
    private func bestMatch(from candidates: [IndexedSound], preferredExt: String, soundType: SoundType) -> IndexedSound? {
        guard !candidates.isEmpty else { return nil }
        let coreUI = isCoreUISound(soundType)
        
        return candidates.max { lhs, rhs in
            score(lhs, preferredExt: preferredExt, coreUI: coreUI, soundType: soundType) <
            score(rhs, preferredExt: preferredExt, coreUI: coreUI, soundType: soundType)
        }
    }
    
    private func score(_ item: IndexedSound, preferredExt: String, coreUI: Bool, soundType: SoundType) -> Int {
        var total = 0
        if item.url.pathExtension.lowercased() == preferredExt { total += 25 }
        
        let rel = item.relativePathLower
        let depth = rel.split(separator: "/").count
        total += max(0, 10 - depth)
        
        if rel.contains("ui-sounds") || rel.contains("ui/") { total += 20 }
        if rel.hasPrefix("sounds/") || !rel.contains("/") { total += 8 }
        
        if coreUI {
            if rel.contains("pack") || rel.contains("theme") || rel.contains("sfx-pack") { total -= 8 }
            if rel.contains("ui") || rel.contains("menu") || rel.contains("toggle") || rel.contains("button") { total += 12 }
        } else {
            if rel.contains(soundType.rawValue.lowercased()) { total += 12 }
        }
        
        return total
    }
    
    private func isCoreUISound(_ soundType: SoundType) -> Bool {
        switch soundType {
        case .success, .error, .notification, .buttonClick,
             .menuOpen, .menuClose, .wooshFast, .wooshMedium, .wooshSlow,
             .uiAppear, .uiDisappear, .toggleOn, .toggleOff,
             .connected, .disconnected, .reconnected:
            return true
        default:
            return false
        }
    }
    
    private func smartKeywords(for soundType: SoundType) -> [String] {
        switch soundType {
        case .connected: return ["connected", "online", "connect"]
        case .disconnected: return ["disconnect", "offline", "lost"]
        case .reconnected: return ["reconnected", "reconnect", "rejoin"]
        case .success: return ["success", "ok", "confirm", "done"]
        case .error: return ["error", "fail", "alert"]
        case .notification: return ["notification", "notify", "ping", "chime"]
        case .buttonClick: return ["button", "click", "tap", "press"]
        case .userJoin: return ["join", "entered", "user-in"]
        case .userLeave: return ["leave", "left", "user-out"]
        case .whisperStart: return ["whisper-start", "whisper_on", "whisper on"]
        case .whisperStop: return ["whisper-stop", "whisper_off", "whisper off"]
        case .peekIn: return ["peek-in", "peek in", "enter-view", "whoosh_in"]
        case .peekOut: return ["peek-out", "peek out", "exit-view", "whoosh_out"]
        case .pttStart: return ["ptt-start", "transmit-start", "key-down", "beep-high"]
        case .pttStop: return ["ptt-stop", "transmit-stop", "key-up", "beep-low"]
        case .messageIncoming: return ["message-incoming", "incoming", "new-message"]
        case .messageReceived: return ["message-received", "received", "chat-receive"]
        case .messageSent: return ["message-sent", "sent", "chat-send"]
        case .doorbell: return ["doorbell", "ding-dong", "ring"]
        case .fileTransferComplete: return ["file-transfer-complete", "transfer-done", "upload-complete", "download-complete"]
        case .menuOpen: return ["menu-open", "open-menu", "whoosh-open"]
        case .menuClose: return ["menu-close", "close-menu", "whoosh-close"]
        case .wooshFast: return ["whoosh_fast", "woosh_fast", "swoosh_fast"]
        case .wooshMedium: return ["whoosh_medium", "woosh_medium", "swoosh_medium"]
        case .wooshSlow: return ["whoosh_slow", "woosh_slow", "swoosh_slow"]
        case .uiAppear: return ["ui-appear", "appear", "pop-in", "show"]
        case .uiDisappear: return ["ui-disappear", "disappear", "hide", "pop-out"]
        case .toggleOn: return ["toggle-on", "switch-on", "enable", "on"]
        case .toggleOff: return ["toggle-off", "switch-off", "disable", "off"]
        case .soundTest: return ["sound-test", "test-tone", "test"]
        }
    }

    private func resolveSoundTestURL() -> URL? {
        guard let soundsRoot = soundsRootURL ?? Bundle.main.resourceURL?.appendingPathComponent("sounds", isDirectory: true) else { return nil }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: soundsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let preferred = entries.first { url in
            guard url.pathExtension.lowercased() == "wav" else { return false }
            let base = url.deletingPathExtension().lastPathComponent.lowercased()
            return base == "sound-test" || base == "sound_test" || base == "your-sound-test"
        }
        if let preferred { return preferred }

        return entries.first { url in
            guard url.pathExtension.lowercased() == "wav" else { return false }
            let base = url.deletingPathExtension().lastPathComponent.lowercased()
            return base.contains("test")
        }
    }

    // MARK: - Play Sounds

    func playSound(_ soundType: SoundType, force: Bool = false, allowSystemFallback: Bool = true) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.playSound(soundType, force: force, allowSystemFallback: allowSystemFallback)
            }
            return
        }
        guard soundsEnabled || force else { return }

        if let player = audioPlayers[soundType] {
            player.volume = volume
            player.currentTime = 0
            player.play()
        } else if let sound = systemSounds[soundType] {
            sound.volume = volume
            sound.stop()
            sound.play()
        } else {
            // Try to load on demand
            loadSound(soundType)
            if let player = audioPlayers[soundType] {
                player.volume = volume
                player.currentTime = 0
                player.play()
            } else if let sound = systemSounds[soundType] {
                sound.volume = volume
                sound.stop()
                sound.play()
            } else {
                queueBackgroundDownload(for: soundType, playWhenReady: true)
                if allowSystemFallback {
                    // Optional fallback to system sound.
                    playSystemSound(for: soundType)
                }
            }
        }
    }

    func stopSound(_ soundType: SoundType) {
        if let player = audioPlayers[soundType] {
            player.stop()
            player.currentTime = 0
        }
        systemSounds[soundType]?.stop()
    }

    func isSoundPlaying(_ soundType: SoundType) -> Bool {
        return (audioPlayers[soundType]?.isPlaying ?? false) || (systemSounds[soundType]?.isPlaying ?? false)
    }

    func soundDuration(_ soundType: SoundType) -> Double {
        if let player = audioPlayers[soundType] {
            return player.duration
        }
        if systemSounds[soundType] != nil {
            return 0.6
        }
        loadSound(soundType)
        return audioPlayers[soundType]?.duration ?? 0.6
    }

    private func playSystemSound(for soundType: SoundType) {
        // Fallback to NSSound system sounds
        let systemSoundName: String? = {
            switch soundType {
            case .success: return "Glass"
            case .error: return "Basso"
            case .notification: return "Ping"
            case .disconnected: return "Blow"
            default: return nil
            }
        }()

        if let name = systemSoundName, let sound = NSSound(named: NSSound.Name(name)) {
            sound.volume = volume
            sound.play()
        }
    }

    // Convenience methods - Connection
    func playConnectedSound() { playSound(.connected) }
    func playDisconnectedSound() { playSound(.disconnected) }
    func playReconnectedSound() { playSound(.reconnected) }

    // Convenience methods - UI Feedback
    func playSuccessSound() { playSound(.success) }
    func playErrorSound() { playSound(.error) }
    func playNotificationSound() { playSound(.notification) }
    func playButtonClickSound() { playSound(.buttonClick) }

    // Convenience methods - User Activity
    func playUserJoinSound() { playSound(.userJoin) }
    func playUserLeaveSound() { playSound(.userLeave) }

    // Convenience methods - Whisper Mode
    func playWhisperStartSound() { playSound(.whisperStart) }
    func playWhisperStopSound() { playSound(.whisperStop) }

    // Convenience methods - Peek Into Room
    func playPeekInSound() { playSound(.peekIn) }
    func playPeekOutSound() { playSound(.peekOut) }

    // Convenience methods - Push-to-Talk
    func playPTTStartSound() { playSound(.pttStart) }
    func playPTTStopSound() { playSound(.pttStop) }

    // Convenience methods - Messages
    func playMessageIncomingSound() { playSound(.messageIncoming) }
    func playMessageReceivedSound() { playSound(.messageReceived) }
    func playDoorbellSound() { playSound(.doorbell) }
    func playFileTransferCompleteSound() { playSound(.fileTransferComplete) }

    // Convenience methods - Menu/UI Transitions
    func playMenuOpenSound() { playSound(.menuOpen) }
    func playMenuCloseSound() { playSound(.menuClose) }
    func playWooshSound() { playSound(.wooshFast) }
    func playUIAppearSound() { playSound(.uiAppear) }
    func playUIDisappearSound() { playSound(.uiDisappear) }
    func playToggleOnSound() { playSound(.toggleOn) }
    func playToggleOffSound() { playSound(.toggleOff) }

    // MARK: - Settings

    private func loadSettings() {
        if let enabled = UserDefaults.standard.object(forKey: "appSoundsEnabled") as? Bool {
            soundsEnabled = enabled
        }
        if let vol = UserDefaults.standard.object(forKey: "appSoundsVolume") as? Float {
            volume = vol
        }
        if let startupEnabled = UserDefaults.standard.object(forKey: "startupIntroEnabled") as? Bool {
            startupIntroEnabled = startupEnabled
        }
    }

    func saveSettings() {
        UserDefaults.standard.set(soundsEnabled, forKey: "appSoundsEnabled")
        UserDefaults.standard.set(volume, forKey: "appSoundsVolume")
        UserDefaults.standard.set(startupIntroEnabled, forKey: "startupIntroEnabled")

        // Update volume on all players
        for player in audioPlayers.values {
            player.volume = volume
        }
        for sound in systemSounds.values {
            sound.volume = volume
        }
        startupIntroPlayer?.volume = volume
    }

    func setEnabled(_ enabled: Bool) {
        soundsEnabled = enabled
        saveSettings()
    }

    func setVolume(_ newVolume: Float) {
        volume = max(0, min(1, newVolume))
        saveSettings()
    }

    // MARK: - Test

    func testAllSounds() {
        var delay: Double = 0
        for soundType in SoundType.allCases {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.playSound(soundType)
            }
            delay += 0.8
        }
    }

    @MainActor
    func runMissingSoundDownloadSelfTest(
        soundType: SoundType = .messageSent,
        timeoutSeconds: TimeInterval = 8
    ) async -> Bool {
        if let overrideBase = ProcessInfo.processInfo.environment["VOICELINK_SOUND_TEST_BASE_URL"],
           !overrideBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserDefaults.standard.set(overrideBase, forKey: "voicelinkSoundBaseURL")
        }
        print("AppSoundManager self-test: starting for \(soundType.rawValue)")
        removeDownloadedVariants(for: soundType)
        audioPlayers.removeValue(forKey: soundType)
        systemSounds.removeValue(forKey: soundType)
        buildSoundLibraryIndex()

        playSound(soundType, force: true)

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if hasDownloadedVariant(for: soundType) {
                buildSoundLibraryIndex()
                loadSound(soundType)
                let loaded = audioPlayers[soundType] != nil || systemSounds[soundType] != nil
                print("AppSoundManager self-test: downloaded=\(true) loaded=\(loaded)")
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        let downloaded = hasDownloadedVariant(for: soundType)
        let loaded = audioPlayers[soundType] != nil || systemSounds[soundType] != nil
        print("AppSoundManager self-test: timeout downloaded=\(downloaded) loaded=\(loaded)")
        return downloaded
    }

    @discardableResult
    func playRandomStartupIntro() -> Bool {
        guard startupIntroEnabled, !startupIntroPlayed else { return false }
        if !isInitialized {
            preloadSounds()
        }
        guard let introURL = pickRandomStartupIntroURL() else {
            print("AppSoundManager: No startup intro candidate found")
            return false
        }
        do {
            let player = try AVAudioPlayer(contentsOf: introURL)
            player.volume = volume
            player.currentTime = 0
            player.prepareToPlay()
            player.play()
            startupIntroPlayer = player
            startupIntroPlayed = true
            print("AppSoundManager: Playing startup intro \(introURL.lastPathComponent)")
            return true
        } catch {
            print("AppSoundManager: Failed to play startup intro: \(error.localizedDescription)")
            return false
        }
    }

    func playStartupWelcomeIfNeeded() {
        guard startupIntroEnabled, !startupIntroPlayed else { return }
        if playRandomStartupIntro() { return }

        // Avoid default macOS fallback tones on launch; if the sound is missing,
        // fetch in background and notify users non-blockingly.
        if hasPlayableVariant(for: .connected) {
            playSound(.connected, force: true, allowSystemFallback: false)
        } else {
            queueBackgroundDownload(for: .connected, playWhenReady: true)
            publishBackgroundDownloadNotice(isReminder: false)
        }
        startupIntroPlayed = true
    }

    private func pickRandomStartupIntroURL() -> URL? {
        guard let soundsRoot = soundsRootURL ?? Bundle.main.resourceURL?.appendingPathComponent("sounds", isDirectory: true) else { return nil }
        let exts: Set<String> = ["wav", "mp3", "flac", "m4a", "aiff", "aif", "aifc", "caf", "pcm"]
        var explicit: [URL] = []

        if let enumerator = FileManager.default.enumerator(
            at: soundsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                      values.isRegularFile == true else { continue }
                let ext = url.pathExtension.lowercased()
                guard exts.contains(ext) else { continue }
                let base = url.deletingPathExtension().lastPathComponent.lowercased()
                if base.contains("intro") || base.contains("welcome") || base.contains("startup") {
                    explicit.append(url)
                }
            }
        }

        return explicit.randomElement()
    }

    // MARK: - Background Sound Download

    private func downloadedSoundsRoot() -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport
            .appendingPathComponent("VoiceLink", isDirectory: true)
            .appendingPathComponent("sounds", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            print("AppSoundManager: Could not create downloaded sounds dir: \(error)")
            return nil
        }
    }

    private func hasDownloadedVariant(for soundType: SoundType) -> Bool {
        guard let root = downloadedSoundsRoot() else { return false }
        let names = Set(normalizedNameCandidates(for: soundType).map { $0.lowercased() })
        let extensions = Set(extensionCandidates(for: soundType).map { $0.lowercased() })
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return false
        }
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let ext = fileURL.pathExtension.lowercased()
            let base = fileURL.deletingPathExtension().lastPathComponent.lowercased()
            if extensions.contains(ext), names.contains(base) {
                return true
            }
        }
        return false
    }

    private func removeDownloadedVariants(for soundType: SoundType) {
        guard let root = downloadedSoundsRoot() else { return }
        let names = Set(normalizedNameCandidates(for: soundType).map { $0.lowercased() })
        let extensions = Set(extensionCandidates(for: soundType).map { $0.lowercased() })
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return
        }
        let fm = FileManager.default
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let ext = fileURL.pathExtension.lowercased()
            let base = fileURL.deletingPathExtension().lastPathComponent.lowercased()
            if extensions.contains(ext), names.contains(base) {
                try? fm.removeItem(at: fileURL)
            }
        }
    }

    private func remoteSoundBaseURLs() -> [URL] {
        let overrideRaw = (UserDefaults.standard.string(forKey: "voicelinkSoundBaseURLs") ?? "")
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let single = (UserDefaults.standard.string(forKey: "voicelinkSoundBaseURL") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawList =
            overrideRaw +
            (single.isEmpty ? [] : [single]) +
            serverDerivedSoundBaseURLStrings() +
            remoteSoundBaseURLDefaults
        var out: [URL] = []
        var seen = Set<String>()
        for raw in rawList {
            let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !trimmed.isEmpty, !seen.contains(trimmed), let url = URL(string: trimmed) else { continue }
            seen.insert(trimmed)
            out.append(url)
        }
        return out
    }

    private func serverDerivedSoundBaseURLStrings() -> [String] {
        let cpBaseRaw = [
            UserDefaults.standard.string(forKey: "voicelinkCopypartyBaseURL") ?? "",
            UserDefaults.standard.string(forKey: "copyPartyBaseURL") ?? ""
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let serverBases = APIEndpointResolver.mainBaseCandidates(preferred: ServerManager.shared.baseURL)
        let copypartyBases = cpBaseRaw + serverBases
        let pathSuffixes = [
            "/sounds",
            "/assets/sounds",
            "/downloads/sounds",
            "/voicelink/sounds",
            "/apps/voicelink/sounds",
            "/apps/voicelink/assets/sounds",
            "/media/voicelink/sounds",
            "/copyparty/sounds",
            "/copyparty/voicelink/sounds",
            "/cp/sounds",
            "/cp/voicelink/sounds",
            "/files/sounds"
        ]
        var out: [String] = []
        var seen = Set<String>()
        for base in copypartyBases {
            let normalizedBase = APIEndpointResolver.normalize(base)
            for suffix in pathSuffixes {
                let full = "\(normalizedBase)\(suffix)"
                if seen.insert(full).inserted {
                    out.append(full)
                }
            }
        }
        return out
    }

    private func normalizedNameCandidates(for soundType: SoundType) -> [String] {
        let raw = soundType.rawValue.lowercased()
        var names = Set<String>()
        names.insert(raw)
        names.insert(raw.replacingOccurrences(of: " ", with: "-"))
        names.insert(raw.replacingOccurrences(of: " ", with: "_"))
        names.formUnion(smartKeywords(for: soundType))
        return Array(names).filter { !$0.isEmpty }
    }

    private func extensionCandidates(for soundType: SoundType) -> [String] {
        let list = [soundType.fileExtension.lowercased(), "wav", "mp3", "flac", "m4a", "aiff", "aif", "aifc", "caf", "pcm"]
        var dedup: [String] = []
        for ext in list where !dedup.contains(ext) { dedup.append(ext) }
        return dedup
    }

    private func queueBackgroundDownload(for soundType: SoundType, playWhenReady: Bool) {
        guard soundType != .soundTest else { return }
        let key = soundType.rawValue.lowercased()
        if playWhenReady {
            pendingPlayAfterDownload.insert(soundType)
        }
        if inFlightDownloads.contains(key) || downloadFailures.contains(key) {
            return
        }
        publishBackgroundDownloadNotice(isReminder: false)
        inFlightDownloads.insert(key)
        ioQueue.async { [weak self] in
            self?.downloadMissingSound(soundType)
        }
    }

    private func downloadMissingSound(_ soundType: SoundType) {
        let key = soundType.rawValue.lowercased()
        defer { inFlightDownloads.remove(key) }
        let baseURLs = remoteSoundBaseURLs()
        guard !baseURLs.isEmpty, let localRoot = downloadedSoundsRoot() else { return }

        let dirCandidates = [
            "",
            "sounds",
            "ui-sounds",
            "sounds/ui-sounds",
            "assets/sounds",
            "assets/sounds/ui-sounds",
            "voicelink/sounds",
            "voicelink/assets/sounds",
            "apps/voicelink/sounds",
            "apps/voicelink/assets/sounds",
            "media/voicelink/sounds",
            "default",
            "packs/default",
            "voice",
            "sfx",
            "effects",
            "voiceover",
            "notifications"
        ]
        let nameCandidates = normalizedNameCandidates(for: soundType)
        let extCandidates = extensionCandidates(for: soundType)
        let fm = FileManager.default

        for baseURL in baseURLs {
            for dir in dirCandidates {
                for name in nameCandidates {
                    for ext in extCandidates {
                        var relative = ""
                        if !dir.isEmpty { relative += "\(dir)/" }
                        relative += "\(name).\(ext)"
                        guard let remoteURL = URL(string: relative, relativeTo: baseURL) else { continue }
                        var req = URLRequest(url: remoteURL)
                        req.timeoutInterval = 8
                        req.setValue("VoiceLinkNative/1.0", forHTTPHeaderField: "User-Agent")
                        do {
                            let (data, response) = try URLSession.shared.syncData(for: req)
                            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
                                continue
                            }
                            let targetDir = localRoot.appendingPathComponent(dir, isDirectory: true)
                            try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
                            let targetFile = targetDir.appendingPathComponent("\(name).\(ext)")
                            try data.write(to: targetFile, options: .atomic)
                            DispatchQueue.main.async { [weak self] in
                                guard let self else { return }
                                // Avoid expensive full directory re-index on the main thread for each downloaded file.
                                // We can load directly from the downloaded target and only fall back to normal resolution.
                                _ = self.cachePlayableSound(for: soundType, url: targetFile)
                                if self.audioPlayers[soundType] == nil && self.systemSounds[soundType] == nil {
                                    self.loadSound(soundType)
                                }
                                self.refreshDownloadReminderState()
                                if self.pendingPlayAfterDownload.contains(soundType) {
                                    self.pendingPlayAfterDownload.remove(soundType)
                                    self.playSound(soundType, allowSystemFallback: false)
                                }
                            }
                            return
                        } catch {
                            continue
                        }
                    }
                }
            }
        }
        downloadFailures.insert(key)
        DispatchQueue.main.async { [weak self] in
            self?.refreshDownloadReminderState()
        }
    }

    private func hasPlayableVariant(for soundType: SoundType) -> Bool {
        if audioPlayers[soundType] != nil || systemSounds[soundType] != nil { return true }
        if resolveMappedSoundURL(for: soundType) != nil { return true }
        if hasDownloadedVariant(for: soundType) { return true }
        return false
    }

    private func criticalSoundTypesForReminder() -> [SoundType] {
        [.connected, .notification, .buttonClick, .userJoin, .userLeave, .messageIncoming, .toggleOn, .toggleOff]
    }

    private func refreshDownloadReminderState() {
        let missingCritical = criticalSoundTypesForReminder().contains { !hasPlayableVariant(for: $0) }
        let shouldShow = missingCritical && !inFlightDownloads.isEmpty
        DispatchQueue.main.async {
            if !shouldShow {
                self.activeSoundDownloadNotice = nil
            }
        }
    }

    private func publishBackgroundDownloadNotice(isReminder: Bool) {
        if !isReminder, didPublishDownloadNoticeThisLaunch { return }
        if !isReminder {
            didPublishDownloadNoticeThisLaunch = true
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let title = isReminder ? "VoiceLink sounds still syncing" : "VoiceLink sounds are downloading"
            let message = isReminder
                ? "Some UI sounds are still downloading in the background. You can keep using rooms normally."
                : "Some sounds are missing and are being downloaded in the background. You can still join rooms and use all app features."
            self.activeSoundDownloadNotice = SoundDownloadNotice(title: title, message: message, isReminder: isReminder)
        }
    }
}

private extension URLSession {
    func syncData(for request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var outputData: Data?
        var outputResponse: URLResponse?
        var outputError: Error?
        let task = dataTask(with: request) { data, response, error in
            outputData = data
            outputResponse = response
            outputError = error
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        if let error = outputError { throw error }
        guard let data = outputData, let response = outputResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }
}
