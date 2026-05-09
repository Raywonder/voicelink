import SwiftUI

// MARK: - Deployment Section
struct AdminDeploymentSection: View {
    @ObservedObject var adminManager = AdminServerManager.shared
    @ObservedObject private var authManager = AuthenticationManager.shared
    @AppStorage("voicelink.deployment.autoDetectDeployment") private var autoDetectDeployment = true
    @AppStorage("voicelink.deployment.showAdvancedOptions") private var showAdvancedDeploymentOptions = false
    @AppStorage("voicelink.deployment.defaultTransport") private var selectedTransport = "sftp"
    @AppStorage("voicelink.deployment.defaultSiteType") private var selectedSiteType = "auto"
    @State private var packagePreset = ""
    @State private var targetLabel = ""
    @State private var targetServerUrl = ""
    @State private var ownerEmail = ""
    @State private var trustedServers = ""
    @State private var sanitize = true
    @State private var linkedToMain = true
    @State private var deploymentMode = "fresh"
    @State private var sourceInstallUrl = ""
    @State private var masterApiUrl = "https://voicelink.dev"
    @State private var secondaryApiUrl = "https://voicelinkapp.app"
    @State private var masterCommunityApiUrl = "https://community.voicelinkapp.app"
    @State private var localAssetFallback = true
    @State private var notifyModuleUpdates = true
    @State private var targetHost = ""
    @State private var targetPort = ""
    @State private var remotePath = ""
    @State private var siteRoot = ""
    @State private var uploadUrl = ""
    @State private var username = ""
    @State private var password = ""
    @State private var httpMethod = "PUT"
    @State private var insecure = false
    @State private var bootstrap = true
    @State private var apiBaseUrl = ""
    @State private var apiToken = ""
    @State private var sharedSecret = ""
    @State private var restartAfterBootstrap = false
    @State private var restartUrl = ""
    @State private var restartMethod = "POST"
    @State private var setupMode = "existing-or-new"
    @State private var accountLinkMode = "shared-identity"
    @State private var portalAccountAction = "create-or-link"
    @State private var linkAllProviders = true
    @State private var reuseFirstGeneratedLicense = true
    @State private var firstLicensePreference = "first-generated"
    @State private var defaultServerTier = "free-limited"
    @State private var allowPaidFeatureUnlocks = true
    @State private var lastPackage: DeploymentPackageResponse?
    @State private var lastDeployment: DeploymentExecutionResponse?
    @State private var actionInFlight = false

    private var availableTransports: [DeploymentTransportInfo] {
        if adminManager.deploymentTransports.isEmpty {
            return adminManager.deploymentManagerStatus?.supportedTransports ?? []
        }
        return adminManager.deploymentTransports
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AdminHelpSection(
                title: "Quick Help",
                summary: "Deployment Manager packages a VoiceLink install, uploads it to another server over SFTP, SMB, HTTP, or HTTPS, bootstraps the remote API config, and can email the owner a getting-started note.",
                steps: [
                    "Generate a package when you need a fresh install bundle or want to stage an update on another server account.",
                    "Use Deploy when you already know the target transport and want VoiceLink to upload, bootstrap, and optionally restart the remote install.",
                    "Use Email Owner after a successful package or deploy so the server owner gets the remote URL, API base, and startup instructions."
                ],
                docs: [
                    AdminDocLink(title: "Deployment Docs", localRelativePath: "authenticated/admin-panel.html", webPath: "/docs/authenticated/admin-panel.html", adminWebPath: "/docs/authenticated/admin-panel.html"),
                    AdminDocLink(title: "Install Docs", localRelativePath: "installation/index.html", webPath: "/docs/installation/index.html", adminWebPath: "/docs/authenticated/admin-panel.html"),
                    AdminDocLink(title: "Installatron Docs", localRelativePath: "INSTALLATRON_BROWSER_UI_INTEGRATION.md", webPath: "/docs/INSTALLATRON_BROWSER_UI_INTEGRATION.md", adminWebPath: "/docs/authenticated/admin-panel.html")
                ]
            )

            statusSection
            packageSection
            onboardingSection
            detectionSection
            transportSection
            bootstrapSection
            actionSection
            resultsSection
        }
        .task {
            _ = await adminManager.fetchDeploymentManagerStatus()
            _ = await adminManager.fetchDeploymentTransports()
            if let base = adminManager.serverConfig?.serverName, targetLabel.isEmpty {
                targetLabel = "\(base) Remote Install"
            }
        }
    }

    private var detectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Detection")
            Text("Enter the server or site details first. VoiceLink will try to detect the best deployment method, site type, and install path automatically. Use Advanced only when you need to override the detected choices.")
                .font(.caption)
                .foregroundColor(.gray)

            HStack(spacing: 20) {
                ConfigToggle(label: "Auto-detect deployment method first", isOn: $autoDetectDeployment)
                ConfigToggle(label: "Show advanced deployment options", isOn: $showAdvancedDeploymentOptions)
            }

            Button("Use Current Choices as Default") {
                saveCurrentDeploymentDefaults()
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Saves the current deployment detection and advanced option choices as the default behavior for future server deployments.")

            VStack(alignment: .leading, spacing: 8) {
                Text(autoDetectDeployment ? "Detected and Will Be Used" : "Current Deployment Choices")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                Text("Transport: \(effectiveTransportLabel)")
                    .font(.caption)
                    .foregroundColor(.white)
                Text("Site Type: \(effectiveSiteTypeLabel)")
                    .font(.caption)
                    .foregroundColor(.white)
                Text("Install Path: \(effectiveRemotePathLabel)")
                    .font(.caption)
                    .foregroundColor(.white)
                Text("Site Root: \(effectiveSiteRootLabel)")
                    .font(.caption)
                    .foregroundColor(.white)
                if !detectedReason.isEmpty {
                    Text(detectedReason)
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                Text(autoDetectDeployment
                     ? "VoiceLink will use these detected values unless you open Advanced and override them."
                     : "VoiceLink will use your current manual deployment choices.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color.white.opacity(0.04))
            .cornerRadius(10)
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Deployment Manager")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Button("Refresh") {
                    Task {
                        _ = await adminManager.fetchDeploymentManagerStatus()
                        _ = await adminManager.fetchDeploymentTransports()
                    }
                }
                .buttonStyle(.bordered)
            }

            if let status = adminManager.deploymentManagerStatus {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ConfigSummaryItem(label: "Module Enabled", value: status.enabled ? "Yes" : "No")
                    ConfigSummaryItem(label: "Mail Ready", value: status.mailConfigured ? "Yes" : "No")
                    ConfigSummaryItem(label: "Fresh Install Bundles", value: status.supportsFreshInstall ? "Supported" : "Unavailable")
                    ConfigSummaryItem(label: "Remote Bootstrap", value: status.supportsRemoteBootstrap ? "Supported" : "Unavailable")
                }
            } else {
                Text("Deployment manager status has not loaded yet.")
                    .foregroundColor(.gray)
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }

    private var packageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Package Options")
            Text("These values are embedded into the generated deployment package. Linked-to-main packages preserve trusted federation defaults and API alignment.")
                .font(.caption)
                .foregroundColor(.gray)

            HStack(spacing: 12) {
                ConfigTextField(label: "Preset", text: $packagePreset)
                ConfigTextField(label: "Target Label", text: $targetLabel)
            }

            HStack(spacing: 12) {
                ConfigTextField(label: "Target Server URL", text: $targetServerUrl)
                ConfigTextField(label: "Owner Email", text: $ownerEmail)
            }

            ConfigTextField(label: "Trusted Servers (comma separated)", text: $trustedServers)

            HStack(spacing: 20) {
                ConfigToggle(label: "Sanitize secrets in package", isOn: $sanitize)
                ConfigToggle(label: "Link package to main cluster", isOn: $linkedToMain)
            }

            Picker("Deployment Mode", selection: $deploymentMode) {
                Text("Fresh Install").tag("fresh")
                Text("Clone Existing Install").tag("clone")
                Text("Update Existing Install").tag("update-existing")
            }
            .pickerStyle(.menu)

            if deploymentMode == "clone" {
                ConfigTextField(label: "Source Install URL or Path", text: $sourceInstallUrl)
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }

    private var transportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Transport")
            if showAdvancedDeploymentOptions {
                Picker("Transport", selection: $selectedTransport) {
                    ForEach(availableTransports) { transport in
                        Text(transport.name).tag(transport.id)
                    }
                    if availableTransports.isEmpty {
                        Text("SFTP").tag("sftp")
                        Text("SMB").tag("smb")
                        Text("HTTP").tag("http")
                        Text("HTTPS").tag("https")
                    }
                }
                .pickerStyle(.menu)

                Picker("Site Type", selection: $selectedSiteType) {
                    Text("Auto Detect").tag("auto")
                    Text("WordPress").tag("wordpress")
                    Text("Composr").tag("composr")
                    Text("WHMCS").tag("whmcs")
                    Text("cPanel").tag("cpanel")
                    Text("Installatron").tag("installatron")
                    Text("Plain App Install").tag("plain")
                }
                .pickerStyle(.menu)

                if let transport = availableTransports.first(where: { $0.id == selectedTransport }) {
                    Text(transport.description)
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                if effectiveTransport == "http" || effectiveTransport == "https" {
                    ConfigTextField(label: "Upload URL", text: $uploadUrl)
                } else {
                    HStack(spacing: 12) {
                        ConfigTextField(label: "Host", text: $targetHost)
                        ConfigTextField(label: "Port", text: $targetPort)
                        ConfigTextField(label: "Remote Path", text: $remotePath)
                    }
                }

                ConfigTextField(label: "Site Root Override", text: $siteRoot)

                HStack(spacing: 12) {
                    ConfigTextField(label: "Username", text: $username)
                    ConfigSecureField(label: "Password", text: $password)
                }

                if effectiveTransport == "http" || effectiveTransport == "https" {
                    Picker("HTTP Method", selection: $httpMethod) {
                        Text("PUT").tag("PUT")
                        Text("POST").tag("POST")
                    }
                    .pickerStyle(.segmented)
                    ConfigToggle(label: "Allow insecure TLS", isOn: $insecure)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Transport: \(detectedTransportLabel)")
                        .font(.caption)
                        .foregroundColor(.white)
                    Text("Site Type: \(detectedSiteTypeLabel)")
                        .font(.caption)
                        .foregroundColor(.white)
                    Text("Install Path: \(detectedRemotePathLabel)")
                        .font(.caption)
                        .foregroundColor(.white)
                }
                .padding(12)
                .background(Color.white.opacity(0.04))
                .cornerRadius(10)
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }

    private var onboardingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Owner Account and License Link")
            Text("Deployment Manager can stage the latest server install, then let the first admin finish setup with an existing or new VoiceLink account, plus a linked Client Portal account when needed.")
                .font(.caption)
                .foregroundColor(.gray)

            Picker("Account Setup", selection: $setupMode) {
                Text("Use Existing or Create New").tag("existing-or-new")
                Text("Use Existing Account Only").tag("existing-only")
                Text("Create New Account First").tag("new-only")
            }
            .pickerStyle(.menu)

            Picker("Identity Link Mode", selection: $accountLinkMode) {
                Text("Shared Identity").tag("shared-identity")
                Text("Separate Identities Allowed").tag("separate-identities")
            }
            .pickerStyle(.menu)

            Picker("Client Portal Action", selection: $portalAccountAction) {
                Text("Create or Link Portal Account").tag("create-or-link")
                Text("Link Existing Portal Account").tag("link-existing")
                Text("Create Portal Account").tag("create-new")
            }
            .pickerStyle(.menu)

            Picker("First License Source", selection: $firstLicensePreference) {
                Text("Whichever Is Generated First").tag("first-generated")
                Text("Prefer Server License").tag("prefer-server")
                Text("Prefer Desktop Client License").tag("prefer-client")
            }
            .pickerStyle(.menu)

            Picker("Default Server Tier", selection: $defaultServerTier) {
                Text("Free with Limits").tag("free-limited")
                Text("Paid / Extended Features").tag("paid-extended")
                Text("All Features Unlocked").tag("all-features")
            }
            .pickerStyle(.menu)

            HStack(spacing: 20) {
                ConfigToggle(label: "Auto-link VoiceLink and portal identities", isOn: $linkAllProviders)
                ConfigToggle(label: "Reuse the first generated license key", isOn: $reuseFirstGeneratedLicense)
            }

            ConfigToggle(label: "Offer payments for extended or full features", isOn: $allowPaidFeatureUnlocks)

            if let currentUser = authManager.currentUser {
                Text("Signed-in owner account: \(currentUser.displayName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("No owner account is signed in on this Mac yet. The deployed server can still prompt the first admin to sign in or create one.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("Recommended default: start new self-hosted installs on the free tier with feature limits, then unlock extended or full server features through the linked payment and portal flow.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }

    private var bootstrapSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Remote Bootstrap")

            ConfigToggle(label: "Bootstrap remote API after upload", isOn: $bootstrap)

            if bootstrap {
                ConfigTextField(label: "Remote API Base URL", text: $apiBaseUrl)
                ConfigTextField(label: ".dev Master API URL", text: $masterApiUrl)
                ConfigTextField(label: "Secondary Main API URL", text: $secondaryApiUrl)
                ConfigTextField(label: "Community Fallback API URL", text: $masterCommunityApiUrl)
                HStack(spacing: 12) {
                    ConfigSecureField(label: "API Token", text: $apiToken)
                    ConfigSecureField(label: "Shared Secret", text: $sharedSecret)
                }
                HStack(spacing: 20) {
                    ConfigToggle(label: "Use local assets before remote fallback", isOn: $localAssetFallback)
                    ConfigToggle(label: "Notify clients when module updates are available", isOn: $notifyModuleUpdates)
                }
                ConfigToggle(label: "Restart remote install after bootstrap", isOn: $restartAfterBootstrap)
                if restartAfterBootstrap {
                    HStack(spacing: 12) {
                        ConfigTextField(label: "Restart URL", text: $restartUrl)
                        ConfigTextField(label: "Restart Method", text: $restartMethod)
                    }
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }

    private var actionSection: some View {
        HStack(spacing: 12) {
            Button("Generate Package") {
                Task { await generatePackage() }
            }
            .buttonStyle(.bordered)

            Button("Deploy to Target") {
                Task { await deployToTarget() }
            }
            .buttonStyle(.borderedProminent)

            Button("Email Owner Details") {
                Task { await emailOwnerDetails() }
            }
            .buttonStyle(.bordered)
            .disabled(ownerEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Restart All AI Endpoints") {
                Task { _ = await adminManager.restartAllAIEndpoints() }
            }
            .buttonStyle(.bordered)

            if actionInFlight {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .disabled(actionInFlight)
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let message = adminManager.deploymentActionMessage, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.green)
            }

            if let message = adminManager.serviceActionMessage, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.green)
            }

            if let package = lastPackage {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last Package")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                    Text("Bundle: \(package.bundleName)")
                        .font(.caption)
                        .foregroundColor(.white)
                    Text("Stored on server: \(package.zipPath)")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                .padding()
                .background(Color.white.opacity(0.05))
                .cornerRadius(10)
            }

            if let deployment = lastDeployment {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last Deployment")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                    Text("Upload target: \(deployment.upload.remoteUrl)")
                        .font(.caption)
                        .foregroundColor(.white)
                    if let bootstrap = deployment.bootstrap {
                        Text("Bootstrap: \(bootstrap.success ? "Succeeded" : "Failed")")
                            .font(.caption2)
                            .foregroundColor(bootstrap.success ? .green : .orange)
                    }
                    if let restart = deployment.restart {
                        Text(restartStatusText(restart))
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }
                .padding()
                .background(Color.white.opacity(0.05))
                .cornerRadius(10)
            }
        }
    }

    private func generatePackage() async {
        actionInFlight = true
        defer { actionInFlight = false }
        lastPackage = await adminManager.buildDeploymentPackage(packageRequest)
    }

    private func deployToTarget() async {
        actionInFlight = true
        defer { actionInFlight = false }
        lastDeployment = await adminManager.runDeployment(
            DeploymentExecutionRequest(
                packageOptions: packageRequest,
                target: targetRequest,
                bootstrap: bootstrap
            )
        )
    }

    private func emailOwnerDetails() async {
        actionInFlight = true
        defer { actionInFlight = false }
        let bundleName = lastDeployment?.bundleName ?? lastPackage?.bundleName
        let remoteUrl = lastDeployment?.upload.remoteUrl
        _ = await adminManager.emailDeploymentOwner(
            DeploymentOwnerEmailRequest(
                recipient: ownerEmail,
                subject: "VoiceLink Deployment Details",
                bundleName: bundleName,
                remoteUrl: remoteUrl,
                apiBaseUrl: apiBaseUrl.isEmpty ? nil : apiBaseUrl
            )
        )
    }

    private var packageRequest: DeploymentPackageRequest {
        DeploymentPackageRequest(
            preset: packagePreset.isEmpty ? nil : packagePreset,
            sanitize: sanitize,
            ownerEmail: ownerEmail.isEmpty ? nil : ownerEmail,
            targetLabel: targetLabel.isEmpty ? nil : targetLabel,
            targetServerUrl: targetServerUrl.isEmpty ? nil : targetServerUrl,
            linkedToMain: linkedToMain,
            trustedServers: trustedServersList,
            extraConfig: DeploymentExtraConfig(
                server: [
                    "deploymentMode": deploymentMode,
                    "sourceInstallUrl": sourceInstallUrl,
                    "domain": effectiveTargetHost,
                    "basePath": detectedBasePath,
                    "targetUser": detectedUserName,
                    "siteType": effectiveSiteType,
                    "siteRoot": effectiveSiteRoot,
                    "remotePath": effectiveRemotePath,
                    "installRoot": effectiveRemotePath,
                    "masterApiUrl": masterApiUrl,
                    "secondaryApiUrl": secondaryApiUrl
                ],
                federation: [
                    "masterApiUrl": masterApiUrl,
                    "secondaryApiUrl": secondaryApiUrl,
                    "masterCommunityApiUrl": masterCommunityApiUrl,
                    "nearestApiStrategy": "local-first-health-latency",
                    "localAssetFallback": localAssetFallback ? "true" : "false"
                ],
                onboarding: [
                    "setupMode": setupMode,
                    "accountLinkMode": accountLinkMode,
                    "portalAccountAction": portalAccountAction,
                    "autoLinkAllProviders": linkAllProviders ? "true" : "false",
                    "reuseFirstGeneratedLicense": reuseFirstGeneratedLicense ? "true" : "false",
                    "firstLicensePreference": firstLicensePreference,
                    "defaultServerTier": defaultServerTier,
                    "allowPaidFeatureUnlocks": allowPaidFeatureUnlocks ? "true" : "false",
                    "mainApiRegistrationRequired": "true",
                    "firstAdminConfiguresServer": "true"
                ],
                owner: [
                    "owner": targetLabel,
                    "accountOwner": detectedUserName,
                    "linkedVoiceLinkAccount": "voicelink",
                    "linkedServerOwner": targetLabel
                ],
                policy: [
                    "listedInDirectory": "true",
                    "allowDirectReveal": "true",
                    "authRequired": "optional",
                    "allowGuests": "true",
                    "guestAccess": "allowed-limited",
                    "roomDirectory": "limited",
                    "roomAccess": "mixed",
                    "verificationStatus": "pending",
                    "verificationMethod": "master-api"
                ],
                moduleUpdates: [
                    "enabled": "true",
                    "localFirst": "true",
                    "notifyClients": notifyModuleUpdates ? "true" : "false",
                    "preserveConfig": "true",
                    "requireSignature": "true",
                    "requireChecksum": "true",
                    "installStrategy": "platform-native",
                    "localAssetFallback": localAssetFallback ? "true" : "false"
                ]
            )
        )
    }

    private var targetRequest: DeploymentTargetRequest {
        DeploymentTargetRequest(
            transport: effectiveTransport,
            host: effectiveTargetHost.isEmpty ? nil : effectiveTargetHost,
            port: Int(targetPort),
            remotePath: effectiveRemotePath.isEmpty ? nil : effectiveRemotePath,
            siteRoot: effectiveSiteRoot.isEmpty ? nil : effectiveSiteRoot,
            uploadUrl: effectiveUploadURL.isEmpty ? nil : effectiveUploadURL,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            method: (effectiveTransport == "http" || effectiveTransport == "https") ? httpMethod : nil,
            insecure: insecure,
            apiBaseUrl: apiBaseUrl.isEmpty ? nil : apiBaseUrl,
            apiToken: apiToken.isEmpty ? nil : apiToken,
            sharedSecret: sharedSecret.isEmpty ? nil : sharedSecret,
            trustedServers: trustedServersList.isEmpty ? nil : trustedServersList,
            restartAfterBootstrap: restartAfterBootstrap,
            restartUrl: restartUrl.isEmpty ? nil : restartUrl,
            restartMethod: restartAfterBootstrap ? restartMethod : nil
        )
    }

    private var effectiveTransport: String {
        autoDetectDeployment ? detectedTransport : selectedTransport
    }

    private var effectiveTransportLabel: String {
        autoDetectDeployment ? detectedTransportLabel : manualTransportLabel
    }

    private var effectiveSiteType: String {
        if autoDetectDeployment { return detectedSiteType }
        if selectedSiteType == "auto" { return detectedSiteType }
        return selectedSiteType
    }

    private var effectiveSiteTypeLabel: String {
        switch effectiveSiteType {
        case "wordpress": return "WordPress"
        case "whmcs": return "WHMCS"
        case "composr": return "Composr"
        case "cpanel": return "cPanel Account"
        case "installatron": return "Installatron"
        default: return "Plain App Install"
        }
    }

    private var effectiveRemotePath: String {
        if !remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return detectedRemotePath
    }

    private var effectiveSiteRoot: String {
        if !siteRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return siteRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return detectedSiteRoot
    }

    private var effectiveTargetHost: String {
        if !targetHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return targetHost.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let host = URL(string: targetServerUrl)?.host {
            return host
        }
        return targetServerUrl.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "").split(separator: "/").first.map(String.init) ?? ""
    }

    private var effectiveUploadURL: String {
        if !uploadUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return uploadUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if detectedTransport == "https" || detectedTransport == "http" {
            return targetServerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private var detectedBasePath: String {
        if let path = URL(string: targetServerUrl.trimmingCharacters(in: .whitespacesAndNewlines))?.path,
           path != "/" {
            return path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty ? "" : path
        }
        return ""
    }

    private var detectedTransport: String {
        let url = targetServerUrl.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if url.hasPrefix("https://") { return "https" }
        if url.hasPrefix("http://") { return "http" }
        return "sftp"
    }

    private var detectedTransportLabel: String {
        switch detectedTransport {
        case "https": return "HTTPS"
        case "http": return "HTTP"
        case "smb": return "SMB"
        default: return "SFTP"
        }
    }

    private var manualTransportLabel: String {
        switch selectedTransport {
        case "https": return "HTTPS"
        case "http": return "HTTP"
        case "smb": return "SMB"
        default: return "SFTP"
        }
    }

    private var detectedSiteType: String {
        let combined = [
            targetServerUrl.lowercased(),
            targetLabel.lowercased(),
            ownerEmail.lowercased(),
            effectiveTargetHost.lowercased(),
            remotePath.lowercased(),
            siteRoot.lowercased()
        ].joined(separator: " ")

        if combined.contains("wp") || combined.contains("wordpress") || combined.contains("tappedin.fm") || combined.contains("walterharper.com") {
            return "wordpress"
        }
        if combined.contains("whmcs") || combined.contains("devine-creations.com") || combined.contains("clientarea.php") {
            return "whmcs"
        }
        if combined.contains("installatron") || combined.contains(".well-known/voicelink.json") || combined.contains("install.xml") {
            return "installatron"
        }
        if combined.contains("composr") || combined.contains("devinecreations.net") || combined.contains("raywonderis.me") {
            return "composr"
        }
        if combined.contains("/home/") || combined.contains("cpanel") || combined.contains("public_html") {
            return "cpanel"
        }
        return "plain"
    }

    private var detectedSiteTypeLabel: String {
        switch detectedSiteType {
        case "wordpress": return "WordPress"
        case "whmcs": return "WHMCS"
        case "composr": return "Composr"
        case "cpanel": return "cPanel Account"
        case "installatron": return "Installatron"
        default: return "Plain App Install"
        }
    }

    private var detectedRemotePath: String {
        if detectedSiteType == "whmcs" {
            return "/home/devinecr/apps/voicelink"
        }
        if detectedSiteType == "wordpress" {
            return "/home/\(detectedUserName)/apps/voicelink"
        }
        if detectedSiteType == "composr" {
            return "/home/\(detectedUserName)/apps/voicelink"
        }
        if detectedSiteType == "cpanel" {
            return "/home/\(detectedUserName)/apps/voicelink"
        }
        if detectedSiteType == "installatron" {
            return "/home/\(detectedUserName)/apps/voicelink"
        }
        return remotePath.isEmpty ? "/home/\(detectedUserName.isEmpty ? "user" : detectedUserName)/apps/voicelink" : remotePath
    }

    private var detectedSiteRoot: String {
        switch detectedSiteType {
        case "whmcs":
            return "/home/devinecr/public_html"
        case "wordpress":
            return "/home/\(detectedUserName)/public_html"
        case "composr":
            return "/home/\(detectedUserName)/public_html"
        case "cpanel":
            return "/home/\(detectedUserName)"
        case "installatron":
            return "/home/\(detectedUserName)/public_html"
        default:
            return detectedRemotePath
        }
    }

    private var detectedRemotePathLabel: String {
        detectedRemotePath
    }

    private var effectiveRemotePathLabel: String {
        effectiveRemotePath
    }

    private var effectiveSiteRootLabel: String {
        effectiveSiteRoot
    }

    private var detectedUserName: String {
        let host = effectiveTargetHost.lowercased()
        if host.contains("tappedin.fm") { return "tappedin" }
        if host.contains("walterharper.com") { return "wharper" }
        if host.contains("devine-creations.com") || host.contains("devinecreations.net") { return "devinecr" }
        if host.contains("raywonderis.me") { return "dom" }
        if !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return username.trimmingCharacters(in: .whitespacesAndNewlines) }
        return "user"
    }

    private var detectedReason: String {
        switch detectedSiteType {
        case "whmcs":
            return "Detected WHMCS-style hosting and portal paths. VoiceLink will preserve the billing site and deploy side by side."
        case "wordpress":
            return "Detected WordPress-style hosting. VoiceLink will prefer the WordPress plugin path and a side-by-side app install."
        case "composr":
            return "Detected Composr-style hosting. VoiceLink will preserve the Composr site root and use the linked app path."
        case "cpanel":
            return "Detected a cPanel account-style host or path. VoiceLink will prefer cPanel-friendly app and shared file roots."
        case "installatron":
            return "Detected Installatron packaging or .well-known install metadata. VoiceLink will preserve the browser UI, sync Installatron app files, and keep WHMCS license state visible in web and desktop admin."
        default:
            return "No supported site type was strongly detected, so VoiceLink will use a plain side-by-side app install."
        }
    }

    private func saveCurrentDeploymentDefaults() {
        UserDefaults.standard.set(autoDetectDeployment, forKey: "voicelink.deployment.autoDetectDeployment")
        UserDefaults.standard.set(showAdvancedDeploymentOptions, forKey: "voicelink.deployment.showAdvancedOptions")
        UserDefaults.standard.set(selectedTransport, forKey: "voicelink.deployment.defaultTransport")
        UserDefaults.standard.set(selectedSiteType, forKey: "voicelink.deployment.defaultSiteType")
        adminManager.deploymentActionMessage = "Saved current deployment preferences as the default."
    }

    private var trustedServersList: [String] {
        trustedServers
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func restartStatusText(_ restart: DeploymentRestartResponse) -> String {
        if restart.success == true {
            return "Restart: triggered"
        }
        if restart.skipped == true {
            return "Restart: skipped (\(restart.reason ?? "not configured"))"
        }
        return "Restart: failed (\(restart.error ?? "unknown"))"
    }
}
