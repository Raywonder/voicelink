import Foundation
import SwiftUI
import AuthenticationServices
import Security
import UserNotifications

// MARK: - Authentication Manager
class AuthenticationManager: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AuthenticationManager()
    static let preferredMastodonInstance = "mastodon.devinecreations.net"
    static let mastodonFallbacks: [String: String] = [
        "md.tappedin.fm": "mastodon.devinecreations.net",
        "layer8": "layer8.space",
        "layer8.space": "layer8.space",
        "layor8": "layer8.space"
    ]
    private let authDefaultsKey = "voicelink.authUser"

    @Published var currentUser: AuthenticatedUser?
    @Published var authState: AuthState = .unauthenticated
    @Published var authError: String?
    @Published var passkeyRecommendationPending = false
    @Published var availableTwoFactorMethods: [TwoFactorMethod] = []
    @Published var selectedTwoFactorMethod: String?
    @Published var twoFactorDeliveryHint: String?
    @Published var twoFactorDeliveryStatus: String?

    // Mastodon OAuth state
    @Published var mastodonInstance: String = ""
    private var mastodonClientId: String?
    private var mastodonClientSecret: String?
    private var authSession: ASWebAuthenticationSession?
    private var passkeyRecommendationWorkItem: DispatchWorkItem?

    // Email verification state
    @Published var pendingEmailVerification: String?
    @Published var emailVerificationExpiry: Date?
    @Published var pendingAdminInviteToken: String?
    @Published var pendingAdminInviteServerURL: String?
    @Published var pendingAdminInviteEmail: String?
    @Published var pendingAdminInviteRole: String?
    @Published var lastCreatedInviteURL: String?
    @Published var lastCreatedInviteEmail: String?
    @Published var lastCreatedInviteRole: String?
    @Published var lastCreatedInviteExpiry: Date?

    enum AuthState {
        case unauthenticated
        case authenticating
        case authenticated
        case error
    }

    override init() {
        super.init()
        loadStoredAuth()
        setupOAuthCallbackListener()
    }

    private func isLegacyEmailSession(_ user: AuthenticatedUser) -> Bool {
        user.authMethod == .email && user.accessToken.hasPrefix("vlemail_")
    }

    private func applyAuthenticatedUser(_ user: AuthenticatedUser, notifyMastodon: Bool = false) {
        currentUser = user
        authState = .authenticated
        saveAuth(user: user)
        schedulePasskeyRecommendationIfNeeded(for: user)

        Task { @MainActor in
            await LicensingManager.shared.syncEntitlementsFromCurrentUser()
            await LicensingManager.shared.refreshForCurrentUser()
        }

        if notifyMastodon {
            NotificationCenter.default.post(name: .mastodonAccountLoaded, object: user)
        }
    }

    func updateCurrentUserContactCard(_ contactCard: AuthenticatedUser.ContactCard) {
        guard var user = currentUser else { return }
        user.contactCard = contactCard
        applyAuthenticatedUser(user)
    }

    func updateCurrentUserRole(_ role: String) {
        guard var user = currentUser else { return }
        let normalized = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, user.role?.lowercased() != normalized else { return }
        user.role = normalized
        applyAuthenticatedUser(user)
    }

    func updateCurrentUserAccessToken(_ accessToken: String) {
        let normalized = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, var user = currentUser, user.accessToken != normalized else { return }
        user.accessToken = normalized
        applyAuthenticatedUser(user)
    }

    private func setupOAuthCallbackListener() {
        // Listen for OAuth callbacks from URL handler (fallback for external browser auth)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOAuthCallbackNotification(_:)),
            name: .oauthCallback,
            object: nil
        )
    }

    @objc private func handleOAuthCallbackNotification(_ notification: Notification) {
        guard let userInfo = notification.object as? [String: Any],
              let code = userInfo["code"] as? String else {
            return
        }
        handleMastodonCallback(code: code)
    }

    // ASWebAuthenticationPresentationContextProviding
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return NSApp.windows.first ?? ASPresentationAnchor()
    }

    // MARK: - Mastodon OAuth

    func authenticateWithMastodon(instance: String, completion: @escaping (Bool, String?) -> Void) {
        authState = .authenticating
        mastodonInstance = Self.normalizedMastodonInstance(instance)

        // Step 1: Register OAuth app with the instance
        registerMastodonApp { [weak self] success, error in
            guard success else {
                self?.authState = .error
                self?.authError = error
                completion(false, error)
                return
            }

            // Step 2: Open OAuth authorization URL
            self?.openMastodonAuth(completion: completion)
        }
    }

    static func normalizedMastodonInstance(_ instance: String) -> String {
        var normalized = instance
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        normalized = normalized.replacingOccurrences(of: "https://", with: "")
        normalized = normalized.replacingOccurrences(of: "http://", with: "")
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        normalized = mastodonFallbacks[normalized] ?? normalized
        return normalized.isEmpty ? preferredMastodonInstance : normalized
    }

    private func registerMastodonApp(completion: @escaping (Bool, String?) -> Void) {
        guard let url = URL(string: "https://\(mastodonInstance)/api/v1/apps") else {
            completion(false, "Invalid Mastodon instance URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "client_name": "VoiceLink",
            "redirect_uris": "voicelink://oauth/callback",
            "scopes": "read write",
            "website": "https://voicelinkapp.app"
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(false, "Failed to contact Mastodon instance: \(error.localizedDescription)")
                    return
                }

                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    if http.statusCode == 502,
                       let current = self?.mastodonInstance,
                       let fallback = Self.mastodonFallbacks[current],
                       fallback != current {
                        self?.mastodonInstance = fallback
                        self?.registerMastodonApp(completion: completion)
                        return
                    }

                    let bodyText = data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let message: String
                    if http.statusCode == 502 {
                        message = "The selected Mastodon instance is unavailable right now (502 Bad Gateway). Try \(Self.preferredMastodonInstance)."
                    } else {
                        message = (bodyText?.isEmpty == false ? bodyText! : "HTTP \(http.statusCode)")
                    }
                    completion(false, "Failed to register with Mastodon instance: \(message)")
                    return
                }

                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let clientId = json["client_id"] as? String,
                      let clientSecret = json["client_secret"] as? String else {
                    completion(false, "Failed to register with Mastodon instance")
                    return
                }

                self?.mastodonClientId = clientId
                self?.mastodonClientSecret = clientSecret
                completion(true, nil)
            }
        }.resume()
    }

    private func openMastodonAuth(completion: @escaping (Bool, String?) -> Void) {
        guard let clientId = mastodonClientId else {
            completion(false, "Missing client ID")
            return
        }

        let authURL = "https://\(mastodonInstance)/oauth/authorize?" +
            "client_id=\(clientId)&" +
            "redirect_uri=voicelink://oauth/callback&" +
            "response_type=code&" +
            "scope=read%20write"

        guard let url = URL(string: authURL) else {
            completion(false, "Invalid auth URL")
            return
        }

        // Store completion for callback handling
        pendingMastodonCompletion = completion

        // Use ASWebAuthenticationSession for in-app authentication
        // This shows the auth page in a secure sheet within the app
        authSession = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: "voicelink"
        ) { [weak self] callbackURL, error in
            DispatchQueue.main.async {
                if let error = error {
                    // Check if user cancelled
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        self?.authState = self?.currentUser == nil ? .unauthenticated : .authenticated
                        self?.pendingMastodonCompletion?(false, "Authentication cancelled")
                        self?.pendingMastodonCompletion = nil
                    } else {
                        self?.authState = .error
                        self?.authError = error.localizedDescription
                        self?.pendingMastodonCompletion?(false, error.localizedDescription)
                        self?.pendingMastodonCompletion = nil
                    }
                    return
                }

                guard let callbackURL = callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                    self?.authState = .error
                    self?.authError = "No authorization code received"
                    self?.pendingMastodonCompletion?(false, "No authorization code received")
                    self?.pendingMastodonCompletion = nil
                    return
                }

                // Handle the OAuth callback with the code
                self?.handleMastodonCallback(code: code)
            }
        }

        // Set the presentation context and start the session
        authSession?.presentationContextProvider = self
        authSession?.prefersEphemeralWebBrowserSession = false // Allow persisting cookies for "remember me"
        authSession?.start()
    }

    private var pendingMastodonCompletion: ((Bool, String?) -> Void)?

    func handleMastodonCallback(code: String) {
        guard let clientId = mastodonClientId,
              let clientSecret = mastodonClientSecret else {
            pendingMastodonCompletion?(false, "Missing OAuth credentials")
            return
        }

        // Exchange code for token
        guard let url = URL(string: "https://\(mastodonInstance)/oauth/token") else {
            pendingMastodonCompletion?(false, "Invalid token URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "client_id": clientId,
            "client_secret": clientSecret,
            "redirect_uri": "voicelink://oauth/callback",
            "grant_type": "authorization_code",
            "code": code,
            "scope": "read write"
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.authState = .error
                    self?.pendingMastodonCompletion?(false, error.localizedDescription)
                    return
                }

                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let accessToken = json["access_token"] as? String else {
                    self?.authState = .error
                    self?.pendingMastodonCompletion?(false, "Failed to get access token")
                    return
                }

                // Get user info
                self?.fetchMastodonUser(accessToken: accessToken)
            }
        }.resume()
    }

    private func fetchMastodonUser(accessToken: String) {
        guard let url = URL(string: "https://\(mastodonInstance)/api/v1/accounts/verify_credentials") else {
            authState = .error
            pendingMastodonCompletion?(false, "Invalid API URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let username = json["username"] as? String,
                      let id = json["id"] as? String else {
                    self?.authState = .error
                    self?.pendingMastodonCompletion?(false, "Failed to get user info")
                    return
                }

                // Parse account creation date
                var accountCreatedAt: Date?
                if let createdString = json["created_at"] as? String {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    accountCreatedAt = formatter.date(from: createdString)
                    if accountCreatedAt == nil {
                        // Try without fractional seconds
                        formatter.formatOptions = [.withInternetDateTime]
                        accountCreatedAt = formatter.date(from: createdString)
                    }
                }

                var user = AuthenticatedUser(
                    id: id,
                    username: username,
                    displayName: json["display_name"] as? String ?? username,
                    email: nil,
                    authMethod: .mastodon,
                    mastodonInstance: self?.mastodonInstance,
                    accessToken: accessToken,
                    avatarURL: json["avatar"] as? String
                )

                // Set Mastodon account factors
                user.followersCount = json["followers_count"] as? Int ?? 0
                user.followingCount = json["following_count"] as? Int ?? 0
                user.statusesCount = json["statuses_count"] as? Int ?? 0
                user.accountCreatedAt = accountCreatedAt

                self?.applyAuthenticatedUser(user, notifyMastodon: true)
                self?.pendingMastodonCompletion?(true, nil)
                self?.pendingMastodonCompletion = nil
            }
        }.resume()
    }

    // MARK: - Email Verification

    func requestEmailVerification(email: String, serverURL: String, completion: @escaping (Bool, String?) -> Void) {
        authState = .authenticating

        guard let url = URL(string: "\(serverURL)/api/auth/email/request") else {
            completion(false, "Invalid server URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "email": email,
            "clientId": getClientId(),
            "clientName": Host.current().localizedName ?? "Unknown Device"
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.authState = .error
                    completion(false, error.localizedDescription)
                    return
                }

                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = json["success"] as? Bool, success else {
                    let errorMsg = (try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any])?["error"] as? String
                    self?.authState = .error
                    completion(false, errorMsg ?? "Failed to send verification email")
                    return
                }

                self?.pendingEmailVerification = email
                self?.emailVerificationExpiry = Date().addingTimeInterval(15 * 60) // 15 minutes
                completion(true, nil)
            }
        }.resume()
    }

    func verifyEmailCode(code: String, serverURL: String, completion: @escaping (Bool, String?) -> Void) {
        guard let email = pendingEmailVerification else {
            completion(false, "No pending email verification")
            return
        }

        guard let url = URL(string: "\(serverURL)/api/auth/email/verify") else {
            completion(false, "Invalid server URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "email": email,
            "code": code.uppercased(),
            "clientId": getClientId()
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.authState = .error
                    completion(false, error.localizedDescription)
                    return
                }

                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = json["success"] as? Bool, success,
                      let accessToken = json["accessToken"] as? String else {
                    let errorMsg = (try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any])?["error"] as? String
                    self?.authState = .error
                    completion(false, errorMsg ?? "Verification failed")
                    return
                }

                if let parsedUser = self?.parseAuthenticatedUser(
                    from: json["user"] as? [String: Any],
                    accessTokenFallback: accessToken,
                    authMethod: .email
                ) {
                    self?.applyAuthenticatedUser(parsedUser)
                } else {
                    let user = AuthenticatedUser(
                        id: json["userId"] as? String ?? UUID().uuidString,
                        username: email,
                        displayName: email.components(separatedBy: "@").first ?? email,
                        email: email,
                        authMethod: .email,
                        mastodonInstance: nil,
                        accessToken: accessToken,
                        avatarURL: nil
                    )
                    self?.applyAuthenticatedUser(user)
                }
                self?.pendingEmailVerification = nil
                self?.emailVerificationExpiry = nil
                completion(true, nil)
            }
        }.resume()
    }

    // MARK: - Admin Invite (Magic Link)

    func stageAdminInvite(token: String, serverURL: String?) {
        pendingAdminInviteToken = token
        pendingAdminInviteServerURL = serverURL
    }

    func fetchAdminInvite(token: String, serverURL: String, completion: @escaping (Bool, String?) -> Void) {
        guard let url = URL(string: "\(serverURL)/api/auth/local/admin-invite/\(token)") else {
            completion(false, "Invalid server URL")
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(false, error.localizedDescription)
                    return
                }
                guard let data = data,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (json["success"] as? Bool) == true else {
                    let errorMsg = (try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any])?["error"] as? String
                    completion(false, errorMsg ?? "Invite is invalid or expired")
                    return
                }
                self?.pendingAdminInviteEmail = json["email"] as? String
                self?.pendingAdminInviteRole = json["role"] as? String
                completion(true, nil)
            }
        }.resume()
    }

    func acceptAdminInvite(
        token: String,
        email: String,
        username: String,
        displayName: String,
        password: String,
        serverURL: String,
        completion: @escaping (Bool, String?) -> Void
    ) {
        guard let url = URL(string: "\(serverURL)/api/auth/local/admin-invite/accept") else {
            completion(false, "Invalid server URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "token": token,
            "email": email,
            "username": username,
            "displayName": displayName,
            "password": password
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(false, error.localizedDescription)
                    return
                }
                guard let data = data,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = json["success"] as? Bool, success,
                      let accessToken = json["accessToken"] as? String,
                      let userJson = json["user"] as? [String: Any] else {
                    let errorMsg = (try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any])?["error"] as? String
                    completion(false, errorMsg ?? "Failed to activate invite")
                    return
                }

                let emailValue = (userJson["email"] as? String) ?? email
                let usernameValue = (userJson["username"] as? String) ?? username
                let displayNameValue = (userJson["displayName"] as? String) ?? displayName
                let userId = (userJson["id"] as? String) ?? UUID().uuidString
                let user = AuthenticatedUser(
                    id: userId,
                    username: usernameValue,
                    displayName: displayNameValue,
                    email: emailValue,
                    authMethod: .email,
                    mastodonInstance: nil,
                    accessToken: accessToken,
                    avatarURL: nil
                )
                self?.applyAuthenticatedUser(user)
                self?.pendingAdminInviteToken = nil
                self?.pendingAdminInviteServerURL = nil
                completion(true, nil)
            }
        }.resume()
    }

    func createAdminInvite(
        email: String,
        role: String = "admin",
        expiresMinutes: Int = 60,
        serverURL: String,
        completion: @escaping (Bool, String?, String?) -> Void
    ) {
        guard let currentUser else {
            completion(false, "You must be signed in to create an invite.", nil)
            return
        }
        guard let url = URL(string: "\(serverURL)/api/admin/invites") else {
            completion(false, "Invalid server URL", nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(currentUser.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(getClientId(), forHTTPHeaderField: "X-Client-ID")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "role": role,
            "expiresMinutes": expiresMinutes
        ])

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error {
                    completion(false, error.localizedDescription, nil)
                    return
                }

                guard let data,
                      let http = response as? HTTPURLResponse,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(false, "Invalid response from server", nil)
                    return
                }

                guard (200..<300).contains(http.statusCode),
                      (json["success"] as? Bool) == true else {
                    completion(false, json["error"] as? String ?? "Failed to create invite", nil)
                    return
                }

                let inviteURL = json["inviteUrl"] as? String
                self?.lastCreatedInviteURL = inviteURL
                self?.lastCreatedInviteEmail = json["email"] as? String ?? email
                self?.lastCreatedInviteRole = json["role"] as? String ?? role
                if let expiresAt = json["expiresAt"] as? String {
                    self?.lastCreatedInviteExpiry = ISO8601DateFormatter().date(from: expiresAt)
                } else {
                    self?.lastCreatedInviteExpiry = nil
                }
                completion(true, nil, inviteURL)
            }
        }.resume()
    }

    func signInWithAccount(
        identity: String,
        password: String,
        serverURL: String,
        provider: AccountAuthProvider,
        twoFactorCode: String = "",
        completion: @escaping (Bool, String?, Bool) -> Void
    ) {
        authState = .authenticating
        authError = nil
        availableTwoFactorMethods = []
        selectedTwoFactorMethod = nil
        twoFactorDeliveryHint = nil
        twoFactorDeliveryStatus = nil
        let providersToTry: [AccountAuthProvider]
        switch provider {
        case .local:
            providersToTry = [.local, .whmcs]
        case .whmcs:
            providersToTry = [.whmcs, .local]
        }
        let isSmartAccountSignIn = provider == .local

        func isRetryablePortalFallbackMessage(_ message: String) -> Bool {
            let lowered = message.lowercased()
            return lowered.contains("invalid credentials")
                || lowered.contains("invalid email or password")
                || lowered.contains("invalid email or username or password")
                || lowered.contains("account not found")
                || lowered.contains("user not found")
                || lowered.contains("unknown user")
                || lowered.contains("identity and password")
                || lowered.contains("email and password")
                || lowered.contains("email or username and password")
        }

        func normalizeAccountSignInError(_ message: String, provider: AccountAuthProvider) -> String {
            let lowered = message.lowercased()
            if provider == .whmcs {
                if lowered.contains("api credentials not configured")
                    || lowered.contains("license")
                    || lowered.contains("temporarily unavailable")
                    || lowered.contains("bad gateway")
                    || lowered.contains("internal server error")
                    || lowered.contains("service unavailable") {
                    return "Client Account sign-in is temporarily unavailable. Use Email Code or Mastodon for now."
                }
            }
            if provider == .local && isSmartAccountSignIn {
                if lowered.contains("whmcs")
                    || lowered.contains("cpanel")
                    || lowered.contains("client portal")
                    || lowered.contains("api credentials not configured") {
                    return "Sign In is temporarily unavailable for that Client Account right now. Use Email Code or Mastodon for now."
                }
            }
            return message
        }

        func attempt(_ remainingProviders: ArraySlice<AccountAuthProvider>) {
            guard let activeProvider = remainingProviders.first else {
                self.authState = .error
                completion(false, self.authError ?? "Authentication failed", false)
                return
            }

            guard let url = URL(string: "\(serverURL)/api/auth/\(activeProvider.rawValue)/login") else {
                completion(false, "Invalid server URL", false)
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            var body: [String: Any] = [
                "identity": identity,
                "password": password
            ]
            if !twoFactorCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                body["twoFactorCode"] = twoFactorCode.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if activeProvider == .whmcs {
                body["portalSite"] = "devine-creations.com"
            }
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                DispatchQueue.main.async {
                    guard let self else {
                        completion(false, "Authentication unavailable", false)
                        return
                    }

                    if let error = error {
                        self.authState = .error
                        self.authError = error.localizedDescription
                        completion(false, error.localizedDescription, false)
                        return
                    }

                    guard let data = data,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        self.authState = .error
                        self.authError = "Authentication failed"
                        completion(false, "Authentication failed", false)
                        return
                    }

                    if let requires2FA = json["requires2FA"] as? Bool, requires2FA {
                        self.authState = .unauthenticated
                        self.availableTwoFactorMethods = Self.parseTwoFactorMethods(json["availableMethods"])
                        self.selectedTwoFactorMethod = self.availableTwoFactorMethods.first(where: \.supportsDelivery)?.type ?? self.availableTwoFactorMethods.first?.type
                        self.twoFactorDeliveryHint = json["hint"] as? String
                        let message = json["error"] as? String ?? json["message"] as? String ?? "Two-factor authentication code required"
                        completion(false, message, true)
                        return
                    }

                    guard let success = json["success"] as? Bool, success else {
                        let message = json["error"] as? String ?? json["message"] as? String ?? "Authentication failed"
                        let shouldTryNext = activeProvider == .local
                            && !remainingProviders.dropFirst().isEmpty
                            && isRetryablePortalFallbackMessage(message)
                        if shouldTryNext {
                            attempt(remainingProviders.dropFirst())
                            return
                        }
                        self.authState = .error
                        let visibleMessage = isSmartAccountSignIn
                            ? normalizeAccountSignInError(message, provider: activeProvider)
                            : message
                        self.authError = visibleMessage
                        completion(false, visibleMessage, false)
                        return
                    }

                    guard let user = self.parseAuthenticatedUser(
                        from: json["user"] as? [String: Any],
                        accessTokenFallback: (json["token"] as? String) ?? (json["accessToken"] as? String),
                        authMethod: activeProvider == .local ? .email : .whmcs
                    ) else {
                        self.authState = .error
                        self.authError = "Invalid user payload"
                        completion(false, "Invalid user payload", false)
                        return
                    }

                    self.applyAuthenticatedUser(user)
                    self.availableTwoFactorMethods = []
                    self.selectedTwoFactorMethod = nil
                    self.twoFactorDeliveryHint = nil
                    self.twoFactorDeliveryStatus = nil
                    completion(true, nil, false)
                }
            }.resume()
        }

        attempt(ArraySlice(providersToTry))
    }

    func requestTwoFactorChallenge(
        identity: String,
        password: String,
        serverURL: String,
        method: String,
        completion: @escaping (Bool, String?) -> Void
    ) {
        guard let url = URL(string: "\(serverURL)/api/auth/local/2fa/challenge") else {
            completion(false, "Invalid server URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "identity": identity,
            "password": password,
            "method": method
        ])

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else {
                    completion(false, "Authentication unavailable")
                    return
                }
                if let error {
                    completion(false, error.localizedDescription)
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(false, "Unable to send verification code")
                    return
                }

                self.availableTwoFactorMethods = Self.parseTwoFactorMethods(json["availableMethods"])
                self.twoFactorDeliveryHint = json["hint"] as? String

                if let success = json["success"] as? Bool, success {
                    let methodName = self.availableTwoFactorMethods.first(where: { $0.type == method })?.name ?? method.capitalized
                    let hint = (json["hint"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let hint, !hint.isEmpty {
                        self.twoFactorDeliveryStatus = "\(methodName) code sent to \(hint)."
                    } else {
                        self.twoFactorDeliveryStatus = "\(methodName) challenge sent."
                    }
                    completion(true, nil)
                    return
                }

                let message = json["error"] as? String ?? json["message"] as? String ?? "Unable to send verification code"
                self.twoFactorDeliveryStatus = message
                completion(false, message)
            }
        }.resume()
    }

    // MARK: - Session Management

    func logout() {
        passkeyRecommendationWorkItem?.cancel()
        passkeyRecommendationWorkItem = nil
        passkeyRecommendationPending = false
        availableTwoFactorMethods = []
        selectedTwoFactorMethod = nil
        twoFactorDeliveryHint = nil
        twoFactorDeliveryStatus = nil
        currentUser = nil
        authState = .unauthenticated
        clearStoredAuth()
    }

    private func passkeyRecommendationSuppressed(for user: AuthenticatedUser) -> Bool {
        let defaults = UserDefaults()
        return defaults.bool(forKey: "voicelink.passkey.suppressed.user.\(user.id)")
            || defaults.bool(forKey: "voicelink.passkey.suppressed.identity.\(user.email ?? user.username)")
    }

    func suppressPasskeyRecommendation(for user: AuthenticatedUser) {
        let defaults = UserDefaults()
        defaults.set(true, forKey: "voicelink.passkey.suppressed.user.\(user.id)")
        defaults.set(true, forKey: "voicelink.passkey.suppressed.identity.\(user.email ?? user.username)")
        passkeyRecommendationPending = false
    }

    func clearPasskeyRecommendation() {
        passkeyRecommendationPending = false
    }

    private func schedulePasskeyRecommendationIfNeeded(for user: AuthenticatedUser) {
        passkeyRecommendationWorkItem?.cancel()
        passkeyRecommendationPending = false
        guard user.passkey.supported,
              user.passkey.eligible,
              !user.passkey.registered,
              !passkeyRecommendationSuppressed(for: user) else {
            return
        }

        let delaySeconds = max(60, user.passkey.recommendedAfterMinutes * 60)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.currentUser?.id == user.id else { return }
            self.passkeyRecommendationPending = true
            AccessibilityManager.shared.announceStatus("VoiceLink recommends adding a passkey for faster secure sign-in.")
            let center = UNUserNotificationCenter.current()
            center.getNotificationSettings { settings in
                guard settings.authorizationStatus == .authorized else { return }
                let content = UNMutableNotificationContent()
                content.title = "Set up a passkey"
                content.body = "Add a passkey to your VoiceLink account for faster secure sign-in."
                content.sound = .default
                let request = UNNotificationRequest(
                    identifier: "voicelink.passkey.recommendation.\(user.id)",
                    content: content,
                    trigger: nil
                )
                center.add(request)
            }
        }
        passkeyRecommendationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delaySeconds), execute: workItem)
    }

    static func parseTwoFactorMethods(_ raw: Any?) -> [TwoFactorMethod] {
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap { json in
            guard let type = json["type"] as? String,
                  let name = json["name"] as? String else {
                return nil
            }
            return TwoFactorMethod(
                type: type,
                name: name,
                hint: json["hint"] as? String,
                count: json["count"] as? Int,
                remaining: json["remaining"] as? Int
            )
        }
    }

    // MARK: - Persistence (UserDefaults first, Keychain best-effort/no-UI)

    private func logKeychainFailure(_ action: String, status: OSStatus) {
        guard status != errSecSuccess && status != errSecItemNotFound else { return }
        print("[Auth] Keychain \(action) skipped with status \(status). Continuing with UserDefaults session fallback.")
    }

    private func saveAuth(user: AuthenticatedUser) {
        guard let data = try? JSONEncoder().encode(user) else { return }

        // Always keep a local fallback to avoid SecurityAgent prompt loops.
        UserDefaults().set(data, forKey: authDefaultsKey)

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VoiceLink",
            kSecAttrAccount as String: "authUser"
        ]
        let addQuery: [String: Any] = baseQuery.merging([
            kSecValueData as String: data,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]) { _, new in new }

        let deleteStatus = SecItemDelete(baseQuery as CFDictionary)
        logKeychainFailure("delete", status: deleteStatus)
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        logKeychainFailure("add", status: addStatus)
    }

    private func decodeStoredUser(_ data: Data) -> AuthenticatedUser? {
        try? JSONDecoder().decode(AuthenticatedUser.self, from: data)
    }

    private func loadFromUserDefaults() -> Bool {
        guard let data = UserDefaults().data(forKey: authDefaultsKey),
              let user = decodeStoredUser(data) else {
            return false
        }
        if isLegacyEmailSession(user) {
            clearStoredAuth()
            authState = .unauthenticated
            currentUser = nil
            return false
        }
        applyAuthenticatedUser(user)
        validateStoredSessionIfNeeded(for: user)
        return true
    }

    private func loadStoredAuth() {
        // Prefer local fallback first to avoid password/security agent loops.
        if loadFromUserDefaults() {
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VoiceLink",
            kSecAttrAccount as String: "authUser",
            kSecReturnData as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]

        var result: AnyObject?
        let copyStatus = SecItemCopyMatching(query as CFDictionary, &result)
        logKeychainFailure("read", status: copyStatus)
        if copyStatus == errSecSuccess,
           let data = result as? Data,
           let user = decodeStoredUser(data) {
            if isLegacyEmailSession(user) {
                clearStoredAuth()
                authState = .unauthenticated
                currentUser = nil
                return
            }
            applyAuthenticatedUser(user)
            UserDefaults().set(data, forKey: authDefaultsKey)
            validateStoredSessionIfNeeded(for: user)
        }
    }

    private func validateStoredSessionIfNeeded(for user: AuthenticatedUser) {
        guard user.authMethod == .whmcs || (user.authProvider ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains("whmcs") else {
            return
        }

        let token = user.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            logout()
            return
        }

        let candidates = APIEndpointResolver.apiBaseCandidates(preferred: ServerManager.shared.baseURL)
        validateWhmcsSession(token: token, candidates: candidates) { [weak self] isValid, reachedAuthority in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let current = self.currentUser, current.id == user.id else { return }
                guard current.accessToken == token else { return }

                if isValid {
                    return
                }

                // Keep the cached session across relaunches unless the user explicitly signs out.
                // Background validation is advisory because linked clusters and fallback endpoints
                // can return a transient 401 for a valid user on a different authority.
                if reachedAuthority {
                    self.authError = "Your client portal session may need to be refreshed. If account actions fail, sign in again."
                }
            }
        }
    }

    private func validateWhmcsSession(
        token: String,
        candidates: [String],
        completion: @escaping (_ isValid: Bool, _ reachedAuthority: Bool) -> Void
    ) {
        let queue = candidates
        guard !queue.isEmpty else {
            completion(false, false)
            return
        }

        func attempt(_ remaining: ArraySlice<String>, reachedAuthority: Bool) {
            guard let base = remaining.first,
                  let url = APIEndpointResolver.url(base: base, path: "/api/auth/whmcs/session/\(token)") else {
                completion(false, reachedAuthority)
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 8

            URLSession.shared.dataTask(with: request) { data, response, error in
                if error != nil {
                    attempt(remaining.dropFirst(), reachedAuthority: reachedAuthority)
                    return
                }

                guard let http = response as? HTTPURLResponse else {
                    attempt(remaining.dropFirst(), reachedAuthority: reachedAuthority)
                    return
                }

                if http.statusCode == 200,
                   let data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   (json["valid"] as? Bool) == true {
                    completion(true, true)
                    return
                }

                if http.statusCode == 401 {
                    completion(false, true)
                    return
                }

                attempt(remaining.dropFirst(), reachedAuthority: true)
            }.resume()
        }

        attempt(ArraySlice(queue), reachedAuthority: false)
    }

    private func clearStoredAuth() {
        UserDefaults().removeObject(forKey: authDefaultsKey)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VoiceLink",
            kSecAttrAccount as String: "authUser",
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        let deleteStatus = SecItemDelete(query as CFDictionary)
        logKeychainFailure("clear", status: deleteStatus)
    }

    func getClientId() -> String {
        if let clientId = UserDefaults().string(forKey: "clientId") {
            return clientId
        }
        let newId = UUID().uuidString
        UserDefaults().set(newId, forKey: "clientId")
        return newId
    }

    private func parseAuthenticatedUser(
        from json: [String: Any]?,
        accessTokenFallback: String?,
        authMethod: AuthMethod
    ) -> AuthenticatedUser? {
        guard let json = json else { return nil }
        let id = json["id"] as? String ?? UUID().uuidString
        let username = json["username"] as? String
            ?? json["email"] as? String
            ?? "user"
        let displayName = json["displayName"] as? String
            ?? json["display_name"] as? String
            ?? username
        let accessToken = json["accessToken"] as? String
            ?? json["token"] as? String
            ?? accessTokenFallback
            ?? ""
        guard !accessToken.isEmpty else { return nil }

        var user = AuthenticatedUser(
            id: id,
            username: username,
            displayName: displayName,
            email: json["email"] as? String,
            canonicalEmail: json["canonicalEmail"] as? String,
            authMethod: authMethod,
            mastodonInstance: json["mastodonInstance"] as? String,
            accessToken: accessToken,
            avatarURL: json["avatarURL"] as? String ?? json["avatar"] as? String,
            accountId: json["accountId"] as? String,
            canonicalAccountId: json["canonicalAccountId"] as? String,
            linkedLocalUserId: json["linkedLocalUserId"] as? String
        )
        if let directGender = json["gender"] as? String, !directGender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            user.gender = directGender
        } else if let directGender = json["sex"] as? String, !directGender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            user.gender = directGender
        } else if let profile = json["profile"] as? [String: Any] {
            if let profileGender = profile["gender"] as? String, !profileGender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                user.gender = profileGender
            } else if let profileGender = profile["sex"] as? String, !profileGender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                user.gender = profileGender
            }
        }
        user.role = json["role"] as? String
        user.authProvider = json["authProvider"] as? String
        user.permissions = json["permissions"] as? [String] ?? []
        if let entitlements = json["entitlements"] as? [String: Any] {
            user.entitlements = entitlements.mapValues(AnyCodable.init)
        }
        if let passkey = json["passkey"] as? [String: Any] {
            user.passkey = AuthenticatedUser.PasskeyState(
                supported: passkey["supported"] as? Bool ?? false,
                eligible: passkey["eligible"] as? Bool ?? false,
                registered: passkey["registered"] as? Bool ?? false,
                count: passkey["count"] as? Int ?? 0,
                recommendedAfterMinutes: passkey["recommendedAfterMinutes"] as? Int ?? 10
            )
        }
        user.presence = (json["presence"] as? String ?? json["status"] as? String ?? "online")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        user.lastLoginAt = Self.parseDateField(json["lastLoginAt"])
        user.lastSeenAt = Self.parseDateField(json["lastSeenAt"] ?? json["lastSeen"])
        user.lastActiveAt = Self.parseDateField(json["lastActiveAt"])
        if let contactCard = json["contactCard"] as? [String: Any] {
            user.contactCard = AuthenticatedUser.ContactCard.from(json: contactCard)
        }
        return user
    }

    static func parseDateField(_ rawValue: Any?) -> Date? {
        guard let string = rawValue as? String else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }

    func syncCurrentUserContactCard(
        _ contactCard: AuthenticatedUser.ContactCard,
        completion: @escaping (Bool, String?) -> Void
    ) {
        guard let currentUser = currentUser else {
            completion(false, "You must be signed in to sync your contact card.")
            return
        }

        let syncBase = APIEndpointResolver.remoteMainBaseCandidates(preferred: ServerManager.shared.baseURL).first
            ?? APIEndpointResolver.canonicalMainBase
        guard let url = URL(string: "\(syncBase)/api/auth/local/contact-card") else {
            completion(false, "Unable to resolve the contact sync server.")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(currentUser.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(currentUser.id, forHTTPHeaderField: "X-User-Id")
        request.setValue(currentUser.username, forHTTPHeaderField: "X-User-Name")
        request.setValue(currentUser.role, forHTTPHeaderField: "X-User-Role")
        request.setValue(currentUser.authProvider ?? currentUser.authMethod.rawValue, forHTTPHeaderField: "X-Auth-Provider")
        request.setValue(currentUser.authMethod.rawValue, forHTTPHeaderField: "X-Auth-Method")

        func jsonString(_ value: String?) -> Any {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? NSNull() : trimmed
        }

        let body: [String: Any] = [
            "contactCard": [
                "fullName": jsonString(contactCard.fullName),
                "firstName": jsonString(contactCard.firstName),
                "lastName": jsonString(contactCard.lastName),
                "nickname": jsonString(contactCard.nickname),
                "company": jsonString(contactCard.company),
                "email": jsonString(contactCard.email),
                "phone": jsonString(contactCard.phone),
                "address": jsonString(contactCard.address),
                "city": jsonString(contactCard.city),
                "state": jsonString(contactCard.state),
                "postalCode": jsonString(contactCard.postalCode),
                "country": jsonString(contactCard.country),
                "website": jsonString(contactCard.website),
                "notes": jsonString(contactCard.notes),
                "organisationRole": jsonString(contactCard.organisationRole),
                "source": jsonString(contactCard.source),
                "importFormats": contactCard.importFormats,
                "autoSyncedAt": ISO8601DateFormatter().string(from: contactCard.autoSyncedAt ?? Date())
            ],
            "contactImportFormats": contactCard.importFormats
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(false, "Unable to prepare contact card sync data.")
            return
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                if let error {
                    completion(false, error.localizedDescription)
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = json["success"] as? Bool, success else {
                    let response = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    completion(false, response?["error"] as? String ?? "Failed to sync contact card")
                    return
                }

                if let userJson = json["user"] as? [String: Any],
                   let parsed = self?.parseAuthenticatedUser(
                    from: userJson,
                    accessTokenFallback: currentUser.accessToken,
                    authMethod: currentUser.authMethod
                   ) {
                    self?.applyAuthenticatedUser(parsed)
                } else {
                    self?.updateCurrentUserContactCard(contactCard)
                }
                completion(true, nil)
            }
        }.resume()
    }

    func openMastodonInstanceInBrowser(instance: String) {
        let trimmed = instance.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty,
              let url = URL(string: "https://\(trimmed)") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Models

struct AuthenticatedUser: Codable, Identifiable {
    struct ContactCard: Codable {
        var fullName: String?
        var firstName: String?
        var lastName: String?
        var nickname: String?
        var company: String?
        var email: String?
        var phone: String?
        var address: String?
        var city: String?
        var state: String?
        var postalCode: String?
        var country: String?
        var website: String?
        var notes: String?
        var organisationRole: String?
        var source: String?
        var importFormats: [String] = []
        var autoSyncedAt: Date?

        static func from(json: [String: Any]) -> ContactCard {
            ContactCard(
                fullName: json["fullName"] as? String,
                firstName: json["firstName"] as? String,
                lastName: json["lastName"] as? String,
                nickname: json["nickname"] as? String,
                company: json["company"] as? String,
                email: json["email"] as? String,
                phone: json["phone"] as? String,
                address: json["address"] as? String,
                city: json["city"] as? String,
                state: json["state"] as? String,
                postalCode: json["postalCode"] as? String,
                country: json["country"] as? String,
                website: json["website"] as? String,
                notes: json["notes"] as? String,
                organisationRole: json["organisationRole"] as? String,
                source: json["source"] as? String,
                importFormats: json["importFormats"] as? [String] ?? [],
                autoSyncedAt: AuthenticationManager.parseDateField(json["autoSyncedAt"])
            )
        }
    }

    struct PasskeyState: Codable {
        var supported: Bool = false
        var eligible: Bool = false
        var registered: Bool = false
        var count: Int = 0
        var recommendedAfterMinutes: Int = 10
    }

    let id: String
    let username: String
    let displayName: String
    let email: String?
    var canonicalEmail: String?
    let authMethod: AuthMethod
    let mastodonInstance: String?
    var accessToken: String
    let avatarURL: String?
    var accountId: String?
    var canonicalAccountId: String?
    var linkedLocalUserId: String?
    var role: String?
    var authProvider: String?
    var gender: String?
    var permissions: [String] = []
    var entitlements: [String: AnyCodable] = [:]
    var passkey: PasskeyState = PasskeyState()
    var presence: String = "online"
    var lastLoginAt: Date?
    var lastSeenAt: Date?
    var lastActiveAt: Date?
    var contactCard: ContactCard?

    // Mastodon account factors (affects room limits)
    var followersCount: Int = 0
    var followingCount: Int = 0
    var statusesCount: Int = 0
    var accountCreatedAt: Date?

    var fullHandle: String {
        if authMethod == .mastodon, let instance = mastodonInstance {
            return "@\(username)@\(instance)"
        }
        return username
    }

    // Calculate account age in days
    var accountAgeDays: Int {
        guard let created = accountCreatedAt else { return 0 }
        return Calendar.current.dateComponents([.day], from: created, to: Date()).day ?? 0
    }

    // Account reputation score based on Mastodon factors
    var accountReputation: AccountReputation {
        guard authMethod == .mastodon else {
            return .standard
        }

        // Calculate reputation based on followers, age, and activity
        var score = 0

        // Account age factor
        if accountAgeDays >= 365 { score += 30 }
        else if accountAgeDays >= 180 { score += 20 }
        else if accountAgeDays >= 90 { score += 10 }
        else if accountAgeDays >= 30 { score += 5 }

        // Followers factor
        if followersCount >= 1000 { score += 30 }
        else if followersCount >= 500 { score += 20 }
        else if followersCount >= 100 { score += 10 }
        else if followersCount >= 50 { score += 5 }

        // Activity factor (posts)
        if statusesCount >= 1000 { score += 20 }
        else if statusesCount >= 500 { score += 15 }
        else if statusesCount >= 100 { score += 10 }
        else if statusesCount >= 50 { score += 5 }

        // Following ratio (not following way more than followers)
        let ratio = followersCount > 0 ? Double(followingCount) / Double(followersCount) : 10.0
        if ratio < 1.5 { score += 10 }
        else if ratio < 3.0 { score += 5 }

        if score >= 70 { return .veteran }
        if score >= 50 { return .established }
        if score >= 30 { return .active }
        if score >= 15 { return .standard }
        return .new
    }

    // Bonus rooms from Mastodon reputation
    var bonusPermanentRooms: Int {
        accountReputation.bonusRooms
    }

    // Bonus room capacity from reputation
    var bonusRoomCapacity: Int {
        accountReputation.bonusCapacity
    }
}

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else if let arrayValue = try? container.decode([AnyCodable].self) {
            value = arrayValue.map(\.value)
        } else if let dictValue = try? container.decode([String: AnyCodable].self) {
            value = dictValue.mapValues(\.value)
        } else {
            value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let intValue as Int:
            try container.encode(intValue)
        case let doubleValue as Double:
            try container.encode(doubleValue)
        case let boolValue as Bool:
            try container.encode(boolValue)
        case let stringValue as String:
            try container.encode(stringValue)
        case let arrayValue as [Any]:
            try container.encode(arrayValue.map(AnyCodable.init))
        case let dictValue as [String: Any]:
            try container.encode(dictValue.mapValues(AnyCodable.init))
        default:
            try container.encodeNil()
        }
    }
}

struct TwoFactorMethod: Identifiable, Codable, Hashable {
    let type: String
    let name: String
    let hint: String?
    let count: Int?
    let remaining: Int?

    var id: String { type }

    var supportsDelivery: Bool {
        ["email", "sms", "voice"].contains(type)
    }
}

enum AccountAuthProvider: String, CaseIterable, Identifiable {
    case local = "local"
    case whmcs = "whmcs"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: return "Client Account"
        case .whmcs: return "Client Account"
        }
    }
}

enum AccountReputation: String, Codable {
    case new = "New"           // < 30 days, few followers
    case standard = "Standard" // Default
    case active = "Active"     // Some activity
    case established = "Established" // Good track record
    case veteran = "Veteran"   // Long-time, well-followed

    var bonusRooms: Int {
        switch self {
        case .new: return 0
        case .standard: return 1
        case .active: return 2
        case .established: return 4
        case .veteran: return 8
        }
    }

    var bonusCapacity: Int {
        switch self {
        case .new: return 0
        case .standard: return 5
        case .active: return 10
        case .established: return 25
        case .veteran: return 50
        }
    }

    var color: String {
        switch self {
        case .new: return "gray"
        case .standard: return "blue"
        case .active: return "green"
        case .established: return "purple"
        case .veteran: return "gold"
        }
    }

    var icon: String {
        switch self {
        case .new: return "leaf"
        case .standard: return "person"
        case .active: return "flame"
        case .established: return "star.fill"
        case .veteran: return "crown.fill"
        }
    }
}

enum AuthMethod: String, Codable {
    case pairingCode = "pairing"
    case mastodon = "mastodon"
    case discord = "discord"
    case email = "email"
    case adminInvite = "admin_invite"
    case whmcs = "whmcs"

    var displayName: String {
        switch self {
        case .pairingCode: return "Pairing Code"
        case .mastodon: return "Mastodon"
        case .discord: return "Discord"
        case .email: return "Email"
        case .adminInvite: return "Admin Invite"
        case .whmcs: return "Client Account"
        }
    }

    var icon: String {
        switch self {
        case .pairingCode: return "number.circle"
        case .mastodon: return "at.circle"
        case .discord: return "bubble.left.and.bubble.right"
        case .email: return "envelope.circle"
        case .adminInvite: return "person.badge.key"
        case .whmcs: return "building.2.crop.circle"
        }
    }
}

// MARK: - Linked Device Model

struct LinkedDevice: Codable, Identifiable {
    let id: String
    let deviceName: String
    let clientId: String
    let authMethod: AuthMethod
    let linkedAt: Date
    var lastSeen: Date
    var isOnline: Bool
    var isRevoked: Bool
    var isCurrentDevice: Bool = false

    var statusText: String {
        if isRevoked {
            return "Revoked"
        }
        if isCurrentDevice {
            return "Online on this device"
        }
        if isOnline || Date().timeIntervalSince(lastSeen) <= 300 {
            return "Online and reachable via API"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Offline • last seen \(formatter.localizedString(for: lastSeen, relativeTo: Date()))"
    }
}

struct PendingDeviceApproval: Codable, Identifiable {
    let id: String
    let userId: String
    let userName: String
    let code: String
    let status: String
    let createdAt: Date
    let expiresAt: Date
    let requestedAt: Date
    let approvedAt: Date?
    let deniedAt: Date?
    let reason: String?
    let deviceId: String?
    let deviceName: String
    let deviceType: String
    let clientVersion: String?
    let timeZone: String?
    let locale: String?
    let locationHint: String?
    let ip: String?
    let userAgent: String?
    let approvalMethods: [String]
    let viaMastodon: Bool

    var isExpired: Bool {
        status.lowercased() == "expired" || expiresAt <= Date()
    }

    var statusText: String {
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        if isExpired {
            return "Expired"
        }
        switch status.lowercased() {
        case "approved":
            return "Approved"
        case "denied":
            return "Denied"
        default:
            return "Expires \(relative.localizedString(for: expiresAt, relativeTo: Date()))"
        }
    }
}

// MARK: - Notifications
extension Notification.Name {
    static let mastodonAccountLoaded = Notification.Name("mastodonAccountLoaded")
    // Note: accessRevoked is already declared in ServerManager.swift
    static let deviceLinked = Notification.Name("deviceLinked")
    static let deviceUnlinked = Notification.Name("deviceUnlinked")
    static let deviceApprovalRequested = Notification.Name("deviceApprovalRequested")
    static let deviceApprovalPending = Notification.Name("deviceApprovalPending")
    static let deviceApprovalApproved = Notification.Name("deviceApprovalApproved")
    static let deviceApprovalDenied = Notification.Name("deviceApprovalDenied")
    static let deviceApprovalResolved = Notification.Name("deviceApprovalResolved")
    static let deviceApprovalExpired = Notification.Name("deviceApprovalExpired")
}

// MARK: - Device Revocation Manager

class DeviceRevocationManager: ObservableObject {
    static let shared = DeviceRevocationManager()

    @Published var linkedDevices: [LinkedDevice] = []
    @Published var pendingApprovals: [PendingDeviceApproval] = []
    @Published var pendingApprovalForCurrentDevice: PendingDeviceApproval?
    @Published var isLoading = false
    @Published var error: String?

    private func currentDeviceNameCandidates() -> Set<String> {
        var names = Set<String>()
        if let localized = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !localized.isEmpty {
            names.insert(localized.lowercased())
        }
        if let host = Host.current().name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !host.isEmpty {
            names.insert(host.lowercased())
            if let first = host.split(separator: ".").first, !first.isEmpty {
                names.insert(String(first).lowercased())
            }
        }
        return names
    }

    private var serverURL: String?

    init() {
        // Listen for Socket.IO revocation events
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAccessRevoked(_:)),
            name: .accessRevoked,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleServerConnectionChanged),
            name: .serverConnectionChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeviceApprovalRequested(_:)),
            name: .deviceApprovalRequested,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeviceApprovalPending(_:)),
            name: .deviceApprovalPending,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeviceApprovalResolved(_:)),
            name: .deviceApprovalResolved,
            object: nil
        )
    }

    @objc private func handleAccessRevoked(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reason = userInfo["reason"] as? String else { return }

        DispatchQueue.main.async {
            // Show alert to user
            let alert = NSAlert()
            alert.messageText = "Access Revoked"
            alert.informativeText = reason
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()

            // Clear local auth state
            AuthenticationManager.shared.logout()
        }
    }

    @objc private func handleServerConnectionChanged() {
        guard ServerManager.shared.isConnected,
              let baseURL = ServerManager.shared.baseURL,
              !baseURL.isEmpty else {
            return
        }
        fetchDevices(serverURL: baseURL)
    }

    @objc private func handleDeviceApprovalRequested(_ notification: Notification) {
        guard let approval = parseApproval(from: notification.userInfo) else { return }
        DispatchQueue.main.async {
            self.upsertApproval(approval)
        }
    }

    @objc private func handleDeviceApprovalPending(_ notification: Notification) {
        guard let approval = parseApproval(from: notification.userInfo) else { return }
        DispatchQueue.main.async {
            self.pendingApprovalForCurrentDevice = approval
        }
    }

    @objc private func handleDeviceApprovalResolved(_ notification: Notification) {
        guard let approval = parseApproval(from: notification.userInfo) else { return }
        DispatchQueue.main.async {
            self.pendingApprovals.removeAll { $0.id == approval.id }
            if self.pendingApprovalForCurrentDevice?.id == approval.id {
                self.pendingApprovalForCurrentDevice = approval
            }
        }
    }

    private func parseApproval(from userInfo: [AnyHashable: Any]?) -> PendingDeviceApproval? {
        guard let payload = userInfo as? [String: Any] else { return nil }
        let formatter = ISO8601DateFormatter()
        let requestedBy = payload["requestedBy"] as? [String: Any] ?? [:]
        guard let approvalId = payload["approvalId"] as? String,
              let userId = payload["userId"] as? String else {
            return nil
        }
        return PendingDeviceApproval(
            id: approvalId,
            userId: userId,
            userName: payload["userName"] as? String ?? "VoiceLink user",
            code: payload["code"] as? String ?? "",
            status: payload["status"] as? String ?? "pending",
            createdAt: (payload["createdAt"] as? String).flatMap { formatter.date(from: $0) } ?? Date(),
            expiresAt: (payload["expiresAt"] as? String).flatMap { formatter.date(from: $0) } ?? Date().addingTimeInterval(300),
            requestedAt: (payload["requestedAt"] as? String).flatMap { formatter.date(from: $0) } ?? Date(),
            approvedAt: (payload["approvedAt"] as? String).flatMap { formatter.date(from: $0) },
            deniedAt: (payload["deniedAt"] as? String).flatMap { formatter.date(from: $0) },
            reason: payload["reason"] as? String,
            deviceId: requestedBy["deviceId"] as? String,
            deviceName: requestedBy["deviceName"] as? String ?? "Unknown Device",
            deviceType: requestedBy["deviceType"] as? String ?? "unknown",
            clientVersion: requestedBy["clientVersion"] as? String,
            timeZone: requestedBy["timeZone"] as? String,
            locale: requestedBy["locale"] as? String,
            locationHint: requestedBy["locationHint"] as? String,
            ip: requestedBy["ip"] as? String,
            userAgent: requestedBy["userAgent"] as? String,
            approvalMethods: payload["approvalMethods"] as? [String] ?? ["in_app"],
            viaMastodon: payload["viaMastodon"] as? Bool ?? false
        )
    }

    private func upsertApproval(_ approval: PendingDeviceApproval) {
        pendingApprovals.removeAll { $0.id == approval.id }
        if !approval.isExpired && approval.status.lowercased() == "pending" {
            pendingApprovals.insert(approval, at: 0)
        }
    }

    func markCurrentDeviceOnline() {
        guard ServerManager.shared.isConnected else { return }

        let currentClientId = AuthenticationManager.shared.getClientId()
        let currentDeviceNames = currentDeviceNameCandidates()
        let now = Date()

        if let index = linkedDevices.firstIndex(where: { device in
            device.clientId == currentClientId
                || currentDeviceNames.contains(device.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }) {
            linkedDevices[index].isCurrentDevice = true
            linkedDevices[index].isOnline = true
            linkedDevices[index].lastSeen = now
            return
        }

        guard let currentUser = AuthenticationManager.shared.currentUser else { return }
        let deviceName = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? Host.current().localizedName!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "This Mac"

        linkedDevices.insert(
            LinkedDevice(
                id: "current-\(currentClientId)",
                deviceName: deviceName,
                clientId: currentClientId,
                authMethod: currentUser.authMethod,
                linkedAt: now,
                lastSeen: now,
                isOnline: true,
                isRevoked: false,
                isCurrentDevice: true
            ),
            at: 0
        )
    }

    // Fetch linked devices from server
    func fetchDevices(serverURL: String) {
        self.serverURL = serverURL
        isLoading = true
        error = nil
        markCurrentDeviceOnline()
        fetchPendingApprovals()
        let currentClientId = AuthenticationManager.shared.getClientId()
        let currentDeviceNames = currentDeviceNameCandidates()

        guard let url = URL(string: "\(serverURL)/api/devices") else {
            error = "Invalid server URL"
            isLoading = false
            return
        }

        var request = URLRequest(url: url)
        applyAuthHeaders(to: &request)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoading = false

                if let error = error {
                    self?.error = error.localizedDescription
                    self?.markCurrentDeviceOnline()
                    return
                }

                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let devicesArray = json["devices"] as? [[String: Any]] else {
                    self?.error = "Failed to parse devices"
                    return
                }

                self?.linkedDevices = devicesArray.compactMap { dict -> LinkedDevice? in
                    guard let id = dict["id"] as? String,
                          let deviceName = dict["deviceName"] as? String,
                          let clientId = dict["clientId"] as? String ?? dict["id"] as? String,
                          let authMethodStr = dict["authMethod"] as? String,
                          let authMethod = AuthMethod(rawValue: authMethodStr) else {
                        return nil
                    }

                    let linkedAtStr = dict["linkedAt"] as? String
                    let lastSeenStr = dict["lastSeen"] as? String

                    let formatter = ISO8601DateFormatter()
                    let linkedAt = linkedAtStr.flatMap { formatter.date(from: $0) } ?? Date()
                    let lastSeen = lastSeenStr.flatMap { formatter.date(from: $0) } ?? Date()
                    let reportedOnline = dict["isOnline"] as? Bool ?? false
                    let normalizedDeviceName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let isCurrentDevice = clientId == currentClientId || currentDeviceNames.contains(normalizedDeviceName)

                    return LinkedDevice(
                        id: id,
                        deviceName: deviceName,
                        clientId: clientId,
                        authMethod: authMethod,
                        linkedAt: linkedAt,
                        lastSeen: lastSeen,
                        isOnline: reportedOnline || isCurrentDevice,
                        isRevoked: dict["isRevoked"] as? Bool ?? false,
                        isCurrentDevice: isCurrentDevice
                    )
                }
                self?.markCurrentDeviceOnline()
            }
        }.resume()
    }

    func fetchPendingApprovals() {
        guard let serverURL,
              let url = URL(string: "\(serverURL)/api/devices/approvals") else {
            return
        }

        var request = URLRequest(url: url)
        applyAuthHeaders(to: &request)

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if error != nil {
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let approvalsArray = json["approvals"] as? [[String: Any]] else {
                    return
                }
                self.pendingApprovals = approvalsArray.compactMap { self.parseApproval(from: $0) }
                    .filter { !$0.isExpired && $0.status.lowercased() == "pending" }
            }
        }.resume()
    }

    func approveDeviceApproval(approvalId: String, reason: String? = nil, completion: @escaping (Bool, String?) -> Void) {
        submitDeviceApprovalDecision(approvalId: approvalId, action: "approve", reason: reason, completion: completion)
    }

    func denyDeviceApproval(approvalId: String, reason: String? = nil, completion: @escaping (Bool, String?) -> Void) {
        submitDeviceApprovalDecision(approvalId: approvalId, action: "deny", reason: reason, completion: completion)
    }

    private func submitDeviceApprovalDecision(approvalId: String, action: String, reason: String? = nil, completion: @escaping (Bool, String?) -> Void) {
        guard let serverURL,
              let url = URL(string: "\(serverURL)/api/devices/approvals/\(approvalId)/\(action)") else {
            completion(false, "Invalid server URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["reason": reason])
        }
        applyAuthHeaders(to: &request)

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                if let error {
                    completion(false, error.localizedDescription)
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = json["success"] as? Bool, success else {
                    let message = (try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any])?["error"] as? String
                    completion(false, message ?? "Failed to update approval")
                    return
                }
                self?.pendingApprovals.removeAll { $0.id == approvalId }
                if self?.pendingApprovalForCurrentDevice?.id == approvalId {
                    self?.pendingApprovalForCurrentDevice = nil
                }
                completion(true, nil)
            }
        }.resume()
    }

    // Revoke a specific device
    func revokeDevice(deviceId: String, reason: String? = nil, completion: @escaping (Bool, String?) -> Void) {
        guard let serverURL = serverURL,
              let url = URL(string: "\(serverURL)/api/devices/\(deviceId)/revoke") else {
            completion(false, "Invalid server URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let reason = reason {
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["reason": reason])
        }
        applyAuthHeaders(to: &request)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(false, error.localizedDescription)
                    return
                }

                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = json["success"] as? Bool, success else {
                    completion(false, "Failed to revoke device")
                    return
                }

                // Update local list
                if let index = self?.linkedDevices.firstIndex(where: { $0.id == deviceId }) {
                    self?.linkedDevices[index].isRevoked = true
                }

                completion(true, nil)
            }
        }.resume()
    }

    // Remove a device completely
    func removeDevice(deviceId: String, completion: @escaping (Bool, String?) -> Void) {
        guard let serverURL = serverURL,
              let url = URL(string: "\(serverURL)/api/devices/\(deviceId)") else {
            completion(false, "Invalid server URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyAuthHeaders(to: &request)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(false, error.localizedDescription)
                    return
                }

                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = json["success"] as? Bool, success else {
                    completion(false, "Failed to remove device")
                    return
                }

                // Remove from local list
                self?.linkedDevices.removeAll { $0.id == deviceId }

                completion(true, nil)
            }
        }.resume()
    }

    private func applyAuthHeaders(to request: inout URLRequest) {
        guard let currentUser = AuthenticationManager.shared.currentUser else { return }
        request.setValue("Bearer \(currentUser.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(currentUser.id, forHTTPHeaderField: "X-User-Id")
        request.setValue(currentUser.username, forHTTPHeaderField: "X-User-Name")
        request.setValue(currentUser.role, forHTTPHeaderField: "X-User-Role")
        request.setValue(currentUser.authProvider ?? currentUser.authMethod.rawValue, forHTTPHeaderField: "X-Auth-Provider")
        request.setValue(currentUser.authMethod.rawValue, forHTTPHeaderField: "X-Auth-Method")
    }
}

// MARK: - Authentication Views

struct MastodonAuthView: View {
    @ObservedObject private var authManager = AuthenticationManager.shared
    @State private var instanceInput: String = AuthenticationManager.preferredMastodonInstance
    @State private var isAuthenticating = false
    @Binding var isPresented: Bool
    var onSuccess: (() -> Void)?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "at.circle.fill")
                .font(.system(size: 50))
                .foregroundColor(.purple)

            Text("Sign in with Mastodon")
                .font(.title2)
                .fontWeight(.bold)

            Text("Enter your Mastodon instance")
                .foregroundColor(.gray)

            HStack {
                Text("https://")
                    .foregroundColor(.gray)
                TextField("mastodon.social", text: $instanceInput)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(width: 300)

            HStack(spacing: 10) {
                Button("DevineCreations") {
                    instanceInput = AuthenticationManager.preferredMastodonInstance
                }
                .buttonStyle(.bordered)

                Button("TappedIn") {
                    instanceInput = "md.tappedin.fm"
                }
                .buttonStyle(.bordered)
            }

            if let error = authManager.authError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            HStack(spacing: 15) {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.bordered)

                Button("Sign In") {
                    authenticate()
                }
                .buttonStyle(.borderedProminent)
                .disabled(instanceInput.isEmpty || isAuthenticating)
            }

            if !instanceInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Open Instance in Browser") {
                    authManager.openMastodonInstanceInBrowser(instance: instanceInput)
                }
                .buttonStyle(.bordered)
            }

            Text("This will open your browser to authorize VoiceLink")
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding(30)
        .frame(width: 400, height: 350)
        .onAppear {
            if let existing = authManager.currentUser?.mastodonInstance?.trimmingCharacters(in: .whitespacesAndNewlines),
               !existing.isEmpty {
                instanceInput = existing
            } else if instanceInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                instanceInput = AuthenticationManager.preferredMastodonInstance
            }
        }
    }

    private func authenticate() {
        isAuthenticating = true
        authManager.authenticateWithMastodon(instance: instanceInput) { success, _ in
            isAuthenticating = false
            if success {
                isPresented = false
                onSuccess?()
            }
        }
    }
}

struct AccountPasswordAuthView: View {
    @ObservedObject private var authManager = AuthenticationManager.shared
    @Binding var isPresented: Bool
    let serverURL: String
    var initialProvider: AccountAuthProvider = .local
    var onSuccess: (() -> Void)?

    @State private var provider: AccountAuthProvider = .local
    @State private var identityInput: String = ""
    @State private var passwordInput: String = ""
    @State private var twoFactorInput: String = ""
    @State private var statusMessage: String?
    @State private var isLoading = false
    @State private var needsTwoFactor = false
    @State private var isRequestingTwoFactorCode = false

    private var normalizedServerURL: String {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ServerManager.mainServer }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return "https://\(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
    }

    private var whmcsPasswordResetURL: URL? {
        URL(string: "\(normalizedServerURL)/index.php?rp=/password/reset/begin")
    }

    private var clientPortalCreateURL: URL? {
        URL(string: "https://devine-creations.com/register.php")
    }

    private var clientPortalURL: URL? {
        URL(string: "https://devine-creations.com/clientarea.php")
    }

    private var availableTwoFactorMethods: [TwoFactorMethod] {
        authManager.availableTwoFactorMethods
    }

    private var deliveryMethods: [TwoFactorMethod] {
        availableTwoFactorMethods.filter(\.supportsDelivery)
    }

    private var selectedTwoFactorMethodBinding: Binding<String> {
        Binding(
            get: { authManager.selectedTwoFactorMethod ?? deliveryMethods.first?.type ?? "email" },
            set: { authManager.selectedTwoFactorMethod = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 50))
                .foregroundColor(.blue)

            Text("Account Sign-In")
                .font(.title2)
                .fontWeight(.bold)

            Text("Enter your account name. VoiceLink will use your username or email in the background and resolve the correct account type automatically.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            TextField("Username or email address", text: $identityInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .textContentType(.username)
                .accessibilityLabel("Username or email")
                .accessibilityHint("Enter the VoiceLink account username or verified email address for this account.")

            SecureField("Password or app password", text: $passwordInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .textContentType(.password)
                .accessibilityLabel("Password")
                .accessibilityHint("Enter the account password. If two-factor or app passwords are enabled, use the appropriate password for this account.")

            if needsTwoFactor {
                if !deliveryMethods.isEmpty {
                    Picker("Verification method", selection: selectedTwoFactorMethodBinding) {
                        ForEach(deliveryMethods) { method in
                            if let hint = method.hint, !hint.isEmpty {
                                Text("\(method.name) (\(hint))").tag(method.type)
                            } else {
                                Text(method.name).tag(method.type)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 240)
                    .accessibilityLabel("Verification method")
                    .accessibilityHint("Choose how VoiceLink should deliver the verification code.")

                    Button(isRequestingTwoFactorCode ? "Sending..." : sendButtonTitle) {
                        requestTwoFactorCode()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRequestingTwoFactorCode)
                }

                TextField("6-digit two-factor code", text: $twoFactorInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .textContentType(.oneTimeCode)
                    .accessibilityLabel("Two-factor code")
                    .accessibilityHint("Enter the current two-factor authentication code for this account.")
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let error = authManager.authError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 6) {
                Button("Forgot Password?") {
                    guard let url = whmcsPasswordResetURL else { return }
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.link)

                Button("Forgot Username? Use Email Code Sign-In") {
                    isPresented = false
                }
                .buttonStyle(.link)

                Button("Create Client Account") {
                    guard let url = clientPortalCreateURL else { return }
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.link)

                Button("Open Client Account Portal") {
                    guard let url = clientPortalURL else { return }
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.link)

                Text("If your Client Account is linked through the portal, password recovery will continue through the client account email reset flow.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: 340)
            }

            HStack(spacing: 15) {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.bordered)

                Button(needsTwoFactor ? "Verify 2FA" : "Sign In") {
                    signIn()
                }
                .buttonStyle(.borderedProminent)
                .disabled(identityInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || passwordInput.isEmpty || isLoading)
            }
        }
        .padding(30)
        .frame(width: 420)
        .onAppear {
            provider = initialProvider
        }
    }

    private func signIn() {
        isLoading = true
        statusMessage = needsTwoFactor ? "Verifying code..." : "Signing in..."
        authManager.signInWithAccount(
            identity: identityInput,
            password: passwordInput,
            serverURL: serverURL,
            provider: provider,
            twoFactorCode: twoFactorInput
        ) { success, error, requires2FA in
            isLoading = false
            if success {
                isPresented = false
                onSuccess?()
            } else if requires2FA {
                needsTwoFactor = true
                if authManager.selectedTwoFactorMethod == nil {
                    authManager.selectedTwoFactorMethod = deliveryMethods.first?.type ?? availableTwoFactorMethods.first?.type
                }
                statusMessage = error ?? "Two-factor authentication code required."
            } else {
                statusMessage = error ?? "Sign-in failed."
            }
        }
    }

    private var sendButtonTitle: String {
        switch authManager.selectedTwoFactorMethod {
        case "voice":
            return "Call Me the Code"
        case "sms":
            return "Text Me the Code"
        default:
            return "Send Code"
        }
    }

    private func requestTwoFactorCode() {
        let method = authManager.selectedTwoFactorMethod ?? deliveryMethods.first?.type ?? "email"
        isRequestingTwoFactorCode = true
        authManager.requestTwoFactorChallenge(
            identity: identityInput,
            password: passwordInput,
            serverURL: normalizedServerURL,
            method: method
        ) { success, error in
            isRequestingTwoFactorCode = false
            statusMessage = success
                ? (authManager.twoFactorDeliveryStatus ?? "Verification challenge sent.")
                : (error ?? "Unable to send verification code.")
        }
    }
}

struct EmailAuthView: View {
    @ObservedObject private var authManager = AuthenticationManager.shared
    @State private var emailInput: String = ""
    @State private var codeInput: String = ""
    @State private var isRequesting = false
    @State private var showCodeEntry = false
    @Binding var isPresented: Bool
    let serverURL: String
    var onSuccess: (() -> Void)?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "envelope.circle.fill")
                .font(.system(size: 50))
                .foregroundColor(.blue)

            Text("Sign in with Email")
                .font(.title2)
                .fontWeight(.bold)

            if !showCodeEntry {
                // Email entry
                Text("Enter your email address")
                    .foregroundColor(.gray)

                TextField("name@example.com", text: $emailInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .accessibilityLabel("Email address")
                    .accessibilityHint("Enter a verified email address for your VoiceLink account to receive a sign-in code.")

                HStack(spacing: 15) {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .buttonStyle(.bordered)

                    Button("Send Code") {
                        requestCode()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(emailInput.isEmpty || isRequesting)
                }
            } else {
                // Code entry
                Text("Enter the 6-digit code sent to \(emailInput)")
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)

                TextField("6-digit sign-in code", text: $codeInput)
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .textContentType(.oneTimeCode)
                    .accessibilityLabel("Verification code")
                    .accessibilityHint("Enter the six-digit code that was sent to your email address.")
                    .onChange(of: codeInput) { newValue in
                        codeInput = String(newValue.uppercased().prefix(6))
                    }

                if let expiry = authManager.emailVerificationExpiry {
                    Text("Code expires \(expiry, style: .relative)")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                HStack(spacing: 15) {
                    Button("Back") {
                        showCodeEntry = false
                    }
                    .buttonStyle(.bordered)

                    Button("Verify") {
                        verifyCode()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(codeInput.count != 6 || isRequesting)
                }
            }

            if let error = authManager.authError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
        .padding(30)
        .frame(width: 400, height: 350)
    }

    private func requestCode() {
        isRequesting = true
        authManager.requestEmailVerification(email: emailInput, serverURL: serverURL) { success, error in
            isRequesting = false
            if success {
                showCodeEntry = true
            }
        }
    }

    private func verifyCode() {
        isRequesting = true
        authManager.verifyEmailCode(code: codeInput, serverURL: serverURL) { success, error in
            isRequesting = false
            if success {
                isPresented = false
                onSuccess?()
            }
        }
    }
}

struct AdminInviteAuthView: View {
    @ObservedObject private var authManager = AuthenticationManager.shared
    @State private var tokenInput: String = ""
    @State private var serverURLInput: String = ""
    @State private var emailInput: String = ""
    @State private var usernameInput: String = ""
    @State private var displayNameInput: String = ""
    @State private var passwordInput: String = ""
    @State private var isLoading = false
    @State private var statusMessage: String?
    @Binding var isPresented: Bool
    var onSuccess: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 44))
                .foregroundColor(.purple)
            Text("Admin Invite Activation")
                .font(.title3)
                .fontWeight(.semibold)

            TextField("Server URL such as https://voicelink.example.com", text: $serverURLInput)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Server URL")
                .accessibilityHint("Enter the full VoiceLink server address for this admin invite.")
            TextField("Invite token from the admin email or link", text: $tokenInput)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Invite token")
                .accessibilityHint("Paste the admin invite token exactly as it appears in the invite.")

            HStack(spacing: 8) {
                Button("Load Invite") { loadInvite() }
                    .buttonStyle(.bordered)
                Spacer()
                if let role = authManager.pendingAdminInviteRole, !role.isEmpty {
                    Text("Role: \(role)").font(.caption).foregroundColor(.secondary)
                }
            }

            TextField("Email address for this admin account", text: $emailInput)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Email address")
                .accessibilityHint("Enter the email address that should be attached to the admin account.")
            TextField("Username to use for this admin account", text: $usernameInput)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Username")
                .accessibilityHint("Enter the permanent username that this admin account should use.")
            TextField("Display name shown to other users", text: $displayNameInput)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Display name")
                .accessibilityHint("Enter the public display name that other users will see for this admin account.")
            SecureField("Password with at least 8 characters", text: $passwordInput)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Password")
                .accessibilityHint("Enter the password that should be used for this new admin account.")

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if let err = authManager.authError {
                Text(err).font(.caption).foregroundColor(.red)
            }

            HStack(spacing: 10) {
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.bordered)
                Button("Activate") { activateInvite() }
                    .buttonStyle(.borderedProminent)
                    .disabled(tokenInput.isEmpty || serverURLInput.isEmpty || usernameInput.isEmpty || passwordInput.count < 8 || isLoading)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if tokenInput.isEmpty { tokenInput = authManager.pendingAdminInviteToken ?? "" }
            if serverURLInput.isEmpty {
                serverURLInput = authManager.pendingAdminInviteServerURL ?? ServerManager.mainServer
            }
        }
    }

    private func normalizedServerURL() -> String {
        var server = serverURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !server.hasPrefix("http://") && !server.hasPrefix("https://") {
            server = "https://" + server
        }
        return server.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func loadInvite() {
        if let current = authManager.currentUser {
            statusMessage = "Sign out \(current.displayName) before loading an admin invite."
            return
        }
        isLoading = true
        statusMessage = "Loading invite..."
        let server = normalizedServerURL()
        authManager.fetchAdminInvite(token: tokenInput, serverURL: server) { success, error in
            isLoading = false
            if success {
                emailInput = authManager.pendingAdminInviteEmail ?? emailInput
                if displayNameInput.isEmpty {
                    displayNameInput = usernameInput
                }
                statusMessage = "Invite loaded."
            } else {
                statusMessage = error ?? "Failed to load invite."
            }
        }
    }

    private func activateInvite() {
        if let current = authManager.currentUser {
            statusMessage = "Sign out \(current.displayName) before activating an admin invite."
            return
        }
        isLoading = true
        statusMessage = "Activating admin access..."
        let server = normalizedServerURL()
        authManager.acceptAdminInvite(
            token: tokenInput,
            email: emailInput,
            username: usernameInput,
            displayName: displayNameInput.isEmpty ? usernameInput : displayNameInput,
            password: passwordInput,
            serverURL: server
        ) { success, error in
            isLoading = false
            if success {
                statusMessage = "Admin access activated."
                isPresented = false
                onSuccess?()
            } else {
                statusMessage = error ?? "Activation failed."
            }
        }
    }
}

struct CreateAdminInviteView: View {
    @ObservedObject private var authManager = AuthenticationManager.shared
    @State private var emailInput: String = ""
    @State private var roleInput: String = "admin"
    @State private var expiresMinutes: Int = 60
    @State private var serverURLInput: String = ""
    @State private var statusMessage: String?
    @State private var generatedInviteURL: String = ""
    @State private var isSubmitting = false
    @Binding var isPresented: Bool

    private let availableRoles = ["moderator", "admin", "owner"]

    private var expirySummaryText: String {
        let days = expiresMinutes / (24 * 60)
        let hours = (expiresMinutes % (24 * 60)) / 60
        let minutes = expiresMinutes % 60
        var parts: [String] = []
        if days > 0 {
            parts.append("\(days) day\(days == 1 ? "" : "s")")
        }
        if hours > 0 {
            parts.append("\(hours) hour\(hours == 1 ? "" : "s")")
        }
        if minutes > 0 || parts.isEmpty {
            parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 42))
                .foregroundColor(.blue)
            Text("Invite Someone")
                .font(.title3)
                .fontWeight(.semibold)

            TextField("Server URL (https://...)", text: $serverURLInput)
                .textFieldStyle(.roundedBorder)
            TextField("Invitee Email", text: $emailInput)
                .textFieldStyle(.roundedBorder)

            Picker("Role", selection: $roleInput) {
                ForEach(availableRoles, id: \.self) { role in
                    Text(role.capitalized).tag(role)
                }
            }
            .pickerStyle(.segmented)

            Stepper(value: $expiresMinutes, in: 5...(24 * 30 * 60), step: 5) {
                Text("This invite will expire in \(expirySummaryText).")
            }

            Text("After that, the recipient will need a new invite link.")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !generatedInviteURL.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Invite link ready")
                        .font(.headline)
                    Text(generatedInviteURL)
                        .font(.caption)
                        .textSelection(.enabled)
                        .foregroundColor(.secondary)
                    HStack {
                        Button("Copy Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(generatedInviteURL, forType: .string)
                            statusMessage = "Invite link copied."
                        }
                        .buttonStyle(.bordered)

                        Button("Copy Desktop Link") {
                            let desktopLink = generatedInviteURL
                                .replacingOccurrences(of: "/admin-invite.html?token=", with: "/")
                            if let token = generatedInviteURL.components(separatedBy: "token=").last {
                                let server = normalizedServerURL()
                                let link = "vcl://admin-invite?token=\(token)&server=\(server.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? server)"
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(link, forType: .string)
                                statusMessage = "Desktop invite link copied."
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.white.opacity(0.05))
                .cornerRadius(10)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let authError = authManager.authError {
                Text(authError)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                Button("Close") { isPresented = false }
                    .buttonStyle(.bordered)
                Button("Create Invite") { createInvite() }
                    .buttonStyle(.borderedProminent)
                    .disabled(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if serverURLInput.isEmpty {
                serverURLInput = AuthenticationManager.shared.pendingAdminInviteServerURL ?? ServerManager.shared.baseURL ?? ServerManager.mainServer
            }
        }
    }

    private func normalizedServerURL() -> String {
        var server = serverURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !server.hasPrefix("http://") && !server.hasPrefix("https://") {
            server = "https://" + server
        }
        return server.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func createInvite() {
        isSubmitting = true
        statusMessage = "Creating invite..."
        let server = normalizedServerURL()
        authManager.createAdminInvite(
            email: emailInput.trimmingCharacters(in: .whitespacesAndNewlines),
            role: roleInput,
            expiresMinutes: expiresMinutes,
            serverURL: server
        ) { success, error, inviteURL in
            isSubmitting = false
            if success {
                generatedInviteURL = inviteURL ?? ""
                statusMessage = "Invite created. An email invite was requested from the server for \(emailInput.trimmingCharacters(in: .whitespacesAndNewlines)). This invite will expire in \(expirySummaryText)."
            } else {
                statusMessage = error ?? "Failed to create invite."
            }
        }
    }
}

// MARK: - Device Management View (for server admin/menubar)

struct DeviceManagementView: View {
    @ObservedObject private var revocationManager = DeviceRevocationManager.shared
    @State private var showRevokeConfirm = false
    @State private var showRemoveConfirm = false
    @State private var selectedDevice: LinkedDevice?
    @State private var selectedApproval: PendingDeviceApproval?
    @State private var showApproveConfirm = false
    @State private var showDenyConfirm = false
    @State private var revokeReason: String = ""
    @State private var approvalReason: String = ""
    let serverURL: String

    var body: some View {
        VStack(spacing: 15) {
            // Header
            HStack {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.title2)
                    .foregroundColor(.blue)
                Text("Linked Devices")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button(action: { revocationManager.fetchDevices(serverURL: serverURL) }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(revocationManager.isLoading)
            }

            Divider()

            if revocationManager.isLoading {
                ProgressView()
                    .padding()
            } else if !revocationManager.pendingApprovals.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(revocationManager.pendingApprovals) { approval in
                            DeviceApprovalCard(
                                approval: approval,
                                onApprove: {
                                    selectedApproval = approval
                                    showApproveConfirm = true
                                },
                                onDeny: {
                                    selectedApproval = approval
                                    showDenyConfirm = true
                                }
                            )
                        }

                        Divider()
                            .padding(.vertical, 6)

                        ForEach(revocationManager.linkedDevices) { device in
                            DeviceCard(
                                device: device,
                                onRevoke: {
                                    selectedDevice = device
                                    showRevokeConfirm = true
                                },
                                onRemove: {
                                    selectedDevice = device
                                    showRemoveConfirm = true
                                }
                            )
                        }
                    }
                }
            } else if let error = revocationManager.error {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .foregroundColor(.gray)
                }
                .padding()
            } else if revocationManager.linkedDevices.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "link.circle")
                        .font(.system(size: 40))
                        .foregroundColor(.gray)
                    Text("No linked devices")
                        .foregroundColor(.gray)
                    Text("Devices paired with this server will appear here")
                        .font(.caption)
                        .foregroundColor(.gray.opacity(0.7))
                }
                .padding(.vertical, 40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(revocationManager.linkedDevices) { device in
                            DeviceCard(
                                device: device,
                                onRevoke: {
                                    selectedDevice = device
                                    showRevokeConfirm = true
                                },
                                onRemove: {
                                    selectedDevice = device
                                    showRemoveConfirm = true
                                }
                            )
                        }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 400, minHeight: 300)
        .onAppear {
            revocationManager.fetchDevices(serverURL: serverURL)
        }
        .alert("Approve Sign-In?", isPresented: $showApproveConfirm) {
            TextField("Reason (optional)", text: $approvalReason)
            Button("Cancel", role: .cancel) {
                approvalReason = ""
            }
            Button("Approve") {
                if let approval = selectedApproval {
                    revocationManager.approveDeviceApproval(
                        approvalId: approval.id,
                        reason: approvalReason.isEmpty ? nil : approvalReason
                    ) { _, _ in }
                }
                approvalReason = ""
            }
        } message: {
            if let approval = selectedApproval {
                Text("Approve \(approval.deviceName) to sign in to \(approval.userName)?")
            }
        }
        .alert("Deny Sign-In?", isPresented: $showDenyConfirm) {
            TextField("Reason (optional)", text: $approvalReason)
            Button("Cancel", role: .cancel) {
                approvalReason = ""
            }
            Button("Deny", role: .destructive) {
                if let approval = selectedApproval {
                    revocationManager.denyDeviceApproval(
                        approvalId: approval.id,
                        reason: approvalReason.isEmpty ? nil : approvalReason
                    ) { _, _ in }
                }
                approvalReason = ""
            }
        } message: {
            if let approval = selectedApproval {
                Text("Deny sign-in request from \(approval.deviceName).")
            }
        }
        .alert("Revoke Device Access?", isPresented: $showRevokeConfirm) {
            TextField("Reason (optional)", text: $revokeReason)
            Button("Cancel", role: .cancel) {
                revokeReason = ""
            }
            Button("Revoke", role: .destructive) {
                if let device = selectedDevice {
                    revocationManager.revokeDevice(
                        deviceId: device.id,
                        reason: revokeReason.isEmpty ? nil : revokeReason
                    ) { _, _ in }
                }
                revokeReason = ""
            }
        } message: {
            if let device = selectedDevice {
                Text("This will revoke access for \"\(device.deviceName)\". The device will be notified and disconnected.")
            }
        }
        .alert("Remove Device?", isPresented: $showRemoveConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                if let device = selectedDevice {
                    revocationManager.removeDevice(deviceId: device.id) { _, _ in }
                }
            }
        } message: {
            if let device = selectedDevice {
                Text("This will permanently remove \"\(device.deviceName)\" from the linked devices list.")
            }
        }
    }
}

struct DeviceApprovalCard: View {
    let approval: PendingDeviceApproval
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Pending sign-in approval")
                        .font(.headline)
                    Text(approval.code)
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .foregroundColor(.orange)
                        .cornerRadius(4)
                }

                Text("\(approval.deviceName) • \(approval.deviceType.capitalized)")
                    .font(.subheadline)
                Text(approval.statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let ip = approval.ip, !ip.isEmpty {
                    Text("IP \(ip)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let locationHint = approval.locationHint, !locationHint.isEmpty {
                    Text(locationHint)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if approval.viaMastodon {
                    Text("Also sent by Mastodon DM")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button("Approve", action: onApprove)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("Deny", role: .destructive, action: onDeny)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding()
        .background(Color.orange.opacity(0.06))
        .cornerRadius(10)
    }
}

struct DeviceCard: View {
    let device: LinkedDevice
    let onRevoke: () -> Void
    let onRemove: () -> Void

    var authMethodColor: Color {
        switch device.authMethod {
        case .pairingCode: return .gray
        case .mastodon: return .purple
        case .discord: return .indigo
        case .whmcs: return .orange
        case .email: return .blue
        case .adminInvite: return .indigo
        }
    }

    var body: some View {
        HStack {
            // Status indicator
            Circle()
                .fill(device.isRevoked ? Color.red : ((device.isCurrentDevice || device.isOnline) ? Color.green : Color.orange))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(device.deviceName)
                        .font(.headline)

                    // Auth method badge
                    HStack(spacing: 2) {
                        Image(systemName: device.authMethod.icon)
                            .font(.caption2)
                        Text(device.authMethod.displayName)
                            .font(.caption2)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(authMethodColor.opacity(0.2))
                    .foregroundColor(authMethodColor)
                    .cornerRadius(4)

                    if device.isRevoked {
                        Text("REVOKED")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.2))
                            .foregroundColor(.red)
                            .cornerRadius(4)
                    }
                }

                Text(device.statusText)
                    .font(.caption)
                    .foregroundColor(.gray)

                Text("Linked \(device.linkedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundColor(.gray.opacity(0.7))
            }

            Spacer()

            // Actions
            if !device.isRevoked {
                Button(action: onRevoke) {
                    Image(systemName: "xmark.circle")
                        .foregroundColor(.orange)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Revoke access")
            }

            Button(action: onRemove) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Remove device")
        }
        .padding()
        .background(device.isRevoked ? Color.red.opacity(0.05) : Color.white.opacity(0.05))
        .cornerRadius(10)
    }
}
