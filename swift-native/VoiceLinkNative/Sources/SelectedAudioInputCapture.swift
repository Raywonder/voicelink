import Foundation
import AVFoundation
import CoreMedia

final class SelectedAudioInputCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let shared = SelectedAudioInputCapture()

    typealias BufferHandler = @Sendable (AVAudioPCMBuffer) -> Void

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "voicelink.selected-input.session", qos: .userInitiated)
    private let callbackQueue = DispatchQueue(label: "voicelink.selected-input.callback", qos: .userInitiated)
    private var currentInput: AVCaptureDeviceInput?
    private var selectedDeviceName: String?
    private var subscribers: [UUID: BufferHandler] = [:]
    private var isConfigured = false

    private override init() {
        super.init()
    }

    func start(deviceName: String?, handler: @escaping BufferHandler) -> UUID {
        let token = UUID()
        sessionQueue.async {
            self.subscribers[token] = handler
            self.configureSessionIfNeeded()
            self.applySelectedDevice(named: deviceName)
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
        return token
    }

    func stop(token: UUID) {
        sessionQueue.async {
            self.subscribers.removeValue(forKey: token)
            if self.subscribers.isEmpty, self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private func configureSessionIfNeeded() {
        guard !isConfigured else { return }
        session.beginConfiguration()
        if session.canAddOutput(output) {
            output.setSampleBufferDelegate(self, queue: callbackQueue)
            session.addOutput(output)
        }
        session.commitConfiguration()
        isConfigured = true
    }

    private func applySelectedDevice(named deviceName: String?) {
        let normalized = normalizedSelection(deviceName)
        guard normalized != selectedDeviceName || currentInput == nil else { return }

        let device = resolveDevice(named: normalized) ?? AVCaptureDevice.default(for: .audio)
        guard let device else { return }

        do {
            let newInput = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            if let currentInput {
                session.removeInput(currentInput)
            }
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                currentInput = newInput
                selectedDeviceName = normalized
                print("[SelectedInputCapture] Using input device: \(device.localizedName)")
            } else {
                print("[SelectedInputCapture] Unable to add selected audio input: \(device.localizedName)")
            }
            session.commitConfiguration()
        } catch {
            print("[SelectedInputCapture] Failed to configure selected audio input: \(error)")
        }
    }

    private func normalizedSelection(_ deviceName: String?) -> String? {
        guard let deviceName else { return nil }
        let trimmed = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "Default" else { return nil }
        return trimmed
    }

    private func resolveDevice(named preferredName: String?) -> AVCaptureDevice? {
        let devices = AVCaptureDevice.devices(for: .audio)
        guard let preferredName else {
            return devices.first
        }
        if let exact = devices.first(where: { $0.localizedName.caseInsensitiveCompare(preferredName) == .orderedSame }) {
            return exact
        }
        return devices.first(where: { $0.localizedName.localizedCaseInsensitiveContains(preferredName) })
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pcmBuffer = makePCMBuffer(from: sampleBuffer) else { return }
        let handlers = sessionQueue.sync { Array(self.subscribers.values) }
        for handler in handlers {
            handler(pcmBuffer)
        }
    }

    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameLength > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
        )
        var bufferListSize = MemoryLayout<AudioBufferList>.size
        let flags = UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: &audioBufferList,
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: flags,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let asbd = asbdPointer.pointee
        let channels = max(Int(asbd.mChannelsPerFrame), 1)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bytesPerSample = max(Int(asbd.mBitsPerChannel / 8), 1)
        let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate, channels: 1, interleaved: false)
        guard let monoFormat,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameLength),
              let output = pcmBuffer.floatChannelData?[0] else {
            return nil
        }

        pcmBuffer.frameLength = frameLength
        let buffers = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        let samples = Int(frameLength)

        if isFloat && bytesPerSample == MemoryLayout<Float>.size {
            if isNonInterleaved {
                var channelPointers: [UnsafePointer<Float>] = []
                for buffer in buffers {
                    guard let base = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    channelPointers.append(UnsafePointer(base))
                }
                guard !channelPointers.isEmpty else { return nil }
                for frame in 0..<samples {
                    var mixed: Float = 0
                    for channel in 0..<min(channels, channelPointers.count) {
                        mixed += channelPointers[channel][frame]
                    }
                    output[frame] = mixed / Float(min(channels, channelPointers.count))
                }
            } else if let interleaved = buffers.first?.mData?.assumingMemoryBound(to: Float.self) {
                for frame in 0..<samples {
                    var mixed: Float = 0
                    for channel in 0..<channels {
                        mixed += interleaved[(frame * channels) + channel]
                    }
                    output[frame] = mixed / Float(channels)
                }
            }
            return pcmBuffer
        }

        if bytesPerSample == MemoryLayout<Int16>.size {
            if isNonInterleaved {
                var channelPointers: [UnsafePointer<Int16>] = []
                for buffer in buffers {
                    guard let base = buffer.mData?.assumingMemoryBound(to: Int16.self) else { continue }
                    channelPointers.append(UnsafePointer(base))
                }
                guard !channelPointers.isEmpty else { return nil }
                for frame in 0..<samples {
                    var mixed: Float = 0
                    for channel in 0..<min(channels, channelPointers.count) {
                        mixed += Float(channelPointers[channel][frame]) / Float(Int16.max)
                    }
                    output[frame] = mixed / Float(min(channels, channelPointers.count))
                }
            } else if let interleaved = buffers.first?.mData?.assumingMemoryBound(to: Int16.self) {
                for frame in 0..<samples {
                    var mixed: Float = 0
                    for channel in 0..<channels {
                        mixed += Float(interleaved[(frame * channels) + channel]) / Float(Int16.max)
                    }
                    output[frame] = mixed / Float(channels)
                }
            }
            return pcmBuffer
        }

        return nil
    }
}
