import Foundation
import SwiftUI

// MARK: - Auto Updater
// Handles automatic updates from server for macOS

class AutoUpdater: ObservableObject {
    static let shared = AutoUpdater()

    // Current app version/build from bundle metadata
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
    static var buildNumber: Int {
        let raw = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return Int(raw) ?? 1
    }

    // Update server configuration
    private var downloadBaseURL: String {
        let current = ServerManager.shared.baseURL ?? APIEndpointResolver.canonicalMainBase
        return "\(current)/downloads"
    }
    private let platform = "macos"

    @Published var updateAvailable: Bool = false
    @Published var latestVersion: String?
    @Published var updateURL: URL?
    @Published var releaseNotes: String?
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
    private var downloadedFileURL: URL?

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
        var path: String?
        var notes: String?
        var inReleaseNotes = false
        var releaseNotesLines: [String] = []

        for line in yaml.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

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

            if trimmed.hasPrefix("version:") {
                version = trimmed.replacingOccurrences(of: "version:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("path:") {
                path = trimmed.replacingOccurrences(of: "path:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("releaseNotes:") {
                inReleaseNotes = true
            }
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

        // Parse sha512 hash from YAML
        var serverHash: String?
        for line in yaml.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("sha512:") && !trimmed.contains("files:") {
                serverHash = trimmed.replacingOccurrences(of: "sha512:", with: "").trimmingCharacters(in: .whitespaces)
                break
            }
        }

        // Compare by hash (allows updates even if version stays at 1.0)
        let installedHash = UserDefaults.standard.string(forKey: "installedBuildHash") ?? ""
        let hasNewBuild = serverHash != nil && serverHash != installedHash && !installedHash.isEmpty

        // Also check version for fresh installs
        let hasNewerVersion = isNewerVersion(serverVersion, than: AutoUpdater.currentVersion)

        if hasNewBuild || hasNewerVersion {
            latestVersion = serverVersion
            releaseNotes = notes

            if let downloadPath = path {
                updateURL = URL(string: "\(resolvedDownloadBaseURL)/\(downloadPath)")
            }

            updateAvailable = true
            updateState = .available(version: serverVersion)

            // Store server hash for comparison after install
            if let hash = serverHash {
                UserDefaults.standard.set(hash, forKey: "pendingBuildHash")
            }

            // Post notification
            NotificationCenter.default.post(name: .updateAvailable, object: serverVersion)
        } else {
            // If no installed hash, store current server hash (first run)
            if installedHash.isEmpty, let hash = serverHash {
                UserDefaults.standard.set(hash, forKey: "installedBuildHash")
            }
            updateAvailable = false
            updateState = .idle
        }
    }

    /// Call after successful update to mark new hash as installed
    func markUpdateInstalled() {
        if let pendingHash = UserDefaults.standard.string(forKey: "pendingBuildHash") {
            UserDefaults.standard.set(pendingHash, forKey: "installedBuildHash")
            UserDefaults.standard.removeObject(forKey: "pendingBuildHash")
        }
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
        guard let downloadURL = updateURL else {
            updateState = .error("No download URL available")
            return
        }

        isDownloading = true
        downloadProgress = 0
        updateState = .downloading

        let session = URLSession(configuration: .default, delegate: DownloadDelegate(updater: self), delegateQueue: nil)
        downloadTask = session.downloadTask(with: downloadURL)
        downloadTask?.resume()
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
        let extractDir = downloadsDir.appendingPathComponent("VoiceLink-Update")

        // Clean up previous extraction
        try? fileManager.removeItem(at: extractDir)

        // Unzip using ditto (preserves permissions and code signing)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", zipURL.path, extractDir.path]

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                // Find the .app bundle
                let contents = try fileManager.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
                if let appBundle = contents.first(where: { $0.pathExtension == "app" }) {
                    // Open Finder to show the new app
                    NSWorkspace.shared.selectFile(appBundle.path, inFileViewerRootedAtPath: extractDir.path)

                    // Show instructions
                    DispatchQueue.main.async {
                        self.showInstallInstructions(appBundle)
                    }
                } else {
                    updateState = .error("Could not find app in downloaded archive")
                }
            } else {
                updateState = .error("Failed to extract update")
            }
        } catch {
            updateState = .error("Failed to extract update: \(error.localizedDescription)")
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

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let fileManager = FileManager.default
            let downloadsURL = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first!

            // Determine file extension from URL
            let originalURL = downloadTask.originalRequest?.url
            let ext = originalURL?.pathExtension ?? "zip"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
                    updater.updateState = .idle
                }
                .buttonStyle(.bordered)
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
