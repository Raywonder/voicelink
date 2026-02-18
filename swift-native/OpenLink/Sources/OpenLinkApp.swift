import SwiftUI

@main
struct OpenLinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var service = OpenLinkService.shared

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About OpenLink") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            .applicationName: "OpenLink",
                            .applicationVersion: "2.0.0",
                            .credits: NSAttributedString(string: "VoiceLink Connection Service")
                        ]
                    )
                }
            }
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        OpenLinkService.shared.start()

        // Get reference to main window
        mainWindow = NSApplication.shared.windows.first
    }

    func applicationWillTerminate(_ notification: Notification) {
        OpenLinkService.shared.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            mainWindow?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "link.circle.fill", accessibilityDescription: "OpenLink")
            button.action = #selector(statusBarClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        updateStatusBarMenu()
    }

    private func updateStatusBarMenu() {
        let menu = NSMenu()

        let statusItem = NSMenuItem(title: OpenLinkService.shared.isRunning ? "Status: Running" : "Status: Stopped", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Show Window", action: #selector(showMainWindow), keyEquivalent: "o"))

        menu.addItem(NSMenuItem.separator())

        if OpenLinkService.shared.isRunning {
            menu.addItem(NSMenuItem(title: "Stop Service", action: #selector(stopService), keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "Start Service", action: #selector(startService), keyEquivalent: ""))
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit OpenLink", action: #selector(quitApp), keyEquivalent: "q"))

        self.statusItem?.menu = menu
    }

    @objc func statusBarClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!
        if event.type == .rightMouseUp {
            updateStatusBarMenu()
            statusItem?.button?.performClick(nil)
        } else {
            showMainWindow()
        }
    }

    @objc func showMainWindow() {
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func startService() {
        OpenLinkService.shared.start()
        updateStatusBarMenu()
    }

    @objc func stopService() {
        OpenLinkService.shared.stop()
        updateStatusBarMenu()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Main Window View

struct MainWindowView: View {
    @StateObject private var service = OpenLinkService.shared
    @State private var selectedTab: TabSelection = .dashboard

    enum TabSelection: String, CaseIterable {
        case dashboard = "Dashboard"
        case servers = "Servers"
        case domains = "Domain Hosts"
        case connection = "Connection"
        case security = "Security"
        case advanced = "Advanced"
        case logs = "Logs"
    }

    var body: some View {
        HSplitView {
            sidebarView
            detailView
        }
    }

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(TabSelection.allCases, id: \.self) { tab in
                Button(action: { selectedTab = tab }) {
                    HStack(spacing: 8) {
                        Image(systemName: iconForTab(tab))
                            .frame(width: 20)
                        Text(tab.rawValue)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(selectedTab == tab ? Color.accentColor.opacity(0.2) : Color.clear)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .foregroundColor(selectedTab == tab ? .accentColor : .primary)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .frame(minWidth: 180, maxWidth: 220)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var detailView: some View {
        VStack(spacing: 0) {
            HeaderBar(selectedTab: selectedTab)
            Divider()
            contentView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch selectedTab {
        case .dashboard:
            DashboardTab()
        case .servers:
            ServersTab()
        case .domains:
            DomainsTab()
        case .connection:
            ConnectionTab()
        case .security:
            SecurityTab()
        case .advanced:
            AdvancedTab()
        case .logs:
            LogsTab()
        }
    }

    private func iconForTab(_ tab: TabSelection) -> String {
        switch tab {
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .servers: return "server.rack"
        case .domains: return "globe"
        case .connection: return "antenna.radiowaves.left.and.right"
        case .security: return "lock.shield"
        case .advanced: return "gearshape.2"
        case .logs: return "doc.text"
        }
    }
}

// MARK: - Header Bar

struct HeaderBar: View {
    @StateObject private var service = OpenLinkService.shared
    let selectedTab: MainWindowView.TabSelection

    var body: some View {
        HStack {
            // Logo and title
            HStack(spacing: 8) {
                Image(systemName: "link.circle.fill")
                    .font(.title)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenLink")
                        .font(.headline)
                    Text(selectedTab.rawValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Status
            HStack(spacing: 16) {
                // Connected devices
                if service.connectedDevices > 0 {
                    Label("\(service.connectedDevices)", systemImage: "laptopcomputer.and.iphone")
                        .foregroundColor(.green)
                }

                // Service status
                HStack(spacing: 6) {
                    Circle()
                        .fill(service.isRunning ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(service.isRunning ? "Running" : "Stopped")
                        .font(.caption)
                }

                // Toggle button
                Button(action: {
                    if service.isRunning {
                        service.stop()
                    } else {
                        service.start()
                    }
                }) {
                    Image(systemName: service.isRunning ? "stop.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundColor(service.isRunning ? .red : .green)
                }
                .buttonStyle(.plain)
                .help(service.isRunning ? "Stop Service" : "Start Service")
            }
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Dashboard Tab

struct DashboardTab: View {
    @StateObject private var service = OpenLinkService.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Status Cards
                HStack(spacing: 16) {
                    StatusCard(
                        title: "Service Status",
                        value: service.isRunning ? "Active" : "Inactive",
                        icon: "checkmark.circle.fill",
                        color: service.isRunning ? .green : .red
                    )

                    StatusCard(
                        title: "Connection Mode",
                        value: service.connectionMode.rawValue,
                        icon: "arrow.triangle.branch",
                        color: .blue
                    )

                    StatusCard(
                        title: "Connected Devices",
                        value: "\(service.connectedDevices)",
                        icon: "laptopcomputer.and.iphone",
                        color: .purple
                    )

                    StatusCard(
                        title: "Paired Servers",
                        value: "\(service.pairedServers.count)",
                        icon: "server.rack",
                        color: .orange
                    )
                }

                // Network Info
                GroupBox("Network Information") {
                    VStack(alignment: .leading, spacing: 12) {
                        InfoRow(label: "Local IP", value: service.localIP ?? "Detecting...")
                        InfoRow(label: "Listening Port", value: "\(service.port)")
                        InfoRow(label: "Auto-Discovery", value: service.discoveryEnabled ? "Enabled" : "Disabled")
                        InfoRow(label: "Remote Control", value: service.allowRemoteControl ? "Allowed" : "Blocked")
                    }
                    .padding()
                }

                // Quick Actions
                GroupBox("Quick Actions") {
                    HStack(spacing: 16) {
                        ActionButton(title: "Restart Service", icon: "arrow.clockwise", color: .blue) {
                            service.stop()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                service.start()
                            }
                        }

                        ActionButton(title: "Refresh Servers", icon: "arrow.triangle.2.circlepath", color: .green) {
                            for server in service.pairedServers {
                                service.testConnection(server)
                            }
                        }

                        ActionButton(title: "Clear Logs", icon: "trash", color: .orange) {
                            // Clear logs action
                        }
                    }
                    .padding()
                }

                // Server Status
                GroupBox("Server Status") {
                    if service.pairedServers.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "server.rack")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text("No servers paired")
                                .foregroundColor(.secondary)
                            Text("Go to Servers tab to add a server")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(40)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(service.pairedServers) { server in
                                ServerStatusRow(server: server)
                            }
                        }
                        .padding()
                    }
                }
            }
            .padding()
        }
    }
}

struct StatusCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                Spacer()
            }

            Text(value)
                .font(.title2)
                .fontWeight(.bold)

            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

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
            .frame(maxWidth: .infinity)
            .padding()
            .background(color.opacity(0.1))
            .foregroundColor(color)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

struct ServerStatusRow: View {
    let server: PairedServer
    @StateObject private var service = OpenLinkService.shared

    var body: some View {
        HStack {
            Circle()
                .fill(server.isOnline ? Color.green : Color.gray)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .fontWeight(.medium)
                Text(server.url)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(server.isOnline ? "Online" : "Offline")
                .font(.caption)
                .foregroundColor(server.isOnline ? .green : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(server.isOnline ? Color.green.opacity(0.1) : Color.gray.opacity(0.1))
                .cornerRadius(4)

            Button(action: { service.testConnection(server) }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Servers Tab

struct ServersTab: View {
    @StateObject private var service = OpenLinkService.shared
    @State private var showAddServer = false
    @State private var pairingCode = ""
    @State private var manualURL = ""
    @State private var serverName = ""
    @State private var addMode: AddMode = .pairing

    enum AddMode {
        case pairing
        case manual
    }

    var body: some View {
        HSplitView {
            // Server list
            VStack(spacing: 0) {
                // Toolbar
                HStack {
                    Text("Paired Servers")
                        .font(.headline)
                    Spacer()
                    Button(action: { showAddServer = true }) {
                        Image(systemName: "plus")
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))

                Divider()

                // List
                List {
                    ForEach(service.pairedServers) { server in
                        ServerListRow(server: server)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            service.removeServer(service.pairedServers[index])
                        }
                    }
                }
            }
            .frame(minWidth: 300)

            // Add server panel
            if showAddServer {
                VStack(spacing: 20) {
                    Text("Add Server")
                        .font(.title2)
                        .fontWeight(.bold)

                    Picker("Method", selection: $addMode) {
                        Text("Pairing Code").tag(AddMode.pairing)
                        Text("Manual URL").tag(AddMode.manual)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    if addMode == .pairing {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Enter the 6-digit pairing code from your VoiceLink server")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            TextField("Pairing Code", text: $pairingCode)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.title, design: .monospaced))
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Server Name", text: $serverName)
                                .textFieldStyle(.roundedBorder)

                            TextField("Server URL (e.g., http://192.168.1.100:3000)", text: $manualURL)
                                .textFieldStyle(.roundedBorder)
                        }
                        .padding()
                    }

                    HStack {
                        Button("Cancel") {
                            showAddServer = false
                            pairingCode = ""
                            manualURL = ""
                            serverName = ""
                        }
                        .buttonStyle(.bordered)

                        Button("Add Server") {
                            if addMode == .pairing {
                                service.pairWithCode(pairingCode)
                            } else {
                                service.addServerManually(url: manualURL)
                            }
                            showAddServer = false
                            pairingCode = ""
                            manualURL = ""
                            serverName = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(addMode == .pairing ? pairingCode.count != 6 : manualURL.isEmpty)
                    }

                    Spacer()
                }
                .frame(minWidth: 350)
                .padding()
                .background(Color(NSColor.windowBackgroundColor))
            }
        }
    }
}

struct ServerListRow: View {
    let server: PairedServer
    @StateObject private var service = OpenLinkService.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Circle()
                        .fill(server.isOnline ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(server.name)
                        .fontWeight(.medium)
                }
                Text(server.url)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let lastSeen = server.lastSeen {
                    Text("Last seen: \(lastSeen, formatter: dateFormatter)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Menu {
                Button("Connect") { service.connectToServer(server) }
                Button("Test Connection") { service.testConnection(server) }
                Divider()
                Button("Remove", role: .destructive) { service.removeServer(server) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.vertical, 4)
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }
}

// MARK: - Domains Tab

struct DomainsTab: View {
    @StateObject private var service = OpenLinkService.shared
    @State private var domainHosts: [DomainHost] = []
    @State private var showAddDomain = false
    @State private var newDomain = ""
    @State private var newTargetIP = ""
    @State private var newTargetPort = "3000"
    @State private var selectedDomain: DomainHost?

    var body: some View {
        HSplitView {
            // Domain list
            VStack(spacing: 0) {
                HStack {
                    Text("Domain Hosts")
                        .font(.headline)
                    Spacer()
                    Button(action: { showAddDomain = true }) {
                        Image(systemName: "plus")
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))

                Divider()

                List(selection: $selectedDomain) {
                    ForEach(domainHosts) { domain in
                        DomainListRow(domain: domain)
                            .tag(domain)
                    }
                    .onDelete { indexSet in
                        domainHosts.remove(atOffsets: indexSet)
                        saveDomainHosts()
                    }
                }
            }
            .frame(minWidth: 300)

            // Domain details / Add domain
            if showAddDomain {
                AddDomainView(
                    newDomain: $newDomain,
                    newTargetIP: $newTargetIP,
                    newTargetPort: $newTargetPort,
                    onCancel: { showAddDomain = false },
                    onAdd: {
                        let domain = DomainHost(
                            domain: newDomain,
                            targetIP: newTargetIP,
                            targetPort: Int(newTargetPort) ?? 3000
                        )
                        domainHosts.append(domain)
                        saveDomainHosts()
                        showAddDomain = false
                        newDomain = ""
                        newTargetIP = ""
                        newTargetPort = "3000"
                    }
                )
            } else if let selected = selectedDomain {
                DomainDetailView(domain: selected)
            } else {
                VStack {
                    Image(systemName: "globe")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Select a domain or add a new one")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            loadDomainHosts()
        }
    }

    private func loadDomainHosts() {
        let path = NSHomeDirectory() + "/.openlink/domains.json"
        if let data = FileManager.default.contents(atPath: path),
           let hosts = try? JSONDecoder().decode([DomainHost].self, from: data) {
            domainHosts = hosts
        }
    }

    private func saveDomainHosts() {
        let path = NSHomeDirectory() + "/.openlink/domains.json"
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(domainHosts) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

struct DomainHost: Identifiable, Codable, Hashable {
    let id: String
    var domain: String
    var targetIP: String
    var targetPort: Int
    var isEnabled: Bool
    var sslEnabled: Bool
    var sslCertPath: String?
    var sslKeyPath: String?

    init(id: String = UUID().uuidString, domain: String, targetIP: String, targetPort: Int = 3000, isEnabled: Bool = true, sslEnabled: Bool = false) {
        self.id = id
        self.domain = domain
        self.targetIP = targetIP
        self.targetPort = targetPort
        self.isEnabled = isEnabled
        self.sslEnabled = sslEnabled
    }
}

struct DomainListRow: View {
    let domain: DomainHost

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Circle()
                        .fill(domain.isEnabled ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(domain.domain)
                        .fontWeight(.medium)
                }
                Text("\(domain.targetIP):\(domain.targetPort)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if domain.sslEnabled {
                Image(systemName: "lock.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}

struct AddDomainView: View {
    @Binding var newDomain: String
    @Binding var newTargetIP: String
    @Binding var newTargetPort: String
    let onCancel: () -> Void
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Domain Host")
                .font(.title2)
                .fontWeight(.bold)

            GroupBox("Domain Settings") {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Domain Name")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("e.g., voicelink.example.com", text: $newDomain)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Target IP Address")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("e.g., 192.168.1.100", text: $newTargetIP)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Target Port")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("3000", text: $newTargetPort)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                }
                .padding()
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)

                Button("Add Domain", action: onAdd)
                    .buttonStyle(.borderedProminent)
                    .disabled(newDomain.isEmpty || newTargetIP.isEmpty)
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 350)
    }
}

struct DomainDetailView: View {
    let domain: DomainHost
    @State private var isEnabled: Bool
    @State private var sslEnabled: Bool

    init(domain: DomainHost) {
        self.domain = domain
        self._isEnabled = State(initialValue: domain.isEnabled)
        self._sslEnabled = State(initialValue: domain.sslEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(domain.domain)
                .font(.title2)
                .fontWeight(.bold)

            GroupBox("Configuration") {
                VStack(alignment: .leading, spacing: 12) {
                    InfoRow(label: "Target", value: "\(domain.targetIP):\(domain.targetPort)")

                    Divider()

                    Toggle("Enabled", isOn: $isEnabled)
                    Toggle("SSL/TLS Enabled", isOn: $sslEnabled)

                    if sslEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Certificate Path")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack {
                                TextField("Path to certificate", text: .constant(domain.sslCertPath ?? ""))
                                    .textFieldStyle(.roundedBorder)
                                Button("Browse...") {}
                                    .buttonStyle(.bordered)
                            }

                            Text("Key Path")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack {
                                TextField("Path to private key", text: .constant(domain.sslKeyPath ?? ""))
                                    .textFieldStyle(.roundedBorder)
                                Button("Browse...") {}
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                .padding()
            }

            GroupBox("Statistics") {
                VStack(alignment: .leading, spacing: 8) {
                    InfoRow(label: "Total Requests", value: "0")
                    InfoRow(label: "Active Connections", value: "0")
                    InfoRow(label: "Bandwidth Used", value: "0 MB")
                }
                .padding()
            }

            Spacer()
        }
        .padding()
    }
}

// MARK: - Connection Tab

struct ConnectionTab: View {
    @StateObject private var service = OpenLinkService.shared
    @AppStorage("serverPort") private var serverPort = 3000
    @AppStorage("discoveryTimeout") private var discoveryTimeout = 10.0
    @AppStorage("maxConnections") private var maxConnections = 100
    @AppStorage("keepAliveInterval") private var keepAliveInterval = 30

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Connection Mode
                GroupBox("Connection Mode") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Mode", selection: $service.connectionMode) {
                            ForEach(ConnectionMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text(service.connectionMode.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                }

                // Network Settings
                GroupBox("Network Settings") {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Listening Port:")
                            TextField("Port", value: $serverPort, formatter: NumberFormatter())
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Text("(requires restart)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Text("Max Connections:")
                            TextField("Max", value: $maxConnections, formatter: NumberFormatter())
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                        }

                        HStack {
                            Text("Keep-Alive Interval:")
                            TextField("Seconds", value: $keepAliveInterval, formatter: NumberFormatter())
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Text("seconds")
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                }

                // Discovery
                GroupBox("Auto-Discovery") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Enable auto-discovery", isOn: $service.discoveryEnabled)

                        if service.discoveryEnabled {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Discovery Timeout: \(Int(discoveryTimeout)) seconds")
                                Slider(value: $discoveryTimeout, in: 5...60, step: 5)
                            }

                            Toggle("Probe local network on startup", isOn: .constant(true))
                            Toggle("Respond to discovery requests", isOn: .constant(true))
                        }
                    }
                    .padding()
                }

                // Proxy Settings
                GroupBox("Proxy Settings") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Use system proxy", isOn: .constant(false))
                        Toggle("Use custom proxy", isOn: .constant(false))

                        HStack {
                            Text("Proxy URL:")
                            TextField("http://proxy:8080", text: .constant(""))
                                .textFieldStyle(.roundedBorder)
                        }
                        .disabled(true)
                    }
                    .padding()
                }
            }
            .padding()
        }
    }
}

// MARK: - Security Tab

struct SecurityTab: View {
    @StateObject private var service = OpenLinkService.shared
    @AppStorage("requireAuth") private var requireAuth = true
    @AppStorage("sessionTimeout") private var sessionTimeout = 3600

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Access Control
                GroupBox("Access Control") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Require authentication", isOn: $requireAuth)
                        Toggle("Allow remote control", isOn: $service.allowRemoteControl)
                        Toggle("Trusted devices only", isOn: $service.trustedDevicesOnly)

                        Divider()

                        HStack {
                            Text("Session Timeout:")
                            TextField("Seconds", value: $sessionTimeout, formatter: NumberFormatter())
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Text("seconds")
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                }

                // Encryption
                GroupBox("Encryption") {
                    VStack(alignment: .leading, spacing: 12) {
                        InfoRow(label: "Protocol", value: "TLS 1.3")
                        InfoRow(label: "Cipher Suite", value: "AES-256-GCM")
                        InfoRow(label: "Key Exchange", value: "ECDHE")

                        Divider()

                        Toggle("Enforce minimum TLS 1.2", isOn: .constant(true))
                        Toggle("Enable certificate pinning", isOn: .constant(false))
                    }
                    .padding()
                }

                // Firewall
                GroupBox("Firewall Rules") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Enable IP whitelist", isOn: .constant(false))
                        Toggle("Block unknown devices", isOn: .constant(false))
                        Toggle("Rate limiting", isOn: .constant(true))

                        HStack {
                            Text("Max requests/minute:")
                            TextField("Rate", value: .constant(100), formatter: NumberFormatter())
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                        }
                    }
                    .padding()
                }
            }
            .padding()
        }
    }
}

// MARK: - Advanced Tab

struct AdvancedTab: View {
    @AppStorage("debugMode") private var debugMode = false
    @AppStorage("verboseLogging") private var verboseLogging = false
    @AppStorage("launchAtLogin") private var launchAtLogin = true
    @AppStorage("minimizeToTray") private var minimizeToTray = true
    @AppStorage("showNotifications") private var showNotifications = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Startup
                GroupBox("Startup") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Launch at login", isOn: $launchAtLogin)
                        Toggle("Start service automatically", isOn: .constant(true))
                        Toggle("Minimize to system tray on close", isOn: $minimizeToTray)
                    }
                    .padding()
                }

                // Notifications
                GroupBox("Notifications") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Show notifications", isOn: $showNotifications)
                        Toggle("Sound alerts", isOn: .constant(true))
                        Toggle("Connection alerts", isOn: .constant(true))
                        Toggle("Error alerts", isOn: .constant(true))
                    }
                    .padding()
                }

                // Debugging
                GroupBox("Debugging") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Debug mode", isOn: $debugMode)
                        Toggle("Verbose logging", isOn: $verboseLogging)

                        HStack {
                            Button("Export Logs") {
                                // Export logs
                            }
                            .buttonStyle(.bordered)

                            Button("Clear Cache") {
                                // Clear cache
                            }
                            .buttonStyle(.bordered)

                            Button("Reset Settings") {
                                // Reset settings
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }
                    }
                    .padding()
                }

                // Data
                GroupBox("Data Management") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Config Location:")
                            Text(NSHomeDirectory() + "/.openlink/")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Open") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.openlink/"))
                            }
                            .buttonStyle(.bordered)
                        }

                        HStack {
                            Button("Export Configuration") {}
                                .buttonStyle(.bordered)

                            Button("Import Configuration") {}
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding()
                }
            }
            .padding()
        }
    }
}

// MARK: - Logs Tab

struct LogsTab: View {
    @State private var logs: [LogEntry] = []
    @State private var filterLevel: LogLevel = .all
    @State private var searchText = ""

    enum LogLevel: String, CaseIterable {
        case all = "All"
        case info = "Info"
        case warning = "Warning"
        case error = "Error"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Picker("Level", selection: $filterLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)

                Spacer()

                TextField("Search logs...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)

                Button(action: { logs.removeAll() }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)

                Button(action: { exportLogs() }) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Log list
            if logs.isEmpty {
                VStack {
                    Image(systemName: "doc.text")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No logs yet")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredLogs) { log in
                    LogRow(entry: log)
                }
            }
        }
        .onAppear {
            generateSampleLogs()
        }
    }

    private var filteredLogs: [LogEntry] {
        logs.filter { log in
            (filterLevel == .all || log.level.rawValue == filterLevel.rawValue) &&
            (searchText.isEmpty || log.message.localizedCaseInsensitiveContains(searchText))
        }
    }

    private func generateSampleLogs() {
        logs = [
            LogEntry(level: .info, message: "OpenLink service started", source: "Service"),
            LogEntry(level: .info, message: "Listening on port 3000", source: "Network"),
            LogEntry(level: .info, message: "Auto-discovery enabled", source: "Discovery"),
        ]
    }

    private func exportLogs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "openlink-logs.txt"

        if panel.runModal() == .OK, let url = panel.url {
            let content = logs.map { "[\($0.timestamp)] [\($0.level.rawValue.uppercased())] \($0.message)" }.joined(separator: "\n")
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogsTab.LogLevel
    let message: String
    let source: String

    init(level: LogsTab.LogLevel, message: String, source: String) {
        self.timestamp = Date()
        self.level = level
        self.message = message
        self.source = source
    }
}

struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconForLevel(entry.level))
                .foregroundColor(colorForLevel(entry.level))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message)
                    .font(.system(.body, design: .monospaced))

                HStack {
                    Text(entry.timestamp, style: .time)
                    Text("•")
                    Text(entry.source)
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func iconForLevel(_ level: LogsTab.LogLevel) -> String {
        switch level {
        case .all: return "circle"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.circle"
        }
    }

    private func colorForLevel(_ level: LogsTab.LogLevel) -> Color {
        switch level {
        case .all: return .secondary
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}
