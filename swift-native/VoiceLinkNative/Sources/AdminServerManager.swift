import Foundation
import SwiftUI

// MARK: - Admin Server Manager
@MainActor
class AdminServerManager: ObservableObject {
    static let shared = AdminServerManager()

    @Published var isAdmin: Bool = false
    @Published var adminRole: AdminRole = .none
    @Published var serverConfig: ServerConfig?
    @Published var advancedServerSettings: AdvancedServerSettings?
    @Published var connectedUsers: [AdminUserInfo] = []
    @Published var serverRooms: [AdminRoomInfo] = []
    @Published var supportSessions: [AdminSupportSessionInfo] = []
    @Published var serverStats: ServerStats?
    @Published var availableModules: [AdminModuleInfo] = []
    @Published var serverLogLines: [String] = []
    @Published var serverLogSource: String?
    @Published var databaseStatus: DatabaseAdminStatus?
    @Published var moduleCategories: [String: String] = [:]
    @Published var modulesLoading: Bool = false
    @Published var moduleActionMessage: String?
    @Published var deploymentManagerStatus: DeploymentManagerStatus?
    @Published var deploymentTransports: [DeploymentTransportInfo] = []
    @Published var deploymentActionMessage: String?
    @Published var databaseActionMessage: String?
    @Published var isLoading: Bool = false
    @Published var error: String?

    private var currentServerURL: String = ""
    private var authToken: String?
    private var canManageUsersEffective: Bool { isAdmin || adminRole.canManageUsers }
    private var canManageRoomsEffective: Bool { isAdmin || adminRole.canManageRooms }
    private var canManageConfigEffective: Bool { isAdmin || adminRole.canManageConfig }

    enum AdminRole: String, Codable {
        case none = "none"
        case moderator = "moderator"
        case admin = "admin"
        case owner = "owner"

        var canManageUsers: Bool {
            self == .moderator || self == .admin || self == .owner
        }

        var canManageRooms: Bool {
            self == .admin || self == .owner
        }

        var canManageServer: Bool {
            self == .owner
        }

        var canManageConfig: Bool {
            self == .admin || self == .owner
        }
    }

    // MARK: - Check Admin Status

    func checkAdminStatus(serverURL: String, token: String?) async {
        self.currentServerURL = APIEndpointResolver.normalize(serverURL)
        self.authToken = token
        let candidates = APIEndpointResolver.apiBaseCandidates(preferred: currentServerURL)

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
                    currentServerURL = base
                    return
                }
            } catch {
                continue
            }
        }

        isAdmin = false
        adminRole = .none
    }

    // MARK: - Fetch Server Config

    func fetchServerConfig() async {
        guard canManageConfigEffective else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        let candidates = APIEndpointResolver.apiBaseCandidates(preferred: effectiveServerURL)
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
                    currentServerURL = base
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

        let candidates = APIEndpointResolver.apiBaseCandidates(preferred: effectiveServerURL)
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
                    error = nil
                    return
                }
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    // Treat advanced settings auth denial as non-fatal; core admin tabs can still work.
                    if advancedServerSettings == nil {
                        advancedServerSettings = AdvancedServerSettings(
                            maxRooms: serverConfig?.maxRooms ?? 100,
                            requireAuth: serverConfig?.requireAuth ?? false,
                            database: DatabaseConfig()
                        )
                    }
                    currentServerURL = base
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

        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/config") else {
            error = "Invalid server config URL"
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

        do {
            let encoder = JSONEncoder()
            request.httpBody = try encoder.encode(config)

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                error = "Failed to update server config"
                return false
            }

            serverConfig = config
            NotificationCenter.default.post(name: .serverConfigurationChanged, object: config)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func updateAdvancedServerSettings(_ settings: AdvancedServerSettings) async -> Bool {
        guard canManageConfigEffective else { return false }

        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/admin/settings") else {
            error = "Invalid advanced settings URL"
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

        do {
            let encoder = JSONEncoder()
            request.httpBody = try encoder.encode(settings)

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                error = "Failed to update advanced server settings"
                return false
            }

            advancedServerSettings = settings
            return true
        } catch {
            self.error = "Failed to update advanced server settings: \(error.localizedDescription)"
            return false
        }
    }

    func fetchDatabaseStatus() async {
        guard canManageConfigEffective else { return }
        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/admin/database/status") else {
            error = "Invalid database status URL"
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
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
        let candidates = APIEndpointResolver.apiBaseCandidates(preferred: effectiveServerURL)
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
        components.queryItems = [URLQueryItem(name: "source", value: "app")]
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
            "maxUsers": room.maxUsers,
            "visibility": room.visibility ?? (room.isPrivate ? "private" : "public"),
            "accessType": room.accessType ?? (room.isPrivate ? "private" : "public"),
            "roomType": room.accessType ?? (room.isPrivate ? "private" : "public"),
            "enabled": room.enabled ?? true,
            "locked": room.locked ?? false,
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
                NotificationCenter.default.post(
                    name: .roomConfigurationChanged,
                    object: Room(
                        id: room.id,
                        name: room.name,
                        description: room.description,
                        userCount: room.userCount,
                        isPrivate: (room.visibility ?? (room.isPrivate ? "private" : "public")).localizedCaseInsensitiveContains("private"),
                        maxUsers: room.maxUsers,
                        createdBy: room.createdBy,
                        createdByRole: nil,
                        roomType: nil,
                        createdAt: room.createdAt,
                        uptimeSeconds: nil,
                        lastActiveUsername: nil,
                        lastActivityAt: nil,
                        hostServerName: room.hostServerName,
                        hostServerOwner: room.hostServerOwner,
                        spatialAudioEnabled: nil
                    )
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
        let candidates = APIEndpointResolver.apiBaseCandidates(preferred: effectiveServerURL)
        let decoder = JSONDecoder()

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
                    continue
                }
                if httpResponse.statusCode == 200 {
                    serverStats = try decoder.decode(ServerStats.self, from: data)
                    currentServerURL = base
                    return
                }
            } catch {
                continue
            }
        }

        serverStats = nil
    }

    func fetchServerLogs() async {
        guard canManageConfigEffective else { return }
        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/admin/logs") else {
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
                  httpResponse.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            serverLogSource = json["source"] as? String
            serverLogLines = (json["lines"] as? [String]) ?? []
        } catch {
            self.error = "Failed to fetch server logs: \(error.localizedDescription)"
        }
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

        let candidates = APIEndpointResolver.apiBaseCandidates(preferred: effectiveServerURL)
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

        let candidates = APIEndpointResolver.apiBaseCandidates(preferred: effectiveServerURL)

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
                return FederationSettings(
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
                )
            } catch {
                continue
            }
        }

        return nil
    }

    func updateFederationSettings(_ settings: FederationSettings) async -> Bool {
        guard canManageConfigEffective else { return false }

        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/federation/settings") else {
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
            "enabled": settings.enabled,
            "mode": (settings.allowIncoming && settings.allowOutgoing) ? "mesh" : (settings.allowOutgoing ? "spoke" : "standalone"),
            "globalFederation": settings.enabled,
            "roomApprovalRequired": settings.requireApproval,
            "trustedServers": settings.trustedServers,
            "allowIncoming": settings.allowIncoming,
            "allowOutgoing": settings.allowOutgoing,
            "maintenanceModeEnabled": settings.maintenanceModeEnabled,
            "autoHandoffEnabled": settings.autoHandoffEnabled,
            "handoffTargetServer": settings.handoffTargetServer as Any
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
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

        var components = URLComponents(string: "\(effectiveServerURL)/api/modules")
        components?.queryItems = [
            URLQueryItem(name: "sortBy", value: sortBy)
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
        } catch {
            self.error = "Failed to fetch module catalog: \(error.localizedDescription)"
        }
    }

    func fetchInstalledModules() async {
        guard let url = URL(string: "\(effectiveServerURL)/api/modules/installed") else {
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
            return currentServerURL
        }
        if let connected = ServerManager.shared.baseURL, !connected.isEmpty {
            return connected
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
            createdBy: dict["createdBy"] as? String,
            createdAt: Self.parseDate(dict["createdAt"] ?? dict["created"]),
            isPermanent: (dict["isDefault"] as? Bool) ?? false,
            backgroundStream: nil,
            visibility: dict["visibility"] as? String,
            accessType: dict["accessType"] as? String,
            hidden: dict["hidden"] as? Bool,
            locked: dict["locked"] as? Bool,
            enabled: dict["enabled"] as? Bool,
            isDefault: dict["isDefault"] as? Bool,
            hostServerName: resolvedHostServerName ?? defaultSource,
            hostServerOwner: dict["hostServerOwner"] as? String,
            serverSource: resolvedServerSource,
            updatedBy: (dict["updatedBy"] as? String) ?? (dict["lastUpdatedBy"] as? String),
            updatedAt: Self.parseDate(dict["updatedAt"] ?? dict["lastUpdated"]),
            previousNames: Self.parseStringArray(dict["previousNames"] ?? dict["nameHistory"] ?? dict["priorNames"])
        )
    }

    nonisolated private static func adminSupportSession(from dict: [String: Any]) -> AdminSupportSessionInfo? {
        guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
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
            endReason: dict["endReason"] as? String
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
        switch value {
        case let date as Date:
            return date
        case let timeInterval as TimeInterval:
            return Date(timeIntervalSince1970: timeInterval)
        case let intValue as Int:
            return Date(timeIntervalSince1970: TimeInterval(intValue))
        case let stringValue as String:
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let parsed = ISO8601DateFormatter().date(from: trimmed) {
                return parsed
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

    private func getClientId() -> String {
        if let clientId = UserDefaults().string(forKey: "clientId") {
            return clientId
        }
        let newId = UUID().uuidString
        UserDefaults().set(newId, forKey: "clientId")
        return newId
    }
}

// MARK: - Models

struct ServerConfig: Codable {
    var serverName: String
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
    var handoffPromptMode: String
    var messageSettings: MessageSettings
    var backgroundStreams: BackgroundStreamsConfig?
    var pushover: PushoverConfig?

    enum CodingKeys: String, CodingKey {
        case serverName
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
        case handoffPromptMode
        case messageSettings
        case backgroundStreams
        case pushover
    }

    init(
        serverName: String = "VoiceLink",
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
        handoffPromptMode: String = "serverRecommended",
        messageSettings: MessageSettings = MessageSettings(),
        backgroundStreams: BackgroundStreamsConfig? = nil,
        pushover: PushoverConfig? = nil
    ) {
        self.serverName = serverName
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
        self.handoffPromptMode = handoffPromptMode
        self.messageSettings = messageSettings
        self.backgroundStreams = backgroundStreams
        self.pushover = pushover
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverName = try container.decodeIfPresent(String.self, forKey: .serverName) ?? "VoiceLink"
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
        handoffPromptMode = try container.decodeIfPresent(String.self, forKey: .handoffPromptMode) ?? "serverRecommended"
        messageSettings = try container.decodeIfPresent(MessageSettings.self, forKey: .messageSettings) ?? MessageSettings()
        backgroundStreams = try container.decodeIfPresent(BackgroundStreamsConfig.self, forKey: .backgroundStreams)
        pushover = try container.decodeIfPresent(PushoverConfig.self, forKey: .pushover)
    }
}

struct ServerVisibilityConfig: Codable, Equatable {
    var desktop: Bool
    var ios: Bool
    var web: Bool
    var frontendOpen: Bool

    init(desktop: Bool = true, ios: Bool = true, web: Bool = true, frontendOpen: Bool = true) {
        self.desktop = desktop
        self.ios = ios
        self.web = web
        self.frontendOpen = frontendOpen
    }

    enum CodingKeys: String, CodingKey {
        case desktop
        case ios
        case web
        case frontendOpen
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        desktop = try container.decodeIfPresent(Bool.self, forKey: .desktop) ?? true
        ios = try container.decodeIfPresent(Bool.self, forKey: .ios) ?? true
        web = try container.decodeIfPresent(Bool.self, forKey: .web) ?? true
        frontendOpen = try container.decodeIfPresent(Bool.self, forKey: .frontendOpen) ?? true
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
    var requireAuth: Bool
    var database: DatabaseConfig

    enum CodingKeys: String, CodingKey {
        case maxRooms
        case requireAuth
        case database
    }

    init(maxRooms: Int = 100, requireAuth: Bool = false, database: DatabaseConfig = DatabaseConfig()) {
        self.maxRooms = maxRooms
        self.requireAuth = requireAuth
        self.database = database
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxRooms = try container.decodeIfPresent(Int.self, forKey: .maxRooms) ?? 100
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

struct BackgroundStreamsConfig: Codable {
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

struct BackgroundStreamConfig: Codable, Identifiable {
    var id: String
    var name: String
    var url: String
    var streamUrl: String
    var volume: Int
    var hidden: Bool
    var autoPlay: Bool
    var rooms: [String]?
    var roomPatterns: [String]?
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
    let ipAddress: String?
    let authMethod: String?
    let email: String?
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
    var visibility: String?
    var accessType: String?
    var hidden: Bool?
    var locked: Bool?
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
        case isPrivate
        case maxUsers
        case userCount
        case createdBy
        case createdAt
        case isPermanent
        case backgroundStream
        case visibility
        case accessType
        case hidden
        case locked
        case enabled
        case isDefault
        case hostServerName
        case hostServerOwner
        case serverSource
        case updatedBy
        case updatedAt
        case previousNames
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Room"
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        maxUsers = try container.decodeIfPresent(Int.self, forKey: .maxUsers) ?? 50
        userCount = try container.decodeIfPresent(Int.self, forKey: .userCount) ?? 0
        createdBy = try container.decodeIfPresent(String.self, forKey: .createdBy)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        isPermanent = try container.decodeIfPresent(Bool.self, forKey: .isPermanent) ?? false
        backgroundStream = try container.decodeIfPresent(String.self, forKey: .backgroundStream)
        visibility = try container.decodeIfPresent(String.self, forKey: .visibility)
        accessType = try container.decodeIfPresent(String.self, forKey: .accessType)
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden)
        locked = try container.decodeIfPresent(Bool.self, forKey: .locked)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault)
        hostServerName = try container.decodeIfPresent(String.self, forKey: .hostServerName)
        hostServerOwner = try container.decodeIfPresent(String.self, forKey: .hostServerOwner)
        serverSource = try container.decodeIfPresent(String.self, forKey: .serverSource)
        updatedBy = try container.decodeIfPresent(String.self, forKey: .updatedBy)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        previousNames = try container.decodeIfPresent([String].self, forKey: .previousNames) ?? []
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
        visibility: String? = nil,
        accessType: String? = nil,
        hidden: Bool? = nil,
        locked: Bool? = nil,
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
        self.visibility = visibility
        self.accessType = accessType
        self.hidden = hidden
        self.locked = locked
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

    var supportTicketLabel: String? {
        ticketId ?? whmcsTicketNumber ?? whmcsTicketId
    }

    var displayRoomName: String {
        hiddenRoomName ?? roomName ?? hiddenRoomId ?? "No room"
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
        allowClientChoice = try container.decodeIfPresent(Bool.self, forKey: .allowClientChoice) ?? true
        autoReturnRecoveredUsers = try container.decodeIfPresent(Bool.self, forKey: .autoReturnRecoveredUsers) ?? false
        snapshotIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .snapshotIntervalSeconds) ?? 180
        routingProfiles = try container.decodeIfPresent([APISyncRoutingProfile].self, forKey: .routingProfiles) ?? []
    }
}

struct APISyncRoutingProfile: Codable, Identifiable, Hashable {
    var id: UUID
    var label: String
    var targetServer: String
    var targetType: String
    var installPath: String?
    var manualAddress: String?
    var actions: [String]

    init(
        id: UUID = UUID(),
        label: String = "Routing Profile",
        targetServer: String = "",
        targetType: String = "domain",
        installPath: String? = nil,
        manualAddress: String? = nil,
        actions: [String] = ["start"]
    ) {
        self.id = id
        self.label = label
        self.targetServer = targetServer
        self.targetType = targetType
        self.installPath = installPath
        self.manualAddress = manualAddress
        self.actions = Array(actions.prefix(4))
    }
}

struct FederationSettings: Codable {
    var enabled: Bool
    var allowIncoming: Bool
    var allowOutgoing: Bool
    var trustedServers: [String]
    var blockedServers: [String]
    var autoAcceptTrusted: Bool
    var requireApproval: Bool
    var maintenanceModeEnabled: Bool
    var autoHandoffEnabled: Bool
    var handoffTargetServer: String?
}

struct AdminModuleInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let version: String
    let category: String
    var installed: Bool
    var enabled: Bool
    let recommended: Bool
    let popular: Bool
    let dependencies: [String]
    let features: [String]
    let configJSON: String
}

struct DeploymentManagerStatus: Codable {
    let enabled: Bool
    let supportsFreshInstall: Bool
    let supportsExistingInstallUpdate: Bool
    let supportsRemoteBootstrap: Bool
    let supportedTransports: [DeploymentTransportInfo]
    let mailConfigured: Bool
    let defaultOwnerEmailTemplateEnabled: Bool
}

struct DeploymentTransportInfo: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
}

struct DeploymentTransportsResponse: Codable {
    let transports: [DeploymentTransportInfo]
}

struct DeploymentPackageRequest: Codable {
    var preset: String?
    var sanitize: Bool
    var ownerEmail: String?
    var targetLabel: String?
    var targetServerUrl: String?
    var linkedToMain: Bool
    var trustedServers: [String]
    var extraConfig: DeploymentExtraConfig
}

struct DeploymentExtraConfig: Codable {
    var server: [String: String]
    var federation: [String: String]

    init(server: [String: String] = [:], federation: [String: String] = [:]) {
        self.server = server
        self.federation = federation
    }
}

struct DeploymentPackageResponse: Codable {
    let success: Bool
    let bundleId: String
    let bundleName: String
    let zipPath: String
    let manifest: DeploymentManifest
}

struct DeploymentManifest: Codable {
    let id: String
    let createdAt: String
    let targetLabel: String?
    let targetServerUrl: String?
    let ownerEmail: String?
}

struct DeploymentExecutionRequest: Codable {
    var packageOptions: DeploymentPackageRequest
    var target: DeploymentTargetRequest
    var bootstrap: Bool
}

struct DeploymentTargetRequest: Codable {
    var transport: String
    var host: String?
    var port: Int?
    var remotePath: String?
    var uploadUrl: String?
    var username: String?
    var password: String?
    var method: String?
    var insecure: Bool
    var apiBaseUrl: String?
    var apiToken: String?
    var sharedSecret: String?
    var trustedServers: [String]?
    var restartAfterBootstrap: Bool?
    var restartUrl: String?
    var restartMethod: String?
}

struct DeploymentExecutionResponse: Codable {
    let success: Bool
    let bundleId: String
    let bundleName: String
    let upload: DeploymentUploadResponse
    let bootstrap: DeploymentBootstrapResponse?
    let restart: DeploymentRestartResponse?
}

struct DeploymentUploadResponse: Codable {
    let success: Bool
    let transport: String
    let remoteUrl: String
}

struct DeploymentBootstrapResponse: Codable {
    let success: Bool
}

struct DeploymentRestartResponse: Codable {
    let success: Bool?
    let skipped: Bool?
    let reason: String?
    let error: String?
}

struct DeploymentOwnerEmailRequest: Codable {
    var recipient: String
    var subject: String?
    var bundleName: String?
    var remoteUrl: String?
    var apiBaseUrl: String?
}

struct DeploymentSimpleResponse: Codable {
    let success: Bool
}
