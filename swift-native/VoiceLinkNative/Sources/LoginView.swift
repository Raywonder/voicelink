import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var authManager = AuthenticationManager.shared
    @State private var mastodonInstance: String = ""
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

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

                Text("Connect with your Mastodon account")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 30)

            // Login Form
            VStack(spacing: 16) {
                // Mastodon Instance Input
                VStack(alignment: .leading, spacing: 8) {
                    Text("Mastodon Instance")
                        .font(.headline)
                        .foregroundColor(.white)

                    TextField("mastodon.social", text: $mastodonInstance)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .disabled(isLoading)

                    Text("Enter your Mastodon instance domain (e.g., mastodon.social)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Login Button
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
}

#Preview {
    LoginView()
        .environmentObject(AppState())
}
