import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var authManager = AuthenticationManager.shared
    @State private var mastodonInstance: String = ""
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var selectedMethod: SignInMethod = .account
    @State private var showAccountAuthSheet = false
    @State private var showEmailAuthSheet = false
    @State private var showAdminInviteSheet = false

    private enum SignInMethod: String, CaseIterable, Identifiable {
        case account
        case emailCode
        case mastodon
        case adminInvite

        var id: String { rawValue }

        var label: String {
            switch self {
            case .account: return "Sign In"
            case .emailCode: return "Email Code"
            case .mastodon: return "Mastodon"
            case .adminInvite: return "Admin Invite"
            }
        }

        var helpText: String {
            switch self {
            case .account:
                return "Use your VoiceLink account credentials. The app resolves supported linked account types automatically in the background."
            case .emailCode:
                return "Request a sign-in code by email. Codes stay valid for 15 minutes."
            case .mastodon:
                return "Sign in with your Mastodon account on the instance you enter below."
            case .adminInvite:
                return "Use an admin invite link or token that was sent to you."
            }
        }
    }

    private var effectiveAuthServerURL: String {
        if let pending = authManager.pendingAdminInviteServerURL?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !pending.isEmpty {
            return pending
        }
        if let base = appState.serverManager.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !base.isEmpty {
            return base
        }
        return ServerManager.mainServer
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

                Text("Choose a sign-in method for this server")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 30)

            // Login Form
            VStack(spacing: 16) {
                Picker("Sign-in Method", selection: $selectedMethod) {
                    ForEach(SignInMethod.allCases) { method in
                        Text(method.label).tag(method)
                    }
                }
                .pickerStyle(.menu)

                Text(selectedMethod.helpText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(selectedMethod.label) {
                    continueWithSelectedMethod()
                }
                .buttonStyle(.borderedProminent)

                if selectedMethod == .mastodon {
                    VStack(alignment: .leading, spacing: 8) {
                    Text("Mastodon Instance")
                        .font(.headline)
                        .foregroundColor(.white)

                    TextField("md.tappedin.fm", text: $mastodonInstance)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .disabled(isLoading)

                    Text("Use this only when signing in with Mastodon.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
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
        .sheet(isPresented: $showEmailAuthSheet) {
            EmailAuthView(isPresented: $showEmailAuthSheet, serverURL: effectiveAuthServerURL) {
                appState.currentScreen = .mainMenu
            }
        }
        .sheet(isPresented: $showAccountAuthSheet) {
            AccountPasswordAuthView(
                isPresented: $showAccountAuthSheet,
                serverURL: effectiveAuthServerURL
            ) {
                appState.currentScreen = .mainMenu
            }
        }
        .sheet(isPresented: $showAdminInviteSheet) {
            AdminInviteAuthView(isPresented: $showAdminInviteSheet) {
                appState.currentScreen = .mainMenu
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

    private func continueWithSelectedMethod() {
        errorMessage = nil
        switch selectedMethod {
        case .account:
            showAccountAuthSheet = true
        case .emailCode:
            showEmailAuthSheet = true
        case .mastodon:
            handleLogin()
        case .adminInvite:
            showAdminInviteSheet = true
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
