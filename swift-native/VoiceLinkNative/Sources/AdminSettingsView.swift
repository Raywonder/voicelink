import SwiftUI
import AppKit
import WebKit

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
        case support = "Support"
        case rooms = "Rooms"
        case modules = "Modules"
        case deployment = "Deployment"
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
                    case .support:
                        AdminSupportSection()
                    case .rooms:
                        AdminRoomsSection()
                    case .modules:
                        AdminModulesSection()
                    case .deployment:
                        AdminDeploymentSection()
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
            if !canAccessTab(selectedTab) {
                selectedTab = .overview
            }
            async let stats: Void = adminManager.fetchServerStats()
            async let config: Void = adminManager.fetchServerConfig()
            async let advanced: Void = adminManager.fetchAdvancedServerSettings()
            async let modules: Void = adminManager.refreshModulesCenter()
            if canAccessTab(.support) {
                async let support: Void = adminManager.fetchSupportSessions()
                _ = await (stats, config, advanced, modules, support)
            } else {
                _ = await (stats, config, advanced, modules)
            }
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
        case .support:
            return adminManager.adminRole.canManageUsers
        case .rooms:
            return adminManager.adminRole.canManageRooms
        case .modules:
            return adminManager.adminRole.canManageConfig
        case .deployment:
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint(isSelected ? "Current server administration tab." : "Opens the \(title) tab.")
        .modifier(AdminSelectedAccessibilityModifier(isSelected: isSelected))
    }
}

private struct AdminSelectedAccessibilityModifier: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        if isSelected {
            content.accessibilityAddTraits(.isSelected)
        } else {
            content
        }
    }
}

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
                VStack(alignment: .leading, spacing: 10) {
                    if let error = adminManager.error, !error.isEmpty {
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
    @State private var showGrantModeratorAlert = false
    @State private var showGrantAdminAlert = false
    @State private var showRevokeRoleAlert = false
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
                        case .grantModerator:
                            showGrantModeratorAlert = true
                        case .grantAdmin:
                            showGrantAdminAlert = true
                        case .revokeRole:
                            showRevokeRoleAlert = true
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
                    ForEach(adminManager.supportSessions) { session in
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
                supportMeta(label: "Ticket", value: session.supportTicketLabel ?? "Pending")
                supportMeta(label: "Channel", value: session.channel.capitalized)
                supportMeta(label: "Agent", value: session.assignedAgentName ?? "Unassigned")
                supportMeta(label: "PIN", value: session.supportPinRequired ? (session.supportPinValidated ? "Verified" : "Required") : "Off")
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

                if session.supportTicketLabel == nil {
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

// MARK: - User Admin Row
struct UserAdminRow: View {
    let user: AdminUserInfo
    let onAction: (UserAction) -> Void

    enum UserAction {
        case kick, ban, grantModerator, grantAdmin, revokeRole
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
                Divider()
                Button(action: { onAction(.grantModerator) }) {
                    Label("Grant Moderator", systemImage: "person.badge.shield.checkmark")
                }
                Button(action: { onAction(.grantAdmin) }) {
                    Label("Grant Admin", systemImage: "person.crop.circle.badge.checkmark")
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
        case messages = "Messages"
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
                    case .messages:
                        messagesSection(config: config)
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
                    .accessibilityValue(selectedSection == section ? "Selected" : "")
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

                SectionHeader(title: "Client Visibility")

                ConfigToggle(label: "Show Server in Desktop Clients", isOn: Binding(
                    get: { editedConfig?.serverVisibility.desktop ?? config.serverVisibility.desktop },
                    set: { value in
                        var next = editedConfig ?? config
                        next.serverVisibility.desktop = value
                        editedConfig = next
                    }
                ))

                ConfigToggle(label: "Show Server in iOS Clients", isOn: Binding(
                    get: { editedConfig?.serverVisibility.ios ?? config.serverVisibility.ios },
                    set: { value in
                        var next = editedConfig ?? config
                        next.serverVisibility.ios = value
                        editedConfig = next
                    }
                ))

                ConfigToggle(label: "Show Server in Web Client", isOn: Binding(
                    get: { editedConfig?.serverVisibility.web ?? config.serverVisibility.web },
                    set: { value in
                        var next = editedConfig ?? config
                        next.serverVisibility.web = value
                        editedConfig = next
                    }
                ))

                ConfigToggle(label: "Frontend Open Status", isOn: Binding(
                    get: { editedConfig?.serverVisibility.frontendOpen ?? config.serverVisibility.frontendOpen },
                    set: { value in
                        var next = editedConfig ?? config
                        next.serverVisibility.frontendOpen = value
                        editedConfig = next
                    }
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

    private func messagesSection(config: ServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: "Message Retention and Loading")

            Text("These settings control room chat, direct messages, bot memory, and how much history users load by default when they join a room or open a direct conversation.")
                .font(.caption)
                .foregroundColor(.gray)

            ConfigToggle(label: "Keep Room Messages", isOn: Binding(
                get: { editedConfig?.messageSettings.keepRoomMessages ?? config.messageSettings.keepRoomMessages },
                set: { value in
                    editedConfig = (editedConfig ?? config).with(messageSettings: nextMessageSettings(config: config) { $0.keepRoomMessages = value })
                }
            ))

            ConfigToggle(label: "Keep Direct Messages", isOn: Binding(
                get: { editedConfig?.messageSettings.keepDirectMessages ?? config.messageSettings.keepDirectMessages },
                set: { value in
                    editedConfig = (editedConfig ?? config).with(messageSettings: nextMessageSettings(config: config) { $0.keepDirectMessages = value })
                }
            ))

            ConfigToggle(label: "Delete Room Messages When Room Empties", isOn: Binding(
                get: { editedConfig?.messageSettings.deleteRoomMessagesWhenEmpty ?? config.messageSettings.deleteRoomMessagesWhenEmpty },
                set: { value in
                    editedConfig = (editedConfig ?? config).with(messageSettings: nextMessageSettings(config: config) { $0.deleteRoomMessagesWhenEmpty = value })
                }
            ))

            ConfigToggle(label: "Keep Messages With Attachments", isOn: Binding(
                get: { editedConfig?.messageSettings.keepAttachmentMessages ?? config.messageSettings.keepAttachmentMessages },
                set: { value in
                    editedConfig = (editedConfig ?? config).with(messageSettings: nextMessageSettings(config: config) { $0.keepAttachmentMessages = value })
                }
            ))

            HStack(spacing: 20) {
                ConfigNumberField(label: "Initial Load Count", value: Binding(
                    get: { editedConfig?.messageSettings.initialLoadCount ?? config.messageSettings.initialLoadCount },
                    set: { value in
                        editedConfig = (editedConfig ?? config).with(messageSettings: nextMessageSettings(config: config) { $0.initialLoadCount = min(max(value, 1), 200) })
                    }
                ))

                ConfigNumberField(label: "Scrollback Limit", value: Binding(
                    get: { editedConfig?.messageSettings.scrollbackLimit ?? config.messageSettings.scrollbackLimit },
                    set: { value in
                        editedConfig = (editedConfig ?? config).with(messageSettings: nextMessageSettings(config: config) { $0.scrollbackLimit = min(max(value, 20), 5000) })
                    }
                ))
            }

            HStack(spacing: 20) {
                ConfigNumberField(label: "Room Message Cap", value: Binding(
                    get: { editedConfig?.messageSettings.roomMessageCap ?? config.messageSettings.roomMessageCap },
                    set: { value in
                        editedConfig = (editedConfig ?? config).with(messageSettings: nextMessageSettings(config: config) { $0.roomMessageCap = min(max(value, 20), 5000) })
                    }
                ))

                ConfigNumberField(label: "Direct Message Cap", value: Binding(
                    get: { editedConfig?.messageSettings.directMessageCap ?? config.messageSettings.directMessageCap },
                    set: { value in
                        editedConfig = (editedConfig ?? config).with(messageSettings: nextMessageSettings(config: config) { $0.directMessageCap = min(max(value, 20), 5000) })
                    }
                ))
            }

            HStack(spacing: 20) {
                ConfigNumberField(label: "Guest Retention (hours)", value: Binding(
                    get: { editedConfig?.messageSettings.guestRetentionHours ?? config.messageSettings.guestRetentionHours },
                    set: { value in
                        editedConfig = (editedConfig ?? config).with(messageSettings: nextMessageSettings(config: config) { $0.guestRetentionHours = min(max(value, 1), 24 * 365) })
                    }
                ))

                ConfigNumberField(label: "Authenticated Retention (days)", value: Binding(
                    get: { editedConfig?.messageSettings.authenticatedRetentionDays ?? config.messageSettings.authenticatedRetentionDays },
                    set: { value in
                        editedConfig = (editedConfig ?? config).with(messageSettings: nextMessageSettings(config: config) { $0.authenticatedRetentionDays = min(max(value, 1), 3650) })
                    }
                ))
            }

            SectionHeader(title: "Bot Memory")

            HStack(spacing: 20) {
                ConfigNumberField(label: "Bot Memory Message Limit", value: Binding(
                    get: { editedConfig?.messageSettings.botMemoryMessageLimit ?? config.messageSettings.botMemoryMessageLimit },
                    set: { value in
                        editedConfig = (editedConfig ?? config).with(messageSettings: nextMessageSettings(config: config) { $0.botMemoryMessageLimit = min(max(value, 0), 5000) })
                    }
                ))

                ConfigNumberField(label: "Bot Memory Days", value: Binding(
                    get: { editedConfig?.messageSettings.botMemoryDays ?? config.messageSettings.botMemoryDays },
                    set: { value in
                        editedConfig = (editedConfig ?? config).with(messageSettings: nextMessageSettings(config: config) { $0.botMemoryDays = min(max(value, 0), 3650) })
                    }
                ))
            }

            Text("Room owners can still get tighter room-level limits from the server API. These are the server defaults used when a room does not define its own message policy.")
                .font(.caption2)
                .foregroundColor(.gray)
        }
    }

    private func nextMessageSettings(config: ServerConfig, mutate: (inout MessageSettings) -> Void) -> MessageSettings {
        var next = editedConfig?.messageSettings ?? config.messageSettings
        mutate(&next)
        return next
    }

    @ViewBuilder
    private var databaseSection: some View {
        if let settings = editedAdvancedSettings ?? adminManager.advancedServerSettings {
            SectionHeader(title: "Database")

            Text("Choose the main database provider first, then decide which server data types should stay on default storage, move into the database, or remain file-backed.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Storage Policy")

                HStack(spacing: 12) {
                    Text("Default Mode")
                        .foregroundColor(.white)
                    Picker("Default Mode", selection: Binding(
                        get: { (editedAdvancedSettings ?? settings).database.storage.defaultMode },
                        set: { value in
                            var next = editedAdvancedSettings ?? settings
                            next.database.storage.defaultMode = value
                            editedAdvancedSettings = next
                        }
                    )) {
                        Text("Use Default").tag("default")
                        Text("Prefer Database").tag("database")
                        Text("Prefer Files").tag("file")
                    }
                    .pickerStyle(.menu)
                }

                storageModePicker(
                    title: "Accounts and Linked Login Methods",
                    field: \.accounts,
                    settings: settings
                )
                storageModePicker(
                    title: "Rooms and Room Metadata",
                    field: \.rooms,
                    settings: settings
                )
                storageModePicker(
                    title: "Support Sessions and Tickets",
                    field: \.support,
                    settings: settings
                )
                storageModePicker(
                    title: "Scheduler State and History",
                    field: \.scheduler,
                    settings: settings
                )
                storageModePicker(
                    title: "Diagnostics and Bug Reports",
                    field: \.diagnostics,
                    settings: settings
                )
                storageModePicker(
                    title: "Server Config Records",
                    field: \.serverConfig,
                    settings: settings
                )
            }
        }
    }

    @ViewBuilder
    private func storageModePicker(
        title: String,
        field: WritableKeyPath<DatabaseStorageConfig, String>,
        settings: AdvancedServerSettings
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundColor(.white)
            Spacer(minLength: 12)
            Picker(title, selection: Binding(
                get: { (editedAdvancedSettings ?? settings).database.storage[keyPath: field] },
                set: { value in
                    var next = editedAdvancedSettings ?? settings
                    next.database.storage[keyPath: field] = value
                    editedAdvancedSettings = next
                }
            )) {
                Text("Use Default").tag("default")
                Text("Database").tag("database")
                Text("Files").tag("file")
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 180)
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
    @State private var config = BackgroundStreamsConfig(enabled: true, streams: [], defaultVolume: 60, fadeInDuration: 1500)
    @State private var showAddStream = false
    @State private var editingStream: BackgroundStreamConfig?
    @State private var selectedStreamID: String?
    @State private var pendingDeleteStream: BackgroundStreamConfig?

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
                                Text(stream.streamUrl)
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
                        await adminManager.updateBackgroundStreamsConfig(config)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear {
            if let serverConfig = adminManager.serverConfig?.backgroundStreams {
                config = serverConfig
            }
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
                    roomPatterns: []
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

    private var resolvedStreamURL: String {
        let primary = stream.streamUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !primary.isEmpty { return primary }
        return stream.url.trimmingCharacters(in: .whitespacesAndNewlines)
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
                    TextField("Name", text: $stream.name)
                    TextField("Direct stream URL", text: Binding(
                        get: { stream.streamUrl.isEmpty ? stream.url : stream.streamUrl },
                        set: {
                            stream.streamUrl = $0
                            stream.url = $0
                        }
                    ))
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
                }

                if isAddMode {
                    Section("Discover Stream URL") {
                        HStack {
                            TextField("example.com, stream domain, or direct URL", text: $probeInput)
                                .textFieldStyle(.roundedBorder)
                            Button(isProbing ? "Checking..." : "Detect") {
                                let input = probeInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !input.isEmpty else { return }
                                isProbing = true
                                Task {
                                    probeResults = await AdminServerManager.shared.probeBackgroundStreams(input: input)
                                    isProbing = false
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isProbing)
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
                                        stream.streamUrl = candidate.streamUrl
                                        stream.url = candidate.streamUrl
                                        if stream.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            stream.name = candidate.name
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                }
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
                    TextField("Comma-separated patterns, optional", text: $roomPatternText)
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
                probeInput = stream.streamUrl.isEmpty ? stream.url : stream.streamUrl
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

// MARK: - API Sync Section
struct AdminAPISyncSection: View {
    @ObservedObject var adminManager = AdminServerManager.shared
    @State private var settings: APISyncSettings?
    @State private var loadError: String?
    @State private var isSaving = false
    @State private var selectedSubtab: APISyncSubtab = .connection
    @State private var manualServerEntry = ""
    private let syncModes = ["standalone", "hybrid", "hub", "federated"]
    private let actionChoices = ["none", "start", "handoff", "return", "fallback"]

    enum APISyncSubtab: String, CaseIterable {
        case connection = "Connection"
        case routing = "Routing"
        case whmcs = "WHMCS"
        case discovery = "Discovery"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            AdminHelpSection(
                title: "Quick Help",
                summary: "API Sync controls whether this install follows the main VoiceLink API, runs standalone, or participates in a hybrid/federated sync model with external systems such as WHMCS.",
                steps: [
                    "Enable API Sync only if this server should exchange config, entitlements, or ownership data with another VoiceLink authority or portal.",
                    "Choose the mode that matches the install: standalone for isolated servers, hybrid for managed installs, or federated when multiple peers are trusted.",
                    "Use WHMCS fields only when this install should honor hosted account, licensing, or ownership data from your portal."
                ],
                docs: [
                    AdminDocLink(title: "API Integration Docs", localRelativePath: "authenticated/admin-panel.html", webPath: "/docs/authentication.html", adminWebPath: "/docs/authenticated/admin-panel.html"),
                    AdminDocLink(title: "Distribution Docs", localRelativePath: "getting-started.html", webPath: "/docs/getting-started.html", adminWebPath: "/docs/authenticated/index.html")
                ]
            )

            if var config = settings {
                subtabToolbar

                switch selectedSubtab {
                case .connection:
                    SectionHeader(title: "VoiceLink API Sync")

                    ConfigToggle(
                        label: "Enable API Sync",
                        helpText: "Turn this on when the server should stay linked to a main VoiceLink authority, hosted portal, or managed federation setup.",
                        isOn: Binding(
                            get: { config.enabled },
                            set: { config.enabled = $0; settings = config }
                        )
                    )

                    Picker("Sync Mode", selection: Binding(
                        get: { config.mode },
                        set: { config.mode = $0; settings = config }
                    )) {
                        ForEach(syncModes, id: \.self) { mode in
                            Text(mode.capitalized).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("`Standalone` keeps the server self-contained. `Hybrid` keeps it linked to the main VoiceLink API. `Hub` is for central-control installs. `Federated` is for trusted peer clusters.")
                        .font(.caption)
                        .foregroundColor(.gray)

                    SectionHeader(title: "Sync Behavior")

                    ConfigNumberField(
                        label: "Sync Interval (seconds)",
                        helpText: "How often this server should refresh linked API state in the background.",
                        value: Binding(
                            get: { config.syncInterval },
                            set: { config.syncInterval = $0; settings = config }
                        )
                    )

                    ConfigToggle(label: "Auto-sync on Changes", helpText: "Immediately push changes when config, room ownership, or linked license state changes.", isOn: Binding(
                        get: { config.autoSyncOnChange },
                        set: { config.autoSyncOnChange = $0; settings = config }
                    ))

                    ConfigToggle(label: "Allow client choice on handoff", helpText: "Let connected clients choose whether to accept an offered handoff when policy allows.", isOn: Binding(
                        get: { config.allowClientChoice },
                        set: { config.allowClientChoice = $0; settings = config }
                    ))

                    ConfigToggle(label: "Auto-return after recovery", helpText: "Return users to the preferred primary server when it recovers and the routing policy allows it.", isOn: Binding(
                        get: { config.autoReturnRecoveredUsers },
                        set: { config.autoReturnRecoveredUsers = $0; settings = config }
                    ))

                    ConfigNumberField(
                        label: "Snapshot Interval (seconds)",
                        helpText: "How often join/leave and transfer snapshots should be refreshed for failover and return actions.",
                        value: Binding(
                            get: { config.snapshotIntervalSeconds },
                            set: { config.snapshotIntervalSeconds = $0; settings = config }
                        )
                    )

                case .routing:
                    SectionHeader(title: "Routing Profiles")

                    Text("Profiles define ordered handoff and fallback actions. You can keep more than one entry for the same server when the target path or action chain is different.")
                        .font(.caption)
                        .foregroundColor(.gray)

                    ForEach(Array(config.routingProfiles.enumerated()), id: \.element.id) { index, profile in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Profile \(index + 1)")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                Spacer()
                                Button(role: .destructive) {
                                    config.routingProfiles.removeAll { $0.id == profile.id }
                                    settings = config
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                                .buttonStyle(.bordered)
                            }

                            ConfigTextField(label: "Label", placeholder: "Main to VPS fallback", helpText: "Friendly name for this routing profile.", text: Binding(
                                get: { config.routingProfiles[safe: index]?.label ?? profile.label },
                                set: {
                                    guard config.routingProfiles.indices.contains(index) else { return }
                                    config.routingProfiles[index].label = $0
                                    settings = config
                                }
                            ))

                            ConfigTextField(label: "Target Server", placeholder: "https://node2.voicelink.devinecreations.net", helpText: "Domain, public IP, private IP, or known endpoint for this target.", text: Binding(
                                get: { config.routingProfiles[safe: index]?.targetServer ?? profile.targetServer },
                                set: {
                                    guard config.routingProfiles.indices.contains(index) else { return }
                                    config.routingProfiles[index].targetServer = $0
                                    settings = config
                                }
                            ))

                            ConfigTextField(label: "Install Path / Manual Address", placeholder: "/home/devinecr/apps/voicelink-local or 10.0.0.5", helpText: "Optional path or direct address used for same-host or manual routing.", text: Binding(
                                get: { config.routingProfiles[safe: index]?.installPath ?? config.routingProfiles[safe: index]?.manualAddress ?? "" },
                                set: {
                                    guard config.routingProfiles.indices.contains(index) else { return }
                                    config.routingProfiles[index].installPath = $0.isEmpty ? nil : $0
                                    config.routingProfiles[index].manualAddress = $0.isEmpty ? nil : $0
                                    settings = config
                                }
                            ))

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Ordered Actions")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                ForEach(0..<4, id: \.self) { slot in
                                    Picker("Action \(slot + 1)", selection: Binding(
                                        get: {
                                            let actions = config.routingProfiles[safe: index]?.actions ?? []
                                            return slot < actions.count ? actions[slot] : "none"
                                        },
                                        set: { value in
                                            guard config.routingProfiles.indices.contains(index) else { return }
                                            var actions = config.routingProfiles[index].actions
                                            while actions.count <= slot { actions.append("none") }
                                            actions[slot] = value
                                            config.routingProfiles[index].actions = actions.filter { $0 != "none" }
                                            settings = config
                                        }
                                    )) {
                                        ForEach(actionChoices, id: \.self) { choice in
                                            Text(choice.capitalized).tag(choice)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                }
                            }
                        }
                        .padding()
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(12)
                    }

                    Button {
                        config.routingProfiles.append(APISyncRoutingProfile())
                        settings = config
                    } label: {
                        Label("Add Routing Profile", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)

                case .whmcs:
                    SectionHeader(title: "WHMCS Integration")

                    ConfigToggle(label: "Enable WHMCS", helpText: "Use the hosted client portal as an entitlement and ownership source for this server install.", isOn: Binding(
                        get: { config.whmcsEnabled },
                        set: { config.whmcsEnabled = $0; settings = config }
                    ))

                    if config.whmcsEnabled {
                        ConfigTextField(
                            label: "WHMCS URL",
                            placeholder: "https://devine-creations.com",
                            helpText: "Enter the base client portal URL this server should use for WHMCS-backed account and licensing checks.",
                            text: Binding(
                                get: { config.whmcsUrl ?? "" },
                                set: { config.whmcsUrl = $0.isEmpty ? nil : $0; settings = config }
                            )
                        )

                        ConfigTextField(
                            label: "API Identifier",
                            placeholder: "WHMCS API identifier",
                            helpText: "Use the WHMCS API identifier for the portal account that should authorize server-side license and ownership checks.",
                            text: Binding(
                                get: { config.whmcsApiIdentifier ?? "" },
                                set: { config.whmcsApiIdentifier = $0.isEmpty ? nil : $0; settings = config }
                            )
                        )

                        ConfigSecureField(
                            label: "API Secret",
                            placeholder: "WHMCS API secret",
                            helpText: "Paste the matching WHMCS API secret. It stays masked in the client UI.",
                            text: Binding(
                                get: { config.whmcsApiSecret ?? "" },
                                set: { config.whmcsApiSecret = $0.isEmpty ? nil : $0; settings = config }
                            )
                        )
                    }

                case .discovery:
                    SectionHeader(title: "Detected Targets")

                    Text("Detected peers and manual entries can both be used. Duplicate targets are valid if they serve different fallback or return flows.")
                        .font(.caption)
                        .foregroundColor(.gray)

                    ForEach(detectedTargets, id: \.self) { target in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(target)
                                    .foregroundColor(.white)
                                Text("Detected")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            Button("Add Profile") {
                                config.routingProfiles.append(APISyncRoutingProfile(label: "Detected Route", targetServer: target))
                                settings = config
                                selectedSubtab = .routing
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 4)
                    }

                    HStack {
                        TextField("Manual domain or IP", text: $manualServerEntry)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") {
                            let trimmed = manualServerEntry.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            config.routingProfiles.append(APISyncRoutingProfile(label: "Manual Route", targetServer: trimmed, manualAddress: trimmed))
                            settings = config
                            manualServerEntry = ""
                            selectedSubtab = .routing
                        }
                        .buttonStyle(.bordered)
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
                            Text("Save API Settings")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                }
                .padding(.top)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("API Sync settings are unavailable right now.")
                        .foregroundColor(.white)
                    if let loadError, !loadError.isEmpty {
                        Text(loadError)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    Button("Load Default Settings") {
                        settings = APISyncSettings()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .task {
            if let fetched = await adminManager.fetchAPISyncSettings() {
                settings = fetched
                loadError = nil
            } else {
                settings = APISyncSettings()
                loadError = adminManager.error ?? "The admin API returned no data. Defaults are loaded so you can still edit and save."
            }
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

    private var subtabToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(APISyncSubtab.allCases, id: \.self) { tab in
                    Button(tab.rawValue) {
                        selectedSubtab = tab
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(selectedSubtab == tab ? .blue : .gray.opacity(0.4))
                    .accessibilityLabel(tab.rawValue)
                    .accessibilityAddTraits(selectedSubtab == tab ? .isSelected : [])
                }
            }
        }
    }

    private var detectedTargets: [String] {
        Array(Set(SettingsManager.managedFederationServers.map(\.url))).sorted()
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

// MARK: - Deployment Section
struct AdminDeploymentSection: View {
    @ObservedObject var adminManager = AdminServerManager.shared
    @State private var selectedTransport = "sftp"
    @State private var packagePreset = ""
    @State private var targetLabel = ""
    @State private var targetServerUrl = ""
    @State private var ownerEmail = ""
    @State private var trustedServers = ""
    @State private var sanitize = true
    @State private var linkedToMain = true
    @State private var targetHost = ""
    @State private var targetPort = ""
    @State private var remotePath = ""
    @State private var uploadUrl = ""
    @State private var username = ""
    @State private var password = ""
    @State private var httpMethod = "PUT"
    @State private var insecure = false
    @State private var bootstrap = true
    @State private var apiBaseUrl = ""
    @State private var apiToken = ""
    @State private var sharedSecret = ""
    @State private var restartAfterBootstrap = false
    @State private var restartUrl = ""
    @State private var restartMethod = "POST"
    @State private var lastPackage: DeploymentPackageResponse?
    @State private var lastDeployment: DeploymentExecutionResponse?
    @State private var actionInFlight = false

    private var availableTransports: [DeploymentTransportInfo] {
        if adminManager.deploymentTransports.isEmpty {
            return adminManager.deploymentManagerStatus?.supportedTransports ?? []
        }
        return adminManager.deploymentTransports
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AdminHelpSection(
                title: "Quick Help",
                summary: "Deployment Manager packages a VoiceLink install, uploads it to another server over SFTP, SMB, HTTP, or HTTPS, bootstraps the remote API config, and can email the owner a getting-started note.",
                steps: [
                    "Generate a package when you need a fresh install bundle or want to stage an update on another server account.",
                    "Use Deploy when you already know the target transport and want VoiceLink to upload, bootstrap, and optionally restart the remote install.",
                    "Use Email Owner after a successful package or deploy so the server owner gets the remote URL, API base, and startup instructions."
                ],
                docs: [
                    AdminDocLink(title: "Deployment Docs", localRelativePath: "authenticated/admin-panel.html", webPath: "/docs/authenticated/admin-panel.html", adminWebPath: "/docs/authenticated/admin-panel.html"),
                    AdminDocLink(title: "Install Docs", localRelativePath: "installation/index.html", webPath: "/docs/installation/index.html", adminWebPath: "/docs/authenticated/admin-panel.html")
                ]
            )

            statusSection
            packageSection
            transportSection
            bootstrapSection
            actionSection
            resultsSection
        }
        .task {
            _ = await adminManager.fetchDeploymentManagerStatus()
            _ = await adminManager.fetchDeploymentTransports()
            if let base = adminManager.serverConfig?.serverName, targetLabel.isEmpty {
                targetLabel = "\(base) Remote Install"
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Deployment Manager")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Button("Refresh") {
                    Task {
                        _ = await adminManager.fetchDeploymentManagerStatus()
                        _ = await adminManager.fetchDeploymentTransports()
                    }
                }
                .buttonStyle(.bordered)
            }

            if let status = adminManager.deploymentManagerStatus {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ConfigSummaryItem(label: "Module Enabled", value: status.enabled ? "Yes" : "No")
                    ConfigSummaryItem(label: "Mail Ready", value: status.mailConfigured ? "Yes" : "No")
                    ConfigSummaryItem(label: "Fresh Install Bundles", value: status.supportsFreshInstall ? "Supported" : "Unavailable")
                    ConfigSummaryItem(label: "Remote Bootstrap", value: status.supportsRemoteBootstrap ? "Supported" : "Unavailable")
                }
            } else {
                Text("Deployment manager status has not loaded yet.")
                    .foregroundColor(.gray)
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }

    private var packageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Package Options")
            Text("These values are embedded into the generated deployment package. Linked-to-main packages preserve trusted federation defaults and API alignment.")
                .font(.caption)
                .foregroundColor(.gray)

            HStack(spacing: 12) {
                ConfigTextField(label: "Preset", text: $packagePreset)
                ConfigTextField(label: "Target Label", text: $targetLabel)
            }

            HStack(spacing: 12) {
                ConfigTextField(label: "Target Server URL", text: $targetServerUrl)
                ConfigTextField(label: "Owner Email", text: $ownerEmail)
            }

            ConfigTextField(label: "Trusted Servers (comma separated)", text: $trustedServers)

            HStack(spacing: 20) {
                ConfigToggle(label: "Sanitize secrets in package", isOn: $sanitize)
                ConfigToggle(label: "Link package to main cluster", isOn: $linkedToMain)
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }

    private var transportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Transport")
            Picker("Transport", selection: $selectedTransport) {
                ForEach(availableTransports) { transport in
                    Text(transport.name).tag(transport.id)
                }
                if availableTransports.isEmpty {
                    Text("SFTP").tag("sftp")
                    Text("SMB").tag("smb")
                    Text("HTTP").tag("http")
                    Text("HTTPS").tag("https")
                }
            }
            .pickerStyle(.menu)

            if let transport = availableTransports.first(where: { $0.id == selectedTransport }) {
                Text(transport.description)
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            if selectedTransport == "http" || selectedTransport == "https" {
                ConfigTextField(label: "Upload URL", text: $uploadUrl)
            } else {
                HStack(spacing: 12) {
                    ConfigTextField(label: "Host", text: $targetHost)
                    ConfigTextField(label: "Port", text: $targetPort)
                    ConfigTextField(label: "Remote Path", text: $remotePath)
                }
            }

            HStack(spacing: 12) {
                ConfigTextField(label: "Username", text: $username)
                ConfigSecureField(label: "Password", text: $password)
            }

            if selectedTransport == "http" || selectedTransport == "https" {
                Picker("HTTP Method", selection: $httpMethod) {
                    Text("PUT").tag("PUT")
                    Text("POST").tag("POST")
                }
                .pickerStyle(.segmented)
                ConfigToggle(label: "Allow insecure TLS", isOn: $insecure)
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }

    private var bootstrapSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Remote Bootstrap")

            ConfigToggle(label: "Bootstrap remote API after upload", isOn: $bootstrap)

            if bootstrap {
                ConfigTextField(label: "Remote API Base URL", text: $apiBaseUrl)
                HStack(spacing: 12) {
                    ConfigSecureField(label: "API Token", text: $apiToken)
                    ConfigSecureField(label: "Shared Secret", text: $sharedSecret)
                }
                ConfigToggle(label: "Restart remote install after bootstrap", isOn: $restartAfterBootstrap)
                if restartAfterBootstrap {
                    HStack(spacing: 12) {
                        ConfigTextField(label: "Restart URL", text: $restartUrl)
                        ConfigTextField(label: "Restart Method", text: $restartMethod)
                    }
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }

    private var actionSection: some View {
        HStack(spacing: 12) {
            Button("Generate Package") {
                Task { await generatePackage() }
            }
            .buttonStyle(.bordered)

            Button("Deploy to Target") {
                Task { await deployToTarget() }
            }
            .buttonStyle(.borderedProminent)

            Button("Email Owner Details") {
                Task { await emailOwnerDetails() }
            }
            .buttonStyle(.bordered)
            .disabled(ownerEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if actionInFlight {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .disabled(actionInFlight)
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let message = adminManager.deploymentActionMessage, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.green)
            }

            if let package = lastPackage {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last Package")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                    Text("Bundle: \(package.bundleName)")
                        .font(.caption)
                        .foregroundColor(.white)
                    Text("Stored on server: \(package.zipPath)")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                .padding()
                .background(Color.white.opacity(0.05))
                .cornerRadius(10)
            }

            if let deployment = lastDeployment {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last Deployment")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                    Text("Upload target: \(deployment.upload.remoteUrl)")
                        .font(.caption)
                        .foregroundColor(.white)
                    if let bootstrap = deployment.bootstrap {
                        Text("Bootstrap: \(bootstrap.success ? "Succeeded" : "Failed")")
                            .font(.caption2)
                            .foregroundColor(bootstrap.success ? .green : .orange)
                    }
                    if let restart = deployment.restart {
                        Text(restartStatusText(restart))
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }
                .padding()
                .background(Color.white.opacity(0.05))
                .cornerRadius(10)
            }
        }
    }

    private func generatePackage() async {
        actionInFlight = true
        defer { actionInFlight = false }
        lastPackage = await adminManager.buildDeploymentPackage(packageRequest)
    }

    private func deployToTarget() async {
        actionInFlight = true
        defer { actionInFlight = false }
        lastDeployment = await adminManager.runDeployment(
            DeploymentExecutionRequest(
                packageOptions: packageRequest,
                target: targetRequest,
                bootstrap: bootstrap
            )
        )
    }

    private func emailOwnerDetails() async {
        actionInFlight = true
        defer { actionInFlight = false }
        let bundleName = lastDeployment?.bundleName ?? lastPackage?.bundleName
        let remoteUrl = lastDeployment?.upload.remoteUrl
        _ = await adminManager.emailDeploymentOwner(
            DeploymentOwnerEmailRequest(
                recipient: ownerEmail,
                subject: "VoiceLink Deployment Details",
                bundleName: bundleName,
                remoteUrl: remoteUrl,
                apiBaseUrl: apiBaseUrl.isEmpty ? nil : apiBaseUrl
            )
        )
    }

    private var packageRequest: DeploymentPackageRequest {
        DeploymentPackageRequest(
            preset: packagePreset.isEmpty ? nil : packagePreset,
            sanitize: sanitize,
            ownerEmail: ownerEmail.isEmpty ? nil : ownerEmail,
            targetLabel: targetLabel.isEmpty ? nil : targetLabel,
            targetServerUrl: targetServerUrl.isEmpty ? nil : targetServerUrl,
            linkedToMain: linkedToMain,
            trustedServers: trustedServersList,
            extraConfig: DeploymentExtraConfig()
        )
    }

    private var targetRequest: DeploymentTargetRequest {
        DeploymentTargetRequest(
            transport: selectedTransport,
            host: targetHost.isEmpty ? nil : targetHost,
            port: Int(targetPort),
            remotePath: remotePath.isEmpty ? nil : remotePath,
            uploadUrl: uploadUrl.isEmpty ? nil : uploadUrl,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            method: (selectedTransport == "http" || selectedTransport == "https") ? httpMethod : nil,
            insecure: insecure,
            apiBaseUrl: apiBaseUrl.isEmpty ? nil : apiBaseUrl,
            apiToken: apiToken.isEmpty ? nil : apiToken,
            sharedSecret: sharedSecret.isEmpty ? nil : sharedSecret,
            trustedServers: trustedServersList.isEmpty ? nil : trustedServersList,
            restartAfterBootstrap: restartAfterBootstrap,
            restartUrl: restartUrl.isEmpty ? nil : restartUrl,
            restartMethod: restartAfterBootstrap ? restartMethod : nil
        )
    }

    private var trustedServersList: [String] {
        trustedServers
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func restartStatusText(_ restart: DeploymentRestartResponse) -> String {
        if restart.success == true {
            return "Restart: triggered"
        }
        if restart.skipped == true {
            return "Restart: skipped (\(restart.reason ?? "not configured"))"
        }
        return "Restart: failed (\(restart.error ?? "unknown"))"
    }
}

// MARK: - Modules Section
struct AdminModulesSection: View {
    @ObservedObject var adminManager = AdminServerManager.shared
    @State private var filterMode: ModuleFilter = .all
    @State private var query = ""
    @State private var actionInFlight: String?
    @State private var configEditorModule: ModuleEditorRequest?
    @State private var configEditorText: String = "{}"

    struct ModuleEditorRequest: Identifiable {
        let module: AdminModuleInfo
        let useAdvancedJSON: Bool

        var id: String {
            "\(module.id)-\(useAdvancedJSON ? "advanced" : "standard")"
        }
    }

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

                                Menu("Configure") {
                                    Button("Standard Controls") {
                                        configEditorModule = ModuleEditorRequest(module: module, useAdvancedJSON: false)
                                        configEditorText = module.configJSON
                                    }
                                    Button("Advanced JSON") {
                                        configEditorModule = ModuleEditorRequest(module: module, useAdvancedJSON: true)
                                        configEditorText = module.configJSON
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

                        VStack(alignment: .leading, spacing: 4) {
                            if module.installed {
                                Text(module.enabled ? "Disable stops this module without removing its saved configuration." : "Enable turns this module back on with its saved configuration.")
                                Text("Update fetches the latest version of this module from the server.")
                                Text("Configure opens standard controls first. Advanced JSON is available from the Configure menu for power users.")
                                Text("Uninstall removes the module from this server.")
                            } else {
                                Text("Install adds this module to the server and enables its standard controls.")
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.gray)
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
        .sheet(item: $configEditorModule) { request in
            ModuleConfigEditorSheet(
                module: request.module,
                jsonText: $configEditorText,
                useAdvancedJSON: request.useAdvancedJSON,
                onSave: { text in
                    runAction("save-config-\(request.module.id)") {
                        await adminManager.saveModuleConfig(request.module.id, jsonText: text)
                    }
                    configEditorModule = nil
                }
            )
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

private struct ModuleConfigEditorSheet: View {
    enum FieldKind {
        case bool
        case string
        case number
        case json
    }

    struct ConfigField: Identifiable {
        let id: String
        let path: [String]
        let label: String
        let kind: FieldKind
        var textValue: String
        var boolValue: Bool
    }

    let module: AdminModuleInfo
    @Binding var jsonText: String
    let useAdvancedJSON: Bool
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var fields: [ConfigField] = []
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configure \(module.name)")
                .font(.title3.bold())
                .foregroundColor(.white)

            Text("Standard controls are shown by default. Use Advanced JSON only when needed.")
                .font(.caption)
                .foregroundColor(.gray)

            if useAdvancedJSON {
                TextEditor(text: $jsonText)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if fields.isEmpty {
                            Text("No editable config fields were detected. Switch to Advanced JSON to edit raw config.")
                                .foregroundColor(.gray)
                                .font(.caption)
                        } else {
                            ForEach(fields.indices, id: \.self) { index in
                                let field = fields[index]
                                switch field.kind {
                                case .bool:
                                    Toggle(field.label, isOn: Binding(
                                        get: { fields[index].boolValue },
                                        set: { fields[index].boolValue = $0 }
                                    ))
                                    .tint(.blue)
                                case .string:
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(field.label)
                                            .foregroundColor(.gray)
                                            .font(.caption)
                                        TextField(field.label, text: Binding(
                                            get: { fields[index].textValue },
                                            set: { fields[index].textValue = $0 }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                    }
                                case .number:
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(field.label)
                                            .foregroundColor(.gray)
                                            .font(.caption)
                                        TextField("Number", text: Binding(
                                            get: { fields[index].textValue },
                                            set: { fields[index].textValue = $0 }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                    }
                                case .json:
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(field.label)
                                            .foregroundColor(.gray)
                                            .font(.caption)
                                        TextEditor(text: Binding(
                                            get: { fields[index].textValue },
                                            set: { fields[index].textValue = $0 }
                                        ))
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(minHeight: 64)
                                        .padding(6)
                                        .background(Color.white.opacity(0.08))
                                        .cornerRadius(8)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if let validationError, !validationError.isEmpty {
                Text(validationError)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Save") {
                    validationError = nil
                    if useAdvancedJSON {
                        onSave(jsonText)
                        dismiss()
                        return
                    }
                    guard let generatedJSON = rebuildJSONFromFields() else {
                        return
                    }
                    jsonText = generatedJSON
                    onSave(generatedJSON)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 420)
        .background(Color(red: 0.08, green: 0.09, blue: 0.14))
        .onAppear {
            parseFieldsFromJSON()
        }
    }

    private func parseFieldsFromJSON() {
        validationError = nil
        guard let data = jsonText.data(using: .utf8) else {
            fields = []
            validationError = "Config text must be valid UTF-8."
            return
        }

        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dictionary = object as? [String: Any] else {
                fields = []
                validationError = "Module config must be a JSON object."
                return
            }
            fields = flattenConfig(dictionary)
        } catch {
            fields = []
            validationError = "Unable to parse current config JSON: \(error.localizedDescription)"
        }
    }

    private func flattenConfig(_ dictionary: [String: Any], path: [String] = []) -> [ConfigField] {
        var output: [ConfigField] = []
        for key in dictionary.keys.sorted() {
            let value = dictionary[key] as Any
            let currentPath = path + [key]
            if let nested = value as? [String: Any] {
                output.append(contentsOf: flattenConfig(nested, path: currentPath))
                continue
            }

            let label = currentPath.joined(separator: " > ")
            if let boolValue = value as? Bool {
                output.append(ConfigField(
                    id: currentPath.joined(separator: "."),
                    path: currentPath,
                    label: label,
                    kind: .bool,
                    textValue: boolValue ? "true" : "false",
                    boolValue: boolValue
                ))
                continue
            }

            if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                output.append(ConfigField(
                    id: currentPath.joined(separator: "."),
                    path: currentPath,
                    label: label,
                    kind: .number,
                    textValue: number.stringValue,
                    boolValue: false
                ))
                continue
            }

            if let stringValue = value as? String {
                output.append(ConfigField(
                    id: currentPath.joined(separator: "."),
                    path: currentPath,
                    label: label,
                    kind: .string,
                    textValue: stringValue,
                    boolValue: false
                ))
                continue
            }

            let fallback = stringifyJSONObject(value) ?? "\(value)"
            output.append(ConfigField(
                id: currentPath.joined(separator: "."),
                path: currentPath,
                label: label,
                kind: .json,
                textValue: fallback,
                boolValue: false
            ))
        }
        return output
    }

    private func rebuildJSONFromFields() -> String? {
        var root: [String: Any] = [:]
        for field in fields {
            let value: Any
            switch field.kind {
            case .bool:
                value = field.boolValue
            case .string:
                value = field.textValue
            case .number:
                let trimmed = field.textValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if let intValue = Int(trimmed) {
                    value = intValue
                } else if let doubleValue = Double(trimmed) {
                    value = doubleValue
                } else {
                    validationError = "Invalid number for \(field.label)."
                    return nil
                }
            case .json:
                let trimmed = field.textValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    value = [:]
                } else if let data = trimmed.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) {
                    value = object
                } else {
                    validationError = "Invalid JSON for \(field.label)."
                    return nil
                }
            }
            assignValue(value, into: &root, path: field.path)
        }

        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            validationError = "Failed to serialize updated module config."
            return nil
        }

        return text
    }

    private func assignValue(_ value: Any, into dictionary: inout [String: Any], path: [String]) {
        guard let key = path.first else { return }
        if path.count == 1 {
            dictionary[key] = value
            return
        }
        var child = dictionary[key] as? [String: Any] ?? [:]
        assignValue(value, into: &child, path: Array(path.dropFirst()))
        dictionary[key] = child
    }

    private func stringifyJSONObject(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
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
    @State private var inAppDoc: IdentifiedURL?

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
                        let resolvedURL = AdminDocsResolver.resolve(doc, isAdmin: adminManager.adminRole.canManageConfig)
                        Menu {
                            Button("Open in App") {
                                guard let url = resolvedURL else { return }
                                inAppDoc = IdentifiedURL(url: url)
                            }
                            .disabled(resolvedURL == nil)

                            Button("Open in Safari") {
                                guard let url = resolvedURL else { return }
                                openInSafari(url)
                            }
                            .disabled(resolvedURL == nil)

                            Button("Open in Default Browser") {
                                guard let url = resolvedURL else { return }
                                NSWorkspace.shared.open(url)
                            }
                            .disabled(resolvedURL == nil)
                        } label: {
                            Label(doc.title, systemImage: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(resolvedURL == nil)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
        .sheet(item: $inAppDoc) { destination in
            AdminDocViewer(url: destination.url)
        }
    }

    private func openInSafari(_ url: URL) {
        guard let safariURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            NSWorkspace.shared.open(url)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: safariURL, configuration: configuration)
    }
}

private struct IdentifiedURL: Identifiable {
    let id = UUID()
    let url: URL
}

private struct AdminDocViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(url.lastPathComponent.isEmpty ? "Documentation" : url.lastPathComponent)
                    .font(.headline)
                Spacer()
                Button("Open in Browser") {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.bordered)
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
            Divider()
            AdminDocWebView(url: url)
        }
        .frame(minWidth: 900, minHeight: 640)
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private struct AdminDocWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.allowsMagnification = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }
}

struct ConfigTextField: View {
    let label: String
    var placeholder: String = ""
    var helpText: String? = nil
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.gray)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
            if let helpText, !helpText.isEmpty {
                Text(helpText)
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
        }
    }
}

struct ConfigSecureField: View {
    let label: String
    var placeholder: String = ""
    var helpText: String? = nil
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.gray)
            SecureField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
            if let helpText, !helpText.isEmpty {
                Text(helpText)
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
        }
    }
}

struct ConfigNumberField: View {
    let label: String
    var helpText: String? = nil
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.gray)
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
            if let helpText, !helpText.isEmpty {
                Text(helpText)
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ConfigToggle: View {
    let label: String
    var helpText: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(label, isOn: $isOn)
                .foregroundColor(.white)
            if let helpText, !helpText.isEmpty {
                Text(helpText)
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - ServerConfig Extensions
extension ServerConfig {
    func with(serverName: String? = nil, serverDescription: String? = nil, maxUsers: Int? = nil,
              maxRooms: Int? = nil, maxUsersPerRoom: Int? = nil, welcomeMessage: String?? = nil,
              motd: String?? = nil, motdSettings: MOTDSettings? = nil,
              registrationEnabled: Bool? = nil, requireAuth: Bool? = nil,
              allowGuests: Bool? = nil, maxGuestDuration: Int?? = nil, enableRateLimiting: Bool? = nil,
              serverVisibility: ServerVisibilityConfig? = nil,
              handoffPromptMode: String? = nil,
              messageSettings: MessageSettings? = nil,
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
            serverVisibility: serverVisibility ?? self.serverVisibility,
            handoffPromptMode: handoffPromptMode ?? self.handoffPromptMode,
            messageSettings: messageSettings ?? self.messageSettings,
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
