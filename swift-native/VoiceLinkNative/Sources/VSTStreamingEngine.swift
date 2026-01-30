import SwiftUI
import AVFoundation
import AudioToolbox
import Combine

// MARK: - VST Plugin Type
enum VSTPluginType: String, CaseIterable, Identifiable {
    case reverb = "reverb"
    case compressor = "compressor"
    case eq = "eq"
    case delay = "delay"
    case chorus = "chorus"
    case distortion = "distortion"
    case pitchShifter = "pitch-shifter"
    case vocoder = "vocoder"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .reverb: return "Reverb"
        case .compressor: return "Compressor"
        case .eq: return "EQ"
        case .delay: return "Delay"
        case .chorus: return "Chorus"
        case .distortion: return "Distortion"
        case .pitchShifter: return "Pitch Shifter"
        case .vocoder: return "Vocoder"
        }
    }

    var icon: String {
        switch self {
        case .reverb: return "waveform.badge.plus"
        case .compressor: return "waveform.badge.minus"
        case .eq: return "slider.horizontal.3"
        case .delay: return "repeat"
        case .chorus: return "waveform"
        case .distortion: return "bolt.fill"
        case .pitchShifter: return "arrow.up.arrow.down"
        case .vocoder: return "waveform.and.mic"
        }
    }

    var category: String {
        switch self {
        case .reverb: return "Spatial"
        case .compressor: return "Dynamics"
        case .eq: return "Filter"
        case .delay, .chorus: return "Modulation"
        case .distortion: return "Saturation"
        case .pitchShifter: return "Pitch"
        case .vocoder: return "Creative"
        }
    }
}

// MARK: - VST Parameter
struct VSTParameter: Identifiable, Codable {
    let id: String
    let name: String
    var value: Float
    let minValue: Float
    let maxValue: Float
    let defaultValue: Float
    let unit: String

    init(id: String = UUID().uuidString, name: String, value: Float, minValue: Float, maxValue: Float, defaultValue: Float, unit: String = "") {
        self.id = id
        self.name = name
        self.value = value
        self.minValue = minValue
        self.maxValue = maxValue
        self.defaultValue = defaultValue
        self.unit = unit
    }

    var normalizedValue: Float {
        return (value - minValue) / (maxValue - minValue)
    }
}

// MARK: - VST Preset
struct VSTPreset: Identifiable, Codable {
    let id: String
    let name: String
    let pluginType: String
    var parameters: [String: Float]
    let createdAt: Date
    var isFactoryPreset: Bool

    init(id: String = UUID().uuidString, name: String, pluginType: String, parameters: [String: Float], isFactoryPreset: Bool = false) {
        self.id = id
        self.name = name
        self.pluginType = pluginType
        self.parameters = parameters
        self.createdAt = Date()
        self.isFactoryPreset = isFactoryPreset
    }
}

// MARK: - VST Plugin Instance
class VSTPluginInstance: ObservableObject, Identifiable {
    let id: String
    let pluginType: VSTPluginType
    let userId: String

    @Published var parameters: [VSTParameter] = []
    @Published var bypassed: Bool = false
    @Published var isStreaming: Bool = false
    @Published var streamTargets: Set<String> = []

    // Audio processing
    var audioUnit: AVAudioUnit?
    var inputNode: AVAudioMixerNode?
    var outputNode: AVAudioMixerNode?

    // Built-in effect nodes (for when AUv3 not available)
    var reverbNode: AVAudioUnitReverb?
    var delayNode: AVAudioUnitDelay?
    var distortionNode: AVAudioUnitDistortion?
    var eqNode: AVAudioUnitEQ?

    init(id: String = UUID().uuidString, pluginType: VSTPluginType, userId: String) {
        self.id = id
        self.pluginType = pluginType
        self.userId = userId
        self.parameters = Self.defaultParameters(for: pluginType)
    }

    static func defaultParameters(for type: VSTPluginType) -> [VSTParameter] {
        switch type {
        case .reverb:
            return [
                VSTParameter(name: "Room Size", value: 0.5, minValue: 0, maxValue: 1, defaultValue: 0.5),
                VSTParameter(name: "Damping", value: 0.2, minValue: 0, maxValue: 1, defaultValue: 0.2),
                VSTParameter(name: "Wet Level", value: 0.3, minValue: 0, maxValue: 1, defaultValue: 0.3),
                VSTParameter(name: "Dry Level", value: 0.7, minValue: 0, maxValue: 1, defaultValue: 0.7)
            ]
        case .compressor:
            return [
                VSTParameter(name: "Threshold", value: -20, minValue: -60, maxValue: 0, defaultValue: -20, unit: "dB"),
                VSTParameter(name: "Ratio", value: 4, minValue: 1, maxValue: 20, defaultValue: 4),
                VSTParameter(name: "Attack", value: 3, minValue: 0.1, maxValue: 100, defaultValue: 3, unit: "ms"),
                VSTParameter(name: "Release", value: 100, minValue: 10, maxValue: 1000, defaultValue: 100, unit: "ms"),
                VSTParameter(name: "Makeup Gain", value: 0, minValue: -20, maxValue: 20, defaultValue: 0, unit: "dB")
            ]
        case .eq:
            return [
                VSTParameter(name: "Low Gain", value: 0, minValue: -15, maxValue: 15, defaultValue: 0, unit: "dB"),
                VSTParameter(name: "Low Mid Gain", value: 0, minValue: -15, maxValue: 15, defaultValue: 0, unit: "dB"),
                VSTParameter(name: "Mid Gain", value: 0, minValue: -15, maxValue: 15, defaultValue: 0, unit: "dB"),
                VSTParameter(name: "High Mid Gain", value: 0, minValue: -15, maxValue: 15, defaultValue: 0, unit: "dB"),
                VSTParameter(name: "High Gain", value: 0, minValue: -15, maxValue: 15, defaultValue: 0, unit: "dB")
            ]
        case .delay:
            return [
                VSTParameter(name: "Delay Time", value: 250, minValue: 1, maxValue: 2000, defaultValue: 250, unit: "ms"),
                VSTParameter(name: "Feedback", value: 0.3, minValue: 0, maxValue: 0.95, defaultValue: 0.3),
                VSTParameter(name: "Wet Level", value: 0.3, minValue: 0, maxValue: 1, defaultValue: 0.3),
                VSTParameter(name: "Low Cut", value: 100, minValue: 20, maxValue: 500, defaultValue: 100, unit: "Hz"),
                VSTParameter(name: "High Cut", value: 8000, minValue: 2000, maxValue: 20000, defaultValue: 8000, unit: "Hz")
            ]
        case .chorus:
            return [
                VSTParameter(name: "Rate", value: 2, minValue: 0.1, maxValue: 10, defaultValue: 2, unit: "Hz"),
                VSTParameter(name: "Depth", value: 0.5, minValue: 0, maxValue: 1, defaultValue: 0.5),
                VSTParameter(name: "Wet Level", value: 0.5, minValue: 0, maxValue: 1, defaultValue: 0.5),
                VSTParameter(name: "Voices", value: 2, minValue: 1, maxValue: 4, defaultValue: 2)
            ]
        case .distortion:
            return [
                VSTParameter(name: "Drive", value: 5, minValue: 1, maxValue: 20, defaultValue: 5),
                VSTParameter(name: "Tone", value: 0.5, minValue: 0, maxValue: 1, defaultValue: 0.5),
                VSTParameter(name: "Level", value: 0.5, minValue: 0, maxValue: 1, defaultValue: 0.5),
                VSTParameter(name: "Mix", value: 0.5, minValue: 0, maxValue: 1, defaultValue: 0.5)
            ]
        case .pitchShifter:
            return [
                VSTParameter(name: "Pitch Shift", value: 0, minValue: -24, maxValue: 24, defaultValue: 0, unit: "st"),
                VSTParameter(name: "Formant", value: 0, minValue: -12, maxValue: 12, defaultValue: 0, unit: "st"),
                VSTParameter(name: "Mix", value: 1, minValue: 0, maxValue: 1, defaultValue: 1)
            ]
        case .vocoder:
            return [
                VSTParameter(name: "Bands", value: 16, minValue: 8, maxValue: 32, defaultValue: 16),
                VSTParameter(name: "Attack", value: 10, minValue: 1, maxValue: 100, defaultValue: 10, unit: "ms"),
                VSTParameter(name: "Release", value: 100, minValue: 10, maxValue: 1000, defaultValue: 100, unit: "ms"),
                VSTParameter(name: "Mix", value: 1, minValue: 0, maxValue: 1, defaultValue: 1)
            ]
        }
    }

    func setParameter(_ name: String, value: Float) {
        if let index = parameters.firstIndex(where: { $0.name == name }) {
            parameters[index].value = value
            applyParameterToAudioUnit(name: name, value: value)
        }
    }

    private func applyParameterToAudioUnit(name: String, value: Float) {
        switch pluginType {
        case .reverb:
            if let reverb = reverbNode {
                switch name {
                case "Wet Level": reverb.wetDryMix = value * 100
                default: break
                }
            }
        case .delay:
            if let delay = delayNode {
                switch name {
                case "Delay Time": delay.delayTime = Double(value) / 1000.0
                case "Feedback": delay.feedback = value * 100
                case "Wet Level": delay.wetDryMix = value * 100
                case "Low Cut": delay.lowPassCutoff = value
                default: break
                }
            }
        case .distortion:
            if let distortion = distortionNode {
                switch name {
                case "Wet Level", "Mix": distortion.wetDryMix = value * 100
                case "Drive": distortion.preGain = value
                default: break
                }
            }
        case .eq:
            if let eq = eqNode {
                let bandIndex: Int
                switch name {
                case "Low Gain": bandIndex = 0
                case "Low Mid Gain": bandIndex = 1
                case "Mid Gain": bandIndex = 2
                case "High Mid Gain": bandIndex = 3
                case "High Gain": bandIndex = 4
                default: return
                }
                if bandIndex < eq.bands.count {
                    eq.bands[bandIndex].gain = value
                }
            }
        default:
            break
        }
    }
}

// MARK: - VST Streaming Engine
class VSTStreamingEngine: ObservableObject {
    static let shared = VSTStreamingEngine()

    // Plugin management
    @Published var pluginInstances: [String: VSTPluginInstance] = [:]
    @Published var userPluginChains: [String: [String]] = [:]
    @Published var availablePlugins: [VSTPluginType] = VSTPluginType.allCases

    // Presets
    @Published var presets: [VSTPreset] = []

    // Streaming
    @Published var activeStreams: [String: VSTStream] = [:]
    @Published var isStreamingEnabled: Bool = true

    // Audio engine
    private var audioEngine: AVAudioEngine?
    private var mainMixer: AVAudioMixerNode?

    // Stream configuration
    var streamConfig = StreamConfiguration()

    // Cancellables
    private var cancellables = Set<AnyCancellable>()

    struct StreamConfiguration {
        var sampleRate: Double = 48000
        var bufferSize: Int = 256
        var bitDepth: Int = 32
        var compressionEnabled: Bool = false
        var latencyCompensation: Bool = true
    }

    init() {
        setupAudioEngine()
        loadPresets()
        initializeFactoryPresets()
    }

    // MARK: - Audio Engine Setup

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        mainMixer = AVAudioMixerNode()

        guard let engine = audioEngine, let mixer = mainMixer else { return }

        engine.attach(mixer)
        engine.connect(mixer, to: engine.mainMixerNode, format: nil)

        do {
            try engine.start()
            print("VST Streaming Engine audio started")
        } catch {
            print("Failed to start VST audio engine: \(error)")
        }
    }

    // MARK: - Plugin Management

    func createPlugin(type: VSTPluginType, userId: String) -> VSTPluginInstance {
        let instance = VSTPluginInstance(pluginType: type, userId: userId)

        // Setup audio nodes based on plugin type
        setupAudioNodes(for: instance)

        // Add to plugin instances
        pluginInstances[instance.id] = instance

        // Add to user's chain
        var chain = userPluginChains[userId] ?? []
        chain.append(instance.id)
        userPluginChains[userId] = chain

        print("Created VST plugin: \(type.displayName) for user \(userId)")
        return instance
    }

    private func setupAudioNodes(for instance: VSTPluginInstance) {
        guard let engine = audioEngine else { return }

        instance.inputNode = AVAudioMixerNode()
        instance.outputNode = AVAudioMixerNode()

        guard let inputNode = instance.inputNode, let outputNode = instance.outputNode else { return }

        engine.attach(inputNode)
        engine.attach(outputNode)

        // Create effect node based on type
        switch instance.pluginType {
        case .reverb:
            let reverb = AVAudioUnitReverb()
            reverb.loadFactoryPreset(.mediumHall)
            reverb.wetDryMix = 30
            instance.reverbNode = reverb
            engine.attach(reverb)
            engine.connect(inputNode, to: reverb, format: nil)
            engine.connect(reverb, to: outputNode, format: nil)

        case .delay:
            let delay = AVAudioUnitDelay()
            delay.delayTime = 0.25
            delay.feedback = 30
            delay.wetDryMix = 30
            instance.delayNode = delay
            engine.attach(delay)
            engine.connect(inputNode, to: delay, format: nil)
            engine.connect(delay, to: outputNode, format: nil)

        case .distortion:
            let distortion = AVAudioUnitDistortion()
            distortion.loadFactoryPreset(.drumsBitBrush)
            distortion.wetDryMix = 50
            instance.distortionNode = distortion
            engine.attach(distortion)
            engine.connect(inputNode, to: distortion, format: nil)
            engine.connect(distortion, to: outputNode, format: nil)

        case .eq:
            let eq = AVAudioUnitEQ(numberOfBands: 5)
            // Setup 5-band EQ
            let frequencies: [Float] = [80, 250, 1000, 4000, 12000]
            for (index, freq) in frequencies.enumerated() {
                eq.bands[index].frequency = freq
                eq.bands[index].bandwidth = 1.0
                eq.bands[index].gain = 0
                eq.bands[index].bypass = false
                eq.bands[index].filterType = index == 0 ? .lowShelf :
                                              index == 4 ? .highShelf : .parametric
            }
            instance.eqNode = eq
            engine.attach(eq)
            engine.connect(inputNode, to: eq, format: nil)
            engine.connect(eq, to: outputNode, format: nil)

        default:
            // For types without built-in nodes, connect input directly to output
            engine.connect(inputNode, to: outputNode, format: nil)
        }

        // Connect output to main mixer
        if let mixer = mainMixer {
            engine.connect(outputNode, to: mixer, format: nil)
        }
    }

    func removePlugin(instanceId: String) {
        guard let instance = pluginInstances[instanceId] else { return }
        guard let engine = audioEngine else { return }

        // Stop streaming if active
        stopStreaming(instanceId: instanceId)

        // Detach audio nodes
        if let inputNode = instance.inputNode {
            engine.detach(inputNode)
        }
        if let outputNode = instance.outputNode {
            engine.detach(outputNode)
        }
        if let reverbNode = instance.reverbNode {
            engine.detach(reverbNode)
        }
        if let delayNode = instance.delayNode {
            engine.detach(delayNode)
        }
        if let distortionNode = instance.distortionNode {
            engine.detach(distortionNode)
        }
        if let eqNode = instance.eqNode {
            engine.detach(eqNode)
        }

        // Remove from collections
        pluginInstances.removeValue(forKey: instanceId)

        // Remove from user chain
        for (userId, var chain) in userPluginChains {
            chain.removeAll { $0 == instanceId }
            userPluginChains[userId] = chain
        }

        print("Removed VST plugin: \(instanceId)")
    }

    func setBypass(instanceId: String, bypassed: Bool) {
        guard let instance = pluginInstances[instanceId] else { return }
        instance.bypassed = bypassed

        // Bypass audio routing
        // In a real implementation, this would route audio around the effect
    }

    // MARK: - Parameter Control

    func setParameter(instanceId: String, parameterName: String, value: Float) {
        guard let instance = pluginInstances[instanceId] else { return }
        instance.setParameter(parameterName, value: value)

        // If streaming, broadcast parameter change
        if instance.isStreaming {
            broadcastParameterChange(instanceId: instanceId, parameter: parameterName, value: value)
        }
    }

    // MARK: - Streaming

    func startStreaming(instanceId: String, targetUserIds: [String]) {
        guard let instance = pluginInstances[instanceId] else { return }

        instance.isStreaming = true
        instance.streamTargets = Set(targetUserIds)

        let streamId = "\(instanceId)_\(Date().timeIntervalSince1970)"
        let stream = VSTStream(
            id: streamId,
            vstInstanceId: instanceId,
            targetUsers: Set(targetUserIds)
        )

        activeStreams[streamId] = stream

        // Setup audio capture from plugin output
        setupStreamCapture(for: stream, instance: instance)

        print("Started VST streaming: \(instance.pluginType.displayName) to \(targetUserIds.count) users")
    }

    private func setupStreamCapture(for stream: VSTStream, instance: VSTPluginInstance) {
        guard let outputNode = instance.outputNode else { return }

        let format = outputNode.outputFormat(forBus: 0)

        outputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(streamConfig.bufferSize), format: format) { [weak self] buffer, time in
            self?.processStreamBuffer(buffer, streamId: stream.id)
        }
    }

    private func processStreamBuffer(_ buffer: AVAudioPCMBuffer, streamId: String) {
        guard let stream = activeStreams[streamId] else { return }
        guard stream.isActive else { return }

        // Convert buffer to data for streaming
        guard let channelData = buffer.floatChannelData else { return }

        let frameLength = Int(buffer.frameLength)
        var samples = [Float](repeating: 0, count: frameLength)

        for i in 0..<frameLength {
            samples[i] = channelData[0][i]
        }

        // Create stream packet
        let packet = VSTStreamPacket(
            streamId: streamId,
            samples: samples,
            timestamp: Date().timeIntervalSince1970,
            sampleRate: buffer.format.sampleRate
        )

        // Send to target users
        broadcastStreamPacket(packet, to: stream.targetUsers)
    }

    private func broadcastStreamPacket(_ packet: VSTStreamPacket, to users: Set<String>) {
        // Send via ServerManager's socket
        // This would be integrated with the existing WebSocket/WebRTC system

        for userId in users {
            // In a real implementation, this would send via Socket.IO or WebRTC
            print("Sending VST stream packet to user: \(userId)")
        }
    }

    func stopStreaming(instanceId: String) {
        guard let instance = pluginInstances[instanceId] else { return }

        instance.isStreaming = false
        instance.streamTargets.removeAll()

        // Remove tap
        instance.outputNode?.removeTap(onBus: 0)

        // Remove active streams for this instance
        let streamsToRemove = activeStreams.filter { $0.value.vstInstanceId == instanceId }
        for (streamId, _) in streamsToRemove {
            activeStreams.removeValue(forKey: streamId)
        }

        print("Stopped VST streaming: \(instanceId)")
    }

    // MARK: - Receiving Streams

    func handleIncomingStream(_ packet: VSTStreamPacket) {
        // Convert samples back to audio buffer
        guard let engine = audioEngine else { return }

        let format = AVAudioFormat(standardFormatWithSampleRate: packet.sampleRate, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(packet.samples.count)) else { return }

        buffer.frameLength = AVAudioFrameCount(packet.samples.count)

        if let channelData = buffer.floatChannelData {
            for (index, sample) in packet.samples.enumerated() {
                channelData[0][index] = sample
            }
        }

        // Play the received stream
        playReceivedStream(buffer)
    }

    private func playReceivedStream(_ buffer: AVAudioPCMBuffer) {
        guard let engine = audioEngine else { return }

        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: buffer.format)

        playerNode.scheduleBuffer(buffer, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                engine.detach(playerNode)
            }
        })

        playerNode.play()
    }

    private func broadcastParameterChange(instanceId: String, parameter: String, value: Float) {
        guard let instance = pluginInstances[instanceId] else { return }

        let change = VSTParameterChange(
            instanceId: instanceId,
            parameter: parameter,
            value: value,
            timestamp: Date().timeIntervalSince1970
        )

        for userId in instance.streamTargets {
            // Send via socket
            print("Broadcasting parameter change to \(userId): \(parameter) = \(value)")
        }
    }

    // MARK: - Preset Management

    private func initializeFactoryPresets() {
        // Reverb presets
        presets.append(VSTPreset(name: "Small Room", pluginType: "reverb", parameters: [
            "Room Size": 0.2, "Damping": 0.5, "Wet Level": 0.2, "Dry Level": 0.8
        ], isFactoryPreset: true))

        presets.append(VSTPreset(name: "Large Hall", pluginType: "reverb", parameters: [
            "Room Size": 0.8, "Damping": 0.2, "Wet Level": 0.4, "Dry Level": 0.6
        ], isFactoryPreset: true))

        // Compressor presets
        presets.append(VSTPreset(name: "Gentle Compression", pluginType: "compressor", parameters: [
            "Threshold": -20, "Ratio": 2, "Attack": 10, "Release": 200, "Makeup Gain": 3
        ], isFactoryPreset: true))

        presets.append(VSTPreset(name: "Heavy Compression", pluginType: "compressor", parameters: [
            "Threshold": -30, "Ratio": 8, "Attack": 1, "Release": 100, "Makeup Gain": 6
        ], isFactoryPreset: true))

        // EQ presets
        presets.append(VSTPreset(name: "Voice Clarity", pluginType: "eq", parameters: [
            "Low Gain": -3, "Low Mid Gain": 0, "Mid Gain": 2, "High Mid Gain": 3, "High Gain": 1
        ], isFactoryPreset: true))

        presets.append(VSTPreset(name: "Bass Boost", pluginType: "eq", parameters: [
            "Low Gain": 6, "Low Mid Gain": 3, "Mid Gain": 0, "High Mid Gain": -1, "High Gain": 0
        ], isFactoryPreset: true))

        // Delay presets
        presets.append(VSTPreset(name: "Slap Back", pluginType: "delay", parameters: [
            "Delay Time": 80, "Feedback": 0.1, "Wet Level": 0.3, "Low Cut": 100, "High Cut": 8000
        ], isFactoryPreset: true))

        presets.append(VSTPreset(name: "Long Echo", pluginType: "delay", parameters: [
            "Delay Time": 500, "Feedback": 0.5, "Wet Level": 0.4, "Low Cut": 200, "High Cut": 6000
        ], isFactoryPreset: true))
    }

    func savePreset(name: String, instanceId: String) {
        guard let instance = pluginInstances[instanceId] else { return }

        var params: [String: Float] = [:]
        for param in instance.parameters {
            params[param.name] = param.value
        }

        let preset = VSTPreset(
            name: name,
            pluginType: instance.pluginType.rawValue,
            parameters: params,
            isFactoryPreset: false
        )

        presets.append(preset)
        savePresets()
    }

    func loadPreset(_ preset: VSTPreset, instanceId: String) {
        guard let instance = pluginInstances[instanceId] else { return }
        guard preset.pluginType == instance.pluginType.rawValue else { return }

        for (name, value) in preset.parameters {
            setParameter(instanceId: instanceId, parameterName: name, value: value)
        }
    }

    func deletePreset(_ preset: VSTPreset) {
        guard !preset.isFactoryPreset else { return }
        presets.removeAll { $0.id == preset.id }
        savePresets()
    }

    private func loadPresets() {
        if let data = UserDefaults.standard.data(forKey: "vst.presets"),
           let loaded = try? JSONDecoder().decode([VSTPreset].self, from: data) {
            presets = loaded
        }
    }

    private func savePresets() {
        let userPresets = presets.filter { !$0.isFactoryPreset }
        if let data = try? JSONEncoder().encode(userPresets) {
            UserDefaults.standard.set(data, forKey: "vst.presets")
        }
    }

    // MARK: - User Plugin Chain Management

    func getUserPlugins(userId: String) -> [VSTPluginInstance] {
        guard let chain = userPluginChains[userId] else { return [] }
        return chain.compactMap { pluginInstances[$0] }
    }

    func reorderPlugins(userId: String, fromIndex: Int, toIndex: Int) {
        guard var chain = userPluginChains[userId] else { return }
        guard fromIndex < chain.count, toIndex < chain.count else { return }

        let plugin = chain.remove(at: fromIndex)
        chain.insert(plugin, at: toIndex)
        userPluginChains[userId] = chain

        // Reconnect audio nodes in new order
        reconnectUserPluginChain(userId: userId)
    }

    private func reconnectUserPluginChain(userId: String) {
        // In a real implementation, this would rewire the audio nodes
        // to reflect the new plugin order
    }

    // MARK: - AUv3 Plugin Loading (for external plugins)

    func loadAUv3Plugin(identifier: String, userId: String) async throws -> VSTPluginInstance? {
        let componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0,
            componentManufacturer: 0,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        return try await withCheckedThrowingContinuation { continuation in
            AVAudioUnitComponentManager.shared().components(matching: componentDescription)
                .first { $0.audioComponentDescription.componentSubType != 0 }
                .map { component in
                    AVAudioUnit.instantiate(with: component.audioComponentDescription, options: []) { audioUnit, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                            return
                        }

                        guard let audioUnit = audioUnit else {
                            continuation.resume(throwing: NSError(domain: "VSTEngine", code: 1, userInfo: nil))
                            return
                        }

                        let instance = VSTPluginInstance(pluginType: .reverb, userId: userId)
                        instance.audioUnit = audioUnit

                        // Attach to engine
                        self.audioEngine?.attach(audioUnit)

                        self.pluginInstances[instance.id] = instance
                        continuation.resume(returning: instance)
                    }
                }
        }
    }

    func getAvailableAUv3Plugins() -> [AVAudioUnitComponent] {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0,
            componentManufacturer: 0,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        return AVAudioUnitComponentManager.shared().components(matching: description)
    }
}

// MARK: - Supporting Types

struct VSTStream {
    let id: String
    let vstInstanceId: String
    var targetUsers: Set<String>
    var isActive: Bool = true
    var startTime: Date = Date()
}

struct VSTStreamPacket: Codable {
    let streamId: String
    let samples: [Float]
    let timestamp: Double
    let sampleRate: Double
}

struct VSTParameterChange: Codable {
    let instanceId: String
    let parameter: String
    let value: Float
    let timestamp: Double
}

// MARK: - VST Plugin View
struct VSTPluginView: View {
    @ObservedObject var instance: VSTPluginInstance
    @ObservedObject var engine = VSTStreamingEngine.shared
    @State private var showPresets = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: instance.pluginType.icon)
                    .font(.title2)
                Text(instance.pluginType.displayName)
                    .font(.headline)

                Spacer()

                // Bypass toggle
                Toggle("", isOn: Binding(
                    get: { !instance.bypassed },
                    set: { engine.setBypass(instanceId: instance.id, bypassed: !$0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()

                // Stream button
                Button(action: toggleStreaming) {
                    Image(systemName: instance.isStreaming ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                }
                .foregroundColor(instance.isStreaming ? .green : .gray)
                .help(instance.isStreaming ? "Stop streaming" : "Start streaming")

                // Presets button
                Button(action: { showPresets = true }) {
                    Image(systemName: "slider.horizontal.2.gobackward")
                }
                .popover(isPresented: $showPresets) {
                    VSTPresetListView(instance: instance)
                }

                // Remove button
                Button(action: { engine.removePlugin(instanceId: instance.id) }) {
                    Image(systemName: "xmark.circle")
                        .foregroundColor(.red)
                }
            }

            Divider()

            // Parameters
            ForEach($instance.parameters) { $param in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(param.name)
                            .font(.caption)
                        Spacer()
                        Text("\(param.value, specifier: "%.1f")\(param.unit)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Slider(value: $param.value, in: param.minValue...param.maxValue)
                        .onChange(of: param.value) { newValue in
                            engine.setParameter(instanceId: instance.id, parameterName: param.name, value: newValue)
                        }
                }
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }

    private func toggleStreaming() {
        if instance.isStreaming {
            engine.stopStreaming(instanceId: instance.id)
        } else {
            // Get current room users as targets
            let targets = ServerManager.shared.currentRoomUsers.map { $0.id }
            engine.startStreaming(instanceId: instance.id, targetUserIds: targets)
        }
    }
}

// MARK: - VST Preset List View
struct VSTPresetListView: View {
    @ObservedObject var instance: VSTPluginInstance
    @ObservedObject var engine = VSTStreamingEngine.shared
    @State private var newPresetName = ""
    @Environment(\.dismiss) var dismiss

    var filteredPresets: [VSTPreset] {
        engine.presets.filter { $0.pluginType == instance.pluginType.rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Presets")
                .font(.headline)

            // Preset list
            List {
                ForEach(filteredPresets) { preset in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(preset.name)
                                .font(.subheadline)
                            if preset.isFactoryPreset {
                                Text("Factory")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()

                        Button("Load") {
                            engine.loadPreset(preset, instanceId: instance.id)
                            dismiss()
                        }
                        .buttonStyle(.bordered)

                        if !preset.isFactoryPreset {
                            Button(action: { engine.deletePreset(preset) }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(height: 200)

            Divider()

            // Save new preset
            HStack {
                TextField("Preset name", text: $newPresetName)
                    .textFieldStyle(.roundedBorder)

                Button("Save") {
                    guard !newPresetName.isEmpty else { return }
                    engine.savePreset(name: newPresetName, instanceId: instance.id)
                    newPresetName = ""
                }
                .disabled(newPresetName.isEmpty)
            }
        }
        .padding()
        .frame(width: 300)
    }
}

// MARK: - VST Chain View
struct VSTChainView: View {
    let userId: String
    @ObservedObject var engine = VSTStreamingEngine.shared
    @State private var showAddPlugin = false

    var userPlugins: [VSTPluginInstance] {
        engine.getUserPlugins(userId: userId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Effect Chain")
                    .font(.headline)

                Spacer()

                Button(action: { showAddPlugin = true }) {
                    Label("Add Effect", systemImage: "plus")
                }
                .popover(isPresented: $showAddPlugin) {
                    AddVSTPluginView(userId: userId)
                }
            }

            if userPlugins.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.badge.plus")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No effects added")
                        .foregroundColor(.secondary)
                    Text("Add effects to process your audio")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(userPlugins) { plugin in
                            VSTPluginView(instance: plugin)
                        }
                    }
                }
            }
        }
        .padding()
    }
}

// MARK: - Add VST Plugin View
struct AddVSTPluginView: View {
    let userId: String
    @ObservedObject var engine = VSTStreamingEngine.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Effect")
                .font(.headline)

            List {
                ForEach(VSTPluginType.allCases) { type in
                    Button(action: {
                        _ = engine.createPlugin(type: type, userId: userId)
                        dismiss()
                    }) {
                        HStack {
                            Image(systemName: type.icon)
                                .frame(width: 30)
                            VStack(alignment: .leading) {
                                Text(type.displayName)
                                    .font(.subheadline)
                                Text(type.category)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 300)
        }
        .padding()
        .frame(width: 250)
    }
}
