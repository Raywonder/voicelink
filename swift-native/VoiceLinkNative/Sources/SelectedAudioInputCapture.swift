import Foundation
import AVFoundation
import AudioUnit
import CoreAudio

final class SelectedAudioInputCapture {
    static let shared = SelectedAudioInputCapture()

    typealias BufferHandler = @Sendable (AVAudioPCMBuffer) -> Void

    private let sessionQueue = DispatchQueue(label: "voicelink.selected-input.session", qos: .userInitiated)
    private let callbackQueue = DispatchQueue(label: "voicelink.selected-input.callback", qos: .userInitiated)
    private var subscribers: [UUID: BufferHandler] = [:]
    private var audioUnit: AudioUnit?
    private var currentDeviceID: AudioDeviceID = 0
    private var currentDeviceName: String?
    private var isRunning = false
    private let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)

    private init() {}

    func start(deviceName: String?, handler: @escaping BufferHandler) -> UUID {
        let token = UUID()
        sessionQueue.async {
            self.subscribers[token] = handler
            self.startCaptureIfNeeded(deviceName: deviceName)
        }
        return token
    }

    func stop(token: UUID) {
        sessionQueue.async {
            self.subscribers.removeValue(forKey: token)
            if self.subscribers.isEmpty {
                self.stopCapture()
            }
        }
    }

    private func startCaptureIfNeeded(deviceName: String?) {
        guard let targetDeviceID = resolveDeviceID(named: deviceName) ?? defaultInputDeviceID() else {
            print("[SelectedInputCapture] No usable input device found for selection: \(deviceName ?? "Default")")
            return
        }

        if audioUnit == nil || currentDeviceID != targetDeviceID {
            stopCapture()
            guard configureAudioUnit(deviceID: targetDeviceID) else { return }
        }

        guard let audioUnit, !isRunning else { return }
        let status = AudioOutputUnitStart(audioUnit)
        if status == noErr {
            isRunning = true
            print("[SelectedInputCapture] Capture started on \(currentDeviceName ?? "unknown device")")
        } else {
            print("[SelectedInputCapture] Failed to start capture. status=\(status)")
        }
    }

    private func stopCapture() {
        if let audioUnit, isRunning {
            AudioOutputUnitStop(audioUnit)
        }
        isRunning = false
        teardownAudioUnit()
    }

    private func teardownAudioUnit() {
        if let audioUnit {
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
        }
        audioUnit = nil
        currentDeviceID = 0
        currentDeviceName = nil
    }

    private func configureAudioUnit(deviceID: AudioDeviceID) -> Bool {
        var componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &componentDescription) else {
            print("[SelectedInputCapture] Failed to find HAL output component")
            return false
        }

        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else {
            print("[SelectedInputCapture] Failed to create HAL audio unit")
            return false
        }

        var enableInput: UInt32 = 1
        var disableOutput: UInt32 = 0
        guard AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        ) == noErr else {
            print("[SelectedInputCapture] Failed enabling input on HAL unit")
            AudioComponentInstanceDispose(unit)
            return false
        }

        guard AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &disableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        ) == noErr else {
            print("[SelectedInputCapture] Failed disabling output on HAL unit")
            AudioComponentInstanceDispose(unit)
            return false
        }

        var mutableDeviceID = deviceID
        guard AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        ) == noErr else {
            print("[SelectedInputCapture] Failed setting current device \(deviceID)")
            AudioComponentInstanceDispose(unit)
            return false
        }

        guard let outputFormat else {
            AudioComponentInstanceDispose(unit)
            return false
        }
        let asbd = outputFormat.streamDescription.pointee
        var streamDescription = asbd
        guard AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &streamDescription,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ) == noErr else {
            print("[SelectedInputCapture] Failed setting stream format")
            AudioComponentInstanceDispose(unit)
            return false
        }

        var callback = AURenderCallbackStruct(
            inputProc: selectedInputRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        guard AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ) == noErr else {
            print("[SelectedInputCapture] Failed setting render callback")
            AudioComponentInstanceDispose(unit)
            return false
        }

        let initStatus = AudioUnitInitialize(unit)
        guard initStatus == noErr else {
            print("[SelectedInputCapture] Failed to initialize HAL unit. status=\(initStatus)")
            AudioComponentInstanceDispose(unit)
            return false
        }

        audioUnit = unit
        currentDeviceID = deviceID
        currentDeviceName = deviceName(for: deviceID) ?? "Unknown"
        print("[SelectedInputCapture] Bound capture to device: \(currentDeviceName ?? "Unknown") [\(deviceID)]")
        return true
    }

    fileprivate func handleInput(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inBusNumber: UInt32,
        inNumberFrames: UInt32
    ) -> OSStatus {
        guard let audioUnit, let outputFormat else { return noErr }
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: inNumberFrames),
              let channelData = pcmBuffer.floatChannelData else {
            return noErr
        }

        pcmBuffer.frameLength = inNumberFrames
        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: inNumberFrames * UInt32(MemoryLayout<Float>.size),
                mData: channelData[0]
            )
        )

        let status = AudioUnitRender(
            audioUnit,
            ioActionFlags,
            inTimeStamp,
            1,
            inNumberFrames,
            &audioBufferList
        )
        guard status == noErr else {
            print("[SelectedInputCapture] AudioUnitRender failed. status=\(status)")
            return status
        }

        let deliveredBuffer = copyBuffer(pcmBuffer)
        callbackQueue.async {
            let handlers = self.sessionQueue.sync { Array(self.subscribers.values) }
            for handler in handlers {
                handler(deliveredBuffer)
            }
        }

        return noErr
    }

    private func copyBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) ?? source
        copy.frameLength = source.frameLength
        if let sourceData = source.floatChannelData,
           let targetData = copy.floatChannelData {
            let frames = Int(source.frameLength)
            memcpy(targetData[0], sourceData[0], frames * MemoryLayout<Float>.size)
        }
        return copy
    }

    private func resolveDeviceID(named preferredName: String?) -> AudioDeviceID? {
        let normalized = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalized.isEmpty, normalized != "Default" else {
            return nil
        }

        let devices = availableInputDevices()
        if let exact = devices.first(where: { $0.name.caseInsensitiveCompare(normalized) == .orderedSame }) {
            return exact.id
        }
        if let partial = devices.first(where: { $0.name.localizedCaseInsensitiveContains(normalized) || normalized.localizedCaseInsensitiveContains($0.name) }) {
            return partial.id
        }

        print("[SelectedInputCapture] Requested input device not found: \(normalized). Available=\(devices.map { $0.name })")
        return nil
    }

    private func availableInputDevices() -> [(id: AudioDeviceID, name: String)] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propertySize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize) == noErr else {
            return []
        }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceIDs
        ) == noErr else {
            return []
        }

        return deviceIDs.compactMap { deviceID in
            guard hasInputChannels(deviceID: deviceID),
                  let name = deviceName(for: deviceID),
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return (deviceID, name)
        }
    }

    private func hasInputChannels(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferListPointer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferListPointer) == noErr else {
            return false
        }

        let audioBufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
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
            return nil
        }
        return deviceID
    }

    private func deviceName(for deviceID: AudioDeviceID) -> String? {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var cfName: CFString = "" as CFString
        guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &cfName) == noErr else {
            return nil
        }
        let name = cfName as String
        return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name
    }
}

private let selectedInputRenderCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _ in
    let capture = Unmanaged<SelectedAudioInputCapture>.fromOpaque(inRefCon).takeUnretainedValue()
    return capture.handleInput(
        ioActionFlags: ioActionFlags,
        inTimeStamp: inTimeStamp,
        inBusNumber: inBusNumber,
        inNumberFrames: inNumberFrames
    )
}
