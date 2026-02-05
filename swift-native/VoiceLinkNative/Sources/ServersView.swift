import SwiftUI

// MARK: - Servers Tab View
struct ServersView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var pairingManager = PairingManager.shared
    @State private var selectedTab = 0
    @State private var showPairingSheet = false
    @State private var showTransferSheet = false
    @State private var selectedServerForTransfer: OwnedServer?
    var isSheet: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Header with back button (when not in sheet mode)
            if !isSheet {
                HStack {
                    Button(action: {
                        // Navigate back to main menu
                        NotificationCenter.default.post(name: .goToMainMenu, object: nil)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Text("Server Management")
                        .font(.headline)
                        .foregroundColor(.white)

                    Spacer()

                    // Spacer for balance
                    Color.clear.frame(width: 60)
                }
                .padding()
                .background(Color.black.opacity(0.2))
            }

            // Tab Selector
            HStack(spacing: 0) {
                TabButton(title: "Linked", count: pairingManager.linkedServers.count, isSelected: selectedTab == 0) {
                    selectedTab = 0
                }
                TabButton(title: "Owned", count: pairingManager.ownedServers.count, isSelected: selectedTab == 1) {
                    selectedTab = 1
                }
                TabButton(title: "Discover", isSelected: selectedTab == 2) {
                    selectedTab = 2
                }
            }
            .padding(.horizontal)
            .padding(.top)

            Divider()
                .padding(.top, 10)

            // Content
            ScrollView {
                switch selectedTab {
                case 0:
                    LinkedServersView(showPairingSheet: $showPairingSheet)
                case 1:
                    OwnedServersView(
                        showTransferSheet: $showTransferSheet,
                        selectedServer: $selectedServerForTransfer
                    )
                case 2:
                    DiscoverServersView()
                default:
                    EmptyView()
                }
            }
        }
        .sheet(isPresented: $showPairingSheet) {
            PairingSheetView()
        }
        .sheet(isPresented: $showTransferSheet) {
            if let server = selectedServerForTransfer {
                TransferServerSheet(server: server)
            }
        }
    }
}

// MARK: - Tab Button
struct TabButton: View {
    let title: String
    var count: Int? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                if let count = count, count > 0 {
                    Text("\(count)")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isSelected ? Color.blue : Color.gray.opacity(0.3))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isSelected ? Color.blue.opacity(0.2) : Color.clear)
            .foregroundColor(isSelected ? .blue : .gray)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Linked Servers View
struct LinkedServersView: View {
    @ObservedObject private var pairingManager = PairingManager.shared
    @Binding var showPairingSheet: Bool
    @State private var showUpgradeSheet = false
    @State private var showMembershipDetails = false

    var body: some View {
        VStack(spacing: 15) {
            // Membership Level Info
            MembershipBadgeView(
                showUpgradeSheet: $showUpgradeSheet,
                showDetails: $showMembershipDetails
            )
            .padding(.horizontal)

            // Header
            HStack {
                Text("Linked Servers")
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()

                Button(action: { showPairingSheet = true }) {
                    Label("Link New", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(pairingManager.linkedServers.count >= pairingManager.maxLinkedDevices || pairingManager.trustLevel == .banned)
            }
            .padding(.horizontal)

            if pairingManager.linkedServers.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "link.circle")
                        .font(.system(size: 40))
                        .foregroundColor(.gray)
                    Text("No linked servers")
                        .foregroundColor(.gray)
                    Text("Link a server to control it remotely")
                        .font(.caption)
                        .foregroundColor(.gray.opacity(0.7))
                }
                .padding(.vertical, 40)
            } else {
                ForEach(pairingManager.linkedServers) { server in
                    LinkedServerCard(server: server)
                }
            }
        }
        .padding()
        .sheet(isPresented: $showUpgradeSheet) {
            MembershipUpgradeSheet()
        }
        .sheet(isPresented: $showMembershipDetails) {
            MembershipDetailsSheet()
        }
    }
}

// MARK: - Membership Badge View
struct MembershipBadgeView: View {
    @ObservedObject private var pairingManager = PairingManager.shared
    @Binding var showUpgradeSheet: Bool
    @Binding var showDetails: Bool

    var levelColor: Color {
        switch pairingManager.membershipLevel {
        case .newbie: return .gray
        case .regular: return .blue
        case .outstanding: return .yellow
        }
    }

    var trustColor: Color {
        switch pairingManager.trustLevel {
        case .excellent: return .green
        case .good: return .blue
        case .fair: return .yellow
        case .poor: return .orange
        case .banned: return .red
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            // Level and Trust Row
            HStack {
                // Membership Level
                Button(action: { showDetails = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: pairingManager.membershipLevel.icon)
                            .foregroundColor(levelColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Level \(pairingManager.membershipLevel.rawValue): \(pairingManager.membershipLevel.displayName)")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(levelColor)
                            Text("\(pairingManager.linkedServers.count)/\(pairingManager.maxLinkedDevices) devices")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                // Trust Score
                HStack(spacing: 4) {
                    Image(systemName: pairingManager.trustLevel.icon)
                        .font(.caption)
                        .foregroundColor(trustColor)
                    Text("\(pairingManager.trustScore)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(trustColor)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(trustColor.opacity(0.15))
                .cornerRadius(6)
                .help("Trust Score: \(pairingManager.trustLevel.rawValue)")
            }

            // Progress to next level
            if pairingManager.canUpgradeLevel, let nextLevel = pairingManager.membershipLevel.nextLevel {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption2)
                    Text("Eligible for \(nextLevel.displayName)!")
                        .font(.caption2)
                        .foregroundColor(.green)
                    Spacer()
                }
            } else if let nextLevel = pairingManager.membershipLevel.nextLevel {
                let daysNeeded = max(0, nextLevel.requiredDaysActive - pairingManager.membershipStats.daysActive)
                let hoursNeeded = max(0, nextLevel.requiredRoomHours - Int(pairingManager.membershipStats.totalRoomHours))

                HStack(spacing: 4) {
                    Text("Next level:")
                        .font(.caption2)
                        .foregroundColor(.gray)
                    if daysNeeded > 0 {
                        Text("\(daysNeeded) days")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                    if hoursNeeded > 0 {
                        Text("\(hoursNeeded) hrs")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                    if pairingManager.trustScore < 50 {
                        Text("(trust too low)")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                    Spacer()
                }
            }

            // Support button and wallet
            HStack {
                if pairingManager.paidTier == .none {
                    Button(action: { showUpgradeSheet = true }) {
                        HStack {
                            Image(systemName: "heart.fill")
                            Text("Support VoiceLink")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.pink)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundColor(.orange)
                        Text(pairingManager.paidTier.rawValue)
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }

                Spacer()

                // Wallet badge
                WalletBadgeView()
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(10)
    }
}

// MARK: - Membership Details Sheet
struct MembershipDetailsSheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var pairingManager = PairingManager.shared
    @ObservedObject private var syncManager = SyncManager.shared

    var body: some View {
        VStack(spacing: 20) {
            // Header with sync status
            HStack {
                Image(systemName: pairingManager.membershipLevel.icon)
                    .font(.title)
                    .foregroundColor(levelColor)
                Text(pairingManager.membershipLevel.displayName)
                    .font(.title)
                    .fontWeight(.bold)
                Spacer()
                SyncStatusView()
            }

            Text(pairingManager.membershipLevel.description)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            // Level = Device Tier explanation
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)
                    Text("Your Level = Your Device Tier")
                        .font(.caption)
                        .fontWeight(.semibold)
                }

                Text("Each membership level unlocks more device slots and room access. Level up by being active in the community!")
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)

                // Current device usage
                HStack(spacing: 20) {
                    VStack(spacing: 2) {
                        Text("\(pairingManager.linkedServers.count)")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.blue)
                        Text("Linked")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }

                    Image(systemName: "arrow.right")
                        .foregroundColor(.gray)

                    VStack(spacing: 2) {
                        Text("\(pairingManager.totalMaxDevices)")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.green)
                        Text("Max Allowed")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }

                    if pairingManager.paidTier != .none {
                        VStack(spacing: 2) {
                            Text("+\(pairingManager.paidTier.bonusDevices)")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.orange)
                            Text("Bonus")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }
                }
                .padding(.top, 4)
            }
            .padding()
            .background(Color.blue.opacity(0.1))
            .cornerRadius(10)

            Divider()

            // Stats Grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 15) {
                StatCard(title: "Devices", value: "\(pairingManager.totalMaxDevices)", icon: "laptopcomputer.and.iphone")
                StatCard(title: "Rooms", value: "\(pairingManager.totalMaxRooms)", icon: "person.3.fill")
                StatCard(title: "Days Active", value: "\(pairingManager.membershipStats.daysActive)", icon: "calendar")
                StatCard(title: "Room Hours", value: String(format: "%.1f", pairingManager.membershipStats.totalRoomHours), icon: "clock.fill")
                StatCard(title: "Trust Score", value: "\(pairingManager.trustScore)", icon: pairingManager.trustLevel.icon, color: trustColor)
                StatCard(title: "Complaints", value: "\(pairingManager.complaints)", icon: "exclamationmark.triangle", color: pairingManager.complaints > 0 ? .orange : .green)
            }
            .padding(.horizontal)

            Divider()

            // All Levels with device info
            Text("Levels & Device Tiers")
                .font(.headline)

            ForEach(PairingManager.MembershipLevel.allCases, id: \.rawValue) { level in
                LevelDeviceRow(level: level, isCurrentLevel: level == pairingManager.membershipLevel)
            }

            Spacer(minLength: 20)
        }
        .padding()
        .frame(width: 480, height: 700)

        // Footer
        VStack {
            Divider()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding()
        }
    }

    var levelColor: Color {
        switch pairingManager.membershipLevel {
        case .newbie: return .gray
        case .regular: return .blue
        case .outstanding: return .yellow
        }
    }

    var trustColor: Color {
        switch pairingManager.trustLevel {
        case .excellent: return .green
        case .good: return .blue
        case .fair: return .yellow
        case .poor: return .orange
        case .banned: return .red
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    var color: Color = .blue

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
            Text(title)
                .font(.caption)
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(10)
    }
}

struct LevelRow: View {
    let level: PairingManager.MembershipLevel
    let isCurrentLevel: Bool

    var levelColor: Color {
        switch level {
        case .newbie: return .gray
        case .regular: return .blue
        case .outstanding: return .yellow
        }
    }

    var body: some View {
        HStack {
            Image(systemName: level.icon)
                .foregroundColor(levelColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Level \(level.rawValue): \(level.displayName)")
                    .fontWeight(isCurrentLevel ? .bold : .regular)
                Text("\(level.maxDevices) devices, \(level.maxRooms) rooms")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            Spacer()
            if isCurrentLevel {
                Text("Current")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(levelColor.opacity(0.2))
                    .foregroundColor(levelColor)
                    .cornerRadius(4)
            } else {
                Text("\(level.requiredDaysActive)d / \(level.requiredRoomHours)h")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(isCurrentLevel ? levelColor.opacity(0.1) : Color.clear)
        .cornerRadius(8)
    }
}

// MARK: - Level Device Row (shows level with device tier info)
struct LevelDeviceRow: View {
    let level: PairingManager.MembershipLevel
    let isCurrentLevel: Bool

    var levelColor: Color {
        switch level {
        case .newbie: return .gray
        case .regular: return .blue
        case .outstanding: return .yellow
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Level indicator
            VStack(spacing: 2) {
                Text("L\(level.rawValue)")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(levelColor)
                Image(systemName: level.icon)
                    .font(.caption)
                    .foregroundColor(levelColor)
            }
            .frame(width: 40)

            // Level details
            VStack(alignment: .leading, spacing: 4) {
                Text(level.displayName)
                    .fontWeight(isCurrentLevel ? .bold : .semibold)
                    .foregroundColor(isCurrentLevel ? levelColor : .primary)

                // Device tier info
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "laptopcomputer.and.iphone")
                            .font(.caption2)
                            .foregroundColor(.blue)
                        Text("\(level.maxDevices) device\(level.maxDevices > 1 ? "s" : "")")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "person.3.fill")
                            .font(.caption2)
                            .foregroundColor(.purple)
                        Text("\(level.maxRooms) rooms")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
            }

            Spacer()

            // Requirements or status
            VStack(alignment: .trailing, spacing: 2) {
                if isCurrentLevel {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Current")
                            .fontWeight(.semibold)
                            .foregroundColor(.green)
                    }
                    .font(.caption)
                } else {
                    Text("Requires")
                        .font(.caption2)
                        .foregroundColor(.gray)
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.caption2)
                        Text("\(level.requiredDaysActive)d")
                            .font(.caption)
                    }
                    .foregroundColor(.orange)
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                        Text("\(level.requiredRoomHours)h")
                            .font(.caption)
                    }
                    .foregroundColor(.orange)
                }
            }
        }
        .padding()
        .background(isCurrentLevel ? levelColor.opacity(0.15) : Color.white.opacity(0.05))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isCurrentLevel ? levelColor : Color.clear, lineWidth: 2)
        )
        .padding(.horizontal)
    }
}

// MARK: - Membership Upgrade Sheet
struct MembershipUpgradeSheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var pairingManager = PairingManager.shared
    @ObservedObject private var walletManager = WalletManager.shared
    @State private var paymentAmount: String = ""
    @State private var selectedMethod: PairingManager.PaymentMethod = .ecrypto
    @State private var selectedTier: PairingManager.PaidTier = .supporter
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var showWalletSetup = false
    @State private var useTestCoins = true

    var tierPrice: Double {
        switch selectedTier {
        case .supporter: return 5.0
        case .unlimited: return 20.0
        case .none: return 0
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "heart.circle.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.pink)
                Text("Support VoiceLink")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Pay what you can to unlock bonus features")
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }

            Divider()

            // Wallet Status
            if walletManager.hasWallet {
                HStack {
                    Image(systemName: walletManager.walletStatus.icon)
                        .foregroundColor(walletManager.walletStatus.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("eCrypto Wallet Connected")
                            .font(.caption)
                            .fontWeight(.semibold)
                        HStack(spacing: 8) {
                            Text("Balance: \(String(format: "%.2f", walletManager.walletBalance))")
                                .font(.caption2)
                                .foregroundColor(.green)
                            Text("Test: \(String(format: "%.2f", walletManager.testCoinsBalance))")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }
                    Spacer()
                }
                .padding()
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            } else {
                Button(action: { showWalletSetup = true }) {
                    HStack {
                        Image(systemName: "wallet.pass")
                            .foregroundColor(.gray)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Set up eCrypto Wallet")
                                .font(.caption)
                                .fontWeight(.semibold)
                            Text("Get test coins to try features for free!")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.gray)
                    }
                    .padding()
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            // Current Level
            HStack {
                Text("Your Level:")
                    .foregroundColor(.gray)
                HStack(spacing: 4) {
                    Image(systemName: pairingManager.membershipLevel.icon)
                    Text(pairingManager.membershipLevel.displayName)
                }
                .foregroundColor(membershipColor)
                Spacer()
                Text("\(pairingManager.membershipLevel.maxDevices) devices, \(pairingManager.membershipLevel.maxRooms) rooms")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding()
            .background(Color.white.opacity(0.05))
            .cornerRadius(8)

            // Paid tier options
            VStack(alignment: .leading, spacing: 8) {
                Text("Bonus Tiers")
                    .font(.caption)
                    .foregroundColor(.gray)

                PaidTierOption(
                    tier: .supporter,
                    isSelected: selectedTier == .supporter,
                    action: { selectedTier = .supporter }
                )

                PaidTierOption(
                    tier: .unlimited,
                    isSelected: selectedTier == .unlimited,
                    action: { selectedTier = .unlimited }
                )
            }

            // Payment options
            if walletManager.hasWallet && walletManager.canAfford(amount: tierPrice, useTestCoins: true) {
                // Can pay with wallet
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pay with eCrypto")
                        .font(.caption)
                        .foregroundColor(.gray)

                    Toggle(isOn: $useTestCoins) {
                        HStack {
                            Image(systemName: "testtube.2")
                                .foregroundColor(.orange)
                            Text("Use test coins first")
                                .font(.caption)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Text("Price: \(String(format: "%.2f", tierPrice)) eCrypto")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            } else {
                // Traditional payment
                VStack(alignment: .leading, spacing: 4) {
                    Text("Amount (pay what you can)")
                        .font(.caption)
                        .foregroundColor(.gray)
                    HStack {
                        Text("$")
                            .foregroundColor(.gray)
                        TextField("Any amount", text: $paymentAmount)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Payment Method")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Picker("", selection: $selectedMethod) {
                        ForEach(PairingManager.PaymentMethod.allCases, id: \.self) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            // Note about free levels
            Text("Free levels are earned through activity. Paid tiers add bonus devices/rooms on top of your level.")
                .font(.caption2)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            HStack(spacing: 15) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)

                Button(action: processPayment) {
                    if isProcessing {
                        ProgressView()
                            .controlSize(.small)
                    } else if walletManager.hasWallet && walletManager.canAfford(amount: tierPrice, useTestCoins: useTestCoins) {
                        Label("Pay with eCrypto", systemImage: "wallet.pass.fill")
                    } else {
                        Text("Support")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .disabled(isProcessing || (!walletManager.hasWallet && paymentAmount.isEmpty))
            }
        }
        .padding(30)
        .frame(width: 420, height: 650)
        .sheet(isPresented: $showWalletSetup) {
            WalletSetupView()
        }
    }

    var membershipColor: Color {
        switch pairingManager.membershipLevel {
        case .newbie: return .gray
        case .regular: return .blue
        case .outstanding: return .yellow
        }
    }

    private func processPayment() {
        isProcessing = true
        errorMessage = nil

        // Check if paying with wallet
        if walletManager.hasWallet && walletManager.canAfford(amount: tierPrice, useTestCoins: useTestCoins) {
            let feature = selectedTier == .supporter ? "supporter_tier" : "unlimited_tier"

            walletManager.makePayment(amount: tierPrice, forFeature: feature, useTestCoins: useTestCoins) { success, error in
                if success {
                    // Update paid tier
                    pairingManager.upgradePaidTier(to: selectedTier, paymentAmount: tierPrice, paymentMethod: .ecrypto) { upgradeSuccess, upgradeError in
                        isProcessing = false
                        if upgradeSuccess {
                            // Sync with server
                            syncWithServer()
                            dismiss()
                        } else {
                            errorMessage = upgradeError
                        }
                    }
                } else {
                    isProcessing = false
                    errorMessage = error ?? "Payment failed"
                }
            }
        } else {
            // Traditional payment
            guard let amount = Double(paymentAmount), amount > 0 else {
                errorMessage = "Please enter a valid amount"
                isProcessing = false
                return
            }

            pairingManager.upgradePaidTier(to: selectedTier, paymentAmount: amount, paymentMethod: selectedMethod) { success, error in
                isProcessing = false
                if success {
                    syncWithServer()
                    dismiss()
                } else {
                    errorMessage = error
                }
            }
        }
    }

    private func syncWithServer() {
        // Sync membership data with server
        if let serverURL = pairingManager.linkedServers.first?.url {
            pairingManager.syncMembershipWithServer(serverURL: serverURL) { _ in }
        }
    }
}

struct PaidTierOption: View {
    let tier: PairingManager.PaidTier
    let isSelected: Bool
    let action: () -> Void

    var tierColor: Color {
        switch tier {
        case .none: return .gray
        case .supporter: return .orange
        case .unlimited: return .purple
        }
    }

    var tierIcon: String {
        switch tier {
        case .none: return "circle"
        case .supporter: return "star.fill"
        case .unlimited: return "crown.fill"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? tierColor : .gray)

                Image(systemName: tierIcon)
                    .foregroundColor(tierColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tier.rawValue)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Text("+\(tier.bonusDevices) devices, +\(tier.bonusRooms) rooms")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                Spacer()
            }
            .padding()
            .background(isSelected ? tierColor.opacity(0.1) : Color.white.opacity(0.05))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? tierColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Linked Server Card
struct LinkedServerCard: View {
    let server: LinkedServer
    @ObservedObject private var pairingManager = PairingManager.shared
    @State private var showUnlinkAlert = false

    var body: some View {
        HStack {
            // Status indicator
            Circle()
                .fill(server.isOnline ? Color.green : Color.gray)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.name)
                        .font(.headline)
                        .foregroundColor(.white)

                    // Auth method badge
                    HStack(spacing: 2) {
                        Image(systemName: server.authMethod.icon)
                            .font(.caption2)
                        Text(server.authMethod.displayName)
                            .font(.caption2)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(authMethodColor.opacity(0.2))
                    .foregroundColor(authMethodColor)
                    .cornerRadius(4)
                }

                Text(server.url)
                    .font(.caption)
                    .foregroundColor(.gray)

                HStack(spacing: 4) {
                    Text("Paired \(server.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2)
                        .foregroundColor(.gray.opacity(0.7))

                    if let username = server.authUsername {
                        Text("as \(username)")
                            .font(.caption2)
                            .foregroundColor(.blue.opacity(0.7))
                    }
                }
            }

            Spacer()

            // Actions
            HStack(spacing: 8) {
                Button(action: {
                    // Connect to this server
                    ServerManager.shared.connect(toMain: false)
                }) {
                    Image(systemName: "link")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: { showUnlinkAlert = true }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(10)
        .alert("Unlink Server?", isPresented: $showUnlinkAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Unlink", role: .destructive) {
                pairingManager.unlinkServer(server)
            }
        } message: {
            Text("This will remove access to \(server.name). You can re-link later with a new pairing code.")
        }
    }

    var authMethodColor: Color {
        switch server.authMethod {
        case .pairingCode: return .gray
        case .mastodon: return .purple
        case .email: return .blue
        case .whmcs: return .orange
        }
    }
}

// MARK: - Owned Servers View
struct OwnedServersView: View {
    @ObservedObject private var pairingManager = PairingManager.shared
    @Binding var showTransferSheet: Bool
    @Binding var selectedServer: OwnedServer?

    var body: some View {
        VStack(spacing: 15) {
            HStack {
                Text("Owned Servers")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal)

            if pairingManager.ownedServers.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 40))
                        .foregroundColor(.gray)
                    Text("No owned servers")
                        .foregroundColor(.gray)
                    Text("Mint a server NFT to own and transfer servers")
                        .font(.caption)
                        .foregroundColor(.gray.opacity(0.7))
                }
                .padding(.vertical, 40)
            } else {
                ForEach(pairingManager.ownedServers) { server in
                    OwnedServerCard(server: server) {
                        selectedServer = server
                        showTransferSheet = true
                    }
                }
            }
        }
        .padding()
    }
}

// MARK: - Owned Server Card
struct OwnedServerCard: View {
    let server: OwnedServer
    let onTransfer: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(server.name)
                        .font(.headline)
                        .foregroundColor(.white)

                    if server.nftTokenId != nil {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.blue)
                            .font(.caption)
                }
                }

                Text(server.url)
                    .font(.caption)
                    .foregroundColor(.gray)

                if let mintedAt = server.mintedAt {
                    Text("Minted \(mintedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2)
                        .foregroundColor(.gray.opacity(0.7))
                }
            }

            Spacer()

            // Transfer button
            Button(action: onTransfer) {
                Label("Transfer", systemImage: "arrow.right.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(10)
    }
}

// MARK: - Discover Servers View
struct DiscoverServersView: View {
    @ObservedObject private var pairingManager = PairingManager.shared
    @State private var discoveredServers: [DiscoveredServer] = []
    @State private var isSearching = false

    var body: some View {
        VStack(spacing: 15) {
            HStack {
                Text("Local Network")
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()

                Button(action: discoverServers) {
                    if isSearching {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Scan", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isSearching)
            }
            .padding(.horizontal)

            if discoveredServers.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "wifi")
                        .font(.system(size: 40))
                        .foregroundColor(.gray)
                    Text(isSearching ? "Scanning..." : "No servers found")
                        .foregroundColor(.gray)
                    Text("Tap Scan to find VoiceLink servers on your network")
                        .font(.caption)
                        .foregroundColor(.gray.opacity(0.7))
                }
                .padding(.vertical, 40)
            } else {
                ForEach(discoveredServers) { server in
                    DiscoveredServerCard(server: server)
                }
            }
        }
        .padding()
        .onAppear {
            discoverServers()
        }
    }

    private func discoverServers() {
        isSearching = true
        pairingManager.discoverLocalServers { servers in
            discoveredServers = servers
            isSearching = false
        }
    }
}

// MARK: - Discovered Server Card
struct DiscoveredServerCard: View {
    let server: DiscoveredServer
    @State private var showPairingEntry = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.headline)
                    .foregroundColor(.white)
                Text("Port \(server.port)")
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            Spacer()

            if server.isPaired {
                Text("Paired")
                    .font(.caption)
                    .foregroundColor(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.2))
                    .cornerRadius(4)
            } else {
                Button("Pair") {
                    showPairingEntry = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(10)
        .sheet(isPresented: $showPairingEntry) {
            PairingEntryView(serverURL: server.url)
        }
    }
}

// MARK: - Pairing Sheet View
struct PairingSheetView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var authManager = AuthenticationManager.shared
    @State private var enteredCode = ""
    @State private var serverURL = ""
    @State private var isPairing = false
    @State private var errorMessage: String?
    @State private var selectedAuthMethod: AuthMethod = .pairingCode
    @State private var showMastodonAuth = false
    @State private var showEmailAuth = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Link a Server")
                .font(.title2)
                .fontWeight(.bold)

            // Auth method selector
            VStack(alignment: .leading, spacing: 8) {
                Text("Authentication Method")
                    .font(.caption)
                    .foregroundColor(.gray)

                HStack(spacing: 12) {
                    AuthMethodButton(
                        method: .pairingCode,
                        isSelected: selectedAuthMethod == .pairingCode,
                        isAuthenticated: true
                    ) {
                        selectedAuthMethod = .pairingCode
                    }

                    AuthMethodButton(
                        method: .mastodon,
                        isSelected: selectedAuthMethod == .mastodon,
                        isAuthenticated: authManager.currentUser?.authMethod == .mastodon
                    ) {
                        if authManager.currentUser?.authMethod == .mastodon {
                            selectedAuthMethod = .mastodon
                        } else {
                            showMastodonAuth = true
                        }
                    }

                    AuthMethodButton(
                        method: .email,
                        isSelected: selectedAuthMethod == .email,
                        isAuthenticated: authManager.currentUser?.authMethod == .email
                    ) {
                        if authManager.currentUser?.authMethod == .email {
                            selectedAuthMethod = .email
                        } else {
                            showEmailAuth = true
                        }
                    }
                }
            }
            .padding(.horizontal)

            // Show authenticated user if applicable
            if let user = authManager.currentUser, selectedAuthMethod != .pairingCode {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Signed in as \(user.fullHandle)")
                        .font(.caption)
                        .foregroundColor(.green)
                    Button("Sign out") {
                        authManager.logout()
                        selectedAuthMethod = .pairingCode
                    }
                    .font(.caption)
                    .foregroundColor(.blue)
                }
            }

            Divider()

            Text("Enter the 6-digit pairing code shown on your server")
                .font(.caption)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            // Code entry
            TextField("XXXXXX", text: $enteredCode)
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onChange(of: enteredCode) { newValue in
                    enteredCode = String(newValue.uppercased().prefix(6))
                }

            // Server URL (for remote)
            TextField("Server URL (optional for local)", text: $serverURL)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            HStack(spacing: 15) {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Link Server") {
                    linkServer()
                }
                .buttonStyle(.borderedProminent)
                .disabled(enteredCode.count != 6 || isPairing || (selectedAuthMethod != .pairingCode && authManager.currentUser == nil))
            }
        }
        .padding(30)
        .frame(width: 450, height: 450)
        .sheet(isPresented: $showMastodonAuth) {
            MastodonAuthView(isPresented: $showMastodonAuth) {
                selectedAuthMethod = .mastodon
            }
        }
        .sheet(isPresented: $showEmailAuth) {
            EmailAuthView(isPresented: $showEmailAuth, serverURL: serverURL.isEmpty ? "http://localhost:4004" : serverURL) {
                selectedAuthMethod = .email
            }
        }
    }

    private func linkServer() {
        isPairing = true
        errorMessage = nil

        let url = serverURL.isEmpty ? "http://localhost:4004" : serverURL

        PairingManager.shared.enterPairingCode(enteredCode, serverURL: url, authMethod: selectedAuthMethod) { success, error in
            isPairing = false
            if success {
                dismiss()
            } else {
                errorMessage = error ?? "Pairing failed"
            }
        }
    }
}

// MARK: - Auth Method Button
struct AuthMethodButton: View {
    let method: AuthMethod
    let isSelected: Bool
    let isAuthenticated: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: method.icon)
                    .font(.title2)
                Text(method.displayName)
                    .font(.caption2)
                if isAuthenticated && method != .pairingCode {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundColor(.green)
                }
            }
            .frame(width: 80, height: 60)
            .background(isSelected ? Color.blue.opacity(0.2) : Color.white.opacity(0.05))
            .foregroundColor(isSelected ? .blue : .gray)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pairing Entry View
struct PairingEntryView: View {
    let serverURL: String
    @Environment(\.dismiss) var dismiss
    @State private var enteredCode = ""
    @State private var isPairing = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Enter Pairing Code")
                .font(.title2)
                .fontWeight(.bold)

            Text("Enter the code shown on your server")
                .font(.caption)
                .foregroundColor(.gray)

            TextField("XXXXXX", text: $enteredCode)
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onChange(of: enteredCode) { newValue in
                    enteredCode = String(newValue.uppercased().prefix(6))
                }

            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            HStack(spacing: 15) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)

                Button("Pair") {
                    pair()
                }
                .buttonStyle(.borderedProminent)
                .disabled(enteredCode.count != 6 || isPairing)
            }
        }
        .padding(30)
        .frame(width: 350, height: 250)
    }

    private func pair() {
        isPairing = true
        PairingManager.shared.enterPairingCode(enteredCode, serverURL: serverURL) { success, error in
            isPairing = false
            if success {
                dismiss()
            } else {
                errorMessage = error
            }
        }
    }
}

// MARK: - Transfer Server Sheet
struct TransferServerSheet: View {
    let server: OwnedServer
    @Environment(\.dismiss) var dismiss
    @State private var walletAddress = ""
    @State private var isTransferring = false
    @State private var transferResult: TransferResult?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            if let result = transferResult {
                // Success view
                VStack(spacing: 15) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.green)

                    Text("Transfer Complete!")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Server transferred to:")
                        .foregroundColor(.gray)

                    Text(result.newOwnerWallet)
                        .font(.caption)
                        .foregroundColor(.blue)

                    if let downloadUrl = result.serverDownloadUrl {
                        Link("Download Server", destination: URL(string: downloadUrl)!)
                            .buttonStyle(.borderedProminent)
                    }

                    Button("Done") { dismiss() }
                        .buttonStyle(.bordered)
                }
            } else {
                // Transfer form
                Text("Transfer Server")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Transfer \"\(server.name)\" to another wallet")
                    .foregroundColor(.gray)

                TextField("Recipient Wallet Address", text: $walletAddress)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 350)

                Text("This will transfer ownership including all data. The recipient will receive download links.")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)

                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }

                HStack(spacing: 15) {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.bordered)

                    Button("Transfer") {
                        transfer()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(walletAddress.isEmpty || isTransferring)
                }
            }
        }
        .padding(30)
        .frame(width: 450, height: 350)
    }

    private func transfer() {
        isTransferring = true
        errorMessage = nil

        PairingManager.shared.transferServer(server, toWalletAddress: walletAddress) { success, result in
            isTransferring = false
            if success, let result = result {
                transferResult = result
            } else {
                errorMessage = "Transfer failed. Please try again."
            }
        }
    }
}
