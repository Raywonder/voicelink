import Foundation
import SwiftUI

// MARK: - Admin Server Manager
@MainActor
class AdminServerManager: ObservableObject {
    static let shared = AdminServerManager()

    struct ManagementTarget: Identifiable, Hashable {
        enum Kind: String {
            case connected
            case linked
            case owned
            case managed
            case trusted
        }

        let id: String
        let name: String
        let url: String
        let kind: Kind
        let isDefault: Bool

        var kindLabel: String {
            switch kind {
            case .connected:
                return "Current"
            case .linked:
                return "Linked"
            case .owned:
                return "Owned"
            case .managed:
                return "Cluster"
            case .trusted:
                return "Trusted"
            }
        }

        var displayLabel: String {
            "\(name) (\(kindLabel))"
        }
    }

    @Published var isAdmin: Bool = false
    @Published var adminRole: AdminRole = .none
    @Published var managementTargets: [ManagementTarget] = []
    @Published var selectedManagementTargetID: String = "connected"
    @Published var manageAllLinkedServers: Bool = false
    @Published var serverConfig: ServerConfig?
    @Published var advancedServerSettings: AdvancedServerSettings?
    @Published var connectedUsers: [AdminUserInfo] = []
    @Published var recentUserLogins: [AdminRecentUserLogin] = []
    @Published var searchableUsers: [AdminUserSearchEntry] = []
    @Published var serverRooms: [AdminRoomInfo] = []
    @Published var supportSessions: [AdminSupportSessionInfo] = []
    @Published var sharedAuthGroups: [AdminSharedAuthGroup] = []
    @Published var serverStats: ServerStats?
    @Published var availableModules: [AdminModuleInfo] = []
    @Published var serverLogLines: [String] = []
    @Published var serverLogSource: String?
    @Published var serverStatsError: String?
    @Published var schedulerStatus: ServerSchedulerStatus?
    @Published var schedulerTasks: [ServerSchedulerTask] = []
    @Published var schedulerLogs: [ServerSchedulerLogEntry] = []
    @Published var schedulerError: String?
    @Published var mastodonBots: [MastodonBotAccount] = []
    @Published var mastodonBotError: String?
    @Published var authProviderStatus: AuthProviderStatusResponse?
    @Published var authProviderStatusError: String?
    @Published var sharedAuthGroupsError: String?
    @Published var databaseStatus: DatabaseAdminStatus?
    @Published var moduleCategories: [String: String] = [:]
    @Published var modulesLoading: Bool = false
    @Published var moduleActionMessage: String?
    @Published var deploymentManagerStatus: DeploymentManagerStatus?
    @Published var deploymentTransports: [DeploymentTransportInfo] = []
    @Published var deploymentActionMessage: String?
    @Published var serviceActionMessage: String?
    @Published var databaseActionMessage: String?
    @Published var isLoading: Bool = false
    @Published var error: String?

    private var currentServerURL: String = ""
    private var authToken: String?
    private var secureTransportRecoveryTask: Task<Void, Never>?
    private var canManageUsersEffective: Bool { isAdmin || adminRole.canManageUsers }
    private var canManageRoomsEffective: Bool { isAdmin || adminRole.canManageRooms }
    private var canManageConfigEffective: Bool { isAdmin || adminRole.canManageConfig }
    private var selectedManagementTarget: ManagementTarget? {
        managementTargets.first(where: { $0.id == selectedManagementTargetID })
    }

    private func adminEndpointCandidates(preferred: String? = nil) -> [String] {
        let explicitBases = [
            preferred,
            currentServerURL,
            ServerManager.shared.baseURL
        ]

        var candidates: [String] = []
        for base in explicitBases {
            let normalized = APIEndpointResolver.normalize(base ?? "")
            guard !normalized.isEmpty else { continue }
            candidates.append(normalized)
        }

        var expanded: [String] = []
        for candidate in candidates {
            expanded.append(contentsOf: APIEndpointResolver.transportFallbackCandidates(for: candidate))
        }

        if expanded.isEmpty {
            expanded = APIEndpointResolver.remoteMainBaseCandidates(preferred: preferred)
        }

        var seen = Set<String>()
        return expanded.filter { seen.insert($0).inserted }
    }

    enum AdminRole: String, Codable {
        case none = "none"
        case moderator = "moderator"
        case roomManager = "room-manager"
        case admin = "admin"
        case owner = "owner"

        var canManageUsers: Bool {
            self == .moderator || self == .admin || self == .owner
        }

        var canManageRooms: Bool {
            self == .roomManager || self == .admin || self == .owner
        }

        var canManageServer: Bool {
            self == .owner
        }

        var canManageConfig: Bool {
            self == .admin || self == .owner
        }
    }

    func refreshManagementTargets() {
        var targets: [ManagementTarget] = []
        var seen = Set<String>()

        func appendTarget(id: String, name: String, url: String, kind: ManagementTarget.Kind, isDefault: Bool = false) {
            let normalized = APIEndpointResolver.normalize(url)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return }
            targets.append(ManagementTarget(id: id, name: name, url: normalized, kind: kind, isDefault: isDefault))
        }

        if let connected = ServerManager.shared.baseURL, !connected.isEmpty {
            let connectedName = ServerManager.shared.connectedServer.trimmingCharacters(in: .whitespacesAndNewlines)
            appendTarget(
                id: "connected",
                name: connectedName.isEmpty ? "Current Connected Server" : connectedName,
                url: connected,
                kind: .connected,
                isDefault: true
            )
        }

        for server in PairingManager.shared.linkedServers {
            appendTarget(id: "linked:\(server.id)", name: server.name, url: server.url, kind: .linked)
        }

        for server in PairingManager.shared.ownedServers {
            appendTarget(id: "owned:\(server.id)", name: server.name, url: server.url, kind: .owned)
        }

        for server in SettingsManager.shared.managedFederationServers {
            appendTarget(
                id: "managed:\(server.id)",
                name: server.name,
                url: server.url,
                kind: .managed
            )
        }

        for trustedURL in normalizedTrustedServerTargets {
            let fallbackName = URL(string: trustedURL)?.host ?? trustedURL
            appendTarget(
                id: "trusted:\(trustedURL)",
                name: fallbackName,
                url: trustedURL,
                kind: .trusted
            )
        }

        if targets.isEmpty {
            appendTarget(id: "canonical-main", name: "VoiceLink", url: APIEndpointResolver.canonicalMainBase, kind: .connected, isDefault: true)
        }

        managementTargets = targets
        if !managementTargets.contains(where: { $0.id == selectedManagementTargetID }) {
            selectedManagementTargetID = managementTargets.first?.id ?? "connected"
        }
    }

    func selectManagementTarget(_ targetID: String, token: String?) async {
        refreshManagementTargets()
        selectedManagementTargetID = targetID
        guard let target = selectedManagementTarget else { return }
        await checkAdminStatus(serverURL: target.url, token: token)
    }

    var allLinkedScopeSummary: String {
        let count = managementTargets.count
        return "Shared cluster overview across \(count) managed server\(count == 1 ? "" : "s")"
    }

    var canManageMultipleTargets: Bool {
        managementTargets.count > 1
    }

    var selectedManagementTargetName: String {
        selectedManagementTarget?.name ?? "Current Connected Server"
    }

    private var normalizedTrustedServerTargets: [String] {
        let trusted = SettingsManager.shared.visibleManagedFederationServers.map(\.url)
            .map { APIEndpointResolver.normalize($0) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        return trusted.filter { seen.insert($0).inserted }
    }

    private func updateSecureTransportRecoveryState() {
        let normalizedCurrent = APIEndpointResolver.normalize(currentServerURL)
        guard !normalizedCurrent.isEmpty else {
            secureTransportRecoveryTask?.cancel()
            secureTransportRecoveryTask = nil
            return
        }

        let currentScheme = URLComponents(string: normalizedCurrent)?.scheme?.lowercased()
        guard currentScheme == "http",
              let secureCandidate = APIEndpointResolver.preferredSecureCandidate(for: normalizedCurrent),
              secureCandidate != normalizedCurrent else {
            secureTransportRecoveryTask?.cancel()
            secureTransportRecoveryTask = nil
            return
        }

        if let existing = secureTransportRecoveryTask, !existing.isCancelled {
            return
        }

        secureTransportRecoveryTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                guard !Task.isCancelled else { return }
                guard self.currentServerURL == normalizedCurrent else { return }

                var request = URLRequest(url: APIEndpointResolver.url(base: secureCandidate, path: "/api/admin/status")!)
                request.timeoutInterval = 6
                if let token = self.authToken {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        continue
                    }
                    self.currentServerURL = secureCandidate
                    self.secureTransportRecoveryTask?.cancel()
                    self.secureTransportRecoveryTask = nil
                    return
                } catch {
                    continue
                }
            }
        }
    }

    // MARK: - Check Admin Status

    func checkAdminStatus(serverURL: String, token: String?) async {
        self.currentServerURL = APIEndpointResolver.normalize(serverURL)
        self.authToken = token
        refreshManagementTargets()
        let candidates = adminEndpointCandidates(preferred: currentServerURL)
        let fallbackRole = AdminRole(rawValue: AuthenticationManager.shared.currentUser?.role?.lowercased() ?? "")

        for base in candidates {
            guard let url = APIEndpointResolver.url(base: base, path: "/api/admin/status") else {
                continue
            }

            var request = URLRequest(url: url)
            if let token = token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    continue
                }

                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    isAdmin = json["isAdmin"] as? Bool ?? false
                    if let roleStr = json["role"] as? String {
                        adminRole = AdminRole(rawValue: roleStr) ?? .none
                    }
                    let permissions = json["permissions"] as? [String: Any]
                    let serverCanManageRooms = (json["canManageRooms"] as? Bool) ?? (permissions?["rooms"] as? Bool) ?? isAdmin
                    if serverCanManageRooms && !adminRole.canManageRooms {
                        adminRole = .roomManager
                    }
                    if adminRole == .none, let fallbackRole {
                        adminRole = fallbackRole
                        isAdmin = fallbackRole == .admin || fallbackRole == .owner
                    }
                    currentServerURL = base
                    updateSecureTransportRecoveryState()
                    return
                }
            } catch {
                continue
            }
        }

        if let fallbackRole {
            adminRole = fallbackRole
            isAdmin = fallbackRole == .admin || fallbackRole == .owner
        } else {
            isAdmin = false
            adminRole = .none
        }
    }

    // MARK: - Fetch Server Config

    func fetchServerConfig() async {
        guard canManageConfigEffective else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        let candidates = adminEndpointCandidates(preferred: effectiveServerURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for base in candidates {
            guard let url = APIEndpointResolver.url(base: base, path: "/api/config") else {
                continue
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            if let token = authToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    continue
                }
                if httpResponse.statusCode == 200 {
                    serverConfig = try decoder.decode(ServerConfig.self, from: data)
                    CopyPartyManager.shared.applyServerFileSharingConfig(serverConfig?.fileSharing)
                    mergeBuiltInModules()
                    currentServerURL = base
                    updateSecureTransportRecoveryState()
                    error = nil
                    return
                }
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    error = "Server config access denied (\(httpResponse.statusCode))."
                }
            } catch {
                self.error = "Failed to fetch server config: \(error.localizedDescription)"
            }
        }

        if serverConfig == nil {
            error = error ?? "Failed to fetch server config"
        }
    }

    func fetchAdvancedServerSettings() async {
        guard canManageConfigEffective else { return }

        let candidates = adminEndpointCandidates(preferred: effectiveServerURL)
        let decoder = JSONDecoder()

        for base in candidates {
            guard let url = APIEndpointResolver.url(base: base, path: "/api/admin/settings") else {
                continue
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            if let token = authToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    continue
                }
                if httpResponse.statusCode == 200 {
                    advancedServerSettings = try decoder.decode(AdvancedServerSettings.self, from: data)
                    currentServerURL = base
                    updateSecureTransportRecoveryState()
                    error = nil
                    return
                }
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    // Treat advanced settings auth denial as non-fatal; core admin tabs can still work.
                    if advancedServerSettings == nil {
                        advancedServerSettings = AdvancedServerSettings(
                            maxRooms: serverConfig?.maxRooms ?? 100,
                            welcomeMessage: serverConfig?.welcomeMessage,
                            lobbyWelcomeMessage: serverConfig?.lobbyWelcomeMessage,
                            requireAuth: serverConfig?.requireAuth ?? false,
                            database: DatabaseConfig()
                        )
                    }
                    currentServerURL = base
                    updateSecureTransportRecoveryState()
                    return
                }
            } catch {
                self.error = "Failed to fetch advanced server settings: \(error.localizedDescription)"
            }
        }

        if advancedServerSettings == nil {
            error = error ?? "Failed to fetch advanced server settings"
        }
    }

    // MARK: - Update Server Config

    func updateServerConfig(_ config: ServerConfig) async -> Bool {
        guard canManageConfigEffective else { return false }
        let candidates = adminEndpointCandidates(preferred: effectiveServerURL)

        for base in candidates {
            guard let url = APIEndpointResolver.url(base: base, path: "/api/config") else {
                continue
            }

            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.timeoutInterval = 6
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token = authToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

            do {
                let encoder = JSONEncoder()
                request.httpBody = try encoder.encode(config)

                let (_, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    continue
                }

                currentServerURL = base
                updateSecureTransportRecoveryState()
                serverConfig = config
                NotificationCenter.default.post(name: .serverConfigurationChanged, object: config)
                return true
            } catch {
                self.error = error.localizedDescription
                continue
            }
        }

        error = error ?? "Failed to update server config"
        return false
    }

    func updateAdvancedServerSettings(_ settings: AdvancedServerSettings) async -> Bool {
        guard canManageConfigEffective else { return false }
        let candidates = adminEndpointCandidates(preferred: effectiveServerURL)

        for base in candidates {
            guard let url = APIEndpointResolver.url(base: base, path: "/api/admin/settings") else {
                continue
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 6
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token = authToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

            do {
                let encoder = JSONEncoder()
                request.httpBody = try encoder.encode(settings)

                let (_, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    continue
                }

                currentServerURL = base
                updateSecureTransportRecoveryState()
                advancedServerSettings = settings
                if let current = serverConfig {
                    serverConfig = current.with(
                        maxRooms: settings.maxRooms,
                        lobbyWelcomeMessage: settings.lobbyWelcomeMessage,
                        welcomeMessage: settings.welcomeMessage,
                        requireAuth: settings.requireAuth
                    )
                }
                NotificationCenter.default.post(name: .serverConfigurationChanged, object: serverConfig)
                return true
            } catch {
                self.error = "Failed to update advanced server settings: \(error.localizedDescription)"
                continue
            }
        }

        error = error ?? "Failed to update advanced server settings"
        return false
    }

    func fetchDatabaseStatus() async {
        guard canManageConfigEffective else { return }
        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/admin/database/status") else {
            error = "Invalid database status URL"
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

        do {
            let decoder = JSONDecoder()
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                error = "Failed to fetch database status"
                return
            }
            guard httpResponse.statusCode == 200 else {
                let message = (try? decoder.decode(DatabaseActionResponse.self, from: data).error) ?? "Failed to fetch database status (\(httpResponse.statusCode))"
                error = message
                return
            }
            let payload = try decoder.decode(DatabaseStatusEnvelope.self, from: data)
            databaseStatus = payload.status
            databaseActionMessage = nil
        } catch {
            self.error = "Failed to fetch database status: \(error.localizedDescription)"
        }
    }

    func initializeDatabase() async -> Bool {
        await runDatabaseAction(path: "/api/admin/database/initialize", successPrefix: "Database initialized")
    }

    func migrateDefaultDataToDatabase() async -> Bool {
        await runDatabaseAction(path: "/api/admin/database/migrate-defaults", successPrefix: "Default data migrated")
    }

    @discardableResult
    private func runDatabaseAction(path: String, successPrefix: String) async -> Bool {
        guard canManageConfigEffective else { return false }
        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: path) else {
            error = "Invalid database action URL"
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

        do {
            let decoder = JSONDecoder()
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                error = "Database action failed"
                return false
            }
            let payload = try? decoder.decode(DatabaseActionResponse.self, from: data)
            guard httpResponse.statusCode == 200, let payload else {
                error = payload?.error ?? "Database action failed (\(httpResponse.statusCode))"
                return false
            }
            databaseStatus = payload.status ?? databaseStatus
            if let message = payload.message, !message.isEmpty {
                databaseActionMessage = message
            } else {
                databaseActionMessage = successPrefix
            }
            return true
        } catch {
            self.error = "Database action failed: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - User Management

    func fetchConnectedUsers() async {
        guard canManageUsersEffective else { return }
        let candidates = adminEndpointCandidates(preferred: effectiveServerURL)
        let decoder = JSONDecoder()

        for base in candidates {
            guard let url = APIEndpointResolver.url(base: base, path: "/api/admin/users") else {
                continue
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            if let token = authToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    continue
                }

                connectedUsers = try decoder.decode([AdminUserInfo].self, from: data)
                currentServerURL = base
                return
            } catch {
                continue
            }
        }
    }

    func fetchRecentUserLogins(limit: Int = 50) async {
        guard canManageUsersEffective else { return }
        let candidates = adminEndpointCandidates(preferred: effectiveServerURL)
        let decoder = JSONDecoder()

        for base in candidates {
            guard let url = APIEndpointResolver.url(base: base, path: "/api/admin/users/recent-logins?limit=\(limit)") else {
                continue
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            if let token = authToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    continue
                }

                let envelope = try decoder.decode(AdminRecentUserLoginEnvelope.self, from: data)
                recentUserLogins = envelope.users
                currentServerURL = base
                return
            } catch {
                continue
            }
        }
    }

    func searchUsers(query: String = "", limit: Int = 100) async {
        guard canManageUsersEffective else { return }
        let candidates = adminEndpointCandidates(preferred: effectiveServerURL)
        let decoder = JSONDecoder()
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        for base in candidates {
            guard let url = APIEndpointResolver.url(base: base, path: "/api/admin/users/search?q=\(encodedQuery)&limit=\(limit)") else {
                continue
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            if let token = authToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    continue
                }

                let envelope = try decoder.decode(AdminUserSearchEnvelope.self, from: data)
                searchableUsers = envelope.users
                currentServerURL = base
                return
            } catch {
                continue
            }
        }
    }

    func fetchSharedAuthGroups() async {
        guard canManageUsersEffective else { return }
        let candidates = adminEndpointCandidates(preferred: effectiveServerURL)
        let decoder = JSONDecoder()

        for base in candidates {
            guard let url = APIEndpointResolver.url(base: base, path: "/api/admin/shared-auth/groups") else {
                continue
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            if let token = authToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    continue
                }
                let envelope = try decoder.decode(AdminSharedAuthGroupsEnvelope.self, from: data)
                sharedAuthGroups = envelope.groups
                sharedAuthGroupsError = nil
                currentServerURL = base
                return
            } catch {
                sharedAuthGroupsError = error.localizedDescription
                continue
            }
        }
    }

    func kickUser(_ userId: String, reason: String? = nil) async -> Bool {
        guard canManageUsersEffective else { return false }

        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/admin/users/\(userId)/kick") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

        let body: [String: Any] = ["reason": reason ?? "Kicked by admin"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func banUser(_ userId: String, reason: String?, duration: Int?) async -> Bool {
        guard canManageUsersEffective else { return false }

        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/admin/users/\(userId)/ban") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

        var body: [String: Any] = ["reason": reason ?? "Banned by admin"]
        if let duration = duration {
            body["duration"] = duration
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func setUserTransmitEnabled(_ userId: String, enabled: Bool) async -> Bool {
        guard canManageUsersEffective else { return false }
        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/admin/users/\(userId)/transmit") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["enabled": enabled])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func updateUserRole(
        _ userId: String,
        role: String,
        accountId: String? = nil,
        email: String? = nil,
        username: String? = nil,
        displayName: String? = nil
    ) async -> Bool {
        guard canManageUsersEffective else { return false }
        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/admin/users/\(userId)/role") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

        let body: [String: Any] = [
            "role": role,
            "accountId": accountId ?? "",
            "email": email ?? "",
            "username": username ?? "",
            "displayName": displayName ?? ""
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func revokeUserRole(
        _ userId: String,
        accountId: String? = nil,
        email: String? = nil,
        username: String? = nil
    ) async -> Bool {
        guard canManageUsersEffective else { return false }
        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/admin/users/\(userId)/role") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

        let body: [String: Any] = [
            "accountId": accountId ?? "",
            "email": email ?? "",
            "username": username ?? ""
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Room Management

    func fetchRooms() async {
        guard canManageRoomsEffective else { return }

        guard var components = URLComponents(string: effectiveServerURL) else {
            return
        }
        components.path = "/api/rooms"
        components.queryItems = [
            URLQueryItem(name: "source", value: "app"),
            URLQueryItem(name: "includeHidden", value: "true")
        ]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return
            }

            let resolvedSource = Self.sourceLabel(from: effectiveServerURL)
            let parsedRooms = try await Task.detached(priority: .userInitiated) {
                guard let rawRooms = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    return [AdminRoomInfo]()
                }

                return Self.deduplicateAdminRooms(
                    rawRooms.map { Self.adminRoom(from: $0, defaultSource: resolvedSource) }
                )
                    .sorted {
                        let lhsActive = $0.userCount > 0
                        let rhsActive = $1.userCount > 0
                        if lhsActive != rhsActive {
                            return lhsActive && !rhsActive
                        }
                        if $0.userCount != $1.userCount {
                            return $0.userCount > $1.userCount
                        }
                        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
            }.value

            serverRooms = parsedRooms
        } catch {
            print("Failed to fetch rooms: \(error)")
        }
    }

    func deleteRoom(_ roomId: String) async -> Bool {
        guard canManageRoomsEffective else { return false }

        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/rooms/\(roomId)") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 6
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                serverRooms.removeAll { $0.id == roomId }
                return true
            }
            if let http = response as? HTTPURLResponse {
                error = "Delete room failed (\(http.statusCode)): \(String(data: data, encoding: .utf8) ?? "Unknown error")"
            }
            return false
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func updateRoom(_ room: AdminRoomInfo) async -> Bool {
        guard canManageRoomsEffective else { return false }

        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/rooms/\(room.id)") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

        let payload: [String: Any] = [
            "name": room.name,
            "description": room.description,
            "welcomeMessage": room.welcomeMessage ?? "",
            "maxUsers": room.maxUsers,
            "visibility": room.visibility ?? (room.isPrivate ? "private" : "public"),
            "accessType": room.accessType ?? (room.isPrivate ? "private" : "public"),
            "roomType": room.accessType ?? (room.isPrivate ? "private" : "public"),
            "enabled": room.enabled ?? true,
            "locked": room.locked ?? false,
            "recordingAllowed": room.recordingAllowed ?? (serverConfig?.recordingEnabled ?? false),
            "accessPin": room.accessPin ?? "",
            "hidden": room.hidden ?? false,
            "isDefault": room.isDefault ?? false
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                if let idx = serverRooms.firstIndex(where: { $0.id == room.id }) {
                    serverRooms[idx] = room
                }
                let mergedCurrentRoom = ServerManager.shared.rooms.first(where: { $0.id == room.id }).map(Room.init(from:)) ?? Room(
                    id: room.id,
                    name: room.name,
                    description: room.description,
                    welcomeMessage: room.welcomeMessage,
                    userCount: room.userCount,
                    isPrivate: (room.visibility ?? (room.isPrivate ? "private" : "public")).localizedCaseInsensitiveContains("private"),
                    isLocked: room.locked ?? false,
                    recordingAllowed: room.recordingAllowed ?? (serverConfig?.recordingEnabled ?? false),
                    maxUsers: room.maxUsers,
                    createdBy: room.createdBy,
                    createdAt: room.createdAt,
                    hostServerName: room.hostServerName,
                    hostServerOwner: room.hostServerOwner
                )
                NotificationCenter.default.post(
                    name: .roomConfigurationChanged,
                    object: mergedCurrentRoom
                )
                return true
            }
            if let http = response as? HTTPURLResponse {
                error = "Update room failed (\(http.statusCode)): \(String(data: data, encoding: .utf8) ?? "Unknown error")"
            }
            return false
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - Support Sessions

    func fetchSupportSessions() async {
        guard canManageUsersEffective else { return }

        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/support/sessions") else {
            error = "Invalid support sessions URL"
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return }
            guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    supportSessions = []
                    return
                }
                error = "Failed to fetch support sessions (\(httpResponse.statusCode))"
                return
            }

            let sessions = try await Task.detached(priority: .userInitiated) {
                guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rawSessions = payload["sessions"] as? [[String: Any]] else {
                    return [AdminSupportSessionInfo]()
                }
                return rawSessions.compactMap(Self.adminSupportSession(from:))
                    .sorted {
                        let lhs = $0.updatedAt ?? $0.createdAt ?? .distantPast
                        let rhs = $1.updatedAt ?? $1.createdAt ?? .distantPast
                        return lhs > rhs
                    }
            }.value

            supportSessions = sessions
        } catch {
            supportSessions = []
        }
    }

    func pickupSupportSession(_ sessionId: String) async -> Bool {
        guard canManageUsersEffective else { return false }
        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/support/sessions/\(sessionId)/pickup") else {
            error = "Invalid support pickup URL"
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")
        request.httpBody = Data("{}".utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            guard httpResponse.statusCode == 200 else {
                error = "Unable to pick up support session (\(httpResponse.statusCode)): \(String(data: data, encoding: .utf8) ?? "Unknown error")"
                return false
            }
            await fetchSupportSessions()
            return true
        } catch {
            self.error = "Unable to pick up support session: \(error.localizedDescription)"
            return false
        }
    }

    func closeSupportSession(_ sessionId: String, reason: String = "completed") async -> Bool {
        guard canManageUsersEffective else { return false }
        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/support/sessions/\(sessionId)/end") else {
            error = "Invalid support close URL"
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "reason": reason,
            "status": "closed"
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            guard httpResponse.statusCode == 200 else {
                error = "Unable to close support session (\(httpResponse.statusCode)): \(String(data: data, encoding: .utf8) ?? "Unknown error")"
                return false
            }
            await fetchSupportSessions()
            await fetchRooms()
            return true
        } catch {
            self.error = "Unable to close support session: \(error.localizedDescription)"
            return false
        }
    }

    func createOrAttachSupportTicket(for sessionId: String) async -> Bool {
        guard canManageUsersEffective else { return false }
        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/support/sessions/\(sessionId)/attach-whmcs-ticket") else {
            error = "Invalid support ticket URL"
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")
        request.httpBody = Data("{}".utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            guard httpResponse.statusCode == 200 else {
                error = "Unable to attach support ticket (\(httpResponse.statusCode)): \(String(data: data, encoding: .utf8) ?? "Unknown error")"
                return false
            }
            await fetchSupportSessions()
            return true
        } catch {
            self.error = "Unable to attach support ticket: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Server Stats

    func fetchServerStats() async {
        let candidates = adminEndpointCandidates(preferred: effectiveServerURL)
        let decoder = JSONDecoder()
        var lastFailure: String?

        for base in candidates {
            guard let url = APIEndpointResolver.url(base: base, path: "/api/admin/stats") else {
                continue
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            if let token = authToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    lastFailure = "The server stats response was invalid."
                    continue
                }
                if httpResponse.statusCode == 200 {
                    serverStats = try decoder.decode(ServerStats.self, from: data)
                    serverStatsError = nil
                    currentServerURL = base
                    return
                }
                if let fallbackStats = await fetchPublicServerStats(from: base) {
                    serverStats = fallbackStats
                    serverStatsError = nil
                    currentServerURL = base
                    return
                }
                lastFailure = "VoiceLink could not load server stats from the connected server (\(httpResponse.statusCode))."
            } catch {
                if let fallbackStats = await fetchPublicServerStats(from: base) {
                    serverStats = fallbackStats
                    serverStatsError = nil
                    currentServerURL = base
                    return
                }
                lastFailure = "VoiceLink could not load server stats from the connected server yet. \(error.localizedDescription)"
                continue
            }
        }

        serverStats = nil
        serverStatsError = lastFailure ?? "VoiceLink could not load server stats from the connected server right now."
    }

    private func fetchPublicServerStats(from base: String) async -> ServerStats? {
        guard var components = URLComponents(string: base) else { return nil }
        components.path = "/api/rooms"
        components.queryItems = [URLQueryItem(name: "source", value: "app")]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let rawRooms = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return nil
            }

            let rooms = rawRooms.map { Self.adminRoom(from: $0, defaultSource: Self.sourceLabel(from: base)) }
            let activeUsers = rooms.reduce(0) { $0 + $1.userCount }
            let activeRooms = rooms.filter { $0.userCount > 0 }.count
            return ServerStats(
                totalUsers: activeUsers,
                activeUsers: activeUsers,
                totalRooms: rooms.count,
                activeRooms: activeRooms,
                uptime: 0,
                peakUsers: activeUsers,
                messagesPerMinute: 0,
                bandwidthUsage: 0
            )
        } catch {
            return nil
        }
    }

    func fetchServerLogs() async {
        guard canManageConfigEffective else { return }
        let candidates = adminEndpointCandidates(preferred: effectiveServerURL)
        var lastFailure: String?

        for base in candidates {
            guard let url = APIEndpointResolver.url(base: base, path: "/api/admin/logs") else {
                continue
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            if let token = authToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    lastFailure = "The server log response was invalid."
                    continue
                }
                guard httpResponse.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    lastFailure = "Server logs returned HTTP \(httpResponse.statusCode)."
                    continue
                }
                serverLogSource = json["source"] as? String
                serverLogLines = (json["lines"] as? [String]) ?? []
                currentServerURL = base
                updateSecureTransportRecoveryState()
                error = nil
                return
            } catch {
                lastFailure = "Failed to fetch server logs from \(base): \(error.localizedDescription)"
            }
        }

        self.error = lastFailure ?? "Failed to fetch server logs from the selected server."
    }

    // MARK: - Server Scheduler

    func fetchServerSchedulerStatus() async {
        guard canManageConfigEffective else { return }

        let candidates = adminEndpointCandidates(preferred: effectiveServerURL)
        var lastFailure: String?

        for base in candidates {
            guard let url = APIEndpointResolver.url(base: base, path: "/api/admin/scheduler/status") else {
                continue
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            if let token = authToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    lastFailure = "The scheduler response was invalid."
                    continue
                }
                guard httpResponse.statusCode == 200 else {
                    lastFailure = "Unable to load scheduler status (\(httpResponse.statusCode))."
                    continue
                }

                let decoded = try JSONDecoder().decode(ServerSchedulerStatusResponse.self, from: data)
                schedulerStatus = decoded.status
                schedulerTasks = decoded.tasks
                schedulerLogs = decoded.logs
                schedulerError = nil
                currentServerURL = base
                return
            } catch {
                lastFailure = "Unable to load scheduler status: \(error.localizedDescription)"
            }
        }

        schedulerStatus = nil
        schedulerTasks = []
        schedulerLogs = []
        schedulerError = lastFailure ?? "Unable to load scheduler status right now."
    }

    func runServerSchedulerTask(_ taskId: String) async -> Bool {
        guard canManageConfigEffective else { return false }
        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/admin/scheduler/tasks/\(taskId)/run") else {
            schedulerError = "Invalid scheduler task URL."
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Data("{}".utf8)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                schedulerError = "Unable to run scheduler task right now."
                return false
            }
            await fetchServerSchedulerStatus()
            return true
        } catch {
            schedulerError = "Unable to run scheduler task: \(error.localizedDescription)"
            return false
        }
    }

    func updateServerSchedulerTask(_ taskId: String, enabled: Bool? = nil, intervalSeconds: Int? = nil) async -> Bool {
        guard canManageConfigEffective else { return false }
        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/admin/scheduler/tasks/\(taskId)") else {
            schedulerError = "Invalid scheduler task URL."
            return false
        }

        var payload: [String: Any] = [:]
        if let enabled {
            payload["enabled"] = enabled
        }
        if let intervalSeconds {
            payload["intervalSeconds"] = intervalSeconds
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                schedulerError = "Unable to update scheduler task right now."
                return false
            }
            await fetchServerSchedulerStatus()
            return true
        } catch {
            schedulerError = "Unable to update scheduler task: \(error.localizedDescription)"
            return false
        }
    }

    func restartAllAIEndpoints(services: [String] = []) async -> Bool {
        guard canManageConfigEffective else { return false }
        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/admin/services/restart-all-ai") else {
            serviceActionMessage = "Invalid AI endpoint restart URL."
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["services": services])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["success"] as? Bool) == true else {
                serviceActionMessage = "Unable to restart AI endpoints right now."
                return false
            }

            let serviceList = json["services"] as? [String] ?? services
            let message = json["message"] as? String ?? "Restart requested."
            if serviceList.isEmpty {
                serviceActionMessage = message
            } else {
                serviceActionMessage = "\(message) \(serviceList.joined(separator: ", "))"
            }
            currentServerURL = effectiveServerURL
            return true
        } catch {
            serviceActionMessage = "Unable to restart AI endpoints: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Mastodon Bot Accounts

    func fetchMastodonBots() async {
        guard canManageConfigEffective else { return }

        let candidates = adminEndpointCandidates(preferred: effectiveServerURL)
        var lastFailure: String?

        for base in candidates {
            guard let url = APIEndpointResolver.url(base: base, path: "/api/mastodon/bots") else {
                continue
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            if let token = authToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    lastFailure = "Unable to load Mastodon bot accounts."
                    continue
                }

                mastodonBots = try JSONDecoder().decode([MastodonBotAccount].self, from: data)
                mastodonBotError = nil
                currentServerURL = base
                return
            } catch {
                lastFailure = "Unable to load Mastodon bot accounts: \(error.localizedDescription)"
            }
        }

        mastodonBots = []
        mastodonBotError = lastFailure
    }

    func registerMastodonBot(instanceURL: String, accessToken: String) async -> Bool {
        guard canManageConfigEffective else { return false }
        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/mastodon/bots") else {
            mastodonBotError = "Invalid Mastodon bot registration URL."
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "instanceUrl": instanceURL,
            "accessToken": accessToken
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                mastodonBotError = "The Mastodon bot response was invalid."
                return false
            }
            guard httpResponse.statusCode == 200 else {
                mastodonBotError = String(data: data, encoding: .utf8) ?? "Failed to register Mastodon bot."
                return false
            }

            mastodonBotError = nil
            await fetchMastodonBots()
            return true
        } catch {
            mastodonBotError = "Failed to register Mastodon bot: \(error.localizedDescription)"
            return false
        }
    }

    func removeMastodonBot(instanceURL: String) async -> Bool {
        guard canManageConfigEffective else { return false }
        let encoded = instanceURL.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? instanceURL
        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/mastodon/bots/\(encoded)") else {
            mastodonBotError = "Invalid Mastodon bot removal URL."
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 8
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                mastodonBotError = "Failed to remove Mastodon bot."
                return false
            }

            mastodonBotError = nil
            await fetchMastodonBots()
            return true
        } catch {
            mastodonBotError = "Failed to remove Mastodon bot: \(error.localizedDescription)"
            return false
        }
    }

    func fetchAuthProviderStatus() async {
        guard canManageConfigEffective else { return }

        let candidates = adminEndpointCandidates(preferred: effectiveServerURL)
        var lastFailure: String?

        for base in candidates {
            guard let url = APIEndpointResolver.url(base: base, path: "/api/admin/auth-status") else {
                continue
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            if let token = authToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    lastFailure = "Unable to load auth provider status."
                    continue
                }

                authProviderStatus = try JSONDecoder().decode(AuthProviderStatusResponse.self, from: data)
                authProviderStatusError = nil
                currentServerURL = base
                return
            } catch {
                lastFailure = "Unable to load auth provider status: \(error.localizedDescription)"
            }
        }

        authProviderStatus = nil
        authProviderStatusError = lastFailure
    }

    // MARK: - Background Streams

    struct StreamProbeResult: Codable, Identifiable {
        var id: String
        var name: String
        var streamUrl: String
        var type: String?
        var genre: String?
        var bitrate: Int?
        var listeners: Int?
        var title: String?
        var artist: String?
        var sourceUrl: String?
    }

    func updateBackgroundStreams(_ streams: [BackgroundStreamConfig]) async -> Bool {
        guard canManageConfigEffective else { return false }
        var config = serverConfig ?? ServerConfig()
        let existing = config.backgroundStreams ?? BackgroundStreamsConfig(enabled: !streams.isEmpty, streams: [], defaultVolume: 60, fadeInDuration: 1500)
        config.backgroundStreams = BackgroundStreamsConfig(
            enabled: !streams.isEmpty,
            streams: streams,
            defaultVolume: existing.defaultVolume,
            fadeInDuration: existing.fadeInDuration,
            autoRefreshEnabled: existing.autoRefreshEnabled,
            autoReconnectDropped: existing.autoReconnectDropped,
            metadataRefreshIntervalSeconds: existing.metadataRefreshIntervalSeconds,
            preJoinEnabled: existing.preJoinEnabled,
            preJoinStreamId: existing.preJoinStreamId
        )
        let success = await updateServerConfig(config)
        if success {
            serverConfig = config
            NotificationCenter.default.post(name: .serverConfigurationChanged, object: config)
        }
        return success
    }

    func updateBackgroundStreamsConfig(_ config: BackgroundStreamsConfig) async -> Bool {
        guard canManageConfigEffective else { return false }
        var serverConfig = self.serverConfig ?? ServerConfig()
        serverConfig.backgroundStreams = config
        let success = await updateServerConfig(serverConfig)
        if success {
            self.serverConfig = serverConfig
            NotificationCenter.default.post(name: .serverConfigurationChanged, object: serverConfig)
        }
        return success
    }

    func probeBackgroundStreams(input: String) async -> [StreamProbeResult] {
        guard canManageConfigEffective else { return [] }
        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/admin/background-streams/probe") else {
            return []
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: ["input": input])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return []
            }
            let decoder = JSONDecoder()
            return try decoder.decode([StreamProbeResult].self, from: data)
        } catch {
            return []
        }
    }

    // MARK: - API Sync Settings

    func fetchAPISyncSettings() async -> APISyncSettings? {
        guard canManageConfigEffective else { return nil }

        let candidates = adminEndpointCandidates(preferred: effectiveServerURL)
        let decoder = JSONDecoder()

        for base in candidates {
            guard let url = APIEndpointResolver.url(base: base, path: "/api/admin/api-sync") else {
                continue
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            if let token = authToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    continue
                }
                if httpResponse.statusCode == 200 {
                    currentServerURL = base
                    return try decoder.decode(APISyncSettings.self, from: data)
                }
            } catch {
                continue
            }
        }

        return nil
    }

    func updateAPISyncSettings(_ settings: APISyncSettings) async -> Bool {
        guard canManageConfigEffective else { return false }

        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/admin/api-sync") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

        let encoder = JSONEncoder()
        request.httpBody = try? encoder.encode(settings)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Federation Settings

    func fetchFederationSettings() async -> FederationSettings? {
        guard canManageConfigEffective else { return nil }

        let candidates = adminEndpointCandidates(preferred: effectiveServerURL)

        for base in candidates {
            guard let url = APIEndpointResolver.url(base: base, path: "/api/federation/status") else {
                continue
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            if let token = authToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    continue
                }

                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                currentServerURL = base
                return normalizedFederationSettings(FederationSettings(
                    enabled: json["enabled"] as? Bool ?? false,
                    allowIncoming: json["allowIncoming"] as? Bool ?? true,
                    allowOutgoing: json["allowOutgoing"] as? Bool ?? true,
                    trustedServers: json["trustedServers"] as? [String] ?? [],
                    blockedServers: [],
                    autoAcceptTrusted: false,
                    requireApproval: json["roomApprovalRequired"] as? Bool ?? false,
                    maintenanceModeEnabled: json["maintenanceModeEnabled"] as? Bool ?? false,
                    autoHandoffEnabled: json["autoHandoffEnabled"] as? Bool ?? false,
                    handoffTargetServer: json["handoffTargetServer"] as? String
                ))
            } catch {
                continue
            }
        }

        return nil
    }

    func updateFederationSettings(_ settings: FederationSettings) async -> Bool {
        guard canManageConfigEffective else { return false }
        let normalizedSettings = normalizedFederationSettings(settings)
        let candidates = adminEndpointCandidates(preferred: effectiveServerURL)

        for base in candidates {
            guard let url = APIEndpointResolver.url(base: base, path: "/api/federation/settings") else {
                continue
            }

            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.timeoutInterval = 6
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token = authToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

            let payload: [String: Any] = [
                "enabled": normalizedSettings.enabled,
                "mode": (normalizedSettings.allowIncoming && normalizedSettings.allowOutgoing) ? "mesh" : (normalizedSettings.allowOutgoing ? "spoke" : "standalone"),
                "globalFederation": normalizedSettings.enabled,
                "roomApprovalRequired": normalizedSettings.requireApproval,
                "trustedServers": normalizedSettings.trustedServers,
                "allowIncoming": normalizedSettings.allowIncoming,
                "allowOutgoing": normalizedSettings.allowOutgoing,
                "maintenanceModeEnabled": normalizedSettings.maintenanceModeEnabled,
                "autoHandoffEnabled": normalizedSettings.autoHandoffEnabled,
                "handoffTargetServer": normalizedSettings.handoffTargetServer as Any
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    currentServerURL = base
                    updateSecureTransportRecoveryState()
                    return true
                }
            } catch {
                continue
            }
        }
        return false
    }

    // MARK: - Deployment Manager

    func fetchDeploymentManagerStatus() async -> DeploymentManagerStatus? {
        guard canManageConfigEffective else { return nil }
        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/modules/deployment-manager/status") else {
            error = "Invalid deployment manager status URL"
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }
            guard httpResponse.statusCode == 200 else {
                error = "Failed to fetch deployment manager status"
                return nil
            }
            let decoder = JSONDecoder()
            let status = try decoder.decode(DeploymentManagerStatus.self, from: data)
            deploymentManagerStatus = status
            return status
        } catch {
            self.error = "Failed to fetch deployment manager status: \(error.localizedDescription)"
            return nil
        }
    }

    func fetchDeploymentTransports() async -> [DeploymentTransportInfo] {
        guard canManageConfigEffective else { return [] }
        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/modules/deployment-manager/transports") else {
            error = "Invalid deployment manager transports URL"
            return []
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                error = "Failed to fetch deployment transports"
                return []
            }
            let decoder = JSONDecoder()
            let payload = try decoder.decode(DeploymentTransportsResponse.self, from: data)
            deploymentTransports = payload.transports
            return payload.transports
        } catch {
            self.error = "Failed to fetch deployment transports: \(error.localizedDescription)"
            return []
        }
    }

    func buildDeploymentPackage(_ requestBody: DeploymentPackageRequest) async -> DeploymentPackageResponse? {
        guard let response: DeploymentPackageResponse = await postDeploymentRequest(
            path: "/api/modules/deployment-manager/package",
            body: requestBody,
            successMessage: "Deployment package generated on the server."
        ) else {
            return nil
        }
        return response
    }

    func runDeployment(_ requestBody: DeploymentExecutionRequest) async -> DeploymentExecutionResponse? {
        guard let response: DeploymentExecutionResponse = await postDeploymentRequest(
            path: "/api/modules/deployment-manager/deploy",
            body: requestBody,
            successMessage: "Deployment completed successfully."
        ) else {
            return nil
        }
        return response
    }

    func emailDeploymentOwner(_ requestBody: DeploymentOwnerEmailRequest) async -> Bool {
        let response: DeploymentSimpleResponse? = await postDeploymentRequest(
            path: "/api/modules/deployment-manager/email-owner",
            body: requestBody,
            successMessage: "Deployment owner email sent."
        )
        return response?.success == true
    }

    private func postDeploymentRequest<T: Decodable, Body: Encodable>(
        path: String,
        body: Body,
        successMessage: String
    ) async -> T? {
        guard canManageConfigEffective else { return nil }
        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: path) else {
            error = "Invalid deployment manager URL"
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

        do {
            let encoder = JSONEncoder()
            request.httpBody = try encoder.encode(body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let serverError = payload["error"] as? String {
                    error = serverError
                } else {
                    error = "Deployment request failed (\(httpResponse.statusCode))"
                }
                return nil
            }

            let decoder = JSONDecoder()
            let decoded = try decoder.decode(T.self, from: data)
            deploymentActionMessage = successMessage
            return decoded
        } catch {
            self.error = "Deployment request failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Helper

    func refreshModulesCenter() async {
        await fetchAvailableModules()
        await fetchInstalledModules()
    }

    func fetchAvailableModules(sortBy: String = "recommended", category: String? = nil) async {
        modulesLoading = true
        defer { modulesLoading = false }
        let cacheBust = String(Int(Date().timeIntervalSince1970))

        var components = URLComponents(string: "\(effectiveServerURL)/api/modules")
        components?.queryItems = [
            URLQueryItem(name: "sortBy", value: sortBy),
            URLQueryItem(name: "cb", value: cacheBust)
        ]
        if let category, !category.isEmpty {
            components?.queryItems?.append(URLQueryItem(name: "category", value: category))
        }

        guard let url = components?.url else {
            error = "Invalid server URL"
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                error = "Failed to fetch module catalog"
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                error = "Invalid module catalog response"
                return
            }

            if let categories = json["categories"] as? [String: String] {
                moduleCategories = categories
            } else if let categories = json["categories"] as? [String: Any] {
                moduleCategories = categories.compactMapValues { "\($0)" }
            }

            let modulesArray = (json["modules"] as? [[String: Any]]) ?? []
            let installedState = Dictionary(uniqueKeysWithValues: availableModules.map { ($0.id, $0) })
            availableModules = modulesArray.compactMap { Self.parseModuleInfo(from: $0) }.map { module in
                guard let existing = installedState[module.id] else { return module }
                var merged = module
                merged.installed = existing.installed
                merged.enabled = existing.enabled
                return merged
            }
            mergeBuiltInModules()
        } catch {
            self.error = "Failed to fetch module catalog: \(error.localizedDescription)"
        }
    }

    func fetchInstalledModules() async {
        guard var components = URLComponents(string: "\(effectiveServerURL)/api/modules/installed") else {
            error = "Invalid server URL"
            return
        }
        components.queryItems = [URLQueryItem(name: "cb", value: String(Int(Date().timeIntervalSince1970)))]
        guard let url = components.url else {
            error = "Invalid server URL"
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return
            }

            let modulesArray = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            let installedById = Dictionary(uniqueKeysWithValues: modulesArray.compactMap { dict -> (String, AdminModuleInfo)? in
                guard let parsed = Self.parseModuleInfo(from: dict) else { return nil }
                return (parsed.id, parsed)
            })

            if availableModules.isEmpty {
                availableModules = Array(installedById.values).sorted { $0.name < $1.name }
            } else {
                var mergedById = Dictionary(uniqueKeysWithValues: availableModules.map { ($0.id, $0) })
                for (moduleId, installed) in installedById {
                    if var existing = mergedById[moduleId] {
                        existing.installed = installed.installed
                        existing.enabled = installed.enabled
                        mergedById[moduleId] = existing
                    } else {
                        mergedById[moduleId] = installed
                    }
                }
                availableModules = Array(mergedById.values).sorted { lhs, rhs in
                    if lhs.installed != rhs.installed {
                        return lhs.installed && !rhs.installed
                    }
                    if lhs.recommended != rhs.recommended {
                        return lhs.recommended && !rhs.recommended
                    }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            }
            mergeBuiltInModules()
        } catch {
            self.error = "Failed to fetch installed modules: \(error.localizedDescription)"
        }
    }

    func installModule(_ moduleId: String) async -> Bool {
        let ok = await postModuleAction(moduleId: moduleId, endpoint: "install", body: [:])
        if ok {
            moduleActionMessage = "Installed module: \(moduleId)"
            await refreshModulesCenter()
        }
        return ok
    }

    func uninstallModule(_ moduleId: String) async -> Bool {
        let ok = await postModuleAction(moduleId: moduleId, endpoint: "uninstall", body: [:])
        if ok {
            moduleActionMessage = "Uninstalled module: \(moduleId)"
            await refreshModulesCenter()
        }
        return ok
    }

    func setModuleEnabled(_ moduleId: String, enabled: Bool) async -> Bool {
        let ok = await postModuleAction(moduleId: moduleId, endpoint: "toggle", body: ["enabled": enabled])
        if ok {
            moduleActionMessage = enabled ? "Enabled module: \(moduleId)" : "Disabled module: \(moduleId)"
            await refreshModulesCenter()
        }
        return ok
    }

    // Uses config endpoint as update/reapply operation from the desktop UI.
    func updateModule(_ moduleId: String, enabled: Bool) async -> Bool {
        guard let url = URL(string: "\(effectiveServerURL)/api/modules/\(moduleId)/config") else {
            error = "Invalid server URL"
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["enabled": enabled], options: [])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            let ok = (200...299).contains(httpResponse.statusCode)
            if ok {
                moduleActionMessage = "Updated module: \(moduleId)"
                await refreshModulesCenter()
            } else {
                error = "Failed to update module \(moduleId)"
            }
            return ok
        } catch {
            self.error = "Failed to update module \(moduleId): \(error.localizedDescription)"
            return false
        }
    }

    func installAllMissingModules() async -> Bool {
        await postBulkModuleAction(
            endpoint: "install-missing",
            successPrefix: "Installed missing modules"
        )
    }

    func updateAllModules() async -> Bool {
        await postBulkModuleAction(
            endpoint: "update-all",
            successPrefix: "Updated installed modules"
        )
    }

    func saveModuleConfig(_ moduleId: String, jsonText: String) async -> Bool {
        guard let url = URL(string: "\(effectiveServerURL)/api/modules/\(moduleId)/config") else {
            error = "Invalid server URL"
            return false
        }

        let payloadObject: Any
        do {
            guard let data = jsonText.data(using: .utf8) else {
                error = "Module config must be valid UTF-8 text"
                return false
            }
            payloadObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            self.error = "Module config is not valid JSON: \(error.localizedDescription)"
            return false
        }

        guard let payload = payloadObject as? [String: Any] else {
            error = "Module config must be a JSON object"
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload, options: [])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                error = "Invalid server response"
                return false
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                error = "Failed to save module config (\(httpResponse.statusCode))"
                return false
            }

            moduleActionMessage = "Saved module config: \(moduleId)"
            await refreshModulesCenter()
            return true
        } catch {
            self.error = "Failed to save module config for \(moduleId): \(error.localizedDescription)"
            return false
        }
    }

    func fetchVoiceLinkFlexPBXHoldMediaStatus() async -> VoiceLinkFlexPBXHoldMediaStatus? {
        guard let url = URL(string: "\(effectiveServerURL)/api/modules/voicelink-flexpbx/hold-media") else {
            error = "Invalid server URL"
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                error = "Failed to fetch FlexPBX hold media status"
                return nil
            }
            return try JSONDecoder().decode(VoiceLinkFlexPBXHoldMediaEnvelope.self, from: data).holdMedia
        } catch {
            self.error = "Failed to fetch FlexPBX hold media status: \(error.localizedDescription)"
            return nil
        }
    }

    func saveVoiceLinkFlexPBXHoldMedia(_ holdMedia: VoiceLinkFlexPBXHoldMediaStatus) async -> Bool {
        guard let url = URL(string: "\(effectiveServerURL)/api/modules/voicelink-flexpbx/hold-media") else {
            error = "Invalid server URL"
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

        let payload = holdMedia.asRequestPayload
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload, options: [])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                error = "Failed to save FlexPBX hold media settings"
                return false
            }
            moduleActionMessage = "Saved FlexPBX hold media settings"
            return true
        } catch {
            self.error = "Failed to save FlexPBX hold media settings: \(error.localizedDescription)"
            return false
        }
    }

    func syncVoiceLinkFlexPBXHoldMedia() async -> VoiceLinkFlexPBXHoldMediaSyncResult? {
        guard let url = URL(string: "\(effectiveServerURL)/api/modules/voicelink-flexpbx/hold-media/sync") else {
            error = "Invalid server URL"
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")
        request.httpBody = Data("{}".utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                error = "Failed to sync FlexPBX hold media"
                return nil
            }
            let result = try JSONDecoder().decode(VoiceLinkFlexPBXHoldMediaSyncResult.self, from: data)
            moduleActionMessage = result.success ? "Synced FlexPBX hold media" : "FlexPBX hold media sync returned warnings"
            return result
        } catch {
            self.error = "Failed to sync FlexPBX hold media: \(error.localizedDescription)"
            return nil
        }
    }

    func fetchSSLManagerStatus() async -> ServerSSLManagerConfig? {
        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/admin/ssl-manager/status") else {
            error = "Invalid SSL manager URL"
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                error = "Failed to fetch SSL manager status"
                return nil
            }
            let envelope = try JSONDecoder().decode(ServerSSLManagerEnvelope.self, from: data)
            if var current = serverConfig {
                current.sslManager = envelope.sslManager
                serverConfig = current
            }
            mergeBuiltInModules()
            return envelope.sslManager
        } catch {
            self.error = "Failed to fetch SSL manager status: \(error.localizedDescription)"
            return nil
        }
    }

    func updateSSLManager(_ sslManager: ServerSSLManagerConfig) async -> Bool {
        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/admin/ssl-manager") else {
            error = "Invalid SSL manager URL"
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

        do {
            request.httpBody = try JSONEncoder().encode(ServerSSLManagerUpdateRequest(sslManager: sslManager))
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                error = "Failed to update SSL manager"
                return false
            }
            let envelope = try JSONDecoder().decode(ServerSSLManagerEnvelope.self, from: data)
            if var current = serverConfig {
                current.sslManager = envelope.sslManager
                serverConfig = current
            }
            moduleActionMessage = "Saved SSL manager settings"
            mergeBuiltInModules()
            return true
        } catch {
            self.error = "Failed to update SSL manager: \(error.localizedDescription)"
            return false
        }
    }

    func autodetectSSLManager() async -> Bool {
        await performSSLManagerAction(path: "/api/admin/ssl-manager/autodetect", successPrefix: "Auto-detected SSL settings")
    }

    func renewSSLManagerCertificates() async -> Bool {
        await performSSLManagerAction(path: "/api/admin/ssl-manager/renew", successPrefix: "SSL renew completed")
    }

    func reloadSSLManagerServices() async -> Bool {
        await performSSLManagerAction(path: "/api/admin/ssl-manager/reload", successPrefix: "Web server reload completed")
    }

    func fetchConfigBackups() async -> [ServerConfigBackup] {
        guard let url = URL(string: "\(effectiveServerURL)/api/config/backups") else {
            error = "Invalid server URL"
            return []
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                error = "Failed to fetch server backups"
                return []
            }
            return try JSONDecoder().decode(ServerConfigBackupsEnvelope.self, from: data).backups
        } catch {
            self.error = "Failed to fetch server backups: \(error.localizedDescription)"
            return []
        }
    }

    func createConfigBackup(label: String?, includeFederationSnapshot: Bool, includeLinkedServers: Bool) async -> Bool {
        guard let url = URL(string: "\(effectiveServerURL)/api/config/backup") else {
            error = "Invalid server URL"
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

        let payload: [String: Any] = [
            "label": label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            "includeFederationSnapshot": includeFederationSnapshot,
            "includeLinkedServers": includeLinkedServers
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload, options: [])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                error = "Failed to create server backup"
                return false
            }
            if let result = try? JSONDecoder().decode(ServerConfigBackupCreateResponse.self, from: data) {
                moduleActionMessage = "Created backup: \(result.filename)"
            } else {
                moduleActionMessage = "Created server backup"
            }
            return true
        } catch {
            self.error = "Failed to create server backup: \(error.localizedDescription)"
            return false
        }
    }

    func restoreConfigBackup(filename: String) async -> Bool {
        guard let url = URL(string: "\(effectiveServerURL)/api/config/restore") else {
            error = "Invalid server URL"
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["filename": filename], options: [])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                error = "Failed to restore server backup"
                return false
            }
            moduleActionMessage = "Restored backup: \(filename)"
            await fetchServerConfig()
            return true
        } catch {
            self.error = "Failed to restore server backup: \(error.localizedDescription)"
            return false
        }
    }

    private func postBulkModuleAction(endpoint: String, successPrefix: String) async -> Bool {
        let targets: [ManagementTarget]
        if manageAllLinkedServers {
            refreshManagementTargets()
            targets = managementTargets
        } else if let selected = selectedManagementTarget {
            targets = [selected]
        } else {
            targets = [
                ManagementTarget(
                    id: "current",
                    name: selectedManagementTargetName,
                    url: effectiveServerURL,
                    kind: .connected,
                    isDefault: true
                )
            ]
        }

        var changedTotal = 0
        var successCount = 0
        var failures: [String] = []

        for target in targets {
            let result = await postBulkModuleActionToTarget(
                endpoint: endpoint,
                target: target,
                applyToCluster: manageAllLinkedServers
            )
            if result.ok {
                successCount += 1
                changedTotal += result.changed
            } else {
                failures.append("\(target.name): \(result.error)")
            }
        }

        await refreshModulesCenter()
        if failures.isEmpty {
            let scope = manageAllLinkedServers && targets.count > 1
                ? " across \(targets.count) managed servers"
                : ""
            moduleActionMessage = changedTotal > 0
                ? "\(successPrefix)\(scope): \(changedTotal) changed."
                : "\(successPrefix)\(scope): already current."
            return true
        }

        if successCount > 0 {
            moduleActionMessage = "\(successPrefix): \(successCount) server\(successCount == 1 ? "" : "s") updated, \(failures.count) failed."
            error = failures.first
            return false
        }

        error = failures.first ?? "Bulk module action failed"
        return false
    }

    private func postBulkModuleActionToTarget(
        endpoint: String,
        target: ManagementTarget,
        applyToCluster: Bool
    ) async -> (ok: Bool, changed: Int, error: String) {
        let targetBase = preferredAdminBase(for: target.url)
        guard let url = URL(string: "\(targetBase)/api/modules/bulk/\(endpoint)") else {
            error = "Invalid server URL"
            return (false, 0, "Invalid server URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "applyToCluster": applyToCluster
        ], options: [])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return (false, 0, "Invalid module action response")
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let serverError = payload["error"] as? String {
                    return (false, 0, serverError)
                } else {
                    return (false, 0, "Bulk module action failed (\(httpResponse.statusCode))")
                }
            }

            guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (true, 0, "")
            }

            if let success = payload["success"] as? Bool, success == false {
                let failures = (payload["failed"] as? [[String: Any]]) ?? []
                let firstFailure = failures.compactMap { $0["error"] as? String }.first
                return (false, 0, firstFailure ?? (payload["error"] as? String) ?? "Bulk module action failed")
            }

            let installedCount = (payload["installed"] as? [Any])?.count ?? 0
            let updatedCount = (payload["updated"] as? [Any])?.count ?? 0
            let changedCount = max(installedCount, updatedCount)
            return (true, changedCount, "")
        } catch {
            return (false, 0, error.localizedDescription)
        }
    }

    private func postModuleAction(moduleId: String, endpoint: String, body: [String: Any]) async -> Bool {
        guard let url = URL(string: "\(effectiveServerURL)/api/modules/\(moduleId)/\(endpoint)") else {
            error = "Invalid server URL"
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                error = "Module action failed (\(httpResponse.statusCode))"
                return false
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let success = json["success"] as? Bool, success == false {
                let message = (json["error"] as? String) ?? "Unknown module action error"
                error = message
                return false
            }
            return true
        } catch {
            self.error = "Module action failed: \(error.localizedDescription)"
            return false
        }
    }

    private var effectiveServerURL: String {
        if !currentServerURL.isEmpty {
            return preferredAdminBase(for: currentServerURL)
        }
        if let selected = selectedManagementTarget?.url, !selected.isEmpty {
            return preferredAdminBase(for: selected)
        }
        if let connected = ServerManager.shared.baseURL, !connected.isEmpty {
            return preferredAdminBase(for: connected)
        }
        return APIEndpointResolver.canonicalMainBase
    }

    var resolvedServerURL: String {
        effectiveServerURL
    }

    nonisolated private static func sourceLabel(from base: String) -> String {
        if let host = URL(string: base)?.host?.trimmingCharacters(in: .whitespacesAndNewlines),
           !host.isEmpty {
            return host
        }
        return APIEndpointResolver.normalize(base)
    }

    private func preferredAdminBase(for base: String) -> String {
        APIEndpointResolver.preferredSecureCandidate(for: base) ?? APIEndpointResolver.normalize(base)
    }

    private var managedDefaultTrustedServers: [String] {
        let urls = SettingsManager.shared.visibleManagedFederationServers.map(\.url)
        var seen = Set<String>()
        return urls
            .map { APIEndpointResolver.normalize($0) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func normalizedTrustedServers(_ urls: [String]) -> [String] {
        var seen = Set<String>()
        return urls
            .map { APIEndpointResolver.normalize($0) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func normalizedFederationSettings(_ settings: FederationSettings) -> FederationSettings {
        var normalized = settings
        normalized.trustedServers = normalizedTrustedServers(settings.trustedServers)
        normalized.blockedServers = normalizedTrustedServers(settings.blockedServers)

        if normalized.enabled && normalized.trustedServers.isEmpty {
            normalized.trustedServers = managedDefaultTrustedServers
        }

        if let handoff = normalized.handoffTargetServer {
            let trimmed = APIEndpointResolver.normalize(handoff)
            normalized.handoffTargetServer = trimmed.isEmpty ? nil : trimmed
        }

        return normalized
    }

    nonisolated private static func adminRoom(from dict: [String: Any], defaultSource: String) -> AdminRoomInfo {
        let usersValue: Int = {
            if let count = dict["users"] as? Int { return count }
            if let count = dict["userCount"] as? Int { return count }
            if let users = dict["users"] as? [[String: Any]] { return users.count }
            return 0
        }()

        let resolvedHostServerName: String? = {
            let keys = [
                "hostServerName",
                "serverDisplayName",
                "serverTitle",
                "serverName",
                "instanceName",
                "nodeName"
            ]
            for key in keys {
                if let value = dict[key] as? String {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            return nil
        }()

        let resolvedServerSource: String = {
            let keys = ["serverSource", "sourceServer", "serverHost", "serverDomain"]
            for key in keys {
                if let value = dict[key] as? String {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            if let host = resolvedHostServerName, !host.isEmpty {
                return host
            }
            return defaultSource
        }()

        return AdminRoomInfo(
            id: (dict["id"] as? String) ?? UUID().uuidString,
            name: (dict["name"] as? String) ?? "Untitled Room",
            description: (dict["description"] as? String) ?? "",
            isPrivate: (dict["isPrivate"] as? Bool) ?? false,
            maxUsers: (dict["maxUsers"] as? Int) ?? 50,
            userCount: usersValue,
            createdBy: (dict["createdBy"] as? String) ?? (dict["ownerUsername"] as? String) ?? (dict["owner"] as? String),
            createdAt: Self.parseDate(dict["createdAt"] ?? dict["created"]),
            isPermanent: (dict["isDefault"] as? Bool) ?? false,
            backgroundStream: nil,
            visibility: dict["visibility"] as? String,
            accessType: dict["accessType"] as? String,
            hidden: dict["hidden"] as? Bool,
            locked: dict["locked"] as? Bool,
            recordingAllowed: (dict["recordingAllowed"] as? Bool) ?? (dict["allowRecording"] as? Bool) ?? (dict["recordingEnabled"] as? Bool),
            accessPin: dict["accessPin"] as? String,
            hasAccessPin: dict["hasAccessPin"] as? Bool,
            enabled: dict["enabled"] as? Bool,
            isDefault: dict["isDefault"] as? Bool,
            hostServerName: resolvedHostServerName ?? defaultSource,
            hostServerOwner: (dict["hostServerOwner"] as? String)
                ?? (dict["serverOwner"] as? String)
                ?? (dict["ownerUsername"] as? String)
                ?? (dict["createdBy"] as? String),
            serverSource: resolvedServerSource,
            updatedBy: (dict["updatedBy"] as? String) ?? (dict["lastUpdatedBy"] as? String),
            updatedAt: Self.parseDate(dict["updatedAt"] ?? dict["lastUpdated"]),
            previousNames: Self.parseStringArray(dict["previousNames"] ?? dict["nameHistory"] ?? dict["priorNames"])
        )
    }

    nonisolated private static func adminSupportSession(from dict: [String: Any]) -> AdminSupportSessionInfo? {
        guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
        let metadata = dict["metadata"] as? [String: Any]
        let whmcsSync = metadata?["whmcsSync"] as? [String: Any]
        return AdminSupportSessionInfo(
            id: id,
            userId: dict["userId"] as? String,
            userName: (dict["userName"] as? String) ?? "Guest",
            userEmail: dict["userEmail"] as? String,
            issue: (dict["issue"] as? String) ?? "",
            roomId: dict["roomId"] as? String,
            roomName: dict["roomName"] as? String,
            hiddenRoomId: dict["hiddenRoomId"] as? String,
            hiddenRoomName: dict["hiddenRoomName"] as? String,
            ticketId: dict["ticketId"] as? String,
            whmcsTicketId: dict["whmcsTicketId"] as? String,
            whmcsTicketNumber: dict["whmcsTicketNumber"] as? String,
            assignedAgentId: dict["assignedAgentId"] as? String,
            assignedAgentName: dict["assignedAgentName"] as? String,
            status: (dict["status"] as? String) ?? "pending",
            channel: (dict["channel"] as? String) ?? "voicelink",
            supportPinRequired: dict["supportPinRequired"] as? Bool ?? false,
            supportPinValidated: dict["supportPinValidated"] as? Bool ?? false,
            pinDelivery: dict["pinDelivery"] as? String,
            createdAt: Self.parseAdminDate(dict["createdAt"]),
            updatedAt: Self.parseAdminDate(dict["updatedAt"]),
            startedAt: Self.parseAdminDate(dict["startedAt"]),
            endedAt: Self.parseAdminDate(dict["endedAt"]),
            endReason: dict["endReason"] as? String,
            pendingWhmcsSync: whmcsSync?["pending"] as? Bool ?? false,
            whmcsSyncMode: whmcsSync?["mode"] as? String,
            whmcsLastSyncError: whmcsSync?["lastError"] as? String
        )
    }

    nonisolated private static func parseAdminDate(_ raw: Any?) -> Date? {
        if let timestamp = raw as? TimeInterval {
            if timestamp > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: timestamp / 1000.0)
            }
            return Date(timeIntervalSince1970: timestamp)
        }
        if let value = raw as? NSNumber {
            let timestamp = value.doubleValue
            if timestamp > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: timestamp / 1000.0)
            }
            return Date(timeIntervalSince1970: timestamp)
        }
        if let string = raw as? String {
            let iso = ISO8601DateFormatter()
            if let parsed = iso.date(from: string) {
                return parsed
            }
        }
        return nil
    }

    nonisolated private static func parseDate(_ value: Any?) -> Date? {
        func dateFromTimestamp(_ raw: TimeInterval) -> Date {
            let seconds = raw > 1_000_000_000_000 ? raw / 1000 : raw
            return Date(timeIntervalSince1970: seconds)
        }

        switch value {
        case let date as Date:
            return date
        case let timeInterval as TimeInterval:
            return dateFromTimestamp(timeInterval)
        case let intValue as Int:
            return dateFromTimestamp(TimeInterval(intValue))
        case let stringValue as String:
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let parsed = ISO8601DateFormatter().date(from: trimmed) {
                return parsed
            }
            if let timestamp = TimeInterval(trimmed) {
                return dateFromTimestamp(timestamp)
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter.date(from: trimmed)
        default:
            return nil
        }
    }

    nonisolated private static func parseStringArray(_ value: Any?) -> [String] {
        if let strings = value as? [String] {
            return strings.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        if let array = value as? [Any] {
            return array.compactMap { item in
                guard let string = item as? String else { return nil }
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        return []
    }

    nonisolated private static func deduplicateAdminRooms(_ rooms: [AdminRoomInfo]) -> [AdminRoomInfo] {
        func normalizedSource(for room: AdminRoomInfo) -> String {
            let source = room.serverSource ?? room.hostServerName ?? room.id
            return source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        func normalizedName(for room: AdminRoomInfo) -> String {
            room.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        func score(_ room: AdminRoomInfo) -> Int {
            var value = room.userCount * 100
            value += room.description.isEmpty ? 0 : 20
            value += room.backgroundStream == nil ? 0 : 10
            value += room.hostServerOwner == nil ? 0 : 5
            value += room.enabled == false ? 0 : 3
            value += room.locked == true ? 1 : 0
            value += room.isDefault == true ? 2 : 0
            return value
        }

        var deduped: [String: AdminRoomInfo] = [:]
        for room in rooms {
            let roomKey = "\(normalizedSource(for: room))::\(normalizedName(for: room))"
            if let existing = deduped[roomKey] {
                deduped[roomKey] = score(room) >= score(existing) ? room : existing
            } else {
                deduped[roomKey] = room
            }
        }
        return Array(deduped.values)
    }

    private static func parseModuleInfo(from dict: [String: Any]) -> AdminModuleInfo? {
        guard let id = dict["id"] as? String else { return nil }
        let config = dict["config"] as? [String: Any]
        let enabledFromConfig = config?["enabled"] as? Bool
        let configJSON: String = {
            guard let config else { return "{}" }
            guard JSONSerialization.isValidJSONObject(config),
                  let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]),
                  let string = String(data: data, encoding: .utf8) else {
                return "{}"
            }
            return string
        }()

        return AdminModuleInfo(
            id: id,
            name: (dict["name"] as? String) ?? id,
            description: (dict["description"] as? String) ?? "",
            version: (dict["version"] as? String) ?? "unknown",
            category: (dict["category"] as? String) ?? "general",
            installed: (dict["installed"] as? Bool) ?? false,
            enabled: enabledFromConfig ?? false,
            recommended: (dict["recommended"] as? Bool) ?? false,
            popular: (dict["popular"] as? Bool) ?? false,
            dependencies: (dict["dependencies"] as? [String]) ?? [],
            features: (dict["features"] as? [String]) ?? [],
            configJSON: configJSON
        )
    }

    private func mergeBuiltInModules() {
        var mergedById = Dictionary(uniqueKeysWithValues: availableModules.map { ($0.id, $0) })
        let sslManager = serverConfig?.sslManager ?? ServerSSLManagerConfig()
        let configData = (try? JSONEncoder().encode(sslManager)) ?? Data("{}".utf8)
        let configJSON = (try? JSONSerialization.jsonObject(with: configData))
            .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys]) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        mergedById["ssl-manager"] = AdminModuleInfo(
            id: "ssl-manager",
            name: "SSL Manager",
            description: "Manage certificates, sync live SSL paths, and control renew or reload actions for this server.",
            version: "builtin",
            category: "security",
            installed: true,
            enabled: sslManager.enabled,
            recommended: true,
            popular: true,
            dependencies: [],
            features: ["ssl", "certificates", "renewal", "reverse-proxy"],
            configJSON: configJSON
        )

        availableModules = Array(mergedById.values).sorted { lhs, rhs in
            if lhs.installed != rhs.installed {
                return lhs.installed && !rhs.installed
            }
            if lhs.recommended != rhs.recommended {
                return lhs.recommended && !rhs.recommended
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func performSSLManagerAction(path: String, successPrefix: String) async -> Bool {
        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: path) else {
            error = "Invalid SSL manager action URL"
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")
        request.httpBody = Data("{}".utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                error = "Invalid SSL manager response"
                return false
            }
            let envelope = try JSONDecoder().decode(ServerSSLManagerActionEnvelope.self, from: data)
            if var current = serverConfig {
                current.sslManager = envelope.sslManager
                serverConfig = current
            }
            mergeBuiltInModules()
            if envelope.success {
                moduleActionMessage = envelope.message?.isEmpty == false ? envelope.message : successPrefix
                return true
            }
            error = envelope.message ?? "SSL manager action failed"
            return false
        } catch {
            self.error = "Failed SSL manager action: \(error.localizedDescription)"
            return false
        }
    }

    private func getClientId() -> String {
        if let clientId = UserDefaults().string(forKey: "clientId") {
            return clientId
        }
        let newId = UUID().uuidString
        UserDefaults().set(newId, forKey: "clientId")
        return newId
    }
}

extension Notification.Name {
    static let serverConfigurationChanged = Notification.Name("serverConfigurationChanged")
    static let roomConfigurationChanged = Notification.Name("roomConfigurationChanged")
}

// MARK: - Models

struct ServerConfig: Codable {
    var serverName: String
    var serverDisplayName: String?
    var serverOwnerDisplayName: String
    var serverOwnerGroup: String?
    var serverDisplayMode: String
    var serverDescription: String
    var maxUsers: Int
    var maxRooms: Int
    var maxUsersPerRoom: Int
    var lobbyWelcomeMessage: String?
    var welcomeMessage: String?
    var motd: String?
    var motdSettings: MOTDSettings
    var registrationEnabled: Bool
    var requireAuth: Bool
    var allowGuests: Bool
    var maxGuestDuration: Int?
    var enableRateLimiting: Bool
    var serverVisibility: ServerVisibilityConfig
    var serverDiscoveryReveal: ServerDiscoveryRevealConfig
    var handoffPromptMode: String
    var messageSettings: MessageSettings
    var authSettings: ServerAuthSettingsConfig
    var backgroundStreams: BackgroundStreamsConfig?
    var pushover: PushoverConfig?
    var recordingEnabled: Bool
    var fileSharing: ServerFileSharingConfig?
    var sslManager: ServerSSLManagerConfig?

    enum CodingKeys: String, CodingKey {
        case serverName
        case serverDisplayName
        case serverOwnerDisplayName
        case serverOwnerGroup
        case serverDisplayMode
        case serverDescription
        case maxUsers
        case maxRooms
        case maxUsersPerRoom
        case lobbyWelcomeMessage
        case welcomeMessage
        case motd
        case motdSettings
        case registrationEnabled
        case requireAuth
        case allowGuests
        case maxGuestDuration
        case enableRateLimiting
        case serverVisibility
        case serverDiscoveryReveal
        case handoffPromptMode
        case messageSettings
        case authSettings
        case backgroundStreams
        case pushover
        case recordingEnabled
        case fileSharing
        case sslManager
    }

    init(
        serverName: String = "VoiceLink",
        serverDisplayName: String? = nil,
        serverOwnerDisplayName: String = "",
        serverOwnerGroup: String? = nil,
        serverDisplayMode: String = "ownerThenDisplayName",
        serverDescription: String = "",
        maxUsers: Int = 500,
        maxRooms: Int = 100,
        maxUsersPerRoom: Int = 50,
        lobbyWelcomeMessage: String? = nil,
        welcomeMessage: String? = nil,
        motd: String? = nil,
        motdSettings: MOTDSettings = MOTDSettings(),
        registrationEnabled: Bool = true,
        requireAuth: Bool = false,
        allowGuests: Bool = true,
        maxGuestDuration: Int? = nil,
        enableRateLimiting: Bool = true,
        serverVisibility: ServerVisibilityConfig = ServerVisibilityConfig(),
        serverDiscoveryReveal: ServerDiscoveryRevealConfig = ServerDiscoveryRevealConfig(),
        handoffPromptMode: String = "serverRecommended",
        messageSettings: MessageSettings = MessageSettings(),
        authSettings: ServerAuthSettingsConfig = ServerAuthSettingsConfig(),
        backgroundStreams: BackgroundStreamsConfig? = nil,
        pushover: PushoverConfig? = nil,
        recordingEnabled: Bool = false
        ,
        fileSharing: ServerFileSharingConfig? = nil,
        sslManager: ServerSSLManagerConfig? = nil
    ) {
        self.serverName = serverName
        self.serverDisplayName = serverDisplayName
        self.serverOwnerDisplayName = serverOwnerDisplayName
        self.serverOwnerGroup = serverOwnerGroup
        self.serverDisplayMode = serverDisplayMode
        self.serverDescription = serverDescription
        self.maxUsers = maxUsers
        self.maxRooms = maxRooms
        self.maxUsersPerRoom = maxUsersPerRoom
        self.lobbyWelcomeMessage = lobbyWelcomeMessage
        self.welcomeMessage = welcomeMessage
        self.motd = motd
        self.motdSettings = motdSettings
        self.registrationEnabled = registrationEnabled
        self.requireAuth = requireAuth
        self.allowGuests = allowGuests
        self.maxGuestDuration = maxGuestDuration
        self.enableRateLimiting = enableRateLimiting
        self.serverVisibility = serverVisibility
        self.serverDiscoveryReveal = serverDiscoveryReveal
        self.handoffPromptMode = handoffPromptMode
        self.messageSettings = messageSettings
        self.authSettings = authSettings
        self.backgroundStreams = backgroundStreams
        self.pushover = pushover
        self.recordingEnabled = recordingEnabled
        self.fileSharing = fileSharing
        self.sslManager = sslManager
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverName = try container.decodeIfPresent(String.self, forKey: .serverName) ?? "VoiceLink"
        serverDisplayName = try container.decodeIfPresent(String.self, forKey: .serverDisplayName)
        serverOwnerDisplayName = try container.decodeIfPresent(String.self, forKey: .serverOwnerDisplayName) ?? ""
        serverOwnerGroup = try container.decodeIfPresent(String.self, forKey: .serverOwnerGroup)
        serverDisplayMode = try container.decodeIfPresent(String.self, forKey: .serverDisplayMode) ?? "ownerThenDisplayName"
        serverDescription = try container.decodeIfPresent(String.self, forKey: .serverDescription) ?? ""
        maxUsers = try container.decodeIfPresent(Int.self, forKey: .maxUsers) ?? 500
        maxRooms = try container.decodeIfPresent(Int.self, forKey: .maxRooms) ?? 100
        maxUsersPerRoom = try container.decodeIfPresent(Int.self, forKey: .maxUsersPerRoom) ?? 50
        lobbyWelcomeMessage = try container.decodeIfPresent(String.self, forKey: .lobbyWelcomeMessage)
        welcomeMessage = try container.decodeIfPresent(String.self, forKey: .welcomeMessage)
        motd = try container.decodeIfPresent(String.self, forKey: .motd)
        motdSettings = try container.decodeIfPresent(MOTDSettings.self, forKey: .motdSettings) ?? MOTDSettings()
        registrationEnabled = try container.decodeIfPresent(Bool.self, forKey: .registrationEnabled) ?? true
        requireAuth = try container.decodeIfPresent(Bool.self, forKey: .requireAuth) ?? false
        allowGuests = try container.decodeIfPresent(Bool.self, forKey: .allowGuests) ?? true
        maxGuestDuration = try container.decodeIfPresent(Int.self, forKey: .maxGuestDuration)
        enableRateLimiting = try container.decodeIfPresent(Bool.self, forKey: .enableRateLimiting) ?? true
        serverVisibility = try container.decodeIfPresent(ServerVisibilityConfig.self, forKey: .serverVisibility) ?? ServerVisibilityConfig()
        serverDiscoveryReveal = try container.decodeIfPresent(ServerDiscoveryRevealConfig.self, forKey: .serverDiscoveryReveal) ?? ServerDiscoveryRevealConfig()
        handoffPromptMode = try container.decodeIfPresent(String.self, forKey: .handoffPromptMode) ?? "serverRecommended"
        messageSettings = try container.decodeIfPresent(MessageSettings.self, forKey: .messageSettings) ?? MessageSettings()
        authSettings = try container.decodeIfPresent(ServerAuthSettingsConfig.self, forKey: .authSettings) ?? ServerAuthSettingsConfig()
        backgroundStreams = try container.decodeIfPresent(BackgroundStreamsConfig.self, forKey: .backgroundStreams)
        pushover = try container.decodeIfPresent(PushoverConfig.self, forKey: .pushover)
        recordingEnabled = try container.decodeIfPresent(Bool.self, forKey: .recordingEnabled) ?? false
        fileSharing = try container.decodeIfPresent(ServerFileSharingConfig.self, forKey: .fileSharing)
        sslManager = try container.decodeIfPresent(ServerSSLManagerConfig.self, forKey: .sslManager)
    }
}

struct ServerAuthSettingsConfig: Codable, Equatable {
    var internalProviderEnabled: Bool
    var whmcsProviderEnabled: Bool
    var wordpressProviderEnabled: Bool
    var composrProviderEnabled: Bool
    var sharedMemberAuthEnabled: Bool
    var sharedMemberAuthMode: String
    var sharedMemberAuthProviders: [String]
    var allowWhmcsFallback: Bool
    var allowMastodonApprovalDelivery: Bool
    var requireSecondDeviceApproval: Bool
    var notifyAdminsOnLoginAttempts: Bool
    var notifyAdminsOnLoginSuccess: Bool
    var notifyAdminsOnLoginFailure: Bool
    var notifyAdminsOnGeneratedLoginLogs: Bool
    var mirrorLoginAlertsToMainChat: Bool
    var allowedTwoFactorMethods: [String]

    init(
        internalProviderEnabled: Bool = true,
        whmcsProviderEnabled: Bool = true,
        wordpressProviderEnabled: Bool = true,
        composrProviderEnabled: Bool = true,
        sharedMemberAuthEnabled: Bool = false,
        sharedMemberAuthMode: String = "group",
        sharedMemberAuthProviders: [String] = ["voicelink", "composr"],
        allowWhmcsFallback: Bool = true,
        allowMastodonApprovalDelivery: Bool = true,
        requireSecondDeviceApproval: Bool = false,
        notifyAdminsOnLoginAttempts: Bool = true,
        notifyAdminsOnLoginSuccess: Bool = true,
        notifyAdminsOnLoginFailure: Bool = true,
        notifyAdminsOnGeneratedLoginLogs: Bool = true,
        mirrorLoginAlertsToMainChat: Bool = false,
        allowedTwoFactorMethods: [String] = ["totp", "email", "sms", "voice", "passkey", "backup"]
    ) {
        self.internalProviderEnabled = internalProviderEnabled
        self.whmcsProviderEnabled = whmcsProviderEnabled
        self.wordpressProviderEnabled = wordpressProviderEnabled
        self.composrProviderEnabled = composrProviderEnabled
        self.sharedMemberAuthEnabled = sharedMemberAuthEnabled
        self.sharedMemberAuthMode = sharedMemberAuthMode
        self.sharedMemberAuthProviders = sharedMemberAuthProviders
        self.allowWhmcsFallback = allowWhmcsFallback
        self.allowMastodonApprovalDelivery = allowMastodonApprovalDelivery
        self.requireSecondDeviceApproval = requireSecondDeviceApproval
        self.notifyAdminsOnLoginAttempts = notifyAdminsOnLoginAttempts
        self.notifyAdminsOnLoginSuccess = notifyAdminsOnLoginSuccess
        self.notifyAdminsOnLoginFailure = notifyAdminsOnLoginFailure
        self.notifyAdminsOnGeneratedLoginLogs = notifyAdminsOnGeneratedLoginLogs
        self.mirrorLoginAlertsToMainChat = mirrorLoginAlertsToMainChat
        self.allowedTwoFactorMethods = allowedTwoFactorMethods
    }
}

struct ServerFileSharingConfig: Codable, Equatable {
    var enabled: Bool
    var uploadRoot: String?
    var smb: ServerSMBAccessConfig?
    var copyParty: ServerCopyPartyAccessConfig?
}

struct ServerSMBAccessConfig: Codable, Equatable {
    var enabled: Bool
    var username: String?
    var hostnames: [String]?
    var local: ServerSMBLayerConfig?
    var central: ServerSMBLayerConfig?
    var preferredShareKey: String?
    var preferredShareName: String?
    var shares: [String: String]?
    var appShareMap: [String: String]?
}

struct ServerSMBLayerConfig: Codable, Equatable {
    var enabled: Bool?
    var hostnames: [String]?
    var preferredShareKey: String?
    var preferredShareName: String?
}

struct ServerCopyPartyAccessConfig: Codable, Equatable {
    var primaryServer: String
    var alternativeServers: [String]?
    var externalShareBaseURL: String?
}

struct ServerSSLManagerEnvelope: Codable, Hashable {
    let success: Bool
    let sslManager: ServerSSLManagerConfig
}

struct ServerSSLManagerUpdateRequest: Codable, Hashable {
    let sslManager: ServerSSLManagerConfig
}

struct ServerSSLManagerActionEnvelope: Codable, Hashable {
    let success: Bool
    let message: String?
    let sslManager: ServerSSLManagerConfig
}

struct ServerSSLManagerConfig: Codable, Equatable, Hashable {
    var enabled: Bool
    var provider: String
    var mode: String
    var controlPanel: String
    var autoRenew: Bool
    var syncToReverseProxy: Bool
    var domains: [String]
    var certificatePath: String?
    var privateKeyPath: String?
    var chainPath: String?
    var acmeWebRoot: String?
    var acmeEmail: String?
    var renewCommand: String?
    var reloadCommand: String?
    var notes: String?
    var status: String
    var certificatePresent: Bool
    var privateKeyPresent: Bool
    var chainPresent: Bool
    var availableTools: [String]
    var supportedManagers: [String]
    var internalManagerAvailable: Bool
    var detectedAt: String?

    init(
        enabled: Bool = true,
        provider: String = "auto",
        mode: String = "auto",
        controlPanel: String = "none",
        autoRenew: Bool = true,
        syncToReverseProxy: Bool = true,
        domains: [String] = [],
        certificatePath: String? = nil,
        privateKeyPath: String? = nil,
        chainPath: String? = nil,
        acmeWebRoot: String? = nil,
        acmeEmail: String? = nil,
        renewCommand: String? = nil,
        reloadCommand: String? = nil,
        notes: String? = nil,
        status: String = "unknown",
        certificatePresent: Bool = false,
        privateKeyPresent: Bool = false,
        chainPresent: Bool = false,
        availableTools: [String] = [],
        supportedManagers: [String] = [],
        internalManagerAvailable: Bool = true,
        detectedAt: String? = nil
    ) {
        self.enabled = enabled
        self.provider = provider
        self.mode = mode
        self.controlPanel = controlPanel
        self.autoRenew = autoRenew
        self.syncToReverseProxy = syncToReverseProxy
        self.domains = domains
        self.certificatePath = certificatePath
        self.privateKeyPath = privateKeyPath
        self.chainPath = chainPath
        self.acmeWebRoot = acmeWebRoot
        self.acmeEmail = acmeEmail
        self.renewCommand = renewCommand
        self.reloadCommand = reloadCommand
        self.notes = notes
        self.status = status
        self.certificatePresent = certificatePresent
        self.privateKeyPresent = privateKeyPresent
        self.chainPresent = chainPresent
        self.availableTools = availableTools
        self.supportedManagers = supportedManagers
        self.internalManagerAvailable = internalManagerAvailable
        self.detectedAt = detectedAt
    }
}

struct ServerVisibilityConfig: Codable, Equatable {
    var desktop: Bool
    var ios: Bool
    var web: Bool
    var frontendOpen: Bool
    var listedInDirectory: Bool
    var allowDirectReveal: Bool

    init(desktop: Bool = true, ios: Bool = true, web: Bool = true, frontendOpen: Bool = true, listedInDirectory: Bool = true, allowDirectReveal: Bool = true) {
        self.desktop = desktop
        self.ios = ios
        self.web = web
        self.frontendOpen = frontendOpen
        self.listedInDirectory = listedInDirectory
        self.allowDirectReveal = allowDirectReveal
    }

    enum CodingKeys: String, CodingKey {
        case desktop
        case ios
        case web
        case frontendOpen
        case listedInDirectory
        case allowDirectReveal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        desktop = try container.decodeIfPresent(Bool.self, forKey: .desktop) ?? true
        ios = try container.decodeIfPresent(Bool.self, forKey: .ios) ?? true
        web = try container.decodeIfPresent(Bool.self, forKey: .web) ?? true
        frontendOpen = try container.decodeIfPresent(Bool.self, forKey: .frontendOpen) ?? true
        listedInDirectory = try container.decodeIfPresent(Bool.self, forKey: .listedInDirectory) ?? true
        allowDirectReveal = try container.decodeIfPresent(Bool.self, forKey: .allowDirectReveal) ?? true
    }
}

struct ServerDiscoveryRevealConfig: Codable, Equatable {
    var staticCodes: [String]
    var rotatingCode: ServerRotatingRevealCodeConfig

    init(staticCodes: [String] = [], rotatingCode: ServerRotatingRevealCodeConfig = ServerRotatingRevealCodeConfig()) {
        self.staticCodes = staticCodes
        self.rotatingCode = rotatingCode
    }
}

struct ServerRotatingRevealCodeConfig: Codable, Equatable {
    var enabled: Bool
    var seed: String
    var seedConfigured: Bool?
    var intervalMinutes: Int
    var length: Int
    var acceptPreviousWindow: Bool

    init(enabled: Bool = false, seed: String = "", seedConfigured: Bool? = nil, intervalMinutes: Int = 60, length: Int = 8, acceptPreviousWindow: Bool = true) {
        self.enabled = enabled
        self.seed = seed
        self.seedConfigured = seedConfigured
        self.intervalMinutes = intervalMinutes
        self.length = length
        self.acceptPreviousWindow = acceptPreviousWindow
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case seed
        case seedConfigured
        case intervalMinutes
        case length
        case acceptPreviousWindow
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        seed = try container.decodeIfPresent(String.self, forKey: .seed) ?? ""
        seedConfigured = try container.decodeIfPresent(Bool.self, forKey: .seedConfigured)
        intervalMinutes = try container.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 60
        length = try container.decodeIfPresent(Int.self, forKey: .length) ?? 8
        acceptPreviousWindow = try container.decodeIfPresent(Bool.self, forKey: .acceptPreviousWindow) ?? true
    }
}

struct MessageSettings: Codable, Equatable {
    var keepRoomMessages: Bool
    var keepDirectMessages: Bool
    var initialLoadCount: Int
    var scrollbackLimit: Int
    var roomMessageCap: Int
    var directMessageCap: Int
    var guestRetentionHours: Int
    var authenticatedRetentionDays: Int
    var deleteRoomMessagesWhenEmpty: Bool
    var keepAttachmentMessages: Bool
    var botMemoryMessageLimit: Int
    var botMemoryDays: Int

    init(
        keepRoomMessages: Bool = true,
        keepDirectMessages: Bool = true,
        initialLoadCount: Int = 20,
        scrollbackLimit: Int = 5000,
        roomMessageCap: Int = 1000,
        directMessageCap: Int = 500,
        guestRetentionHours: Int = 24,
        authenticatedRetentionDays: Int = 30,
        deleteRoomMessagesWhenEmpty: Bool = false,
        keepAttachmentMessages: Bool = true,
        botMemoryMessageLimit: Int = 500,
        botMemoryDays: Int = 30
    ) {
        self.keepRoomMessages = keepRoomMessages
        self.keepDirectMessages = keepDirectMessages
        self.initialLoadCount = initialLoadCount
        self.scrollbackLimit = scrollbackLimit
        self.roomMessageCap = roomMessageCap
        self.directMessageCap = directMessageCap
        self.guestRetentionHours = guestRetentionHours
        self.authenticatedRetentionDays = authenticatedRetentionDays
        self.deleteRoomMessagesWhenEmpty = deleteRoomMessagesWhenEmpty
        self.keepAttachmentMessages = keepAttachmentMessages
        self.botMemoryMessageLimit = botMemoryMessageLimit
        self.botMemoryDays = botMemoryDays
    }
}

struct MOTDSettings: Codable, Equatable {
    var enabled: Bool
    var showBeforeJoin: Bool
    var showInRoom: Bool
    var appendToWelcomeMessage: Bool

    init(
        enabled: Bool = true,
        showBeforeJoin: Bool = true,
        showInRoom: Bool = true,
        appendToWelcomeMessage: Bool = false
    ) {
        self.enabled = enabled
        self.showBeforeJoin = showBeforeJoin
        self.showInRoom = showInRoom
        self.appendToWelcomeMessage = appendToWelcomeMessage
    }
}

struct AdvancedServerSettings: Codable, Equatable {
    var maxRooms: Int
    var welcomeMessage: String?
    var lobbyWelcomeMessage: String?
    var requireAuth: Bool
    var database: DatabaseConfig

    enum CodingKeys: String, CodingKey {
        case maxRooms
        case welcomeMessage
        case lobbyWelcomeMessage
        case requireAuth
        case database
    }

    init(
        maxRooms: Int = 100,
        welcomeMessage: String? = nil,
        lobbyWelcomeMessage: String? = nil,
        requireAuth: Bool = false,
        database: DatabaseConfig = DatabaseConfig()
    ) {
        self.maxRooms = maxRooms
        self.welcomeMessage = welcomeMessage
        self.lobbyWelcomeMessage = lobbyWelcomeMessage
        self.requireAuth = requireAuth
        self.database = database
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxRooms = try container.decodeIfPresent(Int.self, forKey: .maxRooms) ?? 100
        welcomeMessage = try container.decodeIfPresent(String.self, forKey: .welcomeMessage)
        lobbyWelcomeMessage = try container.decodeIfPresent(String.self, forKey: .lobbyWelcomeMessage)
        requireAuth = try container.decodeIfPresent(Bool.self, forKey: .requireAuth) ?? false
        database = try container.decodeIfPresent(DatabaseConfig.self, forKey: .database) ?? DatabaseConfig()
    }
}

struct DatabaseConfig: Codable, Equatable {
    var enabled: Bool
    var provider: String
    var storage: DatabaseStorageConfig
    var sqlite: DatabaseSQLiteConfig
    var postgres: DatabaseNetworkConfig
    var mysql: DatabaseNetworkConfig
    var mariadb: DatabaseNetworkConfig

    init(
        enabled: Bool = false,
        provider: String = "sqlite",
        storage: DatabaseStorageConfig = DatabaseStorageConfig(),
        sqlite: DatabaseSQLiteConfig = DatabaseSQLiteConfig(),
        postgres: DatabaseNetworkConfig = DatabaseNetworkConfig(port: 5432),
        mysql: DatabaseNetworkConfig = DatabaseNetworkConfig(port: 3306),
        mariadb: DatabaseNetworkConfig = DatabaseNetworkConfig(port: 3306)
    ) {
        self.enabled = enabled
        self.provider = provider
        self.storage = storage
        self.sqlite = sqlite
        self.postgres = postgres
        self.mysql = mysql
        self.mariadb = mariadb
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case provider
        case storage
        case sqlite
        case postgres
        case mysql
        case mariadb
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "sqlite"
        storage = try container.decodeIfPresent(DatabaseStorageConfig.self, forKey: .storage) ?? DatabaseStorageConfig()
        sqlite = try container.decodeIfPresent(DatabaseSQLiteConfig.self, forKey: .sqlite) ?? DatabaseSQLiteConfig()
        postgres = try container.decodeIfPresent(DatabaseNetworkConfig.self, forKey: .postgres) ?? DatabaseNetworkConfig(port: 5432)
        mysql = try container.decodeIfPresent(DatabaseNetworkConfig.self, forKey: .mysql) ?? DatabaseNetworkConfig(port: 3306)
        mariadb = try container.decodeIfPresent(DatabaseNetworkConfig.self, forKey: .mariadb) ?? DatabaseNetworkConfig(port: 3306)
    }
}

struct DatabaseStorageConfig: Codable, Equatable {
    var defaultMode: String
    var accounts: String
    var rooms: String
    var support: String
    var scheduler: String
    var diagnostics: String
    var serverConfig: String

    init(
        defaultMode: String = "default",
        accounts: String = "default",
        rooms: String = "default",
        support: String = "default",
        scheduler: String = "default",
        diagnostics: String = "default",
        serverConfig: String = "default"
    ) {
        self.defaultMode = defaultMode
        self.accounts = accounts
        self.rooms = rooms
        self.support = support
        self.scheduler = scheduler
        self.diagnostics = diagnostics
        self.serverConfig = serverConfig
    }

    enum CodingKeys: String, CodingKey {
        case defaultMode
        case accounts
        case rooms
        case support
        case scheduler
        case diagnostics
        case serverConfig
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultMode = try container.decodeIfPresent(String.self, forKey: .defaultMode) ?? "default"
        accounts = try container.decodeIfPresent(String.self, forKey: .accounts) ?? "default"
        rooms = try container.decodeIfPresent(String.self, forKey: .rooms) ?? "default"
        support = try container.decodeIfPresent(String.self, forKey: .support) ?? "default"
        scheduler = try container.decodeIfPresent(String.self, forKey: .scheduler) ?? "default"
        diagnostics = try container.decodeIfPresent(String.self, forKey: .diagnostics) ?? "default"
        serverConfig = try container.decodeIfPresent(String.self, forKey: .serverConfig) ?? "default"
    }
}

struct DatabaseSQLiteConfig: Codable, Equatable {
    var path: String

    init(path: String = "./data/voicelink.db") {
        self.path = path
    }

    enum CodingKeys: String, CodingKey {
        case path
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? "./data/voicelink.db"
    }
}

struct DatabaseNetworkConfig: Codable, Equatable {
    var host: String
    var port: Int
    var database: String
    var user: String
    var password: String
    var ssl: Bool

    init(
        host: String = "127.0.0.1",
        port: Int,
        database: String = "voicelink",
        user: String = "voicelink",
        password: String = "",
        ssl: Bool = false
    ) {
        self.host = host
        self.port = port
        self.database = database
        self.user = user
        self.password = password
        self.ssl = ssl
    }

    enum CodingKeys: String, CodingKey {
        case host
        case port
        case database
        case user
        case password
        case ssl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 0
        database = try container.decodeIfPresent(String.self, forKey: .database) ?? "voicelink"
        user = try container.decodeIfPresent(String.self, forKey: .user) ?? "voicelink"
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        ssl = try container.decodeIfPresent(Bool.self, forKey: .ssl) ?? false
    }
}

struct DatabaseStatusEnvelope: Codable {
    let success: Bool
    let status: DatabaseAdminStatus
    let message: String?
}

struct DatabaseActionResponse: Codable {
    let success: Bool
    let message: String?
    let error: String?
    let status: DatabaseAdminStatus?
}

struct DatabaseAdminStatus: Codable, Equatable {
    var provider: String
    var sqliteAvailable: Bool
    var dbPath: String
    var exists: Bool
    var sizeBytes: Int
    var lastMigration: String?
    var snapshotCounts: [String: Int]

    init(
        provider: String = "sqlite",
        sqliteAvailable: Bool = false,
        dbPath: String = "",
        exists: Bool = false,
        sizeBytes: Int = 0,
        lastMigration: String? = nil,
        snapshotCounts: [String: Int] = [:]
    ) {
        self.provider = provider
        self.sqliteAvailable = sqliteAvailable
        self.dbPath = dbPath
        self.exists = exists
        self.sizeBytes = sizeBytes
        self.lastMigration = lastMigration
        self.snapshotCounts = snapshotCounts
    }
}

struct BackgroundStreamsConfig: Codable, Equatable, Hashable {
    var enabled: Bool
    var streams: [BackgroundStreamConfig]
    var defaultVolume: Int
    var fadeInDuration: Int
    var shuffleEnabled: Bool
    var shuffleIntervalMinutes: Int
    var autoRefreshEnabled: Bool
    var autoReconnectDropped: Bool
    var metadataRefreshIntervalSeconds: Int
    var preJoinEnabled: Bool
    var preJoinStreamId: String?

    enum CodingKeys: String, CodingKey {
        case enabled
        case streams
        case defaultVolume
        case fadeInDuration
        case shuffleEnabled
        case shuffleIntervalMinutes
        case autoRefreshEnabled
        case autoReconnectDropped
        case metadataRefreshIntervalSeconds
        case preJoinEnabled
        case preJoinStreamId
    }

    init(
        enabled: Bool = true,
        streams: [BackgroundStreamConfig] = [],
        defaultVolume: Int = 60,
        fadeInDuration: Int = 1500,
        shuffleEnabled: Bool = false,
        shuffleIntervalMinutes: Int = 15,
        autoRefreshEnabled: Bool = true,
        autoReconnectDropped: Bool = true,
        metadataRefreshIntervalSeconds: Int = 20,
        preJoinEnabled: Bool = false,
        preJoinStreamId: String? = nil
    ) {
        self.enabled = enabled
        self.streams = streams
        self.defaultVolume = defaultVolume
        self.fadeInDuration = fadeInDuration
        self.shuffleEnabled = shuffleEnabled
        self.shuffleIntervalMinutes = shuffleIntervalMinutes
        self.autoRefreshEnabled = autoRefreshEnabled
        self.autoReconnectDropped = autoReconnectDropped
        self.metadataRefreshIntervalSeconds = metadataRefreshIntervalSeconds
        self.preJoinEnabled = preJoinEnabled
        self.preJoinStreamId = preJoinStreamId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        streams = try container.decodeIfPresent([BackgroundStreamConfig].self, forKey: .streams) ?? []
        defaultVolume = try container.decodeIfPresent(Int.self, forKey: .defaultVolume) ?? 60
        fadeInDuration = try container.decodeIfPresent(Int.self, forKey: .fadeInDuration) ?? 1500
        shuffleEnabled = try container.decodeIfPresent(Bool.self, forKey: .shuffleEnabled) ?? false
        shuffleIntervalMinutes = max(1, try container.decodeIfPresent(Int.self, forKey: .shuffleIntervalMinutes) ?? 15)
        autoRefreshEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoRefreshEnabled) ?? true
        autoReconnectDropped = try container.decodeIfPresent(Bool.self, forKey: .autoReconnectDropped) ?? true
        metadataRefreshIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .metadataRefreshIntervalSeconds) ?? 20
        preJoinEnabled = try container.decodeIfPresent(Bool.self, forKey: .preJoinEnabled) ?? false
        preJoinStreamId = try container.decodeIfPresent(String.self, forKey: .preJoinStreamId)
    }
}

struct BackgroundStreamConfig: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var sourceType: String?
    var url: String
    var streamUrl: String
    var uploadPath: String?
    var localFilePath: String?
    var clientRelayUserId: String?
    var volume: Int
    var hidden: Bool
    var autoPlay: Bool
    var rooms: [String]?
    var roomPatterns: [String]?
    var excludedRooms: [String]?
}

struct AdminUserInfo: Codable, Identifiable {
    let id: String
    let odId: String
    let accountId: String?
    let username: String
    let displayName: String?
    let currentRoom: String?
    let connectedAt: Date?
    let role: String
    var isMuted: Bool
    var isDeafened: Bool
    var transmitEnabled: Bool?
    let ipAddress: String?
    let authMethod: String?
    let authProvider: String?
    let email: String?
    let linkedAuthMethods: [AdminLinkedAuthMethod]?
    let sharedAuthMode: String?
}

struct AdminRecentUserLoginEnvelope: Codable {
    let success: Bool
    let count: Int
    let users: [AdminRecentUserLogin]
}

struct AdminRecentUserLogin: Codable, Identifiable {
    let id: String
    let socketId: String?
    let userId: String?
    let username: String?
    let displayName: String?
    let clientType: String?
    let clientVersion: String?
    let deviceName: String?
    let authMethod: String?
    let roomId: String?
    let roomName: String?
    let ipAddress: String?
    let loggedInAt: String?

    var displayLabel: String {
        displayName?.isEmpty == false ? displayName! : (username?.isEmpty == false ? username! : "Unknown user")
    }

    var clientLabel: String {
        [clientType, clientVersion.map { "build \($0)" }, deviceName.map { "on \($0)" }]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

struct AdminUserSearchEnvelope: Codable {
    let success: Bool
    let query: String?
    let count: Int
    let users: [AdminUserSearchEntry]
}

struct AdminUserSearchEntry: Codable, Identifiable {
    let rawId: String?
    let socketId: String?
    let userId: String?
    let odId: String?
    let accountId: String?
    let username: String?
    let displayName: String?
    let email: String?
    let clientType: String?
    let clientVersion: String?
    let deviceName: String?
    let currentRoom: String?
    let roomName: String?
    let authMethod: String?
    let authProvider: String?
    let role: String?
    let source: String?
    let connected: Bool?

    var id: String {
        rawId ?? socketId ?? userId ?? accountId ?? email ?? username ?? displayName ?? "unknown-user"
    }

    var displayLabel: String {
        displayName?.isEmpty == false ? displayName! : (username?.isEmpty == false ? username! : (email ?? "Unknown user"))
    }

    var clientLabel: String {
        [clientType, clientVersion.map { "build \($0)" }, deviceName.map { "on \($0)" }]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    enum CodingKeys: String, CodingKey {
        case rawId = "id"
        case socketId
        case userId
        case odId
        case accountId
        case username
        case displayName
        case email
        case clientType
        case clientVersion
        case deviceName
        case currentRoom
        case roomName
        case authMethod
        case authProvider
        case role
        case source
        case connected
    }
}

struct AdminLinkedAuthMethod: Codable, Hashable {
    let provider: String
    let externalId: String?
    let email: String?
    let username: String?
    let displayName: String?
}

struct AdminSharedAuthGroupsEnvelope: Codable {
    let success: Bool
    let groups: [AdminSharedAuthGroup]
}

struct AdminSharedAuthGroup: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let mode: String
    let providers: [String]
    let source: String
    let externalGroupId: String?
    let externalSite: String?
    let createdAt: String
    let updatedAt: String
    let members: [AdminSharedAuthMember]
    let memberCount: Int
}

struct AdminSharedAuthMember: Codable, Identifiable, Hashable {
    let id: String
    let localUserId: String?
    let email: String?
    let username: String?
    let displayName: String
    let provider: String
    let externalMemberId: String?
    let roles: [String]
    let aliases: [String]
    let createdAt: String
    let updatedAt: String
}

struct AdminRoomInfo: Codable, Identifiable {
    var id: String
    var name: String
    var description: String
    var isPrivate: Bool
    var maxUsers: Int
    var userCount: Int
    var createdBy: String?
    var createdAt: Date?
    var isPermanent: Bool
    var backgroundStream: String?
    var welcomeMessage: String?
    var visibility: String?
    var accessType: String?
    var hidden: Bool?
    var locked: Bool?
    var recordingAllowed: Bool?
    var accessPin: String?
    var hasAccessPin: Bool?
    var enabled: Bool?
    var isDefault: Bool?
    var hostServerName: String?
    var hostServerOwner: String?
    var serverSource: String?
    var updatedBy: String?
    var updatedAt: Date?
    var previousNames: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case metadata
        case isPrivate
        case maxUsers
        case userCount
        case createdBy
        case createdAt
        case isPermanent
        case backgroundStream
        case welcomeMessage
        case visibility
        case accessType
        case hidden
        case locked
        case recordingAllowed
        case accessPin
        case hasAccessPin
        case enabled
        case isDefault
        case hostServerName
        case hostServerOwner
        case serverSource
        case updatedBy
        case updatedAt
        case previousNames
    }

    private struct RoomMetadata: Codable {
        let description: String?
        let roomDescription: String?
        let room_description: String?
        let details: String?
        let topic: String?
        let about: String?
        let summary: String?
        let subtitle: String?

        var resolvedDescription: String? {
            [
                description,
                roomDescription,
                room_description,
                details,
                topic,
                about,
                summary,
                subtitle
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(isPrivate, forKey: .isPrivate)
        try container.encode(maxUsers, forKey: .maxUsers)
        try container.encode(userCount, forKey: .userCount)
        try container.encodeIfPresent(createdBy, forKey: .createdBy)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encode(isPermanent, forKey: .isPermanent)
        try container.encodeIfPresent(backgroundStream, forKey: .backgroundStream)
        try container.encodeIfPresent(welcomeMessage, forKey: .welcomeMessage)
        try container.encodeIfPresent(visibility, forKey: .visibility)
        try container.encodeIfPresent(accessType, forKey: .accessType)
        try container.encodeIfPresent(hidden, forKey: .hidden)
        try container.encodeIfPresent(locked, forKey: .locked)
        try container.encodeIfPresent(recordingAllowed, forKey: .recordingAllowed)
        try container.encodeIfPresent(accessPin, forKey: .accessPin)
        try container.encodeIfPresent(hasAccessPin, forKey: .hasAccessPin)
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try container.encodeIfPresent(isDefault, forKey: .isDefault)
        try container.encodeIfPresent(hostServerName, forKey: .hostServerName)
        try container.encodeIfPresent(hostServerOwner, forKey: .hostServerOwner)
        try container.encodeIfPresent(serverSource, forKey: .serverSource)
        try container.encodeIfPresent(updatedBy, forKey: .updatedBy)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encode(previousNames, forKey: .previousNames)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Room"
        let explicitDescription = try container.decodeIfPresent(String.self, forKey: .description)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let metadataDescription = try container.decodeIfPresent(RoomMetadata.self, forKey: .metadata)?.resolvedDescription
        description = explicitDescription?.isEmpty == false ? explicitDescription! : (metadataDescription ?? "")
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        maxUsers = try container.decodeIfPresent(Int.self, forKey: .maxUsers) ?? 50
        userCount = try container.decodeIfPresent(Int.self, forKey: .userCount) ?? 0
        createdBy = try container.decodeIfPresent(String.self, forKey: .createdBy)
        createdAt = Self.decodeFlexibleDate(from: container, forKey: .createdAt)
        isPermanent = try container.decodeIfPresent(Bool.self, forKey: .isPermanent) ?? false
        backgroundStream = try container.decodeIfPresent(String.self, forKey: .backgroundStream)
        welcomeMessage = try container.decodeIfPresent(String.self, forKey: .welcomeMessage)
        visibility = try container.decodeIfPresent(String.self, forKey: .visibility)
        accessType = try container.decodeIfPresent(String.self, forKey: .accessType)
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden)
        locked = try container.decodeIfPresent(Bool.self, forKey: .locked)
        recordingAllowed = try container.decodeIfPresent(Bool.self, forKey: .recordingAllowed)
        accessPin = try container.decodeIfPresent(String.self, forKey: .accessPin)
        hasAccessPin = try container.decodeIfPresent(Bool.self, forKey: .hasAccessPin)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault)
        hostServerName = try container.decodeIfPresent(String.self, forKey: .hostServerName)
        hostServerOwner = try container.decodeIfPresent(String.self, forKey: .hostServerOwner)
        serverSource = try container.decodeIfPresent(String.self, forKey: .serverSource)
        updatedBy = try container.decodeIfPresent(String.self, forKey: .updatedBy)
        updatedAt = Self.decodeFlexibleDate(from: container, forKey: .updatedAt)
        previousNames = try container.decodeIfPresent([String].self, forKey: .previousNames) ?? []
    }

    private static func decodeFlexibleDate(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Date? {
        func parseLocalDate(_ value: Any?) -> Date? {
            func dateFromTimestamp(_ raw: TimeInterval) -> Date {
                let seconds = raw > 1_000_000_000_000 ? raw / 1000 : raw
                return Date(timeIntervalSince1970: seconds)
            }
            switch value {
            case let date as Date:
                return date
            case let raw as TimeInterval:
                return dateFromTimestamp(raw)
            case let raw as Int:
                return dateFromTimestamp(TimeInterval(raw))
            case let raw as String:
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                if let parsed = ISO8601DateFormatter().date(from: trimmed) {
                    return parsed
                }
                if let timestamp = TimeInterval(trimmed) {
                    return dateFromTimestamp(timestamp)
                }
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                return formatter.date(from: trimmed)
            default:
                return nil
            }
        }

        if let date = try? container.decodeIfPresent(Date.self, forKey: key) {
            return date
        }
        if let rawString = try? container.decodeIfPresent(String.self, forKey: key) {
            return parseLocalDate(rawString)
        }
        if let rawDouble = try? container.decodeIfPresent(Double.self, forKey: key) {
            return parseLocalDate(rawDouble)
        }
        if let rawInt = try? container.decodeIfPresent(Int.self, forKey: key) {
            return parseLocalDate(rawInt)
        }
        return nil
    }

    init(
        id: String,
        name: String,
        description: String,
        isPrivate: Bool,
        maxUsers: Int,
        userCount: Int,
        createdBy: String?,
        createdAt: Date?,
        isPermanent: Bool,
        backgroundStream: String?,
        welcomeMessage: String? = nil,
        visibility: String? = nil,
        accessType: String? = nil,
        hidden: Bool? = nil,
        locked: Bool? = nil,
        recordingAllowed: Bool? = nil,
        accessPin: String? = nil,
        hasAccessPin: Bool? = nil,
        enabled: Bool? = nil,
        isDefault: Bool? = nil,
        hostServerName: String? = nil,
        hostServerOwner: String? = nil,
        serverSource: String? = nil,
        updatedBy: String? = nil,
        updatedAt: Date? = nil,
        previousNames: [String] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.isPrivate = isPrivate
        self.maxUsers = maxUsers
        self.userCount = userCount
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.isPermanent = isPermanent
        self.backgroundStream = backgroundStream
        self.welcomeMessage = welcomeMessage
        self.visibility = visibility
        self.accessType = accessType
        self.hidden = hidden
        self.locked = locked
        self.recordingAllowed = recordingAllowed
        self.accessPin = accessPin
        self.hasAccessPin = hasAccessPin
        self.enabled = enabled
        self.isDefault = isDefault
        self.hostServerName = hostServerName
        self.hostServerOwner = hostServerOwner
        self.serverSource = serverSource
        self.updatedBy = updatedBy
        self.updatedAt = updatedAt
        self.previousNames = previousNames
    }
}

struct AdminSupportSessionInfo: Identifiable, Equatable {
    let id: String
    let userId: String?
    let userName: String
    let userEmail: String?
    let issue: String
    let roomId: String?
    let roomName: String?
    let hiddenRoomId: String?
    let hiddenRoomName: String?
    let ticketId: String?
    let whmcsTicketId: String?
    let whmcsTicketNumber: String?
    let assignedAgentId: String?
    let assignedAgentName: String?
    let status: String
    let channel: String
    let supportPinRequired: Bool
    let supportPinValidated: Bool
    let pinDelivery: String?
    let createdAt: Date?
    let updatedAt: Date?
    let startedAt: Date?
    let endedAt: Date?
    let endReason: String?
    let pendingWhmcsSync: Bool
    let whmcsSyncMode: String?
    let whmcsLastSyncError: String?

    var supportTicketLabel: String? {
        ticketId ?? whmcsTicketNumber ?? whmcsTicketId
    }

    var displayRoomName: String {
        hiddenRoomName ?? roomName ?? hiddenRoomId ?? "No room"
    }

    var supportTicketStateLabel: String {
        if let label = supportTicketLabel, !label.isEmpty {
            return label
        }
        if pendingWhmcsSync {
            return "Pending Sync"
        }
        return "Local Only"
    }
}

struct PushoverConfig: Codable, Equatable {
    var enabled: Bool
    var appToken: String?
    var userKey: String?
    var priority: Int
    var sound: String?
    var notifyOnRoomEvents: Bool
    var notifyOnUserEvents: Bool

    init(
        enabled: Bool = false,
        appToken: String? = nil,
        userKey: String? = nil,
        priority: Int = 0,
        sound: String? = nil,
        notifyOnRoomEvents: Bool = true,
        notifyOnUserEvents: Bool = true
    ) {
        self.enabled = enabled
        self.appToken = appToken
        self.userKey = userKey
        self.priority = priority
        self.sound = sound
        self.notifyOnRoomEvents = notifyOnRoomEvents
        self.notifyOnUserEvents = notifyOnUserEvents
    }
}

struct ServerStats: Codable {
    let totalUsers: Int
    let activeUsers: Int
    let totalRooms: Int
    let activeRooms: Int
    let uptime: Int
    let peakUsers: Int
    let messagesPerMinute: Double
    let bandwidthUsage: Double

    init(
        totalUsers: Int,
        activeUsers: Int,
        totalRooms: Int,
        activeRooms: Int,
        uptime: Int,
        peakUsers: Int,
        messagesPerMinute: Double,
        bandwidthUsage: Double
    ) {
        self.totalUsers = totalUsers
        self.activeUsers = activeUsers
        self.totalRooms = totalRooms
        self.activeRooms = activeRooms
        self.uptime = uptime
        self.peakUsers = peakUsers
        self.messagesPerMinute = messagesPerMinute
        self.bandwidthUsage = bandwidthUsage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalUsers = try container.decodeIfPresent(Int.self, forKey: .totalUsers) ?? 0
        activeUsers = try container.decodeIfPresent(Int.self, forKey: .activeUsers) ?? 0
        totalRooms = try container.decodeIfPresent(Int.self, forKey: .totalRooms) ?? 0
        activeRooms = try container.decodeIfPresent(Int.self, forKey: .activeRooms) ?? 0
        uptime = try container.decodeIfPresent(Int.self, forKey: .uptime) ?? 0
        peakUsers = try container.decodeIfPresent(Int.self, forKey: .peakUsers) ?? activeUsers
        messagesPerMinute = try container.decodeIfPresent(Double.self, forKey: .messagesPerMinute) ?? 0
        bandwidthUsage = try container.decodeIfPresent(Double.self, forKey: .bandwidthUsage) ?? 0
    }
}

struct APISyncSettings: Codable {
    var enabled: Bool
    var mode: String
    var syncInterval: Int
    var autoSyncOnChange: Bool
    var whmcsEnabled: Bool
    var whmcsUrl: String?
    var whmcsApiIdentifier: String?
    var whmcsApiSecret: String?
    var whmcsPortalUrl: String?
    var whmcsAdminUrl: String?
    var whmcsAllowClientPortalLaunch: Bool
    var whmcsAllowAdminPortalLaunch: Bool
    var whmcsEndpointAccessMode: String
    var whmcsManagedEndpointPolicy: String
    var openlinkEnabled: Bool
    var openlinkVoiceFallbackRoomsEnabled: Bool
    var openlinkRequireAdminApprovalForEntry: Bool
    var openlinkAllowAdminOverride: Bool
    var openlinkNotifyBeforeAdminOverride: Bool
    var openlinkShowActiveRoomsInAdminOverview: Bool
    var openlinkRoomDurationMinutes: Int
    var openlinkOverrideWindowSeconds: Int
    var openlinkDefaultDomain: String
    var botsEnabled: Bool
    var botMeshEnabled: Bool
    var botModerationEnabled: Bool
    var botWatchGuestLogins: Bool
    var botWatchRoomMessages: Bool
    var botWatchDirectMessages: Bool
    var botWatchFileOffers: Bool
    var botNotifyAdmins: Bool
    var botNotifySupportRooms: Bool
    var botAllowFileRelay: Bool
    var botDefaultDelegateBot: String
    var botPreferredBackends: [String]
    var botTempDirectory: String?
    var botMaxRelayFileSize: Int
    var allowClientChoice: Bool
    var autoReturnRecoveredUsers: Bool
    var snapshotIntervalSeconds: Int
    var routingProfiles: [APISyncRoutingProfile]

    enum CodingKeys: String, CodingKey {
        case enabled
        case mode
        case syncInterval
        case autoSyncOnChange
        case whmcsEnabled
        case whmcsUrl
        case whmcsApiIdentifier
        case whmcsApiSecret
        case whmcsPortalUrl
        case whmcsAdminUrl
        case whmcsAllowClientPortalLaunch
        case whmcsAllowAdminPortalLaunch
        case whmcsEndpointAccessMode
        case whmcsManagedEndpointPolicy
        case openlinkEnabled
        case openlinkVoiceFallbackRoomsEnabled
        case openlinkRequireAdminApprovalForEntry
        case openlinkAllowAdminOverride
        case openlinkNotifyBeforeAdminOverride
        case openlinkShowActiveRoomsInAdminOverview
        case openlinkRoomDurationMinutes
        case openlinkOverrideWindowSeconds
        case openlinkDefaultDomain
        case botsEnabled
        case botMeshEnabled
        case botModerationEnabled
        case botWatchGuestLogins
        case botWatchRoomMessages
        case botWatchDirectMessages
        case botWatchFileOffers
        case botNotifyAdmins
        case botNotifySupportRooms
        case botAllowFileRelay
        case botDefaultDelegateBot
        case botPreferredBackends
        case botTempDirectory
        case botMaxRelayFileSize
        case allowClientChoice
        case autoReturnRecoveredUsers
        case snapshotIntervalSeconds
        case routingProfiles
    }

    init(
        enabled: Bool = true,
        mode: String = "hybrid",
        syncInterval: Int = 60,
        autoSyncOnChange: Bool = true,
        whmcsEnabled: Bool = false,
        whmcsUrl: String? = nil,
        whmcsApiIdentifier: String? = nil,
        whmcsApiSecret: String? = nil,
        whmcsPortalUrl: String? = nil,
        whmcsAdminUrl: String? = nil,
        whmcsAllowClientPortalLaunch: Bool = true,
        whmcsAllowAdminPortalLaunch: Bool = false,
        whmcsEndpointAccessMode: String = "managed",
        whmcsManagedEndpointPolicy: String = "server-linked",
        openlinkEnabled: Bool = false,
        openlinkVoiceFallbackRoomsEnabled: Bool = true,
        openlinkRequireAdminApprovalForEntry: Bool = true,
        openlinkAllowAdminOverride: Bool = false,
        openlinkNotifyBeforeAdminOverride: Bool = true,
        openlinkShowActiveRoomsInAdminOverview: Bool = true,
        openlinkRoomDurationMinutes: Int = 1440,
        openlinkOverrideWindowSeconds: Int = 180,
        openlinkDefaultDomain: String = "openlink.tappedin.fm",
        botsEnabled: Bool = false,
        botMeshEnabled: Bool = true,
        botModerationEnabled: Bool = false,
        botWatchGuestLogins: Bool = true,
        botWatchRoomMessages: Bool = true,
        botWatchDirectMessages: Bool = true,
        botWatchFileOffers: Bool = true,
        botNotifyAdmins: Bool = true,
        botNotifySupportRooms: Bool = false,
        botAllowFileRelay: Bool = true,
        botDefaultDelegateBot: String = "codex-bot",
        botPreferredBackends: [String] = ["ollama", "codex", "opencode", "openclaw", "claude"],
        botTempDirectory: String? = nil,
        botMaxRelayFileSize: Int = 10_485_760,
        allowClientChoice: Bool = true,
        autoReturnRecoveredUsers: Bool = false,
        snapshotIntervalSeconds: Int = 180,
        routingProfiles: [APISyncRoutingProfile] = []
    ) {
        self.enabled = enabled
        self.mode = mode
        self.syncInterval = syncInterval
        self.autoSyncOnChange = autoSyncOnChange
        self.whmcsEnabled = whmcsEnabled
        self.whmcsUrl = whmcsUrl
        self.whmcsApiIdentifier = whmcsApiIdentifier
        self.whmcsApiSecret = whmcsApiSecret
        self.whmcsPortalUrl = whmcsPortalUrl
        self.whmcsAdminUrl = whmcsAdminUrl
        self.whmcsAllowClientPortalLaunch = whmcsAllowClientPortalLaunch
        self.whmcsAllowAdminPortalLaunch = whmcsAllowAdminPortalLaunch
        self.whmcsEndpointAccessMode = whmcsEndpointAccessMode
        self.whmcsManagedEndpointPolicy = whmcsManagedEndpointPolicy
        self.openlinkEnabled = openlinkEnabled
        self.openlinkVoiceFallbackRoomsEnabled = openlinkVoiceFallbackRoomsEnabled
        self.openlinkRequireAdminApprovalForEntry = openlinkRequireAdminApprovalForEntry
        self.openlinkAllowAdminOverride = openlinkAllowAdminOverride
        self.openlinkNotifyBeforeAdminOverride = openlinkNotifyBeforeAdminOverride
        self.openlinkShowActiveRoomsInAdminOverview = openlinkShowActiveRoomsInAdminOverview
        self.openlinkRoomDurationMinutes = openlinkRoomDurationMinutes
        self.openlinkOverrideWindowSeconds = openlinkOverrideWindowSeconds
        self.openlinkDefaultDomain = openlinkDefaultDomain
        self.botsEnabled = botsEnabled
        self.botMeshEnabled = botMeshEnabled
        self.botModerationEnabled = botModerationEnabled
        self.botWatchGuestLogins = botWatchGuestLogins
        self.botWatchRoomMessages = botWatchRoomMessages
        self.botWatchDirectMessages = botWatchDirectMessages
        self.botWatchFileOffers = botWatchFileOffers
        self.botNotifyAdmins = botNotifyAdmins
        self.botNotifySupportRooms = botNotifySupportRooms
        self.botAllowFileRelay = botAllowFileRelay
        self.botDefaultDelegateBot = botDefaultDelegateBot
        self.botPreferredBackends = botPreferredBackends
        self.botTempDirectory = botTempDirectory
        self.botMaxRelayFileSize = botMaxRelayFileSize
        self.allowClientChoice = allowClientChoice
        self.autoReturnRecoveredUsers = autoReturnRecoveredUsers
        self.snapshotIntervalSeconds = snapshotIntervalSeconds
        self.routingProfiles = routingProfiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "hybrid"
        syncInterval = try container.decodeIfPresent(Int.self, forKey: .syncInterval) ?? 60
        autoSyncOnChange = try container.decodeIfPresent(Bool.self, forKey: .autoSyncOnChange) ?? true
        whmcsEnabled = try container.decodeIfPresent(Bool.self, forKey: .whmcsEnabled) ?? false
        whmcsUrl = try container.decodeIfPresent(String.self, forKey: .whmcsUrl)
        whmcsApiIdentifier = try container.decodeIfPresent(String.self, forKey: .whmcsApiIdentifier)
        whmcsApiSecret = try container.decodeIfPresent(String.self, forKey: .whmcsApiSecret)
        whmcsPortalUrl = try container.decodeIfPresent(String.self, forKey: .whmcsPortalUrl)
        whmcsAdminUrl = try container.decodeIfPresent(String.self, forKey: .whmcsAdminUrl)
        whmcsAllowClientPortalLaunch = try container.decodeIfPresent(Bool.self, forKey: .whmcsAllowClientPortalLaunch) ?? true
        whmcsAllowAdminPortalLaunch = try container.decodeIfPresent(Bool.self, forKey: .whmcsAllowAdminPortalLaunch) ?? false
        whmcsEndpointAccessMode = try container.decodeIfPresent(String.self, forKey: .whmcsEndpointAccessMode) ?? "managed"
        whmcsManagedEndpointPolicy = try container.decodeIfPresent(String.self, forKey: .whmcsManagedEndpointPolicy) ?? "server-linked"
        openlinkEnabled = try container.decodeIfPresent(Bool.self, forKey: .openlinkEnabled) ?? false
        openlinkVoiceFallbackRoomsEnabled = try container.decodeIfPresent(Bool.self, forKey: .openlinkVoiceFallbackRoomsEnabled) ?? true
        openlinkRequireAdminApprovalForEntry = try container.decodeIfPresent(Bool.self, forKey: .openlinkRequireAdminApprovalForEntry) ?? true
        openlinkAllowAdminOverride = try container.decodeIfPresent(Bool.self, forKey: .openlinkAllowAdminOverride) ?? false
        openlinkNotifyBeforeAdminOverride = try container.decodeIfPresent(Bool.self, forKey: .openlinkNotifyBeforeAdminOverride) ?? true
        openlinkShowActiveRoomsInAdminOverview = try container.decodeIfPresent(Bool.self, forKey: .openlinkShowActiveRoomsInAdminOverview) ?? true
        openlinkRoomDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .openlinkRoomDurationMinutes) ?? 1440
        openlinkOverrideWindowSeconds = try container.decodeIfPresent(Int.self, forKey: .openlinkOverrideWindowSeconds) ?? 180
        openlinkDefaultDomain = try container.decodeIfPresent(String.self, forKey: .openlinkDefaultDomain) ?? "openlink.tappedin.fm"
        botsEnabled = try container.decodeIfPresent(Bool.self, forKey: .botsEnabled) ?? false
        botMeshEnabled = try container.decodeIfPresent(Bool.self, forKey: .botMeshEnabled) ?? true
        botModerationEnabled = try container.decodeIfPresent(Bool.self, forKey: .botModerationEnabled) ?? false
        botWatchGuestLogins = try container.decodeIfPresent(Bool.self, forKey: .botWatchGuestLogins) ?? true
        botWatchRoomMessages = try container.decodeIfPresent(Bool.self, forKey: .botWatchRoomMessages) ?? true
        botWatchDirectMessages = try container.decodeIfPresent(Bool.self, forKey: .botWatchDirectMessages) ?? true
        botWatchFileOffers = try container.decodeIfPresent(Bool.self, forKey: .botWatchFileOffers) ?? true
        botNotifyAdmins = try container.decodeIfPresent(Bool.self, forKey: .botNotifyAdmins) ?? true
        botNotifySupportRooms = try container.decodeIfPresent(Bool.self, forKey: .botNotifySupportRooms) ?? false
        botAllowFileRelay = try container.decodeIfPresent(Bool.self, forKey: .botAllowFileRelay) ?? true
        botDefaultDelegateBot = try container.decodeIfPresent(String.self, forKey: .botDefaultDelegateBot) ?? "codex-bot"
        botPreferredBackends = try container.decodeIfPresent([String].self, forKey: .botPreferredBackends) ?? ["ollama", "codex", "opencode", "openclaw", "claude"]
        botTempDirectory = try container.decodeIfPresent(String.self, forKey: .botTempDirectory)
        botMaxRelayFileSize = try container.decodeIfPresent(Int.self, forKey: .botMaxRelayFileSize) ?? 10_485_760
        allowClientChoice = try container.decodeIfPresent(Bool.self, forKey: .allowClientChoice) ?? true
        autoReturnRecoveredUsers = try container.decodeIfPresent(Bool.self, forKey: .autoReturnRecoveredUsers) ?? false
        snapshotIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .snapshotIntervalSeconds) ?? 180
        routingProfiles = try container.decodeIfPresent([APISyncRoutingProfile].self, forKey: .routingProfiles) ?? []
    }
}
