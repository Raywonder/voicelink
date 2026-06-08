import Foundation
import SwiftUI
import AppKit
import os

#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class AutoUpdater: NSObject, ObservableObject {
    static let shared = AutoUpdater()

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    static var buildNumber: Int {
        let raw = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return Int(raw) ?? 1
    }

    enum UpdateState: Equatable {
        case idle
        case checking
        case available(version: String)
        case downloading
        case readyToInstall
        case error(String)
    }

    private let logger = Logger(subsystem: "com.devinecreations.voicelink", category: "SparkleUpdater")
    private let autoCheckKey = "voicelink.sparkle.automaticChecks"
    private let automaticDownloadKey = "voicelink.sparkle.automaticDownloads"
    private let manualDownloadURL = URL(string: "https://voicelinkapp.app/downloads/voicelink/VoiceLinkMacOS.zip")

    @Published var updateAvailable = false
    @Published var latestVersion: String?
    @Published var latestBuildNumber: Int?
    @Published var updateURL: URL?
    @Published var releaseNotes: String?
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var lastChecked: Date?
    @Published var updateState: UpdateState = .idle
    @Published var installationWarning: String?
    @Published private(set) var installMode: InstallMode = .applications

    #if canImport(Sparkle)
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    #endif

    override init() {
        super.init()
        loadLastChecked()
        refreshInstallMode()

        #if canImport(Sparkle)
        configureSparkle()
        #else
        updateState = .error("Sparkle is not linked in this build.")
        logger.error("Sparkle unavailable at compile time")
        #endif
    }

    var versionString: String {
        "v\(Self.currentVersion) (Build \(Self.buildNumber))"
    }

    var shortVersionString: String {
        "v\(Self.currentVersion)"
    }

    var automaticChecksEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: autoCheckKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoCheckKey)
            #if canImport(Sparkle)
            updaterController.updater.automaticallyChecksForUpdates = newValue && installMode.supportsAutomaticReplacement
            updaterController.updater.resetUpdateCycleAfterShortDelay()
            #endif
        }
    }

    var automaticDownloadsEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: automaticDownloadKey) as? Bool ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: automaticDownloadKey)
            #if canImport(Sparkle)
            updaterController.updater.automaticallyDownloadsUpdates = newValue && installMode.supportsAutomaticReplacement
            updaterController.updater.resetUpdateCycleAfterShortDelay()
            #endif
        }
    }

    func checkForUpdates(silent: Bool = false) {
        lastChecked = Date()
        saveLastChecked()
        refreshInstallMode()

        #if canImport(Sparkle)
        guard installMode.supportsSparkleChecks else {
            let message = installationWarning ?? "Move VoiceLink to Applications before updating."
            logger.error("Blocked Sparkle update check: \(message, privacy: .public)")
            updateState = .error(message)
            if !silent {
                showMoveToApplicationsAlert(message: message)
            }
            return
        }

        logger.info("Starting Sparkle update check. silent=\(silent, privacy: .public)")
        updateState = .checking
        if silent {
            updaterController.updater.checkForUpdatesInBackground()
        } else {
            updaterController.checkForUpdates(nil)
        }
        #else
        let message = "Sparkle is not linked in this build."
        updateState = .error(message)
        logger.error("\(message, privacy: .public)")
        #endif
    }

    func downloadUpdate(saveForLater: Bool = false) {
        logger.info("Manual download requested; delegating download and install flow to Sparkle")
        checkForUpdates(silent: false)
    }

    func openManualDownload() {
        guard let manualDownloadURL else {
            updateState = .error("The manual download URL is not configured.")
            return
        }
        logger.info("Opening manual update download \(manualDownloadURL.absoluteString, privacy: .public)")
        NSWorkspace.shared.open(manualDownloadURL)
    }

    func cancelDownload() {
        logger.info("Cancel requested; Sparkle standard UI owns active download cancellation")
        updateState = .idle
        isDownloading = false
        downloadProgress = 0
    }

    func installUpdate() {
        logger.info("Install requested; Sparkle owns rollback-safe install and relaunch")
        checkForUpdates(silent: false)
    }

    func markUpdateInstalled() {
        logger.info("Sparkle update install completion acknowledged")
    }

    private func loadLastChecked() {
        if let timestamp = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date {
            lastChecked = timestamp
        }
    }

    private func saveLastChecked() {
        UserDefaults.standard.set(lastChecked, forKey: "lastUpdateCheck")
    }

    #if canImport(Sparkle)
    private func configureSparkle() {
        guard sparklePublicKeyConfigured else {
            let message = "Sparkle public key is not configured for this build."
            logger.error("\(message, privacy: .public)")
            updateState = .error(message)
            return
        }

        let updater = updaterController.updater
        updater.automaticallyChecksForUpdates = automaticChecksEnabled && installMode.supportsAutomaticReplacement
        updater.automaticallyDownloadsUpdates = automaticDownloadsEnabled && installMode.supportsAutomaticReplacement
        updater.updateCheckInterval = 60 * 60 * 6
        updaterController.startUpdater()
        logger.info("Sparkle updater started")
        if automaticChecksEnabled, installMode.supportsAutomaticReplacement {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.checkForUpdates(silent: true)
            }
        }
    }
    #endif

    private var sparklePublicKeyConfigured: Bool {
        let value = Bundle.main.infoDictionary?["SUPublicEDKey"] as? String ?? ""
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func refreshInstallMode() {
        installMode = currentInstallMode()
        installationWarning = installMode.notice
    }

    private func currentInstallMode() -> InstallMode {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let path = bundleURL.path
        guard bundleURL.pathExtension == "app" else {
            return .unsupported("VoiceLink is not running from an app bundle. Install VoiceLink in Applications before enabling updates.")
        }
        if path == "/Applications/VoiceLink.app" {
            return .applications
        }
        if let resourceValues = try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]),
           resourceValues.volumeIsReadOnly == true {
            return .diskImage
        }
        let parent = bundleURL.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: parent.path) {
            return .portable
        }
        return .unsupported("VoiceLink is running from a folder that is not writable. Copy it to Applications before enabling updates.")
    }

    private func showMoveToApplicationsAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Move VoiceLink to Applications"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func copyToApplications() {
        let source = Bundle.main.bundleURL
        let destination = URL(fileURLWithPath: "/Applications/VoiceLink.app")
        let fm = FileManager.default
        logger.info("Copy to Applications requested from \(source.path, privacy: .public)")

        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: source, to: destination)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.appendingPathComponent("Contents/MacOS/VoiceLink").path)
            NSWorkspace.shared.open(destination)
            NSApp.terminate(nil)
        } catch {
            logger.error("Copy to Applications failed: \(error.localizedDescription, privacy: .public)")
            updateState = .error("Could not copy VoiceLink to Applications: \(error.localizedDescription)")
        }
    }
}

enum InstallMode: Equatable {
    case applications
    case portable
    case diskImage
    case unsupported(String)

    var supportsAutomaticReplacement: Bool {
        self == .applications
    }

    var supportsSparkleChecks: Bool {
        self == .applications
    }

    var notice: String? {
        switch self {
        case .applications:
            return nil
        case .portable:
            return "Portable mode: settings are saved in your normal macOS user folders, but automatic self-replacement is disabled outside Applications."
        case .diskImage:
            return "You are running from a disk image. Settings will be saved, but automatic updates require copying the app to Applications or another writable folder."
        case .unsupported(let message):
            return message
        }
    }
}

#if canImport(Sparkle)
extension AutoUpdater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        refreshInstallMode()
        if !installMode.supportsSparkleChecks, let warning = installationWarning {
            logger.error("Sparkle denied update check \(String(describing: updateCheck), privacy: .public): \(warning, privacy: .public)")
            throw NSError(
                domain: "com.devinecreations.voicelink.updater",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: warning]
            )
        }
        logger.info("Sparkle may perform update check \(String(describing: updateCheck), privacy: .public)")
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        latestVersion = item.displayVersionString
        updateAvailable = true
        updateState = .available(version: item.displayVersionString)
        logger.info("Sparkle found update \(item.displayVersionString, privacy: .public)")
        NotificationCenter.default.post(name: .updateAvailable, object: item.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        isDownloading = false
        downloadProgress = 1
        updateState = .readyToInstall
        logger.info("Sparkle downloaded update \(item.displayVersionString, privacy: .public)")
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        isDownloading = false
        updateState = .error("Update download failed: \(error.localizedDescription)")
        logger.error("Sparkle failed to download update \(item.displayVersionString, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        isDownloading = false
        updateState = .idle
        logger.info("User cancelled Sparkle download")
    }

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        logger.info("Sparkle user choice \(String(describing: choice), privacy: .public) for \(updateItem.displayVersionString, privacy: .public)")
        switch choice {
        case .install:
            updateState = .downloading
        case .skip, .dismiss:
            updateState = .idle
        @unknown default:
            updateState = .idle
        }
    }
}
#endif

extension Notification.Name {
    static let shouldQuitForUpdate = Notification.Name("shouldQuitForUpdate")
    static let updateAvailable = Notification.Name("updateAvailable")
}

struct UpdateSettingsView: View {
    @ObservedObject private var updater = AutoUpdater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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

            if let warning = updater.installationWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
                    .padding()
                    .background(Color.orange.opacity(0.12))
                    .cornerRadius(8)
            }

            Toggle("Check for updates automatically", isOn: Binding(
                get: { updater.automaticChecksEnabled },
                set: { updater.automaticChecksEnabled = $0 }
            ))
            .disabled(!updater.installMode.supportsAutomaticReplacement)

            Toggle("Download updates automatically", isOn: Binding(
                get: { updater.automaticDownloadsEnabled },
                set: { updater.automaticDownloadsEnabled = $0 }
            ))
            .disabled(!updater.installMode.supportsAutomaticReplacement)

            statusView

            if updater.installMode == .diskImage {
                Button {
                    updater.copyToApplications()
                } label: {
                    Label("Copy to Applications", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
            }

            if !updater.installMode.supportsAutomaticReplacement {
                Button {
                    updater.openManualDownload()
                } label: {
                    Label("Download Latest Version", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
            }

            Button {
                updater.checkForUpdates(silent: false)
            } label: {
                Label("Check for Updates", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .disabled(updater.updateState == .checking || !updater.installMode.supportsSparkleChecks)

            if let lastChecked = updater.lastChecked {
                Label("Last checked: \(lastChecked.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
        .padding()
    }

    @ViewBuilder
    private var statusView: some View {
        switch updater.updateState {
        case .idle:
            Text("Sparkle will verify, download, install, and relaunch VoiceLink when an update is available.")
                .font(.caption)
                .foregroundColor(.secondary)
        case .checking:
            HStack {
                ProgressView().scaleEffect(0.8)
                Text("Checking for updates...")
            }
            .foregroundColor(.secondary)
        case .available(let version):
            Label("Version \(version) is available. Continue in the Sparkle update window.", systemImage: "arrow.down.circle.fill")
                .foregroundColor(.green)
        case .downloading:
            Label("Sparkle is downloading or preparing the update.", systemImage: "arrow.down")
                .foregroundColor(.blue)
        case .readyToInstall:
            Label("Sparkle downloaded the update and is ready to install.", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
        }
    }
}

struct UpdateAvailableBanner: View {
    @ObservedObject private var updater = AutoUpdater.shared
    @State private var showUpdateSheet = false

    var body: some View {
        if updater.updateAvailable {
            Button {
                showUpdateSheet = true
            } label: {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Update Available")
                        .font(.caption)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(.white.opacity(0.7))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.green)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showUpdateSheet) {
                UpdateSettingsView()
                    .frame(minWidth: 520, minHeight: 360)
            }
        }
    }
}
