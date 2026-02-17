import Foundation
import SwiftUI

// MARK: - Auto Updater
// Handles automatic updates from server for macOS

class AutoUpdater: ObservableObject {
    static let shared = AutoUpdater()

    // Current app version/build from bundle metadata.
    static var currentVersion: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static var buildNumber: Int {
        let info = Bundle.main.infoDictionary
        if let value = info?["CFBundleVersion"] as? String, let parsed = Int(value) {
            return parsed
        }
        if let number = info?["CFBundleVersion"] as? NSNumber {
            return number.intValue
        }
        return 1
    }

    // Update server configuration
    private var downloadBaseURL: String {
        let current = APIEndpointResolver.normalize(ServerManager.shared.baseURL ?? APIEndpointResolver.canonicalMainBase)
        let withScheme = current.hasPrefix("http://") || current.hasPrefix("https://") ? current : "https://\(current)"
        if withScheme.hasSuffix("/downloads") {
            return withScheme
        }
        return "\(withScheme)/downloads"
    }
    private let platform = "macos"

    @Published var updateAvailable: Bool = false
    @Published var latestVersion: String?
    @Published var latestBuildNumber: Int?
    @Published var latestBuildHash: String?
    @Published var updateURL: URL?
    @Published var mirrorUpdateURLs: [URL] = []
    @Published var releaseNotes: String?
    @Published var minimumSupportedVersion: String?
    @Published var requiredReason: String?
    @Published var enforcedAfter: Date?
    @Published var compatibilityModeUntil: Date?
    @Published var updateRequired: Bool = false
    @Published var updatePolicyActive: Bool = false
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0
    @Published var lastChecked: Date?
    @Published var updateState: UpdateState = .idle

    enum UpdateState: Equatable {
        case idle
        case checking
        case available(version: String)
        case downloading
        case readyToInstall
        case error(String)
    }

    private var downloadTask: URLSessionDownloadTask?
    private var downloadFallbackQueue: [URL] = []
    private var currentDownloadSourceURL: URL?
    private var downloadedFileURL: URL?
    private let canonicalZipDownloadURL = "https://voicelink.devinecreations.net/downloads/voicelink/VoiceLink-macOS.zip"
    private let dismissedBuildHashKey = "dismissedUpdateBuildHash"
    private let dismissedBuildNumberKey = "dismissedUpdateBuildNumber"
    private let dismissedVersionKey = "dismissedUpdateVersion"

    init() {
        loadLastChecked()
        // Check for updates on launch (after a short delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.checkForUpdates()
        }
    }

    // MARK: - Version Info

    var versionString: String {
        "v\(AutoUpdater.currentVersion) (Build \(AutoUpdater.buildNumber))"
    }

    var shortVersionString: String {
        "v\(AutoUpdater.currentVersion)"
    }

    // MARK: - Update Check

    func checkForUpdates(silent: Bool = true) {
        guard updateState != .checking else { return }

        updateState = .checking

        Task {
            let ymlCandidates = APIEndpointResolver.apiBaseCandidates(preferred: ServerManager.shared.baseURL)
                .map { "\($0)/downloads/latest-mac.yml" }

            var selectedBaseForDownloadPath: String?
            var yamlString: String?
            var lastError: Error?

            for candidate in ymlCandidates {
                guard let url = URL(string: candidate) else { continue }
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                do {
                    let (data, _) = try await URLSession.shared.data(for: request)
                    if let yaml = String(data: data, encoding: .utf8) {
                        yamlString = yaml
                        selectedBaseForDownloadPath = candidate.replacingOccurrences(of: "/latest-mac.yml", with: "")
                        break
                    }
                } catch {
                    lastError = error
                }
            }

            let finalYamlString = yamlString
            let finalError = lastError
            let finalDownloadBase = selectedBaseForDownloadPath ?? self.downloadBaseURL

            await MainActor.run {
                self.lastChecked = Date()
                self.saveLastChecked()

                guard let yaml = finalYamlString else {
                    if !silent {
                        self.updateState = .error(finalError?.localizedDescription ?? "Failed to check for updates")
                    } else {
                        self.updateState = .idle
                    }
                    return
                }

                self.parseUpdateYAML(yaml, silent: silent, resolvedDownloadBaseURL: finalDownloadBase)
            }
        }
    }

    private func parseUpdateYAML(_ yaml: String, silent: Bool, resolvedDownloadBaseURL: String) {
        var version: String?
        var build: Int?
        var path: String?
        var mirrorPaths: [String] = []
        var notes: String?
        var minSupported: String?
        var requiredUpdate = false
        var requiredReasonText: String?
        var enforcedAfterDate: Date?
        var compatibilityUntilDate: Date?
        var inReleaseNotes = false
        var releaseNotesLines: [String] = []
        var serverHash: String?
        var collectingTopLevelSha = false
        var topLevelShaParts: [String] = []
        var inMirrorURLs = false

        for line in yaml.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if collectingTopLevelSha {
                // Some manifests wrap long sha512 values to the next indented line.
                if line.hasPrefix(" ") || line.hasPrefix("\t") {
                    if !trimmed.isEmpty {
                        topLevelShaParts.append(stripYAMLValue(trimmed))
                    }
                    continue
                }
                collectingTopLevelSha = false
            }

            if inMirrorURLs {
                if trimmed.hasPrefix("- ") {
                    let value = stripYAMLValue(String(trimmed.dropFirst(2)))
                    if !value.isEmpty {
                        mirrorPaths.append(value)
                    }
                    continue
                }
                if !(line.hasPrefix(" ") || line.hasPrefix("\t")) {
                    inMirrorURLs = false
                } else {
                    continue
                }
            }

            if inReleaseNotes {
                if trimmed.hasPrefix("- ") || trimmed.isEmpty {
                    releaseNotesLines.append(trimmed)
                    continue
                } else if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                    inReleaseNotes = false
                } else {
                    releaseNotesLines.append(trimmed)
                    continue
                }
            }

            if line.hasPrefix("version:") {
                version = stripYAMLValue(String(line.dropFirst("version:".count)))
            } else if line.hasPrefix("build:") {
                let parsed = stripYAMLValue(String(line.dropFirst("build:".count)))
                build = Int(parsed)
            } else if line.hasPrefix("path:") {
                path = stripYAMLValue(String(line.dropFirst("path:".count)))
            } else if line.hasPrefix("mirrorURL:") {
                let value = stripYAMLValue(String(line.dropFirst("mirrorURL:".count)))
                if !value.isEmpty { mirrorPaths.append(value) }
            } else if line.hasPrefix("mirrorURL2:") {
                let value = stripYAMLValue(String(line.dropFirst("mirrorURL2:".count)))
                if !value.isEmpty { mirrorPaths.append(value) }
            } else if line.hasPrefix("mirrorURL3:") {
                let value = stripYAMLValue(String(line.dropFirst("mirrorURL3:".count)))
                if !value.isEmpty { mirrorPaths.append(value) }
            } else if line.hasPrefix("copyPartyURL:") {
                let value = stripYAMLValue(String(line.dropFirst("copyPartyURL:".count)))
                if !value.isEmpty { mirrorPaths.append(value) }
            } else if trimmed.hasPrefix("mirrorURLs:") {
                inMirrorURLs = true
            } else if line.hasPrefix("minimumSupportedVersion:") {
                minSupported = stripYAMLValue(String(line.dropFirst("minimumSupportedVersion:".count)))
            } else if line.hasPrefix("required:") {
                requiredUpdate = parseYAMLBool(String(line.dropFirst("required:".count)))
            } else if line.hasPrefix("requiredReason:") {
                requiredReasonText = stripYAMLValue(String(line.dropFirst("requiredReason:".count)))
            } else if line.hasPrefix("enforcedAfter:") {
                enforcedAfterDate = parseYAMLDate(String(line.dropFirst("enforcedAfter:".count)))
            } else if line.hasPrefix("compatibilityModeUntil:") {
                compatibilityUntilDate = parseYAMLDate(String(line.dropFirst("compatibilityModeUntil:".count)))
            } else if line.hasPrefix("sha512:") {
                let firstPart = stripYAMLValue(String(line.dropFirst("sha512:".count)))
                topLevelShaParts = firstPart.isEmpty ? [] : [firstPart]
                collectingTopLevelSha = true
            } else if trimmed.hasPrefix("releaseNotes:") {
                inReleaseNotes = true
            }
        }

        if !topLevelShaParts.isEmpty {
            serverHash = topLevelShaParts.joined()
        }

        if !releaseNotesLines.isEmpty {
            notes = releaseNotesLines.joined(separator: "\n")
        }

        guard let serverVersion = version else {
            if !silent {
                updateState = .error("Could not parse update information")
            } else {
                updateState = .idle
            }
            return
        }

        // Compare by hash (allows updates even if version stays at 1.0)
        let installedHash = UserDefaults.standard.string(forKey: "installedBuildHash") ?? ""
        let hasNewBuild = serverHash != nil && serverHash != installedHash && !installedHash.isEmpty

        // Also check version for fresh installs
        let hasNewerBuild = build.map { $0 > AutoUpdater.buildNumber } ?? false
        let hasNewerVersion = isNewerVersion(serverVersion, than: AutoUpdater.currentVersion)
        let belowMinimumSupportedVersion = minSupported.map { compareVersions(AutoUpdater.currentVersion, $0) < 0 } ?? false
        let requiredByPolicy = requiredUpdate
        let policyRequiresUpdate = belowMinimumSupportedVersion || requiredByPolicy
        let enforcementIsActive = requiredByPolicy && (enforcedAfterDate == nil || (enforcedAfterDate ?? .distantFuture) <= Date())

        if hasNewBuild || hasNewerBuild || hasNewerVersion || policyRequiresUpdate {
            latestBuildNumber = build
            latestBuildHash = serverHash
            minimumSupportedVersion = minSupported
            requiredReason = requiredReasonText
            enforcedAfter = enforcedAfterDate
            compatibilityModeUntil = compatibilityUntilDate
            updatePolicyActive = policyRequiresUpdate
            updateRequired = enforcementIsActive || belowMinimumSupportedVersion

            let dismissedHash = UserDefaults.standard.string(forKey: dismissedBuildHashKey)
            let dismissedVersion = UserDefaults.standard.string(forKey: dismissedVersionKey)
            let dismissedBuildNumber = UserDefaults.standard.integer(forKey: dismissedBuildNumberKey)
            let hasDismissedBuildNumber = UserDefaults.standard.object(forKey: dismissedBuildNumberKey) != nil
            let dismissedCurrentBuild = (serverHash != nil && dismissedHash == serverHash)
            let dismissedCurrentBuildNumber = (build != nil && hasDismissedBuildNumber && dismissedBuildNumber == build)
            let dismissedCurrentVersion = (serverHash == nil && build == nil && dismissedVersion == serverVersion)
            if (dismissedCurrentBuild || dismissedCurrentBuildNumber || dismissedCurrentVersion), !updateRequired {
                updateAvailable = false
                updateState = .idle
                return
            }

            latestVersion = serverVersion
            releaseNotes = notes

            if let downloadPath = path {
                updateURL = buildDownloadURL(base: resolvedDownloadBaseURL, path: downloadPath)
            }
            mirrorUpdateURLs = resolvedMirrorURLs(base: resolvedDownloadBaseURL, mirrorPaths: mirrorPaths)

            updateAvailable = true
            updateState = .available(version: serverVersion)

            // Store server hash for comparison after install
            if let hash = serverHash {
                UserDefaults.standard.set(hash, forKey: "pendingBuildHash")
            }

            // Post notification
            NotificationCenter.default.post(name: .updateAvailable, object: serverVersion)

            // Auto-start download for forced update policies.
            if updateRequired, updateState == .available(version: serverVersion), !isDownloading {
                downloadUpdate()
            }
        } else {
            // If no installed hash, store current server hash (first run)
            if installedHash.isEmpty, let hash = serverHash {
                UserDefaults.standard.set(hash, forKey: "installedBuildHash")
            }
            latestBuildNumber = build
            latestBuildHash = serverHash
            minimumSupportedVersion = minSupported
            requiredReason = requiredReasonText
            enforcedAfter = enforcedAfterDate
            compatibilityModeUntil = compatibilityUntilDate
            updatePolicyActive = false
            updateRequired = false
            updateAvailable = false
            mirrorUpdateURLs = []
            updateState = .idle
        }
    }

    /// Call after successful update to mark new hash as installed
    func markUpdateInstalled() {
        if let pendingHash = UserDefaults.standard.string(forKey: "pendingBuildHash") {
            UserDefaults.standard.set(pendingHash, forKey: "installedBuildHash")
            UserDefaults.standard.removeObject(forKey: "pendingBuildHash")
        }
        UserDefaults.standard.removeObject(forKey: dismissedBuildHashKey)
        UserDefaults.standard.removeObject(forKey: dismissedBuildNumberKey)
        UserDefaults.standard.removeObject(forKey: dismissedVersionKey)
    }

    func dismissCurrentUpdate() {
        guard !updateRequired else { return }
        if let hash = latestBuildHash {
            UserDefaults.standard.set(hash, forKey: dismissedBuildHashKey)
            UserDefaults.standard.removeObject(forKey: dismissedBuildNumberKey)
            UserDefaults.standard.removeObject(forKey: dismissedVersionKey)
        } else if let build = latestBuildNumber {
            UserDefaults.standard.set(build, forKey: dismissedBuildNumberKey)
            UserDefaults.standard.removeObject(forKey: dismissedBuildHashKey)
            UserDefaults.standard.removeObject(forKey: dismissedVersionKey)
        } else if let version = latestVersion {
            UserDefaults.standard.set(version, forKey: dismissedVersionKey)
            UserDefaults.standard.removeObject(forKey: dismissedBuildHashKey)
            UserDefaults.standard.removeObject(forKey: dismissedBuildNumberKey)
        }
        updateAvailable = false
        updateState = .idle
    }

    private func isNewerVersion(_ new: String, than current: String) -> Bool {
        let newParts = new.components(separatedBy: ".").compactMap { Int($0) }
        let currentParts = current.components(separatedBy: ".").compactMap { Int($0) }

        for i in 0..<max(newParts.count, currentParts.count) {
            let newPart = i < newParts.count ? newParts[i] : 0
            let currentPart = i < currentParts.count ? currentParts[i] : 0

            if newPart > currentPart {
                return true
            } else if newPart < currentPart {
                return false
            }
        }
        return false
    }

    // MARK: - Download Update

    func downloadUpdate() {
        let candidates = downloadCandidates()
        guard let downloadURL = candidates.first else {
            openBrowserAndProtocolFallback()
            updateState = .error("No download URL available")
            return
        }

        downloadFallbackQueue = Array(candidates.dropFirst())
        updateURL = downloadURL

        isDownloading = true
        downloadProgress = 0
        updateState = .downloading
        startDownload(from: downloadURL)
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
        updateState = updateAvailable ? .available(version: latestVersion ?? "") : .idle
    }

    // MARK: - Install Update

    func installUpdate() {
        guard let fileURL = downloadedFileURL else {
            updateState = .error("Update file not found")
            return
        }

        // For ZIP files, unzip and open the app
        if fileURL.pathExtension == "zip" {
            unzipAndInstall(fileURL)
        } else {
            // For DMG/PKG, just open it
            NSWorkspace.shared.open(fileURL)
            NotificationCenter.default.post(name: .shouldQuitForUpdate, object: nil)
        }
    }

    private func unzipAndInstall(_ zipURL: URL) {
        let fileManager = FileManager.default
        let downloadsDir = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let extractDir = downloadsDir.appendingPathComponent("VoiceLink-Update-\(UUID().uuidString)")

        guard isLikelyZipFile(zipURL) else {
            updateState = .error("Downloaded update is not a valid ZIP file")
            return
        }

        // Clean up previous extraction
        try? fileManager.removeItem(at: extractDir)

        let extracted = extractZip(zipURL, to: extractDir)
        if extracted {
            if let appBundle = findAppBundle(in: extractDir) {
                NSWorkspace.shared.selectFile(appBundle.path, inFileViewerRootedAtPath: extractDir.path)
                DispatchQueue.main.async {
                    self.showInstallInstructions(appBundle)
                }
            } else {
                tryRedownloadAfterExtractionFailure("Could not find VoiceLink.app in downloaded archive")
            }
        } else {
            tryRedownloadAfterExtractionFailure("Failed to extract update")
        }
    }

    private func extractZip(_ zipURL: URL, to extractDir: URL) -> Bool {
        if runExtractCommand(executable: "/usr/bin/ditto", arguments: ["-xk", zipURL.path, extractDir.path]) {
            return true
        }
        return runExtractCommand(executable: "/usr/bin/unzip", arguments: ["-o", "-q", zipURL.path, "-d", extractDir.path])
    }

    private func runExtractCommand(executable: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func tryRedownloadAfterExtractionFailure(_ fallbackError: String) {
        if tryNextDownloadCandidate(lastError: nil) {
            downloadedFileURL = nil
            isDownloading = true
            downloadProgress = 0
            updateState = .downloading
            return
        }
        updateState = .error(fallbackError)
    }

    private func findAppBundle(in directory: URL) -> URL? {
        let fileManager = FileManager.default
        if let topLevel = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
           let directApp = topLevel.first(where: { $0.pathExtension == "app" }) {
            return directApp
        }
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in enumerator {
            if url.pathExtension == "app" {
                return url
            }
        }
        return nil
    }

    private func isLikelyZipFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let header = try? handle.read(upToCount: 4)
        return header == Data([0x50, 0x4B, 0x03, 0x04]) || header == Data([0x50, 0x4B, 0x05, 0x06])
    }

    private func parseYAMLBool(_ raw: String) -> Bool {
        let value = stripYAMLValue(raw).lowercased()
        return value == "true" || value == "1" || value == "yes"
    }

    private func parseYAMLDate(_ raw: String) -> Date? {
        let value = stripYAMLValue(raw)
        guard !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: value) {
            return parsed
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: value)
    }

    private func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.components(separatedBy: ".").compactMap { Int($0) }
        let right = rhs.components(separatedBy: ".").compactMap { Int($0) }
        let maxCount = max(left.count, right.count)
        for i in 0..<maxCount {
            let l = i < left.count ? left[i] : 0
            let r = i < right.count ? right[i] : 0
            if l < r { return -1 }
            if l > r { return 1 }
        }
        return 0
    }

    private func stripYAMLValue(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) || (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    private func buildDownloadURL(base: String, path: String) -> URL? {
        let cleanedPath = stripYAMLValue(path)
        if cleanedPath.hasPrefix("voicelink://"),
           let components = URLComponents(string: cleanedPath),
           let encodedTarget = components.queryItems?.first(where: { $0.name == "url" })?.value?.removingPercentEncoding,
           let targetURL = URL(string: encodedTarget),
           isHTTPDownloadURL(targetURL) {
            return targetURL
        }
        if cleanedPath.hasPrefix("http://") || cleanedPath.hasPrefix("https://") {
            return URL(string: cleanedPath)
        }

        let normalizedBase = APIEndpointResolver.normalize(base)
        let withScheme = normalizedBase.hasPrefix("http://") || normalizedBase.hasPrefix("https://")
            ? normalizedBase
            : "https://\(normalizedBase)"
        if let resolved = APIEndpointResolver.url(base: withScheme, path: cleanedPath) {
            return resolved
        }
        return APIEndpointResolver.url(base: downloadBaseURL, path: cleanedPath)
    }

    private func resolvedMirrorURLs(base: String, mirrorPaths: [String]) -> [URL] {
        var resolved: [URL] = []
        var seen = Set<String>()
        let primary = updateURL?.absoluteString ?? ""
        for raw in mirrorPaths {
            guard let url = buildDownloadURL(base: base, path: raw), isHTTPDownloadURL(url) else { continue }
            let key = url.absoluteString
            if key == primary || seen.contains(key) { continue }
            seen.insert(key)
            resolved.append(url)
        }
        return resolved
    }

    private func downloadCandidates() -> [URL] {
        var candidates: [URL] = []
        var seen = Set<String>()
        let potential = [updateURL] + mirrorUpdateURLs.map { Optional($0) } + [URL(string: canonicalZipDownloadURL)]
        for item in potential {
            guard let url = item, isHTTPDownloadURL(url) else { continue }
            let key = url.absoluteString
            if seen.contains(key) { continue }
            seen.insert(key)
            candidates.append(url)
        }
        return candidates
    }

    private func startDownload(from url: URL) {
        currentDownloadSourceURL = url
        let session = URLSession(configuration: .default, delegate: DownloadDelegate(updater: self), delegateQueue: nil)
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
    }

    private func tryNextDownloadCandidate(lastError: Error?) -> Bool {
        while !downloadFallbackQueue.isEmpty {
            let next = downloadFallbackQueue.removeFirst()
            guard isHTTPDownloadURL(next) else { continue }
            updateURL = next
            updateState = .downloading
            startDownload(from: next)
            return true
        }
        if let error = lastError, error.localizedDescription.localizedCaseInsensitiveContains("unsupported URL") {
            openBrowserAndProtocolFallback()
        }
        return false
    }

    private func isHTTPDownloadURL(_ url: URL?) -> Bool {
        guard let url = url else { return false }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        return url.host != nil
    }

    fileprivate static func resolvedHTTPDownloadURL(from url: URL?) -> URL? {
        guard let url else { return nil }
        if let scheme = url.scheme?.lowercased(), (scheme == "https" || scheme == "http") {
            return url.host == nil ? nil : url
        }
        if url.scheme?.lowercased() == "voicelink",
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let encodedTarget = components.queryItems?.first(where: { $0.name == "url" })?.value?.removingPercentEncoding,
           let targetURL = URL(string: encodedTarget),
           let targetScheme = targetURL.scheme?.lowercased(),
           (targetScheme == "https" || targetScheme == "http"),
           targetURL.host != nil {
            return targetURL
        }
        return nil
    }

    private func openBrowserAndProtocolFallback() {
        if let webURL = URL(string: canonicalZipDownloadURL) {
            NSWorkspace.shared.open(webURL)
            let encoded = canonicalZipDownloadURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? canonicalZipDownloadURL
            if let protocolFallback = URL(string: "voicelink://open?url=\(encoded)") {
                NSWorkspace.shared.open(protocolFallback)
            }
        }
    }

    private func showInstallInstructions(_ appURL: URL) {
        let alert = NSAlert()
        alert.messageText = "Update Downloaded"
        alert.informativeText = "The new version has been downloaded to your Downloads folder.\n\nTo complete the update:\n1. Quit VoiceLink\n2. Move the new VoiceLink.app to your Applications folder\n3. Open the new VoiceLink"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Downloads Folder")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.selectFile(appURL.path, inFileViewerRootedAtPath: appURL.deletingLastPathComponent().path)
        }
    }

    // MARK: - Persistence

    private func loadLastChecked() {
        if let timestamp = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date {
            lastChecked = timestamp
        }
    }

    private func saveLastChecked() {
        UserDefaults.standard.set(lastChecked, forKey: "lastUpdateCheck")
    }

    // MARK: - Download Delegate

    class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        weak var updater: AutoUpdater?

        init(updater: AutoUpdater) {
            self.updater = updater
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            if let resolved = AutoUpdater.resolvedHTTPDownloadURL(from: request.url) {
                completionHandler(URLRequest(url: resolved))
                return
            }
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let fileManager = FileManager.default
            let downloadsURL = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first!

            // Determine file extension from URL
            let originalURL = updater?.currentDownloadSourceURL ?? downloadTask.originalRequest?.url
            let ext = originalURL?.pathExtension.isEmpty == false ? (originalURL?.pathExtension ?? "zip") : "zip"
            let fileName = "VoiceLink-\(updater?.latestVersion ?? "update").\(ext)"
            let destinationURL = downloadsURL.appendingPathComponent(fileName)

            do {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }

                try fileManager.moveItem(at: location, to: destinationURL)

                DispatchQueue.main.async {
                    self.updater?.downloadedFileURL = destinationURL
                    self.updater?.isDownloading = false
                    self.updater?.downloadProgress = 1.0
                    self.updater?.updateState = .readyToInstall
                }
            } catch {
                DispatchQueue.main.async {
                    self.updater?.updateState = .error("Failed to save update: \(error.localizedDescription)")
                    self.updater?.isDownloading = false
                }
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            DispatchQueue.main.async {
                self.updater?.downloadProgress = progress
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error = error {
                DispatchQueue.main.async {
                    if self.updater?.tryNextDownloadCandidate(lastError: error) == true {
                        return
                    }
                    self.updater?.updateState = .error("Download failed: \(error.localizedDescription)")
                    self.updater?.isDownloading = false
                }
            }
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let shouldQuitForUpdate = Notification.Name("shouldQuitForUpdate")
    static let updateAvailable = Notification.Name("updateAvailable")
}

// MARK: - Update Settings View

struct UpdateSettingsView: View {
    @ObservedObject private var updater = AutoUpdater.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer()
                if !updater.updateRequired {
                    Button("Close") {
                        updater.dismissCurrentUpdate()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Dismisses the update prompt for this build")
                    .help("Dismisses the update prompt for this build")
                }
            }

            // Current Version
            HStack {
                Image(systemName: "app.badge")
                    .foregroundColor(.blue)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text("VoiceLink")
                        .font(.headline)
                    Text(updater.versionString)
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                Spacer()

                if updater.updateAvailable {
                    Text("Update Available")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)

            // Update State
            switch updater.updateState {
            case .idle:
                updateIdleView

            case .checking:
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Checking for updates...")
                        .foregroundColor(.gray)
                }
                .padding()

            case .available(let version):
                updateAvailableView(version: version)

            case .downloading:
                downloadingView

            case .readyToInstall:
                readyToInstallView

            case .error(let message):
                errorView(message: message)
            }

            // Last checked
            if let lastChecked = updater.lastChecked {
                HStack {
                    Image(systemName: "clock")
                        .foregroundColor(.gray)
                    Text("Last checked: \(lastChecked.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
        }
        .padding()
    }

    private var updateIdleView: some View {
        Button(action: {
            updater.checkForUpdates(silent: false)
        }) {
            HStack {
                Image(systemName: "arrow.clockwise")
                Text("Check for Updates")
            }
        }
        .buttonStyle(.borderedProminent)
    }

    private func updateAvailableView(version: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.green)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Version \(version) Available")
                        .fontWeight(.semibold)
                    Text("A new version of VoiceLink is ready to download")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            if updater.updatePolicyActive {
                VStack(alignment: .leading, spacing: 6) {
                    Text(updater.updateRequired ? "Required Update" : "Compatibility Update")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.red)
                    if let minVersion = updater.minimumSupportedVersion, !minVersion.isEmpty {
                        Text("Minimum supported version: \(minVersion)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let reason = updater.requiredReason, !reason.isEmpty {
                        Text(reason)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let enforcedAt = updater.enforcedAfter {
                        Text("Enforced after: \(enforcedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(10)
                .background(Color.red.opacity(0.08))
                .cornerRadius(8)
            }

            if let notes = updater.releaseNotes {
                Text("What's New:")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text(notes)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
            }

            HStack {
                Button(action: {
                    updater.downloadUpdate()
                }) {
                    HStack {
                        Image(systemName: "arrow.down.to.line")
                        Text("Download Update")
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Later") {
                    updater.dismissCurrentUpdate()
                    dismiss()
                }
                .buttonStyle(.bordered)
                .disabled(updater.updateRequired)
                .accessibilityHint("Dismisses this update prompt")
                .help("Dismisses this update prompt")
            }
        }
        .padding()
        .background(Color.green.opacity(0.1))
        .cornerRadius(12)
    }

    private var downloadingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Downloading Update...")
                    .fontWeight(.semibold)
                Spacer()
                Text("\(Int(updater.downloadProgress * 100))%")
                    .foregroundColor(.gray)
            }

            ProgressView(value: updater.downloadProgress)
                .progressViewStyle(.linear)

            Button("Cancel") {
                updater.cancelDownload()
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(12)
    }

    private var readyToInstallView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Update Downloaded")
                        .fontWeight(.semibold)
                    Text("Click Install to extract and view the new version.")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            Button(action: {
                updater.installUpdate()
            }) {
                HStack {
                    Image(systemName: "arrow.uturn.forward")
                    Text("Install Update")
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color.green.opacity(0.1))
        .cornerRadius(12)
    }

    private func errorView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Button(action: {
                updater.checkForUpdates(silent: false)
            }) {
                Text("Try Again")
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(12)
    }
}

// MARK: - Update Available Banner

struct UpdateAvailableBanner: View {
    @ObservedObject private var updater = AutoUpdater.shared
    @State private var showUpdateSheet = false

    var body: some View {
        if updater.updateAvailable {
            Button(action: {
                showUpdateSheet = true
            }) {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.white)
                    Text("Update Available: v\(updater.latestVersion ?? "")")
                        .foregroundColor(.white)
                        .font(.caption)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.green)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showUpdateSheet) {
                UpdateSettingsView()
                    .frame(minWidth: 400, minHeight: 300)
            }
        }
    }
}
