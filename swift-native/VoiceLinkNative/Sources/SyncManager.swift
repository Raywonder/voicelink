import Foundation
import SwiftUI

// MARK: - Sync Manager
// Handles syncing all user data with server APIs

class SyncManager: ObservableObject {
    static let shared = SyncManager()

    @Published var isSyncing = false
    @Published var lastSyncDate: Date?
    @Published var syncStatus: SyncStatus = .idle
    @Published var syncErrors: [String] = []

    enum SyncStatus: String {
        case idle = "Ready"
        case syncing = "Syncing..."
        case success = "Synced"
        case partialSuccess = "Partial Sync"
        case failed = "Sync Failed"

        var icon: String {
            switch self {
            case .idle: return "arrow.triangle.2.circlepath"
            case .syncing: return "arrow.triangle.2.circlepath.circle"
            case .success: return "checkmark.circle.fill"
            case .partialSuccess: return "exclamationmark.circle.fill"
            case .failed: return "xmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .idle: return .gray
            case .syncing: return .blue
            case .success: return .green
            case .partialSuccess: return .orange
            case .failed: return .red
            }
        }
    }

    private let pairingManager = PairingManager.shared
    private let walletManager = WalletManager.shared
    private let authManager = AuthenticationManager.shared

    // Server API endpoints
    private var primaryServerURL: String {
        pairingManager.linkedServers.first?.url ?? "https://voicelink.devinecreations.net"
    }

    init() {
        loadLastSyncDate()
        setupAutoSync()
    }

    // MARK: - Full Sync

    func performFullSync(completion: @escaping (Bool) -> Void) {
        guard !isSyncing else {
            completion(false)
            return
        }

        DispatchQueue.main.async {
            self.isSyncing = true
            self.syncStatus = .syncing
            self.syncErrors = []
        }

        let group = DispatchGroup()
        var successCount = 0
        var totalTasks = 4

        // 1. Sync membership data
        group.enter()
        syncMembershipData { success in
            if success { successCount += 1 }
            group.leave()
        }

        // 2. Sync wallet data
        group.enter()
        syncWalletData { success in
            if success { successCount += 1 }
            group.leave()
        }

        // 3. Sync trust score
        group.enter()
        syncTrustScore { success in
            if success { successCount += 1 }
            group.leave()
        }

        // 4. Sync linked devices
        group.enter()
        syncLinkedDevices { success in
            if success { successCount += 1 }
            group.leave()
        }

        group.notify(queue: .main) { [weak self] in
            self?.isSyncing = false
            self?.lastSyncDate = Date()
            self?.saveLastSyncDate()

            if successCount == totalTasks {
                self?.syncStatus = .success
            } else if successCount > 0 {
                self?.syncStatus = .partialSuccess
            } else {
                self?.syncStatus = .failed
            }

            completion(successCount == totalTasks)
        }
    }

    // MARK: - Individual Sync Methods

    func syncMembershipData(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(primaryServerURL)/api/sync/membership") else {
            addError("Invalid membership sync URL")
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuthHeaders(to: &request)

        let body: [String: Any] = [
            "clientId": getClientId(),
            "membershipLevel": pairingManager.membershipLevel.rawValue,
            "paidTier": pairingManager.paidTier.rawValue,
            "stats": [
                "daysActive": pairingManager.membershipStats.daysActive,
                "totalRoomHours": pairingManager.membershipStats.totalRoomHours,
                "roomsCreated": pairingManager.membershipStats.roomsCreated,
                "helpfulActions": pairingManager.membershipStats.helpfulActions,
                "firstJoinDate": ISO8601DateFormatter().string(from: pairingManager.membershipStats.firstJoinDate),
                "lastActivityDate": ISO8601DateFormatter().string(from: pairingManager.membershipStats.lastActivityDate)
            ],
            "trustScore": pairingManager.trustScore,
            "complaints": pairingManager.complaints
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let success = json["success"] as? Bool, success else {
                let errorMsg = error?.localizedDescription ?? "Membership sync failed"
                self?.addError(errorMsg)
                DispatchQueue.main.async { completion(false) }
                return
            }

            // Update local data from server response
            DispatchQueue.main.async { [weak self] in
                // Server may have updated values
                if let serverLevel = json["membershipLevel"] as? Int,
                   let level = PairingManager.MembershipLevel(rawValue: serverLevel) {
                    self?.pairingManager.membershipLevel = level
                }

                if let serverTrust = json["trustScore"] as? Int {
                    self?.pairingManager.trustScore = serverTrust
                }

                if let serverComplaints = json["complaints"] as? Int {
                    self?.pairingManager.complaints = serverComplaints
                }

                completion(true)
            }
        }.resume()
    }

    func syncWalletData(completion: @escaping (Bool) -> Void) {
        guard walletManager.hasWallet,
              let walletAddress = walletManager.walletAddress else {
            // No wallet to sync
            completion(true)
            return
        }

        guard let url = URL(string: "\(primaryServerURL)/api/sync/wallet") else {
            addError("Invalid wallet sync URL")
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuthHeaders(to: &request)

        let body: [String: Any] = [
            "clientId": getClientId(),
            "walletAddress": walletAddress,
            "walletStatus": walletManager.walletStatus.rawValue,
            "localBalance": walletManager.walletBalance,
            "localTestBalance": walletManager.testCoinsBalance
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let success = json["success"] as? Bool, success else {
                let errorMsg = error?.localizedDescription ?? "Wallet sync failed"
                self?.addError(errorMsg)
                DispatchQueue.main.async { completion(false) }
                return
            }

            // Update balances from server
            DispatchQueue.main.async { [weak self] in
                if let balance = json["balance"] as? Double {
                    self?.walletManager.walletBalance = balance
                }
                if let testBalance = json["testBalance"] as? Double {
                    self?.walletManager.testCoinsBalance = testBalance
                }
                completion(true)
            }
        }.resume()
    }

    func syncTrustScore(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(primaryServerURL)/api/sync/trust") else {
            addError("Invalid trust sync URL")
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuthHeaders(to: &request)

        let body: [String: Any] = [
            "clientId": getClientId(),
            "trustScore": pairingManager.trustScore,
            "trustLevel": pairingManager.trustLevel.rawValue,
            "complaints": pairingManager.complaints,
            "membershipLevel": pairingManager.membershipLevel.rawValue
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let success = json["success"] as? Bool, success else {
                let errorMsg = error?.localizedDescription ?? "Trust score sync failed"
                self?.addError(errorMsg)
                DispatchQueue.main.async { completion(false) }
                return
            }

            // Server may have adjusted trust score
            DispatchQueue.main.async { [weak self] in
                if let newTrust = json["trustScore"] as? Int {
                    self?.pairingManager.trustScore = newTrust
                }

                // Check for pending complaints from server
                if let pendingComplaints = json["pendingComplaints"] as? [[String: Any]] {
                    for complaint in pendingComplaints {
                        if let reason = complaint["reason"] as? String,
                           let severityStr = complaint["severity"] as? String,
                           let severity = PairingManager.ComplaintSeverity(rawValue: severityStr) {
                            self?.pairingManager.receiveComplaint(reason: reason, severity: severity)
                        }
                    }
                }

                // Check for trust recovery
                if let trustRecovery = json["trustRecovery"] as? Int, trustRecovery > 0 {
                    self?.pairingManager.recoverTrust(amount: trustRecovery)
                }

                completion(true)
            }
        }.resume()
    }

    func syncLinkedDevices(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(primaryServerURL)/api/sync/devices") else {
            addError("Invalid devices sync URL")
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuthHeaders(to: &request)

        let devicesData = pairingManager.linkedServers.map { server -> [String: Any] in
            var deviceInfo: [String: Any] = [
                "id": server.id,
                "name": server.name,
                "url": server.url,
                "authMethod": server.authMethod.rawValue,
                "pairedAt": ISO8601DateFormatter().string(from: server.pairedAt)
            ]
            if let authUserId = server.authUserId {
                deviceInfo["authUserId"] = authUserId
            }
            if let authUsername = server.authUsername {
                deviceInfo["authUsername"] = authUsername
            }
            return deviceInfo
        }

        let body: [String: Any] = [
            "clientId": getClientId(),
            "devices": devicesData,
            "maxDevices": pairingManager.totalMaxDevices
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let success = json["success"] as? Bool, success else {
                let errorMsg = error?.localizedDescription ?? "Devices sync failed"
                self?.addError(errorMsg)
                DispatchQueue.main.async { completion(false) }
                return
            }

            // Check for revoked devices from server
            DispatchQueue.main.async { [weak self] in
                if let revokedIds = json["revokedDevices"] as? [String] {
                    for revokedId in revokedIds {
                        if let server = self?.pairingManager.linkedServers.first(where: { $0.id == revokedId }) {
                            self?.pairingManager.unlinkServer(server)
                        }
                    }
                }

                completion(true)
            }
        }.resume()
    }

    // MARK: - Auto Sync

    private func setupAutoSync() {
        // Sync on app launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.performFullSync { _ in }
        }

        // Periodic sync every 5 minutes when app is active
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.performFullSync { _ in }
        }

        // Listen for specific events that should trigger sync
        NotificationCenter.default.addObserver(forName: .membershipLevelChanged, object: nil, queue: .main) { [weak self] _ in
            self?.syncMembershipData { _ in }
        }

        NotificationCenter.default.addObserver(forName: .trustScoreChanged, object: nil, queue: .main) { [weak self] _ in
            self?.syncTrustScore { _ in }
        }

        NotificationCenter.default.addObserver(forName: .serverLinked, object: nil, queue: .main) { [weak self] _ in
            self?.syncLinkedDevices { _ in }
        }

        NotificationCenter.default.addObserver(forName: .walletConnected, object: nil, queue: .main) { [weak self] _ in
            self?.syncWalletData { _ in }
        }
    }

    // MARK: - Push Updates (Server -> Client)

    func handleServerPush(_ data: [String: Any]) {
        // Handle various types of server push updates
        if let type = data["type"] as? String {
            switch type {
            case "membership_update":
                handleMembershipPush(data)
            case "trust_update":
                handleTrustPush(data)
            case "wallet_update":
                handleWalletPush(data)
            case "complaint":
                handleComplaintPush(data)
            case "level_upgrade":
                handleLevelUpgradePush(data)
            case "revocation":
                handleRevocationPush(data)
            default:
                print("Unknown push type: \(type)")
            }
        }
    }

    private func handleMembershipPush(_ data: [String: Any]) {
        if let level = data["level"] as? Int,
           let membershipLevel = PairingManager.MembershipLevel(rawValue: level) {
            DispatchQueue.main.async { [weak self] in
                self?.pairingManager.membershipLevel = membershipLevel
            }
        }
    }

    private func handleTrustPush(_ data: [String: Any]) {
        if let trustScore = data["trustScore"] as? Int {
            DispatchQueue.main.async { [weak self] in
                self?.pairingManager.trustScore = trustScore
            }
        }
    }

    private func handleWalletPush(_ data: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            if let balance = data["balance"] as? Double {
                self?.walletManager.walletBalance = balance
            }
            if let testBalance = data["testBalance"] as? Double {
                self?.walletManager.testCoinsBalance = testBalance
            }
        }
    }

    private func handleComplaintPush(_ data: [String: Any]) {
        if let reason = data["reason"] as? String,
           let severityStr = data["severity"] as? String,
           let severity = PairingManager.ComplaintSeverity(rawValue: severityStr) {
            DispatchQueue.main.async { [weak self] in
                self?.pairingManager.receiveComplaint(reason: reason, severity: severity)
            }
        }
    }

    private func handleLevelUpgradePush(_ data: [String: Any]) {
        if let level = data["newLevel"] as? Int,
           let membershipLevel = PairingManager.MembershipLevel(rawValue: level) {
            DispatchQueue.main.async { [weak self] in
                self?.pairingManager.membershipLevel = membershipLevel
                // Show celebration notification
                NotificationCenter.default.post(name: .membershipLevelChanged, object: membershipLevel)
            }
        }
    }

    private func handleRevocationPush(_ data: [String: Any]) {
        if let deviceId = data["deviceId"] as? String {
            DispatchQueue.main.async { [weak self] in
                if let server = self?.pairingManager.linkedServers.first(where: { $0.id == deviceId }) {
                    self?.pairingManager.unlinkServer(server)
                }
            }
        }
    }

    // MARK: - Helpers

    private func addAuthHeaders(to request: inout URLRequest) {
        if let user = authManager.currentUser {
            request.setValue("Bearer \(user.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(user.authMethod.rawValue, forHTTPHeaderField: "X-Auth-Method")
        }
    }

    private func getClientId() -> String {
        if let clientId = UserDefaults.standard.string(forKey: "clientId") {
            return clientId
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: "clientId")
        return newId
    }

    private func addError(_ error: String) {
        DispatchQueue.main.async { [weak self] in
            self?.syncErrors.append(error)
        }
    }

    private func loadLastSyncDate() {
        if let date = UserDefaults.standard.object(forKey: "lastSyncDate") as? Date {
            lastSyncDate = date
        }
    }

    private func saveLastSyncDate() {
        UserDefaults.standard.set(lastSyncDate, forKey: "lastSyncDate")
    }
}

// MARK: - Sync Status View

struct SyncStatusView: View {
    @ObservedObject private var syncManager = SyncManager.shared

    var body: some View {
        HStack(spacing: 6) {
            if syncManager.isSyncing {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: syncManager.syncStatus.icon)
                    .foregroundColor(syncManager.syncStatus.color)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(syncManager.syncStatus.rawValue)
                    .font(.caption2)
                    .foregroundColor(syncManager.syncStatus.color)

                if let lastSync = syncManager.lastSyncDate {
                    Text(lastSync.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(syncManager.syncStatus.color.opacity(0.1))
        .cornerRadius(6)
        .onTapGesture {
            syncManager.performFullSync { _ in }
        }
        .help("Tap to sync now")
    }
}

// MARK: - Sync Button

struct SyncButton: View {
    @ObservedObject private var syncManager = SyncManager.shared

    var body: some View {
        Button(action: {
            syncManager.performFullSync { _ in }
        }) {
            if syncManager.isSyncing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .disabled(syncManager.isSyncing)
    }
}
