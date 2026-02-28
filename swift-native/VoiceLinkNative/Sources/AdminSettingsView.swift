import SwiftUI

// MARK: - Admin Settings View
struct AdminSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var adminManager = AdminServerManager.shared
    @ObservedObject var authManager = AuthenticationManager.shared
    @State private var selectedTab: AdminTab = .overview
    @Environment(\.dismiss) var dismiss

    enum AdminTab: String, CaseIterable {
        case overview = "Overview"
        case users = "Users"
        case rooms = "Rooms"
        case modules = "Modules"
        case selfTests = "Self Tests"
        case config = "Server Config"
        case streams = "Background Streams"
        case apiSync = "API Sync"
        case federation = "Federation"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: { appState.closeAdminScreen() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("Server Administration")
                    .font(.title2.bold())
                    .foregroundColor(.white)

                Spacer()

                // Admin role badge
                HStack(spacing: 6) {
                    Image(systemName: adminRoleIcon)
                        .foregroundColor(adminRoleColor)
                    Text(adminManager.adminRole.rawValue.capitalized)
                        .font(.caption)
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(adminRoleColor.opacity(0.2))
                .cornerRadius(20)
            }
            .padding()
            .background(Color.black.opacity(0.3))

            // Tab bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(AdminTab.allCases, id: \.self) { tab in
                        if canAccessTab(tab) {
                            AdminTabButton(title: tab.rawValue, isSelected: selectedTab == tab) {
                                selectedTab = tab
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.2))

            // Content
            ScrollView {
                VStack(spacing: 20) {
                    switch selectedTab {
                    case .overview:
                        AdminOverviewSection()
                    case .users:
                        AdminUsersSection()
                    case .rooms:
                        AdminRoomsSection()
                    case .modules:
                        AdminModulesSection()
                    case .selfTests:
                        AdminSelfTestsSection()
                    case .config:
                        AdminConfigSection()
                    case .streams:
                        AdminStreamsSection()
                    case .apiSync:
                        AdminAPISyncSection()
                    case .federation:
                        AdminFederationSection()
                    }
                }
                .padding()
            }

            if let error = adminManager.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error)
                }
                .foregroundColor(.red)
                .padding()
                .background(Color.red.opacity(0.1))
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.1, green: 0.1, blue: 0.2),
                    Color(red: 0.05, green: 0.05, blue: 0.15)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .task {
            await adminManager.fetchServerStats()
            await adminManager.fetchServerConfig()
            await adminManager.refreshModulesCenter()
        }
    }

    private var adminRoleIcon: String {
        switch adminManager.adminRole {
        case .owner: return "crown.fill"
        case .admin: return "shield.fill"
        case .moderator: return "person.badge.shield.checkmark"
        case .none: return "person"
        }
    }

    private var adminRoleColor: Color {
        switch adminManager.adminRole {
        case .owner: return .yellow
        case .admin: return .purple
        case .moderator: return .blue
        case .none: return .gray
        }
    }

    private func canAccessTab(_ tab: AdminTab) -> Bool {
        switch tab {
        case .overview:
            return true
        case .users:
            return adminManager.adminRole.canManageUsers
        case .rooms:
            return adminManager.adminRole.canManageRooms
        case .modules:
            return adminManager.adminRole.canManageConfig
        case .selfTests:
            return adminManager.adminRole.canManageConfig
        case .config, .streams, .apiSync, .federation:
            return adminManager.adminRole.canManageConfig
        }
    }
}

// MARK: - Tab Button
struct AdminTabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : .gray)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isSelected ? Color.blue.opacity(0.3) : Color.clear)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Overview Section
struct AdminOverviewSection: View {
    @ObservedObject var adminManager = AdminServerManager.shared

    var body: some View {
        VStack(spacing: 20) {
            // Stats grid
            if let stats = adminManager.serverStats {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 16) {
                    AdminStatCard(title: "Active Users", value: "\(stats.activeUsers)", icon: "person.2.fill", color: .green)
                    AdminStatCard(title: "Total Users", value: "\(stats.totalUsers)", icon: "person.3.fill", color: .blue)
                    AdminStatCard(title: "Active Rooms", value: "\(stats.activeRooms)", icon: "bubble.left.and.bubble.right.fill", color: .purple)
                    AdminStatCard(title: "Total Rooms", value: "\(stats.totalRooms)", icon: "square.grid.2x2.fill", color: .orange)
                    AdminStatCard(title: "Peak Users", value: "\(stats.peakUsers)", icon: "chart.line.uptrend.xyaxis", color: .pink)
                    AdminStatCard(title: "Uptime", value: formatUptime(stats.uptime), icon: "clock.fill", color: .cyan)
                    AdminStatCard(title: "Messages/min", value: String(format: "%.1f", stats.messagesPerMinute), icon: "message.fill", color: .yellow)
                    AdminStatCard(title: "Bandwidth", value: formatBandwidth(stats.bandwidthUsage), icon: "network", color: .red)
                }
            } else {
                ProgressView("Loading server stats...")
                    .foregroundColor(.white)
            }

            // Server config summary
            if let config = adminManager.serverConfig {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Server Configuration")
                        .font(.headline)
                        .foregroundColor(.white)

                    HStack(spacing: 30) {
                        ConfigSummaryItem(label: "Server Name", value: config.serverName)
                        ConfigSummaryItem(label: "Max Users", value: "\(config.maxUsers)")
                        ConfigSummaryItem(label: "Max Rooms", value: "\(config.maxRooms)")
                        ConfigSummaryItem(label: "Auth Required", value: config.requireAuth ? "Yes" : "No")
                    }
                }
                .padding()
                .background(Color.white.opacity(0.05))
                .cornerRadius(12)
            }

            // Quick actions
            HStack(spacing: 15) {
                AdminQuickAction(title: "Refresh Stats", icon: "arrow.clockwise") {
                    Task {
                        await adminManager.fetchServerStats()
                    }
                }

                AdminQuickAction(title: "Broadcast Message", icon: "megaphone") {
                    let pa = PATransmissionManager.shared
                    if !pa.isPAEnabled {
                        pa.isPAEnabled = true
                    }
                    pa.toggleTransmission(target: .allRooms)
                }

                AdminQuickAction(title: "Server Logs", icon: "doc.text") {
                    adminManager.moduleActionMessage = "Server logs view is available in the Server Logs panel on web admin. Desktop log panel wiring is next."
                }
            }
        }
    }

    private func formatUptime(_ seconds: Int) -> String {
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        if days > 0 {
            return "\(days)d \(hours)h"
        }
        return "\(hours)h"
    }

    private func formatBandwidth(_ bytes: Double) -> String {
        if bytes >= 1_000_000_000 {
            return String(format: "%.1f GB", bytes / 1_000_000_000)
        } else if bytes >= 1_000_000 {
            return String(format: "%.1f MB", bytes / 1_000_000)
        }
        return String(format: "%.0f KB", bytes / 1000)
    }
}

// MARK: - Stat Card
struct AdminStatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)

            Text(value)
                .font(.title.bold())
                .foregroundColor(.white)

            Text(title)
                .font(.caption)
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }
}

// MARK: - Config Summary Item
struct ConfigSummaryItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.gray)
            Text(value)
                .font(.body)
                .foregroundColor(.white)
        }
    }
}

// MARK: - Quick Action Button
struct AdminQuickAction: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                Text(title)
            }
            .padding()
            .background(Color.blue.opacity(0.2))
            .foregroundColor(.blue)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Users Section
struct AdminUsersSection: View {
    @ObservedObject var adminManager = AdminServerManager.shared
    @State private var selectedUser: AdminUserInfo?
    @State private var showKickAlert = false
    @State private var showBanAlert = false
    @State private var kickReason = ""
    @State private var banReason = ""
    @State private var banDuration = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Connected Users (\(adminManager.connectedUsers.count))")
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()

                Button(action: {
                    Task { await adminManager.fetchConnectedUsers() }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }

            if adminManager.connectedUsers.isEmpty {
                Text("No users connected")
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                ForEach(adminManager.connectedUsers) { user in
                    UserAdminRow(user: user) { action in
                        selectedUser = user
                        switch action {
                        case .kick:
                            showKickAlert = true
                        case .ban:
                            showBanAlert = true
                        }
                    }
                }
            }
        }
        .task {
            await adminManager.fetchConnectedUsers()
        }
        .alert("Kick User", isPresented: $showKickAlert) {
            TextField("Reason (optional)", text: $kickReason)
            Button("Cancel", role: .cancel) {}
            Button("Kick", role: .destructive) {
                if let user = selectedUser {
                    Task {
                        await adminManager.kickUser(user.id, reason: kickReason.isEmpty ? nil : kickReason)
                        await adminManager.fetchConnectedUsers()
                    }
                }
            }
        }
        .alert("Ban User", isPresented: $showBanAlert) {
            TextField("Reason", text: $banReason)
            TextField("Duration (hours)", value: $banDuration, format: .number)
            Button("Cancel", role: .cancel) {}
            Button("Ban", role: .destructive) {
                if let user = selectedUser {
                    Task {
                        await adminManager.banUser(user.id, reason: banReason.isEmpty ? nil : banReason, duration: banDuration * 3600)
                        await adminManager.fetchConnectedUsers()
                    }
                }
            }
        }
    }
}

// MARK: - User Admin Row
struct UserAdminRow: View {
    let user: AdminUserInfo
    let onAction: (UserAction) -> Void

    enum UserAction {
        case kick, ban
    }

    var body: some View {
        HStack {
            // User avatar placeholder
            Circle()
                .fill(Color.blue.opacity(0.3))
                .frame(width: 40, height: 40)
                .overlay(
                    Text(String(user.username.prefix(1)).uppercased())
                        .foregroundColor(.blue)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName ?? user.username)
                    .foregroundColor(.white)
                HStack(spacing: 8) {
                    Text("@\(user.username)")
                        .font(.caption)
                        .foregroundColor(.gray)
                    if let room = user.currentRoom {
                        Text("in \(room)")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
            }

            Spacer()

            // Status indicators
            HStack(spacing: 8) {
                if user.isMuted {
                    Image(systemName: "mic.slash.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                }
                if user.isDeafened {
                    Image(systemName: "speaker.slash.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }

            // Actions
            Menu {
                Button(action: { onAction(.kick) }) {
                    Label("Kick", systemImage: "person.badge.minus")
                }
                Button(role: .destructive, action: { onAction(.ban) }) {
                    Label("Ban", systemImage: "hand.raised.slash")
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

// MARK: - Rooms Section
struct AdminRoomsSection: View {
    @ObservedObject var adminManager = AdminServerManager.shared
    @State private var showCreateRoom = false
    @State private var roomBeingEdited: AdminRoomInfo?
    @State private var roomSearchText = ""

    private var filteredRooms: [AdminRoomInfo] {
        let query = roomSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return adminManager.serverRooms }
        return adminManager.serverRooms.filter { room in
            room.name.lowercased().contains(query)
                || room.description.lowercased().contains(query)
                || room.id.lowercased().contains(query)
                || (room.visibility?.lowercased().contains(query) ?? false)
                || (room.accessType?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Server Rooms (\(adminManager.serverRooms.count))")
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()

                Button(action: { showCreateRoom = true }) {
                    Label("Create Room", systemImage: "plus")
                }
                .buttonStyle(.bordered)

                Button(action: {
                    Task { await adminManager.fetchRooms() }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Room Management Permissions")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Global Policy")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.9))
                    Text("Server roles (admin/moderator/owner) control who can manage rooms across the server.")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Individual Room Override")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.9))
                    Text("Each room can still require owner identity match. Use the room row menu to edit room-level metadata/access.")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                Text("If users report \"settings denied\", verify both global role assignment and per-room ownership identity.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(12)
            .background(Color.white.opacity(0.05))
            .cornerRadius(10)

            VStack(alignment: .leading, spacing: 10) {
                TextField("Search rooms by name, id, visibility, or access", text: $roomSearchText)
                    .textFieldStyle(.roundedBorder)

                Text("Showing \(filteredRooms.count) of \(adminManager.serverRooms.count) rooms")
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            LazyVStack(spacing: 10) {
                ForEach(filteredRooms) { room in
                    RoomAdminRow(room: room) { action in
                        switch action {
                        case .delete:
                            Task {
                                _ = await adminManager.deleteRoom(room.id)
                                await adminManager.fetchRooms()
                            }
                        case .edit:
                            roomBeingEdited = room
                        }
                    }
                }
            }
        }
        .sheet(item: $roomBeingEdited) { room in
            AdminRoomEditSheet(room: room) { updatedRoom in
                Task {
                    _ = await adminManager.updateRoom(updatedRoom)
                    await adminManager.fetchRooms()
                }
                roomBeingEdited = nil
            }
        }
        .task {
            await adminManager.fetchRooms()
        }
    }
}

// MARK: - Room Admin Row
struct RoomAdminRow: View {
    let room: AdminRoomInfo
    let onAction: (RoomAction) -> Void

    enum RoomAction {
        case edit, delete
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(room.name)
                        .foregroundColor(.white)
                    if room.isPrivate {
                        Image(systemName: "lock.fill")
                            .foregroundColor(.yellow)
                            .font(.caption)
                    }
                    if room.isPermanent {
                        Image(systemName: "pin.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                    }
                    if room.locked == true {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                    }
                }
                Text(room.description)
                    .font(.caption)
                    .foregroundColor(.gray)
                HStack(spacing: 8) {
                    Text("Visibility: \(room.visibility ?? (room.isPrivate ? "private" : "public"))")
                    Text("Access: \(room.accessType ?? "hybrid")")
                    if room.hidden == true {
                        Text("Hidden")
                    }
                    if room.enabled == false {
                        Text("Disabled")
                    }
                }
                .font(.caption2)
                .foregroundColor(.blue)
            }

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "person.fill")
                Text("\(room.userCount)/\(room.maxUsers)")
            }
            .font(.caption)
            .foregroundColor(.white.opacity(0.6))

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

struct AdminRoomEditSheet: View {
    @State private var draft: AdminRoomInfo
    let onSave: (AdminRoomInfo) -> Void
    @Environment(\.dismiss) private var dismiss

    init(room: AdminRoomInfo, onSave: @escaping (AdminRoomInfo) -> Void) {
        _draft = State(initialValue: room)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Room")
                .font(.headline)

            ConfigTextField(label: "Name", text: Binding(
                get: { draft.name },
                set: { draft.name = $0 }
            ))

            ConfigTextField(label: "Description", text: Binding(
                get: { draft.description },
                set: { draft.description = $0 }
            ))

            HStack(spacing: 16) {
                ConfigNumberField(label: "Max Users", value: Binding(
                    get: { draft.maxUsers },
                    set: { draft.maxUsers = max(1, $0) }
                ))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Visibility")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Picker("Visibility", selection: Binding(
                        get: { draft.visibility ?? (draft.isPrivate ? "private" : "public") },
                        set: {
                            draft.visibility = $0
                            draft.isPrivate = ($0 == "private")
                        }
                    )) {
                        Text("Public").tag("public")
                        Text("Unlisted").tag("unlisted")
                        Text("Private").tag("private")
                    }
                    .pickerStyle(.segmented)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Room Type")
                    .font(.caption)
                    .foregroundColor(.gray)
                Picker("Room Type", selection: Binding(
                    get: { draft.accessType ?? "hybrid" },
                    set: { draft.accessType = $0 }
                )) {
                    Text("Hybrid").tag("hybrid")
                    Text("App Only").tag("app-only")
                    Text("Web Only").tag("web-only")
                    Text("Hidden").tag("hidden")
                }
                .pickerStyle(.segmented)
            }

            ConfigToggle(label: "Private", isOn: Binding(
                get: { draft.isPrivate },
                set: {
                    draft.isPrivate = $0
                    draft.visibility = $0 ? "private" : (draft.visibility == "private" ? "public" : draft.visibility)
                }
            ))
            ConfigToggle(label: "Hidden", isOn: Binding(
                get: { draft.hidden ?? false },
                set: { draft.hidden = $0 }
            ))
            ConfigToggle(label: "Locked", isOn: Binding(
                get: { draft.locked ?? false },
                set: { draft.locked = $0 }
            ))
            ConfigToggle(label: "Enabled", isOn: Binding(
                get: { draft.enabled ?? true },
                set: { draft.enabled = $0 }
            ))
            ConfigToggle(label: "Default Room", isOn: Binding(
                get: { draft.isDefault ?? false },
                set: { draft.isDefault = $0 }
            ))

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Save") {
                    onSave(draft)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
    }
}

// MARK: - Config Section
struct AdminConfigSection: View {
    @ObservedObject var adminManager = AdminServerManager.shared
    @State private var editedConfig: ServerConfig?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let config = editedConfig ?? adminManager.serverConfig {
                Group {
                    // Server Info
                    SectionHeader(title: "Server Information")

                    VStack(spacing: 12) {
                        ConfigTextField(label: "Server Name", text: Binding(
                            get: { editedConfig?.serverName ?? config.serverName },
                            set: { editedConfig = (editedConfig ?? config).with(serverName: $0) }
                        ))

                        ConfigTextField(label: "Description", text: Binding(
                            get: { editedConfig?.serverDescription ?? config.serverDescription },
                            set: { editedConfig = (editedConfig ?? config).with(serverDescription: $0) }
                        ))

                        ConfigTextField(label: "Welcome Message", text: Binding(
                            get: { editedConfig?.welcomeMessage ?? config.welcomeMessage ?? "" },
                            set: { editedConfig = (editedConfig ?? config).with(welcomeMessage: $0.isEmpty ? nil : $0) }
                        ))
                    }

                    // Limits
                    SectionHeader(title: "Limits")

                    HStack(spacing: 20) {
                        ConfigNumberField(label: "Max Users", value: Binding(
                            get: { editedConfig?.maxUsers ?? config.maxUsers },
                            set: { editedConfig = (editedConfig ?? config).with(maxUsers: $0) }
                        ))

                        ConfigNumberField(label: "Max Rooms", value: Binding(
                            get: { editedConfig?.maxRooms ?? config.maxRooms },
                            set: { editedConfig = (editedConfig ?? config).with(maxRooms: $0) }
                        ))

                        ConfigNumberField(label: "Max Users/Room", value: Binding(
                            get: { editedConfig?.maxUsersPerRoom ?? config.maxUsersPerRoom },
                            set: { editedConfig = (editedConfig ?? config).with(maxUsersPerRoom: $0) }
                        ))
                    }

                    // Security
                    SectionHeader(title: "Security")

                    VStack(spacing: 12) {
                        ConfigToggle(label: "Registration Enabled", isOn: Binding(
                            get: { editedConfig?.registrationEnabled ?? config.registrationEnabled },
                            set: { editedConfig = (editedConfig ?? config).with(registrationEnabled: $0) }
                        ))

                        ConfigToggle(label: "Require Authentication", isOn: Binding(
                            get: { editedConfig?.requireAuth ?? config.requireAuth },
                            set: { editedConfig = (editedConfig ?? config).with(requireAuth: $0) }
                        ))
                    }

                    // Pushover
                    SectionHeader(title: "Pushover Notifications")
                    ConfigToggle(label: "Enable Pushover", isOn: Binding(
                        get: { editedConfig?.pushover?.enabled ?? config.pushover?.enabled ?? false },
                        set: { value in
                            var next = editedConfig ?? config
                            var push = next.pushover ?? PushoverConfig()
                            push.enabled = value
                            next.pushover = push
                            editedConfig = next
                        }
                    ))

                    if editedConfig?.pushover?.enabled == true || (editedConfig == nil && config.pushover?.enabled == true) {
                        VStack(spacing: 12) {
                            ConfigSecureField(label: "App Token", text: Binding(
                                get: { editedConfig?.pushover?.appToken ?? config.pushover?.appToken ?? "" },
                                set: { value in
                                    var next = editedConfig ?? config
                                    var push = next.pushover ?? PushoverConfig()
                                    push.appToken = value.isEmpty ? nil : value
                                    next.pushover = push
                                    editedConfig = next
                                }
                            ))
                            ConfigSecureField(label: "User Key", text: Binding(
                                get: { editedConfig?.pushover?.userKey ?? config.pushover?.userKey ?? "" },
                                set: { value in
                                    var next = editedConfig ?? config
                                    var push = next.pushover ?? PushoverConfig()
                                    push.userKey = value.isEmpty ? nil : value
                                    next.pushover = push
                                    editedConfig = next
                                }
                            ))
                            ConfigTextField(label: "Sound", text: Binding(
                                get: { editedConfig?.pushover?.sound ?? config.pushover?.sound ?? "pushover" },
                                set: { value in
                                    var next = editedConfig ?? config
                                    var push = next.pushover ?? PushoverConfig()
                                    push.sound = value.isEmpty ? nil : value
                                    next.pushover = push
                                    editedConfig = next
                                }
                            ))
                            ConfigNumberField(label: "Priority (-2 to 2)", value: Binding(
                                get: { editedConfig?.pushover?.priority ?? config.pushover?.priority ?? 0 },
                                set: { value in
                                    var next = editedConfig ?? config
                                    var push = next.pushover ?? PushoverConfig()
                                    push.priority = min(max(value, -2), 2)
                                    next.pushover = push
                                    editedConfig = next
                                }
                            ))
                            ConfigToggle(label: "Notify on Room Events", isOn: Binding(
                                get: { editedConfig?.pushover?.notifyOnRoomEvents ?? config.pushover?.notifyOnRoomEvents ?? true },
                                set: { value in
                                    var next = editedConfig ?? config
                                    var push = next.pushover ?? PushoverConfig()
                                    push.notifyOnRoomEvents = value
                                    next.pushover = push
                                    editedConfig = next
                                }
                            ))
                            ConfigToggle(label: "Notify on User Events", isOn: Binding(
                                get: { editedConfig?.pushover?.notifyOnUserEvents ?? config.pushover?.notifyOnUserEvents ?? true },
                                set: { value in
                                    var next = editedConfig ?? config
                                    var push = next.pushover ?? PushoverConfig()
                                    push.notifyOnUserEvents = value
                                    next.pushover = push
                                    editedConfig = next
                                }
                            ))
                        }
                    }
                }

                // Save button
                HStack {
                    Spacer()

                    if editedConfig != nil {
                        Button("Discard Changes") {
                            editedConfig = nil
                        }
                        .buttonStyle(.bordered)
                    }

                    Button(action: saveConfig) {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Save Changes")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(editedConfig == nil || isSaving)
                }
                .padding(.top)
            } else {
                ProgressView("Loading configuration...")
                    .foregroundColor(.white)
            }
        }
    }

    private func saveConfig() {
        guard let config = editedConfig else { return }
        isSaving = true

        Task {
            let success = await adminManager.updateServerConfig(config)
            isSaving = false
            if success {
                editedConfig = nil
            }
        }
    }
}

// MARK: - Background Streams Section
struct AdminStreamsSection: View {
    @ObservedObject var adminManager = AdminServerManager.shared
    @State private var streams: [BackgroundStreamConfig] = []
    @State private var showAddStream = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Background Streams")
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()

                Button(action: { showAddStream = true }) {
                    Label("Add Stream", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }

            if streams.isEmpty {
                Text("No background streams configured")
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                ForEach(streams) { stream in
                    StreamConfigRow(stream: stream) { action in
                        switch action {
                        case .delete:
                            streams.removeAll { $0.id == stream.id }
                        case .edit:
                            // TODO: Show edit sheet
                            break
                        }
                    }
                }
            }

            if !streams.isEmpty {
                Button("Save Stream Configuration") {
                    Task {
                        await adminManager.updateBackgroundStreams(streams)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear {
            if let config = adminManager.serverConfig?.backgroundStreams {
                streams = config.streams
            }
        }
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

// MARK: - API Sync Section
struct AdminAPISyncSection: View {
    @ObservedObject var adminManager = AdminServerManager.shared
    @State private var settings: APISyncSettings?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if var config = settings {
                // HubNode API
                SectionHeader(title: "HubNode API Sync")

                ConfigToggle(label: "Enable HubNode Sync", isOn: Binding(
                    get: { config.hubNodeEnabled },
                    set: { config.hubNodeEnabled = $0; settings = config }
                ))

                if config.hubNodeEnabled {
                    ConfigTextField(label: "HubNode URL", text: Binding(
                        get: { config.hubNodeUrl ?? "" },
                        set: { config.hubNodeUrl = $0.isEmpty ? nil : $0; settings = config }
                    ))

                    ConfigSecureField(label: "API Key", text: Binding(
                        get: { config.hubNodeApiKey ?? "" },
                        set: { config.hubNodeApiKey = $0.isEmpty ? nil : $0; settings = config }
                    ))
                }

                // API Monitor
                SectionHeader(title: "API Monitor")

                ConfigToggle(label: "Enable API Monitor", isOn: Binding(
                    get: { config.apiMonitorEnabled },
                    set: { config.apiMonitorEnabled = $0; settings = config }
                ))

                if config.apiMonitorEnabled {
                    ConfigTextField(label: "Monitor Endpoint", text: Binding(
                        get: { config.apiMonitorEndpoint ?? "" },
                        set: { config.apiMonitorEndpoint = $0.isEmpty ? nil : $0; settings = config }
                    ))
                }

                // WHMCS Integration
                SectionHeader(title: "WHMCS Integration")

                ConfigToggle(label: "Enable WHMCS", isOn: Binding(
                    get: { config.whmcsEnabled },
                    set: { config.whmcsEnabled = $0; settings = config }
                ))

                if config.whmcsEnabled {
                    ConfigTextField(label: "WHMCS URL", text: Binding(
                        get: { config.whmcsUrl ?? "" },
                        set: { config.whmcsUrl = $0.isEmpty ? nil : $0; settings = config }
                    ))

                    ConfigTextField(label: "API Identifier", text: Binding(
                        get: { config.whmcsApiIdentifier ?? "" },
                        set: { config.whmcsApiIdentifier = $0.isEmpty ? nil : $0; settings = config }
                    ))

                    ConfigSecureField(label: "API Secret", text: Binding(
                        get: { config.whmcsApiSecret ?? "" },
                        set: { config.whmcsApiSecret = $0.isEmpty ? nil : $0; settings = config }
                    ))
                }

                // Sync Settings
                SectionHeader(title: "Sync Settings")

                ConfigNumberField(label: "Sync Interval (seconds)", value: Binding(
                    get: { config.syncInterval },
                    set: { config.syncInterval = $0; settings = config }
                ))

                ConfigToggle(label: "Auto-sync on Changes", isOn: Binding(
                    get: { config.autoSyncOnChange },
                    set: { config.autoSyncOnChange = $0; settings = config }
                ))

                // Save button
                HStack {
                    Spacer()
                    Button(action: saveSettings) {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Save API Settings")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                }
                .padding(.top)
            } else {
                ProgressView("Loading API sync settings...")
                    .foregroundColor(.white)
            }
        }
        .task {
            settings = await adminManager.fetchAPISyncSettings()
        }
    }

    private func saveSettings() {
        guard let config = settings else { return }
        isSaving = true

        Task {
            await adminManager.updateAPISyncSettings(config)
            isSaving = false
        }
    }
}

// MARK: - Federation Section
struct AdminFederationSection: View {
    @ObservedObject var adminManager = AdminServerManager.shared
    @State private var settings: FederationSettings?
    @State private var newTrustedServer = ""
    @State private var newBlockedServer = ""
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if var config = settings {
                // Enable Federation
                ConfigToggle(label: "Enable Federation", isOn: Binding(
                    get: { config.enabled },
                    set: { config.enabled = $0; settings = config }
                ))

                if config.enabled {
                    // Direction controls
                    SectionHeader(title: "Federation Direction")

                    HStack(spacing: 20) {
                        ConfigToggle(label: "Allow Incoming", isOn: Binding(
                            get: { config.allowIncoming },
                            set: { config.allowIncoming = $0; settings = config }
                        ))

                        ConfigToggle(label: "Allow Outgoing", isOn: Binding(
                            get: { config.allowOutgoing },
                            set: { config.allowOutgoing = $0; settings = config }
                        ))
                    }

                    // Approval settings
                    SectionHeader(title: "Approval")

                    ConfigToggle(label: "Require Approval for New Servers", isOn: Binding(
                        get: { config.requireApproval },
                        set: { config.requireApproval = $0; settings = config }
                    ))

                    ConfigToggle(label: "Auto-accept Trusted Servers", isOn: Binding(
                        get: { config.autoAcceptTrusted },
                        set: { config.autoAcceptTrusted = $0; settings = config }
                    ))

                    // Trusted servers
                    SectionHeader(title: "Trusted Servers")

                    HStack {
                        TextField("Server URL", text: $newTrustedServer)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") {
                            if !newTrustedServer.isEmpty {
                                config.trustedServers.append(newTrustedServer)
                                settings = config
                                newTrustedServer = ""
                            }
                        }
                        .buttonStyle(.bordered)
                    }

                    ForEach(config.trustedServers, id: \.self) { server in
                        HStack {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundColor(.green)
                            Text(server)
                                .foregroundColor(.white)
                            Spacer()
                            Button(action: {
                                config.trustedServers.removeAll { $0 == server }
                                settings = config
                            }) {
                                Image(systemName: "xmark.circle")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    }

                    // Blocked servers
                    SectionHeader(title: "Blocked Servers")

                    HStack {
                        TextField("Server URL", text: $newBlockedServer)
                            .textFieldStyle(.roundedBorder)
                        Button("Block") {
                            if !newBlockedServer.isEmpty {
                                config.blockedServers.append(newBlockedServer)
                                settings = config
                                newBlockedServer = ""
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }

                    ForEach(config.blockedServers, id: \.self) { server in
                        HStack {
                            Image(systemName: "hand.raised.slash.fill")
                                .foregroundColor(.red)
                            Text(server)
                                .foregroundColor(.white)
                            Spacer()
                            Button(action: {
                                config.blockedServers.removeAll { $0 == server }
                                settings = config
                            }) {
                                Image(systemName: "xmark.circle")
                                    .foregroundColor(.gray)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Save button
                HStack {
                    Spacer()
                    Button(action: saveSettings) {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Save Federation Settings")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                }
                .padding(.top)
            } else {
                ProgressView("Loading federation settings...")
                    .foregroundColor(.white)
            }
        }
        .task {
            settings = await adminManager.fetchFederationSettings()
        }
    }

    private func saveSettings() {
        guard let config = settings else { return }
        isSaving = true

        Task {
            await adminManager.updateFederationSettings(config)
            isSaving = false
        }
    }
}

// MARK: - Modules Section
struct AdminModulesSection: View {
    @ObservedObject var adminManager = AdminServerManager.shared
    @State private var filterMode: ModuleFilter = .all
    @State private var query = ""
    @State private var actionInFlight: String?

    enum ModuleFilter: String, CaseIterable {
        case all = "All"
        case installed = "Installed"
        case available = "Available"
    }

    private var filteredModules: [AdminModuleInfo] {
        adminManager.availableModules
            .filter { module in
                switch filterMode {
                case .all:
                    return true
                case .installed:
                    return module.installed
                case .available:
                    return !module.installed
                }
            }
            .filter { module in
                let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !q.isEmpty else { return true }
                return module.name.lowercased().contains(q)
                    || module.id.lowercased().contains(q)
                    || module.category.lowercased().contains(q)
            }
            .sorted { a, b in
                if a.installed != b.installed {
                    return a.installed && !b.installed
                }
                if a.recommended != b.recommended {
                    return a.recommended && !b.recommended
                }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Modules Center")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Button(action: {
                    Task { await adminManager.refreshModulesCenter() }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 12) {
                Picker("Filter", selection: $filterMode) {
                    ForEach(ModuleFilter.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                TextField("Search modules", text: $query)
                    .textFieldStyle(.roundedBorder)
            }

            if adminManager.modulesLoading {
                ProgressView("Loading modules...")
                    .foregroundColor(.white)
            } else if filteredModules.isEmpty {
                Text("No modules match your filter.")
                    .foregroundColor(.gray)
                    .padding(.vertical, 12)
            } else {
                ForEach(filteredModules) { module in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(module.name)
                                        .foregroundColor(.white)
                                        .font(.headline)
                                    if module.installed {
                                        Text(module.enabled ? "Enabled" : "Disabled")
                                            .font(.caption2)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background((module.enabled ? Color.green : Color.gray).opacity(0.22))
                                            .foregroundColor(module.enabled ? .green : .gray)
                                            .cornerRadius(8)
                                    } else {
                                        Text("Not installed")
                                            .font(.caption2)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Color.orange.opacity(0.2))
                                            .foregroundColor(.orange)
                                            .cornerRadius(8)
                                    }
                                }
                                Text(module.id)
                                    .font(.caption.monospaced())
                                    .foregroundColor(.gray)
                                Text(module.description)
                                    .foregroundColor(.white.opacity(0.8))
                                    .font(.caption)
                                HStack(spacing: 8) {
                                    Text("v\(module.version)")
                                    Text(module.category.capitalized)
                                    if module.recommended { Text("Recommended") }
                                }
                                .font(.caption2)
                                .foregroundColor(.blue)
                            }
                            Spacer()
                        }

                        HStack(spacing: 10) {
                            if module.installed {
                                Button(module.enabled ? "Disable" : "Enable") {
                                    runAction("toggle-\(module.id)") {
                                        await adminManager.setModuleEnabled(module.id, enabled: !module.enabled)
                                    }
                                }
                                .buttonStyle(.bordered)

                                Button("Update") {
                                    runAction("update-\(module.id)") {
                                        await adminManager.updateModule(module.id, enabled: module.enabled)
                                    }
                                }
                                .buttonStyle(.bordered)

                                Button("Uninstall", role: .destructive) {
                                    runAction("uninstall-\(module.id)") {
                                        await adminManager.uninstallModule(module.id)
                                    }
                                }
                                .buttonStyle(.bordered)
                            } else {
                                Button("Install") {
                                    runAction("install-\(module.id)") {
                                        await adminManager.installModule(module.id)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            Spacer()
                        }
                        .disabled(actionInFlight != nil)
                    }
                    .padding()
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(10)
                }
            }

            if let message = adminManager.moduleActionMessage, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.green)
                    .padding(.top, 4)
            }
        }
        .task {
            await adminManager.refreshModulesCenter()
        }
    }

    private func runAction(_ key: String, operation: @escaping () async -> Bool) {
        actionInFlight = key
        Task {
            _ = await operation()
            actionInFlight = nil
        }
    }
}

// MARK: - Self Tests Section
struct AdminSelfTestsSection: View {
    @ObservedObject private var scheduler = SelfTestScheduler.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Built-in Self-Test Scheduler")
                .font(.headline)
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 10) {
                ConfigToggle(label: "Enable scheduler", isOn: Binding(
                    get: { scheduler.schedulerEnabled },
                    set: { scheduler.setSchedulerEnabled($0) }
                ))

                ConfigToggle(label: "Run once on app launch", isOn: Binding(
                    get: { scheduler.runOnLaunch },
                    set: { scheduler.setRunOnLaunch($0) }
                ))

                HStack {
                    Text("Interval (minutes)")
                        .foregroundColor(.gray)
                    Spacer()
                    Stepper(value: Binding(
                        get: { scheduler.intervalMinutes },
                        set: { scheduler.setIntervalMinutes($0) }
                    ), in: 1...1440) {
                        Text("\(scheduler.intervalMinutes)")
                            .foregroundColor(.white)
                            .frame(minWidth: 48, alignment: .trailing)
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        Task { await scheduler.runNow(source: "admin-manual") }
                    } label: {
                        if scheduler.isRunning {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Running...")
                            }
                        } else {
                            Label("Run Self Tests Now", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(scheduler.isRunning)

                    Button("Clear History") {
                        scheduler.clearHistory()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .background(Color.white.opacity(0.05))
            .cornerRadius(12)

            VStack(alignment: .leading, spacing: 8) {
                Text("Scheduler Status")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                statusRow("Last Run", value: scheduler.lastRunAt.map(Self.dateString) ?? "Never")
                statusRow("Next Run", value: scheduler.nextRunAt.map(Self.dateString) ?? "Not scheduled")
                statusRow("Latest Summary", value: scheduler.lastRunSummary)
                if let error = scheduler.lastError, !error.isEmpty {
                    statusRow("Last Error", value: error)
                }
            }
            .padding()
            .background(Color.white.opacity(0.05))
            .cornerRadius(12)

            VStack(alignment: .leading, spacing: 8) {
                Text("Enabled Checks")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)

                ForEach(scheduler.checks) { check in
                    HStack {
                        Toggle(check.id.title, isOn: Binding(
                            get: { check.enabled },
                            set: { scheduler.setCheckEnabled(check.id, enabled: $0) }
                        ))
                        .foregroundColor(.white)
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding()
            .background(Color.white.opacity(0.05))
            .cornerRadius(12)

            VStack(alignment: .leading, spacing: 8) {
                Text("Recent Runs")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)

                if scheduler.runHistory.isEmpty {
                    Text("No self-test runs yet.")
                        .foregroundColor(.gray)
                        .padding(.vertical, 6)
                } else {
                    ForEach(scheduler.runHistory.prefix(8)) { run in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(Self.dateString(run.finishedAt))
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                Spacer()
                                Text(run.source)
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.2))
                                    .foregroundColor(.blue)
                                    .cornerRadius(8)
                            }

                            Text(run.summary)
                                .foregroundColor(.white)
                                .font(.subheadline)

                            ForEach(run.results.prefix(6)) { result in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(color(for: result.status))
                                        .frame(width: 8, height: 8)
                                        .padding(.top, 4)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.check.title)
                                            .font(.caption.weight(.semibold))
                                            .foregroundColor(.white)
                                        Text(result.message)
                                            .font(.caption2)
                                            .foregroundColor(.white.opacity(0.78))
                                    }
                                    Spacer()
                                }
                            }
                        }
                        .padding()
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(10)
                    }
                }
            }
            .padding()
            .background(Color.white.opacity(0.05))
            .cornerRadius(12)
        }
    }

    private func color(for status: SelfTestScheduler.ResultStatus) -> Color {
        switch status {
        case .pass: return .green
        case .warn: return .yellow
        case .fail: return .red
        }
    }

    private func statusRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .foregroundColor(.white)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Helper Views

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundColor(.white)
            .padding(.top, 8)
    }
}

struct ConfigTextField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.gray)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

struct ConfigSecureField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.gray)
            SecureField("", text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

struct ConfigNumberField: View {
    let label: String
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.gray)
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
        }
    }
}

struct ConfigToggle: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn)
            .foregroundColor(.white)
    }
}

// MARK: - ServerConfig Extensions
extension ServerConfig {
    func with(serverName: String? = nil, serverDescription: String? = nil, maxUsers: Int? = nil,
              maxRooms: Int? = nil, maxUsersPerRoom: Int? = nil, welcomeMessage: String?? = nil,
              registrationEnabled: Bool? = nil, requireAuth: Bool? = nil,
              pushover: PushoverConfig?? = nil) -> ServerConfig {
        ServerConfig(
            serverName: serverName ?? self.serverName,
            serverDescription: serverDescription ?? self.serverDescription,
            maxUsers: maxUsers ?? self.maxUsers,
            maxRooms: maxRooms ?? self.maxRooms,
            maxUsersPerRoom: maxUsersPerRoom ?? self.maxUsersPerRoom,
            welcomeMessage: welcomeMessage ?? self.welcomeMessage,
            motd: self.motd,
            registrationEnabled: registrationEnabled ?? self.registrationEnabled,
            requireAuth: requireAuth ?? self.requireAuth,
            backgroundStreams: self.backgroundStreams,
            pushover: pushover ?? self.pushover
        )
    }
}
