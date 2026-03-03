import SwiftUI
import AppKit

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
            async let stats: Void = adminManager.fetchServerStats()
            async let config: Void = adminManager.fetchServerConfig()
            async let advanced: Void = adminManager.fetchAdvancedServerSettings()
            async let modules: Void = adminManager.refreshModulesCenter()
            _ = await (stats, config, advanced, modules)
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
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(isSelected ? "Current server administration tab." : "Opens the \(title) tab.")
    }
}

// MARK: - Overview Section
struct AdminOverviewSection: View {
    @ObservedObject var adminManager = AdminServerManager.shared
    @State private var showLogsSheet = false

    var body: some View {
        VStack(spacing: 20) {
            overviewHeader

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

                operationalSummary(stats: stats)
            } else {
                ProgressView("Loading server stats...")
                    .foregroundColor(.white)
            }

            // Server config summary
            if let config = adminManager.serverConfig {
                serverConfigurationSummary(config: config)
            }

            modulesSummary

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
                    showLogsSheet = true
                    Task { await adminManager.fetchServerLogs() }
                }
            }
        }
        .sheet(isPresented: $showLogsSheet) {
            AdminServerLogsSheet()
        }
    }

    private var overviewHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Overview")
                .font(.title2.bold())
                .foregroundColor(.white)
            Text("Current server health, capacity, and installed feature summary.")
                .font(.subheadline)
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.white.opacity(0.04))
        .cornerRadius(12)
    }

    private func operationalSummary(stats: ServerStats) -> some View {
        let occupancy = stats.totalUsers > 0
            ? String(format: "%.0f%%", (Double(stats.activeUsers) / Double(max(stats.totalUsers, 1))) * 100.0)
            : "0%"
        let roomActivity = stats.totalRooms > 0
            ? String(format: "%.0f%%", (Double(stats.activeRooms) / Double(max(stats.totalRooms, 1))) * 100.0)
            : "0%"

        return VStack(alignment: .leading, spacing: 12) {
            Text("Operational Summary")
                .font(.headline)
                .foregroundColor(.white)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                AdminSummaryPanel(
                    title: "User Activity",
                    lines: [
                        "Currently active: \(stats.activeUsers)",
                        "Known total users: \(stats.totalUsers)",
                        "Activity ratio: \(occupancy)"
                    ],
                    icon: "person.3.sequence.fill",
                    color: .green
                )

                AdminSummaryPanel(
                    title: "Room Activity",
                    lines: [
                        "Open rooms: \(stats.totalRooms)",
                        "Active rooms: \(stats.activeRooms)",
                        "Room activity ratio: \(roomActivity)"
                    ],
                    icon: "rectangle.3.group.bubble.left.fill",
                    color: .purple
                )

                AdminSummaryPanel(
                    title: "Traffic",
                    lines: [
                        "Messages per minute: \(String(format: "%.1f", stats.messagesPerMinute))",
                        "Bandwidth used: \(formatBandwidth(stats.bandwidthUsage))",
                        "Peak concurrent users: \(stats.peakUsers)"
                    ],
                    icon: "waveform.path.ecg.rectangle.fill",
                    color: .orange
                )

                AdminSummaryPanel(
                    title: "Runtime",
                    lines: [
                        "Server uptime: \(formatLongUptime(stats.uptime))",
                        "Quick view: \(formatUptime(stats.uptime))",
                        "Status: \(stats.activeRooms > 0 || stats.activeUsers > 0 ? "Busy" : "Standing by")"
                    ],
                    icon: "clock.arrow.circlepath",
                    color: .cyan
                )
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }

    private func serverConfigurationSummary(config: ServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Server Configuration")
                .font(.headline)
                .foregroundColor(.white)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                ConfigSummaryItem(label: "Server Name", value: config.serverName)
                ConfigSummaryItem(label: "Auth Required", value: config.requireAuth ? "Yes" : "No")
                ConfigSummaryItem(label: "Registration Enabled", value: config.registrationEnabled ? "Yes" : "No")
                ConfigSummaryItem(label: "Guest Access", value: config.requireAuth ? "Restricted" : "Allowed")
                ConfigSummaryItem(label: "Max Users", value: "\(config.maxUsers)")
                ConfigSummaryItem(label: "Max Rooms", value: "\(config.maxRooms)")
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }

    private var modulesSummary: some View {
        let installedCount = adminManager.availableModules.filter(\.installed).count
        let enabledCount = adminManager.availableModules.filter { $0.installed && $0.enabled }.count
        let recommendedMissing = adminManager.availableModules.filter { $0.recommended && !$0.installed }
        let recommendationSummary: String = {
            if recommendedMissing.isEmpty {
                return "Recommended set appears complete"
            }
            return "\(recommendedMissing.count) recommended pending"
        }()

        return VStack(alignment: .leading, spacing: 12) {
            Text("Installed Features")
                .font(.headline)
                .foregroundColor(.white)

            HStack(spacing: 24) {
                ConfigSummaryItem(label: "Installed Modules", value: "\(installedCount)")
                ConfigSummaryItem(label: "Enabled Modules", value: "\(enabledCount)")
                ConfigSummaryItem(label: "Recommended Status", value: recommendationSummary)
            }

            if recommendedMissing.isEmpty {
                Text("All recommended modules currently appear installed.")
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                Text("Recommended not installed: \(recommendedMissing.prefix(3).map(\.name).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundColor(.yellow)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }

    private func formatUptime(_ seconds: Int) -> String {
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        if days > 0 {
            return "\(days)d \(hours)h"
        }
        return "\(hours)h"
    }

    private func formatLongUptime(_ seconds: Int) -> String {
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 {
            return "\(days) days, \(hours) hours, \(minutes) minutes"
        }
        if hours > 0 {
            return "\(hours) hours, \(minutes) minutes"
        }
        return "\(minutes) minutes"
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

struct AdminServerLogsSheet: View {
    @ObservedObject var adminManager = AdminServerManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Server Logs")
                        .font(.headline)
                    Text(adminManager.serverLogSource ?? "No log source available")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                Spacer()
                Button("Refresh") {
                    Task { await adminManager.fetchServerLogs() }
                }
                .buttonStyle(.bordered)
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }

            if adminManager.serverLogLines.isEmpty {
                Text("No logs available.")
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(adminManager.serverLogLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 520)
        .background(Color.black.opacity(0.94))
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
                .font(.body.weight(.medium))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.black.opacity(0.18))
        .cornerRadius(10)
    }
}

struct AdminSummaryPanel: View {
    let title: String
    let lines: [String]
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(color)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
            }

            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.black.opacity(0.18))
        .cornerRadius(10)
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
    @State private var roomPendingDelete: AdminRoomInfo?

    private var filteredRooms: [AdminRoomInfo] {
        let query = roomSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return adminManager.serverRooms }
        return adminManager.serverRooms.filter { room in
            room.name.lowercased().contains(query)
                || room.description.lowercased().contains(query)
                || room.id.lowercased().contains(query)
                || (room.visibility?.lowercased().contains(query) ?? false)
                || (room.accessType?.lowercased().contains(query) ?? false)
                || (room.hostServerName?.lowercased().contains(query) ?? false)
                || (room.serverSource?.lowercased().contains(query) ?? false)
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
                Text("Only one room per server/source is shown here. Duplicate entries from the same server are merged.")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            LazyVStack(spacing: 10) {
                ForEach(filteredRooms) { room in
                    RoomAdminRow(room: room) { action in
                        switch action {
                        case .delete:
                            roomPendingDelete = room
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
        .confirmationDialog(
            roomPendingDelete == nil ? "Delete room" : "Delete \(roomPendingDelete?.name ?? "room")?",
            isPresented: Binding(
                get: { roomPendingDelete != nil },
                set: { if !$0 { roomPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let room = roomPendingDelete, room.userCount > 0 {
                Button("Disable Room Instead") {
                    Task {
                        var disabled = room
                        disabled.hidden = true
                        disabled.enabled = false
                        disabled.locked = true
                        _ = await adminManager.updateRoom(disabled)
                        await adminManager.fetchRooms()
                    }
                    roomPendingDelete = nil
                }
            }

            Button("Delete Room", role: .destructive) {
                guard let room = roomPendingDelete else { return }
                Task {
                    _ = await adminManager.deleteRoom(room.id)
                    await adminManager.fetchRooms()
                }
                roomPendingDelete = nil
            }

            Button("Cancel", role: .cancel) {
                roomPendingDelete = nil
            }
        } message: {
            if let room = roomPendingDelete, room.userCount > 0 {
                Text("This room currently has \(room.userCount) user(s). Disable it first or move users to another room before deleting.")
            } else {
                Text("This permanently removes the room from the server.")
            }
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

    private var roomSourceLabel: String {
        room.hostServerName ?? room.serverSource ?? "Current Server"
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
                Text("Displayed from: \(roomSourceLabel)")
                    .font(.caption2)
                    .foregroundColor(.mint)
                if let owner = room.hostServerOwner, !owner.isEmpty {
                    Text("Server owner: \(owner)")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                if let updatedBy = room.updatedBy, !updatedBy.isEmpty {
                    Text("Last updated by: \(updatedBy)\(room.updatedAt.map { " on \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")")
                        .font(.caption2)
                        .foregroundColor(.orange)
                } else if let updatedAt = room.updatedAt {
                    Text("Last updated: \(updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
                if !room.previousNames.isEmpty {
                    Text("Prior names: \(room.previousNames.prefix(5).joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundColor(.purple)
                        .lineLimit(2)
                }
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
                Text("Total users in room: \(room.userCount) of \(room.maxUsers) max")
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
    @State private var editedAdvancedSettings: AdvancedServerSettings?
    @State private var selectedSection: ConfigSection = .identity
    @State private var isSaving = false

    enum ConfigSection: String, CaseIterable {
        case identity = "Identity"
        case access = "Access"
        case database = "Database"
        case notifications = "Notifications"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            AdminHelpSection(
                title: "Quick Help",
                summary: "Use this tab to update the server identity and hard limits the desktop client relies on.",
                steps: [
                    "Set the server name and description shown across rooms and server status.",
                    "Adjust maximum users, rooms, and users per room for this server.",
                    "Save changes, then refresh the Overview tab to confirm the new values."
                ],
                docs: [
                    AdminDocLink(title: "Server Config Docs", localRelativePath: "authenticated/admin-panel.html", webPath: "/docs/index.html", adminWebPath: "/docs/authenticated/admin-panel.html"),
                    AdminDocLink(title: "Admin UI Notes", localRelativePath: "authenticated/index.html", webPath: "/docs/index.html", adminWebPath: "/docs/authenticated/index.html")
                ]
            )

            if let config = editedConfig ?? adminManager.serverConfig {
                VStack(alignment: .leading, spacing: 16) {
                    configSectionPicker

                    switch selectedSection {
                    case .identity:
                        identitySection(config: config)
                    case .access:
                        accessSection(config: config)
                    case .database:
                        databaseSection
                    case .notifications:
                        notificationsSection(config: config)
                    }
                }

                // Save button
                HStack {
                    Spacer()

                    if editedConfig != nil || editedAdvancedSettings != nil {
                        Button("Discard Changes") {
                            editedConfig = nil
                            editedAdvancedSettings = nil
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
                    .disabled((editedConfig == nil && editedAdvancedSettings == nil) || isSaving)
                }
                .padding(.top)
            } else {
                ProgressView("Loading configuration...")
                    .foregroundColor(.white)
            }
        }
        .task {
            if (adminManager.serverConfig == nil || adminManager.advancedServerSettings == nil) && !adminManager.isLoading {
                async let config: Void = adminManager.fetchServerConfig()
                async let advanced: Void = adminManager.fetchAdvancedServerSettings()
                _ = await (config, advanced)
            }
        }
    }

    private var configSectionPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings Sections")
                .font(.headline)
                .foregroundColor(.white)

            HStack(spacing: 8) {
                ForEach(ConfigSection.allCases, id: \.self) { section in
                    Button(action: { selectedSection = section }) {
                        Text(section.rawValue)
                            .font(.caption.weight(selectedSection == section ? .semibold : .regular))
                            .foregroundColor(selectedSection == section ? .white : .gray)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(selectedSection == section ? Color.blue.opacity(0.35) : Color.white.opacity(0.06))
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(section.rawValue)
                    .accessibilityValue(selectedSection == section ? "Selected" : "Not selected")
                }
            }
        }
    }

    private func identitySection(config: ServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 18) {
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

                ConfigTextField(label: "Message of the Day", text: Binding(
                    get: { editedConfig?.motd ?? config.motd ?? "" },
                    set: { editedConfig = (editedConfig ?? config).with(motd: $0.isEmpty ? nil : $0) }
                ))

                SectionHeader(title: "Message Display")

                ConfigToggle(label: "Enable Message of the Day", isOn: Binding(
                    get: { editedConfig?.motdSettings.enabled ?? config.motdSettings.enabled },
                    set: { editedConfig = (editedConfig ?? config).with(motdSettings: (editedConfig ?? config).motdSettingsUpdating(enabled: $0)) }
                ))

                ConfigToggle(label: "Show Before Joining Rooms", isOn: Binding(
                    get: { editedConfig?.motdSettings.showBeforeJoin ?? config.motdSettings.showBeforeJoin },
                    set: { editedConfig = (editedConfig ?? config).with(motdSettings: (editedConfig ?? config).motdSettingsUpdating(showBeforeJoin: $0)) }
                ))

                ConfigToggle(label: "Show Inside Joined Rooms", isOn: Binding(
                    get: { editedConfig?.motdSettings.showInRoom ?? config.motdSettings.showInRoom },
                    set: { editedConfig = (editedConfig ?? config).with(motdSettings: (editedConfig ?? config).motdSettingsUpdating(showInRoom: $0)) }
                ))

                ConfigToggle(label: "Append MOTD to Welcome Message", isOn: Binding(
                    get: { editedConfig?.motdSettings.appendToWelcomeMessage ?? config.motdSettings.appendToWelcomeMessage },
                    set: { editedConfig = (editedConfig ?? config).with(motdSettings: (editedConfig ?? config).motdSettingsUpdating(appendToWelcomeMessage: $0)) }
                ))

                SectionHeader(title: "Maintenance Handoff Defaults")

                Text("This sets the server-recommended behavior for users when maintenance or failover handoff is offered. A user's explicit client choice still overrides this default.")
                    .font(.caption)
                    .foregroundColor(.gray)

                Picker("Recommended Client Prompt Mode", selection: Binding(
                    get: { editedConfig?.handoffPromptMode ?? config.handoffPromptMode },
                    set: { editedConfig = (editedConfig ?? config).with(handoffPromptMode: $0) }
                )) {
                    ForEach(HandoffPromptMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)

                Text(HandoffPromptMode(rawValue: editedConfig?.handoffPromptMode ?? config.handoffPromptMode)?.description ?? HandoffPromptMode.serverRecommended.description)
                    .font(.caption)
                    .foregroundColor(.gray)
            }

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
        }
    }

    private func accessSection(config: ServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: "Security and Access")

            VStack(spacing: 12) {
                ConfigToggle(label: "Registration Enabled", isOn: Binding(
                    get: { editedConfig?.registrationEnabled ?? config.registrationEnabled },
                    set: { editedConfig = (editedConfig ?? config).with(registrationEnabled: $0) }
                ))

                ConfigToggle(label: "Require Authentication", isOn: Binding(
                    get: { editedConfig?.requireAuth ?? config.requireAuth },
                    set: { editedConfig = (editedConfig ?? config).with(requireAuth: $0) }
                ))

                ConfigToggle(label: "Allow Guests", isOn: Binding(
                    get: { editedConfig?.allowGuests ?? config.allowGuests },
                    set: { editedConfig = (editedConfig ?? config).with(allowGuests: $0) }
                ))

                ConfigToggle(label: "Enable Rate Limiting", isOn: Binding(
                    get: { editedConfig?.enableRateLimiting ?? config.enableRateLimiting },
                    set: { editedConfig = (editedConfig ?? config).with(enableRateLimiting: $0) }
                ))

                ConfigNumberField(label: "Guest Session Limit (minutes, 0 = unlimited)", value: Binding(
                    get: {
                        let seconds = editedConfig?.maxGuestDuration ?? config.maxGuestDuration ?? 0
                        return seconds > 0 ? max(1, seconds / 60) : 0
                    },
                    set: { minutes in
                        let seconds = minutes > 0 ? minutes * 60 : nil
                        editedConfig = (editedConfig ?? config).with(maxGuestDuration: seconds)
                    }
                ))
            }
        }
    }

    @ViewBuilder
    private var databaseSection: some View {
        if let settings = editedAdvancedSettings ?? adminManager.advancedServerSettings {
            SectionHeader(title: "Database")

            ConfigToggle(label: "Enable External Database", isOn: Binding(
                get: { (editedAdvancedSettings ?? settings).database.enabled },
                set: { value in
                    var next = editedAdvancedSettings ?? settings
                    next.database.enabled = value
                    editedAdvancedSettings = next
                }
            ))

            HStack(spacing: 12) {
                Text("Provider")
                    .foregroundColor(.white)
                Picker("Provider", selection: Binding(
                    get: { (editedAdvancedSettings ?? settings).database.provider },
                    set: { value in
                        var next = editedAdvancedSettings ?? settings
                        next.database.provider = value
                        editedAdvancedSettings = next
                    }
                )) {
                    Text("SQLite").tag("sqlite")
                    Text("PostgreSQL").tag("postgres")
                    Text("MySQL").tag("mysql")
                    Text("MariaDB").tag("mariadb")
                }
                .pickerStyle(.segmented)
            }

            let selectedProvider = (editedAdvancedSettings ?? settings).database.provider
            if selectedProvider == "sqlite" {
                ConfigTextField(label: "SQLite Path", text: Binding(
                    get: { (editedAdvancedSettings ?? settings).database.sqlite.path },
                    set: { value in
                        var next = editedAdvancedSettings ?? settings
                        next.database.sqlite.path = value
                        editedAdvancedSettings = next
                    }
                ))
            } else {
                ConfigTextField(label: "Host", text: Binding(
                    get: { databaseNetworkConfig(from: editedAdvancedSettings ?? settings, provider: selectedProvider).host },
                    set: { value in updateDatabaseNetworkConfig(provider: selectedProvider) { $0.host = value } }
                ))

                HStack(spacing: 20) {
                    ConfigNumberField(label: "Port", value: Binding(
                        get: { databaseNetworkConfig(from: editedAdvancedSettings ?? settings, provider: selectedProvider).port },
                        set: { value in updateDatabaseNetworkConfig(provider: selectedProvider) { $0.port = value } }
                    ))
                    ConfigTextField(label: "Database", text: Binding(
                        get: { databaseNetworkConfig(from: editedAdvancedSettings ?? settings, provider: selectedProvider).database },
                        set: { value in updateDatabaseNetworkConfig(provider: selectedProvider) { $0.database = value } }
                    ))
                }

                HStack(spacing: 20) {
                    ConfigTextField(label: "User", text: Binding(
                        get: { databaseNetworkConfig(from: editedAdvancedSettings ?? settings, provider: selectedProvider).user },
                        set: { value in updateDatabaseNetworkConfig(provider: selectedProvider) { $0.user = value } }
                    ))
                    ConfigSecureField(label: "Password", text: Binding(
                        get: { databaseNetworkConfig(from: editedAdvancedSettings ?? settings, provider: selectedProvider).password },
                        set: { value in updateDatabaseNetworkConfig(provider: selectedProvider) { $0.password = value } }
                    ))
                }

                ConfigToggle(label: "Use SSL", isOn: Binding(
                    get: { databaseNetworkConfig(from: editedAdvancedSettings ?? settings, provider: selectedProvider).ssl },
                    set: { value in updateDatabaseNetworkConfig(provider: selectedProvider) { $0.ssl = value } }
                ))
            }
        }
    }

    private func notificationsSection(config: ServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 18) {
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
    }

    private func saveConfig() {
        isSaving = true

        Task {
            var success = true
            if let config = editedConfig {
                success = await adminManager.updateServerConfig(config) && success
            }
            if let advanced = editedAdvancedSettings {
                success = await adminManager.updateAdvancedServerSettings(advanced) && success
            }
            isSaving = false
            if success {
                editedConfig = nil
                editedAdvancedSettings = nil
            }
        }
    }

    private func databaseNetworkConfig(from settings: AdvancedServerSettings, provider: String) -> DatabaseNetworkConfig {
        switch provider {
        case "postgres":
            return settings.database.postgres
        case "mysql":
            return settings.database.mysql
        case "mariadb":
            return settings.database.mariadb
        default:
            return settings.database.postgres
        }
    }

    private func updateDatabaseNetworkConfig(provider: String, mutate: (inout DatabaseNetworkConfig) -> Void) {
        var next = editedAdvancedSettings ?? adminManager.advancedServerSettings ?? AdvancedServerSettings()
        switch provider {
        case "postgres":
            mutate(&next.database.postgres)
        case "mysql":
            mutate(&next.database.mysql)
        case "mariadb":
            mutate(&next.database.mariadb)
        default:
            mutate(&next.database.postgres)
        }
        editedAdvancedSettings = next
    }
}

// MARK: - Background Streams Section
struct AdminStreamsSection: View {
    @ObservedObject var adminManager = AdminServerManager.shared
    @State private var streams: [BackgroundStreamConfig] = []
    @State private var showAddStream = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AdminHelpSection(
                title: "Quick Help",
                summary: "Background streams let you keep radio or ambient audio available in selected rooms without manual playback each time.",
                steps: [
                    "Add a named stream and paste the direct stream URL, not the station web page.",
                    "Set volume and auto-play for rooms that should start with media already active.",
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
            AdminHelpSection(
                title: "Quick Help",
                summary: "API Sync connects this VoiceLink server to external control systems such as HubNode and WHMCS-backed services.",
                steps: [
                    "Enable only the integrations you actively use for this install.",
                    "Set the upstream URLs and credentials, then save and refresh the tab.",
                    "Use WHMCS fields for hosted account linking and license-aware server ownership tracking."
                ],
                docs: [
                    AdminDocLink(title: "API Integration Docs", localRelativePath: "authenticated/admin-panel.html", webPath: "/docs/authentication.html", adminWebPath: "/docs/authenticated/admin-panel.html"),
                    AdminDocLink(title: "Distribution Docs", localRelativePath: "getting-started.html", webPath: "/docs/getting-started.html", adminWebPath: "/docs/authenticated/index.html")
                ]
            )

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
    private let managedPeers = SettingsManager.managedFederationServers

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            AdminHelpSection(
                title: "Quick Help",
                summary: "Federation controls how this server exchanges room visibility, room state, and maintenance handoff behavior with other VoiceLink installs.",
                steps: [
                    "Only server owners and authorized admins should change default peer settings. Members and guests should never use this screen to override server policy.",
                    "Keep the Main VoiceLink and Community VPS peers enabled if they are part of your managed cluster. Toggle them off only during troubleshooting or planned isolation.",
                    "Use maintenance handoff when this server is going down for work. That lets active rooms and users move to an online trusted server instead of being dropped."
                ],
                docs: [
                    AdminDocLink(title: "Admin Federation Guide", localRelativePath: "authenticated/admin-panel.html", webPath: "/docs/authenticated/admin-panel.html", adminWebPath: "/docs/authenticated/admin-panel.html"),
                    AdminDocLink(title: "Server Install Docs", localRelativePath: "installation/index.html", webPath: "/docs/installation/index.html", adminWebPath: "/docs/authenticated/admin-panel.html")
                ]
            )

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

                    SectionHeader(title: "Managed Default Peers")

                    Text("These peers are supplied by the VoiceLink API and represent the managed cluster. Admins can enable or disable federation with them here, but members cannot edit or rename them from client preferences.")
                        .font(.caption)
                        .foregroundColor(.gray)

                    ForEach(managedPeers) { peer in
                        let isEnabled = config.trustedServers.contains(peer.url)
                        HStack(alignment: .top, spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { isEnabled },
                                set: { enabled in
                                    if enabled {
                                        if !config.trustedServers.contains(peer.url) {
                                            config.trustedServers.append(peer.url)
                                        }
                                    } else {
                                        config.trustedServers.removeAll { $0 == peer.url }
                                    }
                                    settings = config
                                }
                            ))
                            .toggleStyle(.switch)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(peer.name)
                                        .foregroundColor(.white)
                                    Text("Default")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.2))
                                        .cornerRadius(6)
                                }
                                Text(peer.url)
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                Text(peer.description)
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }

                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }

                    SectionHeader(title: "Maintenance Handoff")

                    Text("Use these options when this server is being restarted, updated, or migrated. Auto-handoff should point at a trusted online peer so rooms and users can be moved without disconnecting them.")
                        .font(.caption)
                        .foregroundColor(.gray)

                    ConfigToggle(label: "Maintenance Mode", isOn: Binding(
                        get: { config.maintenanceModeEnabled },
                        set: { config.maintenanceModeEnabled = $0; settings = config }
                    ))

                    ConfigToggle(label: "Auto-handoff active rooms and users", isOn: Binding(
                        get: { config.autoHandoffEnabled },
                        set: { config.autoHandoffEnabled = $0; settings = config }
                    ))

                    Picker("Handoff Target", selection: Binding(
                        get: { config.handoffTargetServer ?? "" },
                        set: { config.handoffTargetServer = $0.isEmpty ? nil : $0; settings = config }
                    )) {
                        Text("No automatic target").tag("")
                        ForEach(managedPeers) { peer in
                            Text(peer.name).tag(peer.url)
                        }
                        ForEach(config.trustedServers.filter { trusted in
                            !managedPeers.contains(where: { $0.url == trusted })
                        }, id: \.self) { trusted in
                            Text(trusted).tag(trusted)
                        }
                    }
                    .pickerStyle(.menu)

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
            AdminHelpSection(
                title: "Quick Help",
                summary: "Modules extend server features. Recommended modules should be installed first, then optional modules added as needed.",
                steps: [
                    "Refresh the catalog before making changes if module state looks stale.",
                    "Install recommended modules first, then enable or disable optional modules to fit the server role.",
                    "Use Update when a module is installed but needs its current config reapplied."
                ],
                docs: [
                    AdminDocLink(title: "Module Docs", localRelativePath: "authenticated/admin-panel.html", webPath: "/docs/index.html", adminWebPath: "/docs/authenticated/admin-panel.html"),
                    AdminDocLink(title: "Distribution Docs", localRelativePath: "getting-started.html", webPath: "/docs/getting-started.html", adminWebPath: "/docs/authenticated/index.html")
                ]
            )

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
            AdminHelpSection(
                title: "Quick Help",
                summary: "Self Tests verify the local app and server integration paths that VoiceLink depends on.",
                steps: [
                    "Run the tests after changing server config, media setup, or file transfer settings.",
                    "Enable scheduled checks for ongoing installs that should alert when a dependency breaks.",
                    "Review the recent run history to see which checks passed, warned, or failed."
                ],
                docs: [
                    AdminDocLink(title: "Testing Docs", localRelativePath: "authenticated/admin-panel.html", webPath: "/docs/getting-started.html", adminWebPath: "/docs/authenticated/admin-panel.html"),
                    AdminDocLink(title: "Installation Docs", localRelativePath: "installation/index.html", webPath: "/docs/installation/index.html", adminWebPath: "/docs/authenticated/index.html")
                ]
            )

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

struct AdminDocLink: Identifiable {
    let id = UUID()
    let title: String
    let localRelativePath: String?
    let webPath: String
    let adminWebPath: String?

    init(title: String, localRelativePath: String? = nil, webPath: String, adminWebPath: String? = nil) {
        self.title = title
        self.localRelativePath = localRelativePath
        self.webPath = webPath
        self.adminWebPath = adminWebPath
    }
}

enum AdminDocsResolver {
    private static let webBase = "https://voicelink.devinecreations.net"
    private static let localDocRoots = [
        "/Users/admin/DEV/APPS/voicelink-local/docs",
        "/Users/admin/DEV/APPS/voicelink-local/swift-native/VoiceLinkNative/docs",
        "/Users/admin/DEV/APPS/voicelink-local/source/docs",
        "/Users/admin/DEV/APPS/voicelink-local/voicelink-app/docs"
    ]

    static func resolve(_ doc: AdminDocLink, isAdmin: Bool) -> URL? {
        if let localRelativePath = doc.localRelativePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !localRelativePath.isEmpty {
            for root in localDocRoots {
                let candidate = URL(fileURLWithPath: root).appendingPathComponent(localRelativePath)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        let selectedPath = (isAdmin ? doc.adminWebPath : nil) ?? doc.webPath
        return URL(string: webBase + normalizedPath(selectedPath))
    }

    private static func normalizedPath(_ path: String) -> String {
        path.hasPrefix("/") ? path : "/" + path
    }
}

struct AdminHelpSection: View {
    let title: String
    let summary: String
    let steps: [String]
    let docs: [AdminDocLink]
    @ObservedObject private var adminManager = AdminServerManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundColor(.cyan)
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
            }

            Text(summary)
                .font(.subheadline)
                .foregroundColor(.gray)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.9))
                }
            }

            if !docs.isEmpty {
                HStack(spacing: 10) {
                    ForEach(docs) { doc in
                        Button(doc.title) {
                            guard let url = AdminDocsResolver.resolve(doc, isAdmin: adminManager.adminRole.canManageConfig) else { return }
                            NSWorkspace.shared.open(url)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
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
              motd: String?? = nil, motdSettings: MOTDSettings? = nil,
              registrationEnabled: Bool? = nil, requireAuth: Bool? = nil,
              allowGuests: Bool? = nil, maxGuestDuration: Int?? = nil, enableRateLimiting: Bool? = nil,
              handoffPromptMode: String? = nil,
              pushover: PushoverConfig?? = nil) -> ServerConfig {
        ServerConfig(
            serverName: serverName ?? self.serverName,
            serverDescription: serverDescription ?? self.serverDescription,
            maxUsers: maxUsers ?? self.maxUsers,
            maxRooms: maxRooms ?? self.maxRooms,
            maxUsersPerRoom: maxUsersPerRoom ?? self.maxUsersPerRoom,
            welcomeMessage: welcomeMessage ?? self.welcomeMessage,
            motd: motd ?? self.motd,
            motdSettings: motdSettings ?? self.motdSettings,
            registrationEnabled: registrationEnabled ?? self.registrationEnabled,
            requireAuth: requireAuth ?? self.requireAuth,
            allowGuests: allowGuests ?? self.allowGuests,
            maxGuestDuration: maxGuestDuration ?? self.maxGuestDuration,
            enableRateLimiting: enableRateLimiting ?? self.enableRateLimiting,
            handoffPromptMode: handoffPromptMode ?? self.handoffPromptMode,
            backgroundStreams: self.backgroundStreams,
            pushover: pushover ?? self.pushover
        )
    }

    func motdSettingsUpdating(
        enabled: Bool? = nil,
        showBeforeJoin: Bool? = nil,
        showInRoom: Bool? = nil,
        appendToWelcomeMessage: Bool? = nil
    ) -> MOTDSettings {
        MOTDSettings(
            enabled: enabled ?? motdSettings.enabled,
            showBeforeJoin: showBeforeJoin ?? motdSettings.showBeforeJoin,
            showInRoom: showInRoom ?? motdSettings.showInRoom,
            appendToWelcomeMessage: appendToWelcomeMessage ?? motdSettings.appendToWelcomeMessage
        )
    }
}
