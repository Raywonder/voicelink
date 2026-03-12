import SwiftUI
import AppKit

struct MainMenuView: View {
    enum RoomSortOption: String, CaseIterable, Identifiable {
        case activeFirst = "Active First"
        case mostMembers = "Most Members"
        case alphabeticalAZ = "A-Z"
        case alphabeticalZA = "Z-A"

        var id: String { rawValue }
    }
    enum RoomLayoutOption: String, CaseIterable, Identifiable {
        case list = "List"
        case grid = "Grid"
        case column = "Column"

        var id: String { rawValue }
    }
    enum RoomScopeFilter: String, CaseIterable, Identifiable {
        case all = "All Rooms"
        case publicOnly = "Public"
        case privateOnly = "Private"
        case activeUsers = "Active Users"
        case mediaActive = "Media Active"
        var id: String { rawValue }
    }

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var localDiscovery: LocalServerDiscovery
    @ObservedObject private var authManager = AuthenticationManager.shared
    @ObservedObject private var adminManager = AdminServerManager.shared
    @State private var roomSortOption: RoomSortOption = .activeFirst
    @State private var roomLayoutOption: RoomLayoutOption = .list
    @State private var roomScopeFilter: RoomScopeFilter = .all
    @State private var selectedServerFilter: String = "All Servers"
    @State private var selectedRoomDetails: Room?
    @State private var selectedRoomActionRoom: Room?
    @State private var roomBeingEditedFromMenu: AdminRoomInfo?
    @State private var showRoomActionMenuSheet = false
    @State private var showCreateInviteSheet = false
    @State private var showServerStatusSheet = false
    @State private var showRoomBrowserOptionsSheet = false
    @State private var showMastodonAuthSheet = false
    @State private var showAccountAuthSheet = false
    @State private var showEmailAuthSheet = false
    @State private var showAdminInviteSheet = false
    private let statusRefreshTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var isAuthenticatedForRoomAccess: Bool {
        authManager.authState == .authenticated && authManager.currentUser != nil
    }

    private var effectiveAuthServerURL: String {
        if let pending = authManager.pendingAdminInviteServerURL?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !pending.isEmpty {
            return pending
        }
        if let base = appState.serverManager.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !base.isEmpty {
            return base
        }
        return ServerManager.mainServer
    }

    private var registrationPortalURL: URL? {
        URL(string: "https://devine-creations.com/register.php")
    }

    private func openRegistrationPortal() {
        guard let url = registrationPortalURL else { return }
        NSWorkspace.shared.open(url)
    }

    private var hasPendingAdminInvite: Bool {
        guard let token = authManager.pendingAdminInviteToken?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !token.isEmpty
    }

    var statusColor: Color {
        switch appState.serverStatus {
        case .online: return .green
        case .connecting: return .yellow
        case .offline: return .red
        }
    }

    var statusText: String {
        switch appState.serverStatus {
        case .online: return "Connected"
        case .connecting: return "Connecting..."
        case .offline: return "Offline"
        }
    }

    var serverStatusSummary: String {
        let base = appState.serverManager.baseURL ?? ""
        let host = URL(string: base)?.host
            ?? URL(string: appState.serverManager.connectedServer)?.host
            ?? appState.serverManager.connectedServer
        let resolvedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return appState.isConnected
            ? "Connected to \(resolvedHost.isEmpty ? "active server" : SettingsManager.shared.displayNameForFederationHost(resolvedHost))"
            : statusText
    }

    private var roomFilterSummary: String {
        var parts: [String] = []
        if selectedServerFilter != "All Servers" {
            parts.append(selectedServerFilter)
        }
        if roomScopeFilter != .all {
            parts.append(roomScopeFilter.rawValue)
        }
        if roomSortOption != .activeFirst {
            parts.append(roomSortOption.rawValue)
        }
        if roomLayoutOption != .list {
            parts.append(roomLayoutOption.rawValue)
        }
        return parts.isEmpty ? "All rooms" : parts.joined(separator: " • ")
    }

    var sortedRooms: [Room] {
        switch roomSortOption {
        case .activeFirst:
            return appState.rooms.sorted {
                if ($0.userCount > 0) != ($1.userCount > 0) {
                    return $0.userCount > 0
                }
                if $0.userCount != $1.userCount {
                    return $0.userCount > $1.userCount
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .mostMembers:
            return appState.rooms.sorted {
                if $0.userCount != $1.userCount {
                    return $0.userCount > $1.userCount
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .alphabeticalAZ:
            return appState.rooms.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .alphabeticalZA:
            return appState.rooms.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending
            }
        }
    }

    private func serverLabel(for room: Room) -> String {
        let hostName = room.hostServerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !hostName.isEmpty {
            return SettingsManager.shared.displayNameForFederationHost(hostName)
        }
        let hostedFrom = room.hostedFromLine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if hostedFrom.lowercased().hasPrefix("hosted by "), hostedFrom.count > 10 {
            return SettingsManager.shared.displayNameForFederationHost(
                String(hostedFrom.dropFirst(10)).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        if !hostedFrom.isEmpty {
            return SettingsManager.shared.displayNameForFederationHost(hostedFrom)
        }
        return "Unknown Server"
    }

    var availableServerFilters: [String] {
        var unique = Set(appState.rooms.map { serverLabel(for: $0) })
        if let base = appState.serverManager.baseURL,
           let host = URL(string: base)?.host,
           !host.isEmpty {
            unique.insert(SettingsManager.shared.displayNameForFederationHost(host))
        }
        return ["All Servers"] + unique.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var filteredRooms: [Room] {
        sortedRooms.filter { room in
            let roomServerLabel = serverLabel(for: room)
            let matchesServer = selectedServerFilter == "All Servers" || roomServerLabel == selectedServerFilter
            let lowerServerLabel = roomServerLabel.lowercased()
            let isLocalOnlyRoom = lowerServerLabel.contains("localhost") || lowerServerLabel.contains("local server")
            let matchesVisibility = (!room.isPrivate || SettingsManager.shared.showPrivateMemberRooms)
                && (SettingsManager.shared.showLocalOnlyRooms || !isLocalOnlyRoom)
                && (SettingsManager.shared.showFederatedRooms || !SettingsManager.shared.isVisibleFederationHost(roomServerLabel))
                && SettingsManager.shared.isVisibleFederationHost(roomServerLabel)
            let matchesScope: Bool
            switch roomScopeFilter {
            case .all:
                matchesScope = true
            case .publicOnly:
                matchesScope = !room.isPrivate
            case .privateOnly:
                matchesScope = room.isPrivate
            case .activeUsers:
                matchesScope = room.userCount > 0
            case .mediaActive:
                matchesScope = appState.roomHasActiveMusic[room.id] == true
            }
            return matchesServer && matchesVisibility && matchesScope
        }
    }

    private func resetRoomFilters() {
        selectedServerFilter = "All Servers"
        roomScopeFilter = .all
        roomSortOption = .activeFirst
    }

    private func openFocusedRoomActionsMenu() {
        if let focused = appState.focusedRoomForQuickJoin() {
            selectedRoomActionRoom = focused
            showRoomActionMenuSheet = true
            return
        }

        if let activeId = appState.activeRoomId,
           let active = appState.rooms.first(where: { $0.id == activeId }) {
            selectedRoomActionRoom = active
            showRoomActionMenuSheet = true
        }
    }

    private func resolvedRoomForDetails(_ room: Room) -> Room {
        if let liveServerRoom = ServerManager.shared.rooms.first(where: { $0.id == room.id }) {
            return Room(from: liveServerRoom)
        }
        if let live = appState.rooms.first(where: { $0.id == room.id }) {
            return live
        }
        if appState.currentRoom?.id == room.id, let current = appState.currentRoom {
            return current
        }
        return room
    }

    private func applyScopeShortcut(_ rawValue: String) {
        switch rawValue {
        case "all":
            roomScopeFilter = .all
        case "public":
            roomScopeFilter = .publicOnly
        case "private":
            roomScopeFilter = .privateOnly
        case "active":
            roomScopeFilter = .activeUsers
        case "media":
            roomScopeFilter = .mediaActive
        default:
            break
        }
    }

    private func applySortShortcut(_ rawValue: String) {
        switch rawValue {
        case "active":
            roomSortOption = .activeFirst
        case "members":
            roomSortOption = .mostMembers
        case "az":
            roomSortOption = .alphabeticalAZ
        case "za":
            roomSortOption = .alphabeticalZA
        default:
            break
        }
    }

    private func applyLayoutShortcut(_ rawValue: String) {
        switch rawValue {
        case "list":
            roomLayoutOption = .list
        case "grid":
            roomLayoutOption = .grid
        case "column":
            roomLayoutOption = .column
        default:
            break
        }
    }

    private func shareRoom(_ room: Room) {
        let roomURL = "https://voicelink.devinecreations.net/?room=\(room.id)"
        let url = URL(string: roomURL) ?? URL(fileURLWithPath: roomURL)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(roomURL, forType: .string)
        if let contentView = NSApp.keyWindow?.contentView {
            let picker = NSSharingServicePicker(items: [url])
            picker.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minY)
        } else {
            NSWorkspace.shared.open(url)
        }
        AppSoundManager.shared.playSound(.success)
    }

    @ViewBuilder
    private func roomCardView(_ room: Room) -> some View {
        let canAdminRoom = appState.canManageRoom(room)
        RoomCard(
            room: room,
            descriptionText: appState.displayDescription(for: room),
            roomHasActiveMedia: appState.roomHasActiveMusic[room.id] == true,
            isActiveRoom: appState.activeRoomId == room.id,
            isAdmin: canAdminRoom,
            onFocus: { appState.setFocusedRoom(room) }
        ) {
            appState.joinOrShowRoom(room)
        } onPreview: {
            PeekManager.shared.togglePreview(
                for: room,
                canPreview: SettingsManager.shared.canPreviewRoom(
                    roomId: room.id,
                    userCount: room.userCount,
                    hasActiveMedia: appState.roomHasActiveMusic[room.id] == true
                )
            )
        } onShare: {
            shareRoom(room)
        } onOpenAdmin: {
            NotificationCenter.default.post(name: .roomActionEditRoom, object: room)
        } onCreateRoom: {
            appState.currentScreen = .createRoom
        } onDeleteRoom: {
            appState.deleteRoomFromMenu(room)
        } onOpenDetails: {
            selectedRoomDetails = resolvedRoomForDetails(room)
        } onOpenActionMenu: {
            selectedRoomActionRoom = room
            showRoomActionMenuSheet = true
        }
    }

    @ViewBuilder
    private func roomColumnRowView(_ room: Room) -> some View {
        let canAdminRoom = appState.canManageRoom(room)
        RoomColumnRow(
            room: room,
            descriptionText: appState.displayDescription(for: room),
            roomHasActiveMedia: appState.roomHasActiveMusic[room.id] == true,
            isActiveRoom: appState.activeRoomId == room.id,
            isAdmin: canAdminRoom,
            onFocus: { appState.setFocusedRoom(room) }
        ) {
            appState.joinOrShowRoom(room)
        } onPreview: {
            PeekManager.shared.togglePreview(
                for: room,
                canPreview: SettingsManager.shared.canPreviewRoom(
                    roomId: room.id,
                    userCount: room.userCount,
                    hasActiveMedia: appState.roomHasActiveMusic[room.id] == true
                )
            )
        } onShare: {
            shareRoom(room)
        } onOpenAdmin: {
            NotificationCenter.default.post(name: .roomActionEditRoom, object: room)
        } onCreateRoom: {
            appState.currentScreen = .createRoom
        } onDeleteRoom: {
            appState.deleteRoomFromMenu(room)
        } onOpenDetails: {
            selectedRoomDetails = resolvedRoomForDetails(room)
        } onOpenActionMenu: {
            selectedRoomActionRoom = room
            showRoomActionMenuSheet = true
        }
    }

    @ViewBuilder
    private func roomListContent(_ roomsForDisplay: [Room]) -> some View {
        switch roomLayoutOption {
        case .list:
            LazyVStack(spacing: 12) {
                ForEach(roomsForDisplay) { room in
                    roomCardView(room)
                }
            }
        case .grid:
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 280), spacing: 14, alignment: .top)
                ],
                spacing: 14
            ) {
                ForEach(roomsForDisplay) { room in
                    roomCardView(room)
                }
            }
        case .column:
            LazyVStack(spacing: 8) {
                ForEach(roomsForDisplay) { room in
                    roomColumnRowView(room)
                }
            }
        }
    }

    private var lobbyAnnouncementText: String {
        guard appState.activeRoomId == nil, appState.currentRoom == nil, appState.minimizedRoom == nil else {
            return ""
        }
        guard let config = ServerManager.shared.serverConfig else { return "" }
        let welcome = (config.lobbyWelcomeMessage ?? config.welcomeMessage)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let motd = config.motd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let motdSettings = config.motdSettings

        if motdSettings.appendToWelcomeMessage {
            return [welcome, motd].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }

        if motdSettings.enabled && motdSettings.showBeforeJoin && !motd.isEmpty {
            return motd.isEmpty ? welcome : motd
        }

        return welcome
    }

    @ViewBuilder
    private var authRequiredOverlay: some View {
        VStack(spacing: 14) {
            Text("Guest Mode Active")
                .font(.title2.weight(.semibold))
                .foregroundColor(.white)

            Text("You can browse and join rooms as a guest. Sign in to unlock full room creation and account linking.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.85))
                .multilineTextAlignment(.center)

            if hasPendingAdminInvite {
                Text("An admin invite was detected. Activate it first, then continue.")
                    .font(.caption)
                    .foregroundColor(.yellow)
            }

            HStack(spacing: 10) {
                Button("Sign In") { showAccountAuthSheet = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(maxWidth: 560)
        .background(Color.black.opacity(0.82))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 10)
    }

    @ViewBuilder
    private var mainWindowHeaderPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 10, height: 10)
                        Text(serverStatusSummary)
                            .foregroundColor(.white)
                            .font(.subheadline.weight(.semibold))
                    }
                }

                Spacer()

                Button("Server Status") {
                    showServerStatusSheet = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(alignment: .top, spacing: 16) {
                summaryChip(title: "Rooms", value: "\(appState.rooms.count)")
                summaryChip(title: "Sync", value: SettingsManager.shared.syncMode.displayName)
                summaryChip(title: "Current Room", value: (appState.currentRoom ?? appState.minimizedRoom)?.name ?? "None")
                summaryChip(title: "Audio", value: appState.serverManager.audioTransmissionStatus)
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
        .padding(.horizontal, 40)
    }

    @ViewBuilder
    private func summaryChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.gray)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundColor(.white.opacity(0.88))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.06))
        .cornerRadius(8)
    }

    var body: some View {
        let roomsForDisplay = filteredRooms
        HStack(spacing: 0) {
            // Main Content
            VStack(spacing: 30) {
                // Header
                VStack(spacing: 10) {
                    Text("VoiceLink")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundColor(.white)
                }
                .padding(.top, 40)

                if !isAuthenticatedForRoomAccess {
                    authRequiredOverlay
                        .padding(.horizontal, 40)
                }

                mainWindowHeaderPanel

            // Error message
            if let error = appState.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.horizontal, 40)
            }

                // Room List
            VStack(alignment: .leading, spacing: 15) {
                Text("Available Rooms")
                    .font(.headline)
                    .foregroundColor(.white)

                if !lobbyAnnouncementText.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Server Welcome")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white)
                        Text(lobbyAnnouncementText)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.88))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.blue.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.blue.opacity(0.35), lineWidth: 1)
                    )
                    .cornerRadius(10)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Room Filters")
                        .font(.caption)
                        .foregroundColor(.gray)

                    HStack(spacing: 12) {
                        Label(roomFilterSummary, systemImage: "line.3.horizontal.decrease.circle")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.82))
                        Spacer()
                        Picker("Room View", selection: $roomLayoutOption) {
                            ForEach(RoomLayoutOption.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                        Text("Use Room > Layout to switch views")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }

                }

                if let minimized = appState.minimizedRoom {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Minimized Room: \(minimized.name)")
                                .foregroundColor(.white)
                                .font(.subheadline.weight(.semibold))
                            Text("You are still connected. Use Show Room to restore.")
                                .foregroundColor(.gray)
                                .font(.caption)
                        }
                        Spacer()
                        Button("Show Room") {
                            appState.restoreMinimizedRoom()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Leave") {
                            appState.leaveCurrentRoom()
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                    .padding(10)
                    .background(Color.yellow.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.yellow.opacity(0.4), lineWidth: 1)
                    )
                    .cornerRadius(10)
                }

                ScrollView {
                    roomListContent(roomsForDisplay)

                        if appState.rooms.isEmpty && appState.isConnected {
                            Text("No rooms available. Create one!")
                                .foregroundColor(.gray)
                                .padding()
                        } else if appState.rooms.isEmpty && !appState.isConnected {
                            Text("Connect to server to see rooms")
                                .foregroundColor(.gray)
                                .padding()
                        }
                    }
                }
                .frame(maxHeight: 300)
                .sheet(item: $selectedRoomDetails) { room in
                    RoomDetailsSheet(
                        room: room,
                        roomHasActiveMedia: appState.roomHasActiveMusic[room.id] == true,
                        isActiveRoom: appState.activeRoomId == room.id,
                        onJoin: { appState.joinOrShowRoom(room) },
                        onShare: {
                            shareRoom(room)
                        },
                        onPreview: appState.activeRoomId == room.id ? nil : {
                            PeekManager.shared.togglePreview(
                                for: room,
                                canPreview: SettingsManager.shared.canPreviewRoom(
                                    roomId: room.id,
                                    userCount: room.userCount,
                                    hasActiveMedia: appState.roomHasActiveMusic[room.id] == true
                                )
                            )
                        }
                    )
                }
                .onReceive(NotificationCenter.default.publisher(for: .reopenRoomDetailsSheet)) { notification in
                    guard let room = notification.object as? Room else { return }
                    selectedRoomDetails = room
                }
                .onAppear {
                    if appState.isConnected {
                        appState.refreshRooms()
                        appState.refreshAdminCapabilities()
                    }
                }
                .onReceive(statusRefreshTimer) { _ in
                    guard appState.currentScreen == .mainMenu else { return }
                    guard appState.isConnected else { return }
                    appState.refreshRooms()
                    appState.refreshAdminCapabilities()
                }
                .onReceive(NotificationCenter.default.publisher(for: .roomFilterReset)) { _ in
                    resetRoomFilters()
                }
                .onReceive(NotificationCenter.default.publisher(for: .roomFilterScopeChanged)) { notification in
                    guard let value = notification.userInfo?["scope"] as? String else { return }
                    applyScopeShortcut(value)
                }
                .onReceive(NotificationCenter.default.publisher(for: .roomFilterSortChanged)) { notification in
                    guard let value = notification.userInfo?["sort"] as? String else { return }
                    applySortShortcut(value)
                }
                .onReceive(NotificationCenter.default.publisher(for: .roomFilterLayoutChanged)) { notification in
                    guard let value = notification.userInfo?["layout"] as? String else { return }
                    applyLayoutShortcut(value)
                }
                .onReceive(NotificationCenter.default.publisher(for: .roomActionOpenMenu)) { _ in
                    openFocusedRoomActionsMenu()
                }
                .onReceive(NotificationCenter.default.publisher(for: .roomActionEditRoom)) { notification in
                    guard let room = notification.object as? Room else { return }
                    guard appState.canManageRoom(room) else {
                        appState.errorMessage = "Edit denied for \(room.name). Your current account is not recognized as owner/admin on this server."
                        return
                    }
                    appState.setFocusedRoom(room)
                    roomBeingEditedFromMenu = appState.adminEditableRoomInfo(for: room)
                }
                .sheet(isPresented: $showRoomActionMenuSheet) {
                    if let room = selectedRoomActionRoom {
                        RoomActionMenu(
                            room: room,
                            isInRoom: appState.activeRoomId == room.id,
                            isPresented: $showRoomActionMenuSheet
                        )
                        .presentationDetents([.medium, .large])
                    }
                }
                .sheet(item: $roomBeingEditedFromMenu) { room in
                    AdminRoomEditSheet(room: room) { updatedRoom in
                        Task { @MainActor in
                            let saved = await AdminServerManager.shared.updateRoom(updatedRoom)
                            if saved {
                                appState.refreshRooms()
                            } else {
                                appState.errorMessage = "Could not save room changes for \(updatedRoom.name)."
                            }
                            roomBeingEditedFromMenu = nil
                        }
                    }
                }
                .sheet(isPresented: $showCreateInviteSheet) {
                    CreateAdminInviteView(isPresented: $showCreateInviteSheet)
                }
                .sheet(isPresented: $showServerStatusSheet) {
                    MainWindowServerStatusSheet(appState: appState)
                }
            }
            .padding(.horizontal, 40)

            // Action Buttons
            HStack(spacing: 20) {
                ActionButton(title: "Create Room", icon: "plus.circle.fill", color: .blue) {
                    appState.currentScreen = .createRoom
                }

                ActionButton(title: "Join or Search for Room", icon: "link.circle.fill", color: .green) {
                    appState.openJoinRoomPanel()
                }
            }
            .padding(.horizontal, 40)

            // Account Button
            HStack {
                let authManager = AuthenticationManager.shared
                if authManager.authState == .authenticated {
                    if let user = authManager.currentUser {
                        HStack {
                            Image(systemName: "person.circle.fill")
                                .foregroundColor(.green)
                            VStack(alignment: .leading) {
                                Text(user.displayName)
                                    .foregroundColor(.white)
                                    .font(.subheadline)
                                if let instance = user.mastodonInstance {
                                    Text("@\(instance)")
                                        .foregroundColor(.gray)
                                        .font(.caption)
                                }
                            }
                            Spacer()
                            if adminManager.isAdmin || adminManager.adminRole.canManageUsers || adminManager.adminRole.canManageRooms || adminManager.adminRole.canManageConfig {
                                Button("Server Administration") {
                                    appState.currentScreen = .admin
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            Button("Invite Someone") {
                                showCreateInviteSheet = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Button("Logout") {
                                NotificationCenter.default.post(name: .requestLogoutConfirmation, object: nil)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding()
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(10)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Open Registration") {
                            openRegistrationPortal()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        HStack(spacing: 10) {
                            ActionButton(title: "Sign In", icon: "person.crop.circle.badge.checkmark", color: .blue) {
                                appState.currentScreen = .login
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 40)

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .onAppear {
                selectedServerFilter = "All Servers"
                roomScopeFilter = .all
                appState.refreshRooms()
                if !isAuthenticatedForRoomAccess && hasPendingAdminInvite {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        showAdminInviteSheet = true
                    }
                }
            }
            .sheet(isPresented: $showMastodonAuthSheet) {
                MastodonAuthView(isPresented: $showMastodonAuthSheet)
            }
            .sheet(isPresented: $showAccountAuthSheet) {
                AccountPasswordAuthView(
                    isPresented: $showAccountAuthSheet,
                    serverURL: effectiveAuthServerURL
                )
            }
            .sheet(isPresented: $showEmailAuthSheet) {
                EmailAuthView(
                    isPresented: $showEmailAuthSheet,
                    serverURL: effectiveAuthServerURL
                )
            }
            .sheet(isPresented: $showAdminInviteSheet) {
                AdminInviteAuthView(isPresented: $showAdminInviteSheet)
            }

            // Right Sidebar - Connection Health & Servers
            VStack(spacing: 16) {
                Spacer()

                // Settings tip at bottom of sidebar
                HStack(spacing: 10) {
                    Text("For Settings, press Command comma.")
                        .font(.caption)
                        .foregroundColor(.gray.opacity(0.85))
                }
                .padding(.bottom, 8)
            }
            .frame(width: 280)
            .padding()
            .background(Color.black.opacity(0.2))
        }
    }
// MARK: - Room Card
struct RoomCard: View {
    @ObservedObject private var settings = SettingsManager.shared
    let room: Room
    var descriptionText: String? = nil
    let roomHasActiveMedia: Bool
    let isActiveRoom: Bool
    let isAdmin: Bool
    var onFocus: () -> Void = {}
    let onJoin: () -> Void
    var onPreview: () -> Void = {}
    var onShare: () -> Void = {}
    var onOpenAdmin: () -> Void = {}
    var onCreateRoom: () -> Void = {}
    var onDeleteRoom: () -> Void = {}
    var onOpenDetails: () -> Void = {}
    var onOpenActionMenu: () -> Void = {}

    var displayDescription: String {
        if let descriptionText {
            return descriptionText
        }
        let trimmed = room.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No description provided." : trimmed
    }

    var primaryActionLabel: String {
        switch settings.defaultRoomPrimaryAction {
        case .openDetails:
            return "Room Details"
        case .joinOrShow:
            return isActiveRoom ? "Show Room" : "Join"
        case .preview:
            return "Preview"
        case .share:
            return "Share"
        }
    }

    var primaryActionEffectText: String {
        switch settings.defaultRoomPrimaryAction {
        case .openDetails:
            return "opens room details"
        case .joinOrShow:
            return isActiveRoom ? "returns to your active room" : "joins this room"
        case .preview:
            return previewAvailable ? "starts room audio preview" : "opens room details because preview is unavailable"
        case .share:
            return "copies a room share link"
        }
    }

    var previewAvailable: Bool {
        settings.canPreviewRoom(roomId: room.id, userCount: room.userCount, hasActiveMedia: effectiveRoomHasActiveMedia)
    }

    var mediaStatusText: String {
        effectiveRoomHasActiveMedia ? "Media is playing." : "No media is playing."
    }

    var roomAccessibilitySummary: String {
        "\(room.name). \(displayDescription). Users \(room.userCount) of \(room.maxUsers). \(mediaStatusText)"
    }

    private var effectiveRoomHasActiveMedia: Bool {
        if isActiveRoom,
           ServerManager.shared.activeRoomId == room.id,
           (ServerManager.shared.currentRoomMedia?.active) == true {
            return true
        }
        return roomHasActiveMedia
    }

    var showJoinActionSeparately: Bool {
        settings.defaultRoomPrimaryAction != .joinOrShow
    }

    func runPrimaryAction() {
        switch settings.defaultRoomPrimaryAction {
        case .openDetails:
            onOpenDetails()
        case .joinOrShow:
            onJoin()
        case .preview:
            if previewAvailable { onPreview() } else { onOpenDetails() }
        case .share:
            onShare()
        }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(room.name)
                        .font(.headline)
                        .foregroundColor(.white)

                    if room.isPrivate {
                        Image(systemName: "lock.fill")
                            .foregroundColor(.yellow)
                            .font(.caption)
                    }
                }

                if settings.showRoomDescriptions {
                    Text(displayDescription)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .lineLimit(2)
                }

                if let hostedFrom = room.hostedFromLine {
                    Text(hostedFrom)
                        .font(.caption2)
                        .foregroundColor(.gray.opacity(0.85))
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "person.fill")
                Text("\(room.userCount)")
            }
            .foregroundColor(.white.opacity(0.6))
            .font(.caption)

            RoomActionSplitButton(
                primaryLabel: primaryActionLabel,
                isActiveRoom: isActiveRoom,
                isPrimaryDisabled: settings.defaultRoomPrimaryAction == .preview && !previewAvailable,
                primaryActionEffectText: primaryActionEffectText,
                onPrimaryAction: { runPrimaryAction() },
                onJoin: onJoin,
                onPreview: onPreview,
                onShare: onShare,
                onOpenDetails: onOpenDetails,
                onOpenAdmin: onOpenAdmin,
                onCreateRoom: onCreateRoom,
                onDeleteRoom: onDeleteRoom,
                onOpenActionMenu: onOpenActionMenu,
                roomId: room.id,
                roomCanPreview: previewAvailable,
                showJoinAction: showJoinActionSeparately,
                showPreviewAction: settings.defaultRoomPrimaryAction != .preview,
                isPrimaryPreviewAction: settings.defaultRoomPrimaryAction == .preview,
                onPreviewHoldStart: {
                    PeekManager.shared.startHoldPreview(for: room, canPreview: previewAvailable)
                },
                onPreviewHoldEnd: {
                    PeekManager.shared.stopHoldPreview(for: room)
                },
                isAdmin: isAdmin
            )

            VStack(alignment: .trailing, spacing: 2) {
                Text(roomHasActiveMedia ? "Media: Active" : "Media: None")
                    .font(.caption2)
                    .foregroundColor(.gray.opacity(0.95))
                Text("Users: \(room.userCount)/\(room.maxUsers)")
                    .font(.caption2)
                    .foregroundColor(.gray.opacity(0.8))
                Text(displayDescription)
                    .font(.caption2)
                    .foregroundColor(.gray.opacity(0.75))
                    .lineLimit(2)
            }
            .frame(maxWidth: 260, alignment: .trailing)
        }
        .padding()
        .background(Color.white.opacity(0.1))
        .cornerRadius(12)
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
        .onHover { hovering in
            if hovering { onFocus() }
        }
        .contextMenu {
            Button(isActiveRoom ? "Show Room" : "Join Room") { onJoin() }
            Button("Room Details") { onOpenDetails() }
            Button("Preview Room Audio") {
                if previewAvailable { onPreview() } else { onOpenDetails() }
            }
            .disabled(!previewAvailable)
            Button("Share Room Link") { onShare() }
            Button("Copy Room ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(room.id, forType: .string)
            }
            if isAdmin {
                Divider()
                Button("Edit Room Name and Description") { onOpenAdmin() }
                Button("Create New Room") { onCreateRoom() }
                Button("Delete This Room", role: .destructive) { onDeleteRoom() }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(roomAccessibilitySummary)
        .accessibilityHint("Primary button runs \(primaryActionLabel), based on your default room action setting. Use VoiceOver actions on this room for room details, preview, share, or the room context menu.")
        .accessibilityAction {
            runPrimaryAction()
        }
        .accessibilityAction(named: Text(primaryActionLabel)) { runPrimaryAction() }
        .accessibilityAction(named: Text("Room Context Menu")) { onOpenActionMenu() }
        .modifier(RoomPreviewAccessibilityModifier(
            includePreviewAction: primaryActionLabel != "Preview",
            previewAvailable: previewAvailable,
            onPreview: onPreview,
            onOpenDetails: onOpenDetails
        ))
        .accessibilityAction(named: Text("Share Room Link")) { onShare() }
        .accessibilityAction(named: Text("Room Details")) { onOpenDetails() }
    }

}

struct MainWindowServerStatusSheet: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var adminManager = AdminServerManager.shared
    @State private var federationSettings: FederationSettings?
    @State private var isLoadingFederation = false
    @State private var isRefreshing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Server Status")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button("Refresh") {
                        Task { await refresh() }
                    }
                    .disabled(isRefreshing)
                    Button("Done") { dismiss() }
                }

                GroupBox("Connection") {
                    VStack(alignment: .leading, spacing: 10) {
                        statusRow(
                            "Status",
                            value: appState.serverStatus == AppState.ServerStatus.online
                                ? "Connected"
                                : appState.serverStatus == AppState.ServerStatus.connecting
                                    ? "Connecting"
                                    : "Offline"
                        )
                        statusRow("Base URL", value: appState.serverManager.baseURL ?? "Not connected")
                        statusRow("Server Label", value: resolvedServerLabel)
                        statusRow("Sync Mode", value: SettingsManager.shared.syncMode.displayName)
                        statusRow("Audio Status", value: appState.serverManager.audioTransmissionStatus)
                    }
                }

                GroupBox("Statistics") {
                    VStack(alignment: .leading, spacing: 10) {
                        statusRow("Rooms Loaded", value: "\(appState.rooms.count)")
                        statusRow("Current Room", value: (appState.currentRoom ?? appState.minimizedRoom)?.name ?? "None")
                        statusRow("Admin Role", value: adminManager.adminRole.rawValue.capitalized)
                        statusRow("Users", value: adminManager.serverStats.map { "\($0.activeUsers) active / \($0.totalUsers) total" } ?? "Not available")
                        statusRow("Rooms", value: adminManager.serverStats.map { "\($0.activeRooms) active / \($0.totalRooms) total" } ?? "Not available")
                        statusRow("Peak Users", value: adminManager.serverStats.map { "\($0.peakUsers)" } ?? "Not available")
                        statusRow("Messages per Minute", value: adminManager.serverStats.map { String(format: "%.2f", $0.messagesPerMinute) } ?? "Not available")
                        statusRow("Bandwidth", value: adminManager.serverStats.map { String(format: "%.2f", $0.bandwidthUsage) } ?? "Not available")
                        statusRow("Uptime", value: adminManager.serverStats.map { formatDuration(seconds: $0.uptime) } ?? "Not available")
                    }
                }

                GroupBox("Federation") {
                    VStack(alignment: .leading, spacing: 10) {
                        if isLoadingFederation {
                            ProgressView()
                        } else if federationSettings == nil {
                            statusRow("Status", value: "Unavailable")
                            statusRow("Details", value: "Federation settings could not be loaded from the current server.")
                        } else {
                            statusRow("Enabled", value: boolLabel(federationSettings?.enabled))
                            statusRow("Allow Incoming", value: boolLabel(federationSettings?.allowIncoming))
                            statusRow("Allow Outgoing", value: boolLabel(federationSettings?.allowOutgoing))
                            statusRow("Trusted Servers", value: federationSettings?.trustedServers.joined(separator: ", ").nilIfEmpty ?? "None")
                            statusRow("Blocked Servers", value: federationSettings?.blockedServers.joined(separator: ", ").nilIfEmpty ?? "None")
                            statusRow("Auto Accept Trusted", value: boolLabel(federationSettings?.autoAcceptTrusted))
                            statusRow("Require Approval", value: boolLabel(federationSettings?.requireApproval))
                        }
                    }
                }

                if let config = adminManager.serverConfig {
                    GroupBox("Server Config") {
                        VStack(alignment: .leading, spacing: 10) {
                            statusRow("Name", value: config.serverName)
                            statusRow("Description", value: config.serverDescription.nilIfEmpty ?? "Not available")
                            statusRow("Max Users", value: "\(config.maxUsers)")
                            statusRow("Max Rooms", value: "\(config.maxRooms)")
                            statusRow("Max Users Per Room", value: "\(config.maxUsersPerRoom)")
                            statusRow("Registration", value: boolLabel(config.registrationEnabled))
                            statusRow("Require Auth", value: boolLabel(config.requireAuth))
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 620, minHeight: 520)
        .task {
            await refresh()
        }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        isLoadingFederation = true
        defer {
            isRefreshing = false
            isLoadingFederation = false
        }

        if let serverURL = appState.serverManager.baseURL, !serverURL.isEmpty {
            let token = AuthenticationManager.shared.currentUser?.accessToken
            await adminManager.checkAdminStatus(serverURL: serverURL, token: token)
        }

        async let stats: Void = adminManager.fetchServerStats()
        async let config: Void = adminManager.fetchServerConfig()
        let federation = await adminManager.fetchFederationSettings()
        _ = await (stats, config)
        federationSettings = federation ?? fallbackFederationSettings
    }

    @ViewBuilder
    private func statusRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.gray)
                .frame(width: 140, alignment: .leading)
            Text(value)
                .foregroundColor(.white)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func boolLabel(_ value: Bool?) -> String {
        guard let value else { return "Not available" }
        return value ? "Enabled" : "Disabled"
    }

    private func formatDuration(seconds: Int) -> String {
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private var resolvedServerLabel: String {
        if !appState.serverManager.connectedServer.isEmpty {
            return appState.serverManager.connectedServer
        }
        if let base = appState.serverManager.baseURL,
           let host = URL(string: base)?.host,
           !host.isEmpty {
            return host
        }
        return "Not connected"
    }

    private var fallbackFederationSettings: FederationSettings? {
        guard let status = appState.serverManager.publicFederationStatus else {
            return nil
        }

        return FederationSettings(
            enabled: status.enabled,
            allowIncoming: status.allowIncoming,
            allowOutgoing: status.allowOutgoing,
            trustedServers: status.trustedServers,
            blockedServers: [],
            autoAcceptTrusted: false,
            requireApproval: false,
            maintenanceModeEnabled: false,
            autoHandoffEnabled: false,
            handoffTargetServer: nil
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct RoomActionSplitButton: View {
    @ObservedObject private var roomLockManager = RoomLockManager.shared
    let primaryLabel: String
    let isActiveRoom: Bool
    let isPrimaryDisabled: Bool
    let primaryActionEffectText: String
    let onPrimaryAction: () -> Void
    let onJoin: () -> Void
    let onPreview: () -> Void
    let onShare: () -> Void
    let onOpenDetails: () -> Void
    let onOpenAdmin: () -> Void
    let onCreateRoom: () -> Void
    let onDeleteRoom: () -> Void
    let onOpenActionMenu: () -> Void
    let roomId: String
    let roomCanPreview: Bool
    let showJoinAction: Bool
    let showPreviewAction: Bool
    let isPrimaryPreviewAction: Bool
    let onPreviewHoldStart: () -> Void
    let onPreviewHoldEnd: () -> Void
    let isAdmin: Bool
    @State private var previewHoldActive = false
    @State private var previewHoldTriggered = false

    private func previewOrExplain() {
        if roomCanPreview {
            onPreview()
            return
        }
        AccessibilityManager.shared.announceStatus("Preview is unavailable. No active room audio is available or preview is disabled by policy.")
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(primaryLabel) {
                if isPrimaryPreviewAction && previewHoldTriggered {
                    return
                }
                onPrimaryAction()
            }
            .buttonStyle(.borderedProminent)
            .tint(isActiveRoom ? .green : .blue)
            .disabled(isPrimaryDisabled)
            .help("Default action \(primaryLabel). When pressed, this \(primaryActionEffectText). You can change it in Settings > General.")
            .accessibilityLabel("\(primaryLabel)")
            .accessibilityHint("Default action button. This \(primaryActionEffectText).")
            .onLongPressGesture(minimumDuration: 0.18, maximumDistance: 16, pressing: { pressing in
                guard isPrimaryPreviewAction else { return }
                if pressing {
                    guard !previewHoldActive else { return }
                    previewHoldActive = true
                    previewHoldTriggered = true
                    onPreviewHoldStart()
                } else if previewHoldActive {
                    previewHoldActive = false
                    onPreviewHoldEnd()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        previewHoldTriggered = false
                    }
                }
            }, perform: {})

            Menu {
                if showJoinAction {
                    Button(isActiveRoom ? "Show Room" : "Join Room") { onJoin() }
                }
                Button("Room Details") { onOpenDetails() }
                if showPreviewAction {
                    Button("Preview Room Audio") { previewOrExplain() }
                        .disabled(!roomCanPreview)
                        .accessibilityHint(roomCanPreview ? "Preview live room audio." : "Unavailable because room audio preview is currently disabled or there is no active room audio.")
                }
                Button("Share Room Link") { onShare() }
                Button("Copy Room ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(roomId, forType: .string)
                }
                if isAdmin {
                    Divider()
                    Button("Edit Room Name and Description") { onOpenAdmin() }
                    if isActiveRoom && roomLockManager.canCurrentUserLock {
                        Button(roomLockManager.isRoomLocked ? "Unlock Room" : "Lock Room") {
                            roomLockManager.toggleLock()
                        }
                    }
                    Button("Create New Room") { onCreateRoom() }
                    Button("Delete This Room", role: .destructive) { onDeleteRoom() }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .background((isActiveRoom ? Color.green : Color.blue).opacity(0.8))
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Room context menu")
            .accessibilityHint("Open direct room actions such as details, join, preview, share, and room management actions when allowed.")
            .help("Room context menu. VoiceOver users can open room actions from the room's VoiceOver actions.")
        }
        .contextMenu {
            if showJoinAction {
                Button(isActiveRoom ? "Show Room" : "Join Room") { onJoin() }
            }
            Button("Room Details") { onOpenDetails() }
            if showPreviewAction {
                Button("Preview Room Audio") { previewOrExplain() }
                    .disabled(!roomCanPreview)
            }
            Button("Share Room Link") { onShare() }
            Button("Copy Room ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(roomId, forType: .string)
            }
            if isAdmin {
                Divider()
                Button("Edit Room Name and Description") { onOpenAdmin() }
                if isActiveRoom && roomLockManager.canCurrentUserLock {
                    Button(roomLockManager.isRoomLocked ? "Unlock Room" : "Lock Room") {
                        roomLockManager.toggleLock()
                    }
                }
                Button("Create New Room") { onCreateRoom() }
                Button("Delete This Room", role: .destructive) { onDeleteRoom() }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct RoomColumnRow: View {
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var roomLockManager = RoomLockManager.shared
    let room: Room
    var descriptionText: String? = nil
    let roomHasActiveMedia: Bool
    let isActiveRoom: Bool
    let isAdmin: Bool
    var onFocus: () -> Void = {}
    let onJoin: () -> Void
    var onPreview: () -> Void = {}
    var onShare: () -> Void = {}
    var onOpenAdmin: () -> Void = {}
    var onCreateRoom: () -> Void = {}
    var onDeleteRoom: () -> Void = {}
    var onOpenDetails: () -> Void = {}
    var onOpenActionMenu: () -> Void = {}

    var primaryLabel: String {
        switch settings.defaultRoomPrimaryAction {
        case .openDetails:
            return "Room Details"
        case .joinOrShow:
            return isActiveRoom ? "Show Room" : "Join"
        case .preview:
            return "Preview"
        case .share:
            return "Share"
        }
    }

    var primaryActionEffectText: String {
        switch settings.defaultRoomPrimaryAction {
        case .openDetails:
            return "opens room details"
        case .joinOrShow:
            return isActiveRoom ? "returns to your active room" : "joins this room"
        case .preview:
            return previewAvailable ? "starts room audio preview" : "opens room details because preview is unavailable"
        case .share:
            return "copies a room share link"
        }
    }

    var displayDescription: String {
        descriptionText ?? (room.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No description provided." : room.description)
    }

    var mediaStatusText: String {
        effectiveRoomHasActiveMedia ? "Media is playing." : "No media is playing."
    }

    var previewAvailable: Bool {
        settings.canPreviewRoom(roomId: room.id, userCount: room.userCount, hasActiveMedia: effectiveRoomHasActiveMedia)
    }

    var roomAccessibilitySummary: String {
        "\(room.name). \(displayDescription). Users \(room.userCount) of \(room.maxUsers). \(mediaStatusText)"
    }

    private var effectiveRoomHasActiveMedia: Bool {
        if isActiveRoom,
           ServerManager.shared.activeRoomId == room.id,
           (ServerManager.shared.currentRoomMedia?.active) == true {
            return true
        }
        return roomHasActiveMedia
    }

    var showJoinActionSeparately: Bool {
        settings.defaultRoomPrimaryAction != .joinOrShow
    }

    func runPrimaryAction() {
        switch settings.defaultRoomPrimaryAction {
        case .openDetails:
            onOpenDetails()
        case .joinOrShow:
            onJoin()
        case .preview:
            if previewAvailable { onPreview() } else { onOpenDetails() }
        case .share:
            onShare()
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(room.name)
                    .foregroundColor(.white)
                    .font(.subheadline.weight(.semibold))
                Text(displayDescription)
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .lineLimit(1)
                if let hostedFrom = room.hostedFromLine {
                    Text(hostedFrom)
                        .font(.caption2)
                        .foregroundColor(.gray.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(room.userCount)")
                .frame(width: 70, alignment: .trailing)
                .foregroundColor(.white.opacity(0.75))
                .font(.caption)

            Text(isActiveRoom ? "In room" : "Available")
                .frame(width: 90, alignment: .leading)
                .foregroundColor(isActiveRoom ? .green : .gray)
                .font(.caption)

            Text(effectiveRoomHasActiveMedia ? "Media" : "No Media")
                .frame(width: 70, alignment: .leading)
                .foregroundColor(effectiveRoomHasActiveMedia ? .yellow : .gray)
                .font(.caption2)

            RoomActionSplitButton(
                primaryLabel: primaryLabel,
                isActiveRoom: isActiveRoom,
                isPrimaryDisabled: settings.defaultRoomPrimaryAction == .preview && !previewAvailable,
                primaryActionEffectText: primaryActionEffectText,
                onPrimaryAction: { runPrimaryAction() },
                onJoin: onJoin,
                onPreview: onPreview,
                onShare: onShare,
                onOpenDetails: onOpenDetails,
                onOpenAdmin: onOpenAdmin,
                onCreateRoom: onCreateRoom,
                onDeleteRoom: onDeleteRoom,
                onOpenActionMenu: onOpenActionMenu,
                roomId: room.id,
                roomCanPreview: previewAvailable,
                showJoinAction: showJoinActionSeparately,
                showPreviewAction: settings.defaultRoomPrimaryAction != .preview,
                isPrimaryPreviewAction: settings.defaultRoomPrimaryAction == .preview,
                onPreviewHoldStart: {
                    PeekManager.shared.startHoldPreview(for: room, canPreview: previewAvailable)
                },
                onPreviewHoldEnd: {
                    PeekManager.shared.stopHoldPreview(for: room)
                },
                isAdmin: isAdmin
            )
            .frame(width: 170, alignment: .trailing)
        }
        .padding(10)
        .background(Color.white.opacity(0.08))
        .cornerRadius(10)
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
        .onHover { hovering in
            if hovering { onFocus() }
        }
        .contextMenu {
            Button(isActiveRoom ? "Show Room" : "Join Room") { onJoin() }
            Button("Room Details") { onOpenDetails() }
            Button("Preview Room Audio") {
                if previewAvailable { onPreview() } else { onOpenDetails() }
            }
            .disabled(!previewAvailable)
            Button("Share Room Link") { onShare() }
            Button("Copy Room ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(room.id, forType: .string)
            }
            if isAdmin {
                Divider()
                Button("Edit Room Name and Description") { onOpenAdmin() }
                if isActiveRoom && roomLockManager.canCurrentUserLock {
                    Button(roomLockManager.isRoomLocked ? "Unlock Room" : "Lock Room") {
                        roomLockManager.toggleLock()
                    }
                }
                Button("Create New Room") { onCreateRoom() }
                Button("Delete This Room", role: .destructive) { onDeleteRoom() }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(roomAccessibilitySummary)
        .accessibilityHint("Primary button runs \(primaryLabel), based on your default room action setting. Use VoiceOver actions on this room for room details, preview, share, or the room context menu.")
        .accessibilityAction {
            runPrimaryAction()
        }
        .accessibilityAction(named: Text(primaryLabel)) { runPrimaryAction() }
        .accessibilityAction(named: Text("Room Context Menu")) { onOpenActionMenu() }
        .modifier(RoomPreviewAccessibilityModifier(
            includePreviewAction: primaryLabel != "Preview",
            previewAvailable: previewAvailable,
            onPreview: onPreview,
            onOpenDetails: onOpenDetails
        ))
        .accessibilityAction(named: Text("Share Room Link")) { onShare() }
        .accessibilityAction(named: Text("Room Details")) { onOpenDetails() }
    }
}

private struct RoomPreviewAccessibilityModifier: ViewModifier {
    let includePreviewAction: Bool
    let previewAvailable: Bool
    let onPreview: () -> Void
    let onOpenDetails: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if includePreviewAction {
            content.accessibilityAction(named: Text("Preview Room Audio")) {
                if previewAvailable { onPreview() } else { onOpenDetails() }
            }
        } else {
            content
        }
    }
}



struct RoomDetailsSheet: View {
    let room: Room
    let roomHasActiveMedia: Bool
    let isActiveRoom: Bool
    let onJoin: () -> Void
    let onShare: () -> Void
    let onPreview: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    private var effectiveRoom: Room {
        if let liveMatch = ServerManager.shared.rooms.first(where: { $0.id == room.id }) {
            return Room(from: liveMatch)
        }
        return room
    }

    private var liveRoomUsers: [RoomUser] {
        isActiveRoom ? ServerManager.shared.currentRoomUsers : []
    }

    private var liveHumanUserCount: Int {
        liveRoomUsers.filter { !$0.isBot }.count
    }

    private var canPreviewFromSheet: Bool {
        guard !isActiveRoom else { return false }
        return SettingsManager.shared.canPreviewRoom(
            roomId: effectiveRoom.id,
            userCount: effectiveRoom.userCount,
            hasActiveMedia: effectiveRoomHasActiveMedia
        )
    }

    private var totalUsersLabel: String {
        let effectiveCount = isActiveRoom && liveHumanUserCount > 0 ? liveHumanUserCount : effectiveRoom.userCount
        return "Total users in room: \(effectiveCount) of \(effectiveRoom.maxUsers)"
    }

    private var mediaStatusLabel: String {
        effectiveRoomHasActiveMedia ? "Playing" : "Not playing"
    }

    private var effectiveRoomHasActiveMedia: Bool {
        if isActiveRoom,
           ServerManager.shared.activeRoomId == effectiveRoom.id,
           (ServerManager.shared.currentRoomMedia?.active) == true {
            return true
        }
        return roomHasActiveMedia
    }

    private var serverAnnouncementTitle: String {
        roomAnnouncementText.contains("\n\n") ? "Welcome and Message of the Day" : "Room Message"
    }

    private var roomAnnouncementText: String {
        guard let config = ServerManager.shared.serverConfig else { return "" }
        let motd = config.motd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let motdSettings = config.motdSettings
        if motdSettings.enabled && motdSettings.showBeforeJoin && !motd.isEmpty {
            return motd
        }

        return ""
    }

    private var shouldShowAnnouncement: Bool {
        let text = roomAnnouncementText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty
    }

    private var uptimeLabel: String {
        if isActiveRoom {
            let joinedReference = liveRoomUsers.compactMap(\.joinedAt).min()
            if let joinedReference {
                return formatDuration(seconds: max(0, Int(Date().timeIntervalSince(joinedReference))))
            }
        }
        if let uptimeSeconds = effectiveRoom.uptimeSeconds, uptimeSeconds > 0 {
            return formatDuration(seconds: uptimeSeconds)
        }
        if let createdAt = effectiveRoom.createdAt {
            return formatDuration(seconds: max(0, Int(Date().timeIntervalSince(createdAt))))
        }
        return "Unknown"
    }

    private var lastActivityLabel: String {
        if isActiveRoom {
            let liveActivity = liveRoomUsers.compactMap(\.lastActiveAt).max()
            if let liveActivity {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .full
                let relative = formatter.localizedString(for: liveActivity, relativeTo: Date())
                if let activeUser = liveRoomUsers
                    .filter({ $0.lastActiveAt != nil })
                    .max(by: { ($0.lastActiveAt ?? .distantPast) < ($1.lastActiveAt ?? .distantPast) }),
                   let name = activeUser.displayName?.nilIfEmpty ?? activeUser.username.nilIfEmpty {
                    return "\(name) was last active \(relative)"
                }
                return "Last activity was \(relative)"
            }
        }
        guard let activityDate = effectiveRoom.lastActivityAt else {
            if let createdAt = effectiveRoom.createdAt {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .full
                return "Room was created \(formatter.localizedString(for: createdAt, relativeTo: Date()))"
            }
            let count = max(0, effectiveRoom.userCount)
            if count > 0 {
                return "\(count) user\(count == 1 ? "" : "s") currently in room"
            }
            return "No recent room activity recorded"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: activityDate, relativeTo: Date())
        if let user = effectiveRoom.lastActiveUsername?.trimmingCharacters(in: .whitespacesAndNewlines), !user.isEmpty {
            return "\(user) was last active \(relative)"
        }
        return "Last activity was \(relative)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(effectiveRoom.name)
                .font(.headline)
                .foregroundColor(.white)
            HStack(spacing: 8) {
                Image(systemName: effectiveRoom.isPrivate ? "lock.fill" : "globe")
                    .foregroundColor(effectiveRoom.isPrivate ? .yellow : .green)
                Text(effectiveRoom.isPrivate ? "Private Room" : "Public Room")
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    roomDetailRow(label: "Room ID", value: effectiveRoom.id)
                    roomDetailRow(label: "Room Type", value: effectiveRoom.roomType ?? (effectiveRoom.isPrivate ? "private" : "standard"))
                    roomDetailRow(label: "Join Status", value: isActiveRoom ? "Joined" : "Not Joined")
                    roomDetailRow(label: "Media Status", value: mediaStatusLabel)
                    roomDetailRow(label: "Users", value: totalUsersLabel)
                    roomDetailRow(label: "Uptime", value: uptimeLabel)
                    roomDetailRow(label: "Last Activity", value: lastActivityLabel)
                    if let hostedFrom = effectiveRoom.hostedFromLine, !hostedFrom.isEmpty {
                        roomDetailRow(label: "Hosted From", value: hostedFrom)
                    }
                    if !effectiveRoom.description.isEmpty {
                        roomDetailRow(label: "Description", value: effectiveRoom.description)
                    }
                    if shouldShowAnnouncement {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(serverAnnouncementTitle)
                                .font(.subheadline.bold())
                                .foregroundColor(.white)
                            Text(roomAnnouncementText)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 8)
                    }
                }
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .frame(minWidth: 380, minHeight: 560)
    }

    private func roomDetailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.gray)
            Text(value)
                .font(.caption)
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func formatDuration(seconds: Int) -> String {
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

// MARK: - Action Button
struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                Text(title)
                    .font(.caption)
            }
            .frame(width: 100, height: 80)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(color.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Placeholder Views
struct CreateRoomView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var authManager = AuthenticationManager.shared
    @ObservedObject private var adminManager = AdminServerManager.shared
    @State private var roomName = ""
    @State private var roomDescription = ""
    @State private var isPrivate = false
    @State private var password = ""
    @State private var roomType: String = "standard"
    @State private var maxUsers: Int = 50
    @State private var inviteOnly: Bool = false
    @State private var enableMediaAutoPlay: Bool = true
    @State private var enableSpatialAudio = true
    @State private var moderationNotes = ""
    @State private var hostingPreference: RoomHostingPreference = .currentServer

    private var isLoggedIn: Bool {
        authManager.authState == .authenticated && authManager.currentUser != nil
    }

    private var canCreateAdminType: Bool {
        adminManager.isAdmin || adminManager.adminRole.canManageRooms || adminManager.adminRole.canManageConfig
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Create Room")
                .font(.largeTitle)
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 15) {
                TextField("Room Name", text: $roomName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 350)

                TextField("Description (optional)", text: $roomDescription)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 350)

                Toggle("Private Room", isOn: $isPrivate)
                    .foregroundColor(.white)
                    .frame(width: 350)
                    .disabled(!isLoggedIn)

                if !isLoggedIn {
                    Text("Guest mode limits: 1 room at a time, public room only, max \(RoomManager.guestRoomMaxMembers) users.")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .frame(width: 350, alignment: .leading)
                }

                if isPrivate {
                    SecureField("Room Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 350)
                }

                if isLoggedIn {
                    Picker("Host Server", selection: $hostingPreference) {
                        ForEach(RoomHostingPreference.allCases) { preference in
                            Text(preference.displayName).tag(preference)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 350)

                    Text(hostingPreference.description)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .frame(width: 350, alignment: .leading)

                    Picker("Room Type", selection: $roomType) {
                        Text("Standard").tag("standard")
                        Text("Private").tag("private")
                        Text("Moderated").tag("moderated")
                        if canCreateAdminType {
                            Text("Admin").tag("admin")
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 350)
                    .onChange(of: roomType) { newValue in
                        if newValue == "private" || newValue == "moderated" {
                            isPrivate = true
                        }
                    }

                    Stepper("Max Users: \(maxUsers)", value: $maxUsers, in: 2...500, step: 1)
                        .foregroundColor(.white)
                        .frame(width: 350)

                    Toggle("Invite Only", isOn: $inviteOnly)
                        .foregroundColor(.white)
                        .frame(width: 350)

                    Toggle("Enable Auto-Play Room Media", isOn: $enableMediaAutoPlay)
                        .foregroundColor(.white)
                        .frame(width: 350)

                    Toggle("Enable 3D Spatial Audio", isOn: $enableSpatialAudio)
                        .foregroundColor(.white)
                        .frame(width: 350)

                    if roomType == "moderated" || roomType == "admin" {
                        TextField("Moderation notes (optional)", text: $moderationNotes)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 350)
                    }
                }
            }

            HStack(spacing: 15) {
                Button("Create") {
                    if !isLoggedIn && !RoomManager.shared.canGuestCreateRoom {
                        appState.errorMessage = "Guest limit reached. Sign in to create more rooms."
                        return
                    }

                    let effectiveRoomType = isLoggedIn ? roomType : "guest"
                    let effectiveInviteOnly = isLoggedIn ? inviteOnly : false
                    let effectiveMediaAutoPlay = isLoggedIn ? enableMediaAutoPlay : true
                    let effectiveMaxUsers = isLoggedIn
                        ? maxUsers
                        : min(maxUsers, RoomManager.guestRoomMaxMembers)
                    let effectivePrivate = isLoggedIn ? isPrivate : false

                    var metadata: [String: Any] = [
                        "maxUsers": effectiveMaxUsers,
                        "roomType": effectiveRoomType,
                        "inviteOnly": effectiveInviteOnly,
                        "mediaAutoPlay": effectiveMediaAutoPlay,
                        "spatialAudioEnabled": enableSpatialAudio,
                        "hostingPreference": hostingPreference.rawValue
                    ]
                    if isLoggedIn, let currentUser = authManager.currentUser {
                        metadata["createdBy"] = currentUser.username
                        metadata["createdByRole"] = adminManager.adminRole.rawValue
                    }
                    if !moderationNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        metadata["moderationNotes"] = moderationNotes
                    }

                    // Create room via server
                    appState.serverManager.createRoom(
                        name: roomName,
                        description: roomDescription,
                        isPrivate: effectivePrivate,
                        password: effectivePrivate ? password : nil,
                        preferredServerBase: hostingPreference.preferredServerBase,
                        metadata: metadata
                    )
                    // Go back to main menu - room will appear in list
                    appState.pendingCreateRoomName = ""
                    appState.pendingRoomDraft = nil
                    appState.currentScreen = .mainMenu
                }
                .buttonStyle(.borderedProminent)
                .disabled(roomName.isEmpty || !appState.isConnected)

                Button("Cancel") {
                    appState.pendingCreateRoomName = ""
                    appState.pendingRoomDraft = nil
                    appState.currentScreen = .mainMenu
                }
                .buttonStyle(.bordered)
            }

            if !appState.isConnected {
                Text("Connect to server to create rooms")
                    .foregroundColor(.orange)
                    .font(.caption)
            }
        }
        .onAppear {
            if let draft = appState.pendingRoomDraft {
                roomName = draft.name
                roomDescription = draft.description
                isPrivate = draft.isPrivate
                roomType = draft.roomType
                maxUsers = draft.maxUsers
                inviteOnly = draft.inviteOnly
                hostingPreference = draft.hostingPreference
                enableSpatialAudio = true
            } else if roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !appState.pendingCreateRoomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                roomName = appState.pendingCreateRoomName
            }
        }
    }
}

struct JoinRoomView: View {
    @EnvironmentObject var appState: AppState
    @State private var roomCode = ""
    @State private var domainFilter = ""
    @State private var showCreatePrompt = false

    private var query: String {
        roomCode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredRooms: [Room] {
        let q = query.lowercased()
        let domainQuery = domainFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return appState.rooms.filter { room in
            let matchesQuery = q.isEmpty
                || room.id.lowercased().contains(q)
                || room.name.lowercased().contains(q)
                || room.description.lowercased().contains(q)
                || (room.hostedFromLine?.lowercased().contains(q) ?? false)
            let matchesDomain = domainQuery.isEmpty
                || (room.hostedFromLine?.lowercased().contains(domainQuery) ?? false)
                || (room.hostServerName?.lowercased().contains(domainQuery) ?? false)
            return matchesQuery && matchesDomain
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Join or Search for Room")
                .font(.largeTitle)
                .foregroundColor(.white)

            Text("Use room ID, room name, or keywords. Search runs against the backend room list across connected public servers.")
                .font(.caption)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 620)

            TextField("Room ID, name, or keyword", text: $roomCode)
                .textFieldStyle(.roundedBorder)
                .frame(width: 520)
                .onSubmit {
                    showCreatePrompt = !appState.joinRoomByCodeOrName(roomCode)
                }

            TextField("Optional server domain filter", text: $domainFilter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 520)
                .accessibilityLabel("Server domain filter")
                .accessibilityHint("Type part or all of a server domain to narrow the matching rooms to a specific server.")

            HStack(spacing: 10) {
                Button("Join Match") {
                    showCreatePrompt = !appState.joinRoomByCodeOrName(roomCode)
                }
                .buttonStyle(.borderedProminent)
                .disabled(query.isEmpty)

                Button("Search Servers") {
                    appState.refreshRooms()
                }
                .buttonStyle(.bordered)

                Button("Create Room with This Name") {
                    let name = query.isEmpty ? "New Room" : query
                    appState.pendingCreateRoomName = name
                    appState.currentScreen = .createRoom
                }
                .buttonStyle(.bordered)

                Button("Back") {
                    appState.currentScreen = .mainMenu
                }
                .buttonStyle(.bordered)
            }

            if filteredRooms.isEmpty {
                VStack(spacing: 8) {
                    Text("No rooms found.")
                        .foregroundColor(.gray)
                    if !query.isEmpty {
                        Text("Create \"\(query)\" or refresh from connected servers.")
                            .foregroundColor(.gray)
                            .font(.caption)
                    }
                }
                .padding(.top, 10)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredRooms.prefix(80)) { room in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(room.name)
                                        .foregroundColor(.white)
                                        .font(.subheadline.weight(.semibold))
                                    Text("\(room.id) • \(room.userCount)/\(room.maxUsers)")
                                        .foregroundColor(.gray)
                                        .font(.caption2)
                                    if let hosted = room.hostedFromLine {
                                        Text(hosted)
                                            .foregroundColor(.gray.opacity(0.9))
                                            .font(.caption2)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Button(appState.activeRoomId == room.id ? "Show" : "Join") {
                                    appState.setFocusedRoom(room)
                                    appState.joinOrShowRoom(room)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(10)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(10)
                        }
                    }
                }
                .frame(width: 620, height: 300)
            }
        }
        .onAppear {
            if roomCode.isEmpty, let focused = appState.focusedRoomForQuickJoin() {
                roomCode = focused.name
            }
        }
        .alert("Room Not Found", isPresented: $showCreatePrompt) {
            Button("Create Room") {
                let name = query.isEmpty ? "New Room" : query
                appState.pendingCreateRoomName = name
                appState.currentScreen = .createRoom
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The room \"\(query)\" does not exist. Would you like to create it?")
        }
    }
}

