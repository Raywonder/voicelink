import Foundation
import AVFoundation
import CoreAudio

final class LocalMonitorManager: ObservableObject {
    static let shared = LocalMonitorManager()

    @Published private(set) var isMonitoring: Bool = false

    private var engine = AVAudioEngine()
    private var monitorMixer = AVAudioMixerNode()
    private var sourceNode: AVAudioSourceNode?
    private var isConfigured = false
    private let audioQueue = DispatchQueue(label: "voicelink.local-monitor", qos: .userInitiated)
    private var isTransitioning = false
    private var captureToken: UUID?
    private var sampleBuffer: [Float] = []
    private let maxBufferedSamples = 48_000 * 8
    private var inputMuted = false

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

    func setInputMuted(_ muted: Bool) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.inputMuted = muted
            self.applyMonitorGain()
        }
    }

    func setInputGain(_ gain: Double) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let clamped = min(max(gain, 0), 1)
            SettingsManager.shared.inputVolume = clamped
            self.applyMonitorGain()
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
        sourceNode = nil
        sampleBuffer.removeAll(keepingCapacity: true)
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
            engine.mainMixerNode.outputVolume = Float(SettingsManager.shared.outputVolume)
            applyMonitorGain()
            let monitorFormat = AVAudioFormat(standardFormatWithSampleRate: outputFormat.sampleRate, channels: max(outputFormat.channelCount, 1))
            let sourceNode = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
                guard let self else { return noErr }
                return self.renderMonitorAudio(frameCount: frameCount, audioBufferList: audioBufferList)
            }
            self.sourceNode = sourceNode
            engine.attach(sourceNode)
            engine.connect(sourceNode, to: monitorMixer, format: monitorFormat)
            engine.connect(monitorMixer, to: engine.mainMixerNode, format: nil)
            engine.prepare()
            if !engine.isRunning {
                try engine.start()
            }
            captureToken = SelectedAudioInputCapture.shared.start(deviceName: selectedInput) { [weak self] buffer in
                guard let self else { return }
                self.audioQueue.async {
                    self.appendSamples(from: buffer)
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
        engine.disconnectNodeOutput(monitorMixer)
        if let sourceNode {
            engine.disconnectNodeOutput(sourceNode)
        }
        engine.stop()
        engine.reset()
        sourceNode = nil
        sampleBuffer.removeAll(keepingCapacity: true)
        DispatchQueue.main.async {
            self.isMonitoring = false
        }
        print("[LocalMonitor] Monitoring stopped")
    }

    private func applyMonitorGain() {
        let volume: Float = inputMuted ? 0 : Float(SettingsManager.shared.inputVolume)
        monitorMixer.outputVolume = volume
    }

    private func appendSamples(from source: AVAudioPCMBuffer) {
        guard let sourceData = source.floatChannelData else { return }
        let frames = Int(source.frameLength)
        guard frames > 0 else { return }
        let channelCount = Int(max(source.format.channelCount, 1))
        let currentCount = sampleBuffer.count
        sampleBuffer.reserveCapacity(currentCount + frames)
        if channelCount == 1 {
            sampleBuffer.append(contentsOf: UnsafeBufferPointer(start: sourceData[0], count: frames))
        } else {
            for frame in 0..<frames {
                var mixed: Float = 0
                for channel in 0..<channelCount {
                    mixed += sourceData[channel][frame]
                }
                sampleBuffer.append(mixed / Float(channelCount))
            }
        }
        if sampleBuffer.count > maxBufferedSamples {
            sampleBuffer.removeFirst(sampleBuffer.count - maxBufferedSamples)
        }
    }

    private func renderMonitorAudio(frameCount: UInt32, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let framesRequested = Int(frameCount)
        guard framesRequested > 0 else { return noErr }
        let framesAvailable = min(framesRequested, sampleBuffer.count)

        for bufferIndex in 0..<ablPointer.count {
            let audioBuffer = ablPointer[bufferIndex]
            guard let data = audioBuffer.mData else { continue }
            let samples = data.bindMemory(to: Float.self, capacity: framesRequested)
            if framesAvailable > 0 {
                sampleBuffer.withUnsafeBufferPointer { buffer in
                    samples.assign(from: buffer.baseAddress!, count: framesAvailable)
                }
            }
            if framesAvailable < framesRequested {
                for frame in framesAvailable..<framesRequested {
                    samples[frame] = 0
                }
            }
        }

        if framesAvailable > 0 {
            sampleBuffer.removeFirst(framesAvailable)
        }
        return noErr
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
