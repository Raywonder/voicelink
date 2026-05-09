import SwiftUI
import AVFoundation

// MARK: - Background Streams Section
struct AdminStreamsSection: View {
    @ObservedObject var adminManager = AdminServerManager.shared
    @State private var config = BackgroundStreamsConfig(enabled: true, streams: [], defaultVolume: 60, fadeInDuration: 1500)
    @State private var showAddStream = false
    @State private var editingStream: BackgroundStreamConfig?
    @State private var selectedStreamID: String?
    @State private var pendingDeleteStream: BackgroundStreamConfig?
    @State private var autosaveTask: Task<Void, Never>?
    @State private var isAutosaveEnabled = false
    @State private var isAutosaving = false
    @State private var autosaveStatus = "Changes save automatically."

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AdminHelpSection(
                title: "Quick Help",
                summary: "Background streams let you keep radio or ambient audio available in selected rooms without manual playback each time.",
                steps: [
                    "Add a named stream and keep the source URL if it is a playlist or station page, then store the resolved direct stream URL separately.",
                    "Set volume and auto-play for rooms that should start with media already active.",
                    "Use Detect Stream when you are not sure whether a URL points at a playlist, a station page, or the final playable stream.",
                    "Use hidden streams for admin-managed presets that should not appear in normal room browsing."
                ],
                docs: [
                    AdminDocLink(title: "Background Streams Docs", localRelativePath: "room-management.html", webPath: "/docs/room-management.html", adminWebPath: "/docs/authenticated/admin-panel.html"),
                    AdminDocLink(title: "Server Setup Docs", localRelativePath: "installation/index.html", webPath: "/docs/installation/index.html", adminWebPath: "/docs/authenticated/admin-panel.html")
                ]
            )

            HStack {
                Text("Background Streams")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
            }

            Text(autosaveStatus)
                .font(.caption)
                .foregroundColor(isAutosaving ? .blue : .gray)

            Toggle("Enable background streams", isOn: $config.enabled)
                .toggleStyle(.switch)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Default Volume")
                        .font(.caption)
                        .foregroundColor(.gray)
                    HStack {
                        Slider(value: Binding(
                            get: { Double(config.defaultVolume) },
                            set: { config.defaultVolume = Int($0) }
                        ), in: 0...100, step: 1)
                        Text("\(config.defaultVolume)%")
                            .foregroundColor(.white)
                            .frame(width: 48)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Fade In")
                        .font(.caption)
                        .foregroundColor(.gray)
                    HStack {
                        Slider(value: Binding(
                            get: { Double(config.fadeInDuration) },
                            set: { config.fadeInDuration = Int($0) }
                        ), in: 0...10000, step: 100)
                        Text("\(config.fadeInDuration)ms")
                            .foregroundColor(.white)
                            .frame(width: 72)
                    }
                }
            }

            Toggle("Shuffle matched background streams", isOn: $config.shuffleEnabled)
                .toggleStyle(.switch)

            ConfigNumberField(label: "Shuffle interval (minutes)", helpText: "Rotate through eligible background streams on this schedule when more than one stream matches a room.", value: Binding(
                get: { max(1, config.shuffleIntervalMinutes) },
                set: { config.shuffleIntervalMinutes = min(max($0, 1), 1440) }
            ))
            .disabled(!config.shuffleEnabled)

            ConfigToggle(label: "Auto-refresh stream playback", helpText: "When enabled, stream state is monitored and refreshed automatically.", isOn: $config.autoRefreshEnabled)
            ConfigToggle(label: "Auto-reconnect dropped streams", helpText: "If a playing stream drops, reconnect and continue playback automatically.", isOn: $config.autoReconnectDropped)
            ConfigNumberField(label: "Metadata refresh (seconds)", helpText: "Refresh interval for now-playing metadata while stream is active.", value: Binding(
                get: { max(5, config.metadataRefreshIntervalSeconds) },
                set: { config.metadataRefreshIntervalSeconds = min(max($0, 5), 600) }
            ))

            Divider()

            Toggle("Enable pre-join background ambience", isOn: $config.preJoinEnabled)
                .toggleStyle(.switch)

            Picker("Pre-join source", selection: Binding(
                get: { config.preJoinStreamId ?? "__local__" },
                set: { newValue in
                    config.preJoinStreamId = newValue == "__local__" ? nil : newValue
                }
            )) {
                Text("Bundled Local Ambience").tag("__local__")
                ForEach(config.streams) { stream in
                    Text(stream.name).tag(stream.id)
                }
            }
            .pickerStyle(.menu)
            .disabled(!config.preJoinEnabled)

            Text("When enabled, clients can play a low-volume ambience or selected server stream before a user joins a room. Disable this to keep it in testing only.")
                .font(.caption)
                .foregroundColor(.gray)

            if config.streams.isEmpty {
                Text("No background streams configured")
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                List(selection: $selectedStreamID) {
                    ForEach(config.streams) { stream in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(stream.name)
                                    .foregroundColor(.white)
                                Text(stream.streamUrl.isEmpty ? stream.url : stream.streamUrl)
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            Text("\(stream.volume)%")
                                .font(.caption)
                                .foregroundColor(.blue)
                            if stream.autoPlay {
                                Image(systemName: "play.circle.fill")
                                    .foregroundColor(.green)
                            }
                        }
                        .tag(stream.id)
                    }
                }
                .frame(minHeight: 220, maxHeight: 320)

                HStack {
                    Button(action: { showAddStream = true }) {
                        Label("Add Stream", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        guard let selected = config.streams.first(where: { $0.id == selectedStreamID }) else { return }
                        editingStream = selected
                    } label: {
                        Label("Edit Selected", systemImage: "pencil")
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedStreamID == nil)

                    Button(role: .destructive) {
                        guard let selected = config.streams.first(where: { $0.id == selectedStreamID }) else { return }
                        pendingDeleteStream = selected
                    } label: {
                        Label("Delete Selected", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedStreamID == nil)
                }
            }

            if !config.streams.isEmpty || config.enabled {
                Button("Save Stream Configuration") {
                    Task {
                        await saveStreamsConfig(config, reason: "saved manually")
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear {
            if let serverConfig = adminManager.serverConfig?.backgroundStreams {
                config = serverConfig
            }
            autosaveStatus = "Changes save automatically."
            isAutosaveEnabled = false
            DispatchQueue.main.async {
                isAutosaveEnabled = true
            }
        }
        .onChange(of: config) { newValue in
            guard isAutosaveEnabled else { return }
            scheduleAutosave(for: newValue)
        }
        .sheet(isPresented: $showAddStream) {
            StreamEditorSheet(
                title: "Add Background Stream",
                stream: BackgroundStreamConfig(
                    id: UUID().uuidString,
                    name: "",
                    url: "",
                    streamUrl: "",
                    volume: config.defaultVolume,
                    hidden: false,
                    autoPlay: false,
                    rooms: [],
                    roomPatterns: [],
                    excludedRooms: []
                ),
                isAddMode: true,
                availableRooms: adminManager.serverRooms
            ) { stream in
                config.streams.append(stream)
                selectedStreamID = stream.id
            }
        }
        .sheet(item: $editingStream) { stream in
            StreamEditorSheet(
                title: "Edit Background Stream",
                stream: stream,
                isAddMode: false,
                availableRooms: adminManager.serverRooms
            ) { updated in
                guard let index = config.streams.firstIndex(where: { $0.id == updated.id }) else { return }
                config.streams[index] = updated
            }
        }
        .alert("Delete Stream?", isPresented: Binding(
            get: { pendingDeleteStream != nil },
            set: { if !$0 { pendingDeleteStream = nil } }
        ), actions: {
            Button("Delete", role: .destructive) {
                guard let stream = pendingDeleteStream else { return }
                config.streams.removeAll { $0.id == stream.id }
                if selectedStreamID == stream.id { selectedStreamID = nil }
                pendingDeleteStream = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteStream = nil
            }
        }, message: {
            Text("This removes the selected stream from server configuration.")
        })
    }

    private func scheduleAutosave(for nextConfig: BackgroundStreamsConfig) {
        autosaveTask?.cancel()
        autosaveStatus = "Saving stream changes shortly..."
        autosaveTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            await saveStreamsConfig(nextConfig, reason: "saved automatically")
        }
    }

    @MainActor
    private func saveStreamsConfig(_ nextConfig: BackgroundStreamsConfig, reason: String) async {
        isAutosaving = true
        let success = await adminManager.updateBackgroundStreamsConfig(nextConfig)
        if success {
            autosaveStatus = "Background stream changes \(reason)."
            Task {
                await adminManager.fetchServerConfig()
            }
        } else {
            autosaveStatus = "Unable to save background stream changes."
        }
        isAutosaving = false
    }
}

// MARK: - Stream Config Row
struct StreamConfigRow: View {
    let stream: BackgroundStreamConfig
    let onAction: (StreamAction) -> Void

    enum StreamAction {
        case edit, delete
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(stream.name)
                    .foregroundColor(.white)
                Text(stream.streamUrl)
                    .font(.caption)
                    .foregroundColor(.gray)

                HStack(spacing: 8) {
                    if stream.autoPlay {
                        Label("Auto-play", systemImage: "play.circle")
                    }
                    if stream.hidden {
                        Label("Hidden", systemImage: "eye.slash")
                    }
                    Text("Volume: \(stream.volume)%")
                    if let rooms = stream.rooms, !rooms.isEmpty {
                        Text("Rooms: \(rooms.count)")
                    }
                }
                .font(.caption2)
                .foregroundColor(.blue)
            }

            Spacer()

            Menu {
                Button(action: { onAction(.edit) }) {
                    Label("Edit", systemImage: "pencil")
                }
                Button(role: .destructive, action: { onAction(.delete) }) {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundColor(.gray)
            }
            .menuStyle(.borderlessButton)
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(10)
    }
}

struct StreamEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var serverManager = ServerManager.shared
    let title: String
    @State var stream: BackgroundStreamConfig
    let isAddMode: Bool
    let availableRooms: [AdminRoomInfo]
    let onSave: (BackgroundStreamConfig) -> Void
    @State private var selectedRooms: Set<String> = []
    @State private var roomPatternText: String = ""
    @State private var isResolvingName = false
    @State private var probeInput: String = ""
    @State private var probeResults: [AdminServerManager.StreamProbeResult] = []
    @State private var isProbing = false
    @State private var probeMessage = ""
    @StateObject private var previewPlayer = StreamPreviewPlayer()

    private var resolvedStreamURL: String {
        let primary = stream.streamUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !primary.isEmpty { return primary }
        return stream.url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sourceURL: String {
        stream.url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sourceLooksIndirect: Bool {
        let value = sourceURL.lowercased()
        return value.hasSuffix(".pls")
            || value.hasSuffix(".m3u")
            || value.hasSuffix(".m3u8")
            || value.contains("listen.pls")
            || value.contains("listen.m3u")
            || value.contains("playlist")
    }

    private var isEditedStreamPlayingInCurrentRoom: Bool {
        guard let media = serverManager.currentRoomMedia, media.active else { return false }
        let current = media.streamURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return false }
        return current.caseInsensitiveCompare(resolvedStreamURL) == .orderedSame
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Stream") {
                    TextField("Display name for this background stream", text: $stream.name)
                    TextField("Source URL such as playlist, station page, or direct stream", text: $stream.url)
                    TextField("Resolved direct stream URL used for playback", text: $stream.streamUrl)
                    if sourceLooksIndirect {
                        Text("This source looks like a playlist or wrapper URL. Keep it in Source URL and store the final playable stream in Resolved direct stream URL.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("If the source already points to the playable stream, you can use the same value for both fields or leave the resolved field blank until detection fills it.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Toggle("Auto-play in assigned rooms", isOn: $stream.autoPlay)
                    Toggle("Hide stream from regular users", isOn: $stream.hidden)
                    HStack {
                        Text("Volume")
                        Slider(value: Binding(
                            get: { Double(stream.volume) },
                            set: { stream.volume = Int($0) }
                        ), in: 0...100, step: 1)
                        Text("\(stream.volume)%")
                            .frame(width: 48)
                    }
                    HStack {
                        Button(previewPlayer.isPreviewing ? "Stop Preview" : "Preview Stream") {
                            if previewPlayer.isPreviewing {
                                previewPlayer.stop()
                            } else {
                                previewPlayer.play(urlString: resolvedStreamURL)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(resolvedStreamURL.isEmpty)

                        if !previewPlayer.status.isEmpty {
                            Text(previewPlayer.status)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("Detect Stream") {
                    HStack {
                        TextField("Website, playlist, stream domain, or direct stream URL", text: $probeInput)
                            .textFieldStyle(.roundedBorder)
                        Button(isProbing ? "Checking..." : "Detect") {
                            let input = probeInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !input.isEmpty else { return }
                            isProbing = true
                            probeMessage = ""
                            Task {
                                let results = await AdminServerManager.shared.probeBackgroundStreams(input: input)
                                probeResults = results
                                isProbing = false
                                probeMessage = results.isEmpty
                                    ? "No direct stream candidates were detected from that input."
                                    : "Choose the candidate that actually plays in the room."
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isProbing)
                    }

                    if !probeMessage.isEmpty {
                        Text(probeMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if !probeResults.isEmpty {
                        ForEach(probeResults) { candidate in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(candidate.name)
                                    Text(candidate.streamUrl)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Use") {
                                    let trimmedInput = probeInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !trimmedInput.isEmpty {
                                        stream.url = trimmedInput
                                    }
                                    stream.streamUrl = candidate.streamUrl
                                    if stream.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        stream.name = candidate.name
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }

                if serverManager.activeRoomId != nil {
                    Section("Current Room Playback") {
                        if isEditedStreamPlayingInCurrentRoom {
                            Text("This stream is playing in the room you are currently in.")
                                .foregroundColor(.green)
                            HStack {
                                Button("Stop Playing Here") {
                                    serverManager.stopCurrentRoomMedia()
                                }
                                .buttonStyle(.bordered)

                                Button(serverManager.isCurrentRoomMediaMuted ? "Unmute Stream" : "Mute Stream") {
                                    serverManager.toggleCurrentRoomMediaMuted()
                                }
                                .buttonStyle(.bordered)
                            }
                        } else {
                            Text("This stream is not currently playing in the room you are in.")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("Assign to Rooms") {
                    if availableRooms.isEmpty {
                        Text("No rooms available yet.")
                            .foregroundColor(.gray)
                    } else {
                        ForEach(availableRooms) { room in
                            Toggle(room.name, isOn: Binding(
                                get: { selectedRooms.contains(room.id) },
                                set: { enabled in
                                    if enabled { selectedRooms.insert(room.id) } else { selectedRooms.remove(room.id) }
                                }
                            ))
                        }
                    }
                }

                Section("Room Name Patterns") {
                    TextField("Optional comma-separated room patterns", text: $roomPatternText)
                    Text("Use patterns when a stream should attach to multiple rooms by naming rule.")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            isResolvingName = true
                            stream.rooms = Array(selectedRooms).sorted()
                            let patterns = roomPatternText
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                            stream.roomPatterns = patterns.isEmpty ? nil : patterns
                            let trimmedSource = stream.url.trimmingCharacters(in: .whitespacesAndNewlines)
                            let trimmedResolved = stream.streamUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmedSource.isEmpty && !trimmedResolved.isEmpty {
                                stream.url = trimmedResolved
                            }
                            if trimmedResolved.isEmpty && !trimmedSource.isEmpty {
                                stream.streamUrl = trimmedSource
                            }
                            if stream.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                stream.name = await detectStreamName(from: stream.streamUrl.isEmpty ? stream.url : stream.streamUrl)
                            }
                            isResolvingName = false
                            onSave(stream)
                            dismiss()
                        }
                    }
                    .disabled(isResolvingName || (stream.streamUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && stream.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
            .onAppear {
                selectedRooms = Set(stream.rooms ?? [])
                roomPatternText = (stream.roomPatterns ?? []).joined(separator: ", ")
                probeInput = stream.url.isEmpty ? stream.streamUrl : stream.url
            }
            .onDisappear {
                previewPlayer.stop()
            }
        }
        .frame(minWidth: 640, minHeight: 560)
    }

    private func detectStreamName(from rawURL: String) async -> String {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unnamed Stream" }
        guard let url = URL(string: trimmed) else {
            return inferredNameFromURL(trimmed)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        request.setValue("VoiceLink/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if let icyName = http.value(forHTTPHeaderField: "icy-name"), !icyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return icyName
                }
            }
        } catch {
            // Fall back to URL-derived naming.
        }
        return inferredNameFromURL(trimmed)
    }

    private func inferredNameFromURL(_ value: String) -> String {
        if let url = URL(string: value) {
            if let host = url.host, !host.isEmpty {
                return host.replacingOccurrences(of: "www.", with: "")
            }
            if !url.lastPathComponent.isEmpty {
                return url.lastPathComponent
            }
        }
        return "Unnamed Stream"
    }
}

@MainActor
final class StreamPreviewPlayer: ObservableObject {
    @Published var isPreviewing = false
    @Published var status = ""

    private var player: AVPlayer?

    func play(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            status = "Enter a valid stream URL first."
            return
        }

        stop()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.volume = 0.8
        self.player = player
        self.isPreviewing = true
        self.status = "Previewing stream..."
        player.play()
    }

    func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        isPreviewing = false
        status = ""
    }
}
