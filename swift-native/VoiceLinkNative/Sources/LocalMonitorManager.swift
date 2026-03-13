import Foundation
import AVFoundation
import CoreAudio
import os

struct LocalMonitorDiagnosticsSnapshot: Codable {
    let sourceDescription: String
    let isMonitoring: Bool
    let monitoringActive: Bool
    let inputMuted: Bool
    let inputTapInstalled: Bool
    let usingSharedTransmissionFeed: Bool
    let captureSamplesReceived: Bool
    let totalSampleCallbacks: Int
    let totalFramesCaptured: Int
    let totalFramesRendered: Int
    let totalBufferUnderruns: Int
    let bufferedFrameCount: Int
    let minimumFramesBeforePlayback: Int
    let targetSampleRate: Double?
    let targetChannelCount: UInt32?
    let lastSampleAgeSeconds: Double?
    let lastErrorMessage: String?

    var multilineSummary: String {
        [
            "Local Monitor: \(isMonitoring ? "Enabled" : "Disabled")",
            "Local Monitor Active: \(monitoringActive ? "Yes" : "No")",
            "Monitor Source: \(sourceDescription)",
            "Monitor Input Muted: \(inputMuted ? "Yes" : "No")",
            "Monitor Capture Samples Received: \(captureSamplesReceived ? "Yes" : "No")",
            "Monitor Sample Callbacks: \(totalSampleCallbacks)",
            "Monitor Frames Captured: \(totalFramesCaptured)",
            "Monitor Frames Rendered: \(totalFramesRendered)",
            "Monitor Buffer Underruns: \(totalBufferUnderruns)",
            "Monitor Buffered Frames: \(bufferedFrameCount)",
            "Monitor Minimum Prebuffer Frames: \(minimumFramesBeforePlayback)",
            "Monitor Target Sample Rate: \(targetSampleRate.map { String(format: "%.2f", $0) } ?? "Unknown")",
            "Monitor Target Channels: \(targetChannelCount.map(String.init) ?? "Unknown")",
            "Monitor Last Sample Age Seconds: \(lastSampleAgeSeconds.map { String(format: "%.3f", $0) } ?? "Unknown")",
            "Monitor Last Error: \(lastErrorMessage ?? "None")"
        ].joined(separator: "\n")
    }
}

final class LocalMonitorManager: ObservableObject {
    static let shared = LocalMonitorManager()
    private let logger = Logger(subsystem: "fm.tappedin.voicelink", category: "LocalMonitor")

    @Published private(set) var isMonitoring: Bool = false
    @Published private(set) var lastErrorMessage: String?

    private var engine = AVAudioEngine()
    private var monitorMixer = AVAudioMixerNode()
    private var sourceNode: AVAudioSourceNode?
    private var isConfigured = false
    private let audioQueue = DispatchQueue(label: "voicelink.local-monitor", qos: .userInitiated)
    private var isTransitioning = false
    private var captureToken: UUID?
    private var sampleBuffer: [[Float]] = []
    private var bufferedFrameCount = 0
    private let maxBufferedFrames = 48_000 * 12
    private let sampleBufferLock = OSAllocatedUnfairLock()
    private var inputMuted = false
    private var observers: [NSObjectProtocol] = []
    private var monitoringActive = false
    private var targetMonitorFormat: AVAudioFormat?
    private var inputTapInstalled = false
    private var captureSamplesReceived = false
    private var minimumFramesBeforePlayback = 0
    private var lastSampleAt: DispatchTime = .now()
    private var stalledCaptureFallbackArmed = false
    private var usingSharedTransmissionFeed = false
    private var sharedFeedFallbackArmed = false
    private var didLogWaitingForPrebuffer = false
    private var didLogBufferUnderrun = false
    private var currentSourceDescription = "Inactive"
    private var totalSampleCallbacks = 0
    private var totalFramesCaptured = 0
    private var totalFramesRendered = 0
    private var totalBufferUnderruns = 0

    private init() {
        setupObservers()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

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

    func diagnosticsSnapshot() -> LocalMonitorDiagnosticsSnapshot {
        let elapsed = monitoringActive
            ? Double(DispatchTime.now().uptimeNanoseconds - lastSampleAt.uptimeNanoseconds) / 1_000_000_000
            : nil
        return LocalMonitorDiagnosticsSnapshot(
            sourceDescription: currentSourceDescription,
            isMonitoring: isMonitoring,
            monitoringActive: monitoringActive,
            inputMuted: inputMuted,
            inputTapInstalled: inputTapInstalled,
            usingSharedTransmissionFeed: usingSharedTransmissionFeed,
            captureSamplesReceived: captureSamplesReceived,
            totalSampleCallbacks: totalSampleCallbacks,
            totalFramesCaptured: totalFramesCaptured,
            totalFramesRendered: totalFramesRendered,
            totalBufferUnderruns: totalBufferUnderruns,
            bufferedFrameCount: bufferedFrameCount,
            minimumFramesBeforePlayback: minimumFramesBeforePlayback,
            targetSampleRate: targetMonitorFormat?.sampleRate,
            targetChannelCount: targetMonitorFormat?.channelCount,
            lastSampleAgeSeconds: elapsed,
            lastErrorMessage: lastErrorMessage
        )
    }

    func refreshForSharedCaptureChange(reason: String = "sharedCaptureChanged") {
        audioQueue.async { [weak self] in
            guard let self else { return }
            guard self.monitoringActive, !self.isTransitioning else { return }
            self.isTransitioning = true
            defer { self.isTransitioning = false }
            self.restartMonitoring(reason: reason)
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
        inputTapInstalled = false
        captureSamplesReceived = false
        stalledCaptureFallbackArmed = false
        sharedFeedFallbackArmed = false
        usingSharedTransmissionFeed = false
        currentSourceDescription = "Inactive"
        lastSampleAt = .now()
        sampleBuffer.removeAll(keepingCapacity: true)
        bufferedFrameCount = 0
        didLogWaitingForPrebuffer = false
        didLogBufferUnderrun = false
        totalSampleCallbacks = 0
        totalFramesCaptured = 0
        totalFramesRendered = 0
        totalBufferUnderruns = 0
    }

    private func startMonitoring() {
        guard !monitoringActive else { return }
        configureIfNeeded()
        clearLastError()
        SettingsManager.shared.applySelectedAudioDevices(notifyChange: false)
        rebuildEngine()

        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        let selectedInput = SettingsManager.shared.inputDevice
        let selectedOutput = SettingsManager.shared.outputDevice
        let actualInput = defaultDeviceName(isInput: true)
        let actualOutput = defaultDeviceName(isInput: false)
        print("[LocalMonitor] Selected input=\(selectedInput) actual input=\(actualInput)")
        print("[LocalMonitor] Selected output=\(selectedOutput) actual output=\(actualOutput)")
        print("[LocalMonitor] Output format sr=\(outputFormat.sampleRate) channels=\(outputFormat.channelCount)")
        logger.notice("start monitoring selectedInput=\(selectedInput, privacy: .public) actualInput=\(actualInput, privacy: .public) selectedOutput=\(selectedOutput, privacy: .public) actualOutput=\(actualOutput, privacy: .public) outputRate=\(outputFormat.sampleRate, privacy: .public) outputChannels=\(outputFormat.channelCount, privacy: .public)")

        do {
            engine.attach(monitorMixer)
            engine.mainMixerNode.outputVolume = Float(SettingsManager.shared.outputVolume)
            applyMonitorGain()
            guard let monitorFormat = AVAudioFormat(
                standardFormatWithSampleRate: outputFormat.sampleRate,
                channels: max(outputFormat.channelCount, 1)
            ) else {
                setLastError("Failed to build a monitor format for the selected output device.")
                return
            }
            targetMonitorFormat = monitorFormat
            minimumFramesBeforePlayback = max(Int(monitorFormat.sampleRate * 0.08), 2048)
            let sourceNode = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
                guard let self else { return noErr }
                return self.renderMonitorAudio(frameCount: frameCount, audioBufferList: audioBufferList)
            }
            self.sourceNode = sourceNode
            engine.attach(sourceNode)
            engine.connect(sourceNode, to: monitorMixer, format: monitorFormat)
            engine.connect(monitorMixer, to: engine.mainMixerNode, format: nil)
            let usingRoomTransmission = ServerManager.shared.isAudioTransmitting
            usingSharedTransmissionFeed = usingRoomTransmission
            if usingRoomTransmission {
                print("[LocalMonitor] Using shared transmission feed for in-room monitoring")
                logger.notice("monitor source=shared-transmission-feed")
                currentSourceDescription = "Shared transmission feed"
                scheduleSharedFeedFallbackIfNeeded(monitorFormat: monitorFormat)
            } else if selectedInput == "Default" {
                logger.notice("monitor source=engine-input-tap-default")
                currentSourceDescription = "Engine input tap (default input)"
                installEngineInputTap(monitorFormat: monitorFormat)
            }
            engine.prepare()
            if !engine.isRunning {
                try engine.start()
            }
            if !inputTapInstalled && !usingSharedTransmissionFeed {
                logger.notice("monitor source=selected-input-capture")
                currentSourceDescription = "Selected input capture"
                captureToken = SelectedAudioInputCapture.shared.start(deviceName: selectedInput, preferredFormat: monitorFormat) { [weak self] buffer in
                    guard let self else { return }
                    self.audioQueue.async {
                        if let converted = self.convertBufferIfNeeded(buffer, to: monitorFormat) {
                            self.appendSamples(from: converted)
                        } else {
                            self.appendSamples(from: buffer)
                        }
                    }
                }
                scheduleCaptureFallbackIfNeeded(monitorFormat: monitorFormat)
                scheduleStallWatchdog(monitorFormat: monitorFormat)
            }
            updateMonitoringState(true)
            print("[LocalMonitor] Monitoring started")
            logger.notice("monitoring started")
        } catch {
            engine.stop()
            engine.reset()
            if let captureToken {
                SelectedAudioInputCapture.shared.stop(token: captureToken)
                self.captureToken = nil
            }
            updateMonitoringState(false)
            currentSourceDescription = "Failed to start"
            setLastError("Failed to start self monitoring. Check your selected audio devices and try again.")
            print("[LocalMonitor] Failed to start monitoring: \(error)")
            logger.error("monitoring failed to start: \(String(describing: error), privacy: .public)")
        }
    }

    func ingestSharedTransmissionBuffer(_ buffer: AVAudioPCMBuffer) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            guard self.monitoringActive, self.usingSharedTransmissionFeed else { return }
            guard let monitorFormat = self.targetMonitorFormat else { return }
            if let converted = self.convertBufferIfNeeded(buffer, to: monitorFormat) {
                self.appendSamples(from: converted)
            } else {
                self.appendSamples(from: buffer)
            }
        }
    }

    private func stopMonitoring() {
        guard monitoringActive else { return }
        if let captureToken {
            SelectedAudioInputCapture.shared.stop(token: captureToken)
            self.captureToken = nil
        }
        removeEngineInputTap()
        engine.disconnectNodeOutput(monitorMixer)
        if let sourceNode {
            engine.disconnectNodeOutput(sourceNode)
        }
        engine.stop()
        engine.reset()
        sourceNode = nil
        targetMonitorFormat = nil
        minimumFramesBeforePlayback = 0
        sampleBuffer.removeAll(keepingCapacity: true)
        bufferedFrameCount = 0
        currentSourceDescription = "Stopped"
        updateMonitoringState(false)
        print("[LocalMonitor] Monitoring stopped")
        logger.notice("monitoring stopped")
    }

    private func restartMonitoring(reason: String) {
        guard monitoringActive else { return }
        print("[LocalMonitor] Restarting monitor (\(reason))")
        logger.notice("restarting monitor reason=\(reason, privacy: .public)")
        stopMonitoring()
        startMonitoring()
    }

    private func updateMonitoringState(_ active: Bool) {
        monitoringActive = active
        DispatchQueue.main.async {
            self.isMonitoring = active
        }
    }

    private func setLastError(_ message: String?) {
        DispatchQueue.main.async {
            self.lastErrorMessage = message
        }
    }

    private func clearLastError() {
        setLastError(nil)
    }

    private func setupObservers() {
        let deviceObserver = NotificationCenter.default.addObserver(
            forName: .audioDevicesChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.audioQueue.async { [weak self] in
                self?.restartMonitoring(reason: "audioDevicesChanged")
            }
        }
        observers.append(deviceObserver)

        let engineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.audioQueue.async { [weak self] in
                self?.restartMonitoring(reason: "engineConfigurationChanged")
            }
        }
        observers.append(engineConfigObserver)
    }

    private func applyMonitorGain() {
        let volume: Float = inputMuted ? 0 : Float(SettingsManager.shared.inputVolume)
        monitorMixer.outputVolume = volume
    }

    private func appendSamples(from source: AVAudioPCMBuffer) {
        guard let sourceData = source.floatChannelData else { return }
        let frames = Int(source.frameLength)
        guard frames > 0 else { return }
        captureSamplesReceived = true
        totalSampleCallbacks += 1
        totalFramesCaptured += frames
        lastSampleAt = .now()
        let channelCount = Int(max(source.format.channelCount, 1))
        sampleBufferLock.withLock {
            if sampleBuffer.count != channelCount {
                sampleBuffer = Array(repeating: [], count: channelCount)
                bufferedFrameCount = 0
            }
            for channel in 0..<channelCount {
                sampleBuffer[channel].append(contentsOf: UnsafeBufferPointer(start: sourceData[channel], count: frames))
            }
            bufferedFrameCount += frames
            if bufferedFrameCount > maxBufferedFrames {
                let overflow = bufferedFrameCount - maxBufferedFrames
                for channel in 0..<sampleBuffer.count {
                    sampleBuffer[channel].removeFirst(min(overflow, sampleBuffer[channel].count))
                }
                bufferedFrameCount = maxBufferedFrames
            }
        }
    }

    private func convertBufferIfNeeded(_ source: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        if source.format.sampleRate == targetFormat.sampleRate && source.format.channelCount == targetFormat.channelCount {
            return source
        }

        guard let converter = AVAudioConverter(from: source.format, to: targetFormat) else {
            return nil
        }

        let ratio = targetFormat.sampleRate / source.format.sampleRate
        let targetCapacity = AVAudioFrameCount(max(1, Int((Double(source.frameLength) * ratio).rounded(.up)) + 8))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
            return nil
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return source
        }

        if status == .error || conversionError != nil {
            print("[LocalMonitor] Failed to convert monitor buffer from \(source.format.sampleRate) Hz to \(targetFormat.sampleRate) Hz")
            return nil
        }

        return outputBuffer
    }

    private func renderMonitorAudio(frameCount: UInt32, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let framesRequested = Int(frameCount)
        guard framesRequested > 0 else { return noErr }
        sampleBufferLock.withLock {
            if bufferedFrameCount < minimumFramesBeforePlayback {
                if !didLogWaitingForPrebuffer {
                    self.logger.notice("monitor waiting for prebuffer bufferedFrames=\(self.bufferedFrameCount, privacy: .public) minimumFrames=\(self.minimumFramesBeforePlayback, privacy: .public)")
                    self.didLogWaitingForPrebuffer = true
                }
                for bufferIndex in 0..<ablPointer.count {
                    let audioBuffer = ablPointer[bufferIndex]
                    guard let data = audioBuffer.mData else { continue }
                    let samples = data.bindMemory(to: Float.self, capacity: framesRequested)
                    for frame in 0..<framesRequested {
                        samples[frame] = 0
                    }
                }
                return
            }
            self.didLogWaitingForPrebuffer = false

            let framesAvailable = min(framesRequested, bufferedFrameCount)
            if framesAvailable < framesRequested && !didLogBufferUnderrun {
                totalBufferUnderruns += 1
                self.logger.notice("monitor buffer underrun framesRequested=\(framesRequested, privacy: .public) framesAvailable=\(framesAvailable, privacy: .public) bufferedFrames=\(self.bufferedFrameCount, privacy: .public)")
                self.didLogBufferUnderrun = true
            } else if framesAvailable >= framesRequested {
                self.didLogBufferUnderrun = false
            }

            for bufferIndex in 0..<ablPointer.count {
                let audioBuffer = ablPointer[bufferIndex]
                guard let data = audioBuffer.mData else { continue }
                let samples = data.bindMemory(to: Float.self, capacity: framesRequested)
                if framesAvailable > 0 {
                    let sourceChannel = min(bufferIndex, max(sampleBuffer.count - 1, 0))
                    sampleBuffer[sourceChannel].withUnsafeBufferPointer { buffer in
                        guard let baseAddress = buffer.baseAddress else { return }
                        samples.assign(from: baseAddress, count: framesAvailable)
                    }
                }
                if framesAvailable < framesRequested {
                    for frame in framesAvailable..<framesRequested {
                        samples[frame] = 0
                    }
                }
            }

            if framesAvailable > 0 {
                totalFramesRendered += framesAvailable
                for channel in 0..<sampleBuffer.count {
                    sampleBuffer[channel].removeFirst(min(framesAvailable, sampleBuffer[channel].count))
                }
                bufferedFrameCount = max(0, bufferedFrameCount - framesAvailable)
            }
        }
        return noErr
    }

    private func installEngineInputTap(monitorFormat: AVAudioFormat) {
        guard !inputTapInstalled else { return }
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            print("[LocalMonitor] Input tap unavailable; input node has no channels")
            return
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.audioQueue.async {
                if let converted = self.convertBufferIfNeeded(buffer, to: monitorFormat) {
                    self.appendSamples(from: converted)
                } else {
                    self.appendSamples(from: buffer)
                }
            }
        }
        inputTapInstalled = true
        currentSourceDescription = usingSharedTransmissionFeed ? "Engine input tap (shared-feed fallback)" : currentSourceDescription
        print("[LocalMonitor] Installed engine input tap fallback")
        logger.notice("monitor source switched to engine-input-tap")
    }

    private func removeEngineInputTap() {
        guard inputTapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        inputTapInstalled = false
    }

    private func scheduleCaptureFallbackIfNeeded(monitorFormat: AVAudioFormat) {
        let expectedToken = captureToken
        audioQueue.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            guard self.monitoringActive else { return }
            guard self.captureToken == expectedToken else { return }
            guard !self.captureSamplesReceived else { return }
            guard !self.inputTapInstalled else { return }
            print("[LocalMonitor] No samples received from selected input capture; falling back to engine input tap")
            self.logger.notice("selected input capture produced no samples; switching to engine-input-tap fallback")
            if let captureToken = self.captureToken {
                SelectedAudioInputCapture.shared.stop(token: captureToken)
                self.captureToken = nil
            }
            self.currentSourceDescription = "Engine input tap (selected-input no-samples fallback)"
            self.installEngineInputTap(monitorFormat: monitorFormat)
        }
    }

    private func scheduleStallWatchdog(monitorFormat: AVAudioFormat) {
        guard !stalledCaptureFallbackArmed else { return }
        stalledCaptureFallbackArmed = true
        audioQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.stalledCaptureFallbackArmed = false
            guard self.monitoringActive else { return }
            guard !self.inputTapInstalled else { return }
            guard self.captureToken != nil else { return }

            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - self.lastSampleAt.uptimeNanoseconds) / 1_000_000_000
            if elapsed > 1.5 {
                print("[LocalMonitor] Selected input capture stalled for \(elapsed)s; falling back to engine input tap")
                self.logger.notice("selected input capture stalled elapsed=\(elapsed, privacy: .public); switching to engine-input-tap fallback")
                if let captureToken = self.captureToken {
                    SelectedAudioInputCapture.shared.stop(token: captureToken)
                    self.captureToken = nil
                }
                self.currentSourceDescription = "Engine input tap (selected-input stall fallback)"
                self.installEngineInputTap(monitorFormat: monitorFormat)
                return
            }

            self.scheduleStallWatchdog(monitorFormat: monitorFormat)
        }
    }

    private func scheduleSharedFeedFallbackIfNeeded(monitorFormat: AVAudioFormat) {
        guard !sharedFeedFallbackArmed else { return }
        sharedFeedFallbackArmed = true
        audioQueue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.sharedFeedFallbackArmed = false
            guard self.monitoringActive else { return }
            guard self.usingSharedTransmissionFeed else { return }
            guard !self.inputTapInstalled else { return }

            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - self.lastSampleAt.uptimeNanoseconds) / 1_000_000_000
            if elapsed > 1.0 {
                print("[LocalMonitor] Shared transmission feed stalled for \(elapsed)s; enabling engine input tap fallback")
                self.logger.notice("shared transmission feed stalled elapsed=\(elapsed, privacy: .public); enabling engine-input-tap fallback")
                self.currentSourceDescription = "Engine input tap (shared-feed stall fallback)"
                self.installEngineInputTap(monitorFormat: monitorFormat)
                return
            }

            self.scheduleSharedFeedFallbackIfNeeded(monitorFormat: monitorFormat)
        }
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
