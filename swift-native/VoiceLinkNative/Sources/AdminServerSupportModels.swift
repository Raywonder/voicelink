import Foundation

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

struct ServerSchedulerStatusResponse: Codable {
    let success: Bool
    let status: ServerSchedulerStatus
    let tasks: [ServerSchedulerTask]
    let logs: [ServerSchedulerLogEntry]
}

struct ServerSchedulerStatus: Codable {
    let service: String
    let role: String
    let totalVisibleTasks: Int
    let enabledTasks: Int
    let runningTasks: Int
    let serverTime: String
}

struct ServerSchedulerTask: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let visibility: String
    let allowUserRun: Bool
    let enabled: Bool
    let running: Bool
    let intervalSeconds: Int
    let lastRunAt: String?
    let lastStatus: String
    let lastDurationMs: Int
    let lastMessage: String?
    let nextRunAt: String?
    let action: String?
}

struct ServerSchedulerLogEntry: Codable, Identifiable, Hashable {
    let id: String
    let taskId: String
    let taskName: String
    let actor: String
    let trigger: String
    let status: String
    let message: String?
    let durationMs: Int
    let timestamp: String
}

struct MastodonBotAccount: Codable, Identifiable, Hashable {
    var id: String { instance }
    let instance: String
    let username: String?
    let displayName: String?
    let enabled: Bool
}

struct AuthProviderStatusResponse: Codable {
    let success: Bool
    let providers: [String: AuthProviderHealth]
    let smtp: AuthSmtpStatus
    let recovery: AuthRecoveryStatus
    let scheduler: AuthSchedulerStatus
    let policy: AuthPolicyStatus?
}

struct AuthPolicyStatus: Codable, Hashable {
    let internalProviderEnabled: Bool
    let whmcsProviderEnabled: Bool
    let wordpressProviderEnabled: Bool
    let composrProviderEnabled: Bool
    let sharedMemberAuthEnabled: Bool
    let sharedMemberAuthMode: String
    let sharedMemberAuthProviders: [String]
    let allowWhmcsFallback: Bool
    let allowMastodonApprovalDelivery: Bool
    let requireSecondDeviceApproval: Bool
    let allowedTwoFactorMethods: [String]
}

struct AuthProviderHealth: Codable, Hashable {
    let enabled: Bool
    let health: String
    let label: String?
    let delegated: Bool?
    let portalUrl: String?
    let adminUrl: String?
    let botCount: Int?
}

struct AuthSmtpStatus: Codable, Hashable {
    let configured: Bool
    let health: String
    let host: String?
    let port: Int
    let from: String?
}

struct AuthRecoveryStatus: Codable, Hashable {
    let emailCodesAvailable: Bool
    let smtpRecoveryAvailable: Bool
    let breakGlassConfigured: Bool
}

struct AuthSchedulerStatus: Codable, Hashable {
    let available: Bool
    let health: String
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

struct VoiceLinkFlexPBXHoldMediaEnvelope: Codable {
    let success: Bool
    let holdMedia: VoiceLinkFlexPBXHoldMediaStatus
}

struct VoiceLinkFlexPBXHoldMediaStatus: Codable, Hashable {
    var enabled: Bool
    var optionalSource: Bool
    var autoReload: Bool
    var allowedSourceTypes: [String]
    var globalAssignment: VoiceLinkFlexPBXHoldMediaAssignment
    var roomAssignments: [String: VoiceLinkFlexPBXHoldMediaAssignment]
    var pbxTargets: [VoiceLinkFlexPBXTarget]
    var sources: [VoiceLinkFlexPBXHoldMediaSource]
    var roomCount: Int

    var asRequestPayload: [String: Any] {
        [
            "enabled": enabled,
            "optionalSource": optionalSource,
            "autoReload": autoReload,
            "allowedSourceTypes": allowedSourceTypes,
            "globalAssignment": globalAssignment.asDictionary,
            "roomAssignments": Dictionary(uniqueKeysWithValues: roomAssignments.map { ($0.key, $0.value.asDictionary) }),
            "pbxTargets": pbxTargets.map(\.asDictionary)
        ]
    }
}

struct VoiceLinkFlexPBXHoldMediaAssignment: Codable, Hashable {
    var enabled: Bool
    var sourceType: String
    var sourceId: String
    var mohClass: String
    var targetIds: [String]

    var asDictionary: [String: Any] {
        [
            "enabled": enabled,
            "sourceType": sourceType,
            "sourceId": sourceId,
            "mohClass": mohClass,
            "targetIds": targetIds
        ]
    }
}

struct VoiceLinkFlexPBXTarget: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var apiUrl: String
    var enabled: Bool

    var asDictionary: [String: Any] {
        [
            "id": id,
            "name": name,
            "apiUrl": apiUrl,
            "enabled": enabled
        ]
    }
}

struct VoiceLinkFlexPBXHoldMediaSource: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var sourceType: String
    var description: String
    var streamUrl: String
    var supported: Bool
    var roomId: String?
    var roomName: String?
}

struct VoiceLinkFlexPBXHoldMediaSyncResult: Codable, Hashable {
    let success: Bool
    let syncedAt: Double?
    let targets: [VoiceLinkFlexPBXHoldMediaSyncTarget]
    let classCount: Int?
}

struct VoiceLinkFlexPBXHoldMediaSyncTarget: Codable, Hashable, Identifiable {
    let targetId: String
    let targetName: String
    let apiUrl: String?
    let classes: [VoiceLinkFlexPBXSyncedClass]
    let success: Bool
    let error: String?

    var id: String { targetId }
}

struct VoiceLinkFlexPBXSyncedClass: Codable, Hashable, Identifiable {
    let name: String
    let sourceType: String
    let roomId: String?
    let streamUrl: String?
    let success: Bool

    var id: String { "\(name)|\(roomId ?? "global")" }
}

struct ServerConfigBackupsEnvelope: Codable, Hashable {
    let backups: [ServerConfigBackup]
}

struct ServerConfigBackupCreateResponse: Codable, Hashable {
    let success: Bool
    let path: String?
    let filename: String
}

struct ServerConfigBackup: Codable, Hashable, Identifiable {
    let filename: String
    let path: String?
    let createdAt: String?
    let label: String?
    let size: Int?
    let error: Bool?

    var id: String { filename }
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
    var onboarding: [String: String]
    var owner: [String: String]
    var policy: [String: String]
    var moduleUpdates: [String: String]

    init(
        server: [String: String] = [:],
        federation: [String: String] = [:],
        onboarding: [String: String] = [:],
        owner: [String: String] = [:],
        policy: [String: String] = [:],
        moduleUpdates: [String: String] = [:]
    ) {
        self.server = server
        self.federation = federation
        self.onboarding = onboarding
        self.owner = owner
        self.policy = policy
        self.moduleUpdates = moduleUpdates
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
    var siteRoot: String?
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
