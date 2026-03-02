import Foundation
import AVFoundation
import CoreAudio

final class LocalMonitorManager: ObservableObject {
    static let shared = LocalMonitorManager()

    @Published private(set) var isMonitoring: Bool = false

    private var engine = AVAudioEngine()
    private var monitorMixer = AVAudioMixerNode()
    private var playerNode = AVAudioPlayerNode()
    private var isConfigured = false
    private let audioQueue = DispatchQueue(label: "voicelink.local-monitor", qos: .userInitiated)
    private var isTransitioning = false
    private var captureToken: UUID?

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
        playerNode = AVAudioPlayerNode()
    }

    private func startMonitoring() {
        guard !isMonitoring else { return }
        configureIfNeeded()
        SettingsManager.shared.applySelectedAudioDevices()
        rebuildEngine()

        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        let selectedInput = SettingsManager.shared.inputDevice
        let selectedOutput = SettingsManager.shared.outputDevice
        let actualInput = defaultDeviceName(isInput: true)
        let actualOutput = defaultDeviceName(isInput: false)
        print("[LocalMonitor] Selected input=\(selectedInput) actual input=\(actualInput)")
        print("[LocalMonitor] Selected output=\(selectedOutput) actual output=\(actualOutput)")
        print("[LocalMonitor] Output format sr=\(outputFormat.sampleRate) channels=\(outputFormat.channelCount)")

        do {
            engine.attach(monitorMixer)
            engine.attach(playerNode)
            engine.mainMixerNode.outputVolume = Float(SettingsManager.shared.outputVolume)
            monitorMixer.outputVolume = Float(SettingsManager.shared.inputVolume)
            engine.connect(playerNode, to: monitorMixer, format: nil)
            engine.connect(monitorMixer, to: engine.mainMixerNode, format: nil)
            engine.prepare()
            if !engine.isRunning {
                try engine.start()
            }
            playerNode.play()
            captureToken = SelectedAudioInputCapture.shared.start(deviceName: selectedInput) { [weak self] buffer in
                guard let self else { return }
                let copied = self.copyBuffer(buffer)
                self.audioQueue.async {
                    self.playerNode.scheduleBuffer(copied, completionHandler: nil)
                }
            }
            DispatchQueue.main.async {
                self.isMonitoring = true
            }
            print("[LocalMonitor] Monitoring started")
        } catch {
            engine.stop()
            engine.reset()
            if let captureToken {
                SelectedAudioInputCapture.shared.stop(token: captureToken)
                self.captureToken = nil
            }
            DispatchQueue.main.async {
                self.isMonitoring = false
            }
            print("[LocalMonitor] Failed to start monitoring: \(error)")
        }
    }

    private func stopMonitoring() {
        guard isMonitoring else { return }
        if let captureToken {
            SelectedAudioInputCapture.shared.stop(token: captureToken)
            self.captureToken = nil
        }
        playerNode.stop()
        engine.disconnectNodeOutput(monitorMixer)
        engine.stop()
        engine.reset()
        DispatchQueue.main.async {
            self.isMonitoring = false
        }
        print("[LocalMonitor] Monitoring stopped")
    }

    private func copyBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let format = source.format
        let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: source.frameLength) ?? source
        copy.frameLength = source.frameLength
        if let sourceData = source.floatChannelData,
           let targetData = copy.floatChannelData {
            let channels = Int(format.channelCount)
            let frames = Int(source.frameLength)
            for channel in 0..<channels {
                memcpy(targetData[channel], sourceData[channel], frames * MemoryLayout<Float>.size)
            }
        }
        return copy
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
