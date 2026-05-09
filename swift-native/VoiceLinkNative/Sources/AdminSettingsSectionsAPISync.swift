import SwiftUI

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
        case bots = "Bots"
        case discovery = "Discovery"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            helpSection

            if let initialConfig = settings {
                editorContent(initialConfig: initialConfig)
            } else {
                unavailableContent
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

    private var helpSection: some View {
        AdminHelpSection(
            title: "Quick Help",
            summary: "API Sync controls whether this install follows the main VoiceLink API, runs standalone, or participates in a hybrid/federated sync model with external systems such as WHMCS.",
            steps: [
                "Enable API Sync only if this server should exchange config, entitlements, or ownership data with another VoiceLink authority or portal.",
                "Choose the mode that matches the install: standalone for isolated servers, hybrid for managed installs, or federated when multiple peers are trusted.",
                "Use WHMCS fields only when this install should honor hosted account, licensing, or ownership data from your portal.",
                "Use the Bots tab to enable cross-agent delegation, moderation watches for guests or spam, and server-side defaults shared with related backend integrations."
            ],
            docs: [
                AdminDocLink(title: "API Integration Docs", localRelativePath: "authenticated/admin-panel.html", webPath: "/docs/authentication.html", adminWebPath: "/docs/authenticated/admin-panel.html"),
                AdminDocLink(title: "Distribution Docs", localRelativePath: "getting-started.html", webPath: "/docs/getting-started.html", adminWebPath: "/docs/authenticated/index.html")
            ]
        )
    }

    private var unavailableContent: some View {
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

    @ViewBuilder
    private func editorContent(initialConfig: APISyncSettings) -> some View {
        var config = initialConfig

        subtabToolbar

        switch selectedSubtab {
        case .connection:
            connectionContent(config: config)
        case .routing:
            routingContent(config: config)
        case .whmcs:
            whmcsContent(config: config)
        case .bots:
            botsContent(config: config)
        case .discovery:
            discoveryContent(config: config)
        }

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
    }

    @ViewBuilder
    private func connectionContent(config: APISyncSettings) -> some View {
        SectionHeader(title: "VoiceLink API Sync")

        ConfigToggle(
            label: "Enable API Sync",
            helpText: "Turn this on when the server should stay linked to a main VoiceLink authority, hosted portal, or managed federation setup.",
            isOn: boolBinding(getter: { $0.enabled }) { config, newValue in
                config.enabled = newValue
            }
        )

        Picker("Sync Mode", selection: stringBinding(getter: { $0.mode }) { config, newValue in
            config.mode = newValue
        }) {
            ForEach(syncModes, id: \.self) { mode in
                Text(mode.capitalized).tag(mode)
            }
        }
        .pickerStyle(.segmented)

        Text("`Standalone` keeps the server self-contained. `Hybrid` keeps it linked to the main VoiceLink API. `Hub` is for central-control installs. `Federated` is for trusted peer clusters. Linked server clusters can scale from one primary server to large multi-server deployments with secondary and fallback peers.")
            .font(.caption)
            .foregroundColor(.gray)

        HStack {
            Button {
                applyRecommendedDefaults()
            } label: {
                Label("Auto-Detect and Apply Recommended Defaults", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)

            Text("Uses detected linked servers and safe fallback behavior so new admins do not have to guess the right mode, sync interval, initial routing profile, primary cluster handoff behavior, or which server should be treated as the master.")
                .font(.caption)
                .foregroundColor(.gray)
        }

        SectionHeader(title: "Sync Behavior")

        ConfigNumberField(
            label: "Sync Interval (seconds)",
            helpText: "How often this server should refresh linked API state in the background.",
            value: intBinding(getter: { $0.syncInterval }) { config, newValue in
                config.syncInterval = newValue
            }
        )

        ConfigToggle(label: "Auto-sync on Changes", helpText: "Immediately push changes when config, room ownership, or linked license state changes.", isOn: boolBinding(getter: { $0.autoSyncOnChange }) { config, newValue in
            config.autoSyncOnChange = newValue
        })

        ConfigToggle(label: "Allow client choice on handoff", helpText: "Let connected clients choose whether to accept an offered handoff when policy allows.", isOn: boolBinding(getter: { $0.allowClientChoice }) { config, newValue in
            config.allowClientChoice = newValue
        })

        ConfigToggle(label: "Auto-return after recovery", helpText: "Return users to the preferred primary server when it recovers and the routing policy allows it.", isOn: boolBinding(getter: { $0.autoReturnRecoveredUsers }) { config, newValue in
            config.autoReturnRecoveredUsers = newValue
        })

        ConfigNumberField(
            label: "Snapshot Interval (seconds)",
            helpText: "How often join/leave and transfer snapshots should be refreshed for failover and return actions.",
            value: intBinding(getter: { $0.snapshotIntervalSeconds }) { config, newValue in
                config.snapshotIntervalSeconds = newValue
            }
        )
    }

    @ViewBuilder
    private func routingContent(config: APISyncSettings) -> some View {
        SectionHeader(title: "Routing Profiles")

        Text("Profiles define ordered handoff and fallback actions. `Start` connects to the target, `Handoff` moves active users during maintenance, `Return` brings them back after recovery, and `Fallback` uses the target only when the preferred primary server is unavailable. You can keep more than one entry for the same server when the target path or action chain is different.")
            .font(.caption)
            .foregroundColor(.gray)

        ForEach(Array(config.routingProfiles.enumerated()), id: \.element.id) { index, profile in
            routingProfileCard(index: index, profile: profile)
        }

        Button {
            updateConfig { config in
                config.routingProfiles.append(APISyncRoutingProfile())
            }
        } label: {
            Label("Add Routing Profile", systemImage: "plus")
        }
        .buttonStyle(.bordered)
    }

    private func routingProfileCard(index: Int, profile: APISyncRoutingProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Profile \(index + 1)")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Button(role: .destructive) {
                    updateConfig { config in
                        config.routingProfiles.removeAll { $0.id == profile.id }
                    }
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }

            ConfigTextField(
                label: "Label",
                placeholder: "Main to VPS fallback",
                helpText: "Friendly name for this routing profile.",
                text: routingProfileStringBinding(index: index, getter: { $0.label }) { profile, newValue in
                    profile.label = newValue
                }
            )

            ConfigTextField(
                label: "Target Server",
                placeholder: "https://community.voicelinkapp.app",
                helpText: "Domain, public IP, private IP, or known endpoint for this target.",
                text: routingProfileStringBinding(index: index, getter: { $0.targetServer }) { profile, newValue in
                    profile.targetServer = newValue
                }
            )

            ConfigTextField(
                label: "Install Path / Manual Address",
                placeholder: "/home/devinecr/apps/voicelink-local or 10.0.0.5",
                helpText: "Optional path or direct address used for same-host or manual routing.",
                text: routingProfileStringBinding(index: index, getter: { $0.installPath ?? $0.manualAddress ?? "" }) { profile, newValue in
                    profile.installPath = newValue.isEmpty ? nil : newValue
                    profile.manualAddress = newValue.isEmpty ? nil : newValue
                }
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Ordered Actions")
                    .font(.caption)
                    .foregroundColor(.gray)
                ForEach(0..<4, id: \.self) { slot in
                    Picker("Action \(slot + 1)", selection: routingActionBinding(index: index, slot: slot)) {
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

    @ViewBuilder
    private func whmcsContent(config: APISyncSettings) -> some View {
        SectionHeader(title: "WHMCS Integration")

        ConfigToggle(label: "Enable WHMCS", helpText: "Use the hosted client portal as an entitlement and ownership source for this server install.", isOn: boolBinding(getter: { $0.whmcsEnabled }) { config, newValue in
            config.whmcsEnabled = newValue
        })

        if config.whmcsEnabled {
            ConfigTextField(
                label: "WHMCS URL",
                placeholder: "https://devine-creations.com",
                helpText: "Enter the base client portal URL this server should use for WHMCS-backed account and licensing checks.",
                text: stringBinding(getter: { $0.whmcsUrl ?? "" }) { config, newValue in
                    config.whmcsUrl = newValue.isEmpty ? nil : newValue
                }
            )

            ConfigTextField(
                label: "API Identifier",
                placeholder: "WHMCS API identifier",
                helpText: "Use the WHMCS API identifier for the portal account that should authorize server-side license and ownership checks.",
                text: stringBinding(getter: { $0.whmcsApiIdentifier ?? "" }) { config, newValue in
                    config.whmcsApiIdentifier = newValue.isEmpty ? nil : newValue
                }
            )

            ConfigSecureField(
                label: "API Secret",
                placeholder: "WHMCS API secret",
                helpText: "Paste the matching WHMCS API secret. It stays masked in the client UI.",
                text: stringBinding(getter: { $0.whmcsApiSecret ?? "" }) { config, newValue in
                    config.whmcsApiSecret = newValue.isEmpty ? nil : newValue
                }
            )

            ConfigTextField(
                label: "Client Portal URL",
                placeholder: "https://devine-creations.com/clientarea.php",
                helpText: "Choose the billing or client portal page the desktop app should open for WHMCS-linked accounts.",
                text: stringBinding(getter: { $0.whmcsPortalUrl ?? "" }) { config, newValue in
                    config.whmcsPortalUrl = newValue.isEmpty ? nil : newValue
                }
            )

            ConfigTextField(
                label: "Admin Portal URL",
                placeholder: "https://devine-creations.com/admin/",
                helpText: "Set the WHMCS admin endpoint your support or ownership users should open from the desktop app.",
                text: stringBinding(getter: { $0.whmcsAdminUrl ?? "" }) { config, newValue in
                    config.whmcsAdminUrl = newValue.isEmpty ? nil : newValue
                }
            )

            ConfigToggle(label: "Allow Client Portal Launch", helpText: "Permit connected VoiceLink desktop clients to open the configured WHMCS client portal from this server.", isOn: boolBinding(getter: { $0.whmcsAllowClientPortalLaunch }) { config, newValue in
                config.whmcsAllowClientPortalLaunch = newValue
            })

            ConfigToggle(label: "Allow Admin Portal Launch", helpText: "Permit admin-capable desktop clients to open the configured WHMCS admin URL from this server.", isOn: boolBinding(getter: { $0.whmcsAllowAdminPortalLaunch }) { config, newValue in
                config.whmcsAllowAdminPortalLaunch = newValue
            })

            VStack(alignment: .leading, spacing: 6) {
                Text("Planned Server Ownership Billing")
                    .font(.headline)
                    .foregroundColor(.white)
                Text("VoiceLink governance reserves one primary owner and up to two co-owners per server. The primary owner delegates and revokes co-owners, and WHMCS billing will apply prorated ownership changes on the next invoice once that workflow is implemented.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.white.opacity(0.04))
            .cornerRadius(10)

            ConfigTextField(
                label: "Endpoint Access Mode",
                placeholder: "managed",
                helpText: "Use `managed` to keep installed servers linked to VoiceLink APIs while your management side decides which endpoints stay available.",
                text: stringBinding(getter: { $0.whmcsEndpointAccessMode }) { config, newValue in
                    config.whmcsEndpointAccessMode = newValue.isEmpty ? "managed" : newValue
                }
            )

            ConfigTextField(
                label: "Managed Endpoint Policy",
                placeholder: "server-linked",
                helpText: "Describe the policy your server applies when connected installs must remain linked to VoiceLink APIs and service endpoints.",
                text: stringBinding(getter: { $0.whmcsManagedEndpointPolicy }) { config, newValue in
                    config.whmcsManagedEndpointPolicy = newValue.isEmpty ? "server-linked" : newValue
                }
            )
        }
    }

    @ViewBuilder
    private func discoveryContent(config: APISyncSettings) -> some View {
        SectionHeader(title: "Detected Targets")

        Text("Detected peers and manual entries can both be used. Duplicate targets are valid if they serve different fallback or return flows, and clusters can keep one primary server with additional secondary, fallback, or overflow peers.")
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
                    updateConfig { config in
                        config.routingProfiles.append(APISyncRoutingProfile(label: "Detected Route", targetServer: target))
                    }
                    selectedSubtab = .routing
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)
        }

        HStack {
            TextField("Manual domain, private IP, or public IP", text: $manualServerEntry)
                .textFieldStyle(.roundedBorder)
            Button("Add") {
                let trimmed = manualServerEntry.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                updateConfig { config in
                    config.routingProfiles.append(APISyncRoutingProfile(label: "Manual Route", targetServer: trimmed, manualAddress: trimmed))
                }
                manualServerEntry = ""
                selectedSubtab = .routing
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func botsContent(config: APISyncSettings) -> some View {
        SectionHeader(title: "Bot Mesh and Moderation")

        ConfigToggle(
            label: "Enable Server Bot Features",
            helpText: "Master toggle for server-managed bot delegation and moderation policies shared across VoiceLink and related tools.",
            isOn: boolBinding(getter: { $0.botsEnabled }) { config, newValue in
                config.botsEnabled = newValue
            }
        )

        ConfigToggle(
            label: "Enable Bot Mesh Delegation",
            helpText: "Allow connected bot runtimes to hand work to each other across machines and networks.",
            isOn: boolBinding(getter: { $0.botMeshEnabled }) { config, newValue in
                config.botMeshEnabled = newValue
            }
        )

        ConfigToggle(
            label: "Enable Bot Moderation Watch",
            helpText: "Allow background bots to receive moderation events for guest activity, spam signals, and file offers.",
            isOn: boolBinding(getter: { $0.botModerationEnabled }) { config, newValue in
                config.botModerationEnabled = newValue
            }
        )

        if config.botModerationEnabled {
            SectionHeader(title: "Moderation Sources")

            ConfigToggle(label: "Watch Guest Logins", helpText: "Emit events when guest-style accounts sign in.", isOn: boolBinding(getter: { $0.botWatchGuestLogins }) { config, newValue in
                config.botWatchGuestLogins = newValue
            })

            ConfigToggle(label: "Watch Room Messages", helpText: "Reserve room-level bot moderation policy for VoiceLink rooms and spam scanning.", isOn: boolBinding(getter: { $0.botWatchRoomMessages }) { config, newValue in
                config.botWatchRoomMessages = newValue
            })

            ConfigToggle(label: "Watch Direct Messages", helpText: "Emit moderation events for direct or support-side message traffic.", isOn: boolBinding(getter: { $0.botWatchDirectMessages }) { config, newValue in
                config.botWatchDirectMessages = newValue
            })

            ConfigToggle(label: "Watch File Offers", helpText: "Emit moderation events when attachments or file relay offers are made.", isOn: boolBinding(getter: { $0.botWatchFileOffers }) { config, newValue in
                config.botWatchFileOffers = newValue
            })

            SectionHeader(title: "Notifications and Relay")

            ConfigToggle(label: "Notify Admin Staff", helpText: "Send moderation output to admin/staff workflows by default.", isOn: boolBinding(getter: { $0.botNotifyAdmins }) { config, newValue in
                config.botNotifyAdmins = newValue
            })

            ConfigToggle(label: "Notify Support Rooms", helpText: "Allow bot moderation summaries to surface in support-focused flows when enabled.", isOn: boolBinding(getter: { $0.botNotifySupportRooms }) { config, newValue in
                config.botNotifySupportRooms = newValue
            })
        }

        ConfigToggle(
            label: "Allow Bot File Relay",
            helpText: "Let bot sessions stage temp files for cross-machine delegation work.",
            isOn: boolBinding(getter: { $0.botAllowFileRelay }) { config, newValue in
                config.botAllowFileRelay = newValue
            }
        )

        ConfigTextField(
            label: "Default Delegate Bot",
            placeholder: "codex-bot",
            helpText: "The bot name to target first when a local agent delegates work by default.",
            text: stringBinding(getter: { $0.botDefaultDelegateBot }) { config, newValue in
                config.botDefaultDelegateBot = newValue.isEmpty ? "codex-bot" : newValue
            }
        )

        ConfigTextField(
            label: "Preferred Backends",
            placeholder: "ollama, codex, opencode, openclaw, claude",
            helpText: "Ordered backend preference list used for bot routing and deployment defaults.",
            text: stringBinding(getter: { $0.botPreferredBackends.joined(separator: ", ") }) { config, newValue in
                config.botPreferredBackends = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )

        ConfigTextField(
            label: "Bot Temp Directory",
            placeholder: "/tmp/thrive_bot_mesh",
            helpText: "Optional shared temp path for server-side relay or operator guidance. Leave blank for system default.",
            text: stringBinding(getter: { $0.botTempDirectory ?? "" }) { config, newValue in
                config.botTempDirectory = newValue.isEmpty ? nil : newValue
            }
        )

        ConfigNumberField(
            label: "Max Relay File Size (bytes)",
            helpText: "Maximum temp-file size allowed for bot delegation relay.",
            value: intBinding(getter: { $0.botMaxRelayFileSize }) { config, newValue in
                config.botMaxRelayFileSize = max(1024, newValue)
            }
        )
    }

    private func saveSettings() {
        guard let config = settings else { return }
        isSaving = true

        Task {
            await adminManager.updateAPISyncSettings(config)
            isSaving = false
        }
    }

    private func applyRecommendedDefaults() {
        guard var config = settings else { return }
        config.enabled = true
        config.mode = detectedTargets.isEmpty ? "hybrid" : "federated"
        config.syncInterval = 60
        config.autoSyncOnChange = true
        config.allowClientChoice = true
        config.autoReturnRecoveredUsers = true
        config.snapshotIntervalSeconds = 180

        if config.routingProfiles.isEmpty {
            let seedTargets = detectedTargets.isEmpty
                ? ["https://community.voicelinkapp.app"]
                : detectedTargets
            config.routingProfiles = seedTargets.prefix(4).enumerated().map { index, target in
                APISyncRoutingProfile(
                    label: index == 0 ? "Primary fallback route" : "Detected fallback \(index + 1)",
                    targetServer: target,
                    targetType: target.contains("/") ? "domain" : "manual",
                    manualAddress: target,
                    actions: ["start", "fallback", "return"]
                )
            }
        }

        settings = config
        if selectedSubtab == .connection {
            selectedSubtab = .routing
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
        Array(Set(SettingsManager.shared.managedFederationServers.map(\.url))).sorted()
    }

    private func updateConfig(_ mutate: (inout APISyncSettings) -> Void) {
        guard var current = settings else { return }
        mutate(&current)
        settings = current
    }

    private func boolBinding(
        getter: @escaping (APISyncSettings) -> Bool,
        update: @escaping (inout APISyncSettings, Bool) -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { settings.map(getter) ?? false },
            set: { newValue in
                updateConfig { config in
                    update(&config, newValue)
                }
            }
        )
    }

    private func stringBinding(
        getter: @escaping (APISyncSettings) -> String,
        update: @escaping (inout APISyncSettings, String) -> Void
    ) -> Binding<String> {
        Binding(
            get: { settings.map(getter) ?? "" },
            set: { newValue in
                updateConfig { config in
                    update(&config, newValue)
                }
            }
        )
    }

    private func intBinding(
        getter: @escaping (APISyncSettings) -> Int,
        update: @escaping (inout APISyncSettings, Int) -> Void
    ) -> Binding<Int> {
        Binding(
            get: { settings.map(getter) ?? 0 },
            set: { newValue in
                updateConfig { config in
                    update(&config, newValue)
                }
            }
        )
    }

    private func routingProfileStringBinding(
        index: Int,
        getter: @escaping (APISyncRoutingProfile) -> String,
        update: @escaping (inout APISyncRoutingProfile, String) -> Void
    ) -> Binding<String> {
        Binding(
            get: {
                guard let current = settings, current.routingProfiles.indices.contains(index) else { return "" }
                return getter(current.routingProfiles[index])
            },
            set: { newValue in
                updateConfig { config in
                    guard config.routingProfiles.indices.contains(index) else { return }
                    update(&config.routingProfiles[index], newValue)
                }
            }
        )
    }

    private func routingActionBinding(index: Int, slot: Int) -> Binding<String> {
        Binding(
            get: {
                guard let current = settings, current.routingProfiles.indices.contains(index) else { return "none" }
                let actions = current.routingProfiles[index].actions
                return slot < actions.count ? actions[slot] : "none"
            },
            set: { value in
                updateConfig { config in
                    guard config.routingProfiles.indices.contains(index) else { return }
                    var actions = config.routingProfiles[index].actions
                    while actions.count <= slot { actions.append("none") }
                    actions[slot] = value
                    config.routingProfiles[index].actions = actions.filter { $0 != "none" }
                }
            }
        )
    }
}
