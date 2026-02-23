import Foundation
import SwiftUI

// MARK: - Admin Server Manager
@MainActor
class AdminServerManager: ObservableObject {
    static let shared = AdminServerManager()

    @Published var isAdmin: Bool = false
    @Published var adminRole: AdminRole = .none
    @Published var serverConfig: ServerConfig?
    @Published var connectedUsers: [AdminUserInfo] = []
    @Published var serverRooms: [AdminRoomInfo] = []
    @Published var serverStats: ServerStats?
    @Published var availableModules: [AdminModuleInfo] = []
    @Published var moduleCategories: [String: String] = [:]
    @Published var modulesLoading: Bool = false
    @Published var moduleActionMessage: String?
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
        self.currentServerURL = serverURL
        self.authToken = token

        guard let url = URL(string: "\(serverURL)/api/admin/status") else {
            isAdmin = false
            adminRole = .none
            return
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
                isAdmin = false
                adminRole = .none
                return
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                isAdmin = json["isAdmin"] as? Bool ?? false
                if let roleStr = json["role"] as? String {
                    adminRole = AdminRole(rawValue: roleStr) ?? .none
                }
            }
        } catch {
            isAdmin = false
            adminRole = .none
        }
    }

    // MARK: - Fetch Server Config

    func fetchServerConfig() async {
        guard canManageConfigEffective else { return }
        isLoading = true
        error = nil

        guard let url = URL(string: "\(currentServerURL)/api/admin/config") else {
            error = "Invalid server URL"
            isLoading = false
            return
        }

        var request = URLRequest(url: url)
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                error = "Failed to fetch server config"
                isLoading = false
                return
            }

            let decoder = JSONDecoder()
            serverConfig = try decoder.decode(ServerConfig.self, from: data)
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Update Server Config

    func updateServerConfig(_ config: ServerConfig) async -> Bool {
        guard canManageConfigEffective else { return false }

        guard let url = URL(string: "\(currentServerURL)/api/admin/config") else {
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
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - User Management

    func fetchConnectedUsers() async {
        guard canManageUsersEffective else { return }

        guard let url = URL(string: "\(currentServerURL)/api/admin/users") else {
            return
        }

        var request = URLRequest(url: url)
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

            let decoder = JSONDecoder()
            connectedUsers = try decoder.decode([AdminUserInfo].self, from: data)
        } catch {
            print("Failed to fetch users: \(error)")
        }
    }

    func kickUser(_ userId: String, reason: String? = nil) async -> Bool {
        guard canManageUsersEffective else { return false }

        guard let url = URL(string: "\(currentServerURL)/api/admin/users/\(userId)/kick") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
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

        guard let url = URL(string: "\(currentServerURL)/api/admin/users/\(userId)/ban") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
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

    // MARK: - Room Management

    func fetchRooms() async {
        guard canManageRoomsEffective else { return }

        guard let url = URL(string: "\(currentServerURL)/api/rooms?source=app") else {
            return
        }

        var request = URLRequest(url: url)
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

            guard let rawRooms = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return
            }
            serverRooms = rawRooms.map { Self.adminRoom(from: $0) }
        } catch {
            print("Failed to fetch rooms: \(error)")
        }
    }

    func deleteRoom(_ roomId: String) async -> Bool {
        guard canManageRoomsEffective else { return false }

        guard let url = URL(string: "\(currentServerURL)/api/rooms/\(roomId)") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
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

        guard let url = URL(string: "\(currentServerURL)/api/rooms/\(room.id)") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
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
            "enabled": room.enabled ?? true,
            "locked": room.locked ?? false
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                if let idx = serverRooms.firstIndex(where: { $0.id == room.id }) {
                    serverRooms[idx] = room
                }
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

    // MARK: - Server Stats

    func fetchServerStats() async {
        guard let url = URL(string: "\(currentServerURL)/api/admin/stats") else {
            return
        }

        var request = URLRequest(url: url)
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

            let decoder = JSONDecoder()
            serverStats = try decoder.decode(ServerStats.self, from: data)
        } catch {
            print("Failed to fetch stats: \(error)")
        }
    }

    // MARK: - Background Streams

    func updateBackgroundStreams(_ streams: [BackgroundStreamConfig]) async -> Bool {
        guard canManageConfigEffective else { return false }

        guard let url = URL(string: "\(currentServerURL)/api/admin/background-streams") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let encoder = JSONEncoder()
        request.httpBody = try? encoder.encode(["streams": streams])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - API Sync Settings

    func fetchAPISyncSettings() async -> APISyncSettings? {
        guard canManageConfigEffective else { return nil }

        guard let url = URL(string: "\(currentServerURL)/api/admin/api-sync") else {
            return nil
        }

        var request = URLRequest(url: url)
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            let decoder = JSONDecoder()
            return try decoder.decode(APISyncSettings.self, from: data)
        } catch {
            return nil
        }
    }

    func updateAPISyncSettings(_ settings: APISyncSettings) async -> Bool {
        guard canManageConfigEffective else { return false }

        guard let url = URL(string: "\(currentServerURL)/api/admin/api-sync") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

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

        guard let url = URL(string: "\(currentServerURL)/api/admin/federation") else {
            return nil
        }

        var request = URLRequest(url: url)
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            let decoder = JSONDecoder()
            return try decoder.decode(FederationSettings.self, from: data)
        } catch {
            return nil
        }
    }

    func updateFederationSettings(_ settings: FederationSettings) async -> Bool {
        guard canManageConfigEffective else { return false }

        guard let url = URL(string: "\(currentServerURL)/api/admin/federation") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let encoder = JSONEncoder()
        request.httpBody = try? encoder.encode(settings)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Helper

    func refreshModulesCenter() async {
        await fetchInstalledModules()
        await fetchAvailableModules()
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
            availableModules = modulesArray.compactMap { Self.parseModuleInfo(from: $0) }
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
                availableModules = availableModules.map { module in
                    guard let installed = installedById[module.id] else {
                        var copy = module
                        copy.installed = false
                        return copy
                    }
                    return installed
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

    private static func adminRoom(from dict: [String: Any]) -> AdminRoomInfo {
        let usersValue: Int = {
            if let count = dict["users"] as? Int { return count }
            if let count = dict["userCount"] as? Int { return count }
            if let users = dict["users"] as? [[String: Any]] { return users.count }
            return 0
        }()

        return AdminRoomInfo(
            id: (dict["id"] as? String) ?? UUID().uuidString,
            name: (dict["name"] as? String) ?? "Untitled Room",
            description: (dict["description"] as? String) ?? "",
            isPrivate: (dict["isPrivate"] as? Bool) ?? false,
            maxUsers: (dict["maxUsers"] as? Int) ?? 50,
            userCount: usersValue,
            createdBy: dict["createdBy"] as? String,
            createdAt: nil,
            isPermanent: (dict["isDefault"] as? Bool) ?? false,
            backgroundStream: nil,
            visibility: dict["visibility"] as? String,
            accessType: dict["accessType"] as? String,
            hidden: dict["hidden"] as? Bool,
            locked: dict["locked"] as? Bool,
            enabled: dict["enabled"] as? Bool,
            isDefault: dict["isDefault"] as? Bool
        )
    }

    private static func parseModuleInfo(from dict: [String: Any]) -> AdminModuleInfo? {
        guard let id = dict["id"] as? String else { return nil }
        let config = dict["config"] as? [String: Any]
        let enabledFromConfig = config?["enabled"] as? Bool

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
            features: (dict["features"] as? [String]) ?? []
        )
    }

    private func getClientId() -> String {
        if let clientId = UserDefaults.standard.string(forKey: "clientId") {
            return clientId
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: "clientId")
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
    var welcomeMessage: String?
    var motd: String?
    var registrationEnabled: Bool
    var requireAuth: Bool
    var backgroundStreams: BackgroundStreamsConfig?
    var pushover: PushoverConfig?
}

struct BackgroundStreamsConfig: Codable {
    var enabled: Bool
    var streams: [BackgroundStreamConfig]
    var defaultVolume: Int
    var fadeInDuration: Int
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
    let username: String
    let displayName: String?
    let currentRoom: String?
    let connectedAt: Date?
    let role: String
    var isMuted: Bool
    var isDeafened: Bool
    let ipAddress: String?
    let authMethod: String?
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
        isDefault: Bool? = nil
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
    var hubNodeEnabled: Bool
    var hubNodeUrl: String?
    var hubNodeApiKey: String?
    var apiMonitorEnabled: Bool
    var apiMonitorEndpoint: String?
    var syncInterval: Int
    var autoSyncOnChange: Bool
    var whmcsEnabled: Bool
    var whmcsUrl: String?
    var whmcsApiIdentifier: String?
    var whmcsApiSecret: String?
}

struct FederationSettings: Codable {
    var enabled: Bool
    var allowIncoming: Bool
    var allowOutgoing: Bool
    var trustedServers: [String]
    var blockedServers: [String]
    var autoAcceptTrusted: Bool
    var requireApproval: Bool
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
}
