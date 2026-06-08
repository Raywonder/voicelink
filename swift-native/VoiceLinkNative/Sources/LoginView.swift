import SwiftUI
import AppKit

struct LoginView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var authManager = AuthenticationManager.shared
    @State private var activeMethod: LoginMethod?

    private enum LoginMethod: String, Identifiable {
        case account
        case email
        case mastodon
        case discord
        case adminInvite

        var id: String { rawValue }
    }

    private var serverURL: String {
        let configured = (ServerManager.shared.baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return configured
        }
        return ServerManager.mainServer
    }

    private var clientPortalSignUpURL: URL? {
        URL(string: "https://devine-creations.com/register.php")
    }

    private var clientPortalURL: URL? {
        URL(string: "https://devine-creations.com/clientarea.php")
    }

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 58))
                    .foregroundColor(.blue)

                Text("Sign in to VoiceLink")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Use a Client Account, email code, Google, Apple, GitHub, Mastodon, Discord, or an admin invite.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 10)

            VStack(spacing: 12) {
                loginOptionButton(
                    title: "Client Account",
                    subtitle: "Username or email and password",
                    icon: "person.badge.key.fill"
                ) {
                    activeMethod = .account
                }

                loginOptionButton(
                    title: "Email Code",
                    subtitle: "Get a one-time sign-in code",
                    icon: "envelope.badge"
                ) {
                    activeMethod = .email
                }

                loginOptionButton(
                    title: "Mastodon",
                    subtitle: "Use your Mastodon account",
                    icon: "person.2.circle"
                ) {
                    activeMethod = .mastodon
                }

                loginOptionButton(
                    title: "Discord",
                    subtitle: "Use your Discord account",
                    icon: "bubble.left.and.bubble.right.fill"
                ) {
                    activeMethod = .discord
                }

                loginOptionButton(
                    title: "Admin Invite",
                    subtitle: "Activate a server invite token",
                    icon: "person.badge.shield.checkmark"
                ) {
                    activeMethod = .adminInvite
                }

                HStack(spacing: 10) {
                    oauthButton("Google", url: "https://voicelinkapp.app/auth/google")
                    oauthButton("Apple", url: "https://voicelinkapp.app/auth/apple")
                    oauthButton("GitHub", url: "https://voicelinkapp.app/auth/github")
                    oauthButton("Discord", url: "https://voicelinkapp.app/auth/discord")
                }

                VStack(spacing: 6) {
                    Text("Need to link billing, installs, and server ownership too?")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 10) {
                        Button("Create Client Account") {
                            guard let url = clientPortalSignUpURL else { return }
                            NSWorkspace.shared.open(url)
                        }
                        .buttonStyle(.bordered)

                        Button("Open Client Account Portal") {
                            guard let url = clientPortalURL else { return }
                            NSWorkspace.shared.open(url)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: 520)

            if let currentUser = authManager.currentUser {
                Text("Signed in as \(currentUser.displayName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if let error = authManager.authError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            Spacer()

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
        .frame(maxWidth: 620)
        .padding(28)
        .onAppear {
            if authManager.authState == .authenticated {
                appState.currentScreen = .mainMenu
            }
        }
        .sheet(item: $activeMethod) { method in
            switch method {
            case .account:
                AccountPasswordAuthView(
                    isPresented: sheetBinding(for: .account),
                    serverURL: serverURL,
                    initialProvider: .local
                ) {
                    appState.currentScreen = .mainMenu
                }
            case .email:
                EmailAuthView(
                    isPresented: sheetBinding(for: .email),
                    serverURL: serverURL
                ) {
                    appState.currentScreen = .mainMenu
                }
            case .mastodon:
                MastodonAuthView(
                    isPresented: sheetBinding(for: .mastodon)
                ) {
                    appState.currentScreen = .mainMenu
                }
            case .discord:
                OAuthLoginHelpView(
                    isPresented: sheetBinding(for: .discord),
                    title: "Discord Login",
                    subtitle: "Continue with Discord in your browser. VoiceLink will return here after authorization.",
                    actions: [
                        OAuthAction(label: "Open Discord Login", url: "https://voicelinkapp.app/auth/discord")
                    ]
                )
            case .adminInvite:
                AdminInviteAuthView(
                    isPresented: sheetBinding(for: .adminInvite)
                ) {
                    appState.currentScreen = .mainMenu
                }
            }
        }
    }

    private func loginOptionButton(title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(.blue)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.caption.weight(.semibold))
            }
            .padding(14)
            .background(Color.white.opacity(0.08))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    private func sheetBinding(for method: LoginMethod) -> Binding<Bool> {
        Binding(
            get: { activeMethod == method },
            set: { newValue in
                if !newValue, activeMethod == method {
                    activeMethod = nil
                }
            }
        )
    }

    private func oauthButton(_ title: String, url: String) -> some View {
        Button(title) {
            guard let target = URL(string: url) else { return }
            NSWorkspace.shared.open(target)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

private struct OAuthAction: Identifiable {
    let id = UUID()
    let label: String
    let url: String
}

private struct OAuthLoginHelpView: View {
    @Binding var isPresented: Bool
    let title: String
    let subtitle: String
    let actions: [OAuthAction]

    var body: some View {
        VStack(spacing: 18) {
            Text(title)
                .font(.title2.bold())
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            ForEach(actions) { action in
                Button(action.label) {
                    guard let target = URL(string: action.url) else { return }
                    NSWorkspace.shared.open(target)
                }
                .buttonStyle(.borderedProminent)
            }

            Button("Close") {
                isPresented = false
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(minWidth: 360)
    }
}
