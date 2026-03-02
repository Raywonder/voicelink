import Foundation
import AVFoundation
import CoreAudio

final class LocalMonitorManager: ObservableObject {
    static let shared = LocalMonitorManager()

    @Published private(set) var isMonitoring: Bool = false

    private var engine = AVAudioEngine()
    private var monitorMixer = AVAudioMixerNode()
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

    private func rebuildEngine() {
        engine.stop()
        engine.reset()
        engine = AVAudioEngine()
        monitorMixer = AVAudioMixerNode()
    }

    private func startMonitoring() {
        guard !isMonitoring else { return }
        configureIfNeeded()
        SettingsManager.shared.applySelectedAudioDevices()
        rebuildEngine()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            print("[LocalMonitor] Input format unavailable")
            return
        }
        let selectedInput = SettingsManager.shared.inputDevice
        let selectedOutput = SettingsManager.shared.outputDevice
        let actualInput = defaultDeviceName(isInput: true)
        let actualOutput = defaultDeviceName(isInput: false)
        print("[LocalMonitor] Selected input=\(selectedInput) actual input=\(actualInput)")
        print("[LocalMonitor] Selected output=\(selectedOutput) actual output=\(actualOutput)")
        print("[LocalMonitor] Input format sr=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount)")
        print("[LocalMonitor] Output format sr=\(outputFormat.sampleRate) channels=\(outputFormat.channelCount)")

        do {
            engine.disconnectNodeOutput(inputNode)
            engine.attach(monitorMixer)
            engine.disconnectNodeOutput(engine.mainMixerNode)
            engine.mainMixerNode.outputVolume = Float(SettingsManager.shared.outputVolume)
            monitorMixer.outputVolume = Float(SettingsManager.shared.inputVolume)
            engine.connect(inputNode, to: monitorMixer, format: inputFormat)
            engine.connect(monitorMixer, to: engine.mainMixerNode, format: inputFormat)
            engine.prepare()
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
        engine.disconnectNodeOutput(monitorMixer)
        engine.stop()
        engine.reset()
        DispatchQueue.main.async {
            self.isMonitoring = false
        }
        print("[LocalMonitor] Monitoring stopped")
    }

    private func defaultDeviceName(isInput: Bool) -> String {
        let selector = isInput ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != 0 else {
            return "Not detected"
        }

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        var cfName: CFString?
        guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &cfName) == noErr,
              let name = cfName as String?,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Not detected"
        }
        return name
    }
}
