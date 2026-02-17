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
    @Published var schedulerHealth: SchedulerHealth?
    @Published var isLoading: Bool = false
    @Published var error: String?

    private var currentServerURL: String = ""
    private var authToken: String?

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
        guard adminRole.canManageConfig else { return }
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
        guard adminRole.canManageConfig else { return false }

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
        guard adminRole.canManageUsers else { return }

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
        guard adminRole.canManageUsers else { return false }

        guard let url = URL(string: "\(currentServerURL)/api/admin/users/\(userId)/kick") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

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
        guard adminRole.canManageUsers else { return false }

        guard let url = URL(string: "\(currentServerURL)/api/admin/users/\(userId)/ban") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

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
        guard adminRole.canManageRooms else { return }

        guard let url = URL(string: "\(currentServerURL)/api/admin/rooms") else {
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
            serverRooms = try decoder.decode([AdminRoomInfo].self, from: data)
        } catch {
            print("Failed to fetch rooms: \(error)")
        }
    }

    func deleteRoom(_ roomId: String) async -> Bool {
        guard adminRole.canManageRooms else { return false }

        guard let url = URL(string: "\(currentServerURL)/api/admin/rooms/\(roomId)") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                serverRooms.removeAll { $0.id == roomId }
                return true
            }
            return false
        } catch {
            return false
        }
    }

    func updateRoom(_ room: AdminRoomInfo) async -> Bool {
        guard adminRole.canManageRooms else { return false }

        guard let url = URL(string: "\(currentServerURL)/api/admin/rooms/\(room.id)") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let encoder = JSONEncoder()
        request.httpBody = try? encoder.encode(room)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
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

    // MARK: - Scheduler Health

    func fetchSchedulerHealth() async {
        guard let url = URL(string: "\(currentServerURL)/api/scheduler/health") else {
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
            schedulerHealth = try decoder.decode(SchedulerHealth.self, from: data)
        } catch {
            print("Failed to fetch scheduler health: \(error)")
        }
    }

    // MARK: - Background Streams

    func updateBackgroundStreams(_ streams: [BackgroundStreamConfig]) async -> Bool {
        guard adminRole.canManageConfig else { return false }

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
        guard adminRole.canManageConfig else { return nil }

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
        guard adminRole.canManageConfig else { return false }

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
        guard adminRole.canManageConfig else { return nil }

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
        guard adminRole.canManageConfig else { return false }

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

    // MARK: - Migration APIs

    func exportMigrationSnapshot(
        useCopyParty: Bool = true,
        pushViaApi: Bool = false,
        targetServerUrl: String? = nil,
        sourceRoomId: String? = nil,
        targetRoomId: String? = nil,
        triggerRoomTransfer: Bool = false
    ) async -> MigrationExportResponse? {
        guard adminRole.canManageConfig else { return nil }
        guard let url = URL(string: "\(currentServerURL)/api/admin/migration/export") else { return nil }

        var payload: [String: Any] = [
            "useCopyParty": useCopyParty,
            "pushViaApi": pushViaApi,
            "triggerRoomTransfer": triggerRoomTransfer
        ]
        if let targetServerUrl, !targetServerUrl.isEmpty {
            payload["targetServerUrl"] = targetServerUrl
        }
        if let sourceRoomId, !sourceRoomId.isEmpty {
            payload["sourceRoomId"] = sourceRoomId
        }
        if let targetRoomId, !targetRoomId.isEmpty {
            payload["targetRoomId"] = targetRoomId
        }

        do {
            let (data, _) = try await performJSONRequest(url: url, method: "POST", body: payload)
            return try JSONDecoder().decode(MigrationExportResponse.self, from: data)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func triggerRoomTransfer(sourceRoomId: String, targetRoomId: String, targetServerUrl: String?) async -> MigrationRoomTransferResponse? {
        guard adminRole.canManageConfig else { return nil }
        guard let url = URL(string: "\(currentServerURL)/api/admin/migration/room-transfer") else { return nil }

        var payload: [String: Any] = [
            "sourceRoomId": sourceRoomId,
            "targetRoomId": targetRoomId
        ]
        if let targetServerUrl, !targetServerUrl.isEmpty {
            payload["targetServerUrl"] = targetServerUrl
        }

        do {
            let (data, _) = try await performJSONRequest(url: url, method: "POST", body: payload)
            return try JSONDecoder().decode(MigrationRoomTransferResponse.self, from: data)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    // MARK: - Jellyfin Admin APIs

    func fetchJellyfinLibraryPaths() async -> JellyfinLibraryPathsResponse? {
        guard adminRole.canManageConfig else { return nil }
        guard let url = URL(string: "\(currentServerURL)/api/jellyfin/admin/library-paths") else { return nil }
        do {
            let (data, _) = try await performJSONRequest(url: url, method: "GET", body: nil)
            return try JSONDecoder().decode(JellyfinLibraryPathsResponse.self, from: data)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func updateJellyfinLibraryPaths(_ paths: [String]) async -> JellyfinLibraryPathsResponse? {
        guard adminRole.canManageConfig else { return nil }
        guard let url = URL(string: "\(currentServerURL)/api/jellyfin/admin/library-paths") else { return nil }
        let payload: [String: Any] = ["paths": paths]
        do {
            let (data, _) = try await performJSONRequest(url: url, method: "POST", body: payload)
            return try JSONDecoder().decode(JellyfinLibraryPathsResponse.self, from: data)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    // MARK: - Room Agent AI Settings

    func fetchRoomAgentStatus(roomId: String) async -> RoomAgentState? {
        guard adminRole.canManageRooms else { return nil }
        guard let encodedRoomId = roomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(currentServerURL)/api/rooms/\(encodedRoomId)/agent/status") else {
            return nil
        }

        do {
            let (data, _) = try await performJSONRequest(url: url, method: "GET", body: nil)
            let response = try JSONDecoder().decode(RoomAgentStatusResponse.self, from: data)
            return response.agent
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func updateRoomAgentStatus(
        roomId: String,
        enabled: Bool,
        aiProvider: String,
        aiModel: String,
        statusType: String? = nil,
        statusText: String? = nil
    ) async -> RoomAgentState? {
        guard adminRole.canManageRooms else { return nil }
        guard let encodedRoomId = roomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(currentServerURL)/api/rooms/\(encodedRoomId)/agent/status") else {
            return nil
        }

        var payload: [String: Any] = [
            "enabled": enabled,
            "aiProvider": aiProvider,
            "aiModel": aiModel
        ]
        if let statusType, !statusType.isEmpty {
            payload["statusType"] = statusType
        }
        if let statusText, !statusText.isEmpty {
            payload["statusText"] = statusText
        }

        do {
            let (data, _) = try await performJSONRequest(url: url, method: "PUT", body: payload)
            let response = try JSONDecoder().decode(RoomAgentStatusResponse.self, from: data)
            return response.agent
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func fetchAgentDefaults() async -> AgentDefaultsResponse? {
        guard adminRole.canManageConfig else { return nil }
        guard let url = URL(string: "\(currentServerURL)/api/admin/agent/defaults") else { return nil }
        do {
            let (data, _) = try await performJSONRequest(url: url, method: "GET", body: nil)
            return try JSONDecoder().decode(AgentDefaultsResponse.self, from: data)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func updateAgentDefaults(aiProvider: String, aiModel: String) async -> AgentDefaultsResponse? {
        guard adminRole.canManageConfig else { return nil }
        guard let url = URL(string: "\(currentServerURL)/api/admin/agent/defaults") else { return nil }
        let payload: [String: Any] = [
            "aiProvider": aiProvider,
            "aiModel": aiModel
        ]
        do {
            let (data, _) = try await performJSONRequest(url: url, method: "PUT", body: payload)
            return try JSONDecoder().decode(AgentDefaultsResponse.self, from: data)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    // MARK: - Helper

    private func performJSONRequest(url: URL, method: String, body: [String: Any]?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "AdminServerManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Request failed (\(httpResponse.statusCode))"
            throw NSError(domain: "AdminServerManager", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return (data, httpResponse)
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

struct SchedulerHealth: Codable {
    let ok: Bool
    let role: String
    let systemCronRunning: Bool
    let builtinCronRunning: Bool
    let enabledBuiltinTasks: Int
    let guidance: String
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

struct MigrationArchiveInfo: Codable {
    let fileName: String?
    let size: Int?
    let createdAt: String?
    let downloadUrl: String?
}

struct MigrationRoomTransferResponse: Codable {
    let success: Bool
    let roomTransfer: [String: String]?
    let session: [String: String]?
    let error: String?
}

struct MigrationExportResponse: Codable {
    let success: Bool
    let archive: MigrationArchiveInfo?
    let roomTransfer: [String: String]?
    let error: String?
}

struct JellyfinLibraryPathStatus: Codable, Identifiable {
    let path: String
    let exists: Bool
    let readable: Bool
    let writable: Bool
    let resolvedPath: String?
    var id: String { path }
}

struct JellyfinLibraryPathsResponse: Codable {
    let success: Bool
    let paths: [String]
    let defaults: [String]?
    let status: [JellyfinLibraryPathStatus]?
    let error: String?
}

struct RoomAgentStatusResponse: Codable {
    let success: Bool
    let roomId: String?
    let roomName: String?
    let agent: RoomAgentState?
    let error: String?
}

struct RoomAgentState: Codable {
    let enabled: Bool
    let roomScoped: Bool?
    let present: Bool?
    let agentId: String?
    let agentName: String?
    let aiProvider: String?
    let aiModel: String?
    let statusType: String?
    let statusText: String?
    let allowedActions: [String]?
    let updatedAt: String?
    let updatedBy: String?
}

struct AgentAIDefaults: Codable {
    let aiProvider: String
    let aiModel: String
}

struct AgentDefaultsResponse: Codable {
    let success: Bool
    let defaults: AgentAIDefaults?
    let updatedAt: String?
    let updatedBy: String?
    let error: String?
}
