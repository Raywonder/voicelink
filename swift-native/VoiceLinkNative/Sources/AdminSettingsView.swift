import SwiftUI
import AppKit
import WebKit
import AVFoundation

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
            VStack(spacing: 10) {
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
                        Text(adminRoleBadgeText)
                            .font(.caption)
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(adminRoleColor.opacity(0.2))
                    .cornerRadius(20)
                }

                adminScopeBar
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
            if let serverURL = appState.serverManager.baseURL, !serverURL.isEmpty {
                await adminManager.checkAdminStatus(
                    serverURL: serverURL,
                    token: authManager.currentUser?.accessToken
                )
            }
            if !canAccessTab(selectedTab) {
                selectedTab = .overview
            }
            adminManager.refreshManagementTargets()
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
        .onReceive(NotificationCenter.default.publisher(for: .adminSelectTab)) { notification in
            guard let rawValue = notification.object as? String,
                  let tab = AdminTab(rawValue: rawValue),
                  canAccessTab(tab) else { return }
            selectedTab = tab
        }
        .onChange(of: adminManager.selectedManagementTargetID) { newValue in
            Task {
                await adminManager.selectManagementTarget(newValue, token: authManager.currentUser?.accessToken)
                await reloadSelectedAdminTarget()
            }
        }
        .onChange(of: adminManager.manageAllLinkedServers) { enabled in
            if enabled && !canAccessTab(selectedTab) {
                selectedTab = .overview
            }
        }
    }

    private var adminRoleIcon: String {
        switch adminManager.adminRole {
        case .owner: return "crown.fill"
        case .admin: return "shield.fill"
        case .roomManager: return "rectangle.3.group.bubble.left"
        case .moderator: return "person.badge.shield.checkmark"
        case .none: return "person"
        }
    }

    private var adminRoleColor: Color {
        switch adminManager.adminRole {
        case .owner: return .yellow
        case .admin: return .purple
        case .roomManager: return .green
        case .moderator: return .blue
        case .none: return .gray
        }
    }

    private var adminRoleBadgeText: String {
        switch adminManager.adminRole {
        case .owner:
            return "Owner / Admin"
        case .admin:
            return "Admin"
        case .roomManager:
            return "Room Manager"
        case .moderator:
            return "Moderator"
        case .none:
            return "No Server Role"
        }
    }

    private func canAccessTab(_ tab: AdminTab) -> Bool {
        if adminManager.manageAllLinkedServers {
            switch tab {
            case .overview, .modules, .deployment, .selfTests, .config, .streams, .apiSync, .federation:
                return adminManager.adminRole.canManageConfig || tab == .overview
            case .users, .support, .rooms:
                return false
            }
        }
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

    @ViewBuilder
    private var adminScopeBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Manage")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.gray)

                Picker("Manage", selection: $adminManager.selectedManagementTargetID) {
                    ForEach(adminManager.managementTargets) { target in
                        Text(target.displayLabel).tag(target.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Toggle("All Cluster Servers", isOn: $adminManager.manageAllLinkedServers)
                    .toggleStyle(.switch)
                    .disabled(!adminManager.canManageMultipleTargets)
                    .help("Use shared overview and federation controls across the linked VoiceLink server cluster owned by this admin.")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(adminManager.manageAllLinkedServers ? adminManager.allLinkedScopeSummary : "Managing \(adminManager.selectedManagementTargetName)")
                    .font(.caption)
                    .foregroundColor(.gray)

                if adminManager.manageAllLinkedServers {
                    Text("Shared mode applies configuration changes across the linked VoiceLink server cluster. Use the Manage picker to switch back to an individual server whenever you need per-server naming, federation, or other targeted edits.")
                        .font(.caption2)
                        .foregroundColor(.gray.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                } else if let selectedTarget = adminManager.managementTargets.first(where: { $0.id == adminManager.selectedManagementTargetID }) {
                    Text("\(selectedTarget.kindLabel) target: \(selectedTarget.url)")
                        .font(.caption2)
                        .foregroundColor(.gray.opacity(0.9))
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reloadSelectedAdminTarget() async {
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

private enum HandoffPromptMode: String, CaseIterable, Identifiable {
    case serverRecommended
    case alwaysAsk
    case automatic
    case neverPrompt

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .serverRecommended: return "Server Recommended"
        case .alwaysAsk: return "Always Ask"
        case .automatic: return "Move Automatically"
        case .neverPrompt: return "Do Not Prompt"
        }
    }

    var description: String {
        switch self {
        case .serverRecommended: return "Use the server's suggested failover and maintenance handoff behavior."
        case .alwaysAsk: return "Always prompt users before moving them during maintenance or failover."
        case .automatic: return "Move users automatically when a trusted handoff target is available."
        case .neverPrompt: return "Do not present handoff prompts to clients by default."
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

// MARK: - Config Section
struct AdminConfigSection: View {
    @ObservedObject var adminManager = AdminServerManager.shared
    @State private var editedConfig: ServerConfig?
    @State private var editedAdvancedSettings: AdvancedServerSettings?
    @State private var selectedSection: ConfigSection = .identity
    @State private var isSaving = false
    @State private var databaseActionInFlight = false
    @State private var mastodonBotInstanceURL = ""
    @State private var mastodonBotAccessToken = ""
    @State private var mastodonBotActionInFlight = false

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
            if adminManager.databaseStatus == nil {
                await adminManager.fetchDatabaseStatus()
            }
            if adminManager.schedulerStatus == nil && adminManager.schedulerError == nil {
                await adminManager.fetchServerSchedulerStatus()
            }
            if adminManager.mastodonBots.isEmpty && adminManager.mastodonBotError == nil {
                await adminManager.fetchMastodonBots()
            }
            if adminManager.authProviderStatus == nil && adminManager.authProviderStatusError == nil {
                await adminManager.fetchAuthProviderStatus()
            }
            if adminManager.sharedAuthGroups.isEmpty && adminManager.sharedAuthGroupsError == nil {
                await adminManager.fetchSharedAuthGroups()
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

                SectionHeader(title: "Authentication Policy")

                Text("VoiceLink always includes the built-in authentication and 2FA module. These controls decide which upstream providers and shared member auth paths this server exposes to users in the security tab and login flows.")
                    .font(.caption)
                    .foregroundColor(.gray)

                ConfigToggle(label: "Enable VoiceLink Internal Auth", isOn: Binding(
                    get: { editedConfig?.authSettings.internalProviderEnabled ?? config.authSettings.internalProviderEnabled },
                    set: { value in
                        var next = editedConfig ?? config
                        next.authSettings.internalProviderEnabled = value
                        editedConfig = next
                    }
                ))

                ConfigToggle(label: "Enable Client Portal Fallback", isOn: Binding(
                    get: { editedConfig?.authSettings.whmcsProviderEnabled ?? config.authSettings.whmcsProviderEnabled },
                    set: { value in
                        var next = editedConfig ?? config
                        next.authSettings.whmcsProviderEnabled = value
                        editedConfig = next
                    }
                ))

                ConfigToggle(label: "Enable WordPress Auth Bridge", isOn: Binding(
                    get: { editedConfig?.authSettings.wordpressProviderEnabled ?? config.authSettings.wordpressProviderEnabled },
                    set: { value in
                        var next = editedConfig ?? config
                        next.authSettings.wordpressProviderEnabled = value
                        editedConfig = next
                    }
                ))

                ConfigToggle(label: "Enable Composr Auth Bridge", isOn: Binding(
                    get: { editedConfig?.authSettings.composrProviderEnabled ?? config.authSettings.composrProviderEnabled },
                    set: { value in
                        var next = editedConfig ?? config
                        next.authSettings.composrProviderEnabled = value
                        editedConfig = next
                    }
                ))

                ConfigToggle(label: "Enable Shared Member Auth", isOn: Binding(
                    get: { editedConfig?.authSettings.sharedMemberAuthEnabled ?? config.authSettings.sharedMemberAuthEnabled },
                    set: { value in
                        var next = editedConfig ?? config
                        next.authSettings.sharedMemberAuthEnabled = value
                        editedConfig = next
                    }
                ))

                Picker("Shared Member Auth Mode", selection: Binding(
                    get: { editedConfig?.authSettings.sharedMemberAuthMode ?? config.authSettings.sharedMemberAuthMode },
                    set: { value in
                        var next = editedConfig ?? config
                        next.authSettings.sharedMemberAuthMode = value
                        editedConfig = next
                    }
                )) {
                    Text("Group").tag("group")
                    Text("Server").tag("server")
                    Text("Hybrid").tag("hybrid")
                }
                .pickerStyle(.menu)

                ConfigTextField(
                    label: "Shared Auth Providers",
                    placeholder: "voicelink, composr, whmcs",
                    helpText: "Comma-separated providers allowed to create or attach a shared member account for server groups or member groups.",
                    text: Binding(
                        get: { (editedConfig?.authSettings.sharedMemberAuthProviders ?? config.authSettings.sharedMemberAuthProviders).joined(separator: ", ") },
                        set: { value in
                            var next = editedConfig ?? config
                            next.authSettings.sharedMemberAuthProviders = value
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                                .filter { !$0.isEmpty }
                            editedConfig = next
                        }
                    )
                )

                ConfigToggle(label: "Allow Client Portal Token Refresh Fallback", isOn: Binding(
                    get: { editedConfig?.authSettings.allowWhmcsFallback ?? config.authSettings.allowWhmcsFallback },
                    set: { value in
                        var next = editedConfig ?? config
                        next.authSettings.allowWhmcsFallback = value
                        editedConfig = next
                    }
                ))

                ConfigToggle(label: "Allow Mastodon Approval Delivery", isOn: Binding(
                    get: { editedConfig?.authSettings.allowMastodonApprovalDelivery ?? config.authSettings.allowMastodonApprovalDelivery },
                    set: { value in
                        var next = editedConfig ?? config
                        next.authSettings.allowMastodonApprovalDelivery = value
                        editedConfig = next
                    }
                ))

                ConfigToggle(label: "Require Approval for Second Device Sign-In", isOn: Binding(
                    get: { editedConfig?.authSettings.requireSecondDeviceApproval ?? config.authSettings.requireSecondDeviceApproval },
                    set: { value in
                        var next = editedConfig ?? config
                        next.authSettings.requireSecondDeviceApproval = value
                        editedConfig = next
                    }
                ))

                ConfigTextField(
                    label: "Allowed 2FA Methods",
                    placeholder: "totp, email, sms, voice, passkey, backup",
                    helpText: "Only these methods will be offered in the user's Security tab for this server.",
                    text: Binding(
                        get: { (editedConfig?.authSettings.allowedTwoFactorMethods ?? config.authSettings.allowedTwoFactorMethods).joined(separator: ", ") },
                        set: { value in
                            var next = editedConfig ?? config
                            next.authSettings.allowedTwoFactorMethods = value
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                                .filter { !$0.isEmpty }
                            editedConfig = next
                        }
                    )
                )

                SectionHeader(title: "Client Visibility")

                Text("Federation covers all linked servers, but each server still controls whether it appears on Desktop, iOS, and Web. Leave these enabled when the server should be visible across all platforms.")
                    .font(.caption)
                    .foregroundColor(.gray)

                ConfigToggle(label: "List Server in Public Directory", helpText: "When off, the server stays reachable by direct domain, exact search, or reveal code, but it is not advertised in normal client server lists.", isOn: Binding(
                    get: { editedConfig?.serverVisibility.listedInDirectory ?? config.serverVisibility.listedInDirectory },
                    set: { value in
                        var next = editedConfig ?? config
                        next.serverVisibility.listedInDirectory = value
                        editedConfig = next
                    }
                ))

                ConfigToggle(label: "Allow Direct Domain or Code Reveal", helpText: "When on, users who know the domain, server name, static code, or rotating code can reveal and save the server in their client.", isOn: Binding(
                    get: { editedConfig?.serverVisibility.allowDirectReveal ?? config.serverVisibility.allowDirectReveal },
                    set: { value in
                        var next = editedConfig ?? config
                        next.serverVisibility.allowDirectReveal = value
                        editedConfig = next
                    }
                ))

                ConfigTextField(
                    label: "Static Reveal Codes",
                    placeholder: "family-code, launch-team, always-on-code",
                    helpText: "Comma-separated codes that reveal this server when it is hidden from normal directory listings.",
                    text: Binding(
                        get: { (editedConfig?.serverDiscoveryReveal.staticCodes ?? config.serverDiscoveryReveal.staticCodes).joined(separator: ", ") },
                        set: { value in
                            var next = editedConfig ?? config
                            next.serverDiscoveryReveal.staticCodes = value
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                            editedConfig = next
                        }
                    )
                )

                ConfigToggle(label: "Enable Rotating Reveal Code", helpText: "Generates a time-changing code from the secret below so trusted users can reveal a hidden server without exposing it publicly.", isOn: Binding(
                    get: { editedConfig?.serverDiscoveryReveal.rotatingCode.enabled ?? config.serverDiscoveryReveal.rotatingCode.enabled },
                    set: { value in
                        var next = editedConfig ?? config
                        next.serverDiscoveryReveal.rotatingCode.enabled = value
                        editedConfig = next
                    }
                ))

                ConfigSecureField(
                    label: "Rotating Reveal Secret",
                    placeholder: "Leave masked value unchanged to keep the current secret",
                    helpText: "Used to generate rotating reveal codes. It is saved server-side and returned masked when already configured.",
                    text: Binding(
                        get: { editedConfig?.serverDiscoveryReveal.rotatingCode.seed ?? config.serverDiscoveryReveal.rotatingCode.seed },
                        set: { value in
                            var next = editedConfig ?? config
                            next.serverDiscoveryReveal.rotatingCode.seed = value
                            editedConfig = next
                        }
                    )
                )

                HStack(spacing: 16) {
                    ConfigNumberField(label: "Reveal Code Minutes", helpText: "How long each rotating reveal code remains current.", value: Binding(
                        get: { editedConfig?.serverDiscoveryReveal.rotatingCode.intervalMinutes ?? config.serverDiscoveryReveal.rotatingCode.intervalMinutes },
                        set: { value in
                            var next = editedConfig ?? config
                            next.serverDiscoveryReveal.rotatingCode.intervalMinutes = max(1, value)
                            editedConfig = next
                        }
                    ))
                    ConfigNumberField(label: "Reveal Code Length", helpText: "Generated code length from 4 to 24 characters.", value: Binding(
                        get: { editedConfig?.serverDiscoveryReveal.rotatingCode.length ?? config.serverDiscoveryReveal.rotatingCode.length },
                        set: { value in
                            var next = editedConfig ?? config
                            next.serverDiscoveryReveal.rotatingCode.length = min(24, max(4, value))
                            editedConfig = next
                        }
                    ))
                }

                ConfigToggle(label: "Accept Previous Reveal Code Window", helpText: "Allows the immediately previous rotating code so users are not locked out during clock or network delays.", isOn: Binding(
                    get: { editedConfig?.serverDiscoveryReveal.rotatingCode.acceptPreviousWindow ?? config.serverDiscoveryReveal.rotatingCode.acceptPreviousWindow },
                    set: { value in
                        var next = editedConfig ?? config
                        next.serverDiscoveryReveal.rotatingCode.acceptPreviousWindow = value
                        editedConfig = next
                    }
                ))

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

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Authentication Provider Health")

                Text("This reflects the live server-side auth/provider state used by VoiceLink administration, recovery, and linked-account features.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let authStatus = adminManager.authProviderStatus {
                    ForEach(authStatus.providers.keys.sorted(), id: \.self) { key in
                        if let provider = authStatus.providers[key] {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(provider.label ?? key.capitalized)
                                        .foregroundColor(.white)
                                    Text(provider.enabled ? "Enabled" : "Disabled")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    if let botCount = provider.botCount {
                                        Text("Bot Accounts: \(botCount)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    if let portalUrl = provider.portalUrl, !portalUrl.isEmpty {
                                        Text("Portal: \(portalUrl)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Text(provider.health.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.white.opacity(0.08))
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(10)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("SMTP: \(authStatus.smtp.configured ? "Configured" : "Not Configured")")
                        Text("SMTP Health: \(authStatus.smtp.health.replacingOccurrences(of: "_", with: " ").capitalized)")
                        if let host = authStatus.smtp.host, !host.isEmpty {
                            Text("SMTP Host: \(host):\(authStatus.smtp.port)")
                        }
                        if let from = authStatus.smtp.from, !from.isEmpty {
                            Text("SMTP From: \(from)")
                        }
                        Text("Email Code Recovery: \(authStatus.recovery.emailCodesAvailable ? "Available" : "Unavailable")")
                        Text("SMTP Recovery: \(authStatus.recovery.smtpRecoveryAvailable ? "Available" : "Unavailable")")
                        Text("Break-Glass Recovery: \(authStatus.recovery.breakGlassConfigured ? "Configured" : "Not Configured")")
                        Text("Server Scheduler: \(authStatus.scheduler.available ? authStatus.scheduler.health.capitalized : "Unavailable")")
                        if let policy = authStatus.policy {
                            Text("Shared Member Auth: \(policy.sharedMemberAuthEnabled ? "Enabled (\(policy.sharedMemberAuthMode.capitalized))" : "Disabled")")
                            Text("Second Device Approval: \(policy.requireSecondDeviceApproval ? "Required" : "Optional")")
                            Text("Allowed 2FA Methods: \(policy.allowedTwoFactorMethods.joined(separator: ", "))")
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(10)
                } else if let authError = adminManager.authProviderStatusError, !authError.isEmpty {
                    Text(authError)
                        .font(.caption)
                        .foregroundColor(.orange)
                } else {
                    Text("Auth provider status has not been loaded yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button("Refresh Provider Health") {
                    Task { await adminManager.fetchAuthProviderStatus() }
                }
                .buttonStyle(.bordered)

                SectionHeader(title: "Shared Member Auth Groups")

                Text("These shared groups are the durable backend records used to map Composr or other upstream member/group identities into VoiceLink shared accounts.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if adminManager.sharedAuthGroups.isEmpty {
                    Text(adminManager.sharedAuthGroupsError?.isEmpty == false ? adminManager.sharedAuthGroupsError! : "No shared member auth groups saved yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(adminManager.sharedAuthGroups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(group.name)
                                    .foregroundColor(.white)
                                Spacer()
                                Text("\(group.memberCount) members")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text("\(group.source.capitalized) • \(group.mode.capitalized) • \(group.providers.joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            if !group.description.isEmpty {
                                Text(group.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if let firstMember = group.members.first {
                                Text("Example member: \(firstMember.displayName) (\(firstMember.provider.capitalized))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(10)
                    }
                }

                Button("Refresh Shared Member Auth Groups") {
                    Task { await adminManager.fetchSharedAuthGroups() }
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Mastodon Bot Accounts")

                Text("Register the built-in VoiceLink bot as a real Mastodon bot account on connected instances for announcements, moderation commands, and management actions.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ConfigTextField(
                    label: "Instance URL",
                    placeholder: "https://md.tappedin.fm",
                    helpText: "The Mastodon instance where the VoiceLink bot account exists.",
                    defaultValueDescription: "Blank until you register a bot.",
                    text: $mastodonBotInstanceURL
                )

                ConfigSecureField(
                    label: "Bot Access Token",
                    placeholder: "Paste the bot account access token",
                    helpText: "Use the Mastodon bot account token for VoiceLink bot posting and commands.",
                    defaultValueDescription: "Blank until supplied.",
                    text: $mastodonBotAccessToken
                )

                HStack(spacing: 12) {
                    Button("Register Bot Account") {
                        mastodonBotActionInFlight = true
                        Task {
                            let success = await adminManager.registerMastodonBot(
                                instanceURL: mastodonBotInstanceURL.trimmingCharacters(in: .whitespacesAndNewlines),
                                accessToken: mastodonBotAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                            if success {
                                mastodonBotAccessToken = ""
                            }
                            mastodonBotActionInFlight = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        mastodonBotActionInFlight ||
                        mastodonBotInstanceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        mastodonBotAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )

                    Button("Refresh Bot Accounts") {
                        mastodonBotActionInFlight = true
                        Task {
                            await adminManager.fetchMastodonBots()
                            mastodonBotActionInFlight = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(mastodonBotActionInFlight)
                }

                if let botError = adminManager.mastodonBotError, !botError.isEmpty {
                    Text(botError)
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                if adminManager.mastodonBots.isEmpty {
                    Text("No Mastodon bot accounts registered yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(adminManager.mastodonBots) { bot in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(bot.displayName?.isEmpty == false ? bot.displayName! : "VoiceLink")
                                        .foregroundColor(.white)
                                    Text(bot.instance)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    if let username = bot.username, !username.isEmpty {
                                        Text("@\(username)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Text(bot.enabled ? "Enabled" : "Disabled")
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.white.opacity(0.08))
                                    .foregroundColor(.white)
                                    .cornerRadius(8)

                                Button("Remove") {
                                    mastodonBotActionInFlight = true
                                    Task {
                                        _ = await adminManager.removeMastodonBot(instanceURL: bot.instance)
                                        mastodonBotActionInFlight = false
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(mastodonBotActionInFlight)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(10)
                        }
                    }
                }
            }
        }
    }

    private func messagesSection(config: ServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: "Server Welcome and MOTD")

            Text("These messages are shown in the main window, lobby, and joined rooms depending on the options below.")
                .font(.caption)
                .foregroundColor(.gray)

            ConfigTextField(
                label: "Lobby Welcome Message",
                placeholder: "Welcome everyone before they join a room. Add guidance, links, or a short hello here.",
                helpText: "Shown in the room browser before a user joins a room.",
                defaultValueDescription: "Welcome to VoiceLink.",
                text: Binding(
                    get: { editedConfig?.lobbyWelcomeMessage ?? config.lobbyWelcomeMessage ?? "" },
                    set: { editedConfig = (editedConfig ?? config).with(lobbyWelcomeMessage: $0.isEmpty ? nil : $0) }
                )
            )

            ConfigTextField(
                label: "Server Welcome Message",
                placeholder: "General welcome text shown for the connected server.",
                helpText: "Shown in the connected server summary and other main app surfaces.",
                defaultValueDescription: "Blank unless your server sets one.",
                text: Binding(
                    get: { editedConfig?.welcomeMessage ?? config.welcomeMessage ?? "" },
                    set: { editedConfig = (editedConfig ?? config).with(welcomeMessage: $0.isEmpty ? nil : $0) }
                )
            )

            ConfigTextField(
                label: "Message of the Day",
                placeholder: "Share a featured link, maintenance notice, event, or current update.",
                helpText: "Use this for short rotating announcements that can also appear inside rooms.",
                defaultValueDescription: "Blank and disabled.",
                text: Binding(
                    get: { editedConfig?.motd ?? config.motd ?? "" },
                    set: { editedConfig = (editedConfig ?? config).with(motd: $0.isEmpty ? nil : $0) }
                )
            )

            SectionHeader(title: "MOTD Display")

            ConfigToggle(label: "Enable Message of the Day", defaultValueDescription: "Off", isOn: Binding(
                get: { editedConfig?.motdSettings.enabled ?? config.motdSettings.enabled },
                set: { editedConfig = (editedConfig ?? config).with(motdSettings: (editedConfig ?? config).motdSettingsUpdating(enabled: $0)) }
            ))

            ConfigToggle(label: "Show Before Joining Rooms", defaultValueDescription: "On", isOn: Binding(
                get: { editedConfig?.motdSettings.showBeforeJoin ?? config.motdSettings.showBeforeJoin },
                set: { editedConfig = (editedConfig ?? config).with(motdSettings: (editedConfig ?? config).motdSettingsUpdating(showBeforeJoin: $0)) }
            ))

            ConfigToggle(label: "Show Inside Joined Rooms", defaultValueDescription: "On", isOn: Binding(
                get: { editedConfig?.motdSettings.showInRoom ?? config.motdSettings.showInRoom },
                set: { editedConfig = (editedConfig ?? config).with(motdSettings: (editedConfig ?? config).motdSettingsUpdating(showInRoom: $0)) }
            ))

            ConfigToggle(label: "Append MOTD to Welcome Message", defaultValueDescription: "Off", isOn: Binding(
                get: { editedConfig?.motdSettings.appendToWelcomeMessage ?? config.motdSettings.appendToWelcomeMessage },
                set: { editedConfig = (editedConfig ?? config).with(motdSettings: (editedConfig ?? config).motdSettingsUpdating(appendToWelcomeMessage: $0)) }
            ))

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

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Database Actions")

                Text("Initialize the database first, then migrate the current JSON-backed defaults into database snapshots. This keeps your existing files in place while you verify the database state.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let status = adminManager.databaseStatus {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Provider: \(status.provider.capitalized)")
                        Text("SQLite Available: \(status.sqliteAvailable ? "Yes" : "No")")
                        Text("Database File: \(status.exists ? "Ready" : "Not Created Yet")")
                        if !status.dbPath.isEmpty {
                            Text("Path: \(status.dbPath)")
                        }
                        Text("Size: \(ByteCountFormatter.string(fromByteCount: Int64(status.sizeBytes), countStyle: .file))")
                        if let lastMigration = status.lastMigration, !lastMigration.isEmpty {
                            Text("Last Migration: \(lastMigration)")
                        }
                        if !status.snapshotCounts.isEmpty {
                            Text("Snapshots: " + status.snapshotCounts.keys.sorted().map { "\($0)=\(status.snapshotCounts[$0] ?? 0)" }.joined(separator: ", "))
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(10)
                } else {
                    Text("Database status has not been loaded yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let message = adminManager.databaseActionMessage, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.green)
                }

                HStack(spacing: 12) {
                    Button("Refresh Status") {
                        databaseActionInFlight = true
                        Task {
                            await adminManager.fetchDatabaseStatus()
                            databaseActionInFlight = false
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("Initialize Database") {
                        databaseActionInFlight = true
                        Task {
                            _ = await adminManager.initializeDatabase()
                            databaseActionInFlight = false
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Migrate Default Data") {
                        databaseActionInFlight = true
                        Task {
                            _ = await adminManager.migrateDefaultDataToDatabase()
                            databaseActionInFlight = false
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .disabled(databaseActionInFlight)
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Server Scheduler")

                Text("VoiceLink uses a server-side internal scheduler for sync, health probes, and maintenance work. This status should stay in sync with the active server instance.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let status = adminManager.schedulerStatus {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Service: \(status.service)")
                        Text("Visible Tasks: \(status.totalVisibleTasks)")
                        Text("Enabled Tasks: \(status.enabledTasks)")
                        Text("Running Tasks: \(status.runningTasks)")
                        Text("Role: \(status.role.capitalized)")
                        Text("Server Time: \(status.serverTime)")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(10)
                } else if let schedulerError = adminManager.schedulerError, !schedulerError.isEmpty {
                    Text(schedulerError)
                        .font(.caption)
                        .foregroundColor(.orange)
                } else {
                    Text("Scheduler status has not been loaded yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if !adminManager.schedulerTasks.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Tasks")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)

                        ForEach(adminManager.schedulerTasks) { task in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(task.name)
                                            .foregroundColor(.white)
                                        Text(task.description)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text(task.lastStatus.capitalized)
                                        .font(.caption2)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.white.opacity(0.08))
                                        .foregroundColor(.white)
                                        .cornerRadius(8)
                                }

                                HStack(spacing: 16) {
                                    Toggle("Enabled", isOn: Binding(
                                        get: { task.enabled },
                                        set: { value in
                                            Task { _ = await adminManager.updateServerSchedulerTask(task.id, enabled: value) }
                                        }
                                    ))
                                    .toggleStyle(.switch)

                                    if task.running {
                                        HStack(spacing: 6) {
                                            ProgressView()
                                                .controlSize(.small)
                                            Text("Running")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    } else {
                                        Button("Run Now") {
                                            Task { _ = await adminManager.runServerSchedulerTask(task.id) }
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }

                                HStack(spacing: 20) {
                                    Text("Every \(task.intervalSeconds) sec")
                                    Text("Last Run: \(task.lastRunAt ?? "Never")")
                                }
                                .font(.caption2)
                                .foregroundColor(.secondary)

                                Text("Next Run: \(task.nextRunAt ?? "Not scheduled")")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)

                                if let lastMessage = task.lastMessage, !lastMessage.isEmpty {
                                    Text(lastMessage)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(10)
                        }
                    }
                }

                if !adminManager.schedulerLogs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent Job History")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)

                        ForEach(adminManager.schedulerLogs.prefix(8)) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(entry.taskName)
                                        .foregroundColor(.white)
                                    Spacer()
                                    Text(entry.status.capitalized)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Text("\(entry.timestamp) • \(entry.actor) • \(entry.trigger)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                if let message = entry.message, !message.isEmpty {
                                    Text(message)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(10)
                }

                Button("Refresh Scheduler Status") {
                    Task { await adminManager.fetchServerSchedulerStatus() }
                }
                .buttonStyle(.bordered)
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
            SectionHeader(title: "Admin Login Alerts")
            ConfigToggle(label: "Alert Admins on Login Attempts", isOn: Binding(
                get: { editedConfig?.authSettings.notifyAdminsOnLoginAttempts ?? config.authSettings.notifyAdminsOnLoginAttempts },
                set: { value in
                    var next = editedConfig ?? config
                    next.authSettings.notifyAdminsOnLoginAttempts = value
                    editedConfig = next
                }
            ))
            ConfigToggle(label: "Alert on Successful Logins", isOn: Binding(
                get: { editedConfig?.authSettings.notifyAdminsOnLoginSuccess ?? config.authSettings.notifyAdminsOnLoginSuccess },
                set: { value in
                    var next = editedConfig ?? config
                    next.authSettings.notifyAdminsOnLoginSuccess = value
                    editedConfig = next
                }
            ))
            ConfigToggle(label: "Alert on Failed Logins", isOn: Binding(
                get: { editedConfig?.authSettings.notifyAdminsOnLoginFailure ?? config.authSettings.notifyAdminsOnLoginFailure },
                set: { value in
                    var next = editedConfig ?? config
                    next.authSettings.notifyAdminsOnLoginFailure = value
                    editedConfig = next
                }
            ))
            ConfigToggle(label: "Alert from Generated Login Logs", isOn: Binding(
                get: { editedConfig?.authSettings.notifyAdminsOnGeneratedLoginLogs ?? config.authSettings.notifyAdminsOnGeneratedLoginLogs },
                set: { value in
                    var next = editedConfig ?? config
                    next.authSettings.notifyAdminsOnGeneratedLoginLogs = value
                    editedConfig = next
                }
            ))
            ConfigToggle(label: "Mirror Login Alerts to Main Chat", isOn: Binding(
                get: { editedConfig?.authSettings.mirrorLoginAlertsToMainChat ?? config.authSettings.mirrorLoginAlertsToMainChat },
                set: { value in
                    var next = editedConfig ?? config
                    next.authSettings.mirrorLoginAlertsToMainChat = value
                    editedConfig = next
                }
            ))
            Text("System Assistant can discuss detailed login findings privately with admins. Main chat mirroring sends summary-only alerts when enabled.")
                .font(.caption)
                .foregroundColor(.secondary)

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

struct SSLManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var adminManager = AdminServerManager.shared
    @State private var sslManager = ServerSSLManagerConfig()
    @State private var isLoading = false
    @State private var isSaving = false

    var body: some View {
        NavigationView {
            Form {
                Section("Status") {
                    LabeledContent("Server") {
                        Text(adminManager.selectedManagementTargetName)
                            .foregroundColor(.secondary)
                    }
                    LabeledContent("Status") {
                        Text(sslManager.status.capitalized)
                            .foregroundColor(sslManager.status == "ready" ? .green : .orange)
                    }
                    LabeledContent("Provider") {
                        Text(sslManager.provider.isEmpty ? "Auto" : sslManager.provider.capitalized)
                            .foregroundColor(.secondary)
                    }
                    LabeledContent("Control Panel") {
                        Text(sslManager.controlPanel == "none" ? "Internal / None" : sslManager.controlPanel.capitalized)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Behavior") {
                    Toggle("Enable SSL Manager", isOn: $sslManager.enabled)
                    Toggle("Auto Renew", isOn: $sslManager.autoRenew)
                    Toggle("Sync With Reverse Proxy", isOn: $sslManager.syncToReverseProxy)
                    Picker("Mode", selection: $sslManager.mode) {
                        Text("Auto").tag("auto")
                        Text("Control Panel").tag("control-panel")
                        Text("Internal").tag("internal")
                        Text("Manual").tag("manual")
                    }
                    Picker("Provider", selection: $sslManager.provider) {
                        Text("Auto").tag("auto")
                        ForEach(sslManager.supportedManagers.isEmpty ? ["cpanel", "plesk", "virtualmin", "certbot", "internal", "manual"] : sslManager.supportedManagers, id: \.self) { option in
                            Text(option.capitalized).tag(option)
                        }
                    }
                }

                Section("Certificates") {
                    TextField("Domains (comma separated)", text: Binding(
                        get: { sslManager.domains.joined(separator: ", ") },
                        set: { sslManager.domains = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    TextField("Certificate Path", text: binding(\.certificatePath))
                        .textFieldStyle(.roundedBorder)
                    TextField("Private Key Path", text: binding(\.privateKeyPath))
                        .textFieldStyle(.roundedBorder)
                    TextField("Chain Path", text: binding(\.chainPath))
                        .textFieldStyle(.roundedBorder)
                    TextField("ACME Web Root", text: binding(\.acmeWebRoot))
                        .textFieldStyle(.roundedBorder)
                    TextField("ACME Email", text: binding(\.acmeEmail))
                        .textFieldStyle(.roundedBorder)
                }

                Section("Commands") {
                    TextField("Renew Command", text: binding(\.renewCommand))
                        .textFieldStyle(.roundedBorder)
                    TextField("Reload Command", text: binding(\.reloadCommand))
                        .textFieldStyle(.roundedBorder)
                    TextField("Notes", text: binding(\.notes))
                        .textFieldStyle(.roundedBorder)
                }

                Section("Detected Tools") {
                    if sslManager.availableTools.isEmpty {
                        Text("No SSL tools were detected yet.")
                            .foregroundColor(.secondary)
                    } else {
                        Text(sslManager.availableTools.joined(separator: ", "))
                            .foregroundColor(.secondary)
                    }
                }

                Section("Actions") {
                    Button(isSaving ? "Detecting…" : "Auto-Detect and Apply") {
                        Task {
                            isSaving = true
                            if await adminManager.autodetectSSLManager(),
                               let refreshed = await adminManager.fetchSSLManagerStatus() {
                                sslManager = refreshed
                            }
                            isSaving = false
                        }
                    }
                    .disabled(isSaving)

                    Button(isSaving ? "Saving…" : "Save SSL Settings") {
                        Task {
                            isSaving = true
                            _ = await adminManager.updateSSLManager(sslManager)
                            if let refreshed = await adminManager.fetchSSLManagerStatus() {
                                sslManager = refreshed
                            }
                            isSaving = false
                        }
                    }
                    .disabled(isSaving)

                    Button("Run Renew") {
                        Task {
                            isSaving = true
                            _ = await adminManager.renewSSLManagerCertificates()
                            if let refreshed = await adminManager.fetchSSLManagerStatus() {
                                sslManager = refreshed
                            }
                            isSaving = false
                        }
                    }
                    .disabled(isSaving)

                    Button("Reload Web Services") {
                        Task {
                            isSaving = true
                            _ = await adminManager.reloadSSLManagerServices()
                            if let refreshed = await adminManager.fetchSSLManagerStatus() {
                                sslManager = refreshed
                            }
                            isSaving = false
                        }
                    }
                    .disabled(isSaving)
                }

                if let message = adminManager.moduleActionMessage, !message.isEmpty {
                    Section("Last Result") {
                        Text(message)
                            .foregroundColor(.green)
                    }
                }
            }
            .navigationTitle("SSL Manager")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .automatic) {
                    Button("Refresh") {
                        Task {
                            isLoading = true
                            if let refreshed = await adminManager.fetchSSLManagerStatus() {
                                sslManager = refreshed
                            }
                            isLoading = false
                        }
                    }
                    .disabled(isLoading || isSaving)
                }
            }
            .task {
                isLoading = true
                if let refreshed = await adminManager.fetchSSLManagerStatus() {
                    sslManager = refreshed
                } else if let existing = adminManager.serverConfig?.sslManager {
                    sslManager = existing
                }
                isLoading = false
            }
        }
        .frame(minWidth: 760, minHeight: 680)
    }

    private func binding(_ keyPath: WritableKeyPath<ServerSSLManagerConfig, String?>) -> Binding<String> {
        Binding(
            get: { sslManager[keyPath: keyPath] ?? "" },
            set: { sslManager[keyPath: keyPath] = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        )
    }
}

struct BackupManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var adminManager = AdminServerManager.shared
    @State private var backups: [ServerConfigBackup] = []
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var backupLabel = ""
    @State private var includeFederationSnapshot = true
    @State private var includeLinkedServers = true
    @State private var selectedBackupID: String?
    @State private var restoreConfirmationShown = false

    var body: some View {
        NavigationView {
            Group {
                if isLoading && backups.isEmpty {
                    ProgressView("Loading backups…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Form {
                        Section("Current Target") {
                            HStack(alignment: .top) {
                                Text("Server")
                                    .fontWeight(.semibold)
                                Spacer()
                                Text(adminManager.selectedManagementTargetName)
                                    .multilineTextAlignment(.trailing)
                                    .foregroundColor(.secondary)
                            }
                            HStack(alignment: .top) {
                                Text("URL")
                                    .fontWeight(.semibold)
                                Spacer()
                                Text(adminManager.resolvedServerURL)
                                    .multilineTextAlignment(.trailing)
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                            }
                        }

                        Section("Create Backup") {
                            TextField("Optional label", text: $backupLabel)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Backup label")
                            Toggle("Include federation snapshot", isOn: $includeFederationSnapshot)
                            Toggle("Include linked server list", isOn: $includeLinkedServers)

                            Button(isSaving ? "Creating Backup…" : "Create Backup") {
                                Task {
                                    isSaving = true
                                    let success = await adminManager.createConfigBackup(
                                        label: backupLabel.isEmpty ? nil : backupLabel,
                                        includeFederationSnapshot: includeFederationSnapshot,
                                        includeLinkedServers: includeLinkedServers
                                    )
                                    if success {
                                        backupLabel = ""
                                        backups = await adminManager.fetchConfigBackups()
                                    }
                                    isSaving = false
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isSaving)
                        }

                        Section("Available Backups") {
                            if backups.isEmpty {
                                Text("No backups found on this server.")
                                    .foregroundColor(.secondary)
                            } else {
                                ForEach(backups) { backup in
                                    Button {
                                        selectedBackupID = backup.id
                                    } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(backup.label?.isEmpty == false ? backup.label! : backup.filename)
                                                        .font(.headline)
                                                    Text(backup.filename)
                                                        .font(.caption.monospaced())
                                                        .foregroundColor(.secondary)
                                                }
                                                Spacer()
                                                if selectedBackupID == backup.id {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .foregroundColor(.accentColor)
                                                        .accessibilityHidden(true)
                                                }
                                            }

                                            HStack(spacing: 12) {
                                                if let createdAt = backup.createdAt {
                                                    Text(createdAt)
                                                }
                                                if let size = backup.size {
                                                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                                }
                                            }
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityAddTraits(selectedBackupID == backup.id ? [.isSelected] : [])
                                }
                            }
                        }

                        Section("Restore") {
                            Text("Restore will replace the current server configuration after creating a pre-restore backup.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Button("Restore Selected Backup", role: .destructive) {
                                restoreConfirmationShown = true
                            }
                            .disabled(selectedBackup == nil || isSaving)
                        }

                        if let message = adminManager.moduleActionMessage, !message.isEmpty {
                            Section("Status") {
                                Text(message)
                                    .foregroundColor(.green)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Backup Manager")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .automatic) {
                    Button("Refresh") {
                        Task {
                            isLoading = true
                            backups = await adminManager.fetchConfigBackups()
                            isLoading = false
                        }
                    }
                    .disabled(isLoading || isSaving)
                }
            }
            .task {
                isLoading = true
                backups = await adminManager.fetchConfigBackups()
                isLoading = false
            }
            .alert("Restore Backup", isPresented: $restoreConfirmationShown, presenting: selectedBackup) { backup in
                Button("Cancel", role: .cancel) {}
                Button("Restore", role: .destructive) {
                    Task {
                        isSaving = true
                        _ = await adminManager.restoreConfigBackup(filename: backup.filename)
                        backups = await adminManager.fetchConfigBackups()
                        isSaving = false
                    }
                }
            } message: { backup in
                Text("Restore \(backup.label?.isEmpty == false ? backup.label! : backup.filename) on \(adminManager.selectedManagementTargetName)?")
            }
        }
        .frame(minWidth: 760, minHeight: 640)
    }

    private var selectedBackup: ServerConfigBackup? {
        backups.first(where: { $0.id == selectedBackupID })
    }
}

struct VoiceLinkFlexPBXHoldMediaManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var adminManager = AdminServerManager.shared
    @State private var holdMedia: VoiceLinkFlexPBXHoldMediaStatus?
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var syncResult: VoiceLinkFlexPBXHoldMediaSyncResult?

    var body: some View {
        NavigationView {
            Group {
                if isLoading && holdMedia == nil {
                    ProgressView("Loading hold media manager…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let holdMedia {
                    Form {
                        Section("Mode") {
                            Toggle("Enable VoiceLink hold media", isOn: binding(\.enabled))
                            Toggle("VoiceLink is optional, not required", isOn: binding(\.optionalSource))
                            Toggle("Reload MOH after sync", isOn: binding(\.autoReload))
                        }

                        Section("Allowed Sources") {
                            ForEach(["server-stream", "room-background", "room-stream", "room-mix", "individual-room"], id: \.self) { sourceType in
                                Toggle(sourceType.replacingOccurrences(of: "-", with: " ").capitalized, isOn: allowedSourceBinding(sourceType))
                            }
                        }

                        Section("PBX Targets") {
                            ForEach(holdMedia.pbxTargets.indices, id: \.self) { index in
                                VStack(alignment: .leading, spacing: 6) {
                                    Toggle(holdMedia.pbxTargets[index].name, isOn: Binding(
                                        get: { holdMedia.pbxTargets[index].enabled },
                                        set: { updateTargetEnabled(at: index, enabled: $0) }
                                    ))
                                    Text(holdMedia.pbxTargets[index].apiUrl)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Section("Global Assignment") {
                            Toggle("Use a global hold source", isOn: binding(\.globalAssignment.enabled))
                            Picker("Source", selection: binding(\.globalAssignment.sourceId)) {
                                ForEach(holdMedia.sources.filter(\.supported)) { source in
                                    Text(source.name).tag(source.id)
                                }
                            }
                            TextField("MOH Class", text: binding(\.globalAssignment.mohClass))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Global MOH class")
                        }

                        Section("Per-Room Assignments") {
                            ForEach(roomSources(from: holdMedia), id: \.id) { source in
                                VStack(alignment: .leading, spacing: 6) {
                                    let assignment = roomAssignment(for: source, in: holdMedia)
                                    Toggle(source.name, isOn: Binding(
                                        get: { assignment.enabled },
                                        set: { updateRoomAssignment(for: source, enabled: $0) }
                                    ))
                                    HStack {
                                        Text("MOH Class")
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Text(assignment.mohClass)
                                            .font(.caption.monospaced())
                                    }
                                    .accessibilityElement(children: .combine)
                                    Text(source.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        if let syncResult {
                            Section("Last Sync") {
                                Text(syncResult.success ? "Sync completed." : "Sync completed with issues.")
                                ForEach(syncResult.targets) { target in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(target.targetName)
                                        if let error = target.error, !error.isEmpty {
                                            Text(error)
                                                .font(.caption)
                                                .foregroundColor(.red)
                                        } else {
                                            Text("\(target.classes.count) class\(target.classes.count == 1 ? "" : "es") updated")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Text("Hold media manager unavailable.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("FlexPBX Hold Media")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("Sync") {
                        Task {
                            guard let current = holdMedia else { return }
                            isSaving = true
                            if await adminManager.saveVoiceLinkFlexPBXHoldMedia(current) {
                                syncResult = await adminManager.syncVoiceLinkFlexPBXHoldMedia()
                            }
                            isSaving = false
                        }
                    }
                    .disabled(isSaving || holdMedia == nil)

                    Button("Save") {
                        Task {
                            guard let current = holdMedia else { return }
                            isSaving = true
                            _ = await adminManager.saveVoiceLinkFlexPBXHoldMedia(current)
                            isSaving = false
                        }
                    }
                    .disabled(isSaving || holdMedia == nil)
                }
            }
            .task {
                isLoading = true
                holdMedia = await adminManager.fetchVoiceLinkFlexPBXHoldMediaStatus()
                isLoading = false
            }
        }
        .frame(minWidth: 760, minHeight: 640)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<VoiceLinkFlexPBXHoldMediaStatus, T>) -> Binding<T> {
        Binding(
            get: { holdMedia?[keyPath: keyPath] ?? (VoiceLinkFlexPBXHoldMediaStatus(enabled: false, optionalSource: true, autoReload: true, allowedSourceTypes: [], globalAssignment: .init(enabled: false, sourceType: "server-stream", sourceId: "", mohClass: "", targetIds: []), roomAssignments: [:], pbxTargets: [], sources: [], roomCount: 0))[keyPath: keyPath] },
            set: { holdMedia?[keyPath: keyPath] = $0 }
        )
    }

    private func roomSources(from status: VoiceLinkFlexPBXHoldMediaStatus) -> [VoiceLinkFlexPBXHoldMediaSource] {
        status.sources.filter { ($0.roomId?.isEmpty == false) && $0.supported }
    }

    private func roomAssignment(for source: VoiceLinkFlexPBXHoldMediaSource, in status: VoiceLinkFlexPBXHoldMediaStatus) -> VoiceLinkFlexPBXHoldMediaAssignment {
        let roomId = source.roomId ?? ""
        return status.roomAssignments[roomId] ?? VoiceLinkFlexPBXHoldMediaAssignment(
            enabled: false,
            sourceType: source.sourceType,
            sourceId: source.id,
            mohClass: "voicelink-room-\(roomId)",
            targetIds: status.pbxTargets.filter(\.enabled).map(\.id)
        )
    }

    private func updateRoomAssignment(for source: VoiceLinkFlexPBXHoldMediaSource, enabled: Bool) {
        guard let roomId = source.roomId, var current = holdMedia else { return }
        var assignment = roomAssignment(for: source, in: current)
        assignment.enabled = enabled
        assignment.sourceType = source.sourceType
        assignment.sourceId = source.id
        current.roomAssignments[roomId] = assignment
        holdMedia = current
    }

    private func allowedSourceBinding(_ sourceType: String) -> Binding<Bool> {
        Binding(
            get: { holdMedia?.allowedSourceTypes.contains(sourceType) ?? false },
            set: { enabled in
                guard var current = holdMedia else { return }
                if enabled {
                    if current.allowedSourceTypes.contains(sourceType) == false {
                        current.allowedSourceTypes.append(sourceType)
                    }
                } else {
                    current.allowedSourceTypes.removeAll { $0 == sourceType }
                }
                holdMedia = current
            }
        )
    }

    private func updateTargetEnabled(at index: Int, enabled: Bool) {
        guard var current = holdMedia, current.pbxTargets.indices.contains(index) else { return }
        current.pbxTargets[index].enabled = enabled
        holdMedia = current
    }
}

struct ModuleConfigEditorSheet: View {
    enum FieldKind {
        case bool
        case string
        case number
        case stringList
        case json
    }

    struct ConfigField: Identifiable {
        let id: String
        let path: [String]
        let label: String
        let detailLabel: String
        let helperText: String?
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
                            ForEach(groupedFields, id: \.group) { group in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(group.title)
                                        .font(.headline)
                                        .foregroundColor(.white)
                                        .accessibilityAddTraits(.isHeader)

                                    ForEach(group.items, id: \.id) { field in
                                        if let index = fields.firstIndex(where: { $0.id == field.id }) {
                                            fieldEditor(for: index)
                                        }
                                    }
                                }
                                .padding(12)
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(10)
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

            let label = humanizedPathLabel(currentPath)
            let detailLabel = currentPath.joined(separator: " > ")
            let helperText = helperText(for: currentPath)
            if let boolValue = value as? Bool {
                output.append(ConfigField(
                    id: currentPath.joined(separator: "."),
                    path: currentPath,
                    label: label,
                    detailLabel: detailLabel,
                    helperText: helperText,
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
                    detailLabel: detailLabel,
                    helperText: helperText,
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
                    detailLabel: detailLabel,
                    helperText: helperText,
                    kind: .string,
                    textValue: stringValue,
                    boolValue: false
                ))
                continue
            }

            if let stringList = value as? [String] {
                output.append(ConfigField(
                    id: currentPath.joined(separator: "."),
                    path: currentPath,
                    label: label,
                    detailLabel: detailLabel,
                    helperText: helperText ?? "Enter one item per line.",
                    kind: .stringList,
                    textValue: stringList.joined(separator: "\n"),
                    boolValue: false
                ))
                continue
            }

            let fallback = stringifyJSONObject(value) ?? "\(value)"
            output.append(ConfigField(
                id: currentPath.joined(separator: "."),
                path: currentPath,
                label: label,
                detailLabel: detailLabel,
                helperText: helperText,
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
            case .stringList:
                value = field.textValue
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
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

    private var groupedFields: [(group: String, title: String, items: [ConfigField])] {
        let grouped = Dictionary(grouping: fields) { field in
            field.path.first ?? "general"
        }

        return grouped.keys.sorted().map { key in
            (
                group: key,
                title: humanizeKey(key),
                items: grouped[key, default: []].sorted { lhs, rhs in
                    lhs.detailLabel.localizedCaseInsensitiveCompare(rhs.detailLabel) == .orderedAscending
                }
            )
        }
    }

    @ViewBuilder
    private func fieldEditor(for index: Int) -> some View {
        let field = fields[index]

        VStack(alignment: .leading, spacing: 4) {
            switch field.kind {
            case .bool:
                Toggle(field.label, isOn: Binding(
                    get: { fields[index].boolValue },
                    set: { fields[index].boolValue = $0 }
                ))
                .tint(.blue)
            case .string:
                labeledTextField(title: field.label, value: Binding(
                    get: { fields[index].textValue },
                    set: { fields[index].textValue = $0 }
                ))
            case .number:
                labeledTextField(title: field.label, value: Binding(
                    get: { fields[index].textValue },
                    set: { fields[index].textValue = $0 }
                ), placeholder: "Number")
            case .stringList:
                Text(field.label)
                    .foregroundColor(.white)
                    .font(.subheadline.weight(.semibold))
                TextEditor(text: Binding(
                    get: { fields[index].textValue },
                    set: { fields[index].textValue = $0 }
                ))
                .font(.system(.body, design: .default))
                .frame(minHeight: 96)
                .padding(6)
                .background(Color.white.opacity(0.08))
                .cornerRadius(8)
            case .json:
                Text(field.label)
                    .foregroundColor(.white)
                    .font(.subheadline.weight(.semibold))
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

            if field.kind != .bool {
                Text(field.detailLabel)
                    .foregroundColor(.gray)
                    .font(.caption2)
            }

            if let helperText = field.helperText, !helperText.isEmpty {
                Text(helperText)
                    .foregroundColor(.gray)
                    .font(.caption)
            }
        }
    }

    private func labeledTextField(title: String, value: Binding<String>, placeholder: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .foregroundColor(.white)
                .font(.subheadline.weight(.semibold))
            TextField(placeholder ?? title, text: value)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func humanizedPathLabel(_ path: [String]) -> String {
        if path.count <= 1 {
            return humanizeKey(path.first ?? "setting")
        }
        return humanizeKey(path.last ?? path.joined(separator: " "))
    }

    private func humanizeKey(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { chunk in
                let lower = chunk.lowercased()
                switch lower {
                case "id", "url", "api", "sms", "totp", "smtp", "whmcs":
                    return lower.uppercased()
                default:
                    return lower.prefix(1).uppercased() + lower.dropFirst()
                }
            }
            .joined(separator: " ")
    }

    private func helperText(for path: [String]) -> String? {
        let key = path.joined(separator: ".").lowercased()
        let last = path.last?.lowercased() ?? ""

        switch key {
        case let value where value.contains("enabled"):
            return "Turn this on to make the feature active without removing its saved settings."
        case let value where value.contains("intervalseconds"):
            return "How often this task should run, in seconds."
        case let value where value.contains("retentiondays"):
            return "How many days of data to keep before cleanup."
        case let value where value.contains("maxqueuesize"):
            return "Maximum number of waiting items allowed before the queue is considered full."
        case let value where value.contains("minutesbefore"):
            return "Enter one reminder lead time per line, in minutes."
        case let value where value.contains("webhooks"):
            return "Enter one webhook URL per line."
        default:
            switch last {
            case "issuer":
                return "Name shown by authenticator apps when users enroll."
            case "provider":
                return "Backend service used for this integration."
            case "categories":
                return "Enter one category per line."
            case "priorities":
                return "Enter one priority per line."
            default:
                return nil
            }
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
    static func resolve(_ doc: AdminDocLink, isAdmin: Bool) -> URL? {
        if let localRelativePath = doc.localRelativePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !localRelativePath.isEmpty,
           let localURL = DocsManager.shared.resolveLocalDoc(relativePath: localRelativePath) {
            return localURL
        }

        let selectedPath = (isAdmin ? doc.adminWebPath : nil) ?? doc.webPath
        return DocsManager.shared.webURL(for: selectedPath)
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
    var defaultValueDescription: String? = nil
    @Binding var text: String

    private var resolvedPlaceholder: String {
        let trimmed = placeholder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return "Enter \(label.lowercased())"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.gray)
            TextField(resolvedPlaceholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
                .accessibilityHint(resolvedAccessibilityHint)
            if let helpText, !helpText.isEmpty {
                Text(helpText)
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
            if let defaultValueDescription, !defaultValueDescription.isEmpty {
                Text("Default: \(defaultValueDescription)")
                    .font(.caption2)
                    .foregroundColor(.gray.opacity(0.9))
            }
        }
    }

    private var resolvedAccessibilityHint: String {
        let base = helpText ?? "Enter the value for \(label.lowercased())."
        if let defaultValueDescription, !defaultValueDescription.isEmpty {
            return "\(base) Default: \(defaultValueDescription)."
        }
        return base
    }
}

struct ConfigSecureField: View {
    let label: String
    var placeholder: String = ""
    var helpText: String? = nil
    var defaultValueDescription: String? = nil
    @Binding var text: String

    private var resolvedPlaceholder: String {
        let trimmed = placeholder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return "Enter \(label.lowercased())"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.gray)
            SecureField(resolvedPlaceholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
                .accessibilityHint(resolvedAccessibilityHint)
            if let helpText, !helpText.isEmpty {
                Text(helpText)
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
            if let defaultValueDescription, !defaultValueDescription.isEmpty {
                Text("Default: \(defaultValueDescription)")
                    .font(.caption2)
                    .foregroundColor(.gray.opacity(0.9))
            }
        }
    }

    private var resolvedAccessibilityHint: String {
        let base = helpText ?? "Enter the secure value for \(label.lowercased())."
        if let defaultValueDescription, !defaultValueDescription.isEmpty {
            return "\(base) Default: \(defaultValueDescription)."
        }
        return base
    }
}

struct ConfigNumberField: View {
    let label: String
    var helpText: String? = nil
    var defaultValueDescription: String? = nil
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.gray)
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                .accessibilityLabel(label)
                .accessibilityHint(resolvedAccessibilityHint)
            if let helpText, !helpText.isEmpty {
                Text(helpText)
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let defaultValueDescription, !defaultValueDescription.isEmpty {
                Text("Default: \(defaultValueDescription)")
                    .font(.caption2)
                    .foregroundColor(.gray.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var resolvedAccessibilityHint: String {
        let base = helpText ?? "Enter the number for \(label.lowercased())."
        if let defaultValueDescription, !defaultValueDescription.isEmpty {
            return "\(base) Default: \(defaultValueDescription)."
        }
        return base
    }
}

struct ConfigToggle: View {
    let label: String
    var helpText: String? = nil
    var defaultValueDescription: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(label, isOn: $isOn)
                .foregroundColor(.white)
                .accessibilityHint(resolvedAccessibilityHint)
            if let helpText, !helpText.isEmpty {
                Text(helpText)
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let defaultValueDescription, !defaultValueDescription.isEmpty {
                Text("Default: \(defaultValueDescription)")
                    .font(.caption2)
                    .foregroundColor(.gray.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var resolvedAccessibilityHint: String {
        let base = helpText ?? "Toggles \(label.lowercased())."
        if let defaultValueDescription, !defaultValueDescription.isEmpty {
            return "\(base) Default: \(defaultValueDescription)."
        }
        return base
    }
}

// MARK: - ServerConfig Extensions
extension ServerConfig {
    func with(serverName: String? = nil, serverDescription: String? = nil, maxUsers: Int? = nil,
              maxRooms: Int? = nil, maxUsersPerRoom: Int? = nil, lobbyWelcomeMessage: String?? = nil, welcomeMessage: String?? = nil,
              motd: String?? = nil, motdSettings: MOTDSettings? = nil,
              registrationEnabled: Bool? = nil, requireAuth: Bool? = nil,
              allowGuests: Bool? = nil, maxGuestDuration: Int?? = nil, enableRateLimiting: Bool? = nil,
              serverVisibility: ServerVisibilityConfig? = nil,
              serverDiscoveryReveal: ServerDiscoveryRevealConfig? = nil,
              handoffPromptMode: String? = nil,
              messageSettings: MessageSettings? = nil,
              authSettings: ServerAuthSettingsConfig? = nil,
              pushover: PushoverConfig?? = nil,
              sslManager: ServerSSLManagerConfig?? = nil) -> ServerConfig {
        ServerConfig(
            serverName: serverName ?? self.serverName,
            serverDescription: serverDescription ?? self.serverDescription,
            maxUsers: maxUsers ?? self.maxUsers,
            maxRooms: maxRooms ?? self.maxRooms,
            maxUsersPerRoom: maxUsersPerRoom ?? self.maxUsersPerRoom,
            lobbyWelcomeMessage: lobbyWelcomeMessage ?? self.lobbyWelcomeMessage,
            welcomeMessage: welcomeMessage ?? self.welcomeMessage,
            motd: motd ?? self.motd,
            motdSettings: motdSettings ?? self.motdSettings,
            registrationEnabled: registrationEnabled ?? self.registrationEnabled,
            requireAuth: requireAuth ?? self.requireAuth,
            allowGuests: allowGuests ?? self.allowGuests,
            maxGuestDuration: maxGuestDuration ?? self.maxGuestDuration,
            enableRateLimiting: enableRateLimiting ?? self.enableRateLimiting,
            serverVisibility: serverVisibility ?? self.serverVisibility,
            serverDiscoveryReveal: serverDiscoveryReveal ?? self.serverDiscoveryReveal,
            handoffPromptMode: handoffPromptMode ?? self.handoffPromptMode,
            messageSettings: messageSettings ?? self.messageSettings,
            authSettings: authSettings ?? self.authSettings,
            backgroundStreams: self.backgroundStreams,
            pushover: pushover ?? self.pushover,
            recordingEnabled: self.recordingEnabled,
            fileSharing: self.fileSharing,
            sslManager: sslManager ?? self.sslManager
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
