import Foundation
import SwiftUI

// MARK: - Announcement Model
struct Announcement: Codable, Identifiable {
    let id: String
    let title: String
    let type: String
    let date: String
    let version: String?
    let content: String
    let features: [String]?
    let bugTrackerUrl: String?
    let active: Bool?
}

struct BugTracker: Codable {
    let url: String
    let newIssueUrl: String
    let labelsUrl: String
}

struct AnnouncementsResponse: Codable {
    let announcements: [Announcement]
    let bugTracker: BugTracker?
}

struct BugReport: Codable {
    let title: String
    let description: String
    let category: String
    let severity: String
    let anonymous: Bool
    let submittedBy: String?
    let mastodonHandle: String?
    let appVersion: String
    let platform: String
    let accountEmail: String?
    let displayName: String?
    let username: String?
    let clientId: String?
    let currentRoom: String?
    let diagnosticsSummary: String?
    let localMonitorDiagnostics: String?
    let recentCrashReports: [CrashReportSummary]?
    let submittedAt: String?
}

struct CrashReportSummary: Codable {
    let fileName: String
    let modifiedAt: String
    let preview: String
}

// MARK: - Announcements Manager
class AnnouncementsManager: ObservableObject {
    static let shared = AnnouncementsManager()

    @Published var announcements: [Announcement] = []
    @Published var bugTracker: BugTracker?
    @Published var isLoading = false
    @Published var error: String?
    @Published var hasUnreadAnnouncements = false

    private let lastReadDateKey = "lastReadAnnouncementDate"
    private var serverURL: String {
        ServerManager.shared.baseURL ?? APIEndpointResolver.canonicalMainBase
    }

    private init() {
        loadAnnouncements()
    }

    // MARK: - Load Announcements
    func loadAnnouncements() {
        isLoading = true
        error = nil

        Task {
            do {
                let response = try await fetchAnnouncementsWithFallback()
                await MainActor.run {
                    self.announcements = response.announcements
                    self.bugTracker = response.bugTracker
                    self.checkForUnread()
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    // MARK: - Check for Unread
    private func checkForUnread() {
        guard let lastRead = UserDefaults().string(forKey: lastReadDateKey),
              let lastReadDate = ISO8601DateFormatter().date(from: lastRead) else {
            hasUnreadAnnouncements = !announcements.isEmpty
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        hasUnreadAnnouncements = announcements.contains { ann in
            if let date = formatter.date(from: ann.date) {
                return date > lastReadDate
            }
            return false
        }
    }

    // MARK: - Mark as Read
    func markAsRead() {
        UserDefaults().set(ISO8601DateFormatter().string(from: Date()), forKey: lastReadDateKey)
        hasUnreadAnnouncements = false
    }

    // MARK: - Submit Bug Report
    func submitBugReport(_ report: BugReport, completion: @escaping (Result<Void, Error>) -> Void) {
        Task {
            do {
                let encoder = JSONEncoder()
                let payload = try encoder.encode(report)

                for base in APIEndpointResolver.apiBaseCandidates(preferred: serverURL) {
                    guard let url = APIEndpointResolver.url(base: base, path: "/api/bugs/submit") else { continue }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = payload

                    do {
                        let (_, response) = try await URLSession.shared.data(for: request)
                        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                            await MainActor.run { completion(.success(())) }
                            return
                        }
                    } catch {
                        continue
                    }
                }

                await MainActor.run {
                    completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to submit bug report"])))
                }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Open Announcements in Browser
    func openAnnouncementsInBrowser() {
        if let url = URL(string: "\(serverURL)/announcements.html") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Open Bug Tracker
    func openBugTracker() {
        if let urlString = bugTracker?.url, let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "\(serverURL)/bugtracker/") {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
extension AnnouncementsManager {
    static func diagnosticsSummaryText(appState: AppState, settings: SettingsManager = .shared) -> String {
        let authManager = AuthenticationManager.shared
        let user = authManager.currentUser
        let license = LicensingManager.shared
        let roleText = user.map { effectiveRoleSummaryStatic(for: $0) } ?? "visitor"
        let nickname = settings.userNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let monitorDetails = LocalMonitorManager.shared.diagnosticsSnapshot().multilineSummary
        return [
            "VoiceLink Diagnostics",
            "Nickname: \(nickname.isEmpty ? "Not set" : nickname)",
            "Account: \(user?.email ?? user?.username ?? "Not signed in")",
            "Role: \(roleText)",
            "License Key: \(license.licenseKey ?? "Not assigned")",
            "License Status: \(license.licenseStatus.rawValue)",
            "Current Device: \(license.currentDeviceName)",
            "Platform: \(license.currentDevicePlatform)",
            "Server URL: \(appState.serverManager.baseURL ?? "Not connected")",
            "Server Status: \(appState.serverStatus == .online ? "Connected" : appState.serverStatus == .connecting ? "Connecting" : "Offline")",
            "Audio Status: \(appState.serverManager.audioTransmissionStatus)",
            "Rooms Loaded: \(appState.rooms.count)",
            "Current Room: \((appState.currentRoom ?? appState.minimizedRoom)?.name ?? "None")",
            monitorDetails
        ].joined(separator: "\n")
    }

    static func collectRecentCrashReports(limit: Int = 3) -> [CrashReportSummary] {
        let reportsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: reportsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let matching = files
            .filter { $0.lastPathComponent.hasPrefix("VoiceLink") && $0.pathExtension == "ips" }
            .sorted {
                let lhsDate = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
            .prefix(limit)

        let formatter = ISO8601DateFormatter()
        return matching.compactMap { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let preview = (try? String(contentsOf: url, encoding: .utf8)
                .replacingOccurrences(of: "\u{0}", with: ""))
                .map { String($0.prefix(2000)) }
                ?? ""
            return CrashReportSummary(
                fileName: url.lastPathComponent,
                modifiedAt: formatter.string(from: date),
                preview: preview
            )
        }
    }
}

private extension AnnouncementsManager {
    static func effectiveRoleSummaryStatic(for user: AuthenticatedUser) -> String {
        let role = user.role?.isEmpty == false ? user.role! : "member"
        let permissionSummary = user.permissions.isEmpty ? "standard" : user.permissions.joined(separator: ", ")
        return "\(role) | \(permissionSummary)"
    }
}

private extension AnnouncementsManager {
    func fetchAnnouncementsWithFallback() async throws -> AnnouncementsResponse {
        var lastError: Error = URLError(.cannotFindHost)

        for base in APIEndpointResolver.apiBaseCandidates(preferred: serverURL) {
            guard let url = APIEndpointResolver.url(base: base, path: "/api/announcements") else { continue }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    continue
                }
                return try JSONDecoder().decode(AnnouncementsResponse.self, from: data)
            } catch {
                lastError = error
            }
        }

        throw lastError
    }
}

// MARK: - Announcements View
struct AnnouncementsView: View {
    @StateObject private var manager = AnnouncementsManager.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if manager.isLoading {
                    ProgressView("Loading announcements...")
                        .padding()
                } else if let error = manager.error {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text("Error loading announcements")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("Retry") {
                            manager.loadAnnouncements()
                        }
                    }
                    .padding()
                } else if manager.announcements.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "bell.slash")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No announcements")
                            .font(.headline)
                    }
                    .padding()
                } else {
                    List(manager.announcements) { announcement in
                        AnnouncementCard(announcement: announcement)
                    }
                }
            }
            .navigationTitle("Announcements")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { manager.loadAnnouncements() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            manager.markAsRead()
        }
    }
}

struct AnnouncementCard: View {
    let announcement: Announcement

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(announcement.title)
                    .font(.headline)
                Spacer()
                Text(announcement.type.capitalized)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(typeColor.opacity(0.2))
                    .foregroundColor(typeColor)
                    .cornerRadius(8)
            }

            HStack {
                if let version = announcement.version {
                    Text("v\(version)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(announcement.date)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(announcement.content)
                .font(.body)
                .foregroundColor(.secondary)

            if let features = announcement.features, !features.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Features & Changes")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.accentColor)

                    ForEach(features.prefix(5), id: \.self) { feature in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .foregroundColor(.green)
                            Text(feature)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    if features.count > 5 {
                        Text("... and \(features.count - 5) more")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(12)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
            }
        }
        .padding()
    }

    private var typeColor: Color {
        switch announcement.type.lowercased() {
        case "release": return .green
        case "update": return .blue
        case "fix": return .orange
        case "security": return .red
        default: return .purple
        }
    }
}

// MARK: - Bug Report View
struct BugReportView: View {
    @StateObject private var manager = AnnouncementsManager.shared
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    @State private var title = ""
    @State private var description = ""
    @State private var category = "general"
    @State private var severity = "normal"
    @State private var mastodonHandle = ""
    @State private var isAnonymous = false
    @State private var isSubmitting = false
    @State private var showSuccess = false
    @State private var errorMessage: String?

    let categories = ["general", "audio", "rooms", "authentication", "ui", "performance", "connectivity", "other"]
    let severities = ["low", "normal", "high", "critical"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Bug Details") {
                    TextField("Title", text: $title)
                    TextEditor(text: $description)
                        .frame(minHeight: 100)

                    Picker("Category", selection: $category) {
                        ForEach(categories, id: \.self) { cat in
                            Text(cat.capitalized).tag(cat)
                        }
                    }

                    Picker("Severity", selection: $severity) {
                        Text("Low - Minor inconvenience").tag("low")
                        Text("Normal - Affects usability").tag("normal")
                        Text("High - Major functionality broken").tag("high")
                        Text("Critical - App unusable").tag("critical")
                    }
                }

                Section("Contact (Optional)") {
                    TextField("Mastodon Handle", text: $mastodonHandle)
                        .textContentType(.username)

                    Toggle("Submit anonymously", isOn: $isAnonymous)
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Report a Bug")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Submit") {
                        submitReport()
                    }
                    .disabled(title.isEmpty || description.isEmpty || isSubmitting)
                }
            }
            .alert("Bug Report Submitted", isPresented: $showSuccess) {
                Button("OK") { dismiss() }
            } message: {
                Text("Thank you for helping improve VoiceLink!")
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private func submitReport() {
        isSubmitting = true
        errorMessage = nil
        let settings = SettingsManager.shared
        let authManager = AuthenticationManager.shared
        let user = authManager.currentUser
        let diagnosticsSummary = settings.autoSendDiagnostics
            ? AnnouncementsManager.diagnosticsSummaryText(appState: appState, settings: settings)
            : nil
        let monitorDiagnostics = settings.autoSendDiagnostics
            ? LocalMonitorManager.shared.diagnosticsSnapshot().multilineSummary
            : nil
        let crashReports = (settings.autoSendDiagnostics && settings.shareCrashReports)
            ? AnnouncementsManager.collectRecentCrashReports()
            : nil

        let report = BugReport(
            title: title,
            description: description,
            category: category,
            severity: severity,
            anonymous: isAnonymous,
            submittedBy: isAnonymous ? nil : NSFullUserName(),
            mastodonHandle: isAnonymous ? nil : mastodonHandle,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            platform: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            accountEmail: isAnonymous ? nil : user?.email,
            displayName: isAnonymous ? nil : (user?.displayName ?? user?.username),
            username: isAnonymous ? nil : user?.username,
            clientId: isAnonymous ? nil : UserDefaults().string(forKey: "clientId"),
            currentRoom: (appState.currentRoom ?? appState.minimizedRoom)?.name,
            diagnosticsSummary: diagnosticsSummary,
            localMonitorDiagnostics: monitorDiagnostics,
            recentCrashReports: crashReports,
            submittedAt: ISO8601DateFormatter().string(from: Date())
        )

        manager.submitBugReport(report) { result in
            isSubmitting = false
            switch result {
            case .success:
                showSuccess = true
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }
}
