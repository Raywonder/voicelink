import SwiftUI

// MARK: - Federation Section
struct AdminFederationSection: View {
    @ObservedObject var adminManager = AdminServerManager.shared
    @ObservedObject private var settingsManager = SettingsManager.shared
    @State private var settings: FederationSettings?
    @State private var newTrustedServer = ""
    @State private var newBlockedServer = ""
    @State private var isSaving = false

    private var managedPeers: [SettingsManager.ManagedFederationServer] {
        settingsManager.managedFederationServers
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            AdminHelpSection(
                title: "Quick Help",
                summary: "Federation controls how this server exchanges room visibility, room state, and maintenance handoff behavior with other VoiceLink installs.",
                steps: [
                    "Only server owners and authorized admins should change default peer settings. Members and guests should never use this screen to override server policy.",
                    "Keep the VoiceLink and VoiceLink Community Server peers enabled if they are part of your managed cluster. Toggle them off only during troubleshooting or planned isolation.",
                    "Federation is the all-servers layer. Per-server Desktop, iOS, and Web visibility settings still decide which platforms can see each server after federation is enabled.",
                    "Use maintenance handoff when this server is going down for work. That lets active rooms and users move to an online trusted server instead of being dropped."
                ],
                docs: [
                    AdminDocLink(title: "Admin Federation Guide", localRelativePath: "authenticated/admin-panel.html", webPath: "/docs/authenticated/admin-panel.html", adminWebPath: "/docs/authenticated/admin-panel.html"),
                    AdminDocLink(title: "Server Install Docs", localRelativePath: "installation/index.html", webPath: "/docs/installation/index.html", adminWebPath: "/docs/authenticated/admin-panel.html")
                ]
            )

            if var config = settings {
                ConfigToggle(label: "Enable Federation", isOn: Binding(
                    get: { config.enabled },
                    set: { config.enabled = $0; settings = config }
                ))

                if config.enabled {
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

                    Text("These peers are supplied by the VoiceLink API and represent the managed cluster. Admins can enable or disable federation with them here, but members cannot edit or rename them from client preferences. When enabled, they participate in the shared all-servers federation view.")
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

                    SectionHeader(title: "Trusted Servers")

                    HStack {
                        TextField("Trusted server URL", text: $newTrustedServer)
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

                    SectionHeader(title: "Blocked Servers")

                    HStack {
                        TextField("Blocked server URL", text: $newBlockedServer)
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
