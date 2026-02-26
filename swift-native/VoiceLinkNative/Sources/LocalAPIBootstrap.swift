import Foundation

final class LocalAPIBootstrap {
    static let shared = LocalAPIBootstrap()

    private let queue = DispatchQueue(label: "voicelink.local-api-bootstrap")
    private var launchProcess: Process?
    private var isBootstrapping = false

    private init() {}

    func ensureRunningIfNeeded() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isBootstrapping else { return }
            self.isBootstrapping = true
            defer { self.isBootstrapping = false }

            if self.probeLocalAPI() {
                return
            }

            guard self.startLocalAPIProcess() else {
                print("[LocalAPIBootstrap] No local API launcher found.")
                return
            }

            if self.waitUntilHealthy(timeout: 20) {
                print("[LocalAPIBootstrap] Local API is healthy.")
            } else {
                print("[LocalAPIBootstrap] Local API did not become healthy in time.")
            }
        }
    }

    private func probeLocalAPI() -> Bool {
        for path in ["/api/health", "/health"] {
            guard let url = URL(string: "http://127.0.0.1:3010\(path)") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 1.5
            request.httpMethod = "GET"

            let sema = DispatchSemaphore(value: 0)
            var healthy = false

            URLSession.shared.dataTask(with: request) { _, response, _ in
                if let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) {
                    healthy = true
                }
                sema.signal()
            }.resume()

            _ = sema.wait(timeout: .now() + 2)
            if healthy {
                return true
            }
        }
        return false
    }

    private func waitUntilHealthy(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if probeLocalAPI() {
                return true
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    private func startLocalAPIProcess() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if let command = env["VOICELINK_LOCAL_API_COMMAND"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty {
            return launchShell(command: command)
        }

        guard let launch = resolveNodeLaunch() else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", launch.scriptPath]
        process.currentDirectoryURL = URL(fileURLWithPath: launch.rootPath)
        process.environment = env

        do {
            try process.run()
            launchProcess = process
            print("[LocalAPIBootstrap] Started local API with node at \(launch.scriptPath)")
            return true
        } catch {
            print("[LocalAPIBootstrap] Failed to start local API: \(error.localizedDescription)")
            return false
        }
    }

    private func launchShell(command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
            launchProcess = process
            print("[LocalAPIBootstrap] Started local API with custom command.")
            return true
        } catch {
            print("[LocalAPIBootstrap] Custom local API launch failed: \(error.localizedDescription)")
            return false
        }
    }

    private func resolveNodeLaunch() -> (rootPath: String, scriptPath: String)? {
        let fileManager = FileManager.default

        for root in candidateRoots() {
            let rootURL = URL(fileURLWithPath: root)
            let scriptURL = rootURL.appendingPathComponent("server/routes/local-server.js")
            if fileManager.fileExists(atPath: scriptURL.path) {
                return (rootURL.path, scriptURL.path)
            }
        }

        return nil
    }

    private func candidateRoots() -> [String] {
        var roots: [String] = []
        let env = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default

        if let explicitRoot = env["VOICELINK_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitRoot.isEmpty {
            roots.append(explicitRoot)
        }

        roots.append(fileManager.currentDirectoryPath)

        var bundleURL = Bundle.main.bundleURL
        for _ in 0..<8 {
            roots.append(bundleURL.path)
            bundleURL.deleteLastPathComponent()
        }

        if let home = fileManager.homeDirectoryForCurrentUser.path.removingPercentEncoding {
            roots.append("\(home)/DEV/APPS/.worktrees/voicelink-main")
            roots.append("\(home)/DEV/APPS/voicelink-main")
            roots.append("\(home)/DEV/APPS/voicelink-local")
        }

        var deduped: [String] = []
        for root in roots {
            if !deduped.contains(root) {
                deduped.append(root)
            }
        }
        return deduped
    }
}
