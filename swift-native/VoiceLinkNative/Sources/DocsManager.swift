import Foundation

final class DocsManager {
    static let shared = DocsManager()

    private let webBase = "https://voicelink.dev"
    private let fm = FileManager.default
    private let syncQueue = DispatchQueue(label: "voicelink.docs.sync", qos: .utility)
    private var syncInFlight = false

    private init() {}

    var bundledDocsRoot: URL? {
        if let nestedBundleURL = Bundle.main.resourceURL?.appendingPathComponent("VoiceLinkNative_VoiceLinkNative.bundle"),
           let nestedBundle = Bundle(url: nestedBundleURL),
           let docsURL = nestedBundle.resourceURL?.appendingPathComponent("docs"),
           fm.fileExists(atPath: docsURL.path) {
            return docsURL
        }
        #if SWIFT_PACKAGE
        if let docsURL = Bundle.module.resourceURL?.appendingPathComponent("docs"),
           fm.fileExists(atPath: docsURL.path) {
            return docsURL
        }
        #endif
        return nil
    }

    var cachedDocsRoot: URL? {
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport.appendingPathComponent("VoiceLink/docs-cache", isDirectory: true)
    }

    func startBackgroundSync(baseURL: String? = nil) {
        syncQueue.async { [weak self] in
            self?.syncInBackground(baseURL: baseURL)
        }
    }

    func resolveLocalDoc(relativePath: String) -> URL? {
        let normalized = normalizedRelativePath(relativePath)

        if let cachedDocsRoot {
            let cached = cachedDocsRoot.appendingPathComponent(normalized)
            if fm.fileExists(atPath: cached.path) {
                return cached
            }
        }

        if let bundledDocsRoot {
            let bundled = bundledDocsRoot.appendingPathComponent(normalized)
            if fm.fileExists(atPath: bundled.path) {
                return bundled
            }
        }

        return nil
    }

    func webURL(for path: String) -> URL? {
        URL(string: webBase + normalizedWebPath(path))
    }

    private func syncInBackground(baseURL: String?) {
        guard !syncInFlight else { return }
        syncInFlight = true
        defer { syncInFlight = false }

        guard let cacheRoot = cachedDocsRoot else { return }
        try? fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        let baseCandidates = [baseURL, ServerManager.shared.baseURL, webBase]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for candidate in baseCandidates {
            guard let statusURL = URL(string: normalizedBase(candidate) + "/api/docs/list") else { continue }
            var request = URLRequest(url: statusURL)
            request.timeoutInterval = 10
            if let token = AuthenticationManager.shared.currentUser?.accessToken, !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            do {
                let (data, response) = try syncData(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { continue }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                let publicDocs = json["public"] as? [[String: Any]] ?? []
                let authDocs = json["authenticated"] as? [[String: Any]] ?? []

                sync(documents: publicDocs, pathPrefix: "/docs", targetRoot: cacheRoot, remoteBase: candidate)
                sync(documents: authDocs, pathPrefix: "/admin/docs", targetRoot: cacheRoot.appendingPathComponent("authenticated", isDirectory: true), remoteBase: candidate)
                return
            } catch {
                continue
            }
        }
    }

    private func sync(documents: [[String: Any]], pathPrefix: String, targetRoot: URL, remoteBase: String) {
        try? fm.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        for item in documents {
            guard let file = item["file"] as? String, !file.isEmpty else { continue }
            let destination = targetRoot.appendingPathComponent(file)
            guard let remoteURL = URL(string: normalizedBase(remoteBase) + normalizedWebPath("\(pathPrefix)/\(file)")) else { continue }
            var request = URLRequest(url: remoteURL)
            request.timeoutInterval = 12
            if let token = AuthenticationManager.shared.currentUser?.accessToken, !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            do {
                let (data, response) = try syncData(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else { continue }
                let parent = destination.deletingLastPathComponent()
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                try data.write(to: destination, options: Data.WritingOptions.atomic)
            } catch {
                continue
            }
        }
    }

    private func syncData(for request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var outputData: Data?
        var outputResponse: URLResponse?
        var outputError: Error?
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            outputData = data
            outputResponse = response
            outputError = error
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        if let error = outputError { throw error }
        guard let data = outputData, let response = outputResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }

    private func normalizedRelativePath(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func normalizedWebPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }

    private func normalizedBase(_ base: String) -> String {
        base.hasSuffix("/") ? String(base.dropLast()) : base
    }
}
