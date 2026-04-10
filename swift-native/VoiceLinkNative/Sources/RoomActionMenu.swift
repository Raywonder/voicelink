import SwiftUI
import Foundation

enum BackgroundMediaAssignmentScope {
    case currentRoom
    case allRooms
    case selectedRooms
}

struct BackgroundMediaRoomPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let availableRooms: [AdminRoomInfo]
    let applyLabel: String
    let onApply: (Set<String>) -> Void

    @State private var selectedRoomIDs: Set<String>

    init(
        title: String,
        availableRooms: [AdminRoomInfo],
        initiallySelectedRoomIDs: Set<String>,
        applyLabel: String,
        onApply: @escaping (Set<String>) -> Void
    ) {
        self.title = title
        self.availableRooms = availableRooms
        self.applyLabel = applyLabel
        self.onApply = onApply
        _selectedRoomIDs = State(initialValue: initiallySelectedRoomIDs)
    }

    private var sortedRooms: [AdminRoomInfo] {
        availableRooms.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose which rooms should use this background media assignment.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                List(sortedRooms) { room in
                    Toggle(
                        isOn: Binding(
                            get: { selectedRoomIDs.contains(room.id) },
                            set: { isOn in
                                if isOn {
                                    selectedRoomIDs.insert(room.id)
                                } else {
                                    selectedRoomIDs.remove(room.id)
                                }
                            }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(room.name)
                            if !room.description.isEmpty {
                                Text(room.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("Use background media in \(room.name)")
                }
                .frame(minHeight: 260)

                HStack {
                    Button("Select All") {
                        selectedRoomIDs = Set(sortedRooms.map(\.id))
                    }
                    .buttonStyle(.bordered)

                    Button("Clear") {
                        selectedRoomIDs.removeAll()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)

                    Button(applyLabel) {
                        onApply(selectedRoomIDs)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedRoomIDs.isEmpty)
                }
            }
            .padding()
            .navigationTitle(title)
        }
        .frame(minWidth: 460, minHeight: 420)
    }
}

/// Room Action Menu - Shows available actions for a room
/// Displayed when joining a room or clicking room name
struct RoomActionMenu: View {
    let room: Room
    let isInRoom: Bool
    @Binding var isPresented: Bool

    @ObservedObject var serverManager = ServerManager.shared
    @ObservedObject var adminManager = AdminServerManager.shared
    @ObservedObject private var authManager = AuthenticationManager.shared
    @ObservedObject private var pairingManager = PairingManager.shared
    @ObservedObject var whisperManager = WhisperModeManager.shared
    @ObservedObject var audioControl = UserAudioControlManager.shared
    @ObservedObject var roomLockManager = RoomLockManager.shared
    @ObservedObject private var settings = SettingsManager.shared
    @State private var isPeeking = false
    @State private var selectedUser: RoomUser?
    @State private var roomMediaStatusText: String = "Checking..."
    @State private var roomMediaActionStatus: String?
    @State private var pendingBackgroundMediaStream: BackgroundStreamConfig?
    @State private var showBackgroundMediaScopeDialog = false
    @State private var showBackgroundMediaRoomPicker = false
    @State private var pendingBackgroundMediaApplyLabel = "Apply to Selected Rooms"
    @State private var pendingBackgroundMediaSelectionTitle = "Choose Rooms"
    @State private var preselectedBackgroundMediaRoomIDs: Set<String> = []

    // Room features (from server settings)
    var roomFeatures: RoomFeatures {
        // In production, these would come from room settings
        RoomFeatures(
            whisperEnabled: true,
            peekEnabled: room.userCount > 0 || settings.allowPreviewWhenMediaActive,
            spatialAudioEnabled: true,
            recordingAllowed: room.recordingAllowed,
            voiceEffectsEnabled: true,
            pttRequired: false,
            canLockRoom: roomLockManager.canCurrentUserLock,
            isRoomLocked: roomLockManager.isRoomLocked
        )
    }

    private var roomPreviewOverride: Bool? {
        settings.roomPreviewOverride(for: room.id)
    }

    private var canManageRoomActions: Bool {
        adminManager.isAdmin || adminManager.adminRole.canManageRooms || roomFeatures.canLockRoom
    }

    private var canOpenServerAdministration: Bool {
        let currentRole = authManager.currentUser?.role?.lowercased()
        return adminManager.isAdmin
            || adminManager.adminRole.canManageConfig
            || adminManager.adminRole.canManageServer
            || currentRole == "admin"
            || currentRole == "owner"
    }

    private var canManageBackgroundMedia: Bool {
        adminManager.isAdmin || adminManager.adminRole.canManageConfig || adminManager.adminRole.canManageRooms
    }

    private var isAuthenticatedUser: Bool {
        authManager.authState == .authenticated && authManager.currentUser != nil
    }

    private var roomJoinStatusText: String {
        isInRoom ? "Joined" : "Not Joined"
    }

    private var roomPreviewEnabledText: String {
        if roomPreviewOverride == false {
            return "Enable Preview in This Room"
        }
        return "Disable Preview in This Room"
    }

    private var roomWelcomeMessage: String? {
        let trimmed = room.welcomeMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var roomUsersForLocalAudioControl: [RoomUser] {
        serverManager.currentRoomUsers.filter { user in
            guard let currentUser = authManager.currentUser else { return true }
            return user.id.caseInsensitiveCompare(currentUser.id) != .orderedSame
                && user.username.caseInsensitiveCompare(currentUser.username) != .orderedSame
        }
    }

    private var availableBackgroundStreams: [BackgroundStreamConfig] {
        guard adminManager.serverConfig?.backgroundStreams?.enabled != false else { return [] }
        let streams = adminManager.serverConfig?.backgroundStreams?.streams ?? []
        return streams
            .filter { stream in
                let url = stream.streamUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stream.url : stream.streamUrl
                return !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var currentBackgroundStreamName: String? {
        if let title = serverManager.currentRoomMedia?.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        guard let activeURL = serverManager.currentRoomMedia?.streamURL.trimmingCharacters(in: .whitespacesAndNewlines),
              !activeURL.isEmpty else { return nil }
        return availableBackgroundStreams.first(where: {
            normalizedStreamURL(for: $0).trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(activeURL) == .orderedSame
        })?.name
    }

    private var assignedBackgroundStream: BackgroundStreamConfig? {
        availableBackgroundStreams.first(where: isStreamAssignedToRoom(_:))
    }

    private var configuredBackgroundMediaFadeDuration: TimeInterval {
        let fadeMilliseconds = adminManager.serverConfig?.backgroundStreams?.fadeInDuration ?? 1500
        return max(Double(fadeMilliseconds) / 1000.0, 0.05)
    }

    private var switchableServers: [(name: String, url: String, isCurrent: Bool)] {
        var ordered: [(name: String, url: String, isCurrent: Bool)] = []
        var seen = Set<String>()

        func append(name: String, rawURL: String) {
            let normalized = normalizedServerURL(rawURL)
            guard !normalized.isEmpty, !seen.contains(normalized) else { return }
            seen.insert(normalized)
            ordered.append((
                name: name,
                url: normalized,
                isCurrent: normalized == normalizedServerURL(serverManager.baseURL ?? "")
            ))
        }

        for managed in settings.managedFederationServers where !managed.isHidden {
            append(name: managed.name, rawURL: managed.url)
        }
        for linked in pairingManager.linkedServers {
            append(name: linked.name, rawURL: linked.url)
        }

        return ordered
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(room.name)
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()

                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color.blue.opacity(0.3))

            // Room info
            HStack {
                Image(systemName: room.isPrivate ? "lock.fill" : "globe")
                    .foregroundColor(room.isPrivate ? .yellow : .green)

                Text("\(room.userCount)/\(room.maxUsers) users")
                    .font(.caption)
                    .foregroundColor(.gray)

                if settings.showRoomDescriptions && !room.description.isEmpty {
                    Text("- \(room.description)")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Room details
            VStack(alignment: .leading, spacing: 8) {
                roomDetailRow(label: "Room ID", value: room.id)
                roomDetailRow(label: "Room Type", value: roomTypeLabel)
                roomDetailRow(label: "Your Access", value: viewerAccessLabel)
                roomDetailRow(label: "Join Status", value: roomJoinStatusText)
                roomDetailRow(label: "Media Status", value: roomMediaStatusText)
                roomDetailRow(label: "Room Controls", value: roomControlsStatusLabel)
                roomDetailRow(label: "Total Users", value: "\(room.userCount)/\(room.maxUsers)")
                roomDetailRow(label: "Uptime", value: roomUptimeLabel)
                roomDetailRow(label: "Last User", value: room.lastActiveUsername ?? "No activity yet")
                roomDetailRow(label: "Last Activity", value: roomLastActivityLabel)
                roomDetailRow(label: "Lock Status", value: room.isLocked ? "Locked" : "Unlocked")
                if let lockedBy = room.lockedBy?.trimmingCharacters(in: .whitespacesAndNewlines), !lockedBy.isEmpty {
                    roomDetailRow(label: "Locked By", value: lockedBy)
                }
                if let hostedFrom = room.hostedFromLine {
                    roomDetailRow(label: "Hosted From", value: hostedFrom)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.03))
            .cornerRadius(8)
            .padding(.horizontal)
            .padding(.top, 8)

            if let roomWelcomeMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Room Welcome")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.85))
                    Text(StatusManager.shared.attributedMessage(roomWelcomeMessage))
                        .font(.caption)
                        .foregroundColor(.gray)
                        .textSelection(.enabled)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if !isInRoom && roomFeatures.peekEnabled {
                        Button(isPeeking ? "Stop Preview" : "Preview") {
                            togglePeek()
                            isPresented = false
                        }
                        .buttonStyle(.bordered)
                    }

                    Button(isInRoom ? "Leave Room" : "Join Room") {
                        NotificationCenter.default.post(
                            name: isInRoom ? .roomActionLeave : .roomActionJoin,
                            object: isInRoom ? nil : room
                        )
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                }

                if isInRoom {
                    Button("Report a Bug") {
                        NotificationCenter.default.post(name: .openBugReport, object: nil)
                        isPresented = false
                    }
                    .buttonStyle(.bordered)
                }

                if isInRoom {
                    EscortMeButton(roomId: room.id)
                }

                if isInRoom && !switchableServers.isEmpty {
                    Menu {
                        ForEach(switchableServers, id: \.url) { server in
                            Button {
                                NotificationCenter.default.post(
                                    name: .roomActionSwitchServer,
                                    object: [
                                        "room": room,
                                        "serverURL": server.url
                                    ]
                                )
                                isPresented = false
                            } label: {
                                if server.isCurrent {
                                    Label(server.name, systemImage: "checkmark")
                                } else {
                                    Text(server.name)
                                }
                            }
                            .disabled(server.isCurrent)
                        }
                    } label: {
                        Label("Switch Servers", systemImage: "arrow.triangle.branch")
                    }
                }

                if isInRoom {
                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Room Audio")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white.opacity(0.9))

                        HStack {
                            Text("Master Output")
                                .font(.caption)
                                .foregroundColor(.gray)

                            Slider(
                                value: Binding(
                                    get: { Double(audioControl.masterVolume) },
                                    set: { audioControl.masterVolume = Float($0) }
                                ),
                                in: 0...2.0
                            )

                            Text("\(Int(audioControl.masterVolume * 100))%")
                                .font(.caption)
                                .foregroundColor(.gray)
                                .frame(width: 42)
                        }

                        if serverManager.currentRoomMedia?.active == true {
                            HStack {
                                Text("Room Media")
                                    .font(.caption)
                                    .foregroundColor(.gray)

                                Slider(
                                    value: Binding(
                                        get: { Double(serverManager.currentRoomMediaVolume) },
                                        set: { serverManager.setCurrentRoomMediaVolume(Float($0)) }
                                    ),
                                    in: 0...1.5
                                )

                                Text("\(Int(serverManager.currentRoomMediaVolume * 100))%")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                    .frame(width: 42)
                            }

                            HStack(spacing: 10) {
                                Button(serverManager.isCurrentRoomMediaMuted ? "Unmute Room Media" : "Mute Room Media") {
                                    serverManager.toggleCurrentRoomMediaMuted()
                                }
                                .buttonStyle(.bordered)

                                Button("Stop Room Media Here") {
                                    stopRoomMediaForCurrentRoom()
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        if !roomUsersForLocalAudioControl.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("User Audio")
                                    .font(.caption)
                                    .foregroundColor(.gray)

                                VStack(spacing: 6) {
                                    ForEach(roomUsersForLocalAudioControl) { user in
                                        InlineUserVolumeControl(userId: user.odId)
                                    }
                                }
                            }
                        }
                    }
                }

                if canManageRoomActions || canOpenServerAdministration {
                    Divider()

                    if canManageBackgroundMedia {
                        Menu {
                            Button("No Background Media") {
                                presentBackgroundMediaSelectionOptions(for: nil)
                            }

                            if !availableBackgroundStreams.isEmpty {
                                Divider()

                                ForEach(availableBackgroundStreams) { stream in
                                    Button {
                                        presentBackgroundMediaSelectionOptions(for: stream)
                                    } label: {
                                        if isStreamAssignedToRoom(stream) {
                                            Label(stream.name, systemImage: "checkmark")
                                        } else {
                                            Text(stream.name)
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("Room Background Media", systemImage: "music.note.list")
                        }

                        if let roomMediaActionStatus, !roomMediaActionStatus.isEmpty {
                            Text(roomMediaActionStatus)
                                .font(.caption2)
                                .foregroundColor(.gray)
                        } else if let assignedBackgroundStream {
                            Text("Assigned stream: \(assignedBackgroundStream.name)")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        } else if let currentBackgroundStreamName, !currentBackgroundStreamName.isEmpty {
                            Text("Current room stream: \(currentBackgroundStreamName)")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }

                    if canOpenServerAdministration {
                        Button("Server Administration") {
                            NotificationCenter.default.post(name: .openServerAdministration, object: nil)
                            isPresented = false
                        }
                    }

                    if canManageRoomActions {
                        Button("Room Administration") {
                            NotificationCenter.default.post(name: .roomActionOpenSettings, object: room)
                            isPresented = false
                        }
                    }

                    if canManageRoomActions {
                        if roomLockManager.isRoomLocked {
                            Button("Unlock Room") {
                                roomLockManager.unlockRoom()
                                isPresented = false
                            }
                        } else {
                            Menu {
                                ForEach(RoomLockManager.LockDurationPreset.allCases) { preset in
                                    Button(preset.title) {
                                        roomLockManager.lockRoom(duration: preset.duration)
                                        isPresented = false
                                    }
                                }
                            } label: {
                                Label("Lock Room", systemImage: "lock.fill")
                            }
                        }
                    }

                    if canManageRoomActions {
                        Button(roomPreviewEnabledText) {
                            if roomPreviewOverride == false {
                                settings.setRoomPreviewOverride(roomId: room.id, enabled: nil)
                            } else {
                                settings.setRoomPreviewOverride(roomId: room.id, enabled: false)
                                if PeekManager.shared.isPeeking, PeekManager.shared.peekingRoom?.id == room.id {
                                    PeekManager.shared.stopPeeking()
                                }
                            }
                        }
                    }
                }

                Divider()
            }
            .padding()
        }
        .frame(width: 320)
        .background(Color(white: 0.15))
        .cornerRadius(12)
        .shadow(radius: 20)
        .onAppear {
            refreshAdminCapabilities()
            refreshRoomMediaStatus()
        }
        .confirmationDialog(
            pendingBackgroundMediaStream == nil ? "Clear Background Media" : "Apply Background Media",
            isPresented: $showBackgroundMediaScopeDialog,
            titleVisibility: .visible
        ) {
            Button("This Room Only") {
                applyPendingBackgroundMediaSelection(scope: .currentRoom)
            }
            Button("All Rooms") {
                applyPendingBackgroundMediaSelection(scope: .allRooms)
            }
            Button("Choose Rooms...") {
                pendingBackgroundMediaSelectionTitle = pendingBackgroundMediaStream == nil
                    ? "Clear Background Media in Rooms"
                    : "Choose Rooms for \(pendingBackgroundMediaStream?.name ?? "Background Media")"
                pendingBackgroundMediaApplyLabel = pendingBackgroundMediaStream == nil
                    ? "Clear in Selected Rooms"
                    : "Apply to Selected Rooms"
                showBackgroundMediaRoomPicker = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingBackgroundMediaStream == nil
                 ? "Choose where to clear the current background media assignment."
                 : "Choose where to start \(pendingBackgroundMediaStream?.name ?? "the selected stream").")
        }
        .sheet(isPresented: $showBackgroundMediaRoomPicker) {
            BackgroundMediaRoomPickerSheet(
                title: pendingBackgroundMediaSelectionTitle,
                availableRooms: adminManager.serverRooms,
                initiallySelectedRoomIDs: preselectedBackgroundMediaRoomIDs,
                applyLabel: pendingBackgroundMediaApplyLabel
            ) { selectedRoomIDs in
                applyBackgroundMediaSelection(pendingBackgroundMediaStream, roomIDs: Array(selectedRoomIDs))
            }
        }
    }

    private func refreshAdminCapabilities() {
        guard let serverURL = serverManager.baseURL, !serverURL.isEmpty else { return }
        let token = authManager.currentUser?.accessToken
        Task {
            await adminManager.checkAdminStatus(serverURL: serverURL, token: token)
            await adminManager.fetchServerConfig()
        }
    }

    private func isStreamAssignedToRoom(_ stream: BackgroundStreamConfig) -> Bool {
        let roomId = room.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let roomName = room.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let excludedRooms = (stream.excludedRooms ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if excludedRooms.contains(roomId) {
            return false
        }
        let explicitRooms = (stream.rooms ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if explicitRooms.contains(roomId) {
            return true
        }
        return (stream.roomPatterns ?? []).contains { pattern in
            roomNameMatchesPattern(roomName, pattern: pattern)
        }
    }

    private func normalizedStreamURL(for stream: BackgroundStreamConfig) -> String {
        let primary = stream.streamUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !primary.isEmpty { return primary }
        return stream.url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedServerURL(_ rawURL: String) -> String {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let candidate = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ? trimmed : "https://\(trimmed)"
        return candidate.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    private func roomNameMatchesPattern(_ roomName: String, pattern: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
        let expression = "^\(escaped)$"
        return roomName.range(of: expression, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func allAssignableRoomIDs() -> [String] {
        let ids = adminManager.serverRooms.map(\.id).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if ids.isEmpty {
            return [room.id]
        }
        return Array(Set(ids)).sorted()
    }

    private func presentBackgroundMediaSelectionOptions(for selectedStream: BackgroundStreamConfig?) {
        pendingBackgroundMediaStream = selectedStream
        preselectedBackgroundMediaRoomIDs = [room.id]
        showBackgroundMediaScopeDialog = true
    }

    private func applyPendingBackgroundMediaSelection(scope: BackgroundMediaAssignmentScope) {
        switch scope {
        case .currentRoom:
            applyBackgroundMediaSelection(pendingBackgroundMediaStream, roomIDs: [room.id])
        case .allRooms:
            applyBackgroundMediaSelection(pendingBackgroundMediaStream, roomIDs: allAssignableRoomIDs())
        case .selectedRooms:
            showBackgroundMediaRoomPicker = true
        }
    }

    private func applyBackgroundMediaSelection(_ selectedStream: BackgroundStreamConfig?, roomIDs: [String]) {
        guard canManageBackgroundMedia else { return }
        guard var config = adminManager.serverConfig?.backgroundStreams else {
            roomMediaActionStatus = "Load server media settings first."
            return
        }

        let normalizedRoomIDs = Array(Set(roomIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        guard !normalizedRoomIDs.isEmpty else {
            roomMediaActionStatus = "Choose at least one room."
            return
        }

        config.streams = config.streams.map { stream in
            var updated = stream
            var rooms = (updated.rooms ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !normalizedRoomIDs.contains($0) }
            var excludedRooms = (updated.excludedRooms ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !normalizedRoomIDs.contains($0) }
            if let selectedStream, updated.id == selectedStream.id {
                rooms.append(contentsOf: normalizedRoomIDs)
                updated.autoPlay = true
            } else {
                excludedRooms.append(contentsOf: normalizedRoomIDs)
            }
            updated.rooms = rooms.isEmpty ? nil : Array(Set(rooms)).sorted()
            updated.excludedRooms = excludedRooms.isEmpty ? nil : Array(Set(excludedRooms)).sorted()
            return updated
        }

        let roomTargetLabel: String = normalizedRoomIDs.count == 1
            ? "1 room"
            : "\(normalizedRoomIDs.count) rooms"
        roomMediaActionStatus = selectedStream == nil
            ? "Clearing background media in \(roomTargetLabel)..."
            : "Starting \(selectedStream?.name ?? "selected stream") in \(roomTargetLabel)..."

        Task {
            let success = await adminManager.updateBackgroundStreamsConfig(config)
            await MainActor.run {
                if success {
                    roomMediaActionStatus = selectedStream == nil
                        ? "Background media cleared for \(roomTargetLabel)."
                        : "Background media updated for \(roomTargetLabel)."
                    serverManager.setRoomMediaFadeDuration(configuredBackgroundMediaFadeDuration)
                    serverManager.stopCurrentRoomMedia()
                    if selectedStream != nil {
                        serverManager.refreshRoomMedia(for: room.id)
                    }
                    Task {
                        await adminManager.fetchServerConfig()
                    }
                    refreshRoomMediaStatus()
                } else {
                    roomMediaActionStatus = "Unable to update room background media."
                }
            }
        }
    }

    private func stopRoomMediaForCurrentRoom() {
        guard isInRoom else {
            serverManager.stopCurrentRoomMedia()
            refreshRoomMediaStatus()
            return
        }

        if canManageBackgroundMedia, assignedBackgroundStream != nil {
            roomMediaActionStatus = "Stopping room background media..."
            applyBackgroundMediaSelection(nil, roomIDs: [room.id])
            return
        }

        serverManager.stopCurrentRoomMedia()
        refreshRoomMediaStatus()
    }

    private func togglePeek() {
        if isPeeking {
            PeekManager.shared.stopPeeking()
        } else {
            PeekManager.shared.peekIntoRoom(room)
        }
        isPeeking.toggle()
    }

    private var roomTypeLabel: String {
        let mappedByType: String? = {
            guard let type = room.roomType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !type.isEmpty else { return nil }
            if type.contains("default") || type == "system" {
                return "Default Room"
            }
            if type.contains("admin") || type.contains("owner") {
                return "Admin-Created Room"
            }
            if type.contains("member") || type.contains("user") || type.contains("community") {
                return "Member-Created Room"
            }
            return "\(type.capitalized) Room"
        }()

        if let mappedByType {
            return mappedByType
        }

        let role = room.createdByRole?.lowercased() ?? ""
        if role.contains("admin") || role.contains("owner") {
            return "Admin-Created Room"
        }
        if role.contains("member") || role.contains("user") {
            return "Member-Created Room"
        }

        let loweredName = room.name.lowercased()
        let loweredId = room.id.lowercased()
        if loweredId.contains("default")
            || loweredName.contains("lobby")
            || loweredName.contains("welcome")
            || loweredName.contains("general") {
            return "Default Room"
        }
        return "Member-Created Room"
    }

    private var viewerAccessLabel: String {
        if adminManager.isAdmin || adminManager.adminRole == .admin || adminManager.adminRole == .owner {
            return "Admin Access"
        }
        if roomFeatures.canLockRoom {
            return "Room Moderator Access"
        }
        if isInRoom {
            return "Member Access (Joined)"
        }
        if room.isPrivate {
            return "Limited Access (Approval Required)"
        }
        return "Standard Access"
    }

    private var roomControlsStatusLabel: String {
        if canOpenServerAdministration && canManageRoomActions {
            return "Server Admin + Room Controls"
        }
        if canOpenServerAdministration {
            return "Server Admin Access"
        }
        if canManageRoomActions {
            return "Room Controls Allowed"
        }
        if isAuthenticatedUser {
            return "Member Access"
        }
        return "Guest Access"
    }

    private var roomUptimeLabel: String {
        if let uptimeSeconds = room.uptimeSeconds {
            return formatDuration(seconds: uptimeSeconds)
        }
        if let createdAt = room.createdAt {
            let seconds = max(0, Int(Date().timeIntervalSince(createdAt)))
            return formatDuration(seconds: seconds)
        }
        return "Not reported yet"
    }

    private var roomLastActivityLabel: String {
        guard let lastActivityAt = room.lastActivityAt else {
            return "No activity yet"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: lastActivityAt, relativeTo: Date())
    }

    @ViewBuilder
    private func roomDetailRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(label):")
                .font(.caption)
                .foregroundColor(.gray)
            Text(value)
                .font(.caption)
                .foregroundColor(.white)
            Spacer(minLength: 0)
        }
    }

    private func formatDuration(seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }
        return "\(secs)s"
    }

    private func refreshRoomMediaStatus() {
        if serverManager.activeRoomId == room.id {
            if serverManager.isCurrentRoomMediaPlaying {
                let title = currentBackgroundStreamName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                roomMediaStatusText = title.isEmpty ? "Broadcasting in room" : "Broadcasting in room (\(title))"
            } else {
                roomMediaStatusText = assignedBackgroundStream == nil ? "Stopped in room" : "Assigned but stopped"
            }
            return
        }

        if let assignedBackgroundStream {
            roomMediaStatusText = "Assigned (\(assignedBackgroundStream.name))"
            return
        }

        roomMediaStatusText = "Checking..."
        guard let base = serverManager.baseURL,
              let encoded = room.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(base)/api/jellyfin/room-stream/\(encoded)") else {
            roomMediaStatusText = "Idle"
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data,
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async {
                    self.roomMediaStatusText = self.assignedBackgroundStream == nil ? "Idle" : self.roomMediaStatusText
                }
                return
            }

            let active = (payload["active"] as? Bool) == true
            let title = (payload["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                if active {
                    self.roomMediaStatusText = title.isEmpty ? "Playing" : "Playing (\(title))"
                } else {
                    self.roomMediaStatusText = "Idle"
                }
            }
        }.resume()
    }
}

// MARK: - Room Features

struct RoomFeatures {
    var whisperEnabled: Bool
    var peekEnabled: Bool
    var spatialAudioEnabled: Bool
    var recordingAllowed: Bool
    var voiceEffectsEnabled: Bool
    var pttRequired: Bool
    var canLockRoom: Bool = false      // User has permission to lock room
    var isRoomLocked: Bool = false     // Current lock state
}

// MARK: - Room Lock Manager

class RoomLockManager: ObservableObject {
    static let shared = RoomLockManager()

    enum LockDurationPreset: String, CaseIterable, Identifiable {
        case untilUnlocked = "untilUnlocked"
        case fifteenMinutes = "15m"
        case oneHour = "1h"
        case eightHours = "8h"
        case oneDay = "1d"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .untilUnlocked: return "Until Unlocked"
            case .fifteenMinutes: return "15 Minutes"
            case .oneHour: return "1 Hour"
            case .eightHours: return "8 Hours"
            case .oneDay: return "24 Hours"
            }
        }

        var duration: TimeInterval? {
            switch self {
            case .untilUnlocked: return nil
            case .fifteenMinutes: return 15 * 60
            case .oneHour: return 60 * 60
            case .eightHours: return 8 * 60 * 60
            case .oneDay: return 24 * 60 * 60
            }
        }
    }

    @Published var isRoomLocked = false
    @Published var lockedByUserId: String?
    @Published var lockedByUsername: String?
    @Published var canCurrentUserLock = false
    @Published var lockDurationPreset: LockDurationPreset = .untilUnlocked
    @Published var lockedUntil: Date?

    private var keyMonitor: Any?
    private var scheduledUnlockWorkItem: DispatchWorkItem?

    init() {
        setupKeyboardShortcut()
        setupNotifications()
    }

    deinit {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Lock Control

    /// Lock the current room (if user has permission)
    func lockRoom(duration: TimeInterval? = nil) {
        guard canCurrentUserLock, !isRoomLocked else { return }

        isRoomLocked = true
        lockedByUserId = getCurrentUserId()
        lockedByUsername = getCurrentUsername()
        lockedUntil = duration.map { Date().addingTimeInterval($0) }
        scheduleUnlockIfNeeded(after: duration)

        // Play lock sound
        AppSoundManager.shared.playSound(.toggleOn)

        // Notify server
        NotificationCenter.default.post(
            name: .roomLockStateChanged,
            object: nil,
            userInfo: [
                "locked": true,
                "userId": lockedByUserId ?? "",
                "username": lockedByUsername ?? "",
                "durationSeconds": duration as Any,
                "lockedUntil": lockedUntil?.timeIntervalSince1970 as Any
            ]
        )

        print("RoomLockManager: Room locked by \(lockedByUsername ?? "user")")
    }

    /// Unlock the current room
    func unlockRoom() {
        guard isRoomLocked else { return }

        // Only the user who locked can unlock, or room owner/admin
        let currentUser = getCurrentUserId()
        guard canCurrentUserLock || lockedByUserId == currentUser else {
            print("RoomLockManager: Cannot unlock - not authorized")
            return
        }

        isRoomLocked = false
        lockedByUserId = nil
        lockedByUsername = nil
        lockedUntil = nil
        scheduledUnlockWorkItem?.cancel()
        scheduledUnlockWorkItem = nil

        // Play unlock sound
        AppSoundManager.shared.playSound(.toggleOff)

        // Notify server
        NotificationCenter.default.post(
            name: .roomLockStateChanged,
            object: nil,
            userInfo: ["locked": false]
        )

        print("RoomLockManager: Room unlocked")
    }

    /// Toggle room lock state
    func toggleLock() {
        if isRoomLocked {
            unlockRoom()
        } else {
            lockRoom(duration: lockDurationPreset.duration)
        }
    }

    private func scheduleUnlockIfNeeded(after duration: TimeInterval?) {
        scheduledUnlockWorkItem?.cancel()
        scheduledUnlockWorkItem = nil
        guard let duration, duration > 0 else { return }
        let workItem = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                self?.unlockRoom()
            }
        }
        scheduledUnlockWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    // MARK: - Keyboard Shortcut (Cmd+Opt+L)

    private func setupKeyboardShortcut() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            // Check for Cmd+Opt+L (keyCode 37 is L)
            let hasCmd = event.modifierFlags.contains(.command)
            let hasOpt = event.modifierFlags.contains(.option)

            if event.keyCode == 37 && hasCmd && hasOpt {
                // Don't trigger if in text field
                if let responder = NSApp.keyWindow?.firstResponder,
                   responder is NSTextView || responder is NSTextField {
                    return event
                }

                if self.canCurrentUserLock {
                    self.toggleLock()
                    return nil // Consume event
                }
            }
            return event
        }
    }

    // MARK: - Server Notifications

    private func setupNotifications() {
        // Listen for lock state changes from server
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleServerLockUpdate),
            name: .serverRoomLockUpdate,
            object: nil
        )

        // Listen for permission changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePermissionUpdate),
            name: .roomPermissionsUpdated,
            object: nil
        )
    }

    @objc private func handleServerLockUpdate(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }

        DispatchQueue.main.async {
            self.isRoomLocked = userInfo["locked"] as? Bool ?? false
            self.lockedByUserId = userInfo["userId"] as? String
            self.lockedByUsername = userInfo["username"] as? String
        }
    }

    @objc private func handlePermissionUpdate(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }

        DispatchQueue.main.async {
            self.canCurrentUserLock = userInfo["canLock"] as? Bool ?? false
        }
    }

    // MARK: - Helpers

    private func getCurrentUserId() -> String? {
        return UserDefaults.standard.string(forKey: "clientId")
    }

    private func getCurrentUsername() -> String? {
        return UserDefaults.standard.string(forKey: "username")
    }

    // MARK: - Status

    func getLockStatus() -> [String: Any] {
        return [
            "isLocked": isRoomLocked,
            "canLock": canCurrentUserLock,
            "lockedBy": lockedByUsername ?? ""
        ]
    }
}

// MARK: - Room Lock Notifications

extension Notification.Name {
    static let roomLockStateChanged = Notification.Name("roomLockStateChanged")
    static let serverRoomLockUpdate = Notification.Name("serverRoomLockUpdate")
    static let roomPermissionsUpdated = Notification.Name("roomPermissionsUpdated")
}

// MARK: - Action Menu Components

struct ActionMenuSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.gray)
                .padding(.leading, 4)
                .padding(.top, 8)

            content()
        }
    }
}

struct ActionMenuItem: View {
    let icon: String
    let label: String
    let shortcut: String?
    let description: String?
    var isActive: Bool = false
    var isToggle: Bool = false
    var isToggled: Bool = false
    var isDestructive: Bool = false
    var isPrimary: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .foregroundColor(labelColor)

                    if let desc = description {
                        Text(desc)
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }

                Spacer()

                if isToggle {
                    Toggle("", isOn: .constant(isToggled))
                        .labelsHidden()
                        .scaleEffect(0.8)
                }

                if let key = shortcut {
                    Text(key)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isActive ? Color.blue.opacity(0.2) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(accessibilityHintText)
        .accessibilityValue(accessibilityValueText)
    }

    var iconColor: Color {
        if isDestructive { return .red }
        if isPrimary { return .blue }
        if isActive { return .blue }
        return .white.opacity(0.8)
    }

    var labelColor: Color {
        if isDestructive { return .red }
        if isPrimary { return .blue }
        return .white
    }

    var accessibilityHintText: String {
        if let description, !description.isEmpty {
            return description
        }
        if isDestructive {
            return "Destructive action."
        }
        if isPrimary {
            return "Primary action."
        }
        return "Opens room action."
    }

    var accessibilityValueText: String {
        guard isToggle else { return "" }
        return isToggled ? "On" : "Off"
    }
}

struct UserVolumeMenuItem: View {
    let user: RoomUser
    @ObservedObject var audioControl = UserAudioControlManager.shared

    var volume: Float {
        audioControl.getVolume(for: user.odId)
    }

    var isMuted: Bool {
        audioControl.isMuted(user.odId)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Mute button
            Button(action: { audioControl.toggleMute(for: user.odId) }) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundColor(isMuted ? .red : .white.opacity(0.8))
                    .frame(width: 20)
            }
            .buttonStyle(.plain)

            // Username
            Text(user.username)
                .foregroundColor(.white)
                .frame(width: 80, alignment: .leading)

            // Volume slider
            Slider(
                value: Binding(
                    get: { Double(volume) },
                    set: { audioControl.setVolume(for: user.odId, volume: Float($0)) }
                ),
                in: 0...2
            )
            .disabled(isMuted)

            // Volume buttons
            Button(action: { audioControl.decreaseVolume(for: user.odId) }) {
                Image(systemName: "minus")
            }
            .buttonStyle(.plain)

            Button(action: { audioControl.increaseVolume(for: user.odId) }) {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundColor(.white.opacity(0.7))
    }
}

// MARK: - Peek Manager

class PeekManager: ObservableObject {
    static let shared = PeekManager()

    @Published var isPeeking = false
    @Published var peekingRoom: Room?
    @Published var peekTimeRemaining: Int = 0

    private var peekTimer: Timer?
    private let defaultTapPeekTime = 10 // seconds
    private let maxHoldPeekTime = 30 // seconds

    func peekIntoRoom(_ room: Room, maxDuration: Int = 10) {
        guard !isPeeking else { return }

        isPeeking = true
        peekingRoom = room
        peekTimeRemaining = max(1, maxDuration)

        // Play preview start cue if enabled.
        if SettingsManager.shared.previewSoundCuesEnabled {
            AppSoundManager.shared.playPeekInSound()
        }

        // Start countdown timer
        peekTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.peekTimeRemaining -= 1
            if self.peekTimeRemaining <= 0 {
                self.stopPeeking()
            }
        }

        // Request audio preview from server
        NotificationCenter.default.post(
            name: .startPeekingRoom,
            object: nil,
            userInfo: ["roomId": room.id]
        )

        print("PeekManager: Started peeking into \(room.name)")
    }

    func stopPeeking() {
        guard isPeeking else { return }

        // Play preview stop cue if enabled.
        if SettingsManager.shared.previewSoundCuesEnabled {
            AppSoundManager.shared.playPeekOutSound()
        }

        // Stop timer
        peekTimer?.invalidate()
        peekTimer = nil

        // Stop audio preview
        if let room = peekingRoom {
            NotificationCenter.default.post(
                name: .stopPeekingRoom,
                object: nil,
                userInfo: ["roomId": room.id]
            )
        }

        isPeeking = false
        peekingRoom = nil
        peekTimeRemaining = 0

        print("PeekManager: Stopped peeking")
    }

    @discardableResult
    func togglePreview(for room: Room, canPreview: Bool = true, maxDuration: Int? = nil) -> Bool {
        if isPeeking, peekingRoom?.id == room.id {
            stopPeeking()
            return false
        }
        guard canPreview else {
            AccessibilityManager.shared.announceStatus("Preview is unavailable for this room right now.")
            return false
        }
        if isPeeking {
            stopPeeking()
        }
        peekIntoRoom(room, maxDuration: maxDuration ?? defaultTapPeekTime)
        return true
    }

    func startHoldPreview(for room: Room, canPreview: Bool = true) {
        guard canPreview else {
            AccessibilityManager.shared.announceStatus("Preview is unavailable for this room right now.")
            return
        }
        if isPeeking, peekingRoom?.id == room.id {
            return
        }
        if isPeeking {
            stopPeeking()
        }
        peekIntoRoom(room, maxDuration: maxHoldPeekTime)
    }

    func stopHoldPreview(for room: Room) {
        guard isPeeking, peekingRoom?.id == room.id else { return }
        stopPeeking()
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let startPeekingRoom = Notification.Name("startPeekingRoom")
    static let stopPeekingRoom = Notification.Name("stopPeekingRoom")
}

// MARK: - Peek Indicator View

struct PeekIndicator: View {
    @ObservedObject var peekManager = PeekManager.shared

    var body: some View {
        if peekManager.isPeeking, let room = peekManager.peekingRoom {
            HStack(spacing: 8) {
                Image(systemName: "eye.fill")
                    .foregroundColor(.orange)

                Text("Peeking: \(room.name)")
                    .font(.caption)

                Text("\(peekManager.peekTimeRemaining)s")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.orange)

                Button(action: { peekManager.stopPeeking() }) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.2))
            .cornerRadius(20)
            .foregroundColor(.white)
        }
    }
}

// MARK: - Room Lock Indicator View

struct RoomLockIndicator: View {
    @ObservedObject var lockManager = RoomLockManager.shared

    var body: some View {
        if lockManager.isRoomLocked {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .foregroundColor(.orange)

                Text("Room Locked")
                    .font(.caption)
                    .foregroundColor(.orange)

                if lockManager.canCurrentUserLock {
                    Button(action: { lockManager.unlockRoom() }) {
                        Text("Unlock")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.15))
            .cornerRadius(16)
        }
    }
}

// MARK: - Room Lock Button (for toolbar)

struct RoomLockButton: View {
    @ObservedObject var lockManager = RoomLockManager.shared

    var body: some View {
        if lockManager.canCurrentUserLock {
            Button(action: { lockManager.toggleLock() }) {
                Image(systemName: lockManager.isRoomLocked ? "lock.fill" : "lock.open")
                    .foregroundColor(lockManager.isRoomLocked ? .orange : .white)
            }
            .buttonStyle(.plain)
            .help(lockManager.isRoomLocked ? "Unlock Room (Cmd+Opt+L)" : "Lock Room (Cmd+Opt+L)")
            .keyboardShortcut("l", modifiers: [.command, .option])
        }
    }
}
