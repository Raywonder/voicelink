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
    let canManageRooms: Bool

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
    @Environment(\.openURL) private var openURL
    @AppStorage("voicelink.authToken") private var authToken = ""
    @AppStorage("voicelink.audio.inputGain") private var inputGain: Double = 1.0
    @AppStorage("voicelink.audio.outputGain") private var outputGain: Double = 1.0
    @AppStorage("voicelink.audio.mediaMuted") private var mediaMuted = false
    @AppStorage("voicelink.audio.inputMuted") private var inputMuted = false
    @AppStorage("voicelink.audio.roomOutputMuted") private var roomOutputMuted = false
    @AppStorage("voicelink.audio.mode") private var audioMode = IOSVoiceLinkAudioMode.original.rawValue
    @AppStorage("voicelink.audio.noiseReductionEnabled") private var noiseReductionEnabled = false
    @AppStorage("voicelink.audio.echoCancellationEnabled") private var echoCancellationEnabled = false
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
    @State private var showRoomAdmin = false
    @State private var showAudioControls = true
    @State private var showPeopleAudioState = true
    @State private var expandedUserAudioControls: Set<String> = []
    @State private var showRoomMessages = false
    @State private var showDirectMessages = false
    @State private var selectedProfileTarget: IOSDirectMessageTarget?
    @State private var whisperTarget: IOSDirectMessageTarget?
    @State private var monitorTarget: IOSDirectMessageTarget?
    @State private var replyTarget: IOSRoomMessageItem?
    @State private var keepRoomAliveDuringInterfaceChange = false
    @State private var keepRoomAliveResetTask: Task<Void, Never>?
    @State private var joinSoundTask: Task<Void, Never>?
    @State private var memberRefreshTask: Task<Void, Never>?
    @State private var roomBackgroundPlayer: AVPlayer?
    @State private var roomBackgroundFadeTask: Task<Void, Never>?
    @State private var roomAudioDuckTask: Task<Void, Never>?
    @State private var draftMessage = ""
    @State private var draftDirectMessage = ""
    @State private var canManageRooms: Bool

    init(destination: RoomSessionDestination, roomState: IOSRoomMessagingState) {
        self.destination = destination
        self.roomState = roomState
        _showChat = State(initialValue: destination.showChatByDefault)
        _canManageRooms = State(initialValue: destination.canManageRooms)
    }

    private var isSignedIn: Bool {
        !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var roomMessages: [IOSRoomMessageItem] {
        let targetRoomId = normalizedIOSRoomIdentity(destination.roomId)
        let targetRoomName = normalizedIOSRoomIdentity(destination.roomName)
        let roomItems = roomState.roomMessages
            .filter { message in
                let messageRoomId = normalizedIOSRoomIdentity(message.roomId)
                let messageRoomName = normalizedIOSRoomIdentity(message.roomName)
                return messageRoomId == targetRoomId || messageRoomName == targetRoomName
            }
            .suffix(max(destination.chatMessageLimit, 150))
        return destination.chatMessageOrder == "oldest-first"
            ? Array(roomItems)
            : Array(roomItems.reversed())
    }

    private var roomTranscripts: [IOSRoomTranscriptItem] {
        let targetRoomId = normalizedIOSRoomIdentity(destination.roomId)
        let targetRoomName = normalizedIOSRoomIdentity(destination.roomName)
        return roomState.roomTranscripts
            .filter { transcript in
                let transcriptRoomId = normalizedIOSRoomIdentity(transcript.roomId)
                let transcriptRoomName = normalizedIOSRoomIdentity(transcript.roomName)
                return transcriptRoomId == targetRoomId || transcriptRoomName == targetRoomName
            }
            .suffix(50)
            .reversed()
    }

    private var visibleRoomUsers: [IOSDirectMessageTarget] {
        iosMergedVisibleTargets(primary: roomState.directTargets, secondary: socketClient.roomUsers)
    }

    private var visibleHumanRoomUsers: [IOSDirectMessageTarget] {
        visibleRoomUsers.filter { !$0.isBot }
    }

    private var visibleBotRoomUsers: [IOSDirectMessageTarget] {
        visibleRoomUsers.filter { $0.isBot }
    }

    private var isPresentingAuxiliarySheet: Bool {
        showDetails
            || showControls
            || showPeople
            || showSettings
            || showRoomAdmin
            || showRoomMessages
            || showDirectMessages
            || selectedProfileTarget != nil
    }

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                peopleSection
                roomAudioSection
                roomChatSection
                liveTranscriptsSection
            }
            .navigationTitle(destination.roomName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                roomActionsToolbarItem
            }
            .sheet(isPresented: $showDetails, onDismiss: handleAuxiliaryInterfaceDismissed) { roomDetailsSheet }
            .sheet(isPresented: $showControls, onDismiss: handleAuxiliaryInterfaceDismissed) { roomControlsSheet }
            .sheet(isPresented: $showPeople, onDismiss: handleAuxiliaryInterfaceDismissed) { peopleSheet }
            .sheet(isPresented: $showSettings, onDismiss: handleAuxiliaryInterfaceDismissed) { roomSettingsSheet }
            .sheet(isPresented: $showRoomAdmin, onDismiss: handleAuxiliaryInterfaceDismissed) { roomAdminSheet }
            .sheet(isPresented: $showRoomMessages, onDismiss: handleAuxiliaryInterfaceDismissed) { roomMessagesSheet }
            .sheet(isPresented: $showDirectMessages, onDismiss: handleAuxiliaryInterfaceDismissed) { directMessagesSheet }
            .sheet(item: $selectedProfileTarget, onDismiss: handleAuxiliaryInterfaceDismissed) { target in
                userProfileSheet(for: target)
            }
        }
        .onAppear {
            IOSAudioSessionManager.shared.activate(for: .room)
            socketClient.setPlaybackGain(Float(outputGain))
            syncRoomAudioState()
            socketClient.startSession(
                baseURL: destination.baseURL,
                roomId: destination.roomId,
                roomName: destination.roomName,
                displayName: destination.displayName,
                authToken: authToken,
                authProvider: authProvider,
                authUserJSON: authUserJSON
            )
            Task { await refreshRoomAdminAccess() }
            joinSoundTask?.cancel()
            joinSoundTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled else { return }
                IOSActionSoundPlayer.playRoomJoin()
            }
            memberRefreshTask?.cancel()
            memberRefreshTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                while !Task.isCancelled {
                    socketClient.requestRoomUsersIfDue(minimumInterval: 6.0)
                    if socketClient.roomUsers.isEmpty {
                        await socketClient.refreshRoomSnapshotViaHTTP()
                    }
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                }
            }
        }
        .onDisappear {
            if keepRoomAliveDuringInterfaceChange || isPresentingAuxiliarySheet {
                return
            }
            joinSoundTask?.cancel()
            joinSoundTask = nil
            memberRefreshTask?.cancel()
            memberRefreshTask = nil
            keepRoomAliveResetTask?.cancel()
            keepRoomAliveResetTask = nil
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
            startRoomBackgroundPlaybackIfNeeded()
            socketClient.requestRoomUsersIfDue(minimumInterval: 1.0)
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

    @ViewBuilder
    private var peopleSection: some View {
        Section("People in Room") {
            if visibleHumanRoomUsers.isEmpty {
                Text("No people reported in this room yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleHumanRoomUsers) { target in
                    roomUserRow(for: target, includeRoleBadges: true)
                }
            }
        }
        if !visibleBotRoomUsers.isEmpty {
            Section("Room Bots") {
                ForEach(visibleBotRoomUsers) { target in
                    roomUserRow(for: target, includeRoleBadges: true)
                }
            }
        }
    }

    @ViewBuilder
    private var roomChatSection: some View {
        Section("Room Chat") {
            if roomMessages.isEmpty {
                Text("No room messages yet.")
                    .foregroundStyle(.secondary)
            } else if showChat {
                ForEach(Array(roomMessages.prefix(12))) { message in
                    roomMessageRow(for: message)
                }
                if roomMessages.count > 12 {
                    Button("Show All Room Messages") {
                        presentRoomInterface { showRoomMessages = true }
                        IOSActionSoundPlayer.playConfirm()
                    }
                }
            } else {
                Button("Show Room Messages") {
                    protectRoomDuringInterfaceChange()
                    showChat = true
                    showRoomMessages = true
                    IOSActionSoundPlayer.playConfirm()
                }
            }

            Button(showChat ? "Hide Inline Messages" : "Show Inline Messages") {
                protectRoomDuringInterfaceChange()
                showChat.toggle()
                IOSActionSoundPlayer.playToggle()
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

    private var roomAudioModeLabel: String {
        switch IOSVoiceLinkAudioMode.current {
        case .original:
            return "Original Audio"
        case .voiceIsolation:
            return "Voice Isolation"
        case .meeting:
            return "Meeting Mode"
        case .studio:
            return "Studio Mode"
        }
    }

    @ViewBuilder
    private var roomAudioSection: some View {
        if showAudioControls {
            Section("Audio Settings") {
                LabeledContent("Microphone", value: inputMuted ? "Muted" : "On")
                LabeledContent("Room Output", value: roomOutputMuted ? "Muted" : "On")
                LabeledContent("Audio Mode", value: roomAudioModeLabel)
                if showRoomRelayDebugDetails {
                    LabeledContent("Relay", value: socketClient.audioRelayStatus)
                }
                Button("Audio Settings") {
                    presentRoomInterface { showControls = true }
                    IOSActionSoundPlayer.playConfirm()
                }
                .accessibilityHint("Opens the room audio settings subtab with microphone, output, media, and processing controls.")
                Button(inputMuted ? "Unmute Microphone" : "Mute Microphone") {
                    inputMuted.toggle()
                    syncRoomAudioState()
                    IOSActionSoundPlayer.playToggle()
                }
                Button(roomOutputMuted ? "Unmute Room Output" : "Mute Room Output") {
                    roomOutputMuted.toggle()
                    syncRoomAudioState()
                    IOSActionSoundPlayer.playToggle()
                }
            }
        }
    }

    private var roomActionsToolbarItem: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                presentRoomInterface { showSettings = true }
                IOSActionSoundPlayer.playConfirm()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .accessibilityLabel("App Settings")
            .accessibilityHint("Open full settings without leaving the room.")

            Button {
                toggleRoomAudioControls()
                IOSActionSoundPlayer.playToggle()
            } label: {
                Image(systemName: showAudioControls ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
            .accessibilityLabel(showAudioControls ? "Hide Room Audio Controls" : "Show Room Audio Controls")
            .accessibilityHint("Toggle the main room audio controls section.")

            Menu {
                Button(showChat ? "Hide Chat" : "Show Chat") {
                    protectRoomDuringInterfaceChange()
                    showChat.toggle()
                    IOSActionSoundPlayer.playToggle()
                }
                Button("Room Messages") {
                    presentRoomInterface { showRoomMessages = true }
                    IOSActionSoundPlayer.playConfirm()
                }
                Button("Room Audio Settings") {
                    presentRoomInterface { showControls = true }
                    IOSActionSoundPlayer.playConfirm()
                }
                Button("People in Room") {
                    socketClient.requestRoomUsersIfDue(minimumInterval: 1.0)
                    presentRoomInterface { showPeople = true }
                    IOSActionSoundPlayer.playConfirm()
                }
                Button("Room Details") {
                    presentRoomInterface { showDetails = true }
                    IOSActionSoundPlayer.playConfirm()
                }
                Button(showAudioControls ? "Hide Room Audio Controls" : "Show Room Audio Controls") {
                    toggleRoomAudioControls()
                    IOSActionSoundPlayer.playToggle()
                }
                Button(showPeopleAudioState ? "Hide User Audio State" : "Show User Audio State") {
                    protectRoomDuringInterfaceChange()
                    showPeopleAudioState.toggle()
                    IOSActionSoundPlayer.playToggle()
                }
                if canManageRooms {
                    Divider()
                    Button("Room Administration") {
                        presentRoomInterface { showRoomAdmin = true }
                        IOSActionSoundPlayer.playConfirm()
                    }
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
                Section("Room View") {
                    Toggle("Show Chat", isOn: $showChat)
                        .onChange(of: showChat) { _ in
                            protectRoomDuringInterfaceChange()
                            IOSActionSoundPlayer.playToggle()
                        }
                    Toggle("Show Audio Controls", isOn: $showAudioControls)
                        .onChange(of: showAudioControls) { _ in
                            protectRoomDuringInterfaceChange()
                            IOSActionSoundPlayer.playToggle()
                        }
                    Toggle("Show User Audio State", isOn: $showPeopleAudioState)
                        .onChange(of: showPeopleAudioState) { _ in
                            protectRoomDuringInterfaceChange()
                            IOSActionSoundPlayer.playToggle()
                        }
                }

                Section("Audio Settings") {
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
                    .accessibilityAdjustableAction { direction in
                        adjustGainValue(&inputGain, direction: direction)
                    }

                    Slider(value: $outputGain, in: 0...3) {
                        Text("Master Output")
                    } minimumValueLabel: {
                        Text("0%")
                    } maximumValueLabel: {
                        Text("300%")
                    }
                    .accessibilityValue("\(Int(outputGain * 100)) percent")
                    .accessibilityAdjustableAction { direction in
                        adjustGainValue(&outputGain, direction: direction)
                    }

                    Toggle("Mute Media Playback", isOn: $mediaMuted)
                        .onChange(of: mediaMuted) { _ in
                            syncRoomBackgroundPlaybackState()
                            IOSActionSoundPlayer.playToggle()
                        }
                    Picker("Audio Mode", selection: $audioMode) {
                        Text("Original Audio").tag(IOSVoiceLinkAudioMode.original.rawValue)
                        Text("Voice Isolation").tag(IOSVoiceLinkAudioMode.voiceIsolation.rawValue)
                        Text("Meeting Mode").tag(IOSVoiceLinkAudioMode.meeting.rawValue)
                        Text("Studio Mode").tag(IOSVoiceLinkAudioMode.studio.rawValue)
                    }
                    .onChange(of: audioMode) { _ in
                        IOSAudioSessionManager.shared.refreshActiveSessionConfiguration()
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
                    Text("Original Audio is the default. Voice processing is enabled only when the selected mode or toggles request it.")
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
                    if visibleHumanRoomUsers.isEmpty {
                        Text("No people reported in this room yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleHumanRoomUsers) { target in
                            roomUserRow(for: target, includeRoleBadges: false)
                        }
                    }
                }
                if !visibleBotRoomUsers.isEmpty {
                    Section("Room Bots") {
                        ForEach(visibleBotRoomUsers) { target in
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

    private var roomMessagesSheet: some View {
        NavigationStack {
            List {
                Section("Room Messages") {
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
                        .lineLimit(1...5)
                    Button("Send to Room") {
                        sendRoomMessage()
                    }
                    .disabled(draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Room Messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { showRoomMessages = false }
                }
            }
        }
    }

    private var roomSettingsSheet: some View {
        SettingsTab(roomState: roomState, openServers: {}, onClose: { showSettings = false })
    }

    private var roomAdminSheet: some View {
        AdminTabView(serverURL: .constant(destination.baseURL))
    }

    private func userProfileSheet(for target: IOSDirectMessageTarget) -> some View {
        NavigationStack {
            List {
                Section("User") {
                    LabeledContent("Name", value: target.name)
                    LabeledContent("Identifier", value: target.id)
                    if isCurrentRoomUser(target) {
                        LabeledContent("Relation", value: "Current signed-in user")
                    }
                    if !target.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        LabeledContent("Role", value: target.role)
                    }
                    if !target.authProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        LabeledContent("Authentication", value: target.authProvider)
                    }
                }

                Section("Room State") {
                    LabeledContent("Audio", value: roomAudioStatusLabel(for: target))
                    LabeledContent("Transmit", value: target.transmitEnabled ? "Allowed" : "Disabled")
                    LabeledContent("Muted", value: target.isMuted ? "Yes" : "No")
                    LabeledContent("Output Muted", value: target.isDeafened ? "Yes" : "No")
                    LabeledContent("Speaking", value: target.isSpeaking ? "Yes" : "No")
                    if target.isBot {
                        LabeledContent("Bot Type", value: roomUserBotStatusLabel(for: target) ?? "Bot")
                    }
                    if let statusMessage = roomUserStatusMessage(for: target) {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if !target.deviceName.isEmpty || !target.deviceType.isEmpty || !target.clientVersion.isEmpty {
                    Section("Device") {
                        if !target.deviceName.isEmpty {
                            LabeledContent("Device", value: target.deviceName)
                        }
                        if !target.deviceType.isEmpty {
                            LabeledContent("Type", value: target.deviceType)
                        }
                        if !target.clientVersion.isEmpty {
                            LabeledContent("Client", value: target.clientVersion)
                        }
                    }
                }

                Section("Actions") {
                    if canDirectMessageRoomUser(target) {
                        Button("Direct Message") {
                            selectedProfileTarget = nil
                            openDirectMessages(with: target)
                        }
                    }
                    if canMonitorRoomUser(target) {
                        Button(monitorTarget?.id == target.id ? "Stop Monitoring" : "Start Monitoring") {
                            toggleMonitorTarget(target)
                        }
                    }
                    if canWhisperToRoomUser(target) {
                        Button(whisperTarget?.id == target.id ? "Stop Whisper" : "Start Whisper") {
                            toggleWhisperTarget(target)
                        }
                    }
                    if canShowPerUserAudioControls(for: target) {
                        Button(isShowingUserAudioControls(for: target) ? "Hide Audio Controls" : "Show Audio Controls") {
                            toggleUserAudioControls(for: target)
                        }
                    }
                }
            }
            .navigationTitle(target.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        selectedProfileTarget = nil
                    }
                }
            }
        }
    }

    private func roomUserRow(for target: IOSDirectMessageTarget, includeRoleBadges: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
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
                            if let botStatus = roomUserBotStatusLabel(for: target) {
                                Text(botStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if showPeopleAudioState {
                                Text(roomAudioStatusLabel(for: target))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if canShowPerUserAudioControls(for: target) {
                                    userAudioLevelMeter(for: target)
                                }
                            }
                            if let statusMessage = roomUserStatusMessage(for: target) {
                                Text(statusMessage)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
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
                                    .accessibilityHidden(true)
                            } else if monitorTarget?.id == target.id {
                                Text("Monitor")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.blue)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(roomUserAccessibilityLabel(for: target))
                .accessibilityValue(roomUserAccessibilityValue(for: target))
                .accessibilityHint(roomUserAccessibilityHint(for: target))
                .accessibilityAction {
                    openProfile(for: target)
                }
                .accessibilityActions {
                    Button("View Profile") {
                        openProfile(for: target)
                    }
                    if canDirectMessageRoomUser(target) {
                        Button("Direct Message") {
                            openDirectMessages(with: target)
                        }
                    }
                    if canMonitorRoomUser(target) {
                        Button(monitorTarget?.id == target.id ? "Stop Monitoring" : "Start Monitoring") {
                            toggleMonitorTarget(target)
                        }
                    }
                    if canWhisperToRoomUser(target) {
                        Button(whisperTarget?.id == target.id ? "Stop Whisper" : "Start Whisper") {
                            toggleWhisperTarget(target)
                        }
                    }
                    if canShowPerUserAudioControls(for: target) {
                        Button(isShowingUserAudioControls(for: target) ? "Hide Audio Controls" : "Show Audio Controls") {
                            toggleUserAudioControls(for: target)
                        }
                    }
                }

                if isShowingUserAudioControls(for: target) {
                    userAudioControlsView(for: target)
                        .frame(maxWidth: 190)
                }
            }
        }
        .contextMenu {
            Button("View Profile") {
                openProfile(for: target)
            }
            if canDirectMessageRoomUser(target) {
                Button("Direct Message \(target.name)") {
                    openDirectMessages(with: target)
                }
            }
            if canWhisperToRoomUser(target) {
                Button(whisperTarget?.id == target.id ? "Stop Whisper Target" : "Whisper to \(target.name)") {
                    toggleWhisperTarget(target)
                }
            }
            if canMonitorRoomUser(target) {
                Button(monitorTarget?.id == target.id ? "Stop Monitoring \(target.name)" : "Monitor \(target.name)") {
                    toggleMonitorTarget(target)
                }
            }
            if canShowPerUserAudioControls(for: target) {
                Button(isShowingUserAudioControls(for: target) ? "Hide Audio Controls" : "Show Audio Controls") {
                    toggleUserAudioControls(for: target)
                }
            }
            Button(showPeopleAudioState ? "Hide User Audio State" : "Show User Audio State") {
                protectRoomDuringInterfaceChange()
                showPeopleAudioState.toggle()
                IOSActionSoundPlayer.playToggle()
            }
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.55)
                .onEnded { _ in
                    if canWhisperToRoomUser(target) {
                        toggleWhisperTarget(target)
                    } else if canMonitorRoomUser(target) {
                        toggleMonitorTarget(target)
                    } else if canDirectMessageRoomUser(target) {
                        openDirectMessages(with: target)
                    } else {
                        openProfile(for: target)
                    }
                }
        )
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(roomMessageAccessibilityLabel(for: message))
        .accessibilityHint("Use actions to reply or direct message the sender when available.")
        .accessibilityActions {
            Button("Reply") {
                replyToRoomMessage(message)
            }
            if let target = roomMessageDirectMessageTarget(for: message), canDirectMessageRoomUser(target) {
                Button("Direct Message \(target.name)") {
                    openDirectMessages(with: target)
                }
            }
        }
        .contextMenu {
            Button("Reply to \(message.author)") {
                replyToRoomMessage(message)
            }
            if let target = roomMessageDirectMessageTarget(for: message), canDirectMessageRoomUser(target) {
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
        presentRoomInterface { selectedProfileTarget = target }
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
        presentRoomInterface { showDirectMessages = true }
        IOSActionSoundPlayer.playConfirm()
    }

    private func toggleWhisperTarget(_ target: IOSDirectMessageTarget) {
        guard canWhisperToRoomUser(target) else {
            roomState.statusText = isCurrentRoomUser(target)
                ? "Whisper is only available for other users."
                : "Whisper is only available for people or bots with audio."
            UIAccessibility.post(notification: .announcement, argument: roomState.statusText)
            IOSActionSoundPlayer.playError()
            return
        }
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
        UIAccessibility.post(notification: .announcement, argument: roomState.statusText)
        IOSActionSoundPlayer.playToggle()
    }

    private func toggleMonitorTarget(_ target: IOSDirectMessageTarget) {
        guard canMonitorRoomUser(target) else {
            roomState.statusText = "Monitoring is only available for people or audio-capable bots."
            UIAccessibility.post(notification: .announcement, argument: roomState.statusText)
            IOSActionSoundPlayer.playError()
            return
        }
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
        UIAccessibility.post(notification: .announcement, argument: roomState.statusText)
        IOSActionSoundPlayer.playToggle()
    }

    private func isCurrentRoomUser(_ target: IOSDirectMessageTarget) -> Bool {
        let targetId = normalizedRoomUserIdentity(target.id)
        let targetName = normalizedRoomUserIdentity(target.name)
        let localIds = [
            authUserValue(keys: ["id", "userId", "clientId", "sub", "email"]),
            UserDefaults.standard.string(forKey: "voicelink.userId")
        ]
        .compactMap { normalizedRoomUserIdentity($0 ?? "") }
        .filter { !$0.isEmpty }
        let localNames = [
            destination.displayName,
            authUserValue(keys: ["name", "displayName", "username", "userName", "email"]),
            UserDefaults.standard.string(forKey: "voicelink.displayName"),
            UserDefaults.standard.string(forKey: "voicelink.accountDisplayName"),
            UserDefaults.standard.string(forKey: "voicelink.userName")
        ]
        .compactMap { normalizedRoomUserIdentity($0 ?? "") }
        .filter { !$0.isEmpty }

        return (!targetId.isEmpty && localIds.contains(targetId))
            || (!targetName.isEmpty && localNames.contains(targetName))
    }

    private func canDirectMessageRoomUser(_ target: IOSDirectMessageTarget) -> Bool {
        !isSystemOnlyRoomUser(target)
    }

    private func canMonitorRoomUser(_ target: IOSDirectMessageTarget) -> Bool {
        if target.isBot {
            return isAudioCapableRoomUser(target)
        }
        return target.hasAudioControls || isCurrentRoomUser(target)
    }

    private func canWhisperToRoomUser(_ target: IOSDirectMessageTarget) -> Bool {
        !isCurrentRoomUser(target) && isAudioCapableRoomUser(target)
    }

    private func isAudioCapableRoomUser(_ target: IOSDirectMessageTarget) -> Bool {
        if target.isBot {
            return target.hasAudioControls && targetBotType(target) == "audio"
        }
        return target.hasAudioControls
    }

    private func isSystemOnlyRoomUser(_ target: IOSDirectMessageTarget) -> Bool {
        target.isBot && targetBotType(target) == "system"
    }

    private func targetBotType(_ target: IOSDirectMessageTarget) -> String {
        target.botType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedRoomUserIdentity(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func authUserValue(keys: [String]) -> String {
        guard let data = authUserJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return ""
        }
        for key in keys {
            if let value = dictionary[key] {
                let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, text.lowercased() != "null" {
                    return text
                }
            }
        }
        return ""
    }

    private func canShowPerUserAudioControls(for target: IOSDirectMessageTarget) -> Bool {
        isAudioCapableRoomUser(target)
    }

    private func roomUserBotStatusLabel(for target: IOSDirectMessageTarget) -> String? {
        guard target.isBot else { return nil }
        switch targetBotType(target) {
        case "audio":
            return "Audio bot"
        case "system":
            return "System bot"
        default:
            return "Text bot"
        }
    }

    private func roomUserStatusMessage(for target: IOSDirectMessageTarget) -> String? {
        let message = target.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty {
            return message
        }
        guard target.isBot else { return nil }
        switch targetBotType(target) {
        case "audio":
            return "This bot supports audio controls."
        case "system":
            return "System updates only."
        default:
            return "Text interaction only."
        }
    }

    private func isShowingUserAudioControls(for target: IOSDirectMessageTarget) -> Bool {
        expandedUserAudioControls.contains(target.id) && canShowPerUserAudioControls(for: target)
    }

    private func toggleUserAudioControls(for target: IOSDirectMessageTarget) {
        guard canShowPerUserAudioControls(for: target) else { return }
        protectRoomDuringInterfaceChange()
        if expandedUserAudioControls.contains(target.id) {
            expandedUserAudioControls.remove(target.id)
        } else {
            expandedUserAudioControls.insert(target.id)
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }
        IOSActionSoundPlayer.playToggle()
    }

    private func toggleRoomAudioControls() {
        protectRoomDuringInterfaceChange()
        showAudioControls.toggle()
    }

    private func presentRoomInterface(_ update: () -> Void) {
        protectRoomDuringInterfaceChange(resetAfter: 3.0)
        update()
    }

    private func protectRoomDuringInterfaceChange(resetAfter seconds: Double = 1.2) {
        keepRoomAliveDuringInterfaceChange = true
        keepRoomAliveResetTask?.cancel()
        keepRoomAliveResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0.2, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if !isPresentingAuxiliarySheet {
                keepRoomAliveDuringInterfaceChange = false
            }
        }
    }

    private func handleAuxiliaryInterfaceDismissed() {
        keepRoomAliveResetTask?.cancel()
        keepRoomAliveResetTask = nil
        keepRoomAliveDuringInterfaceChange = false
        IOSAudioSessionManager.shared.activate(for: .room)
        syncRoomAudioState()
        socketClient.setPlaybackGain(Float(outputGain))
        updateRoomBackgroundPlaybackVolume()
        socketClient.requestRoomUsersIfDue(minimumInterval: 1.0)
        Task { await refreshRoomAdminAccess() }
    }

    @MainActor
    private func refreshRoomAdminAccess() async {
        guard let url = URL(string: "\(destination.baseURL)/api/admin/status") else {
            canManageRooms = destination.canManageRooms
            return
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue(token, forHTTPHeaderField: "x-session-token")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                canManageRooms = destination.canManageRooms
                return
            }
            let permissions = json["permissions"] as? [String: Bool]
            let isAdmin = (json["isAdmin"] as? Bool) ?? false
            canManageRooms = ((json["canManageRooms"] as? Bool) ?? (permissions?["rooms"] ?? false)) || isAdmin || destination.canManageRooms
        } catch {
            canManageRooms = destination.canManageRooms
        }
    }

    @ViewBuilder
    private func userAudioControlsView(for target: IOSDirectMessageTarget) -> some View {
        let mutedBinding = Binding<Bool>(
            get: { socketClient.userPlaybackMuted[target.id] ?? false },
            set: { socketClient.setUserPlaybackMuted($0, for: target.id) }
        )
        let volumeBinding = Binding<Double>(
            get: { Double(socketClient.userPlaybackGains[target.id] ?? 1.0) },
            set: { socketClient.setUserPlaybackGain(Float($0), for: target.id) }
        )

        VStack(alignment: .leading, spacing: 10) {
            Toggle("Mute \(target.name)", isOn: mutedBinding)
                .onChange(of: mutedBinding.wrappedValue) { _ in
                    IOSActionSoundPlayer.playToggle()
                }
            Slider(value: volumeBinding, in: 0...3) {
                Text("\(target.name) Volume")
            } minimumValueLabel: {
                Text("0%")
            } maximumValueLabel: {
                Text("300%")
            }
            .accessibilityValue("\(Int(volumeBinding.wrappedValue * 100)) percent")
            .accessibilityAdjustableAction { direction in
                var nextValue = volumeBinding.wrappedValue
                adjustGainValue(&nextValue, direction: direction)
                volumeBinding.wrappedValue = nextValue
            }
        }
        .padding(.leading, 8)
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
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 1
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
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
        if target.isBot && !target.hasAudioControls {
            return "Text interaction only"
        }
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
        var parts = [target.name]
        if let botStatus = roomUserBotStatusLabel(for: target) {
            parts.append(botStatus)
        }
        parts.append(roomAudioStatusLabel(for: target))
        if let statusMessage = roomUserStatusMessage(for: target) {
            parts.append(statusMessage)
        }
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

    private func roomUserAccessibilityHint(for target: IOSDirectMessageTarget) -> String {
        let actions = roomUserAvailableActionNames(for: target)
        if actions.isEmpty {
            return "Double tap to show this user's details without leaving the room."
        }
        return "Double tap to show this user's details without leaving the room. Available actions: \(actions.joined(separator: ", "))."
    }

    private func roomUserAvailableActionNames(for target: IOSDirectMessageTarget) -> [String] {
        var actions = ["View Profile"]
        if canDirectMessageRoomUser(target) {
            actions.append("Direct Message")
        }
        if canMonitorRoomUser(target) {
            actions.append(monitorTarget?.id == target.id ? "Stop Monitoring" : "Start Monitoring")
        }
        if canWhisperToRoomUser(target) {
            actions.append(whisperTarget?.id == target.id ? "Stop Whisper" : "Start Whisper")
        }
        if canShowPerUserAudioControls(for: target) {
            actions.append(isShowingUserAudioControls(for: target) ? "Hide Audio Controls" : "Show Audio Controls")
        }
        return actions
    }

    private func replyToRoomMessage(_ message: IOSRoomMessageItem) {
        replyTarget = message
        draftMessage = "@\(message.author) "
        IOSActionSoundPlayer.playConfirm()
    }

    private func roomMessageDirectMessageTarget(for message: IOSRoomMessageItem) -> IOSDirectMessageTarget? {
        visibleRoomUsers.first {
            $0.name.localizedCaseInsensitiveCompare(message.author) == .orderedSame
        }
    }

    private func roomMessageAccessibilityLabel(for message: IOSRoomMessageItem) -> String {
        var parts = [message.author, message.body.trimmingCharacters(in: .whitespacesAndNewlines)]
        if message.isSystemMessage {
            parts.append("System message")
        } else if message.isBotMessage {
            parts.append("Bot message")
        }
        return parts.joined(separator: ", ")
    }

    private func adjustGainValue(_ value: inout Double, direction: AccessibilityAdjustmentDirection) {
        let step = 0.05
        switch direction {
        case .increment:
            value = min(3.0, value + step)
        case .decrement:
            value = max(0.0, value - step)
        @unknown default:
            break
        }
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
    static let iosRoomUserJoined = Notification.Name("iosRoomUserJoined")
    static let iosRoomUserLeft = Notification.Name("iosRoomUserLeft")
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
