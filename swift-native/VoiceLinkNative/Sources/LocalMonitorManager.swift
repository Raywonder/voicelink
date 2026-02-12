import Foundation
import AVFoundation

@MainActor
final class LocalMonitorManager: ObservableObject {
    static let shared = LocalMonitorManager()

    @Published private(set) var isMonitoring: Bool = false

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var isConfigured = false

    private init() {}

    func toggleMonitoring() {
        setMonitoringEnabled(!isMonitoring)
    }

    func setMonitoringEnabled(_ enabled: Bool) {
        if enabled {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }

    private func configureIfNeeded() {
        guard !isConfigured else { return }
        engine.attach(playerNode)
        let mainMixer = engine.mainMixerNode
        engine.connect(playerNode, to: mainMixer, format: nil)
        isConfigured = true
    }

    private func startMonitoring() {
        guard !isMonitoring else { return }
        configureIfNeeded()

        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            print("[LocalMonitor] Input format unavailable")
            return
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.playerNode.scheduleBuffer(buffer, completionHandler: nil)
        }

        do {
            if !engine.isRunning {
                try engine.start()
            }
            if !playerNode.isPlaying {
                playerNode.play()
            }
            isMonitoring = true
            print("[LocalMonitor] Monitoring started")
        } catch {
            inputNode.removeTap(onBus: 0)
            print("[LocalMonitor] Failed to start monitoring: \(error)")
        }
    }

    private func stopMonitoring() {
        guard isMonitoring else { return }
        engine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        engine.stop()
        isMonitoring = false
        print("[LocalMonitor] Monitoring stopped")
    }
}
