import Foundation
import UIKit

private enum IOSDiagnosticsSubmissionLogger {
    private static let storageKey = "voicelink.iosDiagnosticsSubmissionLog"
    private static let maxEntries = 80

    static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(timestamp) [iOS] \(message)"
        NSLog("%@", entry)
        var entries = UserDefaults.standard.stringArray(forKey: storageKey) ?? []
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        UserDefaults.standard.set(entries, forKey: storageKey)
    }
}

private enum IOSDiagnosticsSubmissionMessage {
    static func starting(title: String, category: String, severity: String) -> String {
        "Sending diagnostics report \"\(title)\" in \(category) with \(severity) priority."
    }

    static func attemptingPrimaryRoute() -> String {
        "Trying the server diagnostics route."
    }

    static func routeStatus(_ statusCode: Int?) -> String {
        guard let statusCode else {
            return "The server replied, but the response could not be read clearly."
        }
        switch statusCode {
        case 200 ... 299:
            return "The server accepted the diagnostics report."
        case 401, 403:
            return "The server refused the diagnostics report because this account is not allowed to send it."
        case 404:
            return "The diagnostics route is not available on this server."
        case 500 ... 599:
            return "The server hit an internal error while processing the diagnostics report."
        default:
            return "The server replied with status \(statusCode) while processing the diagnostics report."
        }
    }

    static func attemptingSupportLogs() -> String {
        "Sending the attached support logs."
    }

    static func supportLogStatus(_ statusCode: Int?) -> String {
        guard let statusCode else {
            return "The support logs were sent, but the response could not be read clearly."
        }
        switch statusCode {
        case 200 ... 299:
            return "The support logs were delivered successfully."
        case 401, 403:
            return "The server would not accept the support logs from this account."
        case 404:
            return "The support-log route is not available on this server."
        case 500 ... 599:
            return "The server hit an internal error while processing the support logs."
        default:
            return "The server replied with status \(statusCode) while processing the support logs."
        }
    }

    static func failed(_ error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            return "The diagnostics report could not be delivered."
        }
        if message.lowercased().contains("timed out") {
            return "The diagnostics report timed out before the server replied."
        }
        return "The diagnostics report could not be delivered: \(message)"
    }
}

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
                IOSDiagnosticsSubmissionLogger.log(IOSDiagnosticsSubmissionMessage.starting(title: trimmedTitle, category: category, severity: severity))
                try await submitPayload(payload, serverURL: serverURL)
                IOSDiagnosticsSubmissionLogger.log("bug report submission succeeded")
                completion(.success(()))
            } catch {
                IOSDiagnosticsSubmissionLogger.log(IOSDiagnosticsSubmissionMessage.failed(error))
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
        let supportLogsPayload = makeSupportLogsPayload(from: payload)
        let bases = candidateBases(from: serverURL)
        var lastError: Error = NSError(domain: "VoiceLinkiOS", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "Failed to submit bug report."
        ])

        for base in bases {
            guard let url = URL(string: "\(base)/api/bugs/submit") else { continue }
            IOSDiagnosticsSubmissionLogger.log(IOSDiagnosticsSubmissionMessage.attemptingPrimaryRoute())
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    IOSDiagnosticsSubmissionLogger.log(IOSDiagnosticsSubmissionMessage.routeStatus(nil))
                    continue
                }
                IOSDiagnosticsSubmissionLogger.log(IOSDiagnosticsSubmissionMessage.routeStatus(http.statusCode))
                if (200...299).contains(http.statusCode) {
                    if let supportLogsPayload {
                        try? await submitSupportLogs(supportLogsPayload, base: base)
                    }
                    return
                }
                lastError = NSError(domain: "VoiceLinkiOS", code: http.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "Server returned status \(http.statusCode)."
                ])
            } catch {
                IOSDiagnosticsSubmissionLogger.log(IOSDiagnosticsSubmissionMessage.failed(error))
                lastError = error
            }
        }

        throw lastError
    }

    private func makeSupportLogsPayload(from bugPayload: Data) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: bugPayload) as? [String: Any] else {
            return nil
        }

        let displayName = String(json["displayName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let room = json["currentRoom"] as? String
        let summary = json["diagnosticsSummary"] as? String ?? ""
        let defaults = UserDefaults.standard
        let device = UIDevice.current
        let notificationPref = defaults.bool(forKey: "voicelink.notifications.enabled")
        let inputGain = defaults.object(forKey: "voicelink.audio.inputGain") as? Double ?? 1.0
        let outputGain = defaults.object(forKey: "voicelink.audio.outputGain") as? Double ?? 1.0
        let mediaMuted = defaults.bool(forKey: "voicelink.audio.mediaMuted")
        let authToken = defaults.string(forKey: "voicelink.authToken") ?? ""
        let serverURL = defaults.string(forKey: "voicelink.serverURL") ?? "https://voicelink.devinecreations.net"
        let clientId = defaults.string(forKey: "voicelink.clientId") ?? device.identifierForVendor?.uuidString ?? device.name

        let sections: [String: Any] = [
            "device": [
                "name": device.name,
                "model": device.model,
                "systemName": device.systemName,
                "systemVersion": device.systemVersion
            ],
            "audio": [
                "inputGain": inputGain,
                "outputGain": outputGain,
                "mediaMuted": mediaMuted
            ],
            "session": [
                "room": room ?? "none",
                "status": summary
            ],
            "notifications": [
                "enabled": notificationPref
            ],
            "auth": [
                "signedIn": !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ],
            "server": [
                "baseURL": serverURL
            ]
        ]

        let logs = [
            "section=device name=\(device.name) model=\(device.model) system=\(device.systemName) \(device.systemVersion)",
            String(format: "section=audio inputGain=%.2f outputGain=%.2f mediaMuted=%@", inputGain, outputGain, mediaMuted ? "true" : "false"),
            "section=session room=\(room ?? "none") summary=\(summary.isEmpty ? "none" : summary)",
            "section=notifications enabled=\(notificationPref ? "true" : "false")",
            "section=auth signedIn=\(!authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "true" : "false")",
            "section=server baseURL=\(serverURL)"
        ]

        let payload: [String: Any] = [
            "reason": "ios-settings-diagnostics",
            "clientId": clientId,
            "appVersion": "\(json["appVersion"] as? String ?? "unknown") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"))",
            "platform": "iOS \(device.systemVersion)",
            "room": room ?? NSNull(),
            "user": displayName.isEmpty ? device.name : displayName,
            "displayName": displayName.isEmpty ? device.name : displayName,
            "diagnosticsSummary": summary,
            "sections": sections,
            "logs": logs
        ]

        return try? JSONSerialization.data(withJSONObject: payload)
    }

    private func submitSupportLogs(_ payload: Data, base: String) async throws {
        guard let url = URL(string: "\(base)/api/support/logs") else { return }
        IOSDiagnosticsSubmissionLogger.log(IOSDiagnosticsSubmissionMessage.attemptingSupportLogs())
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                IOSDiagnosticsSubmissionLogger.log(IOSDiagnosticsSubmissionMessage.supportLogStatus(http.statusCode))
            } else {
                IOSDiagnosticsSubmissionLogger.log(IOSDiagnosticsSubmissionMessage.supportLogStatus(nil))
            }
        } catch {
            IOSDiagnosticsSubmissionLogger.log(IOSDiagnosticsSubmissionMessage.failed(error))
            throw error
        }
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
