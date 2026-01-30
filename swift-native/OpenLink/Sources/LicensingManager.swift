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
    @Published var isChecking: Bool = false
    @Published var errorMessage: String?
    @Published var devices: [ActivatedDevice] = []

    // MARK: - Configuration
    private let apiBaseUrl: String
    private let registrationDelayMinutes: Int = 15
    private var statusCheckTimer: Timer?
    private var heartbeatTimer: Timer?

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
            ?? "https://voicelink.devinecreations.net/api/licensing"

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
    }

    // MARK: - API Methods

    /// Register this node for licensing (starts 15-min delay)
    func registerNode(serverId: String, nodeId: String, nodeUrl: String? = nil) async {
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
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
                "deviceInfo": [
                    "name": deviceInfo.name,
                    "platform": deviceInfo.platform,
                    "uuid": deviceInfo.uuid,
                    "model": deviceInfo.model,
                    "osVersion": deviceInfo.osVersion
                ]
            ]

            let result = try await apiRequest(endpoint: "/register", method: "POST", body: body)

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
                    licenseStatus = .pending
                    remainingMinutes = result["remainingMinutes"] as? Int ?? registrationDelayMinutes
                    let remainingMs = result["remainingMs"] as? Double ?? Double(registrationDelayMinutes * 60 * 1000)
                    registrationProgress = 1.0 - (remainingMs / Double(registrationDelayMinutes * 60 * 1000))
                    startStatusCheckTimer(serverId: serverId, nodeId: nodeId)

                case "registered":
                    licenseStatus = .pending
                    remainingMinutes = result["remainingMinutes"] as? Int ?? registrationDelayMinutes
                    registrationProgress = 0
                    startStatusCheckTimer(serverId: serverId, nodeId: nodeId)

                case "licensed":
                    if let key = result["licenseKey"] as? String {
                        saveLicense(key)
                        licenseStatus = .licensed
                        activatedDevices = result["activatedDevices"] as? Int ?? 0
                        maxDevices = result["maxDevices"] as? Int ?? 3
                        remainingSlots = result["remainingSlots"] as? Int ?? (maxDevices - activatedDevices)
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

    /// Check license status
    func checkStatus() async {
        guard let serverId = UserDefaults.standard.string(forKey: serverIdKey),
              let nodeId = UserDefaults.standard.string(forKey: nodeIdKey) else {
            licenseStatus = .notRegistered
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

        // Check every 30 seconds while pending
        statusCheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
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
            Task { @MainActor in
                await self?.sendHeartbeat()
            }
        }
    }

    // MARK: - Network Helper

    private func apiRequest(endpoint: String, method: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let url = URL(string: apiBaseUrl + endpoint) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? String {
                throw NSError(domain: "LicensingError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: error])
            }
            throw URLError(.badServerResponse)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        return json
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
