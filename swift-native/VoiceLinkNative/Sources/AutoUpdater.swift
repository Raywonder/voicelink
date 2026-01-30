import Foundation
import SwiftUI

// MARK: - Auto Updater
// Handles automatic updates from server for macOS

class AutoUpdater: ObservableObject {
    static let shared = AutoUpdater()

    // Current app version
    static let currentVersion = "1.0.0"
    static let buildNumber = 1

    // Update server configuration
    private let updateServerURL = "https://voicelink.devinecreations.net/api/updates"
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

        guard let url = URL(string: "\(updateServerURL)/check") else {
            if !silent {
                updateState = .error("Invalid update server URL")
            } else {
                updateState = .idle
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "platform": platform,
            "currentVersion": AutoUpdater.currentVersion,
            "buildNumber": AutoUpdater.buildNumber,
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.lastChecked = Date()
                self?.saveLastChecked()

                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    if !silent {
                        self?.updateState = .error(error?.localizedDescription ?? "Failed to check for updates")
                    } else {
                        self?.updateState = .idle
                    }
                    return
                }

                if let hasUpdate = json["updateAvailable"] as? Bool, hasUpdate {
                    let newVersion = json["version"] as? String ?? "Unknown"
                    self?.latestVersion = newVersion
                    self?.releaseNotes = json["releaseNotes"] as? String
                    if let downloadURL = json["downloadURL"] as? String {
                        self?.updateURL = URL(string: downloadURL)
                    }
                    self?.updateAvailable = true
                    self?.updateState = .available(version: newVersion)
                } else {
                    self?.updateAvailable = false
                    self?.updateState = .idle
                }
            }
        }.resume()
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

        // For macOS, we typically:
        // 1. Verify the downloaded DMG/PKG
        // 2. Open it for the user to install
        // 3. Quit the app so the installer can run

        NSWorkspace.shared.open(fileURL)

        // Post notification that app should quit
        NotificationCenter.default.post(name: .shouldQuitForUpdate, object: nil)
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
            // Move downloaded file to a permanent location
            let fileManager = FileManager.default
            let downloadsURL = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            let fileName = "VoiceLinkNative-\(updater?.latestVersion ?? "update").dmg"
            let destinationURL = downloadsURL.appendingPathComponent(fileName)

            do {
                // Remove existing file if present
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

                // Update status badge
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
            .background(Color.white.opacity(0.05))
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
                    .background(Color.black.opacity(0.2))
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
                    Text("Ready to install. The app will close to complete installation.")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            Button(action: {
                updater.installUpdate()
            }) {
                HStack {
                    Image(systemName: "arrow.uturn.forward")
                    Text("Install and Restart")
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
