import Foundation
import UIKit

@MainActor
final class IOSDiagnosticsManager {
    static let shared = IOSDiagnosticsManager()

    private init() {}

    func submitBugReport(
        serverURL: String,
        title: String,
        description: String,
        category: String,
        severity: String,
        anonymous: Bool,
        currentRoom: String?,
        sessionStatus: String?,
        displayName: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedDescription.isEmpty else {
            completion(.failure(NSError(domain: "VoiceLinkiOS", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Diagnostics title and description are required."
            ])))
            return
        }

        Task {
            do {
                let payload = try makePayload(
                    title: trimmedTitle,
                    description: trimmedDescription,
                    category: category,
                    severity: severity,
                    anonymous: anonymous,
                    currentRoom: currentRoom,
                    sessionStatus: sessionStatus,
                    displayName: displayName
                )
                try await submitPayload(payload, serverURL: serverURL)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func makePayload(
        title: String,
        description: String,
        category: String,
        severity: String,
        anonymous: Bool,
        currentRoom: String?,
        sessionStatus: String?,
        displayName: String
    ) throws -> Data {
        let info = Bundle.main.infoDictionary ?? [:]
        let appVersion = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildNumber = info["CFBundleVersion"] as? String ?? "unknown"
        let device = UIDevice.current

        let diagnosticsSummary = [
            "device=\(device.model)",
            "system=\(device.systemName) \(device.systemVersion)",
            "appVersion=\(appVersion)",
            "build=\(buildNumber)",
            "room=\((currentRoom ?? "").isEmpty ? "none" : currentRoom!)",
            "status=\((sessionStatus ?? "").isEmpty ? "none" : sessionStatus!)"
        ].joined(separator: " | ")

        let payload: [String: Any] = [
            "title": title,
            "description": description,
            "category": category,
            "severity": severity,
            "anonymous": anonymous,
            "submittedBy": anonymous ? NSNull() : (displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? UIDevice.current.name : displayName),
            "displayName": anonymous ? NSNull() : displayName,
            "appVersion": appVersion,
            "platform": "\(device.systemName) \(device.systemVersion)",
            "currentRoom": currentRoom ?? NSNull(),
            "diagnosticsSummary": diagnosticsSummary,
            "submittedAt": ISO8601DateFormatter().string(from: Date()),
            "recentCrashReports": []
        ]

        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func submitPayload(_ payload: Data, serverURL: String) async throws {
        let bases = candidateBases(from: serverURL)
        var lastError: Error = NSError(domain: "VoiceLinkiOS", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "Failed to submit bug report."
        ])

        for base in bases {
            guard let url = URL(string: "\(base)/api/bugs/submit") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    continue
                }
                if (200...299).contains(http.statusCode) {
                    return
                }
                lastError = NSError(domain: "VoiceLinkiOS", code: http.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "Server returned status \(http.statusCode)."
                ])
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    private func candidateBases(from raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            ? trimmed
            : "https://\(trimmed)"
        let cleaned = normalized.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)

        var candidates = [cleaned]
        if cleaned != "https://voicelink.devinecreations.net" {
            candidates.append("https://voicelink.devinecreations.net")
        }
        return Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
    }
}
