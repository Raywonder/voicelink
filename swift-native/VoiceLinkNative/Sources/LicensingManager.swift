import Foundation
import SwiftUI
import IOKit

/// VoiceLink Licensing Manager
/// Handles node registration, license validation, and device activation
/// - 15 minute delay before license issued
/// - 3 device limit (1 auto + 2 on request)
/// - Deactivate to free slot or purchase more
@MainActor
class LicensingManager: ObservableObject {
    static let shared = LicensingManager()

    // MARK: - Published Properties
    @Published var licenseKey: String?
    @Published var licenseStatus: LicenseStatus = .unknown
    @Published var activatedDevices: Int = 0
    @Published var maxDevices: Int = 3
    @Published var remainingSlots: Int = 3
    @Published var registrationProgress: Double = 0
    @Published var remainingMinutes: Int = 0
    @Published var remainingSeconds: Int = 0
    @Published var isChecking: Bool = false
    @Published var errorMessage: String?
    @Published var devices: [ActivatedDevice] = []
    @Published var retryAttempts: Int = 0
    @Published var supportTicketId: String?
    @Published var supportTicketNumber: String?

    // 2FA support
    @Published var requires2FA: Bool = false
    @Published var twoFactorCode: String = ""
    @Published var show2FAPrompt: Bool = false

    // MARK: - Configuration
    private let apiBaseUrl: String
    private let registrationDelayMinutes: Int = 15
    private var statusCheckTimer: Timer?
    private var heartbeatTimer: Timer?
    private var countdownTimer: Timer?
    private var pendingUntilDate: Date?
    private var hasEscalatedPendingFailure = false

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
            self.licenseStatus = .unknown

            // Only validate immediately if the authenticated user is already available.
            if AuthenticationManager.shared.currentUser != nil {
                Task {
                    await validateLicense()
                }
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
        self.pendingUntilDate = nil
        self.remainingMinutes = 0
        self.remainingSeconds = 0
        self.retryAttempts = 0
        self.supportTicketId = nil
        self.supportTicketNumber = nil
    }

    func syncEntitlementsFromCurrentUser() async {
        guard let user = AuthenticationManager.shared.currentUser else { return }

        if let maxDevices = user.entitlements["maxDevices"]?.value as? Int {
            self.maxDevices = max(maxDevices, 1)
            remainingSlots = max(self.maxDevices - activatedDevices, 0)
        }

        await syncCurrentUserEntitlementsToAuthority(user)
    }

    func refreshForCurrentUser() async {
        guard AuthenticationManager.shared.currentUser != nil else {
            licenseStatus = licenseKey == nil ? .notRegistered : .error
            return
        }

        if await fetchCurrentLicenseForAuthenticatedUser() {
            return
        }

        if licenseKey != nil {
            await validateLicense()
        } else {
            licenseStatus = .notRegistered
        }
    }

    // MARK: - API Methods

    /// Register this node for licensing (starts 15-min delay)
    /// Requires user to be logged in - uses AuthenticationManager email
    func registerNode(serverId: String, nodeId: String, nodeUrl: String? = nil) async {
        // Check if user is logged in
        guard let currentUser = AuthenticationManager.shared.currentUser,
              let userEmail = currentUser.email else {
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
            let body: [String: Any] = [
                "serverId": serverId,
                "nodeId": nodeId,
                "nodeUrl": nodeUrl ?? "",
                "email": userEmail,  // Required for WHMCS authentication
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
                "deviceInfo": [
                    "name": deviceInfo.name,
                    "platform": deviceInfo.platform,
                    "uuid": deviceInfo.uuid,
                    "model": deviceInfo.model,
                    "osVersion": deviceInfo.osVersion
                ]
            ]

            let result = try await apiRequest(endpoint: "/register", method: "POST", body: body, userEmail: userEmail)

            if let status = result["status"] as? String {
                switch status {
                case "already_licensed":
                    if let key = result["licenseKey"] as? String {
                        saveLicense(key)
                        licenseStatus = .licensed
                        activatedDevices = result["activatedDevices"] as? Int ?? 0
                        maxDevices = result["maxDevices"] as? Int ?? 3
                        remainingSlots = maxDevices - activatedDevices
                    }

                case "pending":
                    applyPendingStatus(result)
                    startStatusCheckTimer(serverId: serverId, nodeId: nodeId)

                case "registered":
                    applyPendingStatus(result)
                    startStatusCheckTimer(serverId: serverId, nodeId: nodeId)

                case "licensed":
                    if let key = result["licenseKey"] as? String {
                        saveLicense(key)
                        licenseStatus = .licensed
                        pendingUntilDate = nil
                        remainingMinutes = 0
                        remainingSeconds = 0
                        retryAttempts = 0
                        supportTicketId = nil
                        supportTicketNumber = nil
                        activatedDevices = result["activatedDevices"] as? Int ?? 0
                        maxDevices = result["maxDevices"] as? Int ?? 3
                        remainingSlots = result["remainingSlots"] as? Int ?? (maxDevices - activatedDevices)
                        stopStatusCheckTimer()
                        startHeartbeat()
                    }

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
        guard let currentUser = AuthenticationManager.shared.currentUser,
              let userEmail = currentUser.email else {
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
            await registerNodeWith2FA(serverId: newServerId, nodeId: newNodeId, email: userEmail)
            return
        }

        await registerNodeWith2FA(serverId: serverId, nodeId: nodeId, email: userEmail)
    }

    private func registerNodeWith2FA(serverId: String, nodeId: String, email: String) async {
        do {
            let body: [String: Any] = [
                "serverId": serverId,
                "nodeId": nodeId,
                "email": email,
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

            var result: [String: Any]?
            for base in licensingBaseCandidates() {
                guard let registerURL = URL(string: base + "/register") else { continue }
                var request = URLRequest(url: registerURL)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(email, forHTTPHeaderField: "X-User-Email")
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
                    if let key = result["licenseKey"] as? String {
                        saveLicense(key)
                        licenseStatus = .licensed
                        activatedDevices = result["activatedDevices"] as? Int ?? 0
                        maxDevices = result["maxDevices"] as? Int ?? 3
                        remainingSlots = result["remainingSlots"] as? Int ?? (maxDevices - activatedDevices)
                        startHeartbeat()
                    }
                case "pending", "registered":
                    applyPendingStatus(result)
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
            if await fetchCurrentLicenseForAuthenticatedUser() {
                return
            }
            if licenseKey != nil {
                await validateLicense()
            } else {
                licenseStatus = .notRegistered
            }
            return
        }

        isChecking = true

        do {
            let result = try await apiRequest(endpoint: "/status/\(serverId)/\(nodeId)", method: "GET")

            if let status = result["status"] as? String {
                switch status {
                case "licensed":
                    if let key = result["licenseKey"] as? String {
                        saveLicense(key)
                        licenseStatus = .licensed
                        activatedDevices = result["activatedDevices"] as? Int ?? 0
                        maxDevices = result["maxDevices"] as? Int ?? 3
                        remainingSlots = result["remainingSlots"] as? Int ?? (maxDevices - activatedDevices)

                        // Parse devices
                        if let devicesData = result["devices"] as? [[String: Any]] {
                            devices = devicesData.compactMap { dict in
                                guard let id = dict["id"] as? String,
                                      let name = dict["name"] as? String else { return nil }
                                return ActivatedDevice(
                                    id: id,
                                    name: name,
                                    platform: dict["platform"] as? String ?? "unknown",
                                    activatedAt: dict["activatedAt"] as? String ?? "",
                                    lastSeen: dict["lastSeen"] as? String ?? ""
                                )
                            }
                        }

                        stopStatusCheckTimer()
                        startHeartbeat()
                    }

                case "pending":
                    applyPendingStatus(result)

                case "not_registered":
                    if pendingUntilDate != nil || licenseStatus == .pending {
                        await handlePendingStatusFailure(serverId: serverId, nodeId: nodeId, reason: "Server still reports pending registration as unavailable.")
                    } else {
                        licenseStatus = .notRegistered
                        stopStatusCheckTimer()
                    }

                default:
                    break
                }
            }
        } catch {
            if licenseStatus == .pending || pendingUntilDate != nil {
                await handlePendingStatusFailure(serverId: serverId, nodeId: nodeId, reason: error.localizedDescription)
            } else {
                errorMessage = error.localizedDescription
            }
        }

        isChecking = false
    }

    /// Validate license and device
    func validateLicense() async {
        guard let key = licenseKey else {
            if await fetchCurrentLicenseForAuthenticatedUser() {
                return
            }
            licenseStatus = .notRegistered
            return
        }
        guard AuthenticationManager.shared.currentUser != nil else {
            licenseStatus = .unknown
            errorMessage = nil
            return
        }

        isChecking = true

        do {
            let body: [String: Any] = [
                "licenseKey": key,
                "deviceInfo": [
                    "name": deviceInfo.name,
                    "platform": deviceInfo.platform,
                    "uuid": deviceInfo.uuid
                ]
            ]

            let result = try await apiRequest(endpoint: "/validate", method: "POST", body: body)

            if result["valid"] as? Bool == true {
                licenseStatus = .licensed
                startHeartbeat()
            } else if result["deviceActivated"] as? Bool == false {
                licenseStatus = .deviceLimitReached
                errorMessage = result["message"] as? String ?? "Device not activated"
            } else {
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
        guard AuthenticationManager.shared.currentUser != nil else {
            errorMessage = "You must be signed in to activate this device."
            return false
        }

        isChecking = true

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

            let result = try await apiRequest(endpoint: "/activate", method: "POST", body: body)

            if result["success"] as? Bool == true {
                activatedDevices = result["activatedDevices"] as? Int ?? activatedDevices + 1
                remainingSlots = result["remainingSlots"] as? Int ?? (maxDevices - activatedDevices)
                licenseStatus = .licensed
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
        guard AuthenticationManager.shared.currentUser != nil else {
            errorMessage = "You must be signed in to manage activated devices."
            return false
        }

        isChecking = true

        do {
            let body: [String: Any] = [
                "licenseKey": key,
                "deviceId": deviceId
            ]

            let result = try await apiRequest(endpoint: "/deactivate", method: "POST", body: body)

            if result["success"] as? Bool == true {
                activatedDevices = result["activatedDevices"] as? Int ?? max(0, activatedDevices - 1)
                remainingSlots = result["remainingSlots"] as? Int ?? (maxDevices - activatedDevices)
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
        guard AuthenticationManager.shared.currentUser != nil else { return }

        let body: [String: Any] = [
            "licenseKey": key,
            "deviceInfo": [
                "name": deviceInfo.name,
                "platform": deviceInfo.platform,
                "uuid": deviceInfo.uuid
            ]
        ]

        do {
            _ = try await apiRequest(endpoint: "/heartbeat", method: "POST", body: body)
        } catch {
            print("[Licensing] Heartbeat error: \(error.localizedDescription)")
        }
    }

    // MARK: - Timers

    private func startStatusCheckTimer(serverId: String, nodeId: String) {
        stopStatusCheckTimer()
        startCountdownTimer()

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
        countdownTimer?.invalidate()
        countdownTimer = nil
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

    private func applyPendingStatus(_ result: [String: Any]) {
        licenseStatus = .pending
        let remainingMs = result["remainingMs"] as? Double
            ?? Double((result["remainingSeconds"] as? Int ?? (result["remainingMinutes"] as? Int ?? registrationDelayMinutes) * 60) * 1000)
        remainingSeconds = max(0, Int(ceil(remainingMs / 1000.0)))
        remainingMinutes = max(0, Int(ceil(Double(remainingSeconds) / 60.0)))
        let totalMs = max(Double(registrationDelayMinutes * 60 * 1000), remainingMs)
        registrationProgress = min(1.0, max(0.0, 1.0 - (remainingMs / totalMs)))
        pendingUntilDate = Date().addingTimeInterval(TimeInterval(remainingSeconds))
        hasEscalatedPendingFailure = false
    }

    private func syncCurrentUserEntitlementsToAuthority(_ user: AuthenticatedUser) async {
        let entitlements = user.entitlements.mapValues(\.value)
        guard !entitlements.isEmpty else { return }

        let provider = (user.authProvider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().isEmpty == false)
            ? user.authProvider!.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            : user.authMethod.rawValue

        do {
            _ = try await apiRequest(
                endpoint: "/sync-entitlements",
                method: "POST",
                body: [
                    "source": provider,
                    "provider": provider,
                    "entitlements": entitlements
                ]
            )
        } catch {
            // Keep UI quiet here; this is background alignment work.
        }
    }

    private func applyLicenseSnapshot(_ result: [String: Any], persistKey: Bool) {
        if let key = result["licenseKey"] as? String, !key.isEmpty {
            if persistKey {
                saveLicense(key)
            } else {
                licenseKey = key
            }
        }

        let status = String(result["status"] as? String ?? "").lowercased()
        switch status {
        case "pending":
            applyPendingStatus(result)
        case "licensed", "already_licensed":
            licenseStatus = .licensed
            pendingUntilDate = nil
            remainingMinutes = 0
            remainingSeconds = 0
            retryAttempts = 0
            supportTicketId = nil
            supportTicketNumber = nil
            activatedDevices = result["activatedDevices"] as? Int ?? 0
            maxDevices = result["maxDevices"] as? Int ?? maxDevices
            remainingSlots = result["remainingSlots"] as? Int ?? max(0, maxDevices - activatedDevices)

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
            }
            startHeartbeat()
        case "device_limit_reached":
            licenseStatus = .deviceLimitReached
        case "not_registered":
            licenseStatus = .notRegistered
        default:
            break
        }

        if let installs = result["linkedServers"] as? [[String: Any]], !installs.isEmpty {
            PairingManager.shared.syncServersFromAuthority(installs)
        }
    }

    private func fetchCurrentLicenseForAuthenticatedUser() async -> Bool {
        do {
            let result = try await apiRequest(endpoint: "/me", method: "GET")
            guard result["success"] as? Bool != false else { return false }
            applyLicenseSnapshot(result, persistKey: true)
            return true
        } catch {
            return false
        }
    }

    private func startCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.licenseStatus == .pending else { return }
                if let pendingUntilDate = self.pendingUntilDate {
                    let seconds = max(0, Int(ceil(pendingUntilDate.timeIntervalSinceNow)))
                    self.remainingSeconds = seconds
                    self.remainingMinutes = max(0, Int(ceil(Double(seconds) / 60.0)))
                    let totalSeconds = max(self.registrationDelayMinutes * 60, 1)
                    self.registrationProgress = min(1.0, max(0.0, 1.0 - (Double(seconds) / Double(totalSeconds))))
                }
            }
        }
    }

    private func handlePendingStatusFailure(serverId: String, nodeId: String, reason: String) async {
        errorMessage = reason
        let secondsRemaining = max(remainingSeconds, Int(ceil((pendingUntilDate?.timeIntervalSinceNow ?? 0))))
        if secondsRemaining > 0 {
            licenseStatus = .pending
            return
        }

        if retryAttempts < 2 {
            retryAttempts += 1
            await retryPendingRegistration(serverId: serverId, nodeId: nodeId)
            return
        }

        if !hasEscalatedPendingFailure {
            hasEscalatedPendingFailure = true
            await createLicensingSupportTicket(serverId: serverId, nodeId: nodeId, reason: reason)
        }
    }

    private func retryPendingRegistration(serverId: String, nodeId: String) async {
        guard AuthenticationManager.shared.currentUser?.email != nil else { return }
        do {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            await registerNode(serverId: serverId, nodeId: nodeId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createLicensingSupportTicket(serverId: String, nodeId: String, reason: String) async {
        guard let currentUser = AuthenticationManager.shared.currentUser else { return }
        let body: [String: Any] = [
            "retryAttempts": retryAttempts
        ]

        do {
            let result = try await apiRequest(endpoint: "/escalate/\(serverId)/\(nodeId)", method: "POST", body: body, userEmail: currentUser.email)
            supportTicketId = result["ticketId"] as? String
            supportTicketNumber = result["ticketNumber"] as? String
            errorMessage = "License generation is delayed. Support ticket \(supportTicketNumber ?? supportTicketId ?? "created") was opened."
        } catch {
            let ticketBody: [String: Any] = [
                "subject": "VoiceLink licensing pending for \(serverId)",
                "description": [
                    "VoiceLink could not finish automatic license generation within the pending grace window.",
                    "Server ID: \(serverId)",
                    "Node ID: \(nodeId)",
                    "Retry attempts: \(retryAttempts)",
                    "Reason: \(reason)"
                ].joined(separator: "\n"),
                "priority": "high",
                "category": "technical",
                "channel": "voicelink",
                "userId": currentUser.id,
                "userName": currentUser.displayName,
                "userEmail": currentUser.email ?? ""
            ]
            do {
                let result = try await supportRequest(endpoint: "/api/support/tickets", body: ticketBody)
                supportTicketId = result["ticketId"] as? String ?? result["id"] as? String
                supportTicketNumber = result["ticketNumber"] as? String
                errorMessage = "License setup is taking longer than expected, so VoiceLink opened an internal support ticket (\(supportTicketNumber ?? supportTicketId ?? "created")). Nothing is lost, and the app will keep trying in the background."
            } catch {
                errorMessage = "License setup is still delayed, and VoiceLink could not open the internal support ticket automatically. \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Network Helper

    private func apiRequest(endpoint: String, method: String, body: [String: Any]? = nil, userEmail: String? = nil) async throws -> [String: Any] {
        var lastError: Error = URLError(.cannotFindHost)
        let accessToken = AuthenticationManager.shared.currentUser?.accessToken

        for base in licensingBaseCandidates() {
            guard let url = URL(string: base + endpoint) else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            if let email = userEmail {
                request.setValue(email, forHTTPHeaderField: "X-User-Email")
            }
            if let accessToken, !accessToken.isEmpty {
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            }

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

    private func supportRequest(endpoint: String, body: [String: Any]) async throws -> [String: Any] {
        var lastError: Error = URLError(.cannotFindHost)
        let accessToken = AuthenticationManager.shared.currentUser?.accessToken

        for base in APIEndpointResolver.apiBaseCandidates(preferred: ServerManager.shared.baseURL) {
            guard let url = URL(string: base + endpoint) else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let accessToken, !accessToken.isEmpty {
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    lastError = URLError(.badServerResponse)
                    continue
                }
                guard (200...299).contains(httpResponse.statusCode) else {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let error = json["error"] as? String {
                        lastError = NSError(domain: "SupportError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: error])
                    } else {
                        lastError = URLError(.badServerResponse)
                    }
                    continue
                }
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return json
                }
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
