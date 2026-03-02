import Foundation
import AVFoundation
import CoreAudio

final class LocalMonitorManager: ObservableObject {
    static let shared = LocalMonitorManager()

    @Published private(set) var isMonitoring: Bool = false

    private var engine = AVAudioEngine()
    private var monitorPlayer = AVAudioPlayerNode()
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
        monitorPlayer = AVAudioPlayerNode()
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
            engine.attach(monitorPlayer)
            engine.disconnectNodeOutput(inputNode)
            engine.disconnectNodeOutput(engine.mainMixerNode)
            inputNode.removeTap(onBus: 0)
            engine.mainMixerNode.outputVolume = Float(SettingsManager.shared.outputVolume)
            let downstreamFormat = outputFormat.sampleRate > 0 ? outputFormat : inputFormat
            engine.connect(monitorPlayer, to: engine.mainMixerNode, format: inputFormat)
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: downstreamFormat)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                guard let self, self.isMonitoring else { return }
                guard let copiedBuffer = self.makePCMBufferCopy(from: buffer, format: inputFormat) else { return }
                self.monitorPlayer.scheduleBuffer(copiedBuffer, completionHandler: nil)
                if !self.monitorPlayer.isPlaying {
                    self.monitorPlayer.play()
                }
            }
            engine.prepare()
            if !engine.isRunning {
                try engine.start()
            }
            monitorPlayer.volume = Float(SettingsManager.shared.inputVolume)
            if !monitorPlayer.isPlaying {
                monitorPlayer.play()
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
        monitorPlayer.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.disconnectNodeOutput(engine.inputNode)
        engine.disconnectNodeOutput(monitorPlayer)
        engine.stop()
        engine.reset()
        DispatchQueue.main.async {
            self.isMonitoring = false
        }
        print("[LocalMonitor] Monitoring stopped")
    }

    private func makePCMBufferCopy(from sourceBuffer: AVAudioPCMBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: sourceBuffer.frameLength) else {
            return nil
        }
        copy.frameLength = sourceBuffer.frameLength

        if let sourceFloat = sourceBuffer.floatChannelData,
           let copyFloat = copy.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                memcpy(copyFloat[channel], sourceFloat[channel], Int(sourceBuffer.frameLength) * MemoryLayout<Float>.size)
            }
            return copy
        }

        if let sourceInt16 = sourceBuffer.int16ChannelData,
           let copyInt16 = copy.int16ChannelData {
            for channel in 0..<Int(format.channelCount) {
                memcpy(copyInt16[channel], sourceInt16[channel], Int(sourceBuffer.frameLength) * MemoryLayout<Int16>.size)
            }
            return copy
        }

        if let sourceInt32 = sourceBuffer.int32ChannelData,
           let copyInt32 = copy.int32ChannelData {
            for channel in 0..<Int(format.channelCount) {
                memcpy(copyInt32[channel], sourceInt32[channel], Int(sourceBuffer.frameLength) * MemoryLayout<Int32>.size)
            }
            return copy
        }

        return nil
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
