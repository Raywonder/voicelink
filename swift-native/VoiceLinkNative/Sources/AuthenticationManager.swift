import Foundation
import SwiftUI
import AuthenticationServices
import Security

// MARK: - Authentication Manager
class AuthenticationManager: ObservableObject {
    static let shared = AuthenticationManager()

    @Published var currentUser: AuthenticatedUser?
    @Published var authState: AuthState = .unauthenticated
    @Published var authError: String?

    // Mastodon OAuth state
    @Published var mastodonInstance: String = ""
    private var mastodonClientId: String?
    private var mastodonClientSecret: String?

    // Email verification state
    @Published var pendingEmailVerification: String?
    @Published var emailVerificationExpiry: Date?

    enum AuthState {
        case unauthenticated
        case authenticating
        case authenticated
        case error
    }

    init() {
        loadStoredAuth()
    }

    // MARK: - Mastodon OAuth

    func authenticateWithMastodon(instance: String, completion: @escaping (Bool, String?) -> Void) {
        authState = .authenticating
        mastodonInstance = instance.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

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
            "website": "https://voicelink.devinecreations.net"
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(false, error.localizedDescription)
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

        // Open in default browser - app will handle callback via URL scheme
        NSWorkspace.shared.open(url)

        // Store completion for callback handling
        pendingMastodonCompletion = completion
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

                self?.currentUser = user
                self?.authState = .authenticated
                self?.saveAuth(user: user)
                self?.pendingMastodonCompletion?(true, nil)
                self?.pendingMastodonCompletion = nil

                // Notify about reputation for room calculations
                NotificationCenter.default.post(name: .mastodonAccountLoaded, object: user)
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
                self?.emailVerificationExpiry = Date().addingTimeInterval(300) // 5 minutes
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

                self?.currentUser = user
                self?.authState = .authenticated
                self?.pendingEmailVerification = nil
                self?.emailVerificationExpiry = nil
                self?.saveAuth(user: user)
                completion(true, nil)
            }
        }.resume()
    }

    // MARK: - Session Management

    func logout() {
        currentUser = nil
        authState = .unauthenticated
        clearStoredAuth()
    }

    // MARK: - Persistence (Keychain)

    private func saveAuth(user: AuthenticatedUser) {
        if let data = try? JSONEncoder().encode(user) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "VoiceLink",
                kSecAttrAccount as String: "authUser",
                kSecValueData as String: data
            ]

            SecItemDelete(query as CFDictionary)
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    private func loadStoredAuth() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VoiceLink",
            kSecAttrAccount as String: "authUser",
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let user = try? JSONDecoder().decode(AuthenticatedUser.self, from: data) {
            currentUser = user
            authState = .authenticated
        }
    }

    private func clearStoredAuth() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VoiceLink",
            kSecAttrAccount as String: "authUser"
        ]
        SecItemDelete(query as CFDictionary)
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

struct AuthenticatedUser: Codable, Identifiable {
    let id: String
    let username: String
    let displayName: String
    let email: String?
    let authMethod: AuthMethod
    let mastodonInstance: String?
    var accessToken: String
    let avatarURL: String?

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
    case email = "email"

    var displayName: String {
        switch self {
        case .pairingCode: return "Pairing Code"
        case .mastodon: return "Mastodon"
        case .email: return "Email"
        }
    }

    var icon: String {
        switch self {
        case .pairingCode: return "number.circle"
        case .mastodon: return "at.circle"
        case .email: return "envelope.circle"
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
    var isRevoked: Bool

    var statusText: String {
        if isRevoked {
            return "Revoked"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Active \(formatter.localizedString(for: lastSeen, relativeTo: Date()))"
    }
}

// MARK: - Notifications
extension Notification.Name {
    static let mastodonAccountLoaded = Notification.Name("mastodonAccountLoaded")
}

// MARK: - Authentication Views

struct MastodonAuthView: View {
    @ObservedObject private var authManager = AuthenticationManager.shared
    @State private var instanceInput: String = ""
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

            Text("This will open your browser to authorize VoiceLink")
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding(30)
        .frame(width: 400, height: 350)
    }

    private func authenticate() {
        isAuthenticating = true
        authManager.authenticateWithMastodon(instance: instanceInput) { success, error in
            isAuthenticating = false
            if success {
                isPresented = false
                onSuccess?()
            }
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

                TextField("you@example.com", text: $emailInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)

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

                TextField("XXXXXX", text: $codeInput)
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
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
