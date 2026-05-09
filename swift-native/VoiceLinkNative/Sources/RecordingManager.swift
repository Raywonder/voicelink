import SwiftUI
import AVFoundation
import Combine
import AppKit

// MARK: - Recording Format
enum RecordingFormat: String, CaseIterable, Identifiable {
    case wav = "wav"
    case mp3 = "mp3"
    case aac = "aac"
    case flac = "flac"
    case opus = "opus"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wav: return "WAV (Uncompressed)"
        case .mp3: return "MP3 (Compressed)"
        case .aac: return "AAC (Apple)"
        case .flac: return "FLAC (Lossless)"
        case .opus: return "Opus (VoIP Optimized)"
        }
    }

    var fileExtension: String { rawValue }

    var audioFormatID: AudioFormatID {
        switch self {
        case .wav: return kAudioFormatLinearPCM
        case .mp3: return kAudioFormatMPEGLayer3
        case .aac: return kAudioFormatMPEG4AAC
        case .flac: return kAudioFormatFLAC
        case .opus: return kAudioFormatOpus
        }
    }

    var settings: [String: Any] {
        switch self {
        case .wav:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000.0,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        case .mp3:
            return [
                AVFormatIDKey: kAudioFormatMPEGLayer3,
                AVSampleRateKey: 48000.0,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 320000
            ]
        case .aac:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000.0,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256000
            ]
        case .flac:
            return [
                AVFormatIDKey: kAudioFormatFLAC,
                AVSampleRateKey: 48000.0,
                AVNumberOfChannelsKey: 2
            ]
        case .opus:
            return [
                AVFormatIDKey: kAudioFormatOpus,
                AVSampleRateKey: 48000.0,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128000
            ]
        }
    }
}

// MARK: - Recording Mode
enum RecordingMode: String, CaseIterable, Identifiable {
    case mixed = "mixed"
    case multiTrack = "multitrack"
    case selfOnly = "self"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mixed: return "Mixed (All Users)"
        case .multiTrack: return "Multi-Track (Separate Files)"
        case .selfOnly: return "Self Only"
        }
    }

    var description: String {
        switch self {
        case .mixed: return "Record all audio mixed into a single file"
        case .multiTrack: return "Record each user to a separate file for post-production"
        case .selfOnly: return "Record only your own microphone"
        }
    }
}

// MARK: - Recording State
enum RecordingState {
    case idle
    case preparing
    case recording
    case paused
    case stopping
    case error(String)

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }
}

// MARK: - Track Info
struct TrackInfo: Identifiable {
    let id: String
    let userId: String
    let username: String
    var fileURL: URL?
    var duration: TimeInterval = 0
    var peakLevel: Float = 0
    var isActive: Bool = true
}

// MARK: - Recording Session
struct RecordingSession: Identifiable, Codable, Hashable {
    let id: String
    let startTime: Date
    var endTime: Date?
    let roomId: String
    let roomName: String
    let mode: String
    let format: String
    var duration: TimeInterval
    var fileURLs: [String]
    var fileSize: Int64
    var participants: [String]

    var displayDuration: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var displayFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }

    var masterFileURLs: [String] {
        fileURLs.filter { URL(fileURLWithPath: $0).lastPathComponent.lowercased().hasPrefix("recording.") }
    }

    var stemFileURLs: [String] {
        fileURLs.filter { !URL(fileURLWithPath: $0).lastPathComponent.lowercased().hasPrefix("recording.") }
    }
}

enum RecordingExportScope: String, CaseIterable, Identifiable {
    case masterMix = "masterMix"
    case perUserStems = "perUserStems"
    case everything = "everything"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .masterMix: return "Master Mix"
        case .perUserStems: return "Per-User Stems"
        case .everything: return "Master + Stems"
        }
    }
}

// MARK: - Recording Manager
class RecordingManager: ObservableObject {
    static let shared = RecordingManager()

    // Recording state
    @Published var state: RecordingState = .idle
    @Published var currentDuration: TimeInterval = 0
    @Published var currentPeakLevel: Float = 0
    @Published var tracks: [TrackInfo] = []

    // Settings
    @Published var format: RecordingFormat = .wav
    @Published var mode: RecordingMode = .mixed
    @Published var autoSplit: Bool = false
    @Published var splitDurationMinutes: Int = 60
    @Published var includeSystemAudio: Bool = false
    @Published var normalizeOnExport: Bool = true

    // Recording history
    @Published var recentRecordings: [RecordingSession] = []

    // Audio engine components
    private var audioEngine: AVAudioEngine?
    private var mixerNode: AVAudioMixerNode?
    private var recorderNodes: [String: AVAudioMixerNode] = [:]
    private var audioFiles: [String: AVAudioFile] = [:]
    private let writeQueue = DispatchQueue(label: "voicelink.recording-write", qos: .userInitiated)

    // Timing
    private var recordingStartTime: Date?
    private var durationTimer: Timer?
    private var pausedDuration: TimeInterval = 0

    // File management
    private let recordingsDirectory: URL
    private var currentSessionId: String?
    private var currentRoomId: String?
    private var currentRoomName: String?

    init() {
        // Setup recordings directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        recordingsDirectory = documentsPath.appendingPathComponent("VoiceLink Recordings", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)

        // Load settings
        loadSettings()

        // Load recent recordings
        loadRecentRecordings()
    }

    // MARK: - Recording Control

    func startRecording(roomId: String, roomName: String) {
        guard case .idle = state else { return }

        state = .preparing
        currentSessionId = UUID().uuidString
        recordingStartTime = Date()
        currentRoomId = roomId
        currentRoomName = roomName
        currentDuration = 0
        pausedDuration = 0
        tracks = []

        do {
            try setupAudioEngine()
            try createRecordingFiles(roomId: roomId, roomName: roomName)

            // Start the engine
            try audioEngine?.start()

            // Start duration timer
            startDurationTimer()

            state = .recording

            print("Recording started: \(currentSessionId ?? "")")

        } catch {
            state = .error("Failed to start recording: \(error.localizedDescription)")
            print("Recording error: \(error)")
        }
    }

    func stopRecording() {
        guard state.isRecording || state.isPaused else { return }

        state = .stopping

        // Stop duration timer
        durationTimer?.invalidate()
        durationTimer = nil

        // Stop audio engine
        audioEngine?.stop()
        mixerNode?.removeTap(onBus: 0)
        audioEngine = nil
        mixerNode = nil
        recorderNodes.removeAll()

        // Close all audio files
        for (_, file) in audioFiles {
            // Files are automatically closed when deallocated
            _ = file
        }
        audioFiles.removeAll()

        // Calculate final duration
        let finalDuration = currentDuration

        // Create recording session record
        if let sessionId = currentSessionId,
           let startTime = recordingStartTime {

            let fileURLs = tracks.compactMap { $0.fileURL?.path }
            let totalSize = calculateTotalFileSize(urls: tracks.compactMap { $0.fileURL })

            let session = RecordingSession(
                id: sessionId,
                startTime: startTime,
                endTime: Date(),
                roomId: currentRoomId ?? "",
                roomName: currentRoomName ?? "VoiceLink Room",
                mode: mode.rawValue,
                format: format.rawValue,
                duration: finalDuration,
                fileURLs: fileURLs,
                fileSize: totalSize,
                participants: tracks.map { $0.username }
            )

            writeSessionManifest(for: session)
            recentRecordings.insert(session, at: 0)
            saveRecentRecordings()
        }

        // Reset state
        currentSessionId = nil
        recordingStartTime = nil
        currentRoomId = nil
        currentRoomName = nil
        tracks = []

        state = .idle

        print("Recording stopped")
    }

    func pauseRecording() {
        guard state.isRecording else { return }

        audioEngine?.pause()
        durationTimer?.invalidate()

        state = .paused
    }

    func resumeRecording() {
        guard state.isPaused else { return }

        do {
            try audioEngine?.start()
            startDurationTimer()
            state = .recording
        } catch {
            state = .error("Failed to resume: \(error.localizedDescription)")
        }
    }

    // MARK: - Audio Engine Setup

    private func setupAudioEngine() throws {
        audioEngine = AVAudioEngine()
        mixerNode = AVAudioMixerNode()

        guard let engine = audioEngine, let mixer = mixerNode else {
            throw NSError(domain: "RecordingManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio engine"])
        }

        engine.attach(mixer)
        engine.connect(mixer, to: engine.mainMixerNode, format: nil)

        // Setup recording tap on mixer
        let format = mixer.outputFormat(forBus: 0)
        mixer.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer, userId: "mixed")
        }
    }

    private func createRecordingFiles(roomId: String, roomName: String) throws {
        guard currentSessionId != nil else { return }

        // Create session directory
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dateString = dateFormatter.string(from: Date())

        let sanitizedRoomName = roomName.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")

        let sessionDir = recordingsDirectory
            .appendingPathComponent("\(sanitizedRoomName)_\(dateString)", isDirectory: true)

        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        // Create main recording file
        let mainFileURL = sessionDir.appendingPathComponent("recording.\(format.fileExtension)")

        let settings = format.settings
        let audioFile = try AVAudioFile(forWriting: mainFileURL, settings: settings)
        audioFiles["mixed"] = audioFile

        let trackInfo = TrackInfo(
            id: "mixed",
            userId: "mixed",
            username: "Mixed Recording",
            fileURL: mainFileURL
        )
        tracks.append(trackInfo)
    }

    // MARK: - Audio Processing

    func addUserAudio(userId: String, username: String, buffer: AVAudioPCMBuffer) {
        guard state.isRecording else { return }
        writeRemoteAudio(userId: userId, username: username, buffer: buffer)
    }

    func addLocalAudio(username: String, buffer: AVAudioPCMBuffer) {
        guard state.isRecording else { return }
        let normalizedName = sanitizedTrackName(username.isEmpty ? "Local User" : username)
        let localUserId = "self"
        writeQueue.async { [weak self] in
            guard let self else { return }
            switch self.mode {
            case .selfOnly:
                self.writeBuffer(buffer, to: "mixed")
            case .mixed:
                self.writeBuffer(buffer, to: "mixed")
            case .multiTrack:
                self.ensureTrackExists(userId: localUserId, username: normalizedName)
                self.writeBuffer(buffer, to: "mixed")
                self.writeBuffer(buffer, to: localUserId)
            }
            self.updateLevels(for: localUserId, buffer: buffer)
        }
    }

    private func createUserTrack(userId: String, username: String) {
        guard currentSessionId != nil else { return }

        // Get session directory from existing track
        guard let existingURL = tracks.first?.fileURL?.deletingLastPathComponent() else { return }

        let sanitizedUsername = username.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")

        let userFileURL = existingURL.appendingPathComponent("\(sanitizedUsername).\(format.fileExtension)")

        do {
            let settings = format.settings
            let audioFile = try AVAudioFile(forWriting: userFileURL, settings: settings)
            audioFiles[userId] = audioFile

            let trackInfo = TrackInfo(
                id: userId,
                userId: userId,
                username: username,
                fileURL: userFileURL
            )
            tracks.append(trackInfo)

        } catch {
            print("Failed to create track for user \(username): \(error)")
        }
    }

    private func writeRemoteAudio(userId: String, username: String, buffer: AVAudioPCMBuffer) {
        let normalizedName = sanitizedTrackName(username.isEmpty ? userId : username)
        writeQueue.async { [weak self] in
            guard let self else { return }
            switch self.mode {
            case .selfOnly:
                break
            case .mixed:
                self.writeBuffer(buffer, to: "mixed")
            case .multiTrack:
                self.ensureTrackExists(userId: userId, username: normalizedName)
                self.writeBuffer(buffer, to: "mixed")
                self.writeBuffer(buffer, to: userId)
            }
            self.updateLevels(for: userId, buffer: buffer)
        }
    }

    private func ensureTrackExists(userId: String, username: String) {
        if audioFiles[userId] == nil {
            createUserTrack(userId: userId, username: username)
        }
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, userId: String) {
        writeBuffer(buffer, to: userId)
    }

    private func writeBuffer(_ buffer: AVAudioPCMBuffer, to fileKey: String) {
        guard let audioFile = audioFiles[fileKey] else { return }
        guard let convertedBuffer = convertedBufferIfNeeded(buffer, to: audioFile.processingFormat) else { return }

        do {
            try audioFile.write(from: convertedBuffer)
        } catch {
            print("Failed to write audio buffer for \(fileKey): \(error)")
        }
    }

    private func convertedBufferIfNeeded(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == targetFormat {
            return buffer
        }

        let targetFrameCapacity = AVAudioFrameCount(
            max(
                Double(buffer.frameLength) * (targetFormat.sampleRate / max(buffer.format.sampleRate, 1)),
                1
            )
        )
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetFrameCapacity) else {
            return nil
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            return nil
        }

        var conversionError: NSError?
        var didSupplyInput = false
        let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
            if didSupplyInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didSupplyInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let conversionError {
            print("Recording conversion error: \(conversionError)")
            return nil
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return convertedBuffer.frameLength > 0 ? convertedBuffer : nil
        case .error:
            return nil
        @unknown default:
            return nil
        }
    }

    private func updateLevels(for userId: String, buffer: AVAudioPCMBuffer) {
        let level = calculatePeakLevel(buffer: buffer)
        DispatchQueue.main.async {
            self.currentPeakLevel = level
            if let index = self.tracks.firstIndex(where: { $0.userId == userId }) {
                self.tracks[index].peakLevel = level
            }
        }
    }

    private func sanitizedTrackName(_ value: String) -> String {
        value
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    private func calculatePeakLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)

        var peak: Float = 0

        for channel in 0..<channelCount {
            for frame in 0..<frameLength {
                let sample = abs(channelData[channel][frame])
                if sample > peak {
                    peak = sample
                }
            }
        }

        return peak
    }

    // MARK: - Duration Timer

    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.recordingStartTime else { return }
            self.currentDuration = Date().timeIntervalSince(startTime) - self.pausedDuration

            // Check for auto-split
            if self.autoSplit {
                let splitSeconds = Double(self.splitDurationMinutes * 60)
                if self.currentDuration >= splitSeconds {
                    self.splitRecording()
                }
            }
        }
    }

    private func splitRecording() {
        // TODO: Implement auto-split functionality
        // This would close current files and create new ones
        print("Auto-split triggered at \(currentDuration) seconds")
    }

    // MARK: - File Management

    func getRecordingsDirectory() -> URL {
        return recordingsDirectory
    }

    func deleteRecording(_ session: RecordingSession) {
        // Delete files
        for urlString in session.fileURLs {
            let url = URL(fileURLWithPath: urlString)
            try? FileManager.default.removeItem(at: url)
        }

        // Remove from list
        recentRecordings.removeAll { $0.id == session.id }
        saveRecentRecordings()
    }

    func exportRecording(
        _ session: RecordingSession,
        to destination: URL,
        format: RecordingFormat,
        scope: RecordingExportScope = .everything
    ) {
        // TODO: Implement true format conversion for export.
        // For now, copy the selected source files and preserve the original encoding.
        let selectedFiles: [String]
        switch scope {
        case .masterMix:
            selectedFiles = session.masterFileURLs
        case .perUserStems:
            selectedFiles = session.stemFileURLs
        case .everything:
            selectedFiles = session.fileURLs
        }

        for urlString in selectedFiles {
            let sourceURL = URL(fileURLWithPath: urlString)
            let destURL = destination.appendingPathComponent(sourceURL.lastPathComponent)
            try? FileManager.default.copyItem(at: sourceURL, to: destURL)
        }

        let manifestURL = destination.appendingPathComponent("recording-export.json")
        let exportMetadata: [String: Any] = [
            "sessionId": session.id,
            "roomId": session.roomId,
            "roomName": session.roomName,
            "scope": scope.rawValue,
            "requestedFormat": format.rawValue,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "files": selectedFiles.map { URL(fileURLWithPath: $0).lastPathComponent }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: exportMetadata, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    private func calculateTotalFileSize(urls: [URL]) -> Int64 {
        var total: Int64 = 0
        for url in urls {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total
    }

    private func writeSessionManifest(for session: RecordingSession) {
        guard let firstFilePath = session.fileURLs.first else { return }
        let sessionDirectory = URL(fileURLWithPath: firstFilePath).deletingLastPathComponent()
        let manifestURL = sessionDirectory.appendingPathComponent("recording-session.json")
        let payload: [String: Any] = [
            "sessionId": session.id,
            "roomId": session.roomId,
            "roomName": session.roomName,
            "mode": session.mode,
            "format": session.format,
            "startedAt": ISO8601DateFormatter().string(from: session.startTime),
            "endedAt": session.endTime.map { ISO8601DateFormatter().string(from: $0) } as Any,
            "duration": session.duration,
            "participants": session.participants,
            "masterFiles": session.masterFileURLs.map { URL(fileURLWithPath: $0).lastPathComponent },
            "stemFiles": session.stemFileURLs.map { URL(fileURLWithPath: $0).lastPathComponent }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    // MARK: - Settings Persistence

    private func loadSettings() {
        if let formatRaw = UserDefaults.standard.string(forKey: "recording.format"),
           let format = RecordingFormat(rawValue: formatRaw) {
            self.format = format
        }

        if let modeRaw = UserDefaults.standard.string(forKey: "recording.mode"),
           let mode = RecordingMode(rawValue: modeRaw) {
            self.mode = mode
        }

        autoSplit = UserDefaults.standard.bool(forKey: "recording.autoSplit")
        splitDurationMinutes = UserDefaults.standard.integer(forKey: "recording.splitDuration")
        if splitDurationMinutes == 0 { splitDurationMinutes = 60 }

        includeSystemAudio = UserDefaults.standard.bool(forKey: "recording.includeSystemAudio")
        normalizeOnExport = UserDefaults.standard.bool(forKey: "recording.normalizeOnExport")
    }

    func saveSettings() {
        UserDefaults.standard.set(format.rawValue, forKey: "recording.format")
        UserDefaults.standard.set(mode.rawValue, forKey: "recording.mode")
        UserDefaults.standard.set(autoSplit, forKey: "recording.autoSplit")
        UserDefaults.standard.set(splitDurationMinutes, forKey: "recording.splitDuration")
        UserDefaults.standard.set(includeSystemAudio, forKey: "recording.includeSystemAudio")
        UserDefaults.standard.set(normalizeOnExport, forKey: "recording.normalizeOnExport")
    }

    private func loadRecentRecordings() {
        if let data = UserDefaults.standard.data(forKey: "recording.recentSessions"),
           let sessions = try? JSONDecoder().decode([RecordingSession].self, from: data) {
            recentRecordings = sessions
        }
    }

    private func saveRecentRecordings() {
        if let data = try? JSONEncoder().encode(recentRecordings) {
            UserDefaults.standard.set(data, forKey: "recording.recentSessions")
        }
    }
}

// MARK: - Recording Controls View
struct RecordingControlsView: View {
    @ObservedObject var recordingManager = RecordingManager.shared
    let roomId: String
    let roomName: String

    var body: some View {
        HStack(spacing: 12) {
            // Recording button
            Button(action: toggleRecording) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(recordingManager.state.isRecording ? Color.red : Color.gray)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.5), lineWidth: 1)
                        )
                        .animation(
                            recordingManager.state.isRecording ?
                            Animation.easeInOut(duration: 0.5).repeatForever(autoreverses: true) :
                            .default,
                            value: recordingManager.state.isRecording
                        )

                    Text(recordingButtonLabel)
                        .font(.caption)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(recordingManager.state.isRecording ? Color.red.opacity(0.2) : Color.gray.opacity(0.2))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)

            // Duration display
            if recordingManager.state.isRecording || recordingManager.state.isPaused {
                Text(formatDuration(recordingManager.currentDuration))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(recordingManager.state.isPaused ? .orange : .red)

                // Peak level indicator
                LevelMeterView(level: recordingManager.currentPeakLevel)
                    .frame(width: 60, height: 8)

                // Pause button
                Button(action: togglePause) {
                    Image(systemName: recordingManager.state.isPaused ? "play.fill" : "pause.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var recordingButtonLabel: String {
        switch recordingManager.state {
        case .idle: return "Record"
        case .preparing: return "Starting..."
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .stopping: return "Stopping..."
        case .error: return "Error"
        }
    }

    private func toggleRecording() {
        if recordingManager.state.isRecording || recordingManager.state.isPaused {
            recordingManager.stopRecording()
        } else if case .idle = recordingManager.state {
            recordingManager.startRecording(roomId: roomId, roomName: roomName)
        }
    }

    private func togglePause() {
        if recordingManager.state.isPaused {
            recordingManager.resumeRecording()
        } else if recordingManager.state.isRecording {
            recordingManager.pauseRecording()
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Level Meter View
struct LevelMeterView: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.3))

                // Level
                RoundedRectangle(cornerRadius: 2)
                    .fill(levelColor)
                    .frame(width: geometry.size.width * CGFloat(min(level, 1.0)))
            }
        }
    }

    private var levelColor: Color {
        if level > 0.9 {
            return .red
        } else if level > 0.7 {
            return .orange
        } else {
            return .green
        }
    }
}

// MARK: - Recording Settings View
struct RecordingSettingsView: View {
    @ObservedObject var recordingManager = RecordingManager.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recording Settings")
                .font(.headline)

            // Format selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Format")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Picker("Format", selection: $recordingManager.format) {
                    ForEach(RecordingFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.menu)
            }

            // Mode selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Recording Mode")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Picker("Mode", selection: $recordingManager.mode) {
                    ForEach(RecordingMode.allCases) { mode in
                        VStack(alignment: .leading) {
                            Text(mode.displayName)
                        }
                        .tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(recordingManager.mode.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Auto-split
            Toggle("Auto-split recordings", isOn: $recordingManager.autoSplit)

            if recordingManager.autoSplit {
                HStack {
                    Text("Split every")
                    TextField("", value: $recordingManager.splitDurationMinutes, format: .number)
                        .frame(width: 50)
                        .textFieldStyle(.roundedBorder)
                    Text("minutes")
                }
                .padding(.leading, 20)
            }

            Divider()

            // Additional options
            Toggle("Include system audio (requires permission)", isOn: $recordingManager.includeSystemAudio)
            Toggle("Normalize audio on export", isOn: $recordingManager.normalizeOnExport)

            Spacer()

            // Storage info
            VStack(alignment: .leading, spacing: 4) {
                Text("Recordings saved to:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(recordingManager.getRecordingsDirectory().path)
                    .font(.caption)
                    .foregroundColor(.blue)
                    .onTapGesture {
                        NSWorkspace.shared.open(recordingManager.getRecordingsDirectory())
                    }
            }

            HStack {
                Spacer()
                Button("Done") {
                    recordingManager.saveSettings()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 400, height: 500)
    }
}

// MARK: - Recording History View
struct RecordingHistoryView: View {
    @ObservedObject var recordingManager = RecordingManager.shared
    @State private var selectedRecording: RecordingSession?
    @State private var exportFormat: RecordingFormat = .wav
    @State private var exportScope: RecordingExportScope = .everything

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Recordings")
                    .font(.headline)

                Spacer()

                if let selectedRecording {
                    Menu("Export") {
                        Picker("Export Type", selection: $exportScope) {
                            ForEach(RecordingExportScope.allCases) { scope in
                                Text(scope.displayName).tag(scope)
                            }
                        }

                        Picker("Requested Format", selection: $exportFormat) {
                            ForEach(RecordingFormat.allCases) { format in
                                Text(format.displayName).tag(format)
                            }
                        }

                        Divider()

                        Button("Export Selected Recording") {
                            exportSelectedRecording(selectedRecording)
                        }
                    }
                    .accessibilityLabel("Export Selected Recording")
                }

                Button(action: openRecordingsFolder) {
                    Image(systemName: "folder")
                }
                .help("Open recordings folder")
                .accessibilityLabel("Open Recordings Folder")
            }

            if recordingManager.recentRecordings.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No recordings yet")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(recordingManager.recentRecordings, selection: $selectedRecording) { recording in
                    RecordingRowView(recording: recording)
                        .tag(recording)
                        .contextMenu {
                            Button("Show in Finder") {
                                showInFinder(recording)
                            }
                            Button("Export Master Mix") {
                                exportRecording(recording, scope: .masterMix)
                            }
                            Button("Export Per-User Stems") {
                                exportRecording(recording, scope: .perUserStems)
                            }
                            Button("Export Master and Stems") {
                                exportRecording(recording, scope: .everything)
                            }
                            Button("Delete", role: .destructive) {
                                recordingManager.deleteRecording(recording)
                            }
                        }
                }
            }
        }
        .padding()
    }

    private func openRecordingsFolder() {
        NSWorkspace.shared.open(recordingManager.getRecordingsDirectory())
    }

    private func showInFinder(_ recording: RecordingSession) {
        if let firstFile = recording.fileURLs.first {
            let url = URL(fileURLWithPath: firstFile)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func exportSelectedRecording(_ recording: RecordingSession) {
        exportRecording(recording, scope: exportScope)
    }

    private func exportRecording(_ recording: RecordingSession, scope: RecordingExportScope) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a folder for the exported recording files."

        guard panel.runModal() == .OK, let destinationRoot = panel.url else { return }

        let safeRoomName = recording.roomName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let exportFolderName = "\(safeRoomName.isEmpty ? "Recording" : safeRoomName)-\(recording.id.prefix(8))"
        let exportFolder = destinationRoot.appendingPathComponent(exportFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)
        recordingManager.exportRecording(recording, to: exportFolder, format: exportFormat, scope: scope)
        NSWorkspace.shared.activateFileViewerSelecting([exportFolder])
    }
}

// MARK: - Recording Row View
struct RecordingRowView: View {
    let recording: RecordingSession

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.roomName.isEmpty ? "Recording" : recording.roomName)
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack(spacing: 8) {
                    Label(recording.displayDuration, systemImage: "clock")
                    Label(recording.displayFileSize, systemImage: "doc")
                    Label(recording.format.uppercased(), systemImage: "waveform")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            Text(formatDate(recording.startTime))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
