import Foundation

@MainActor
final class SelfTestScheduler: ObservableObject {
    static let shared = SelfTestScheduler()

    enum CheckID: String, CaseIterable, Codable, Identifiable {
        case serverConnection = "serverConnection"
        case apiHealth = "apiHealth"
        case adminStatus = "adminStatus"
        case copyPartyAPI = "copyPartyAPI"
        case updaterMetadata = "updaterMetadata"
        case coreSounds = "coreSounds"
        case roomInventory = "roomInventory"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .serverConnection: return "Server Socket Connection"
            case .apiHealth: return "Server API Health"
            case .adminStatus: return "Admin Status Endpoint"
            case .copyPartyAPI: return "CopyParty API Reachability"
            case .updaterMetadata: return "Updater Metadata Endpoint"
            case .coreSounds: return "Core Sound Assets"
            case .roomInventory: return "Room Inventory"
            }
        }
    }

    enum ResultStatus: String, Codable {
        case pass = "pass"
        case warn = "warn"
        case fail = "fail"
    }

    struct CheckConfig: Identifiable, Codable {
        var id: CheckID
        var enabled: Bool
    }

    struct CheckResult: Identifiable, Codable {
        let id: UUID
        let check: CheckID
        let status: ResultStatus
        let message: String
        let durationMs: Int
        let ranAt: Date
    }

    struct RunRecord: Identifiable, Codable {
        let id: UUID
        let source: String
        let startedAt: Date
        let finishedAt: Date
        let results: [CheckResult]

        var passedCount: Int { results.filter { $0.status == .pass }.count }
        var warnedCount: Int { results.filter { $0.status == .warn }.count }
        var failedCount: Int { results.filter { $0.status == .fail }.count }
        var summary: String {
            "Pass \(passedCount) • Warn \(warnedCount) • Fail \(failedCount)"
        }
    }

    @Published var schedulerEnabled: Bool = true
    @Published var runOnLaunch: Bool = true
    @Published var intervalMinutes: Int = 15
    @Published var checks: [CheckConfig] = CheckID.allCases.map { CheckConfig(id: $0, enabled: true) }
    @Published var isRunning = false
    @Published var lastRunAt: Date?
    @Published var nextRunAt: Date?
    @Published var lastRunSummary: String = "No runs yet"
    @Published var runHistory: [RunRecord] = []
    @Published var lastError: String?

    private var timer: Timer?
    private let maxHistory = 30
    private let defaults = UserDefaults.standard

    private let enabledKey = "selfTestScheduler.enabled"
    private let runOnLaunchKey = "selfTestScheduler.runOnLaunch"
    private let intervalKey = "selfTestScheduler.intervalMinutes"
    private let checksKey = "selfTestScheduler.checks"
    private let historyKey = "selfTestScheduler.history"
    private let lastRunAtKey = "selfTestScheduler.lastRunAt"
    private let lastRunSummaryKey = "selfTestScheduler.lastRunSummary"

    private init() {
        loadSettings()
        if schedulerEnabled {
            scheduleTimer()
        }
        if runOnLaunch {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.runNow(source: "startup")
            }
        }
    }

    func setSchedulerEnabled(_ enabled: Bool) {
        schedulerEnabled = enabled
        saveSettings()
        if enabled {
            scheduleTimer()
        } else {
            invalidateTimer()
            nextRunAt = nil
        }
    }

    func setRunOnLaunch(_ enabled: Bool) {
        runOnLaunch = enabled
        saveSettings()
    }

    func setIntervalMinutes(_ minutes: Int) {
        intervalMinutes = min(max(minutes, 1), 1440)
        saveSettings()
        if schedulerEnabled {
            scheduleTimer()
        }
    }

    func setCheckEnabled(_ id: CheckID, enabled: Bool) {
        if let index = checks.firstIndex(where: { $0.id == id }) {
            checks[index].enabled = enabled
            saveSettings()
        }
    }

    func clearHistory() {
        runHistory = []
        lastRunSummary = "No runs yet"
        lastRunAt = nil
        saveSettings()
    }

    func runNow(source: String = "manual") async {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil

        let started = Date()
        var results: [CheckResult] = []
        for check in checks where check.enabled {
            let result = await runCheck(check.id)
            results.append(result)
        }
        let finished = Date()
        let run = RunRecord(
            id: UUID(),
            source: source,
            startedAt: started,
            finishedAt: finished,
            results: results
        )

        runHistory.insert(run, at: 0)
        if runHistory.count > maxHistory {
            runHistory = Array(runHistory.prefix(maxHistory))
        }
        lastRunAt = finished
        lastRunSummary = run.summary
        isRunning = false
        saveSettings()

        if schedulerEnabled {
            scheduleTimer()
        }
    }

    private func runCheck(_ id: CheckID) async -> CheckResult {
        let started = Date()
        let (status, message) = await evaluateCheck(id)
        let elapsed = max(1, Int(Date().timeIntervalSince(started) * 1000))
        return CheckResult(
            id: UUID(),
            check: id,
            status: status,
            message: message,
            durationMs: elapsed,
            ranAt: Date()
        )
    }

    private func evaluateCheck(_ id: CheckID) async -> (ResultStatus, String) {
        switch id {
        case .serverConnection:
            let isConnected = ServerManager.shared.isConnected
            return isConnected
                ? (.pass, "Socket connected to \(ServerManager.shared.baseURL ?? "server").")
                : (.fail, "Socket is disconnected.")

        case .apiHealth:
            let base = APIEndpointResolver.normalize(ServerManager.shared.baseURL ?? ServerManager.mainServer)
            guard let url = APIEndpointResolver.url(base: base, path: "/api/health") else {
                return (.fail, "Unable to build /api/health URL.")
            }
            return await performHTTPCheck(url: url, successRange: 200...499, okMessage: "API health reachable")

        case .adminStatus:
            guard let token = AuthenticationManager.shared.currentUser?.accessToken, !token.isEmpty else {
                return (.warn, "No auth token. Sign in to validate admin endpoint.")
            }
            let base = APIEndpointResolver.normalize(ServerManager.shared.baseURL ?? ServerManager.mainServer)
            guard let url = APIEndpointResolver.url(base: base, path: "/api/admin/status") else {
                return (.fail, "Unable to build /api/admin/status URL.")
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    return (.fail, "Admin status returned invalid response.")
                }
                if http.statusCode == 200 {
                    return (.pass, "Admin status endpoint reachable.")
                }
                if http.statusCode == 401 || http.statusCode == 403 {
                    return (.warn, "Admin status denied (\(http.statusCode)).")
                }
                return (.fail, "Admin status failed (\(http.statusCode)).")
            } catch {
                return (.fail, "Admin status error: \(error.localizedDescription)")
            }

        case .copyPartyAPI:
            let base = APIEndpointResolver.normalize(CopyPartyManager.shared.config.primaryServer)
            guard let url = URL(string: "\(base)/?j") else {
                return (.fail, "Invalid CopyParty URL.")
            }
            return await performHTTPCheck(url: url, successRange: 200...499, okMessage: "CopyParty API reachable")

        case .updaterMetadata:
            for candidate in APIEndpointResolver.mainBaseCandidates(preferred: ServerManager.shared.baseURL) {
                guard let url = APIEndpointResolver.url(base: candidate, path: "/downloads/latest-mac.yml") else { continue }
                let result = await performHTTPCheck(url: url, successRange: 200...299, okMessage: "Updater metadata reachable")
                if result.0 == .pass {
                    return (.pass, "Updater metadata reachable at \(candidate).")
                }
            }
            return (.fail, "Updater metadata check failed for all known endpoints.")

        case .coreSounds:
            let required = [
                "sounds/ui-sounds/button-click.wav",
                "sounds/ui-sounds/notification.wav",
                "sounds/ui-sounds/user-join.wav",
                "sounds/ui-sounds/user-leave.wav"
            ]
            let root = Bundle.main.resourceURL
            let missing = required.filter { rel in
                guard let root else { return true }
                let path = root.appendingPathComponent(rel).path
                return !FileManager.default.fileExists(atPath: path)
            }
            if missing.isEmpty {
                return (.pass, "Core sound files present.")
            }
            return (.warn, "Missing bundled sounds: \(missing.joined(separator: ", ")).")

        case .roomInventory:
            let connected = ServerManager.shared.isConnected
            let roomCount = ServerManager.shared.rooms.count
            if !connected {
                return (.warn, "Room inventory skipped while disconnected.")
            }
            return roomCount > 0
                ? (.pass, "Room inventory loaded (\(roomCount) rooms).")
                : (.warn, "Connected but no rooms were returned.")
        }
    }

    private func performHTTPCheck(url: URL, successRange: ClosedRange<Int>, okMessage: String) async -> (ResultStatus, String) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (.fail, "Invalid HTTP response from \(url.absoluteString).")
            }
            if successRange.contains(http.statusCode) {
                return (.pass, "\(okMessage) (\(http.statusCode)).")
            }
            return (.fail, "HTTP \(http.statusCode) from \(url.absoluteString).")
        } catch {
            return (.fail, "Request failed for \(url.absoluteString): \(error.localizedDescription)")
        }
    }

    private func scheduleTimer() {
        invalidateTimer()
        guard schedulerEnabled else { return }
        let interval = TimeInterval(intervalMinutes * 60)
        nextRunAt = Date().addingTimeInterval(interval)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.runNow(source: "scheduled")
            }
        }
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func loadSettings() {
        if defaults.object(forKey: enabledKey) != nil {
            schedulerEnabled = defaults.bool(forKey: enabledKey)
        }
        if defaults.object(forKey: runOnLaunchKey) != nil {
            runOnLaunch = defaults.bool(forKey: runOnLaunchKey)
        }
        if defaults.object(forKey: intervalKey) != nil {
            let value = defaults.integer(forKey: intervalKey)
            intervalMinutes = min(max(value, 1), 1440)
        }

        if let data = defaults.data(forKey: checksKey),
           let decoded = try? JSONDecoder().decode([CheckConfig].self, from: data),
           !decoded.isEmpty {
            checks = CheckID.allCases.map { id in
                decoded.first(where: { $0.id == id }) ?? CheckConfig(id: id, enabled: true)
            }
        }

        if let data = defaults.data(forKey: historyKey),
           let decoded = try? JSONDecoder().decode([RunRecord].self, from: data) {
            runHistory = decoded
        }

        if let date = defaults.object(forKey: lastRunAtKey) as? Date {
            lastRunAt = date
        }
        if let summary = defaults.string(forKey: lastRunSummaryKey), !summary.isEmpty {
            lastRunSummary = summary
        }
    }

    private func saveSettings() {
        defaults.set(schedulerEnabled, forKey: enabledKey)
        defaults.set(runOnLaunch, forKey: runOnLaunchKey)
        defaults.set(intervalMinutes, forKey: intervalKey)
        defaults.set(lastRunAt, forKey: lastRunAtKey)
        defaults.set(lastRunSummary, forKey: lastRunSummaryKey)

        if let checksData = try? JSONEncoder().encode(checks) {
            defaults.set(checksData, forKey: checksKey)
        }
        if let historyData = try? JSONEncoder().encode(Array(runHistory.prefix(maxHistory))) {
            defaults.set(historyData, forKey: historyKey)
        }
    }
}
