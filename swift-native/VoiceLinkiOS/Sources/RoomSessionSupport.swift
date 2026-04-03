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
    @AppStorage("voicelink.authProvider") private var authProvider = ""
    @AppStorage("voicelink.authUserJSON") private var authUserJSON = ""
    let destination: RoomSessionDestination
    @ObservedObject var roomState: IOSRoomMessagingState
    @ObservedObject private var socketClient = IOSNativeRoomSocketClient.shared
    @State private var showChat: Bool
    @State private var showDetails = false
    @State private var showControls = false
    @State private var showPeople = false
    @State private var showAudioControls = true
    @State private var showDirectMessages = false
    @State private var whisperTarget: IOSDirectMessageTarget?
    @State private var joinSoundTask: Task<Void, Never>?
    @State private var memberRefreshTask: Task<Void, Never>?
    @State private var roomBackgroundPlayer: AVPlayer?
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

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    LabeledContent("Room", value: destination.roomName)
                    LabeledContent("Status", value: socketClient.connectionStatus)
                    if !destination.roomDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(destination.roomDescription)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("People in Room") {
                    if roomState.directTargets.isEmpty {
                        Text("No room users reported yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(roomState.directTargets) { target in
                            Button {
                                openProfile(for: target)
                            } label: {
                                HStack(alignment: .center, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(target.name)
                                            .font(.body)
                                        Text(roomAudioStatusLabel(for: target))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if whisperTarget?.id == target.id {
                                        Text("Whisper")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
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
                            .accessibilityAction(named: Text(whisperTarget?.id == target.id ? "Stop Whisper" : "Start Whisper")) {
                                toggleWhisperTarget(target)
                            }
                        }
                    }
                }

                if showChat {
                    Section("Send Message") {
                        TextField("Type a room message", text: $draftMessage, axis: .vertical)
                            .lineLimit(1...4)
                        Button("Send to Room") {
                            let body = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !body.isEmpty else { return }
                            socketClient.sendRoomMessage(body)
                            draftMessage = ""
                            IOSActionSoundPlayer.playConfirm()
                        }
                        .disabled(draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Section("Direct Messages") {
                        if let target = roomState.selectedDirectTarget {
                            LabeledContent("Current Thread", value: target.name)
                            Button("Open Conversation with \(target.name)") {
                                openDirectMessages(with: target)
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Text("Open a person from the room list to start a direct conversation.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Recent Room Messages") {
                        if roomMessages.isEmpty {
                            Text("No room messages yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(roomMessages)) { message in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(message.author)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(message.isSystemMessage ? .orange : .primary)
                                    Text(iosMarkdownMessageText(message.body))
                                        .font(.body)
                                    if message.isSystemMessage {
                                        Text("System message")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }

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

                if showAudioControls {
                    Section("Audio") {
                        LabeledContent("Relay", value: socketClient.audioRelayStatus)
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
                            .onChange(of: mediaMuted) { muted in
                                _ = muted
                                syncRoomBackgroundPlaybackState()
                                IOSActionSoundPlayer.playToggle()
                            }
                        Text("Press and hold a person to mark a whisper target. Relay playback ducks to 25% while a whisper target is active so that direct talk is easier to follow.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Settings") {
                    Text("Settings stay available in-room here so volume and room chat controls can be changed without leaving the session.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(destination.roomName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(showChat ? "Hide Chat" : "Show Chat") {
                            showChat.toggle()
                            IOSActionSoundPlayer.playToggle()
                        }
                        Button("Room Settings") {
                            showControls = true
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
                        Divider()
                        Button("Leave Room", role: .destructive) {
                            IOSActionSoundPlayer.playClose()
                            socketClient.leaveRoom(roomId: destination.roomId)
                            dismiss()
                        }

                        if isSignedIn {
                            // Reserved for future signed-in room actions parity.
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
                    .accessibilityHint("Opens room actions including chat, people, room details, room settings, and leave room.")
                }
            }
            .sheet(isPresented: $showDetails) {
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
            .sheet(isPresented: $showControls) {
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
                            Button(whisperTarget == nil ? "No Whisper Target" : "Clear Whisper Target") {
                                whisperTarget = nil
                                socketClient.setPlaybackDuckScale(1.0)
                                IOSActionSoundPlayer.playToggle()
                            }
                            .disabled(whisperTarget == nil)
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
            .sheet(isPresented: $showPeople) {
                NavigationStack {
                    List {
                        Section("People in Room") {
                            if roomState.directTargets.isEmpty {
                                Text("No room users reported yet.")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(roomState.directTargets) { target in
                                    Button {
                                        openProfile(for: target)
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(target.name)
                                                    .font(.body)
                                                Text(roomAudioStatusLabel(for: target))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                        }
                                    }
                                    .contextMenu {
                                        Button("Direct Message \(target.name)") {
                                            openDirectMessages(with: target)
                                        }
                                        Button(whisperTarget?.id == target.id ? "Stop Whisper Target" : "Whisper to \(target.name)") {
                                            toggleWhisperTarget(target)
                                        }
                                    }
                                    .simultaneousGesture(
                                        LongPressGesture(minimumDuration: 0.55)
                                            .onEnded { _ in
                                                toggleWhisperTarget(target)
                                            }
                                    )
                                    .accessibilityHint("Double tap to open this profile. Press and hold to set or clear whisper target.")
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
            .sheet(isPresented: $showDirectMessages) {
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

                        Section("Status") {
                            Text(roomState.statusText.isEmpty ? "Private conversation window is open." : roomState.statusText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
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
            stopRoomBackgroundPlayback()
            IOSAudioSessionManager.shared.deactivate(.room)
            socketClient.leaveRoom(roomId: destination.roomId)
        }
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

    private func startRoomBackgroundPlaybackIfNeeded() {
        let streamURL = destination.backgroundStream.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !streamURL.isEmpty, let url = URL(string: streamURL) else {
            roomBackgroundPlayer = nil
            return
        }
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
}

struct RoomPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let destination: RoomPreviewDestination
    @State private var previewPlayer: AVPlayer?
    @State private var closeTask: Task<Void, Never>?
    @State private var previewSecondsRemaining = 12

    var body: some View {
        NavigationStack {
            List {
                Section("Preview") {
                    LabeledContent("Room", value: destination.roomName)
                    LabeledContent("Users", value: "\(destination.room.userCount)")
                    LabeledContent("Auto Close", value: "\(previewSecondsRemaining)s")
                    Text(destination.roomDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No description provided." : destination.roomDescription)
                        .foregroundStyle(.secondary)
                }

                Section("Status") {
                    Group {
                        if destination.room.backgroundStream.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("No room background stream is available to preview right now. This screen closes automatically after a short review window.")
                        } else {
                            Text("Playing this room’s background stream briefly so you can review it before joining. Preview closes automatically after a short review window.")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            IOSAudioSessionManager.shared.activate(for: .preview)
            IOSActionSoundPlayer.playConfirm()
            startPreviewPlayback()
            scheduleAutoClose()
        }
        .onDisappear {
            closeTask?.cancel()
            closeTask = nil
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
        previewPlayer = player
        player.play()
    }

    private func stopPreviewPlayback() {
        previewPlayer?.pause()
        previewPlayer = nil
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
            stopPreviewPlayback()
            IOSActionSoundPlayer.playClose()
            dismiss()
        }
    }
}

extension Notification.Name {
    static let iosOpenMessagesTab = Notification.Name("iosOpenMessagesTab")
    static let iosShowUserProfile = Notification.Name("iosShowUserProfile")
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
