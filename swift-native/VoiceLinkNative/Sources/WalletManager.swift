import Foundation
import SwiftUI

// MARK: - eCrypto Wallet Manager
class WalletManager: ObservableObject {
    static let shared = WalletManager()

    // Wallet state
    @Published var hasWallet: Bool = false
    @Published var walletAddress: String?
    @Published var walletBalance: Double = 0
    @Published var testCoinsBalance: Double = 0
    @Published var isEcryptoInstalled: Bool = false
    @Published var walletStatus: WalletStatus = .notSetup

    // Invite link for eCrypto app
    @Published var inviteLink: String?
    @Published var inviteCoinsAmount: Double = 0

    enum WalletStatus: String {
        case notSetup = "Not Setup"
        case creatingEmbedded = "Creating..."
        case embeddedReady = "Embedded Wallet"
        case externalConnected = "eCrypto Connected"
        case error = "Error"

        var icon: String {
            switch self {
            case .notSetup: return "wallet.pass"
            case .creatingEmbedded: return "arrow.triangle.2.circlepath"
            case .embeddedReady: return "wallet.pass.fill"
            case .externalConnected: return "checkmark.seal.fill"
            case .error: return "exclamationmark.triangle.fill"
            }
        }

        var color: Color {
            switch self {
            case .notSetup: return .gray
            case .creatingEmbedded: return .orange
            case .embeddedReady: return .blue
            case .externalConnected: return .green
            case .error: return .red
            }
        }
    }

    // Server API base URL
    private let ecryptoAPIBase = "https://ecrypto.devinecreations.net/api"

    init() {
        loadWalletData()
        checkEcryptoInstalled()
    }

    // MARK: - Wallet Setup

    func setupWallet(completion: @escaping (Bool, String?) -> Void) {
        // First check if user has auth
        guard let user = AuthenticationManager.shared.currentUser else {
            completion(false, "Please sign in first to set up a wallet")
            return
        }

        walletStatus = .creatingEmbedded

        // Create embedded wallet tied to auth
        createEmbeddedWallet(userId: user.id, authMethod: user.authMethod) { [weak self] success, address, error in
            DispatchQueue.main.async {
                if success, let address = address {
                    self?.walletAddress = address
                    self?.hasWallet = true
                    self?.walletStatus = .embeddedReady
                    self?.saveWalletData()

                    // Request test coins for new wallet
                    self?.requestTestCoins(walletAddress: address) { _, _ in }

                    completion(true, nil)
                } else {
                    self?.walletStatus = .error
                    completion(false, error ?? "Failed to create wallet")
                }
            }
        }
    }

    private func createEmbeddedWallet(userId: String, authMethod: AuthMethod, completion: @escaping (Bool, String?, String?) -> Void) {
        guard let url = URL(string: "\(ecryptoAPIBase)/wallet/create") else {
            completion(false, nil, "Invalid API URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "userId": userId,
            "authMethod": authMethod.rawValue,
            "appId": "voicelink",
            "deviceId": getDeviceId(),
            "embedded": true  // Create as embedded wallet
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let success = json["success"] as? Bool, success,
                  let address = json["address"] as? String else {
                let errorMsg = (try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any])?["error"] as? String
                completion(false, nil, errorMsg ?? error?.localizedDescription ?? "Failed to create wallet")
                return
            }

            completion(true, address, nil)
        }.resume()
    }

    // MARK: - Test Coins

    func requestTestCoins(walletAddress: String, completion: @escaping (Bool, Double) -> Void) {
        guard let url = URL(string: "\(ecryptoAPIBase)/faucet/request") else {
            completion(false, 0)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "walletAddress": walletAddress,
            "appId": "voicelink",
            "reason": "new_user"
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let success = json["success"] as? Bool, success,
                  let amount = json["amount"] as? Double else {
                DispatchQueue.main.async {
                    completion(false, 0)
                }
                return
            }

            DispatchQueue.main.async {
                self?.testCoinsBalance += amount
                self?.saveWalletData()
                completion(true, amount)
            }
        }.resume()
    }

    // MARK: - Invite Links

    func generateInviteLink(hasServer: Bool, completion: @escaping (String?, Double) -> Void) {
        guard let url = URL(string: "\(ecryptoAPIBase)/invite/generate") else {
            completion(nil, 0)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "appId": "voicelink",
            "hasServer": hasServer,
            "walletAddress": walletAddress ?? "",
            "userId": AuthenticationManager.shared.currentUser?.id ?? ""
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let link = json["inviteLink"] as? String else {
                DispatchQueue.main.async {
                    completion(nil, 0)
                }
                return
            }

            let coinsAmount = json["bonusCoins"] as? Double ?? 0

            DispatchQueue.main.async {
                self?.inviteLink = link
                self?.inviteCoinsAmount = coinsAmount
                completion(link, coinsAmount)
            }
        }.resume()
    }

    // MARK: - eCrypto App Integration

    func checkEcryptoInstalled() {
        // Check if eCrypto app is installed via URL scheme
        if let url = URL(string: "ecrypto://") {
            isEcryptoInstalled = NSWorkspace.shared.urlForApplication(toOpen: url) != nil
        }
    }

    func openEcryptoApp() {
        if let url = URL(string: "ecrypto://wallet") {
            NSWorkspace.shared.open(url)
        }
    }

    func openEcryptoInstall() {
        // Open eCrypto download page with invite link
        if let invite = inviteLink, let url = URL(string: invite) {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "https://ecrypto.devinecreations.net/download") {
            NSWorkspace.shared.open(url)
        }
    }

    func connectExternalWallet(completion: @escaping (Bool, String?) -> Void) {
        // Deep link to eCrypto app for connection
        guard isEcryptoInstalled else {
            completion(false, "eCrypto app not installed")
            return
        }

        // Generate connection request
        guard let url = URL(string: "ecrypto://connect?app=voicelink&callback=voicelink://wallet-connected") else {
            completion(false, "Failed to create connection URL")
            return
        }

        NSWorkspace.shared.open(url)

        // The callback will be handled by the app's URL scheme handler
        completion(true, nil)
    }

    func handleWalletCallback(url: URL) {
        // Handle callback from eCrypto app
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else { return }

        if let address = queryItems.first(where: { $0.name == "address" })?.value {
            DispatchQueue.main.async { [weak self] in
                self?.walletAddress = address
                self?.hasWallet = true
                self?.walletStatus = .externalConnected
                self?.saveWalletData()
                self?.refreshBalance()

                NotificationCenter.default.post(name: .walletConnected, object: address)
            }
        }
    }

    // MARK: - Balance

    func refreshBalance() {
        guard let address = walletAddress else { return }

        guard let url = URL(string: "\(ecryptoAPIBase)/wallet/balance?address=\(address)") else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            DispatchQueue.main.async {
                if let balance = json["balance"] as? Double {
                    self?.walletBalance = balance
                }
                if let testBalance = json["testBalance"] as? Double {
                    self?.testCoinsBalance = testBalance
                }
                self?.saveWalletData()
            }
        }.resume()
    }

    // MARK: - Payments

    func canAfford(amount: Double, useTestCoins: Bool = true) -> Bool {
        if useTestCoins {
            return testCoinsBalance >= amount || walletBalance >= amount
        }
        return walletBalance >= amount
    }

    func makePayment(amount: Double, forFeature: String, useTestCoins: Bool = true, completion: @escaping (Bool, String?) -> Void) {
        guard let address = walletAddress else {
            completion(false, "No wallet connected")
            return
        }

        guard canAfford(amount: amount, useTestCoins: useTestCoins) else {
            completion(false, "Insufficient balance")
            return
        }

        guard let url = URL(string: "\(ecryptoAPIBase)/payment/process") else {
            completion(false, "Invalid API URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "fromAddress": address,
            "amount": amount,
            "feature": forFeature,
            "appId": "voicelink",
            "useTestCoins": useTestCoins && testCoinsBalance >= amount
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let success = json["success"] as? Bool else {
                DispatchQueue.main.async {
                    completion(false, error?.localizedDescription ?? "Payment failed")
                }
                return
            }

            DispatchQueue.main.async {
                if success {
                    // Update local balance
                    if let usedTestCoins = json["usedTestCoins"] as? Bool, usedTestCoins {
                        self?.testCoinsBalance -= amount
                    } else {
                        self?.walletBalance -= amount
                    }
                    self?.saveWalletData()
                    completion(true, nil)
                } else {
                    let error = json["error"] as? String ?? "Payment failed"
                    completion(false, error)
                }
            }
        }.resume()
    }

    // MARK: - Feature Prices

    struct FeaturePrice {
        let feature: String
        let price: Double
        let description: String

        static let supporterTier = FeaturePrice(feature: "supporter_tier", price: 5.0, description: "Supporter Tier (+7 devices, +15 rooms)")
        static let unlimitedTier = FeaturePrice(feature: "unlimited_tier", price: 20.0, description: "Unlimited Tier (+97 devices, +90 rooms)")
        static let extraDevice = FeaturePrice(feature: "extra_device", price: 1.0, description: "Extra Device Slot")
        static let extraRoom = FeaturePrice(feature: "extra_room", price: 0.5, description: "Extra Room Slot")
        static let serverHosting = FeaturePrice(feature: "server_hosting", price: 10.0, description: "Server Hosting (monthly)")
    }

    // MARK: - Persistence

    private func loadWalletData() {
        walletAddress = UserDefaults.standard.string(forKey: "walletAddress")
        hasWallet = walletAddress != nil
        walletBalance = UserDefaults.standard.double(forKey: "walletBalance")
        testCoinsBalance = UserDefaults.standard.double(forKey: "testCoinsBalance")

        if let statusRaw = UserDefaults.standard.string(forKey: "walletStatus"),
           let status = WalletStatus(rawValue: statusRaw) {
            walletStatus = status
        } else {
            walletStatus = hasWallet ? .embeddedReady : .notSetup
        }

        inviteLink = UserDefaults.standard.string(forKey: "walletInviteLink")
    }

    private func saveWalletData() {
        UserDefaults.standard.set(walletAddress, forKey: "walletAddress")
        UserDefaults.standard.set(walletBalance, forKey: "walletBalance")
        UserDefaults.standard.set(testCoinsBalance, forKey: "testCoinsBalance")
        UserDefaults.standard.set(walletStatus.rawValue, forKey: "walletStatus")
        UserDefaults.standard.set(inviteLink, forKey: "walletInviteLink")
    }

    private func getDeviceId() -> String {
        if let deviceId = UserDefaults.standard.string(forKey: "deviceId") {
            return deviceId
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: "deviceId")
        return newId
    }

    func disconnectWallet() {
        walletAddress = nil
        hasWallet = false
        walletBalance = 0
        testCoinsBalance = 0
        walletStatus = .notSetup
        saveWalletData()
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let walletConnected = Notification.Name("walletConnected")
    static let walletDisconnected = Notification.Name("walletDisconnected")
}

// MARK: - Wallet Setup View

struct WalletSetupView: View {
    @ObservedObject private var walletManager = WalletManager.shared
    @ObservedObject private var authManager = AuthenticationManager.shared
    @Environment(\.dismiss) var dismiss
    @State private var isSettingUp = false
    @State private var errorMessage: String?
    @State private var showEcryptoInstall = false

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: walletManager.walletStatus.icon)
                    .font(.system(size: 50))
                    .foregroundColor(walletManager.walletStatus.color)

                Text("eCrypto Wallet")
                    .font(.title2)
                    .fontWeight(.bold)

                Text(walletManager.walletStatus.rawValue)
                    .font(.caption)
                    .foregroundColor(walletManager.walletStatus.color)
            }

            Divider()

            if walletManager.hasWallet {
                // Wallet connected view
                WalletConnectedView()
            } else {
                // Setup options
                WalletSetupOptionsView(
                    isSettingUp: $isSettingUp,
                    errorMessage: $errorMessage,
                    showEcryptoInstall: $showEcryptoInstall
                )
            }

            Spacer()

            Button("Done") { dismiss() }
                .buttonStyle(.bordered)
        }
        .padding(30)
        .frame(width: 400, height: 500)
        .sheet(isPresented: $showEcryptoInstall) {
            EcryptoInstallSheet()
        }
    }
}

struct WalletConnectedView: View {
    @ObservedObject private var walletManager = WalletManager.shared

    var body: some View {
        VStack(spacing: 15) {
            // Address
            VStack(alignment: .leading, spacing: 4) {
                Text("Wallet Address")
                    .font(.caption)
                    .foregroundColor(.gray)
                HStack {
                    Text(walletManager.walletAddress ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(action: {
                        if let address = walletManager.walletAddress {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(address, forType: .string)
                        }
                    }) {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding()
            .background(Color.white.opacity(0.05))
            .cornerRadius(8)

            // Balances
            HStack(spacing: 15) {
                BalanceCard(title: "Balance", amount: walletManager.walletBalance, icon: "dollarsign.circle.fill", color: .green)
                BalanceCard(title: "Test Coins", amount: walletManager.testCoinsBalance, icon: "testtube.2", color: .orange)
            }

            // Actions
            HStack(spacing: 10) {
                Button(action: { walletManager.refreshBalance() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)

                if walletManager.isEcryptoInstalled {
                    Button(action: { walletManager.openEcryptoApp() }) {
                        Label("Open eCrypto", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            // Invite link
            if walletManager.inviteLink != nil {
                InviteLinkView()
            }
        }
    }
}

struct BalanceCard: View {
    let title: String
    let amount: Double
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            Text(String(format: "%.2f", amount))
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

struct WalletSetupOptionsView: View {
    @ObservedObject private var walletManager = WalletManager.shared
    @ObservedObject private var authManager = AuthenticationManager.shared
    @Binding var isSettingUp: Bool
    @Binding var errorMessage: String?
    @Binding var showEcryptoInstall: Bool

    var body: some View {
        VStack(spacing: 15) {
            Text("Set up a wallet to unlock premium features and support VoiceLink")
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            // Option 1: Create embedded wallet
            Button(action: createEmbeddedWallet) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Create Embedded Wallet")
                            .fontWeight(.semibold)
                        Text("Quick setup, managed by VoiceLink")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    if isSettingUp {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .disabled(isSettingUp || authManager.currentUser == nil)

            // Option 2: Connect eCrypto app
            Button(action: connectEcrypto) {
                HStack {
                    Image(systemName: "link.circle.fill")
                        .foregroundColor(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connect eCrypto App")
                            .fontWeight(.semibold)
                        Text(walletManager.isEcryptoInstalled ? "Full control with eCrypto" : "Install eCrypto first")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    if !walletManager.isEcryptoInstalled {
                        Text("Install")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.2))
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                    }
                }
                .padding()
                .background(Color.green.opacity(0.1))
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .disabled(isSettingUp)

            if authManager.currentUser == nil {
                HStack {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundColor(.orange)
                    Text("Sign in first to set up a wallet")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            // Benefits list
            VStack(alignment: .leading, spacing: 8) {
                Text("With a wallet you can:")
                    .font(.caption)
                    .foregroundColor(.gray)
                BenefitRow(text: "Unlock bonus devices and rooms")
                BenefitRow(text: "Support VoiceLink development")
                BenefitRow(text: "Get test coins to try features")
                BenefitRow(text: "Transfer server ownership")
            }
            .padding()
            .background(Color.white.opacity(0.05))
            .cornerRadius(10)
        }
    }

    private func createEmbeddedWallet() {
        isSettingUp = true
        errorMessage = nil

        walletManager.setupWallet { success, error in
            isSettingUp = false
            if !success {
                errorMessage = error
            }
        }
    }

    private func connectEcrypto() {
        if walletManager.isEcryptoInstalled {
            walletManager.connectExternalWallet { success, error in
                if !success {
                    errorMessage = error
                }
            }
        } else {
            showEcryptoInstall = true
        }
    }
}

struct BenefitRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
            Text(text)
                .font(.caption)
        }
    }
}

struct InviteLinkView: View {
    @ObservedObject private var walletManager = WalletManager.shared
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Share & Earn")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                if walletManager.inviteCoinsAmount > 0 {
                    Text("+\(Int(walletManager.inviteCoinsAmount)) coins per invite")
                        .font(.caption2)
                        .foregroundColor(.green)
                }
            }

            if let link = walletManager.inviteLink {
                HStack {
                    Text(link)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copied = false
                        }
                    }) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                Button("Generate Invite Link") {
                    let hasServer = !PairingManager.shared.ownedServers.isEmpty
                    walletManager.generateInviteLink(hasServer: hasServer) { _, _ in }
                }
                .font(.caption)
            }
        }
        .padding()
        .background(Color.purple.opacity(0.1))
        .cornerRadius(8)
    }
}

struct EcryptoInstallSheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var walletManager = WalletManager.shared
    @State private var isGeneratingLink = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "app.badge.fill")
                .font(.system(size: 50))
                .foregroundColor(.purple)

            Text("Install eCrypto")
                .font(.title2)
                .fontWeight(.bold)

            Text("Get full wallet control with the eCrypto app. You'll receive test coins to try premium features!")
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            // Benefits
            VStack(alignment: .leading, spacing: 10) {
                InstallBenefitRow(icon: "wallet.pass.fill", text: "Full wallet control & security")
                InstallBenefitRow(icon: "arrow.triangle.2.circlepath", text: "Send & receive eCrypto")
                InstallBenefitRow(icon: "gift.fill", text: "Receive test coins to get started")
                InstallBenefitRow(icon: "link", text: "Connect to all eCrypto-enabled apps")
            }
            .padding()
            .background(Color.white.opacity(0.05))
            .cornerRadius(10)

            if let link = walletManager.inviteLink {
                VStack(spacing: 8) {
                    Text("Your invite link is ready!")
                        .font(.caption)
                        .foregroundColor(.green)
                    if walletManager.inviteCoinsAmount > 0 {
                        Text("Includes \(Int(walletManager.inviteCoinsAmount)) test coins")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
            }

            HStack(spacing: 15) {
                Button("Maybe Later") { dismiss() }
                    .buttonStyle(.bordered)

                Button(action: installEcrypto) {
                    if isGeneratingLink {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Install eCrypto")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(isGeneratingLink)
            }
        }
        .padding(30)
        .frame(width: 400, height: 450)
        .onAppear {
            generateInviteIfNeeded()
        }
    }

    private func generateInviteIfNeeded() {
        if walletManager.inviteLink == nil {
            isGeneratingLink = true
            let hasServer = !PairingManager.shared.ownedServers.isEmpty
            walletManager.generateInviteLink(hasServer: hasServer) { _, _ in
                isGeneratingLink = false
            }
        }
    }

    private func installEcrypto() {
        walletManager.openEcryptoInstall()
        dismiss()
    }
}

struct InstallBenefitRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.purple)
                .frame(width: 20)
            Text(text)
                .font(.callout)
        }
    }
}

// MARK: - Wallet Badge View (for inline display)
struct WalletBadgeView: View {
    @ObservedObject private var walletManager = WalletManager.shared
    @State private var showWalletSetup = false

    var body: some View {
        Button(action: { showWalletSetup = true }) {
            HStack(spacing: 6) {
                Image(systemName: walletManager.walletStatus.icon)
                    .foregroundColor(walletManager.walletStatus.color)

                if walletManager.hasWallet {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(String(format: "%.2f", walletManager.walletBalance + walletManager.testCoinsBalance))
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text("eCrypto")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                } else {
                    Text("Set up wallet")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(walletManager.walletStatus.color.opacity(0.1))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showWalletSetup) {
            WalletSetupView()
        }
    }
}
