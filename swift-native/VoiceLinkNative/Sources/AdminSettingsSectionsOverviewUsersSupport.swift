import SwiftUI
import AppKit

// MARK: - Overview Section
struct AdminOverviewSection: View {
    @ObservedObject var adminManager = AdminServerManager.shared
    @State private var showLogsSheet = false

    private var webFrontendURL: URL? {
        if let url = URL(string: adminManager.resolvedServerURL) {
            return url
        }
        return URL(string: APIEndpointResolver.canonicalMainBase)
    }

    var body: some View {
        VStack(spacing: 20) {
            overviewHeader

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
                VStack(alignment: .leading, spacing: 10) {
                    if let error = adminManager.serverStatsError, !error.isEmpty {
                        Label("Server stats are unavailable right now.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.gray)
                    } else {
                        ProgressView("Loading server stats...")
                            .foregroundColor(.white)
                    }
                    Button("Refresh Stats") {
                        Task {
                            await adminManager.fetchServerStats()
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.white.opacity(0.04))
                .cornerRadius(12)
            }

            if let config = adminManager.serverConfig {
                serverConfigurationSummary(config: config)
            }

            modulesSummary

            HStack(spacing: 15) {
                AdminQuickAction(title: "Refresh Stats", icon: "arrow.clockwise") {
                    Task {
                        await adminManager.fetchServerStats()
                        await adminManager.fetchServerLogs()
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

            HStack(spacing: 15) {
                AdminQuickAction(title: "Open Web App", icon: "safari") {
                    guard let url = webFrontendURL else { return }
                    NSWorkspace.shared.open(url)
                }

                AdminQuickAction(
                    title: (adminManager.serverConfig?.serverVisibility.frontendOpen ?? true) ? "Close Browser Access" : "Open Browser Access",
                    icon: (adminManager.serverConfig?.serverVisibility.frontendOpen ?? true) ? "lock.slash" : "lock.open"
                ) {
                    Task {
                        guard var config = adminManager.serverConfig else { return }
                        config.serverVisibility.frontendOpen.toggle()
                        _ = await adminManager.updateServerConfig(config)
                    }
                }
            }
        }
        .sheet(isPresented: $showLogsSheet) {
            AdminServerLogsSheet()
        }
        .task {
            if adminManager.serverStats == nil {
                await adminManager.fetchServerStats()
            }
            if adminManager.serverConfig == nil {
                await adminManager.fetchServerConfig()
            }
            if adminManager.serverLogLines.isEmpty {
                await adminManager.fetchServerLogs()
            }
        }
    }

    private var overviewHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Overview")
                .font(.title2.bold())
                .foregroundColor(.white)
            Text(adminManager.manageAllLinkedServers ? adminManager.allLinkedScopeSummary : "Current server health, capacity, and installed feature summary for \(adminManager.selectedManagementTargetName).")
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
                VStack(alignment: .center, spacing: 10) {
                    Text(adminManager.error?.isEmpty == false ? "Server logs are unavailable right now." : "No logs available.")
                        .foregroundColor(.gray)
                    if let error = adminManager.error, !error.isEmpty {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                    }
                    Button("Refresh") {
                        Task { await adminManager.fetchServerLogs() }
                    }
                    .buttonStyle(.bordered)
                }
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
        .task {
            await adminManager.fetchServerLogs()
        }
    }
}

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

struct AdminUsersSection: View {
    @ObservedObject var adminManager = AdminServerManager.shared
    @State private var selectedUser: AdminUserInfo?
    @State private var showKickAlert = false
    @State private var showBanAlert = false
    @State private var showGrantModeratorAlert = false
    @State private var showGrantAdminAlert = false
    @State private var showGrantOwnerAlert = false
    @State private var showRevokeRoleAlert = false
    @State private var kickReason = ""
    @State private var banReason = ""
    @State private var banDuration = 24
    @State private var memberSearchQuery = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Connected Users (\(adminManager.connectedUsers.count))")
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()

                Button(action: {
                    Task {
                        await adminManager.fetchConnectedUsers()
                        await adminManager.fetchRecentUserLogins()
                        await adminManager.searchUsers(query: memberSearchQuery)
                    }
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
                        case .grantModerator:
                            showGrantModeratorAlert = true
                        case .grantAdmin:
                            showGrantAdminAlert = true
                        case .grantOwner:
                            showGrantOwnerAlert = true
                        case .revokeRole:
                            showRevokeRoleAlert = true
                        }
                    }
                }
            }

            Divider()
                .background(Color.white.opacity(0.18))

            VStack(alignment: .leading, spacing: 10) {
                Text("Recent Member Logins")
                    .font(.headline)
                    .foregroundColor(.white)
                Text("Last users seen by the backend, including client type, build, device, room, and auth method for debugging.")
                    .font(.caption)
                    .foregroundColor(.gray)

                if adminManager.recentUserLogins.isEmpty {
                    Text("No recent login records yet.")
                        .foregroundColor(.gray)
                        .padding(.vertical, 4)
                } else {
                    ForEach(adminManager.recentUserLogins.prefix(10)) { login in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(login.displayLabel)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.white)
                            Text([
                                login.clientLabel.isEmpty ? nil : login.clientLabel,
                                login.roomName.map { "Room: \($0)" },
                                login.authMethod.map { "Auth: \($0)" },
                                login.loggedInAt.map { "Seen: \($0)" }
                            ].compactMap { $0 }.joined(separator: " | "))
                                .font(.caption)
                                .foregroundColor(.gray)
                                .accessibilityLabel("Client and login details \(login.clientLabel), room \(login.roomName ?? "none"), auth \(login.authMethod ?? "unknown")")
                        }
                        .padding(10)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(10)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Find Members for Debugging")
                    .font(.headline)
                    .foregroundColor(.white)
                Text("Search connected users, recent logins, and saved member records by name, email, provider, room, client, or device.")
                    .font(.caption)
                    .foregroundColor(.gray)

                HStack {
                    TextField("Search members", text: $memberSearchQuery)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search members")
                    Button("Search") {
                        Task { await adminManager.searchUsers(query: memberSearchQuery) }
                    }
                    .buttonStyle(.borderedProminent)
                }

                if adminManager.searchableUsers.isEmpty {
                    Text("No matching member records loaded.")
                        .foregroundColor(.gray)
                        .padding(.vertical, 4)
                } else {
                    ForEach(adminManager.searchableUsers.prefix(25)) { user in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(user.displayLabel)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.white)
                                Spacer()
                                Text(user.connected == true ? "Connected" : (user.source ?? "Record"))
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(user.connected == true ? .green : .gray)
                            }
                            Text([
                                user.email,
                                user.clientLabel.isEmpty ? nil : user.clientLabel,
                                user.currentRoom.map { "Room: \($0)" } ?? user.roomName.map { "Room: \($0)" },
                                user.authMethod.map { "Auth: \($0)" } ?? user.authProvider.map { "Provider: \($0)" },
                                user.role.map { "Role: \($0)" }
                            ].compactMap { $0 }.joined(separator: " | "))
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .padding(10)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(10)
                    }
                }
            }
        }
        .task {
            await adminManager.fetchConnectedUsers()
            await adminManager.fetchRecentUserLogins()
            await adminManager.searchUsers()
        }
        .alert("Kick User", isPresented: $showKickAlert) {
            TextField("Optional reason shown to the user being removed", text: $kickReason)
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
            TextField("Reason for the ban", text: $banReason)
            TextField("Ban duration in hours", value: $banDuration, format: .number)
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
        .alert("Grant Moderator Access", isPresented: $showGrantModeratorAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Grant Moderator") {
                if let user = selectedUser {
                    Task {
                        _ = await adminManager.updateUserRole(
                            user.id,
                            role: "moderator",
                            accountId: user.accountId,
                            email: user.email,
                            username: user.username,
                            displayName: user.displayName
                        )
                        await adminManager.fetchConnectedUsers()
                    }
                }
            }
        } message: {
            Text("Grant moderator access to this user across the servers you own and keep it synced on connected endpoints.")
        }
        .alert("Grant Admin Access", isPresented: $showGrantAdminAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Grant Admin") {
                if let user = selectedUser {
                    Task {
                        _ = await adminManager.updateUserRole(
                            user.id,
                            role: "admin",
                            accountId: user.accountId,
                            email: user.email,
                            username: user.username,
                            displayName: user.displayName
                        )
                        await adminManager.fetchConnectedUsers()
                    }
                }
            }
        } message: {
            Text("Grant server administration access to this user across the servers you own.")
        }
        .alert("Grant Owner Access", isPresented: $showGrantOwnerAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Grant Owner", role: .destructive) {
                if let user = selectedUser {
                    Task {
                        _ = await adminManager.updateUserRole(
                            user.id,
                            role: "owner",
                            accountId: user.accountId,
                            email: user.email,
                            username: user.username,
                            displayName: user.displayName
                        )
                        await adminManager.fetchConnectedUsers()
                    }
                }
            }
        } message: {
            Text("Grant full owner access to this user. This gives full server administration control, synced identity updates, and authority across linked server role assignment features.")
        }
        .alert("Revoke Elevated Access", isPresented: $showRevokeRoleAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Revoke", role: .destructive) {
                if let user = selectedUser {
                    Task {
                        _ = await adminManager.revokeUserRole(
                            user.id,
                            accountId: user.accountId,
                            email: user.email,
                            username: user.username
                        )
                        await adminManager.fetchConnectedUsers()
                    }
                }
            }
        } message: {
            Text("Remove moderator or admin access for this user and return them to normal member access.")
        }
    }
}

struct AdminSupportSection: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var adminManager = AdminServerManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Support Sessions (\(adminManager.supportSessions.count))")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("Private support rooms, live pickup, and ticket reuse.")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                Spacer()

                Button(action: {
                    Task { await adminManager.fetchSupportSessions() }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Support Workflow")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                Text("Support sessions create hidden rooms for the conversation first. Staff can attach an existing support ticket or create one from the session when needed, and closing the session closes the hidden room.")
                    .font(.caption)
                    .foregroundColor(.gray)
                Text("Support rooms are task-focused spaces. They do not need the normal social room media controls unless you explicitly turn that behavior back on later.")
                    .font(.caption)
                    .foregroundColor(.gray)
                Text("Picking up a support session opens the hidden room so you can continue with the user immediately.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(12)
            .background(Color.white.opacity(0.05))
            .cornerRadius(10)

            if adminManager.supportSessions.isEmpty {
                Text("No support sessions are waiting right now.")
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(adminManager.supportSessions, id: \.id) { session in
                        AdminSupportSessionRow(session: session) { action in
                            switch action {
                            case .pickup:
                                Task {
                                    let pickedUp = await adminManager.pickupSupportSession(session.id)
                                    if pickedUp, let hiddenRoomId = session.hiddenRoomId {
                                        await MainActor.run {
                                            appState.openHiddenRoom(roomId: hiddenRoomId, roomName: session.hiddenRoomName)
                                        }
                                    }
                                }
                            case .openRoom:
                                if let hiddenRoomId = session.hiddenRoomId {
                                    appState.openHiddenRoom(roomId: hiddenRoomId, roomName: session.hiddenRoomName)
                                }
                            case .close:
                                Task {
                                    _ = await adminManager.closeSupportSession(session.id)
                                }
                            case .attachTicket:
                                Task {
                                    _ = await adminManager.createOrAttachSupportTicket(for: session.id)
                                }
                            }
                        }
                    }
                }
            }
        }
        .task {
            await adminManager.fetchSupportSessions()
        }
    }
}

struct AdminSupportSessionRow: View {
    let session: AdminSupportSessionInfo
    let onAction: (Action) -> Void

    enum Action {
        case pickup
        case openRoom
        case close
        case attachTicket
    }

    private var accent: Color {
        switch session.status.lowercased() {
        case "active":
            return .green
        case "closed", "completed":
            return .gray
        default:
            return .orange
        }
    }

    private var statusLabel: String {
        session.status.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.userName)
                        .foregroundColor(.white)
                        .font(.headline)
                    if let userEmail = session.userEmail, !userEmail.isEmpty {
                        Text(userEmail)
                            .foregroundColor(.gray)
                            .font(.caption)
                    }
                    Text(session.issue.isEmpty ? "Support session" : session.issue)
                        .foregroundColor(.white.opacity(0.88))
                        .font(.subheadline)
                        .lineLimit(3)
                    Text(session.displayRoomName)
                        .foregroundColor(.gray)
                        .font(.caption)
                }

                Spacer()

                Text(statusLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(accent.opacity(0.15))
                    .cornerRadius(20)
            }

            HStack(spacing: 12) {
                supportMeta(label: "Ticket", value: session.supportTicketStateLabel)
                supportMeta(label: "Channel", value: session.channel.capitalized)
                supportMeta(label: "Agent", value: session.assignedAgentName ?? "Unassigned")
                supportMeta(label: "PIN", value: session.supportPinRequired ? (session.supportPinValidated ? "Verified" : "Required") : "Off")
            }

            if session.pendingWhmcsSync || (session.whmcsLastSyncError?.isEmpty == false) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.pendingWhmcsSync ? "WHMCS sync pending" : "WHMCS sync issue")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(session.pendingWhmcsSync ? .orange : .red)
                    if let mode = session.whmcsSyncMode, !mode.isEmpty {
                        Text("Mode: \(mode.replacingOccurrences(of: "-", with: " ").capitalized)")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                    if let lastError = session.whmcsLastSyncError, !lastError.isEmpty {
                        Text(lastError)
                            .font(.caption2)
                            .foregroundColor(.gray)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background((session.pendingWhmcsSync ? Color.orange : Color.red).opacity(0.08))
                .cornerRadius(8)
            }

            HStack(spacing: 10) {
                if session.status.lowercased() != "active" && session.status.lowercased() != "closed" {
                    Button("Pick Up") {
                        onAction(.pickup)
                    }
                    .buttonStyle(.borderedProminent)
                }

                if session.hiddenRoomId != nil {
                    Button("Open Room") {
                        onAction(.openRoom)
                    }
                    .buttonStyle(.bordered)
                }

                if session.supportTicketLabel == nil || session.pendingWhmcsSync {
                    Button("Create or Reuse Support Ticket") {
                        onAction(.attachTicket)
                    }
                    .buttonStyle(.bordered)
                }

                if session.status.lowercased() != "closed" {
                    Button("Close Session and Room") {
                        onAction(.close)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(accent.opacity(0.35), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    @ViewBuilder
    private func supportMeta(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundColor(.gray)
            Text(value)
                .font(.caption)
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
        }
    }
}

struct UserAdminRow: View {
    let user: AdminUserInfo
    let onAction: (UserAction) -> Void

    enum UserAction {
        case kick, ban, grantModerator, grantAdmin, grantOwner, revokeRole
    }

    var body: some View {
        HStack {
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
                if let authLabel = authSummary, !authLabel.isEmpty {
                    Text(authLabel)
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }

            Spacer()

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

            Menu {
                Button(action: { onAction(.kick) }) {
                    Label("Kick", systemImage: "person.badge.minus")
                }
                Divider()
                Button(action: { onAction(.grantModerator) }) {
                    Label("Grant Moderator", systemImage: "person.badge.shield.checkmark")
                }
                Button(action: { onAction(.grantAdmin) }) {
                    Label("Grant Admin", systemImage: "person.crop.circle.badge.checkmark")
                }
                Button(action: { onAction(.grantOwner) }) {
                    Label("Grant Owner", systemImage: "crown.fill")
                }
                Button(action: { onAction(.revokeRole) }) {
                    Label("Revoke Elevated Access", systemImage: "person.crop.circle.badge.minus")
                }
                Divider()
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

    private var authSummary: String? {
        var parts: [String] = []
        if let provider = user.authProvider?.trimmingCharacters(in: .whitespacesAndNewlines), !provider.isEmpty {
            parts.append("Primary: \(provider.capitalized)")
        } else if let method = user.authMethod?.trimmingCharacters(in: .whitespacesAndNewlines), !method.isEmpty {
            parts.append("Method: \(method.capitalized)")
        }
        let linked = (user.linkedAuthMethods ?? [])
            .map(\.provider)
            .map { $0.capitalized }
        if !linked.isEmpty {
            parts.append("Linked: \(linked.joined(separator: ", "))")
        }
        if let shared = user.sharedAuthMode?.trimmingCharacters(in: .whitespacesAndNewlines), !shared.isEmpty {
            parts.append("Shared auth: \(shared.capitalized)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
}
