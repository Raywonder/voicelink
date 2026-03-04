import SwiftUI

/// Licensing status view for VoiceLink
/// Shows license status, device activations, and management options
struct LicensingView: View {
    @ObservedObject var licensing = LicensingManager.shared
    @State private var showDeviceManagement = false
    @State private var selectedDeviceToDeactivate: LicensingManager.ActivatedDevice?
    @State private var selectedTab: LicensingTab = .summary
    @State private var showActivateConfirmation = false
    @State private var showDeactivateConfirmation = false

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "key.fill")
                    .font(.title2)
                    .foregroundColor(statusColor)
                Text("License Status")
                    .font(.headline)
                Spacer()
                if licensing.isChecking {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }

            Divider()

            HStack(alignment: .top, spacing: 16) {
                licensingTabs
                    .frame(width: 120, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 16) {
                    switch selectedTab {
                    case .summary:
                        statusView
                        if licensing.licenseStatus == .licensed || licensing.licenseStatus == .deviceLimitReached {
                            deviceSlotsView
                        }
                        currentMachineView
                        actionsView
                    case .devices:
                        devicesView
                    case .history:
                        recentMachinesView
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            // Error message
            if let error = licensing.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.top, 4)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .sheet(isPresented: $showDeviceManagement) {
            DeviceManagementSheet(licensing: licensing)
        }
        .task {
            if AuthenticationManager.shared.currentUser != nil {
                await licensing.refreshForCurrentUser()
            } else if licensing.licenseKey != nil {
                await licensing.validateLicense()
            }
        }
        .alert("Activate This Mac?", isPresented: $showActivateConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Continue") {
                Task {
                    _ = await licensing.activateDevice()
                }
            }
        } message: {
            Text("This will activate \(licensing.currentDeviceName) using your assigned license.")
        }
        .alert("Deactivate Device?", isPresented: $showDeactivateConfirmation, presenting: selectedDeviceToDeactivate) { device in
            Button("Cancel", role: .cancel) { }
            Button("Continue", role: .destructive) {
                Task {
                    _ = await licensing.deactivateDevice(device.id)
                }
            }
        } message: { device in
            Text("This will deactivate \(device.name). If you're not sure, cancel.")
        }
    }

    private enum LicensingTab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case devices = "Devices"
        case history = "History"

        var id: String { rawValue }
    }

    private var licensingTabs: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(LicensingTab.allCases) { tab in
                Button(tab.rawValue) {
                    selectedTab = tab
                }
                .buttonStyle(.bordered)
                .tint(selectedTab == tab ? .accentColor : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(tab.rawValue)
                .accessibilityValue(selectedTab == tab ? "Selected" : "Not selected")
            }
            Spacer()
        }
    }

    private var statusColor: Color {
        switch licensing.licenseStatus {
        case .licensed: return .green
        case .pending: return .orange
        case .deviceLimitReached: return .yellow
        case .requires2FA: return .blue
        case .revoked, .error: return .red
        default: return .gray
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch licensing.licenseStatus {
        case .notRegistered, .unknown:
            VStack(spacing: 8) {
                Image(systemName: "questionmark.circle")
                    .font(.largeTitle)
                    .foregroundColor(.gray)
                Text("Not Registered")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("Register to get a license key")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

        case .pending:
            VStack(spacing: 12) {
                // Progress ring
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.3), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: licensing.registrationProgress)
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut, value: licensing.registrationProgress)
                    VStack {
                        Text("\(licensing.remainingMinutes)")
                            .font(.title.bold())
                        Text("min")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 80, height: 80)

                Text("Registration in Progress")
                    .font(.subheadline)
                Text("License will be issued soon")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

        case .licensed:
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.largeTitle)
                    .foregroundColor(.green)
                Text("Licensed")
                    .font(.subheadline.bold())
                    .foregroundColor(.green)
                if let key = licensing.licenseKey {
                    Text(formatLicenseKey(key))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

        case .deviceLimitReached:
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundColor(.yellow)
                Text(licensing.activationRequired ? "Device Activation Required" : "Device Limit Reached")
                    .font(.subheadline.bold())
                    .foregroundColor(.yellow)
                Text(licensing.activationRequired ? "Your account license is already assigned. Activate this Mac to attach it to the existing key." : "Deactivate a device or purchase more slots")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let key = licensing.licenseKey {
                    Text(formatLicenseKey(key))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                if let primaryEmail = licensing.primaryEmail {
                    Text(primaryEmail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let evictedName = licensing.lastEvictedDeviceName {
                    Text("Oldest install replaced: \(evictedName)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

        case .revoked:
            VStack(spacing: 8) {
                Image(systemName: "xmark.seal.fill")
                    .font(.largeTitle)
                    .foregroundColor(.red)
                Text("License Revoked")
                    .font(.subheadline.bold())
                    .foregroundColor(.red)
            }

        case .error:
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundColor(.red)
                Text("Error")
                    .font(.subheadline.bold())
                    .foregroundColor(.red)
            }

        case .requires2FA:
            VStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.largeTitle)
                    .foregroundColor(.blue)
                Text("2FA Required")
                    .font(.subheadline.bold())
                    .foregroundColor(.blue)
                Text("Enter your two-factor authentication code")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                HStack {
                    TextField("2FA Code", text: $licensing.twoFactorCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)

                    Button("Verify") {
                        Task {
                            await licensing.verifyWith2FA()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(licensing.twoFactorCode.count < 6)
                }
            }
        }
    }

    private var deviceSlotsView: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Device Slots")
                    .font(.caption.bold())
                Spacer()
                Text("\(licensing.activatedDevices)/\(licensing.maxDevices)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Slot indicators
            HStack(spacing: 4) {
                ForEach(0..<licensing.maxDevices, id: \.self) { index in
                    Circle()
                        .fill(index < licensing.activatedDevices ? Color.green : Color.gray.opacity(0.3))
                        .frame(width: 12, height: 12)
                }
                Spacer()

                if licensing.remainingSlots > 0 {
                    Text("\(licensing.remainingSlots) available")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var currentMachineView: some View {
        GroupBox("This Mac") {
            VStack(alignment: .leading, spacing: 8) {
                machineRow("Name", licensing.currentDeviceName)
                machineRow("Platform", licensing.currentDevicePlatform)
                machineRow("Status", currentMachineStatusText)
                if let machine = currentMachine {
                    machineRow("Last Seen", formatMachineTimestamp(machine.lastSeen))
                    if let lastActivatedAt = machine.lastActivatedAt, !lastActivatedAt.isEmpty {
                        machineRow("Last Activated", formatMachineTimestamp(lastActivatedAt))
                    }
                }
            }
        }
    }

    private var devicesView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if licensing.devices.isEmpty {
                Text("No active devices")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(licensing.devices) { device in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.name)
                                .font(.subheadline.bold())
                            Text("\(device.platform) • Last seen \(formatMachineTimestamp(device.lastSeen))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if isCurrentDevice(device) {
                            Text("Active Here")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                        Button("Deactivate") {
                            selectedDeviceToDeactivate = device
                            showDeactivateConfirmation = true
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var recentMachinesView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Machine History")
                    .font(.caption.bold())
                Spacer()
                if let primaryEmail = licensing.primaryEmail {
                    Text(primaryEmail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if licensing.recentMachines.isEmpty {
                Text("No machine history")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(licensing.recentMachines.prefix(10)) { machine in
                HStack(spacing: 8) {
                    Image(systemName: iconName(for: machine.state))
                        .foregroundColor(iconColor(for: machine.state))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(machine.name)
                            .font(.caption)
                        Text(machineStatusText(for: machine))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func machineStatusText(for machine: LicensingManager.RecentMachine) -> String {
        let normalizedState = machine.state.replacingOccurrences(of: "_", with: " ")
        return "\(machine.platform) • \(normalizedState) • \(formatMachineTimestamp(machine.lastSeen))"
    }

    @ViewBuilder
    private var actionsView: some View {
        switch licensing.licenseStatus {
        case .notRegistered, .unknown:
            Button(action: {
                Task {
                    // Auto-generate IDs if not set
                    let serverId = "server_\(UUID().uuidString.prefix(8))"
                    let nodeId = "node_\(UUID().uuidString.prefix(8))"
                    await licensing.registerNode(serverId: serverId, nodeId: nodeId)
                }
            }) {
                Label("Register for License", systemImage: "key.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(licensing.isChecking)

        case .pending:
            Button(action: {
                Task {
                    await licensing.checkStatus()
                }
            }) {
                Label("Check Status", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(licensing.isChecking)

        case .licensed:
            HStack {
                Button(action: {
                    showDeviceManagement = true
                }) {
                    Label("Manage Devices", systemImage: "macbook.and.iphone")
                }
                .buttonStyle(.bordered)

                if canActivateCurrentMachine {
                    Button(action: {
                        showActivateConfirmation = true
                    }) {
                        Label("Activate This Device", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(licensing.isChecking)
                }
            }

        case .deviceLimitReached:
            VStack(spacing: 8) {
                if canActivateCurrentMachine {
                    Button(action: {
                        showActivateConfirmation = true
                    }) {
                        Label("Activate This Device", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(licensing.isChecking)
                }

                if let key = licensing.licenseKey {
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(key, forType: .string)
                    }) {
                        Label("Copy License Key", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                }

                Button(action: {
                    showDeviceManagement = true
                }) {
                    Label("Manage Devices", systemImage: "macbook.and.iphone")
                }
                .buttonStyle(.borderedProminent)

                Button(action: {
                    // Open purchase URL
                    if let url = URL(string: "https://voicelink.devinecreations.net/purchase") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Label("Purchase More Slots", systemImage: "cart")
                }
                .buttonStyle(.bordered)
            }

        default:
            Button(action: {
                Task {
                    await licensing.checkStatus()
                }
            }) {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(licensing.isChecking)
        }
    }

    private func formatLicenseKey(_ key: String) -> String {
        // Show first and last segments only: VL-XXXX-****-****-XXXX
        let parts = key.split(separator: "-")
        guard parts.count == 5 else { return key }
        return "\(parts[0])-\(parts[1])-****-****-\(parts[4])"
    }

    private var currentMachine: LicensingManager.RecentMachine? {
        licensing.currentMachine
    }

    private var currentMachineStatusText: String {
        if let machine = currentMachine {
            return machine.state.replacingOccurrences(of: "_", with: " ").capitalized
        }
        if licensing.activationRequired {
            return "Pending Activation"
        }
        return "Unknown"
    }

    private var canActivateCurrentMachine: Bool {
        licensing.currentMachineNeedsActivation && licensing.remainingSlots > 0
    }

    private func machineRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption.weight(.semibold))
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private func formatMachineTimestamp(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func iconName(for state: String) -> String {
        switch state {
        case "active":
            return "checkmark.circle.fill"
        case "deactivated":
            return "minus.circle.fill"
        case "pending_activation":
            return "clock.arrow.circlepath"
        default:
            return "circle"
        }
    }

    private func iconColor(for state: String) -> Color {
        switch state {
        case "active":
            return .green
        case "deactivated":
            return .orange
        case "pending_activation":
            return .secondary
        default:
            return .secondary
        }
    }

    private func isCurrentDevice(_ device: LicensingManager.ActivatedDevice) -> Bool {
        device.id == licensing.currentDeviceUUID || (device.platform == licensing.currentDevicePlatform && device.name == licensing.currentDeviceName)
    }
}

/// Device management sheet
struct DeviceManagementSheet: View {
    @ObservedObject var licensing: LicensingManager
    @Environment(\.dismiss) var dismiss
    @State private var isDeactivating = false

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text("Manage Devices")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
            }

            Divider()

            // Device list
            if licensing.devices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "desktopcomputer")
                        .font(.largeTitle)
                        .foregroundColor(.gray)
                    Text("No devices activated")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(licensing.devices) { device in
                            DeviceRow(device: device, isCurrentDevice: isCurrentDevice(device)) {
                                Task {
                                    isDeactivating = true
                                    _ = await licensing.deactivateDevice(device.id)
                                    isDeactivating = false
                                }
                            }
                        }
                    }
                }
            }

            // Info
            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                Text("Deactivate a device to use your license on a different device.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 8)

            // Activate new device button
            if licensing.remainingSlots > 0 {
                Button(action: {
                    Task {
                        _ = await licensing.activateDevice()
                    }
                }) {
                    Label("Activate This Device", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(licensing.isChecking)
            }
        }
        .padding()
        .frame(width: 400, height: 350)
        .disabled(isDeactivating)
        .overlay {
            if isDeactivating {
                ProgressView("Deactivating...")
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
            }
        }
    }

    private func isCurrentDevice(_ device: LicensingManager.ActivatedDevice) -> Bool {
        // Compare device ID with current device
        return device.platform == "macOS" && device.name == Host.current().localizedName
    }
}

/// Individual device row
struct DeviceRow: View {
    let device: LicensingManager.ActivatedDevice
    let isCurrentDevice: Bool
    let onDeactivate: () -> Void

    var body: some View {
        HStack {
            Image(systemName: deviceIcon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(device.name)
                        .font(.subheadline.bold())
                    if isCurrentDevice {
                        Text("(This device)")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                Text(device.platform)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Last seen: \(formatDate(device.lastSeen))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: onDeactivate) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("Deactivate this device")
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private var deviceIcon: String {
        switch device.platform.lowercased() {
        case "macos": return "macbook"
        case "ios": return "iphone"
        case "windows": return "pc"
        case "linux": return "desktopcomputer"
        default: return "display"
        }
    }

    private func formatDate(_ dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: dateString) else { return dateString }

        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.unitsStyle = .abbreviated
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Compact license badge for status bar or toolbar
struct LicenseBadge: View {
    @ObservedObject var licensing = LicensingManager.shared

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(4)
    }

    private var statusColor: Color {
        switch licensing.licenseStatus {
        case .licensed: return .green
        case .pending: return .orange
        case .deviceLimitReached: return .yellow
        default: return .gray
        }
    }

    private var statusText: String {
        switch licensing.licenseStatus {
        case .licensed: return "Licensed"
        case .pending: return "Pending"
        case .deviceLimitReached: return "Limit"
        case .notRegistered: return "Unlicensed"
        default: return "..."
        }
    }
}

// Preview disabled for SPM builds
// struct LicensingView_Previews: PreviewProvider {
//     static var previews: some View {
//         LicensingView()
//             .frame(width: 300)
//             .padding()
//     }
// }
