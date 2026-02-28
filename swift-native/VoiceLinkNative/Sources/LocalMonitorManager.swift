import Foundation
import AVFoundation

final class LocalMonitorManager: ObservableObject {
    static let shared = LocalMonitorManager()

    @Published private(set) var isMonitoring: Bool = false

    private let engine = AVAudioEngine()
    private var isConfigured = false
    private let audioQueue = DispatchQueue(label: "voicelink.local-monitor", qos: .userInitiated)
    private var isTransitioning = false

    private init() {}

    func toggleMonitoring() {
        setMonitoringEnabled(!isMonitoring)
    }

    func setMonitoringEnabled(_ enabled: Bool) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isTransitioning else { return }
            self.isTransitioning = true
            defer { self.isTransitioning = false }

            if enabled {
                self.startMonitoring()
            } else {
                self.stopMonitoring()
            }
        }
    }

    private func configureIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true
    }

    private func startMonitoring() {
        guard !isMonitoring else { return }
        configureIfNeeded()

        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            print("[LocalMonitor] Input format unavailable")
            return
        }

        do {
            if engine.isRunning {
                engine.stop()
                engine.reset()
            }
            engine.disconnectNodeOutput(inputNode)
            engine.connect(inputNode, to: engine.mainMixerNode, format: format)
            if !engine.isRunning {
                try engine.start()
            }
            DispatchQueue.main.async {
                self.isMonitoring = true
            }
            print("[LocalMonitor] Monitoring started")
        } catch {
            engine.stop()
            engine.reset()
            engine.disconnectNodeOutput(inputNode)
            DispatchQueue.main.async {
                self.isMonitoring = false
            }
            print("[LocalMonitor] Failed to start monitoring: \(error)")
        }
    }

    private func stopMonitoring() {
        guard isMonitoring else { return }
        engine.disconnectNodeOutput(engine.inputNode)
        engine.stop()
        engine.reset()
        DispatchQueue.main.async {
            self.isMonitoring = false
        }
        print("[LocalMonitor] Monitoring stopped")
    }
}
