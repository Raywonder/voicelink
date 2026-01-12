import SwiftUI

// MARK: - Admin Settings View
struct AdminSettingsView: View {
    @ObservedObject var adminManager = AdminServerManager.shared
    @ObservedObject var authManager = AuthenticationManager.shared
    @State private var selectedTab: AdminTab = .overview
    @Environment(\.dismiss) var dismiss

    enum AdminTab: String, CaseIterable {
        case overview = "Overview"
        case users = "Users"
        case rooms = "Rooms"
        case config = "Server Config"
        case streams = "Background Streams"
        case apiSync = "API Sync"
        case federation = "Federation"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: { dismiss() }) {
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
                    // TODO: Show broadcast sheet
                }

                AdminQuickAction(title: "Server Logs", icon: "doc.text") {
                    // TODO: Show logs sheet
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

            ForEach(adminManager.serverRooms) { room in
                RoomAdminRow(room: room) { action in
                    switch action {
                    case .delete:
                        Task { await adminManager.deleteRoom(room.id) }
                    case .edit:
                        // TODO: Show edit sheet
                        break
                    }
                }
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
                }
                Text(room.description)
                    .font(.caption)
                    .foregroundColor(.gray)
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
              registrationEnabled: Bool? = nil, requireAuth: Bool? = nil) -> ServerConfig {
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
            backgroundStreams: self.backgroundStreams
        )
    }
}
