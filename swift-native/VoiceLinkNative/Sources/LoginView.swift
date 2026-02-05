import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var authManager = AuthenticationManager.shared
    @State private var mastodonInstance: String = ""
    @State private var whmcsEmail: String = ""
    @State private var whmcsPassword: String = ""
    @State private var whmcsTwoFactor: String = ""
    @State private var whmcsMastodonHandle: String = ""
    @State private var rememberWhmcs: Bool = true
    @State private var loginMode: LoginMode = .mastodon
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    enum LoginMode: String, CaseIterable, Identifiable {
        case mastodon = "Mastodon"
        case clientPortal = "Client Portal"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)

                Text("Login to VoiceLink")
                    .font(.title)
                    .fontWeight(.bold)

                Text(loginMode == .mastodon ? "Connect with your Mastodon account" : "Sign in with your Client Portal account")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 30)

            // Login Form
            VStack(spacing: 16) {
                Picker("Login Method", selection: $loginMode) {
                    ForEach(LoginMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isLoading)

                if loginMode == .mastodon {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Mastodon Instance")
                            .font(.headline)
                            .foregroundColor(.white)

                        TextField("mastodon.social", text: $mastodonInstance)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                            .textInputAutocapitalization(.never)
                            .disabled(isLoading)

                        Text("Enter your Mastodon instance domain (e.g., mastodon.social)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Button(action: handleLogin) {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "person.fill.checkmark")
                            }
                            Text(isLoading ? "Authenticating..." : "Login with Mastodon")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(isLoading ? Color.gray : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .disabled(mastodonInstance.isEmpty || isLoading)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Client Portal Email")
                            .font(.headline)
                            .foregroundColor(.white)

                        TextField("you@devinecreations.net", text: $whmcsEmail)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .disabled(isLoading)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Client Portal Password")
                            .font(.headline)
                            .foregroundColor(.white)

                        SecureField("Password", text: $whmcsPassword)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.password)
                            .disabled(isLoading)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Two-Factor Code (if enabled)")
                            .font(.headline)
                            .foregroundColor(.white)

                        TextField("123 456", text: $whmcsTwoFactor)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.oneTimeCode)
                            .textInputAutocapitalization(.never)
                            .disabled(isLoading)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Mastodon Handle (optional)")
                            .font(.headline)
                            .foregroundColor(.white)

                        TextField("@name@instance.social", text: $whmcsMastodonHandle)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .disabled(isLoading)
                    }

                    Toggle("Remember me", isOn: $rememberWhmcs)
                        .disabled(isLoading)

                    Button(action: handleWhmcsLogin) {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "person.badge.key")
                            }
                            Text(isLoading ? "Authenticating..." : "Login with Client Portal")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(isLoading ? Color.gray : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .disabled(whmcsEmail.isEmpty || whmcsPassword.isEmpty || isLoading)

                    Button(action: handleWhmcsPortalLogin) {
                        HStack {
                            Image(systemName: "safari")
                            Text("Login via Client Portal")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.gray.opacity(0.2))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .disabled(whmcsEmail.isEmpty || whmcsPassword.isEmpty || isLoading)
                }

                // Error Message
                if let error = errorMessage ?? authManager.authError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding(.horizontal, 40)

            Spacer()

            // Back Button
            Button(action: {
                appState.currentScreen = .mainMenu
            }) {
                HStack {
                    Image(systemName: "arrow.left")
                    Text("Back to Main Menu")
                }
                .foregroundColor(.secondary)
            }
            .padding(.bottom, 20)
        }
        .frame(maxWidth: 500)
        .padding()
        .onAppear {
            // Check if already authenticated
            if authManager.authState == .authenticated {
                appState.currentScreen = .mainMenu
            }
        }
        .onReceive(authManager.$currentUser) { user in
            if let user = user {
                appState.username = user.displayName
            }
        }
    }

    private func handleLogin() {
        guard !mastodonInstance.isEmpty else {
            errorMessage = "Please enter a Mastodon instance"
            return
        }

        isLoading = true
        errorMessage = nil

        authManager.authenticateWithMastodon(instance: mastodonInstance) { success, error in
            DispatchQueue.main.async {
                isLoading = false

                if success {
                    // Navigate back to main menu on success
                    appState.currentScreen = .mainMenu
                } else {
                    errorMessage = error ?? "Authentication failed. Please try again."
                }
            }
        }
    }

    private func handleWhmcsLogin() {
        guard !whmcsEmail.isEmpty, !whmcsPassword.isEmpty else {
            errorMessage = "Please enter your Client Portal email and password"
            return
        }

        isLoading = true
        errorMessage = nil

        authManager.authenticateWithWhmcs(
            email: whmcsEmail,
            password: whmcsPassword,
            twoFactorCode: whmcsTwoFactor.isEmpty ? nil : whmcsTwoFactor,
            mastodonHandle: whmcsMastodonHandle.isEmpty ? nil : whmcsMastodonHandle,
            remember: rememberWhmcs
        ) { success, error in
            DispatchQueue.main.async {
                isLoading = false

                if success {
                    appState.currentScreen = .mainMenu
                } else {
                    errorMessage = error ?? "Authentication failed. Please try again."
                }
            }
        }
    }

    private func handleWhmcsPortalLogin() {
        guard !whmcsEmail.isEmpty, !whmcsPassword.isEmpty else {
            errorMessage = "Please enter your Client Portal email and password"
            return
        }

        isLoading = true
        errorMessage = nil

        authManager.startWhmcsPortalLogin(
            email: whmcsEmail,
            password: whmcsPassword,
            twoFactorCode: whmcsTwoFactor.isEmpty ? nil : whmcsTwoFactor,
            remember: rememberWhmcs
        ) { success, error in
            DispatchQueue.main.async {
                isLoading = false
                if !success {
                    errorMessage = error ?? "Failed to open Client Portal"
                }
            }
        }
    }
}

// Preview disabled for SPM builds
// struct LoginView_Previews: PreviewProvider {
//     static var previews: some View {
//         LoginView()
//             .environmentObject(AppState())
//     }
// }
