import Foundation
import SwiftUI
import IOKit
import UserNotifications

/// VoiceLink Licensing Manager
/// Handles node registration, license validation, and device activation
/// - 15 minute delay before license issued
/// - 3 device limit (1 auto + 2 on request)
/// - Deactivate to free slot or purchase more
@MainActor
class LicensingManager: ObservableObject {
    static let shared = LicensingManager()

    private struct LicensingIdentityContext {
        let identity: String
        let authProvider: String
        let authMethod: String
        let userId: String
        let username: String
        let displayName: String
        let email: String?
        let fullHandle: String?
        let accessToken: String?
    }

    // MARK: - Published Properties
    @Published var licenseKey: String?
    @Published var licenseStatus: LicenseStatus = .unknown
    @Published var activatedDevices: Int = 0
    @Published var maxDevices: Int = 3
    @Published var remainingSlots: Int = 3
    @Published var activationRequired: Bool = false
    @Published var registrationProgress: Double = 0
    @Published var remainingMinutes: Int = 0
    @Published var isChecking: Bool = false
    @Published var errorMessage: String?
    @Published var devices: [ActivatedDevice] = []
    @Published var recentMachines: [RecentMachine] = []
    @Published var primaryEmail: String?
    @Published var ownershipPolicy: OwnershipPolicy?
    @Published var lastEvictedDeviceName: String?
    @Published var latestLicenseNotice: String?

    // 2FA support
    @Published var requires2FA: Bool = false
    @Published var twoFactorCode: String = ""
    @Published var show2FAPrompt: Bool = false

    // MARK: - Configuration
    private let apiBaseUrl: String
    private let registrationDelayMinutes: Int = 15
    private var statusCheckTimer: Timer?
    private var heartbeatTimer: Timer?
    private var lastAnnouncedLicenseKey: String?
    private var lastAnnouncedActivationState: Bool = false

    // Device identification
    private let deviceId: String
    private let deviceInfo: DeviceInfo

    // Persistence
    private let licenseKeyKey = "voicelink_license_key"
    private let nodeIdKey = "voicelink_node_id"
    private let serverIdKey = "voicelink_server_id"

    enum LicenseStatus: String {
        case unknown = "unknown"
        case notRegistered = "not_registered"
        case pending = "pending"
        case licensed = "licensed"
        case deviceLimitReached = "device_limit_reached"
        case revoked = "revoked"
        case error = "error"
        case requires2FA = "requires_2fa"
    }

    struct DeviceInfo: Codable {
        let name: String
        let platform: String
        let uuid: String
        let model: String
        let osVersion: String
    }

    struct ActivatedDevice: Identifiable, Codable {
        let id: String
        let name: String
        let platform: String
        let activatedAt: String
        let lastSeen: String
    }

    struct RecentMachine: Identifiable, Codable {
        let id: String
        let name: String
        let platform: String
        let osVersion: String?
        let model: String?
        let state: String
        let lastSeen: String
        let lastActivatedAt: String?
    }

    struct OwnershipPolicy: Codable {
        let billingModel: String?
        let allowsTransfer: Bool
        let requiresManualTransferApproval: Bool
        let transferCooldownDays: Int
    }

    // MARK: - Initialization
    private init() {
        // Get API URL from config or use default
        self.apiBaseUrl = ProcessInfo.processInfo.environment["LICENSING_API_URL"]
            ?? "\(APIEndpointResolver.canonicalMainBase)/api/licensing"

        // Generate device info
        self.deviceInfo = Self.generateDeviceInfo()
        self.deviceId = Self.generateDeviceId(from: deviceInfo)

        // Load saved license
        loadSavedLicense()
    }

    var currentDeviceUUID: String { deviceInfo.uuid }
    var currentDeviceName: String { deviceInfo.name }
    var currentDevicePlatform: String { deviceInfo.platform }
    var currentMachine: RecentMachine? {
        recentMachines.first { $0.id == currentDeviceUUID || $0.name == currentDeviceName }
    }
    var currentMachineNeedsActivation: Bool {
        guard let machine = currentMachine else { return activationRequired }
        return activationRequired || machine.state == "pending_activation" || machine.state == "deactivated"
    }

    // MARK: - Device Identification
    private static func generateDeviceInfo() -> DeviceInfo {
        let name = Host.current().localizedName ?? "Mac"
        let platform = "macOS"
        let uuid = getHardwareUUID() ?? UUID().uuidString
        let model = getModelIdentifier() ?? "Mac"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        return DeviceInfo(
            name: name,
            platform: platform,
            uuid: uuid,
            model: model,
            osVersion: osVersion
        )
    }

    private static func generateDeviceId(from info: DeviceInfo) -> String {
        let data = "\(info.name)\(info.platform)\(info.uuid)"
        return data.data(using: .utf8)?.sha256Hash ?? UUID().uuidString
    }

    private static func getHardwareUUID() -> String? {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )

        guard platformExpert != 0 else { return nil }
        defer { IOObjectRelease(platformExpert) }

        if let serialNumber = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String {
            return serialNumber
        }

        return nil
    }

    private static func getModelIdentifier() -> String? {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    // MARK: - License Persistence
    private func loadSavedLicense() {
        if let savedKey = UserDefaults.standard.string(forKey: licenseKeyKey) {
            self.licenseKey = savedKey
            // Validate on load
            Task {
                await validateLicense()
            }
        }
    }

    private func saveLicense(_ key: String) {
        UserDefaults.standard.set(key, forKey: licenseKeyKey)
        self.licenseKey = key
    }

    private func clearLicense() {
        UserDefaults.standard.removeObject(forKey: licenseKeyKey)
        self.licenseKey = nil
        self.licenseStatus = .notRegistered
        self.activationRequired = false
        self.devices = []
        self.recentMachines = []
        self.primaryEmail = nil
        self.ownershipPolicy = nil
        self.lastEvictedDeviceName = nil
    }

    // MARK: - API Methods

    /// Register this node for licensing (starts 15-min delay)
    /// Requires user to be logged in - uses AuthenticationManager email
    func registerNode(serverId: String, nodeId: String, nodeUrl: String? = nil) async {
        // Check if user is logged in
        guard let identityContext = currentLicensingIdentity() else {
            await MainActor.run {
                errorMessage = "You must be logged in to get a license. Please sign in first."
                licenseStatus = .error
            }
            return
        }

        isChecking = true
        errorMessage = nil

        // Save IDs for later
        UserDefaults.standard.set(serverId, forKey: serverIdKey)
        UserDefaults.standard.set(nodeId, forKey: nodeIdKey)

        do {
            var body: [String: Any] = [
                "serverId": serverId,
                "nodeId": nodeId,
                "nodeUrl": nodeUrl ?? "",
                "identity": identityContext.identity,
                "userId": identityContext.userId,
                "username": identityContext.username,
                "displayName": identityContext.displayName,
                "authProvider": identityContext.authProvider,
                "authMethod": identityContext.authMethod,
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
                "deviceInfo": [
                    "name": deviceInfo.name,
                    "platform": deviceInfo.platform,
                    "uuid": deviceInfo.uuid,
                    "model": deviceInfo.model,
                    "osVersion": deviceInfo.osVersion
                ]
            ]

            if let email = identityContext.email {
                body["email"] = email
            }
            if let fullHandle = identityContext.fullHandle {
                body["fullHandle"] = fullHandle
            }

            let result = try await apiRequest(endpoint: "/register", method: "POST", body: body, identityContext: identityContext)

            if let status = result["status"] as? String {
                switch status {
                case "already_licensed":
                    applyLicenseState(from: result)

                case "pending":
                    applyLicenseState(from: result)
                    licenseStatus = .pending
                    remainingMinutes = result["remainingMinutes"] as? Int ?? registrationDelayMinutes
                    let remainingMs = result["remainingMs"] as? Double ?? Double(registrationDelayMinutes * 60 * 1000)
                    registrationProgress = 1.0 - (remainingMs / Double(registrationDelayMinutes * 60 * 1000))
                    startStatusCheckTimer(serverId: serverId, nodeId: nodeId)

                case "registered":
                    applyLicenseState(from: result)
                    licenseStatus = .pending
                    remainingMinutes = result["remainingMinutes"] as? Int ?? registrationDelayMinutes
                    registrationProgress = 0
                    startStatusCheckTimer(serverId: serverId, nodeId: nodeId)

                case "licensed":
                    applyLicenseState(from: result)
                    startHeartbeat()

                default:
                    errorMessage = result["message"] as? String ?? "Unknown status"
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            licenseStatus = .error
        }

        isChecking = false
    }

    /// Verify with 2FA code after 2FA is required
    func verifyWith2FA() async {
        guard let identityContext = currentLicensingIdentity() else {
            errorMessage = "You must be logged in to verify 2FA."
            return
        }

        guard !twoFactorCode.isEmpty else {
            errorMessage = "Please enter your 2FA code."
            return
        }

        isChecking = true
        errorMessage = nil

        guard let serverId = UserDefaults.standard.string(forKey: serverIdKey),
              let nodeId = UserDefaults.standard.string(forKey: nodeIdKey) else {
            // If no stored IDs, generate new ones
            let newServerId = "server_\(UUID().uuidString.prefix(8))"
            let newNodeId = "node_\(UUID().uuidString.prefix(8))"
            await registerNodeWith2FA(serverId: newServerId, nodeId: newNodeId, identityContext: identityContext)
            return
        }

        await registerNodeWith2FA(serverId: serverId, nodeId: nodeId, identityContext: identityContext)
    }

    private func registerNodeWith2FA(serverId: String, nodeId: String, identityContext: LicensingIdentityContext) async {
        do {
            var body: [String: Any] = [
                "serverId": serverId,
                "nodeId": nodeId,
                "identity": identityContext.identity,
                "userId": identityContext.userId,
                "username": identityContext.username,
                "displayName": identityContext.displayName,
                "authProvider": identityContext.authProvider,
                "authMethod": identityContext.authMethod,
                "twoFactorCode": twoFactorCode,
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
                "deviceInfo": [
                    "name": deviceInfo.name,
                    "platform": deviceInfo.platform,
                    "uuid": deviceInfo.uuid,
                    "model": deviceInfo.model,
                    "osVersion": deviceInfo.osVersion
                ]
            ]

            if let email = identityContext.email {
                body["email"] = email
            }
            if let fullHandle = identityContext.fullHandle {
                body["fullHandle"] = fullHandle
            }

            var result: [String: Any]?
            for base in licensingBaseCandidates() {
                guard let registerURL = URL(string: base + "/register") else { continue }
                var request = URLRequest(url: registerURL)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                applyIdentityHeaders(identityContext, to: &request)
                request.setValue(twoFactorCode, forHTTPHeaderField: "X-2FA-Code")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode) else {
                        continue
                    }
                    result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    if result != nil {
                        break
                    }
                } catch {
                    continue
                }
            }

            guard let result else {
                errorMessage = "Licensing endpoint unavailable"
                licenseStatus = .error
                isChecking = false
                return
            }

            // Clear 2FA code and process result
            twoFactorCode = ""
            requires2FA = false

            if let status = result["status"] as? String {
                switch status {
                case "licensed", "already_licensed":
                    applyLicenseState(from: result)
                    startHeartbeat()
                case "pending", "registered":
                    applyLicenseState(from: result)
                    licenseStatus = .pending
                    remainingMinutes = result["remainingMinutes"] as? Int ?? 15
                    startStatusCheckTimer(serverId: serverId, nodeId: nodeId)
                default:
                    errorMessage = result["message"] as? String ?? "Unknown status"
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            licenseStatus = .error
        }

        isChecking = false
    }

    /// Check license status
    func checkStatus() async {
        guard let serverId = UserDefaults.standard.string(forKey: serverIdKey),
              let nodeId = UserDefaults.standard.string(forKey: nodeIdKey) else {
            licenseStatus = .notRegistered
            return
        }

        isChecking = true
        let identityContext = currentLicensingIdentity()

        do {
            let result = try await apiRequest(endpoint: "/status/\(serverId)/\(nodeId)", method: "GET", identityContext: identityContext)

            if let status = result["status"] as? String {
                switch status {
                case "licensed":
                    applyLicenseState(from: result)
                    stopStatusCheckTimer()
                    startHeartbeat()

                case "pending":
                    applyLicenseState(from: result)
                    licenseStatus = .pending
                    remainingMinutes = result["remainingMinutes"] as? Int ?? 0
                    let remainingMs = result["remainingMs"] as? Double ?? 0
                    let totalMs = Double(registrationDelayMinutes * 60 * 1000)
                    registrationProgress = 1.0 - (remainingMs / totalMs)

                case "not_registered":
                    licenseStatus = .notRegistered
                    stopStatusCheckTimer()

                default:
                    break
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isChecking = false
    }

    /// Validate license and device
    func validateLicense() async {
        guard let key = licenseKey else {
            licenseStatus = .notRegistered
            return
        }

        isChecking = true
        let identityContext = currentLicensingIdentity()

        do {
            let body: [String: Any] = [
                "licenseKey": key,
                "deviceInfo": [
                    "name": deviceInfo.name,
                    "platform": deviceInfo.platform,
                    "uuid": deviceInfo.uuid
                ]
            ]

            let result = try await apiRequest(endpoint: "/validate", method: "POST", body: body, identityContext: identityContext)

            if result["valid"] as? Bool == true {
                applyLicenseState(from: result)
                licenseStatus = currentMachineNeedsActivation ? .deviceLimitReached : .licensed
                if !currentMachineNeedsActivation {
                    startHeartbeat()
                }
            } else if result["deviceActivated"] as? Bool == false {
                applyLicenseState(from: result)
                licenseStatus = .deviceLimitReached
                errorMessage = result["message"] as? String ?? "Device not activated"
            } else {
                applyLicenseState(from: result)
                licenseStatus = .error
                errorMessage = result["error"] as? String ?? "Validation failed"
            }
        } catch {
            errorMessage = error.localizedDescription
            licenseStatus = .error
        }

        isChecking = false
    }

    /// Activate this device on the license
    func activateDevice() async -> Bool {
        guard let key = licenseKey else { return false }

        isChecking = true
        let identityContext = currentLicensingIdentity()

        do {
            let body: [String: Any] = [
                "licenseKey": key,
                "deviceInfo": [
                    "name": deviceInfo.name,
                    "platform": deviceInfo.platform,
                    "uuid": deviceInfo.uuid,
                    "model": deviceInfo.model
                ]
            ]

            let result = try await apiRequest(endpoint: "/activate", method: "POST", body: body, identityContext: identityContext)

            if result["success"] as? Bool == true {
                applyLicenseState(from: result)
                activationRequired = false
                licenseStatus = .licensed
                startHeartbeat()
                isChecking = false
                return true
            } else {
                errorMessage = result["error"] as? String ?? "Activation failed"
                if result["error"] as? String == "Device limit reached" {
                    licenseStatus = .deviceLimitReached
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isChecking = false
        return false
    }

    /// Deactivate a device to free up a slot
    func deactivateDevice(_ deviceId: String) async -> Bool {
        guard let key = licenseKey else { return false }

        isChecking = true
        let identityContext = currentLicensingIdentity()

        do {
            let body: [String: Any] = [
                "licenseKey": key,
                "deviceId": deviceId
            ]

            let result = try await apiRequest(endpoint: "/deactivate", method: "POST", body: body, identityContext: identityContext)

            if result["success"] as? Bool == true {
                applyLicenseState(from: result)
                devices.removeAll { $0.id == deviceId }
                isChecking = false
                return true
            } else {
                errorMessage = result["error"] as? String ?? "Deactivation failed"
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isChecking = false
        return false
    }

    /// Send heartbeat to keep license active
    func sendHeartbeat() async {
        guard let key = licenseKey else { return }
        let identityContext = currentLicensingIdentity()

        let body: [String: Any] = [
            "licenseKey": key,
            "deviceInfo": [
                "name": deviceInfo.name,
                "platform": deviceInfo.platform,
                "uuid": deviceInfo.uuid
            ]
        ]

        do {
            _ = try await apiRequest(endpoint: "/heartbeat", method: "POST", body: body, identityContext: identityContext)
        } catch {
            print("[Licensing] Heartbeat error: \(error.localizedDescription)")
        }
    }

    func refreshForCurrentUser() async {
        guard currentLicensingIdentity() != nil else {
            clearLicense()
            return
        }

        isChecking = true
        defer { isChecking = false }

        do {
            let result = try await apiRequest(endpoint: "/me", method: "GET", identityContext: currentLicensingIdentity())
            if result["status"] as? String == "not_registered" {
                clearLicense()
                return
            }
            applyLicenseState(from: result)
            let status = (result["status"] as? String) ?? "licensed"
            switch status {
            case "pending":
                licenseStatus = .pending
            case "licensed":
                licenseStatus = activationRequired ? .deviceLimitReached : .licensed
                if !activationRequired {
                    startHeartbeat()
                }
            default:
                licenseStatus = activationRequired ? .deviceLimitReached : .licensed
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func syncEntitlementsFromCurrentUser() async {
        guard let identityContext = currentLicensingIdentity() else { return }

        let entitlementPayload = AuthenticationManager.shared.currentUser?.entitlements.reduce(into: [String: Any]()) { partialResult, entry in
            partialResult[entry.key] = entry.value.value
        } ?? [:]
        let source: String
        if entitlementPayload["appStore"] != nil || entitlementPayload["iosPurchases"] != nil {
            source = "app_store"
        } else {
            switch AuthenticationManager.shared.currentUser?.authMethod {
            case .whmcs:
                source = "whmcs"
            case .mastodon:
                source = "mastodon"
            case .email, .adminInvite:
                source = "email"
            case .pairingCode:
                source = "pairing"
            case .none:
                source = "manual"
            }
        }

        var body: [String: Any] = [
            "source": source,
            "identity": identityContext.identity,
            "userId": identityContext.userId,
            "username": identityContext.username,
            "displayName": identityContext.displayName,
            "authProvider": identityContext.authProvider,
            "authMethod": identityContext.authMethod,
            "entitlements": entitlementPayload
        ]

        if let email = identityContext.email {
            body["email"] = email
        }
        if source == "app_store" {
            body["appStore"] = [
                "platform": deviceInfo.platform,
                "productState": entitlementPayload
            ]
        }

        do {
            let result = try await apiRequest(endpoint: "/sync-entitlements", method: "POST", body: body, identityContext: identityContext)
            applyLicenseState(from: result)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Timers

    private func startStatusCheckTimer(serverId: String, nodeId: String) {
        stopStatusCheckTimer()

        // Check every 30 seconds while pending
        statusCheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.checkStatus()
            }
        }
    }

    private func stopStatusCheckTimer() {
        statusCheckTimer?.invalidate()
        statusCheckTimer = nil
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()

        // Send heartbeat every 5 minutes
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.sendHeartbeat()
            }
        }
    }

    // MARK: - Network Helper

    private func apiRequest(endpoint: String, method: String, body: [String: Any]? = nil, identityContext: LicensingIdentityContext? = nil) async throws -> [String: Any] {
        var lastError: Error = URLError(.cannotFindHost)

        for base in licensingBaseCandidates() {
            guard let url = URL(string: base + endpoint) else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            applyIdentityHeaders(identityContext, to: &request)

            if let body = body {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    lastError = URLError(.badServerResponse)
                    continue
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let error = json["error"] as? String {
                        lastError = NSError(domain: "LicensingError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: error])
                    } else {
                        lastError = URLError(.badServerResponse)
                    }
                    continue
                }

                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    lastError = URLError(.cannotParseResponse)
                    continue
                }

                return json
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    private func licensingBaseCandidates() -> [String] {
        var candidates: [String] = [apiBaseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))]
        candidates.append(contentsOf: APIEndpointResolver.apiBaseCandidates(preferred: ServerManager.shared.baseURL).map {
            "\($0)/api/licensing"
        })

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private func currentLicensingIdentity() -> LicensingIdentityContext? {
        guard let currentUser = AuthenticationManager.shared.currentUser else {
            return nil
        }

        let email = sanitized(currentUser.email)
        let username = sanitized(currentUser.username) ?? currentUser.id
        let displayName = sanitized(currentUser.displayName) ?? username
        let authProvider = sanitized(currentUser.authProvider) ?? currentUser.authMethod.rawValue
        let authMethod = currentUser.authMethod.rawValue
        let userId = sanitized(currentUser.id) ?? UUID().uuidString
        let fullHandle = sanitized(currentUser.fullHandle)
        let identity = email ?? fullHandle ?? username

        return LicensingIdentityContext(
            identity: identity,
            authProvider: authProvider,
            authMethod: authMethod,
            userId: userId,
            username: username,
            displayName: displayName,
            email: email,
            fullHandle: fullHandle,
            accessToken: sanitized(currentUser.accessToken)
        )
    }

    private func applyIdentityHeaders(_ identityContext: LicensingIdentityContext?, to request: inout URLRequest) {
        guard let identityContext else { return }

        request.setValue(identityContext.identity, forHTTPHeaderField: "X-User-Identity")
        request.setValue(identityContext.userId, forHTTPHeaderField: "X-User-ID")
        request.setValue(identityContext.username, forHTTPHeaderField: "X-Username")
        request.setValue(identityContext.authProvider, forHTTPHeaderField: "X-Auth-Provider")
        request.setValue(identityContext.authMethod, forHTTPHeaderField: "X-Auth-Method")

        if let email = identityContext.email {
            request.setValue(email, forHTTPHeaderField: "X-User-Email")
        }
        if let fullHandle = identityContext.fullHandle {
            request.setValue(fullHandle, forHTTPHeaderField: "X-User-Full-Handle")
        }
        if let accessToken = identityContext.accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
    }

    private func sanitized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func applyLicenseState(from result: [String: Any]) {
        let previousKey = licenseKey
        let previousActivationRequired = activationRequired

        if let key = result["licenseKey"] as? String, !key.isEmpty {
            saveLicense(key)
        }

        primaryEmail = sanitized(result["primaryEmail"] as? String)
        activatedDevices = result["activatedDevices"] as? Int ?? activatedDevices
        maxDevices = result["maxDevices"] as? Int ?? maxDevices
        remainingSlots = result["remainingSlots"] as? Int ?? max(0, maxDevices - activatedDevices)
        activationRequired = result["activationRequired"] as? Bool ?? false

        if let policy = result["ownershipPolicy"] as? [String: Any] {
            ownershipPolicy = OwnershipPolicy(
                billingModel: policy["billingModel"] as? String,
                allowsTransfer: policy["allowsTransfer"] as? Bool ?? false,
                requiresManualTransferApproval: policy["requiresManualTransferApproval"] as? Bool ?? false,
                transferCooldownDays: policy["transferCooldownDays"] as? Int ?? 30
            )
        } else {
            ownershipPolicy = nil
        }

        if let evicted = result["lastEvictedDevice"] as? [String: Any] {
            lastEvictedDeviceName = sanitized(evicted["name"] as? String) ?? sanitized(evicted["id"] as? String)
        } else {
            lastEvictedDeviceName = nil
        }

        if let devicesData = result["devices"] as? [[String: Any]] {
            devices = devicesData.compactMap { dict in
                guard let id = dict["id"] as? String,
                      let name = dict["name"] as? String else { return nil }
                return ActivatedDevice(
                    id: id,
                    name: name,
                    platform: dict["platform"] as? String ?? "unknown",
                    activatedAt: dict["linkedAt"] as? String ?? dict["activatedAt"] as? String ?? "",
                    lastSeen: dict["lastSeen"] as? String ?? ""
                )
            }
        } else {
            devices = []
        }

        if let machinesData = result["recentMachines"] as? [[String: Any]] {
            recentMachines = machinesData.compactMap { dict in
                let id = (dict["id"] as? String) ?? (dict["uuid"] as? String) ?? UUID().uuidString
                let name = dict["name"] as? String ?? "Unknown Device"
                let platform = dict["platform"] as? String ?? "unknown"
                let state = dict["state"] as? String ?? "seen"
                let lastSeen = dict["lastSeen"] as? String ?? ""
                return RecentMachine(
                    id: id,
                    name: name,
                    platform: platform,
                    osVersion: dict["osVersion"] as? String,
                    model: dict["model"] as? String,
                    state: state,
                    lastSeen: lastSeen,
                    lastActivatedAt: dict["lastActivatedAt"] as? String
                )
            }
        } else {
            recentMachines = []
        }

        if !activationRequired,
           let machine = currentMachine,
           machine.state == "pending_activation" || machine.state == "deactivated" {
            activationRequired = true
        }

        if let key = licenseKey, !key.isEmpty, previousKey != key {
            announceLicenseEvent(
                title: "VoiceLink license assigned",
                message: activationRequired
                    ? "Your account license \(key) is available. Activate this Mac to use it."
                    : "Your account license \(key) is now active on this Mac."
            )
            lastAnnouncedLicenseKey = key
        } else if activationRequired && !previousActivationRequired && lastAnnouncedActivationState != activationRequired {
            announceLicenseEvent(
                title: "VoiceLink activation required",
                message: {
                    if let key = licenseKey, !key.isEmpty {
                        return "This Mac is signed in. License \(key) is assigned to your account and just needs device activation."
                    }
                    return "This Mac is signed in, but it still needs to be activated for your license."
                }()
            )
        }

        lastAnnouncedActivationState = activationRequired
    }

    private func announceLicenseEvent(title: String, message: String) {
        latestLicenseNotice = message
        NotificationCenter.default.post(
            name: .licenseNoticeReceived,
            object: nil,
            userInfo: [
                "title": title,
                "message": message
            ]
        )

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "voicelink.license.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }
}

extension Notification.Name {
    static let licenseNoticeReceived = Notification.Name("licenseNoticeReceived")
}

// MARK: - SHA256 Extension
extension Data {
    var sha256Hash: String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        self.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(self.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}

// Import CommonCrypto for SHA256
import CommonCrypto
