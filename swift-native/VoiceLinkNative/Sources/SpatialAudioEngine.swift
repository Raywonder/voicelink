import Foundation
import AVFoundation
import Accelerate

// MARK: - Spatial Audio Engine
/// 3D binaural audio processing for immersive voice chat with HRTF support

class SpatialAudioEngine: ObservableObject {
    static let shared = SpatialAudioEngine()

    // Audio engine components
    private var audioEngine: AVAudioEngine?
    private var environmentNode: AVAudioEnvironmentNode?
    private var playerNodes: [String: AVAudioPlayerNode] = [:]
    private var spatialMixers: [String: AVAudioMixerNode] = [:]

    // User positions in 3D space
    @Published var userPositions: [String: SIMD3<Float>] = [:]
    @Published var listenerPosition: SIMD3<Float> = .zero
    @Published var listenerOrientation: SIMD3<Float> = SIMD3<Float>(0, 0, -1) // Forward

    // Settings
    @Published var isEnabled: Bool = true
    @Published var roomModel: RoomAcousticModel = .largeRoom
    @Published var distanceModel: DistanceAttenuationModel = .inverse
    @Published var reverbLevel: Float = 0.3
    @Published var rolloffFactor: Float = 1.0
    @Published var referenceDistance: Float = 1.0
    @Published var maxDistance: Float = 20.0

    // HRTF Data
    private var hrtfDatabase: HRTFDatabase?
    private var hrtfEnabled: Bool = true

    // Room acoustic parameters
    enum RoomAcousticModel: String, CaseIterable, Identifiable {
        case none = "none"
        case smallRoom = "small_room"
        case mediumRoom = "medium_room"
        case largeRoom = "large_room"
        case hall = "hall"
        case cathedral = "cathedral"
        case outdoor = "outdoor"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .none: return "No Reverb"
            case .smallRoom: return "Small Room"
            case .mediumRoom: return "Medium Room"
            case .largeRoom: return "Large Room"
            case .hall: return "Concert Hall"
            case .cathedral: return "Cathedral"
            case .outdoor: return "Outdoor"
            }
        }

        var reverbPreset: AVAudioUnitReverbPreset {
            switch self {
            case .none: return .smallRoom
            case .smallRoom: return .smallRoom
            case .mediumRoom: return .mediumRoom
            case .largeRoom: return .largeRoom
            case .hall: return .largeHall
            case .cathedral: return .cathedral
            case .outdoor: return .plate
            }
        }

        var decayTime: Float {
            switch self {
            case .none: return 0.0
            case .smallRoom: return 0.3
            case .mediumRoom: return 0.5
            case .largeRoom: return 0.8
            case .hall: return 1.5
            case .cathedral: return 2.5
            case .outdoor: return 0.1
            }
        }
    }

    enum DistanceAttenuationModel: String, CaseIterable, Identifiable {
        case linear = "linear"
        case inverse = "inverse"
        case exponential = "exponential"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .linear: return "Linear"
            case .inverse: return "Inverse (Realistic)"
            case .exponential: return "Exponential"
            }
        }

        var avModel: AVAudioEnvironmentDistanceAttenuationModel {
            switch self {
            case .linear: return .linear
            case .inverse: return .inverse
            case .exponential: return .exponential
            }
        }
    }

    init() {
        setupAudioEngine()
        loadHRTFDatabase()
        setupAudioControlObservers()
    }

    // MARK: - Setup

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()

        guard let engine = audioEngine else { return }

        // Create environment node for 3D audio
        environmentNode = AVAudioEnvironmentNode()

        guard let envNode = environmentNode else { return }

        // Configure environment
        envNode.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        envNode.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)
        envNode.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        envNode.distanceAttenuationParameters.referenceDistance = referenceDistance
        envNode.distanceAttenuationParameters.maximumDistance = maxDistance
        envNode.distanceAttenuationParameters.rolloffFactor = rolloffFactor

        // Configure reverb
        envNode.reverbParameters.enable = roomModel != .none
        envNode.reverbParameters.level = reverbLevel * 100
        envNode.reverbParameters.loadFactoryReverbPreset(roomModel.reverbPreset)

        // Enable HRTF rendering
        envNode.renderingAlgorithm = .HRTFHQ

        // Attach to engine
        engine.attach(envNode)
        engine.connect(envNode, to: engine.mainMixerNode, format: nil)

        print("[SpatialAudio] Engine configured with HRTF")
    }

    func start() throws {
        guard let engine = audioEngine else {
            throw SpatialAudioError.engineNotInitialized
        }

        if !engine.isRunning {
            try engine.start()
            print("[SpatialAudio] Engine started")
        }
    }

    func stop() {
        audioEngine?.stop()
        print("[SpatialAudio] Engine stopped")
    }

    // MARK: - HRTF Database

    private func loadHRTFDatabase() {
        // Load HRTF data for accurate 3D positioning
        hrtfDatabase = HRTFDatabase()
        print("[SpatialAudio] HRTF database loaded")
    }

    private func setupAudioControlObservers() {
        NotificationCenter.default.addObserver(
            forName: .userVolumeChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userId = notification.userInfo?["userId"] as? String else { return }
            self?.applyUserVolume(userId: userId)
        }

        NotificationCenter.default.addObserver(
            forName: .userMuteChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userId = notification.userInfo?["userId"] as? String else { return }
            self?.applyUserVolume(userId: userId)
        }

        NotificationCenter.default.addObserver(
            forName: .userSoloChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAllUserVolumes()
        }

        NotificationCenter.default.addObserver(
            forName: .userMasterVolumeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAllUserVolumes()
        }
    }

    // MARK: - User Audio Management

    /// Add a user's audio stream to the spatial environment
    func addUserAudio(userId: String, audioBuffer: AVAudioPCMBuffer) {
        guard isEnabled, let engine = audioEngine, let envNode = environmentNode else { return }

        // Create player node if not exists
        if playerNodes[userId] == nil {
            let playerNode = AVAudioPlayerNode()
            let mixerNode = AVAudioMixerNode()

            engine.attach(playerNode)
            engine.attach(mixerNode)

            // Connect: playerNode -> mixerNode -> environmentNode
            engine.connect(playerNode, to: mixerNode, format: audioBuffer.format)
            engine.connect(mixerNode, to: envNode, format: audioBuffer.format)

            playerNodes[userId] = playerNode
            spatialMixers[userId] = mixerNode

            // Set default position
            if userPositions[userId] == nil {
                userPositions[userId] = SIMD3<Float>(0, 0, -2) // In front of listener
            }

            playerNode.play()
        }

        applyUserVolume(userId: userId)

        // Update position
        updateUserPosition(userId: userId)

        // Schedule buffer for playback
        if let playerNode = playerNodes[userId] {
            playerNode.scheduleBuffer(audioBuffer, completionHandler: nil)
        }
    }

    /// Remove a user's audio from the spatial environment
    func removeUserAudio(userId: String) {
        guard let engine = audioEngine else { return }

        if let playerNode = playerNodes[userId] {
            playerNode.stop()
            engine.detach(playerNode)
            playerNodes.removeValue(forKey: userId)
        }

        if let mixerNode = spatialMixers[userId] {
            engine.detach(mixerNode)
            spatialMixers.removeValue(forKey: userId)
        }

        userPositions.removeValue(forKey: userId)
    }

    // MARK: - Volume / Mute / Solo

    private func applyAllUserVolumes() {
        for userId in spatialMixers.keys {
            applyUserVolume(userId: userId)
        }
    }

    private func applyUserVolume(userId: String) {
        guard let mixerNode = spatialMixers[userId] else { return }
        let audioControl = UserAudioControlManager.shared

        let isMuted = audioControl.isMuted(userId)
        let baseVolume = audioControl.getVolume(for: userId) * audioControl.masterVolume
        let soloedId = audioControl.soloedUserId

        let effectiveVolume: Float
        if let soloedId = soloedId {
            effectiveVolume = (soloedId == userId && !isMuted) ? baseVolume : 0.0
        } else {
            effectiveVolume = isMuted ? 0.0 : baseVolume
        }

        mixerNode.outputVolume = max(0.0, min(2.0, effectiveVolume))
    }

    // MARK: - Position Management

    /// Update a user's position in 3D space
    func setUserPosition(userId: String, position: SIMD3<Float>) {
        userPositions[userId] = position
        updateUserPosition(userId: userId)
    }

    /// Update a user's position from polar coordinates (angle, distance)
    func setUserPositionPolar(userId: String, angle: Float, distance: Float, elevation: Float = 0) {
        let x = distance * sin(angle * .pi / 180)
        let y = elevation
        let z = -distance * cos(angle * .pi / 180) // Negative Z is forward

        setUserPosition(userId: userId, position: SIMD3<Float>(x, y, z))
    }

    private func updateUserPosition(userId: String) {
        guard let mixerNode = spatialMixers[userId],
              let position = userPositions[userId] else { return }

        // Set 3D position on mixer node
        mixerNode.position = AVAudio3DPoint(x: position.x, y: position.y, z: position.z)
    }

    /// Update listener position
    func setListenerPosition(_ position: SIMD3<Float>) {
        listenerPosition = position
        environmentNode?.listenerPosition = AVAudio3DPoint(x: position.x, y: position.y, z: position.z)
    }

    /// Update listener orientation (yaw, pitch, roll in degrees)
    func setListenerOrientation(yaw: Float, pitch: Float, roll: Float) {
        environmentNode?.listenerAngularOrientation = AVAudio3DAngularOrientation(
            yaw: yaw,
            pitch: pitch,
            roll: roll
        )
    }

    // MARK: - Room Acoustics

    func setRoomModel(_ model: RoomAcousticModel) {
        roomModel = model

        guard let envNode = environmentNode else { return }

        envNode.reverbParameters.enable = model != .none
        if model != .none {
            envNode.reverbParameters.loadFactoryReverbPreset(model.reverbPreset)
            envNode.reverbParameters.level = reverbLevel * 100
        }
    }

    func setReverbLevel(_ level: Float) {
        reverbLevel = max(0, min(1, level))
        environmentNode?.reverbParameters.level = reverbLevel * 100
    }

    // MARK: - Distance Attenuation

    func setDistanceModel(_ model: DistanceAttenuationModel) {
        distanceModel = model
        environmentNode?.distanceAttenuationParameters.distanceAttenuationModel = model.avModel
    }

    func setRolloffFactor(_ factor: Float) {
        rolloffFactor = factor
        environmentNode?.distanceAttenuationParameters.rolloffFactor = factor
    }

    func setReferenceDistance(_ distance: Float) {
        referenceDistance = distance
        environmentNode?.distanceAttenuationParameters.referenceDistance = distance
    }

    func setMaxDistance(_ distance: Float) {
        maxDistance = distance
        environmentNode?.distanceAttenuationParameters.maximumDistance = distance
    }

    // MARK: - Rendering Algorithm

    func setRenderingAlgorithm(_ algorithm: AVAudio3DMixingRenderingAlgorithm) {
        environmentNode?.renderingAlgorithm = algorithm
    }

    func enableHRTF(_ enabled: Bool) {
        hrtfEnabled = enabled
        if enabled {
            environmentNode?.renderingAlgorithm = .HRTFHQ
        } else {
            environmentNode?.renderingAlgorithm = .equalPowerPanning
        }
    }

    // MARK: - Utility

    /// Calculate distance between two positions
    func distance(from: SIMD3<Float>, to: SIMD3<Float>) -> Float {
        return simd_distance(from, to)
    }

    /// Calculate angle from listener to a position (in degrees)
    func angle(to position: SIMD3<Float>) -> Float {
        let delta = position - listenerPosition
        return atan2(delta.x, -delta.z) * 180 / .pi
    }

    /// Get all user positions as dictionary for UI
    func getUserPositionsForUI() -> [String: (angle: Float, distance: Float)] {
        var result: [String: (angle: Float, distance: Float)] = [:]

        for (userId, position) in userPositions {
            let dist = distance(from: listenerPosition, to: position)
            let ang = angle(to: position)
            result[userId] = (angle: ang, distance: dist)
        }

        return result
    }
}

// MARK: - HRTF Database

class HRTFDatabase {
    // Head-Related Transfer Function data
    // In a full implementation, this would load measured HRTF data

    private var leftEarFilters: [Float: [Float]] = [:]
    private var rightEarFilters: [Float: [Float]] = [:]

    init() {
        // Generate synthetic HRTF data for common angles
        generateSyntheticHRTF()
    }

    private func generateSyntheticHRTF() {
        // Generate basic ITD (Interaural Time Difference) and ILD (Interaural Level Difference)
        // For angles from -180 to 180 degrees
        for angle in stride(from: -180, through: 180, by: 15) {
            let angleRad = Float(angle) * .pi / 180

            // Simple HRTF model based on angle
            let leftGain = cos((angleRad + .pi/2) / 2)
            let rightGain = cos((angleRad - .pi/2) / 2)

            leftEarFilters[Float(angle)] = [leftGain]
            rightEarFilters[Float(angle)] = [rightGain]
        }
    }

    func getFilters(forAngle angle: Float) -> (left: [Float], right: [Float]) {
        // Find nearest angle
        let nearestAngle = round(angle / 15) * 15
        let clampedAngle = max(-180, min(180, nearestAngle))

        let left = leftEarFilters[clampedAngle] ?? [1.0]
        let right = rightEarFilters[clampedAngle] ?? [1.0]

        return (left, right)
    }
}

// MARK: - Errors

enum SpatialAudioError: Error {
    case engineNotInitialized
    case userNotFound
    case invalidPosition
}

// MARK: - Spatial Audio Settings View

import SwiftUI

struct SpatialAudioSettingsView: View {
    @ObservedObject var spatialEngine = SpatialAudioEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Enable/Disable
            Toggle("Enable 3D Spatial Audio", isOn: $spatialEngine.isEnabled)

            if spatialEngine.isEnabled {
                // Room Model
                VStack(alignment: .leading, spacing: 8) {
                    Text("Room Acoustics")
                        .font(.headline)

                    Picker("Room Type", selection: $spatialEngine.roomModel) {
                        ForEach(SpatialAudioEngine.RoomAcousticModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: spatialEngine.roomModel) { newValue in
                        spatialEngine.setRoomModel(newValue)
                    }

                    HStack {
                        Text("Reverb Level")
                        Slider(value: $spatialEngine.reverbLevel, in: 0...1)
                            .onChange(of: spatialEngine.reverbLevel) { newValue in
                                spatialEngine.setReverbLevel(newValue)
                            }
                        Text("\(Int(spatialEngine.reverbLevel * 100))%")
                            .frame(width: 40)
                    }
                }

                Divider()

                // Distance Model
                VStack(alignment: .leading, spacing: 8) {
                    Text("Distance Attenuation")
                        .font(.headline)

                    Picker("Model", selection: $spatialEngine.distanceModel) {
                        ForEach(SpatialAudioEngine.DistanceAttenuationModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: spatialEngine.distanceModel) { newValue in
                        spatialEngine.setDistanceModel(newValue)
                    }

                    HStack {
                        Text("Rolloff Factor")
                        Slider(value: $spatialEngine.rolloffFactor, in: 0.1...3.0)
                            .onChange(of: spatialEngine.rolloffFactor) { newValue in
                                spatialEngine.setRolloffFactor(newValue)
                            }
                        Text(String(format: "%.1f", spatialEngine.rolloffFactor))
                            .frame(width: 40)
                    }

                    HStack {
                        Text("Max Distance")
                        Slider(value: $spatialEngine.maxDistance, in: 5...100)
                            .onChange(of: spatialEngine.maxDistance) { newValue in
                                spatialEngine.setMaxDistance(newValue)
                            }
                        Text("\(Int(spatialEngine.maxDistance))m")
                            .frame(width: 40)
                    }
                }

                Divider()

                // HRTF Toggle
                VStack(alignment: .leading, spacing: 8) {
                    Text("HRTF Processing")
                        .font(.headline)

                    Toggle("Enable HRTF (Head-Related Transfer Function)", isOn: Binding(
                        get: { true },
                        set: { spatialEngine.enableHRTF($0) }
                    ))

                    Text("HRTF provides realistic 3D audio positioning using binaural processing")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
        }
        .padding()
    }
}

// MARK: - Spatial Audio Visualizer

struct SpatialAudioVisualizerView: View {
    @ObservedObject var spatialEngine = SpatialAudioEngine.shared
    let userColors: [String: Color] = [:]

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius = min(geometry.size.width, geometry.size.height) / 2 - 40

            ZStack {
                // Background circles (distance rings)
                ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { scale in
                    Circle()
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                        .frame(width: radius * 2 * scale, height: radius * 2 * scale)
                }

                // Direction indicators
                ForEach([0, 90, 180, 270], id: \.self) { angle in
                    let radians = CGFloat(angle) * .pi / 180
                    let x = center.x + cos(radians - .pi/2) * radius
                    let y = center.y + sin(radians - .pi/2) * radius

                    Text(directionLabel(for: angle))
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .position(x: x, y: y)
                }

                // Listener (center)
                Circle()
                    .fill(Color.blue)
                    .frame(width: 20, height: 20)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.caption)
                            .foregroundColor(.white)
                    )
                    .position(center)

                // User positions
                ForEach(Array(spatialEngine.userPositions.keys), id: \.self) { userId in
                    if let position = spatialEngine.userPositions[userId] {
                        let normalizedDist = min(1.0, CGFloat(simd_distance(spatialEngine.listenerPosition, position)) / CGFloat(spatialEngine.maxDistance))
                        let angle = CGFloat(spatialEngine.angle(to: position)) * .pi / 180

                        let x = center.x + sin(angle) * radius * normalizedDist
                        let y = center.y - cos(angle) * radius * normalizedDist

                        Circle()
                            .fill(Color.green)
                            .frame(width: 16, height: 16)
                            .overlay(
                                Text(String(userId.prefix(1)))
                                    .font(.caption2)
                                    .foregroundColor(.white)
                            )
                            .position(x: x, y: y)
                    }
                }
            }
        }
        .background(Color.black.opacity(0.1))
        .cornerRadius(10)
    }

    private func directionLabel(for angle: Int) -> String {
        switch angle {
        case 0: return "Front"
        case 90: return "Right"
        case 180: return "Back"
        case 270: return "Left"
        default: return ""
        }
    }
}
