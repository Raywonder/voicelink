import AVFoundation
import SwiftUI

struct RoomSessionDestination: Identifiable, Hashable {
    let roomId: String
    let roomName: String
    let roomDescription: String
    let baseURL: String
    let displayName: String
    let backgroundStream: String
    let backgroundStreamVolume: Double
    let showChatByDefault: Bool
    let chatMessageOrder: String
    let chatMessageLimit: Int

    var id: String { "\(baseURL)|\(roomId)|join" }
}

struct RoomPreviewDestination: Identifiable, Hashable {
    let roomId: String
    let roomName: String
    let roomDescription: String
    let baseURL: String
    let room: RoomSummary

    var id: String { "\(baseURL)|\(roomId)|preview" }
}

struct RoomSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("voicelink.authToken") private var authToken = ""
    @AppStorage("voicelink.audio.inputGain") private var inputGain: Double = 1.0
    @AppStorage("voicelink.audio.outputGain") private var outputGain: Double = 1.0
    @AppStorage("voicelink.audio.mediaMuted") private var mediaMuted = false
    @AppStorage("voicelink.audio.inputMuted") private var inputMuted = false
    @AppStorage("voicelink.audio.roomOutputMuted") private var roomOutputMuted = false
    @AppStorage("voicelink.audio.noiseReductionEnabled") private var noiseReductionEnabled = true
    @AppStorage("voicelink.audio.echoCancellationEnabled") private var echoCancellationEnabled = true
    @AppStorage("voicelink.ios.showRoomRelayDebugDetails") private var showRoomRelayDebugDetails = false
    @AppStorage("voicelink.authProvider") private var authProvider = ""
    @AppStorage("voicelink.authUserJSON") private var authUserJSON = ""
    let destination: RoomSessionDestination
    @ObservedObject var roomState: IOSRoomMessagingState
    @ObservedObject private var socketClient = IOSNativeRoomSocketClient.shared
    @State private var showChat: Bool
    @State private var showDetails = false
    @State private var showControls = false
    @State private var showPeople = false
    @State private var showSettings = false
    @State private var showAudioControls = true
    @State private var showPeopleAudioState = true
    @State private var showDirectMessages = false
    @State private var whisperTarget: IOSDirectMessageTarget?
    @State private var monitorTarget: IOSDirectMessageTarget?
    @State private var replyTarget: IOSRoomMessageItem?
    @State private var joinSoundTask: Task<Void, Never>?
    @State private var memberRefreshTask: Task<Void, Never>?
    @State private var roomBackgroundPlayer: AVPlayer?
    @State private var roomBackgroundFadeTask: Task<Void, Never>?
    @State private var roomAudioDuckTask: Task<Void, Never>?
    @State private var draftMessage = ""
    @State private var draftDirectMessage = ""

    init(destination: RoomSessionDestination, roomState: IOSRoomMessagingState) {
        self.destination = destination
        self.roomState = roomState
        _showChat = State(initialValue: destination.showChatByDefault)
    }

    private var isSignedIn: Bool {
        !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var roomMessages: [IOSRoomMessageItem] {
        let roomItems = roomState.roomMessages
            .filter { $0.roomId == destination.roomId }
            .suffix(destination.chatMessageLimit)
        return destination.chatMessageOrder == "oldest-first"
            ? Array(roomItems)
            : Array(roomItems.reversed())
    }

    private var roomTranscripts: [IOSRoomTranscriptItem] {
        roomState.roomTranscripts
            .filter { $0.roomId == destination.roomId }
            .suffix(50)
            .reversed()
    }

    private var visibleRoomUsers: [IOSDirectMessageTarget] {
        var merged: [String: IOSDirectMessageTarget] = [:]
        socketClient.roomUsers.forEach { merged[$0.id] = $0 }
        roomState.directTargets.forEach { merged[$0.id] = $0 }
        return merged.values.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                peopleSection
                roomChatSection
                liveTranscriptsSection
                roomAudioSection
                settingsSection
            }
            .navigationTitle(destination.roomName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                roomActionsToolbarItem
            }
            .sheet(isPresented: $showDetails) { roomDetailsSheet }
            .sheet(isPresented: $showControls) { roomControlsSheet }
            .sheet(isPresented: $showPeople) { peopleSheet }
            .sheet(isPresented: $showSettings) { roomSettingsSheet }
            .sheet(isPresented: $showDirectMessages) { directMessagesSheet }
        }
        .onAppear {
            IOSAudioSessionManager.shared.activate(for: .room)
            socketClient.setPlaybackGain(Float(outputGain))
            syncRoomAudioState()
            startRoomBackgroundPlaybackIfNeeded()
            socketClient.startSession(
                baseURL: destination.baseURL,
                roomId: destination.roomId,
                roomName: destination.roomName,
                displayName: destination.displayName,
                authToken: authToken,
                authProvider: authProvider,
                authUserJSON: authUserJSON
            )
            joinSoundTask?.cancel()
            joinSoundTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled else { return }
                IOSActionSoundPlayer.playRoomJoin()
            }
            memberRefreshTask?.cancel()
            memberRefreshTask = Task { @MainActor in
                while !Task.isCancelled {
                    socketClient.requestRoomUsers()
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                }
            }
        }
        .onDisappear {
            joinSoundTask?.cancel()
            joinSoundTask = nil
            memberRefreshTask?.cancel()
            memberRefreshTask = nil
            roomBackgroundFadeTask?.cancel()
            roomBackgroundFadeTask = nil
            roomAudioDuckTask?.cancel()
            roomAudioDuckTask = nil
            stopRoomBackgroundPlayback()
            IOSAudioSessionManager.shared.deactivate(.room)
            socketClient.leaveRoom(roomId: destination.roomId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .iosRoomJoined)) { notification in
            let joinedRoomId = (notification.userInfo?["roomId"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard joinedRoomId == destination.roomId else { return }
            startRoomBackgroundPlaybackIfNeeded(forceRestart: true)
            socketClient.requestRoomUsers()
            socketClient.requestRoomMessages()
        }
        .onReceive(NotificationCenter.default.publisher(for: .iosPlayTestSound)) { _ in
            playTestSoundWithRoomDuck()
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            LabeledContent("Room", value: destination.roomName)
            if showRoomRelayDebugDetails {
                LabeledContent("Status", value: socketClient.connectionStatus)
            }
            if !destination.roomDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(destination.roomDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var peopleSection: some View {
        Section("People in Room") {
            if visibleRoomUsers.isEmpty {
                Text("No room users reported yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleRoomUsers) { target in
                    roomUserRow(for: target, includeRoleBadges: true)
                }
            }
        }
    }

    @ViewBuilder
    private var roomChatSection: some View {
        if showChat {
            Section("Room Chat") {
                if roomMessages.isEmpty {
                    Text("No room messages yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(roomMessages)) { message in
                        roomMessageRow(for: message)
                    }
                }
            }

            Section("Send Message") {
                if let replyTarget {
                    HStack {
                        Text("Replying to \(replyTarget.author)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") {
                            self.replyTarget = nil
                            IOSActionSoundPlayer.playClose()
                        }
                    }
                }
                TextField("Type a room message", text: $draftMessage, axis: .vertical)
                    .lineLimit(1...4)
                Button("Send to Room") {
                    sendRoomMessage()
                }
                .disabled(draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var liveTranscriptsSection: some View {
        Section("Live Transcripts") {
            if roomTranscripts.isEmpty {
                Text("No transcripts yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(roomTranscripts)) { transcript in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(transcript.speaker)
                            .font(.subheadline.weight(.semibold))
                        Text(transcript.body)
                            .font(.body)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var roomAudioSection: some View {
        if showAudioControls {
            Section("Audio") {
                if showRoomRelayDebugDetails {
                    LabeledContent("Relay", value: socketClient.audioRelayStatus)
                }
                LabeledContent("Whisper Target", value: whisperTarget?.name ?? "None")
                Toggle("Mute Microphone", isOn: $inputMuted)
                    .onChange(of: inputMuted) { _ in
                        syncRoomAudioState()
                        IOSActionSoundPlayer.playToggle()
                    }
                Toggle("Mute Room Output", isOn: $roomOutputMuted)
                    .onChange(of: roomOutputMuted) { _ in
                        syncRoomAudioState()
                        IOSActionSoundPlayer.playToggle()
                    }
                Slider(value: $outputGain, in: 0...3) {
                    Text("Output Volume")
                } minimumValueLabel: {
                    Text("0%")
                } maximumValueLabel: {
                    Text("300%")
                }
                .accessibilityValue("\(Int(outputGain * 100)) percent")
                .onChange(of: outputGain) { newValue in
                    socketClient.setPlaybackGain(Float(newValue))
                    updateRoomBackgroundPlaybackVolume()
                }
                Toggle("Mute Media Playback", isOn: $mediaMuted)
                    .onChange(of: mediaMuted) { _ in
                        syncRoomBackgroundPlaybackState()
                        IOSActionSoundPlayer.playToggle()
                    }
                Toggle("Noise Reduction", isOn: $noiseReductionEnabled)
                    .onChange(of: noiseReductionEnabled) { _ in
                        IOSAudioSessionManager.shared.refreshActiveSessionConfiguration()
                        IOSActionSoundPlayer.playToggle()
                    }
                Toggle("Echo Cancellation", isOn: $echoCancellationEnabled)
                    .onChange(of: echoCancellationEnabled) { _ in
                        IOSAudioSessionManager.shared.refreshActiveSessionConfiguration()
                        IOSActionSoundPlayer.playToggle()
                    }
                Text("Press and hold a person to mark a whisper target. Relay playback ducks to 25% while a whisper target is active so that direct talk is easier to follow.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var settingsSection: some View {
        Section {
            Button("Open Full Settings") {
                showSettings = true
                IOSActionSoundPlayer.playConfirm()
            }
        }
    }

    private var roomActionsToolbarItem: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showSettings = true
                IOSActionSoundPlayer.playConfirm()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .accessibilityLabel("App Settings")
            .accessibilityHint("Open full settings without leaving the room.")

            Menu {
                Button(showChat ? "Hide Chat" : "Show Chat") {
                    showChat.toggle()
                    IOSActionSoundPlayer.playToggle()
                }
                Button("Room Settings") {
                    showControls = true
                    IOSActionSoundPlayer.playConfirm()
                }
                Button("App Settings") {
                    showSettings = true
                    IOSActionSoundPlayer.playConfirm()
                }
                Button("People in Room") {
                    socketClient.requestRoomUsers()
                    showPeople = true
                    IOSActionSoundPlayer.playConfirm()
                }
                Button("Room Details") {
                    showDetails = true
                    IOSActionSoundPlayer.playConfirm()
                }
                Button(showAudioControls ? "Hide Audio Controls" : "Show Audio Controls") {
                    showAudioControls.toggle()
                    IOSActionSoundPlayer.playToggle()
                }
                Button(showPeopleAudioState ? "Hide User Audio State" : "Show User Audio State") {
                    showPeopleAudioState.toggle()
                    IOSActionSoundPlayer.playToggle()
                }
                Divider()
                Button("Leave Room", role: .destructive) {
                    IOSActionSoundPlayer.playClose()
                    socketClient.leaveRoom(roomId: destination.roomId)
                    dismiss()
                }
            } label: {
                Label("Room Actions", systemImage: "line.3.horizontal.circle.fill")
                    .font(.headline.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
            }
            .accessibilityLabel("Room Actions")
            .accessibilityHint("Opens room actions including chat, people, room details, app settings, room settings, and leave room.")
        }
    }

    private var roomDetailsSheet: some View {
        NavigationStack {
            List {
                Section("Room") {
                    LabeledContent("Name", value: destination.roomName)
                    LabeledContent("Room ID", value: destination.roomId)
                    Text(destination.roomDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No description provided." : destination.roomDescription)
                }
            }
            .navigationTitle("Room Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { showDetails = false }
                }
            }
        }
    }

    private var roomControlsSheet: some View {
        NavigationStack {
            Form {
                Section("Room Controls") {
                    Toggle("Show Chat", isOn: $showChat)
                        .onChange(of: showChat) { _ in
                            IOSActionSoundPlayer.playToggle()
                        }
                    Toggle("Show Audio Controls", isOn: $showAudioControls)
                        .onChange(of: showAudioControls) { _ in
                            IOSActionSoundPlayer.playToggle()
                        }
                    Toggle("Show User Audio State", isOn: $showPeopleAudioState)
                        .onChange(of: showPeopleAudioState) { _ in
                            IOSActionSoundPlayer.playToggle()
                        }
                }

                Section("Audio") {
                    Toggle("Mute Microphone", isOn: $inputMuted)
                        .onChange(of: inputMuted) { _ in
                            syncRoomAudioState()
                            IOSActionSoundPlayer.playToggle()
                        }
                    Toggle("Mute Room Output", isOn: $roomOutputMuted)
                        .onChange(of: roomOutputMuted) { _ in
                            syncRoomAudioState()
                            IOSActionSoundPlayer.playToggle()
                        }
                    Slider(value: $inputGain, in: 0...3) {
                        Text("Mic Level")
                    } minimumValueLabel: {
                        Text("0%")
                    } maximumValueLabel: {
                        Text("300%")
                    }
                    .accessibilityValue("\(Int(inputGain * 100)) percent")

                    Slider(value: $outputGain, in: 0...3) {
                        Text("Master Output")
                    } minimumValueLabel: {
                        Text("0%")
                    } maximumValueLabel: {
                        Text("300%")
                    }
                    .accessibilityValue("\(Int(outputGain * 100)) percent")

                    Toggle("Mute Media Playback", isOn: $mediaMuted)
                        .onChange(of: mediaMuted) { _ in
                            syncRoomBackgroundPlaybackState()
                            IOSActionSoundPlayer.playToggle()
                        }
                    Toggle("Noise Reduction", isOn: $noiseReductionEnabled)
                        .onChange(of: noiseReductionEnabled) { _ in
                            IOSAudioSessionManager.shared.refreshActiveSessionConfiguration()
                            IOSActionSoundPlayer.playToggle()
                        }
                    Toggle("Echo Cancellation", isOn: $echoCancellationEnabled)
                        .onChange(of: echoCancellationEnabled) { _ in
                            IOSAudioSessionManager.shared.refreshActiveSessionConfiguration()
                            IOSActionSoundPlayer.playToggle()
                        }
                    Text("Voice processing mode is enabled when Noise Reduction or Echo Cancellation is on. Turn both off for raw monitoring.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button(whisperTarget == nil ? "No Whisper Target" : "Clear Whisper Target") {
                        whisperTarget = nil
                        socketClient.setPlaybackDuckScale(1.0)
                        IOSActionSoundPlayer.playToggle()
                    }
                    .disabled(whisperTarget == nil)

                    Button(monitorTarget == nil ? "No Monitor Target" : "Clear Monitor Target") {
                        monitorTarget = nil
                        socketClient.setMonitorUserId(nil)
                        IOSActionSoundPlayer.playToggle()
                    }
                    .disabled(monitorTarget == nil)
                }
            }
            .navigationTitle("Room Controls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { showControls = false }
                }
            }
        }
    }

    private var peopleSheet: some View {
        NavigationStack {
            List {
                Section("People in Room") {
                    if visibleRoomUsers.isEmpty {
                        Text("No room users reported yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleRoomUsers) { target in
                            roomUserRow(for: target, includeRoleBadges: false)
                        }
                    }
                }
            }
            .navigationTitle("People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { showPeople = false }
                }
            }
        }
    }

    private var directMessagesSheet: some View {
        NavigationStack {
            List {
                Section("Conversation") {
                    if let target = roomState.selectedDirectTarget {
                        LabeledContent("To", value: target.name)
                    }
                    TextField("Type a private message", text: $draftDirectMessage, axis: .vertical)
                        .lineLimit(1...5)
                    Button("Send Direct Message") {
                        roomState.sendDirectMessage(draftDirectMessage)
                        draftDirectMessage = ""
                        IOSActionSoundPlayer.playConfirm()
                    }
                    .disabled(draftDirectMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle(roomState.selectedDirectTarget?.name ?? "Direct Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        showDirectMessages = false
                    }
                }
            }
        }
    }

    private var roomSettingsSheet: some View {
        SettingsTab(roomState: roomState, openServers: {})
    }

    private func roomUserRow(for target: IOSDirectMessageTarget, includeRoleBadges: Bool) -> some View {
        Button {
            openProfile(for: target)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: iosUserAudioIconName(target))
                    .foregroundStyle(target.isSpeaking ? .green : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(target.name)
                        .font(.body)
                    if showPeopleAudioState {
                        Text(roomAudioStatusLabel(for: target))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        userAudioLevelMeter(for: target)
                    }
                    if let deviceSummary = iosUserDeviceSummary(target) {
                        Text(deviceSummary)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if includeRoleBadges {
                    if whisperTarget?.id == target.id {
                        Text("Whisper")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    } else if monitorTarget?.id == target.id {
                        Text("Monitor")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(roomUserAccessibilityLabel(for: target))
        .accessibilityValue(roomUserAccessibilityValue(for: target))
        .contextMenu {
            Button("View Profile") {
                openProfile(for: target)
            }
            Button("Direct Message \(target.name)") {
                openDirectMessages(with: target)
            }
            Button(whisperTarget?.id == target.id ? "Stop Whisper Target" : "Whisper to \(target.name)") {
                toggleWhisperTarget(target)
            }
            Button(monitorTarget?.id == target.id ? "Stop Monitoring \(target.name)" : "Monitor \(target.name)") {
                toggleMonitorTarget(target)
            }
            Button(showPeopleAudioState ? "Hide User Audio State" : "Show User Audio State") {
                showPeopleAudioState.toggle()
                IOSActionSoundPlayer.playToggle()
            }
            Button(showAudioControls ? "Hide Audio Controls" : "Show Audio Controls") {
                showAudioControls.toggle()
                IOSActionSoundPlayer.playToggle()
            }
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.55)
                .onEnded { _ in
                    toggleWhisperTarget(target)
                }
        )
        .accessibilityHint("Double tap to open this user's profile. Press and hold to set or clear whisper target. Open the context menu for direct messages and audio controls.")
        .accessibilityAction(named: Text("View Profile")) {
            openProfile(for: target)
        }
        .accessibilityAction(named: Text("Direct Message")) {
            openDirectMessages(with: target)
        }
        .accessibilityAction(named: Text(monitorTarget?.id == target.id ? "Stop Monitoring" : "Start Monitoring")) {
            toggleMonitorTarget(target)
        }
        .accessibilityAction(named: Text(whisperTarget?.id == target.id ? "Stop Whisper" : "Start Whisper")) {
            toggleWhisperTarget(target)
        }
    }

    private func roomMessageRow(for message: IOSRoomMessageItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.author)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(message.isSystemMessage ? .orange : (message.isBotMessage ? .blue : .primary))
            Text(iosMarkdownMessageText(message.body))
                .font(.body)
            if let replyTarget, replyTarget.id == message.id {
                Text("Replying to this message")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if message.isSystemMessage {
                Text("System message")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else if message.isBotMessage {
                Text("Bot message")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Reply to \(message.author)") {
                replyTarget = message
                draftMessage = "@\(message.author) "
                IOSActionSoundPlayer.playConfirm()
            }
            if let target = visibleRoomUsers.first(where: { $0.name == message.author }) {
                Button("Direct Message \(target.name)") {
                    openDirectMessages(with: target)
                }
            }
        }
    }

    private func userAudioLevelMeter(for target: IOSDirectMessageTarget) -> some View {
        let level = max(0, min(1, socketClient.userAudioLevels[target.id] ?? 0))
        let percent = Int(level * 100)

        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Audio Level")
                    .font(.caption2)
                Spacer()
                Text("\(percent)%")
                    .font(.caption2.monospacedDigit())
            }
            ProgressView(value: Double(level), total: 1.0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio level for \(target.name)")
        .accessibilityValue("\(percent) percent")
    }

    private func openProfile(for target: IOSDirectMessageTarget) {
        roomState.selectedDirectTarget = target
        roomState.selectedProfileName = target.name
        NotificationCenter.default.post(
            name: .iosShowUserProfile,
            object: nil,
            userInfo: ["userId": target.id, "userName": target.name]
        )
        IOSActionSoundPlayer.playConfirm()
    }

    private func sendRoomMessage() {
        let body = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let outgoingBody = replyTarget == nil ? body : "> \(replyTarget?.author ?? "User"): \(replyTarget?.body ?? "")\n\n\(body)"
        socketClient.sendRoomMessage(outgoingBody)
        draftMessage = ""
        replyTarget = nil
        IOSActionSoundPlayer.playConfirm()
    }

    private func openDirectMessages(with target: IOSDirectMessageTarget) {
        roomState.selectedDirectTarget = target
        roomState.selectedProfileName = target.name
        showDirectMessages = true
        IOSActionSoundPlayer.playConfirm()
    }

    private func toggleWhisperTarget(_ target: IOSDirectMessageTarget) {
        if whisperTarget?.id == target.id {
            whisperTarget = nil
            socketClient.setPlaybackDuckScale(1.0)
            updateRoomBackgroundPlaybackVolume()
            roomState.statusText = "Whisper target cleared."
        } else {
            whisperTarget = target
            roomState.selectedDirectTarget = target
            roomState.selectedProfileName = target.name
            socketClient.setPlaybackDuckScale(0.25)
            updateRoomBackgroundPlaybackVolume()
            roomState.statusText = "Whisper target set to \(target.name)."
        }
        IOSActionSoundPlayer.playToggle()
    }

    private func toggleMonitorTarget(_ target: IOSDirectMessageTarget) {
        if monitorTarget?.id == target.id {
            monitorTarget = nil
            socketClient.setMonitorUserId(nil)
            roomState.statusText = "Stopped monitoring \(target.name)."
        } else {
            monitorTarget = target
            roomState.selectedDirectTarget = target
            roomState.selectedProfileName = target.name
            socketClient.setMonitorUserId(target.id)
            roomState.statusText = "Monitoring \(target.name)."
        }
        IOSActionSoundPlayer.playToggle()
    }

    private func startRoomBackgroundPlaybackIfNeeded(forceRestart: Bool = false) {
        let streamURL = destination.backgroundStream.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !streamURL.isEmpty, let url = URL(string: streamURL) else {
            roomBackgroundPlayer = nil
            return
        }
        if !forceRestart,
           let existingPlayer = roomBackgroundPlayer,
           let existingURL = (existingPlayer.currentItem?.asset as? AVURLAsset)?.url,
           existingURL.standardizedFileURL == url.standardizedFileURL {
            syncRoomBackgroundPlaybackState()
            return
        }
        roomBackgroundPlayer?.pause()
        let player = AVPlayer(url: url)
        roomBackgroundPlayer = player
        updateRoomBackgroundPlaybackVolume()
        if !mediaMuted {
            player.play()
        }
    }

    private func syncRoomBackgroundPlaybackState() {
        guard let roomBackgroundPlayer else { return }
        updateRoomBackgroundPlaybackVolume()
        if mediaMuted {
            roomBackgroundPlayer.pause()
        } else {
            roomBackgroundPlayer.play()
        }
    }

    private func syncRoomAudioState() {
        socketClient.setInputMuted(inputMuted)
        socketClient.setOutputMuted(roomOutputMuted)
    }

    private func updateRoomBackgroundPlaybackVolume() {
        let roomVolume = max(0, min(3, destination.backgroundStreamVolume / 100.0))
        let duckScale = whisperTarget == nil ? 1.0 : 0.25
        roomBackgroundPlayer?.volume = mediaMuted ? 0 : Float(max(0, min(3, outputGain * roomVolume * duckScale)))
    }

    private func fadeRoomBackgroundVolume(to targetVolume: Float, durationSeconds: Double) {
        roomBackgroundFadeTask?.cancel()
        guard let player = roomBackgroundPlayer else { return }
        let startVolume = player.volume
        let steps = 10
        let stepDuration = max(0.02, durationSeconds / Double(steps))
        roomBackgroundFadeTask = Task { @MainActor in
            for step in 1...steps {
                guard !Task.isCancelled else { return }
                let progress = Float(step) / Float(steps)
                player.volume = startVolume + (targetVolume - startVolume) * progress
                try? await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))
            }
            player.volume = targetVolume
        }
    }

    private func playTestSoundWithRoomDuck() {
        roomAudioDuckTask?.cancel()
        let restoredGain = Float(outputGain)
        fadeRoomBackgroundVolume(to: 0, durationSeconds: 0.18)
        socketClient.setPlaybackGain(max(0, restoredGain * 0.2))
        IOSActionSoundPlayer.playTest()
        roomAudioDuckTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            socketClient.setPlaybackGain(restoredGain)
            updateRoomBackgroundPlaybackVolume()
            fadeRoomBackgroundVolume(
                to: mediaMuted ? 0 : Float(max(0, min(3, outputGain * max(0, min(3, destination.backgroundStreamVolume / 100.0)) * (whisperTarget == nil ? 1.0 : 0.25)))),
                durationSeconds: 0.22
            )
        }
    }

    private func stopRoomBackgroundPlayback() {
        roomBackgroundPlayer?.pause()
        roomBackgroundPlayer = nil
    }

    private func roomAudioStatusLabel(for target: IOSDirectMessageTarget) -> String {
        var labels: [String] = []
        if target.isSpeaking {
            labels.append("Speaking")
        }
        if target.isMuted || !target.transmitEnabled {
            labels.append("Mic muted")
        }
        if target.isDeafened {
            labels.append("Output muted")
        }
        return labels.isEmpty ? "Available" : labels.joined(separator: " · ")
    }

    private func roomUserAccessibilityLabel(for target: IOSDirectMessageTarget) -> String {
        var parts = [target.name, roomAudioStatusLabel(for: target)]
        if let deviceSummary = iosUserDeviceSummary(target) {
            parts.append(deviceSummary)
        }
        return parts.joined(separator: ", ")
    }

    private func roomUserAccessibilityValue(for target: IOSDirectMessageTarget) -> String {
        if whisperTarget?.id == target.id {
            return "Whisper target"
        }
        if monitorTarget?.id == target.id {
            return "Monitor target"
        }
        return ""
    }
}

struct RoomPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let destination: RoomPreviewDestination
    @State private var previewPlayer: AVPlayer?
    @State private var closeTask: Task<Void, Never>?
    @State private var fadeTask: Task<Void, Never>?
    @State private var previewSecondsRemaining = 12

    var body: some View {
        NavigationStack {
            List {
                Section("Preview") {
                    LabeledContent("Room", value: destination.roomName)
                    LabeledContent("Preview Time Remaining", value: "\(previewSecondsRemaining)s")
                }
            }
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            IOSAudioSessionManager.shared.activate(for: .preview)
            IOSActionSoundPlayer.playPreviewStart()
            startPreviewPlayback()
            scheduleAutoClose()
        }
        .onDisappear {
            closeTask?.cancel()
            closeTask = nil
            fadeTask?.cancel()
            fadeTask = nil
            stopPreviewPlayback()
            IOSAudioSessionManager.shared.deactivate(.preview)
        }
    }

    private func startPreviewPlayback() {
        let streamURL = destination.room.backgroundStream.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !streamURL.isEmpty, let url = URL(string: streamURL) else {
            return
        }
        let player = AVPlayer(url: url)
        player.volume = 0
        previewPlayer = player
        player.play()
        fadePreviewVolume(to: 1.0, durationSeconds: 0.8)
    }

    private func stopPreviewPlayback() {
        guard let previewPlayer else { return }
        previewPlayer.pause()
        self.previewPlayer = nil
    }

    private func scheduleAutoClose() {
        closeTask?.cancel()
        previewSecondsRemaining = 12
        closeTask = Task { @MainActor in
            for second in stride(from: 12, to: 0, by: -1) {
                previewSecondsRemaining = second
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
            }
            previewSecondsRemaining = 0
            IOSActionSoundPlayer.playPreviewStop()
            await fadePreviewOutAndStop()
            dismiss()
        }
    }

    private func fadePreviewOutAndStop() async {
        fadePreviewVolume(to: 0, durationSeconds: 0.8)
        try? await Task.sleep(nanoseconds: 850_000_000)
        guard !Task.isCancelled else { return }
        stopPreviewPlayback()
    }

    private func fadePreviewVolume(to targetVolume: Float, durationSeconds: Double) {
        fadeTask?.cancel()
        guard let player = previewPlayer else { return }
        let startVolume = player.volume
        let steps = 12
        let stepDuration = max(0.02, durationSeconds / Double(steps))
        fadeTask = Task { @MainActor in
            for step in 1...steps {
                guard !Task.isCancelled else { return }
                let progress = Float(step) / Float(steps)
                player.volume = startVolume + (targetVolume - startVolume) * progress
                try? await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))
            }
            player.volume = targetVolume
        }
    }
}

extension Notification.Name {
    static let iosOpenMessagesTab = Notification.Name("iosOpenMessagesTab")
    static let iosShowUserProfile = Notification.Name("iosShowUserProfile")
    static let iosPlayTestSound = Notification.Name("iosPlayTestSound")
    static let iosRoomJoined = Notification.Name("iosRoomJoined")
    static let iosRoomLeft = Notification.Name("iosRoomLeft")
    static let iosRoomUsersUpdated = Notification.Name("iosRoomUsersUpdated")
    static let iosRoomMessageEvent = Notification.Name("iosRoomMessageEvent")
    static let iosDirectMessageEvent = Notification.Name("iosDirectMessageEvent")
    static let iosRoomTranscriptEvent = Notification.Name("iosRoomTranscriptEvent")
    static let iosRequestLeaveRoom = Notification.Name("iosRequestLeaveRoom")
    static let iosSendDirectMessage = Notification.Name("iosSendDirectMessage")
    static let iosSetRoomChatVisibility = Notification.Name("iosSetRoomChatVisibility")
}

private func iosMarkdownMessageText(_ body: String) -> AttributedString {
    let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedBody.isEmpty else {
        return AttributedString("")
    }
    if let attributed = try? AttributedString(markdown: trimmedBody, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
        return attributed
    }
    return AttributedString(trimmedBody)
}
