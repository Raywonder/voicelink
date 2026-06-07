import SwiftUI

// MARK: - Modules Section
struct AdminModulesSection: View {
    @ObservedObject var adminManager = AdminServerManager.shared
    @State private var filterMode: ModuleFilter = .all
    @State private var query = ""
    @State private var actionInFlight: String?
    @State private var configEditorModule: ModuleEditorRequest?
    @State private var configEditorText: String = "{}"
    @State private var showFlexPBXHoldMediaManager = false
    @State private var showBackupManager = false
    @State private var showSSLManager = false
    @State private var selectedModuleID: String?
    @AccessibilityFocusState private var focusedModuleID: String?

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

    private var missingModuleCount: Int {
        adminManager.availableModules.filter { !$0.installed }.count
    }

    private var installedModuleCount: Int {
        adminManager.availableModules.filter { $0.installed && $0.id != "ssl-manager" }.count
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
                    runAction("install-all-missing", focusModuleID: selectedModuleID ?? filteredModules.first?.id) {
                        await adminManager.installAllMissingModules()
                    }
                }) {
                    Label("Install All Missing", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(actionInFlight != nil || missingModuleCount == 0)
                .accessibilityHint("Installs every module that is not installed on the selected server. If All Cluster Servers is enabled, the request is marked for cluster API sync.")

                Button(action: {
                    runAction("update-all", focusModuleID: selectedModuleID ?? filteredModules.first?.id) {
                        await adminManager.updateAllModules()
                    }
                }) {
                    Label("Update All", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .disabled(actionInFlight != nil || installedModuleCount == 0)
                .accessibilityHint("Reconciles installed modules with the current API module catalog and preserves existing custom settings.")

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

                TextField("Search modules by name, category, or description", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Module search")
                    .accessibilityHint("Filter the module list by module name, category, or description.")
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
                                if module.id != "ssl-manager" {
                                    Button(module.enabled ? "Disable" : "Enable") {
                                        runAction("toggle-\(module.id)", focusModuleID: module.id) {
                                            await adminManager.setModuleEnabled(module.id, enabled: !module.enabled)
                                        }
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Update") {
                                        runAction("update-\(module.id)", focusModuleID: module.id) {
                                            await adminManager.updateModule(module.id, enabled: module.enabled)
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                }

                                Menu("Configure") {
                                    if module.id == "ssl-manager" {
                                        Button("SSL Manager") {
                                            showSSLManager = true
                                        }
                                    }
                                    if module.id == "voicelink-flexpbx" {
                                        Button("Hold Media Manager") {
                                            showFlexPBXHoldMediaManager = true
                                        }
                                    }
                                    if module.id == "backup-manager" {
                                        Button("Backup Manager") {
                                            showBackupManager = true
                                        }
                                    }
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

                                if module.id != "ssl-manager" {
                                    Button("Uninstall", role: .destructive) {
                                        runAction("uninstall-\(module.id)", focusModuleID: module.id) {
                                            await adminManager.uninstallModule(module.id)
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                }
                            } else {
                                Button("Install") {
                                    runAction("install-\(module.id)", focusModuleID: module.id) {
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
                                if module.id == "ssl-manager" {
                                    Text("SSL Manager is built in on every server. Use Configure to review live certificate paths, renew settings, and reload behavior.")
                                    Text("Auto-detect syncs known cPanel, reverse-proxy, and internal certificate defaults.")
                                } else {
                                    Text(module.enabled ? "Disable stops this module without removing its saved configuration." : "Enable turns this module back on with its saved configuration.")
                                    Text("Update fetches the latest version of this module from the server.")
                                    Text("Configure opens standard controls first. Advanced JSON is available from the Configure menu for power users.")
                                    Text("Uninstall removes the module from this server.")
                                }
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
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(selectedModuleID == module.id ? Color.blue.opacity(0.85) : Color.clear, lineWidth: 2)
                    )
                    .onTapGesture {
                        selectedModuleID = module.id
                        focusedModuleID = module.id
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityFocused($focusedModuleID, equals: module.id)
                    .accessibilityAction(named: "Select Module") {
                        selectedModuleID = module.id
                        focusedModuleID = module.id
                    }
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
            selectedModuleID = selectedModuleID ?? filteredModules.first?.id
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
        .sheet(isPresented: $showFlexPBXHoldMediaManager) {
            VoiceLinkFlexPBXHoldMediaManagerSheet()
        }
        .sheet(isPresented: $showBackupManager) {
            BackupManagerSheet()
        }
        .sheet(isPresented: $showSSLManager) {
            SSLManagerSheet()
        }
    }

    private func runAction(_ key: String, focusModuleID: String? = nil, operation: @escaping () async -> Bool) {
        if let focusModuleID {
            selectedModuleID = focusModuleID
        }
        actionInFlight = key
        Task {
            _ = await operation()
            actionInFlight = nil
            restoreModuleFocus(preferredID: focusModuleID)
        }
    }

    private func restoreModuleFocus(preferredID: String?) {
        let target = preferredID
            ?? selectedModuleID
            ?? filteredModules.first?.id
        guard let target else { return }
        selectedModuleID = target
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            focusedModuleID = target
        }
    }
}
