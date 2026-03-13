import Foundation
import UIKit

struct IOSCrashReportSummary: Codable {
    let fileName: String
    let modifiedAt: String
    let preview: String
}

struct IOSBugReport: Codable {
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
    let username: String?
    let clientId: String?
    let currentRoom: String?
    let diagnosticsSummary: String?
    let localMonitorDiagnostics: String?
    let recentCrashReports: [IOSCrashReportSummary]?
    let submittedAt: String?
}

@MainActor
final class IOSDiagnosticsManager: ObservableObject {
    static let shared = IOSDiagnosticsManager()

    private let lastSessionActiveKey = "voicelink.ios.lastSessionActive"
    private let lastSessionAtKey = "voicelink.ios.lastSessionAt"
    private let pendingCrashSummaryKey = "voicelink.ios.pendingCrashSummary"

    private init() {}

    func markSceneActive() {
        let defaults = UserDefaults.standard
        let previousActive = defaults.bool(forKey: lastSessionActiveKey)
        let isoNow = ISO8601DateFormatter().string(from: Date())
        if previousActive {
            defaults.set(
                "Previous iOS session appears to have ended unexpectedly before \(isoNow).",
                forKey: pendingCrashSummaryKey
            )
        }
        defaults.set(true, forKey: lastSessionActiveKey)
        defaults.set(isoNow, forKey: lastSessionAtKey)
    }

    func markSceneBackground() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: lastSessionActiveKey)
        defaults.set(ISO8601DateFormatter().string(from: Date()), forKey: lastSessionAtKey)
    }

    func currentCrashSummaries() -> [IOSCrashReportSummary] {
        let defaults = UserDefaults.standard
        guard let summary = defaults.string(forKey: pendingCrashSummaryKey), !summary.isEmpty else {
            return []
        }
        let stamp = defaults.string(forKey: lastSessionAtKey) ?? ISO8601DateFormatter().string(from: Date())
        return [
            IOSCrashReportSummary(
                fileName: "ios-session-state",
                modifiedAt: stamp,
                preview: summary
            )
        ]
    }

    func diagnosticsSummary(
        serverURL: String,
        currentRoom: String?,
        sessionStatus: String = "",
        displayName: String = ""
    ) -> String {
        let defaults = UserDefaults.standard
        let authToken = defaults.string(forKey: "voicelink.authToken") ?? ""
        let tokenState = authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Not signed in" : "Authenticated"
        let pendingCrash = defaults.string(forKey: pendingCrashSummaryKey) ?? "None"
        return [
            "VoiceLink iOS Diagnostics",
            "Display Name: \(displayName.isEmpty ? "Not set" : displayName)",
            "Server URL: \(normalizeDiagnosticsBaseURL(serverURL))",
            "Current Room: \(currentRoom?.isEmpty == false ? currentRoom! : "None")",
            "Auth State: \(tokenState)",
            "Audio Status: \(sessionStatus.isEmpty ? "Unknown" : sessionStatus)",
            "Pending Crash Summary: \(pendingCrash)"
        ].joined(separator: "\n")
    }

    func submitBugReport(
        serverURL: String,
        title: String,
        description: String,
        category: String,
        severity: String,
        anonymous: Bool,
        currentRoom: String?,
        sessionStatus: String,
        displayName: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        Task {
            do {
                let defaults = UserDefaults.standard
                let diagnosticsEnabled = defaults.object(forKey: "voicelink.autoSendDiagnostics") as? Bool ?? true
                let includeCrashReports = defaults.object(forKey: "voicelink.shareCrashReports") as? Bool ?? true
                let authToken = defaults.string(forKey: "voicelink.authToken") ?? ""
                let accountEmail = defaults.string(forKey: "voicelink.accountEmail")
                let username = defaults.string(forKey: "voicelink.username") ?? displayName
                let clientId = defaults.string(forKey: "clientId") ?? UIDevice.current.identifierForVendor?.uuidString

                let report = IOSBugReport(
                    title: title,
                    description: description,
                    category: category,
                    severity: severity,
                    anonymous: anonymous,
                    submittedBy: anonymous ? nil : displayName,
                    mastodonHandle: nil,
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
                    platform: "iOS",
                    accountEmail: anonymous ? nil : accountEmail,
                    username: anonymous ? nil : username,
                    clientId: clientId,
                    currentRoom: currentRoom,
                    diagnosticsSummary: diagnosticsEnabled ? diagnosticsSummary(serverURL: serverURL, currentRoom: currentRoom, sessionStatus: sessionStatus, displayName: displayName) : nil,
                    localMonitorDiagnostics: nil,
                    recentCrashReports: (diagnosticsEnabled && includeCrashReports) ? currentCrashSummaries() : nil,
                    submittedAt: ISO8601DateFormatter().string(from: Date())
                )

                let payload = try JSONEncoder().encode(report)
                guard let url = URL(string: "\(normalizeDiagnosticsBaseURL(serverURL))/api/bugs/submit") else {
                    throw URLError(.badURL)
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let trimmedToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedToken.isEmpty {
                    request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
                    request.setValue(trimmedToken, forHTTPHeaderField: "x-session-token")
                }
                request.httpBody = payload

                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }

                if includeCrashReports {
                    defaults.removeObject(forKey: pendingCrashSummaryKey)
                }

                await MainActor.run {
                    completion(.success(()))
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }
}

private func normalizeDiagnosticsBaseURL(_ rawURL: String) -> String {
    let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return "https://voicelink.devinecreations.net"
    }
    let withScheme: String
    if trimmed.contains("://") {
        withScheme = trimmed
    } else {
        withScheme = "https://\(trimmed)"
    }
    return withScheme.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
}
