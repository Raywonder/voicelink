import Foundation
import AVFoundation
import CoreAudio

// MARK: - Multi-Channel Audio Engine
/// Professional 64-channel I/O with mono/stereo/binaural support

class MultiChannelAudioEngine: ObservableObject {
    static let shared = MultiChannelAudioEngine()

    // Constants
    let maxChannels = 64

    // Audio engine
    private var audioEngine: AVAudioEngine?
    private var inputMixers: [Int: AVAudioMixerNode] = [:]
    private var outputMixers: [Int: AVAudioMixerNode] = [:]

    // Channel configurations
    @Published var inputChannels: [AudioChannel] = []
    @Published var outputChannels: [AudioChannel] = []

    // User-to-channel mapping
    @Published var userInputChannels: [String: [Int]] = [:]
    @Published var userOutputChannels: [String: [Int]] = [:]

    // Routing matrix
    @Published var routingMatrix: [[Float]] = [] // [input][output] = gain

    // Audio interface info
    @Published var currentInterface: AudioInterfaceInfo?
    @Published var availableInterfaces: [AudioInterfaceInfo] = []

    // Settings
    @Published var sampleRate: Double = 48000
    @Published var bufferSize: Int = 256
    @Published var bitDepth: Int = 24

    // Channel types
    enum ChannelType: String, Codable {
        case mono
        case stereo
        case binaural
        case surround51
        case surround71
    }

    struct AudioChannel: Identifiable, Codable {
        let id: Int
        var name: String
        var type: ChannelType
        var isConnected: Bool
        var gain: Float
        var muted: Bool
        var solo: Bool
        var pan: Float // -1 (left) to 1 (right)
        var linkedChannels: [Int] // For stereo/surround linking

        init(id: Int, name: String = "", type: ChannelType = .mono) {
            self.id = id
            self.name = name.isEmpty ? "Channel \(id)" : name
            self.type = type
            self.isConnected = false
            self.gain = 1.0
            self.muted = false
            self.solo = false
            self.pan = 0.0
            self.linkedChannels = []
        }
    }

    struct AudioInterfaceInfo: Identifiable {
        let id: AudioDeviceID
        let name: String
        let manufacturer: String
        let inputChannelCount: Int
        let outputChannelCount: Int
        let supportedSampleRates: [Double]
        let supportedBitDepths: [Int]
        var isDefault: Bool
    }

    init() {
        setupDefaultChannels()
        detectAudioInterfaces()
        initializeRoutingMatrix()
    }

    // MARK: - Setup

    private func setupDefaultChannels() {
        // Initialize input channels (1-64)
        inputChannels = (1...maxChannels).map { AudioChannel(id: $0, name: "Input \($0)") }

        // Initialize output channels (1-64)
        outputChannels = (1...maxChannels).map { AudioChannel(id: $0, name: "Output \($0)") }

        // Setup default stereo pairs
        setupStereoPair(inputChannel: 1, rightChannel: 2, name: "Main L/R")
        setupStereoPair(outputChannel: 1, rightChannel: 2, name: "Main Out L/R")
    }

    private func initializeRoutingMatrix() {
        // Create 64x64 routing matrix initialized to 0 (no routing)
        routingMatrix = Array(repeating: Array(repeating: Float(0), count: maxChannels), count: maxChannels)

        // Default 1:1 routing for first 2 channels (stereo passthrough)
        routingMatrix[0][0] = 1.0
        routingMatrix[1][1] = 1.0
    }

    func setupAudioEngine() throws {
        audioEngine = AVAudioEngine()

        guard let engine = audioEngine else {
            throw MultiChannelError.engineNotInitialized
        }

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)

        // Create mixer nodes for each channel
        for i in 0..<maxChannels {
            let inputMixer = AVAudioMixerNode()
            let outputMixer = AVAudioMixerNode()

            engine.attach(inputMixer)
            engine.attach(outputMixer)

            inputMixers[i] = inputMixer
            outputMixers[i] = outputMixer
        }

        // Connect output mixers to main output
        for (_, mixer) in outputMixers {
            engine.connect(mixer, to: engine.mainMixerNode, format: format)
        }

        try engine.start()
        print("[MultiChannel] Audio engine started with \(maxChannels) channels")
    }

    // MARK: - Audio Interface Detection

    func detectAudioInterfaces() {
        availableInterfaces = []

        var propertySize: UInt32 = 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize)

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &deviceIDs)

        for deviceID in deviceIDs {
            if let info = getDeviceInfo(deviceID: deviceID) {
                availableInterfaces.append(info)
            }
        }

        // Set default interface
        if currentInterface == nil {
            currentInterface = availableInterfaces.first(where: { $0.isDefault })
        }

        print("[MultiChannel] Detected \(availableInterfaces.count) audio interfaces")
    }

    private func getDeviceInfo(deviceID: AudioDeviceID) -> AudioInterfaceInfo? {
        // Get device name
        var nameSize: UInt32 = 256
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: CFString = "" as CFString
        AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)

        // Get manufacturer
        var manufacturerSize: UInt32 = 256
        var manufacturerAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyManufacturer,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var manufacturer: CFString = "" as CFString
        AudioObjectGetPropertyData(deviceID, &manufacturerAddress, 0, nil, &manufacturerSize, &manufacturer)

        // Get input channel count
        var inputStreamSize: UInt32 = 0
        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &inputStreamSize)

        var inputChannelCount = 0
        if inputStreamSize > 0 {
            let bufferListSize = Int(inputStreamSize)
            let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: bufferListSize)
            AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &inputStreamSize, bufferList)

            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            for buffer in buffers {
                inputChannelCount += Int(buffer.mNumberChannels)
            }
            bufferList.deallocate()
        }

        // Get output channel count
        var outputStreamSize: UInt32 = 0
        var outputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyDataSize(deviceID, &outputAddress, 0, nil, &outputStreamSize)

        var outputChannelCount = 0
        if outputStreamSize > 0 {
            let bufferListSize = Int(outputStreamSize)
            let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: bufferListSize)
            AudioObjectGetPropertyData(deviceID, &outputAddress, 0, nil, &outputStreamSize, bufferList)

            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            for buffer in buffers {
                outputChannelCount += Int(buffer.mNumberChannels)
            }
            bufferList.deallocate()
        }

        // Skip devices with no channels
        guard inputChannelCount > 0 || outputChannelCount > 0 else { return nil }

        // Check if default device
        var defaultInputID: AudioDeviceID = 0
        var defaultInputSize: UInt32 = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultInputAddress, 0, nil, &defaultInputSize, &defaultInputID)

        return AudioInterfaceInfo(
            id: deviceID,
            name: name as String,
            manufacturer: manufacturer as String,
            inputChannelCount: inputChannelCount,
            outputChannelCount: outputChannelCount,
            supportedSampleRates: [44100, 48000, 96000, 192000],
            supportedBitDepths: [16, 24, 32],
            isDefault: deviceID == defaultInputID
        )
    }

    // MARK: - Channel Management

    func setupStereoPair(inputChannel left: Int, rightChannel right: Int, name: String) {
        guard left > 0 && left <= maxChannels && right > 0 && right <= maxChannels else { return }

        let leftIdx = left - 1
        let rightIdx = right - 1

        inputChannels[leftIdx].name = "\(name) L"
        inputChannels[leftIdx].type = .stereo
        inputChannels[leftIdx].linkedChannels = [right]

        inputChannels[rightIdx].name = "\(name) R"
        inputChannels[rightIdx].type = .stereo
        inputChannels[rightIdx].linkedChannels = [left]
    }

    func setupStereoPair(outputChannel left: Int, rightChannel right: Int, name: String) {
        guard left > 0 && left <= maxChannels && right > 0 && right <= maxChannels else { return }

        let leftIdx = left - 1
        let rightIdx = right - 1

        outputChannels[leftIdx].name = "\(name) L"
        outputChannels[leftIdx].type = .stereo
        outputChannels[leftIdx].linkedChannels = [right]

        outputChannels[rightIdx].name = "\(name) R"
        outputChannels[rightIdx].type = .stereo
        outputChannels[rightIdx].linkedChannels = [left]
    }

    func setChannelGain(channel: Int, isInput: Bool, gain: Float) {
        let idx = channel - 1
        guard idx >= 0 && idx < maxChannels else { return }

        if isInput {
            inputChannels[idx].gain = gain
            inputMixers[idx]?.outputVolume = gain
        } else {
            outputChannels[idx].gain = gain
            outputMixers[idx]?.outputVolume = gain
        }
    }

    func setChannelMute(channel: Int, isInput: Bool, muted: Bool) {
        let idx = channel - 1
        guard idx >= 0 && idx < maxChannels else { return }

        if isInput {
            inputChannels[idx].muted = muted
            inputMixers[idx]?.outputVolume = muted ? 0 : inputChannels[idx].gain
        } else {
            outputChannels[idx].muted = muted
            outputMixers[idx]?.outputVolume = muted ? 0 : outputChannels[idx].gain
        }
    }

    func setChannelSolo(channel: Int, isInput: Bool, solo: Bool) {
        let idx = channel - 1
        guard idx >= 0 && idx < maxChannels else { return }

        if isInput {
            inputChannels[idx].solo = solo
            updateSoloState(isInput: true)
        } else {
            outputChannels[idx].solo = solo
            updateSoloState(isInput: false)
        }
    }

    private func updateSoloState(isInput: Bool) {
        let channels = isInput ? inputChannels : outputChannels
        let mixers = isInput ? inputMixers : outputMixers
        let anySolo = channels.contains { $0.solo }

        for (idx, channel) in channels.enumerated() {
            if anySolo {
                // Only soloed channels are audible
                mixers[idx]?.outputVolume = channel.solo ? channel.gain : 0
            } else {
                // Normal operation
                mixers[idx]?.outputVolume = channel.muted ? 0 : channel.gain
            }
        }
    }

    // MARK: - Routing

    func setRouting(inputChannel: Int, outputChannel: Int, gain: Float) {
        guard inputChannel > 0 && inputChannel <= maxChannels,
              outputChannel > 0 && outputChannel <= maxChannels else { return }

        routingMatrix[inputChannel - 1][outputChannel - 1] = gain
    }

    func getRouting(inputChannel: Int, outputChannel: Int) -> Float {
        guard inputChannel > 0 && inputChannel <= maxChannels,
              outputChannel > 0 && outputChannel <= maxChannels else { return 0 }

        return routingMatrix[inputChannel - 1][outputChannel - 1]
    }

    func clearAllRouting() {
        routingMatrix = Array(repeating: Array(repeating: Float(0), count: maxChannels), count: maxChannels)
    }

    func setDefaultStereoRouting() {
        clearAllRouting()
        routingMatrix[0][0] = 1.0 // Input 1 -> Output 1
        routingMatrix[1][1] = 1.0 // Input 2 -> Output 2
    }

    // MARK: - User Channel Assignment

    func assignUserToInputChannels(userId: String, channels: [Int]) {
        userInputChannels[userId] = channels.filter { $0 > 0 && $0 <= maxChannels }
    }

    func assignUserToOutputChannels(userId: String, channels: [Int]) {
        userOutputChannels[userId] = channels.filter { $0 > 0 && $0 <= maxChannels }
    }

    func removeUserChannelAssignments(userId: String) {
        userInputChannels.removeValue(forKey: userId)
        userOutputChannels.removeValue(forKey: userId)
    }

    func getUserInputChannels(userId: String) -> [Int] {
        return userInputChannels[userId] ?? [1, 2] // Default to stereo
    }

    func getUserOutputChannels(userId: String) -> [Int] {
        return userOutputChannels[userId] ?? [1, 2] // Default to stereo
    }

    // MARK: - Presets

    struct ChannelPreset: Codable, Identifiable {
        let id: UUID
        var name: String
        var inputConfigs: [AudioChannel]
        var outputConfigs: [AudioChannel]
        var routing: [[Float]]
    }

    func savePreset(name: String) -> ChannelPreset {
        return ChannelPreset(
            id: UUID(),
            name: name,
            inputConfigs: inputChannels,
            outputConfigs: outputChannels,
            routing: routingMatrix
        )
    }

    func loadPreset(_ preset: ChannelPreset) {
        inputChannels = preset.inputConfigs
        outputChannels = preset.outputConfigs
        routingMatrix = preset.routing

        // Apply to mixers
        for (idx, channel) in inputChannels.enumerated() {
            inputMixers[idx]?.outputVolume = channel.muted ? 0 : channel.gain
        }
        for (idx, channel) in outputChannels.enumerated() {
            outputMixers[idx]?.outputVolume = channel.muted ? 0 : channel.gain
        }
    }
}

// MARK: - Errors

enum MultiChannelError: Error {
    case engineNotInitialized
    case invalidChannel
    case deviceNotFound
}

// MARK: - Multi-Channel Settings View

import SwiftUI

struct MultiChannelSettingsView: View {
    @ObservedObject var engine = MultiChannelAudioEngine.shared
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Tab selector
            Picker("View", selection: $selectedTab) {
                Text("Inputs").tag(0)
                Text("Outputs").tag(1)
                Text("Routing").tag(2)
                Text("Interface").tag(3)
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            // Content
            ScrollView {
                switch selectedTab {
                case 0:
                    ChannelListView(channels: $engine.inputChannels, isInput: true)
                case 1:
                    ChannelListView(channels: $engine.outputChannels, isInput: false)
                case 2:
                    RoutingMatrixView()
                case 3:
                    InterfaceSettingsView()
                default:
                    EmptyView()
                }
            }
        }
    }
}

struct ChannelListView: View {
    @Binding var channels: [MultiChannelAudioEngine.AudioChannel]
    let isInput: Bool
    @ObservedObject var engine = MultiChannelAudioEngine.shared

    var body: some View {
        LazyVStack(spacing: 8) {
            ForEach(channels.indices.prefix(16), id: \.self) { idx in
                ChannelStripView(
                    channel: $channels[idx],
                    isInput: isInput,
                    onGainChange: { gain in
                        engine.setChannelGain(channel: idx + 1, isInput: isInput, gain: gain)
                    },
                    onMuteToggle: {
                        engine.setChannelMute(channel: idx + 1, isInput: isInput, muted: !channels[idx].muted)
                    },
                    onSoloToggle: {
                        engine.setChannelSolo(channel: idx + 1, isInput: isInput, solo: !channels[idx].solo)
                    }
                )
            }
        }
        .padding()
    }
}

struct ChannelStripView: View {
    @Binding var channel: MultiChannelAudioEngine.AudioChannel
    let isInput: Bool
    let onGainChange: (Float) -> Void
    let onMuteToggle: () -> Void
    let onSoloToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Channel number
            Text("\(channel.id)")
                .font(.caption)
                .frame(width: 24)

            // Channel name
            TextField("Name", text: $channel.name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)

            // Gain slider
            HStack {
                Text("Gain")
                    .font(.caption)
                Slider(value: Binding(
                    get: { channel.gain },
                    set: { onGainChange(Float($0)) }
                ), in: 0...2)
                .frame(width: 100)
                Text(String(format: "%.1f", channel.gain))
                    .font(.caption)
                    .frame(width: 30)
            }

            // Mute button
            Button(action: onMuteToggle) {
                Text("M")
                    .font(.caption.bold())
                    .frame(width: 24, height: 24)
                    .background(channel.muted ? Color.red : Color.gray.opacity(0.3))
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)

            // Solo button
            Button(action: onSoloToggle) {
                Text("S")
                    .font(.caption.bold())
                    .frame(width: 24, height: 24)
                    .background(channel.solo ? Color.yellow : Color.gray.opacity(0.3))
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)

            // Type indicator
            Text(channel.type.rawValue)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.2))
                .cornerRadius(4)

            Spacer()
        }
        .padding(8)
        .background(Color.white.opacity(0.05))
        .cornerRadius(6)
    }
}

struct RoutingMatrixView: View {
    @ObservedObject var engine = MultiChannelAudioEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Routing Matrix")
                .font(.headline)

            Text("Click cells to toggle routing between inputs and outputs")
                .font(.caption)
                .foregroundColor(.gray)

            // Simple 8x8 matrix view (showing first 8 channels)
            VStack(spacing: 2) {
                // Header row
                HStack(spacing: 2) {
                    Text("")
                        .frame(width: 60)
                    ForEach(1...8, id: \.self) { out in
                        Text("Out \(out)")
                            .font(.caption2)
                            .frame(width: 44)
                    }
                }

                // Matrix rows
                ForEach(0..<8, id: \.self) { inIdx in
                    HStack(spacing: 2) {
                        Text("In \(inIdx + 1)")
                            .font(.caption2)
                            .frame(width: 60)

                        ForEach(0..<8, id: \.self) { outIdx in
                            let gain = engine.routingMatrix[inIdx][outIdx]
                            Button(action: {
                                let newGain: Float = gain > 0 ? 0 : 1
                                engine.setRouting(inputChannel: inIdx + 1, outputChannel: outIdx + 1, gain: newGain)
                            }) {
                                Rectangle()
                                    .fill(gain > 0 ? Color.green : Color.gray.opacity(0.3))
                                    .frame(width: 44, height: 24)
                                    .overlay(
                                        Text(gain > 0 ? "ON" : "")
                                            .font(.caption2)
                                            .foregroundColor(.white)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack {
                Button("Clear All") {
                    engine.clearAllRouting()
                }
                .buttonStyle(.bordered)

                Button("Default Stereo") {
                    engine.setDefaultStereoRouting()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }
}

struct InterfaceSettingsView: View {
    @ObservedObject var engine = MultiChannelAudioEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Current interface
            if let current = engine.currentInterface {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current Interface")
                        .font(.headline)

                    HStack {
                        VStack(alignment: .leading) {
                            Text(current.name)
                                .font(.subheadline.bold())
                            Text(current.manufacturer)
                                .font(.caption)
                                .foregroundColor(.gray)
                        }

                        Spacer()

                        VStack(alignment: .trailing) {
                            Text("\(current.inputChannelCount) in / \(current.outputChannelCount) out")
                                .font(.caption)
                            if current.isDefault {
                                Text("Default Device")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                            }
                        }
                    }
                    .padding()
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(8)
                }
            }

            // Sample rate
            VStack(alignment: .leading, spacing: 8) {
                Text("Sample Rate")
                    .font(.headline)

                Picker("Sample Rate", selection: $engine.sampleRate) {
                    Text("44.1 kHz").tag(44100.0)
                    Text("48 kHz").tag(48000.0)
                    Text("96 kHz").tag(96000.0)
                    Text("192 kHz").tag(192000.0)
                }
                .pickerStyle(.segmented)
            }

            // Buffer size
            VStack(alignment: .leading, spacing: 8) {
                Text("Buffer Size")
                    .font(.headline)

                Picker("Buffer Size", selection: $engine.bufferSize) {
                    Text("64").tag(64)
                    Text("128").tag(128)
                    Text("256").tag(256)
                    Text("512").tag(512)
                    Text("1024").tag(1024)
                }
                .pickerStyle(.segmented)

                Text("Lower = less latency, higher CPU. Higher = more latency, less CPU.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            // Available interfaces
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Available Interfaces")
                        .font(.headline)
                    Spacer()
                    Button("Refresh") {
                        engine.detectAudioInterfaces()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                ForEach(engine.availableInterfaces) { interface in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(interface.name)
                                .font(.subheadline)
                            Text("\(interface.inputChannelCount) in / \(interface.outputChannelCount) out")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }

                        Spacer()

                        if interface.id == engine.currentInterface?.id {
                            Text("Active")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                    .padding(8)
                    .background(Color.white.opacity(0.03))
                    .cornerRadius(6)
                }
            }
        }
        .padding()
    }
}
