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
    @Published var serverStats: ServerStats?
    @Published var availableModules: [AdminModuleInfo] = []
    @Published var serverLogLines: [String] = []
    @Published var serverLogSource: String?
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

        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/admin/settings") else {
            error = "Invalid admin settings URL"
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
                error = "Failed to fetch advanced server settings"
                return
            }

            let decoder = JSONDecoder()
            advancedServerSettings = try decoder.decode(AdvancedServerSettings.self, from: data)
        } catch {
            self.error = "Failed to fetch advanced server settings: \(error.localizedDescription)"
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

    // MARK: - User Management

    func fetchConnectedUsers() async {
        guard canManageUsersEffective else { return }

        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/admin/users") else {
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

            let decoder = JSONDecoder()
            connectedUsers = try decoder.decode([AdminUserInfo].self, from: data)
        } catch {
            print("Failed to fetch users: \(error)")
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
        guard let url = URL(string: "\(effectiveServerURL)/api/admin/stats") else {
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

            let decoder = JSONDecoder()
            serverStats = try decoder.decode(ServerStats.self, from: data)
        } catch {
            print("Failed to fetch stats: \(error)")
        }
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

    func updateBackgroundStreams(_ streams: [BackgroundStreamConfig]) async -> Bool {
        guard canManageConfigEffective else { return false }

        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/admin/background-streams") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 6
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

        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/admin/api-sync") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
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

        guard let url = APIEndpointResolver.url(base: effectiveServerURL, path: "/api/federation/status") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            return FederationSettings(
                enabled: json["enabled"] as? Bool ?? false,
                allowIncoming: true,
                allowOutgoing: true,
                trustedServers: [],
                blockedServers: [],
                autoAcceptTrusted: false,
                requireApproval: json["roomApprovalRequired"] as? Bool ?? false
            )
        } catch {
            return nil
        }
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

        let payload: [String: Any] = [
            "enabled": settings.enabled,
            "mode": (settings.allowIncoming && settings.allowOutgoing) ? "mesh" : (settings.allowOutgoing ? "spoke" : "standalone"),
            "globalFederation": settings.enabled,
            "roomApprovalRequired": settings.requireApproval,
            "trustedServers": settings.trustedServers
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
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
    var allowGuests: Bool
    var maxGuestDuration: Int?
    var enableRateLimiting: Bool
    var backgroundStreams: BackgroundStreamsConfig?
    var pushover: PushoverConfig?

    enum CodingKeys: String, CodingKey {
        case serverName
        case serverDescription
        case maxUsers
        case maxRooms
        case maxUsersPerRoom
        case welcomeMessage
        case motd
        case registrationEnabled
        case requireAuth
        case allowGuests
        case maxGuestDuration
        case enableRateLimiting
        case backgroundStreams
        case pushover
    }

    init(
        serverName: String = "VoiceLink",
        serverDescription: String = "",
        maxUsers: Int = 500,
        maxRooms: Int = 100,
        maxUsersPerRoom: Int = 50,
        welcomeMessage: String? = nil,
        motd: String? = nil,
        registrationEnabled: Bool = true,
        requireAuth: Bool = false,
        allowGuests: Bool = true,
        maxGuestDuration: Int? = nil,
        enableRateLimiting: Bool = true,
        backgroundStreams: BackgroundStreamsConfig? = nil,
        pushover: PushoverConfig? = nil
    ) {
        self.serverName = serverName
        self.serverDescription = serverDescription
        self.maxUsers = maxUsers
        self.maxRooms = maxRooms
        self.maxUsersPerRoom = maxUsersPerRoom
        self.welcomeMessage = welcomeMessage
        self.motd = motd
        self.registrationEnabled = registrationEnabled
        self.requireAuth = requireAuth
        self.allowGuests = allowGuests
        self.maxGuestDuration = maxGuestDuration
        self.enableRateLimiting = enableRateLimiting
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
        welcomeMessage = try container.decodeIfPresent(String.self, forKey: .welcomeMessage)
        motd = try container.decodeIfPresent(String.self, forKey: .motd)
        registrationEnabled = try container.decodeIfPresent(Bool.self, forKey: .registrationEnabled) ?? true
        requireAuth = try container.decodeIfPresent(Bool.self, forKey: .requireAuth) ?? false
        allowGuests = try container.decodeIfPresent(Bool.self, forKey: .allowGuests) ?? true
        maxGuestDuration = try container.decodeIfPresent(Int.self, forKey: .maxGuestDuration)
        enableRateLimiting = try container.decodeIfPresent(Bool.self, forKey: .enableRateLimiting) ?? true
        backgroundStreams = try container.decodeIfPresent(BackgroundStreamsConfig.self, forKey: .backgroundStreams)
        pushover = try container.decodeIfPresent(PushoverConfig.self, forKey: .pushover)
    }
}

struct AdvancedServerSettings: Codable, Equatable {
    var maxRooms: Int
    var requireAuth: Bool
    var database: DatabaseConfig

    init(maxRooms: Int = 100, requireAuth: Bool = false, database: DatabaseConfig = DatabaseConfig()) {
        self.maxRooms = maxRooms
        self.requireAuth = requireAuth
        self.database = database
    }
}

struct DatabaseConfig: Codable, Equatable {
    var enabled: Bool
    var provider: String
    var sqlite: DatabaseSQLiteConfig
    var postgres: DatabaseNetworkConfig
    var mysql: DatabaseNetworkConfig
    var mariadb: DatabaseNetworkConfig

    init(
        enabled: Bool = false,
        provider: String = "sqlite",
        sqlite: DatabaseSQLiteConfig = DatabaseSQLiteConfig(),
        postgres: DatabaseNetworkConfig = DatabaseNetworkConfig(port: 5432),
        mysql: DatabaseNetworkConfig = DatabaseNetworkConfig(port: 3306),
        mariadb: DatabaseNetworkConfig = DatabaseNetworkConfig(port: 3306)
    ) {
        self.enabled = enabled
        self.provider = provider
        self.sqlite = sqlite
        self.postgres = postgres
        self.mysql = mysql
        self.mariadb = mariadb
    }
}

struct DatabaseSQLiteConfig: Codable, Equatable {
    var path: String

    init(path: String = "./data/voicelink.db") {
        self.path = path
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
