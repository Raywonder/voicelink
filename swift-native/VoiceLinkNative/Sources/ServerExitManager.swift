import Foundation
import SwiftUI
import AVFoundation

// MARK: - Server Exit Manager
// Handles graceful server shutdown with room transfer options

class ServerExitManager: ObservableObject {
    static let shared = ServerExitManager()

    @Published var isExitInProgress = false
    @Published var exitProgress: ExitProgress = .idle
    @Published var showExitAlert = false
    @Published var transferStatus: TransferStatus?
    @Published var waitingRoomActive = false

    // Audio players for sound effects
    private var wooshPlayer: AVAudioPlayer?
    private var ambiencePlayer: AVAudioPlayer?

    // Managers
    private let serverManager = ServerModeManager.shared
    private let roomManager = RoomManager.shared
    private let pairingManager = PairingManager.shared
    private let deviceManager = ServerDeviceManager.shared

    // Waiting room settings
    static let waitingRoomTimeout: TimeInterval = 300  // 5 minutes default
    static let autoMoveTimeout: TimeInterval = 180     // 3 minutes auto-move
    private var waitingRoomTimer: Timer?
    private var autoMoveTimer: Timer?

    init() {
        setupAudioPlayers()
    }

    // MARK: - Exit Progress States

    enum ExitProgress: Equatable {
        case idle
        case showingOptions
        case transferringToDevice
        case transferringToFederated
        case movingToWaitingRoom
        case waitingForRestart
        case shuttingDown
        case complete
        case error(String)

        var description: String {
            switch self {
            case .idle: return ""
            case .showingOptions: return "Choosing exit option..."
            case .transferringToDevice: return "Transferring rooms to your other device..."
            case .transferringToFederated: return "Transferring to federated server..."
            case .movingToWaitingRoom: return "Moving users to waiting room..."
            case .waitingForRestart: return "Waiting room active - restart to resume"
            case .shuttingDown: return "Shutting down server..."
            case .complete: return "Exit complete"
            case .error(let msg): return "Error: \(msg)"
            }
        }
    }

    // MARK: - Exit Options

    enum ExitOption: String, CaseIterable {
        case transferToDevice = "Transfer to Another Device"
        case transferToFederated = "Transfer to Federated Server"
        case waitingRoom = "Put Users in Waiting Room"
        case autoMove = "Auto-Move After Timeout"
        case justExit = "Just Exit (Users Disconnected)"
        case systemReboot = "Reboot Device (If Stuck)"

        var icon: String {
            switch self {
            case .transferToDevice: return "laptopcomputer.and.iphone"
            case .transferToFederated: return "globe"
            case .waitingRoom: return "hourglass"
            case .autoMove: return "clock.arrow.circlepath"
            case .justExit: return "power"
            case .systemReboot: return "arrow.counterclockwise.circle"
            }
        }

        var description: String {
            switch self {
            case .transferToDevice:
                return "Move all rooms and users to one of your other online devices"
            case .transferToFederated:
                return "Transfer to a random federated server node, keeping rooms if possible"
            case .waitingRoom:
                return "Put users in a peaceful waiting room with ambient music until you restart"
            case .autoMove:
                return "Wait a few minutes, then auto-transfer to next available option"
            case .justExit:
                return "Stop the server immediately - all users will be disconnected"
            case .systemReboot:
                return "Reboot the device if it's stuck - use when other options fail"
            }
        }

        var isDangerous: Bool {
            switch self {
            case .justExit, .systemReboot: return true
            default: return false
            }
        }
    }

    // MARK: - Transfer Status

    struct TransferStatus {
        var totalRooms: Int
        var transferredRooms: Int
        var totalUsers: Int
        var transferredUsers: Int
        var targetDevice: String?
        var targetServer: String?

        var progress: Double {
            guard totalRooms > 0 else { return 0 }
            return Double(transferredRooms) / Double(totalRooms)
        }

        var statusText: String {
            if let device = targetDevice {
                return "Transferring to \(device): \(transferredRooms)/\(totalRooms) rooms"
            } else if let server = targetServer {
                return "Transferring to \(server): \(transferredRooms)/\(totalRooms) rooms"
            }
            return "Preparing transfer..."
        }
    }

    // MARK: - Initiate Exit

    /// Call this when user tries to quit the app while server is running with active rooms
    func initiateGracefulExit() {
        // Check if there are active rooms hosted on this server
        let activeRooms = getActiveHostedRooms()

        if activeRooms.isEmpty {
            // No rooms, just exit normally
            performJustExit()
            return
        }

        // Show exit options alert
        showExitAlert = true
        exitProgress = .showingOptions
    }

    /// Check if server has active rooms that need handling
    func hasActiveRooms() -> Bool {
        return !getActiveHostedRooms().isEmpty
    }

    private func getActiveHostedRooms() -> [PermanentRoom] {
        // Get rooms hosted on this device
        let thisDeviceId = UserDefaults.standard.string(forKey: "clientId") ?? ""
        return roomManager.permanentRooms.filter { $0.hostDeviceId == thisDeviceId && $0.currentMembers > 0 }
    }

    // MARK: - Exit Option Handlers

    func handleExitOption(_ option: ExitOption) {
        showExitAlert = false
        isExitInProgress = true

        switch option {
        case .transferToDevice:
            transferToOtherDevice()
        case .transferToFederated:
            transferToFederatedServer()
        case .waitingRoom:
            moveToWaitingRoom()
        case .autoMove:
            startAutoMoveSequence()
        case .justExit:
            performJustExit()
        case .systemReboot:
            performSystemReboot()
        }
    }

    // MARK: - System Reboot

    private func performSystemReboot() {
        exitProgress = .shuttingDown

        // First try to transfer rooms if possible
        let otherDevices = pairingManager.linkedServers.filter { $0.isOnline && $0.id != currentDeviceId }
        let activeRooms = getActiveHostedRooms()

        if let targetDevice = otherDevices.first, !activeRooms.isEmpty {
            // Quick transfer before reboot
            transferRoomsToDevice(activeRooms, device: targetDevice) { [weak self] _ in
                self?.executeSystemReboot()
            }
        } else {
            // No transfer possible, just reboot
            notifyUsersOfShutdown()
            executeSystemReboot()
        }
    }

    private func executeSystemReboot() {
        // Stop server first
        serverManager.stopServer()

        // Execute system reboot command
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = [
            "-e",
            "tell application \"System Events\" to restart"
        ]

        do {
            try task.run()
        } catch {
            // Fallback: try shutdown command with sudo (will prompt for password)
            let fallbackTask = Process()
            fallbackTask.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            fallbackTask.arguments = [
                "-e",
                "do shell script \"sudo shutdown -r now\" with administrator privileges"
            ]
            try? fallbackTask.run()
        }
    }

    // MARK: - Transfer to Other Device

    private func transferToOtherDevice() {
        exitProgress = .transferringToDevice

        // Find another online device owned by user
        let otherDevices = pairingManager.linkedServers.filter { $0.isOnline && $0.id != currentDeviceId }

        guard let targetDevice = otherDevices.first else {
            // No other devices available
            exitProgress = .error("No other online devices available")
            offerFallbackOptions()
            return
        }

        let activeRooms = getActiveHostedRooms()
        transferStatus = TransferStatus(
            totalRooms: activeRooms.count,
            transferredRooms: 0,
            totalUsers: activeRooms.reduce(0) { $0 + $1.currentMembers },
            transferredUsers: 0,
            targetDevice: targetDevice.name,
            targetServer: nil
        )

        // Transfer each room
        transferRoomsToDevice(activeRooms, device: targetDevice) { [weak self] success in
            if success {
                self?.playWooshSound()
                self?.notifyUsersOfTransfer(to: targetDevice.name)
                self?.exitProgress = .complete
                self?.performDelayedShutdown()
            } else {
                self?.exitProgress = .error("Transfer failed")
                self?.offerFallbackOptions()
            }
        }
    }

    private func transferRoomsToDevice(_ rooms: [PermanentRoom], device: LinkedServer, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(device.url)/api/rooms/transfer-accept") else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(device.accessToken, forHTTPHeaderField: "Authorization")

        let roomsData = rooms.map { room -> [String: Any] in
            return [
                "id": room.id,
                "name": room.name,
                "description": room.description,
                "ownerId": room.ownerId,
                "ownerUsername": room.ownerUsername,
                "isPrivate": room.isPrivate,
                "maxMembers": room.maxMembers,
                "currentMembers": room.currentMembers,
                "hasPassword": room.hasPassword
            ]
        }

        let body: [String: Any] = [
            "rooms": roomsData,
            "sourceDeviceId": currentDeviceId,
            "transferType": "device_exit"
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = json["success"] as? Bool, success else {
                    completion(false)
                    return
                }

                // Update transfer status
                self?.transferStatus?.transferredRooms = rooms.count
                self?.transferStatus?.transferredUsers = rooms.reduce(0) { $0 + $1.currentMembers }

                completion(true)
            }
        }.resume()
    }

    // MARK: - Transfer to Federated Server

    private func transferToFederatedServer() {
        exitProgress = .transferringToFederated

        // Get list of federated servers
        fetchFederatedServers { [weak self] servers in
            guard let targetServer = servers.randomElement() else {
                self?.exitProgress = .error("No federated servers available")
                self?.offerFallbackOptions()
                return
            }

            let activeRooms = self?.getActiveHostedRooms() ?? []
            self?.transferStatus = TransferStatus(
                totalRooms: activeRooms.count,
                transferredRooms: 0,
                totalUsers: activeRooms.reduce(0) { $0 + $1.currentMembers },
                transferredUsers: 0,
                targetDevice: nil,
                targetServer: targetServer.name
            )

            self?.transferRoomsToFederated(activeRooms, server: targetServer) { success in
                if success {
                    self?.playWooshSound()
                    self?.notifyUsersOfFederatedTransfer(to: targetServer.name, sameRoom: true)
                    self?.exitProgress = .complete
                    self?.performDelayedShutdown()
                } else {
                    // Room couldn't be kept, notify of change
                    self?.notifyUsersOfFederatedTransfer(to: targetServer.name, sameRoom: false)
                    self?.exitProgress = .complete
                    self?.performDelayedShutdown()
                }
            }
        }
    }

    private func fetchFederatedServers(completion: @escaping ([FederatedServer]) -> Void) {
        // Fetch from main federation API
        guard let url = URL(string: "https://voicelink.app/api/federation/nodes") else {
            completion([])
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let nodesArray = json["nodes"] as? [[String: Any]] else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            let servers = nodesArray.compactMap { FederatedServer(from: $0) }
            DispatchQueue.main.async { completion(servers) }
        }.resume()
    }

    private func transferRoomsToFederated(_ rooms: [PermanentRoom], server: FederatedServer, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(server.url)/api/rooms/federated-transfer") else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let roomsData = rooms.map { room -> [String: Any] in
            return [
                "id": room.id,
                "name": room.name,
                "description": room.description,
                "ownerId": room.ownerId,
                "ownerUsername": room.ownerUsername,
                "currentMembers": room.currentMembers
            ]
        }

        let body: [String: Any] = [
            "rooms": roomsData,
            "sourceServer": currentDeviceId,
            "preserveRoomIds": true
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = json["success"] as? Bool else {
                    completion(false)
                    return
                }

                self?.transferStatus?.transferredRooms = rooms.count
                completion(success)
            }
        }.resume()
    }

    // MARK: - Waiting Room

    func moveToWaitingRoom() {
        exitProgress = .movingToWaitingRoom
        waitingRoomActive = true

        // Start ambient music
        playMeditationAmbience()

        // Notify all users
        notifyUsersOfWaitingRoom()

        // Start waiting room timer
        waitingRoomTimer = Timer.scheduledTimer(withTimeInterval: ServerExitManager.waitingRoomTimeout, repeats: false) { [weak self] _ in
            self?.waitingRoomTimeout()
        }

        exitProgress = .waitingForRestart

        // Don't actually exit - keep server in waiting room mode
        // Server stays running but rooms are "paused"
        pauseAllRooms()
    }

    private func pauseAllRooms() {
        let activeRooms = getActiveHostedRooms()

        for room in activeRooms {
            // Send pause command to room
            guard let server = pairingManager.linkedServers.first(where: { $0.isOnline }),
                  let url = URL(string: "\(server.url)/api/rooms/\(room.id)/pause") else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(server.accessToken, forHTTPHeaderField: "Authorization")

            let body: [String: Any] = [
                "reason": "server_exit",
                "waitingRoom": true,
                "ambienceEnabled": true
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            URLSession.shared.dataTask(with: request).resume()
        }
    }

    func resumeFromWaitingRoom() {
        waitingRoomActive = false
        waitingRoomTimer?.invalidate()
        waitingRoomTimer = nil

        // Stop ambience
        ambiencePlayer?.stop()

        // Resume all rooms
        let activeRooms = getActiveHostedRooms()
        for room in activeRooms {
            guard let server = pairingManager.linkedServers.first(where: { $0.isOnline }),
                  let url = URL(string: "\(server.url)/api/rooms/\(room.id)/resume") else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(server.accessToken, forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: request).resume()
        }

        // Play woosh to indicate resumption
        playWooshSound()

        exitProgress = .idle
        isExitInProgress = false
    }

    private func waitingRoomTimeout() {
        // Auto-move to next available option
        startAutoMoveSequence()
    }

    // MARK: - Auto Move Sequence

    private func startAutoMoveSequence() {
        exitProgress = .movingToWaitingRoom

        // First, try other devices
        let otherDevices = pairingManager.linkedServers.filter { $0.isOnline && $0.id != currentDeviceId }

        if !otherDevices.isEmpty {
            // Transfer to another device
            transferToOtherDevice()
            return
        }

        // No devices, try federated
        fetchFederatedServers { [weak self] servers in
            if !servers.isEmpty {
                self?.transferToFederatedServer()
            } else {
                // No options, put in waiting room with timer
                self?.moveToWaitingRoomWithAutoMove()
            }
        }
    }

    private func moveToWaitingRoomWithAutoMove() {
        moveToWaitingRoom()

        // Set auto-move timer
        autoMoveTimer = Timer.scheduledTimer(withTimeInterval: ServerExitManager.autoMoveTimeout, repeats: true) { [weak self] _ in
            self?.checkAndAutoMove()
        }
    }

    private func checkAndAutoMove() {
        // Check for new available devices
        let otherDevices = pairingManager.linkedServers.filter { $0.isOnline && $0.id != currentDeviceId }

        if let targetDevice = otherDevices.first {
            autoMoveTimer?.invalidate()
            autoMoveTimer = nil

            // Stop waiting room
            ambiencePlayer?.stop()
            waitingRoomActive = false

            // Transfer to device
            let activeRooms = getActiveHostedRooms()
            transferRoomsToDevice(activeRooms, device: targetDevice) { [weak self] success in
                if success {
                    self?.playWooshSound()
                    self?.notifyUsersOfAutoMove(to: targetDevice.name)
                    self?.exitProgress = .complete
                    self?.performDelayedShutdown()
                }
            }
        }
    }

    // MARK: - Just Exit

    private func performJustExit() {
        exitProgress = .shuttingDown

        // Notify users that server is shutting down
        notifyUsersOfShutdown()

        // Stop server
        serverManager.stopServer()

        exitProgress = .complete

        // Quit app after short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            NSApp.terminate(nil)
        }
    }

    private func performDelayedShutdown() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.serverManager.stopServer()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Fallback Options

    private func offerFallbackOptions() {
        // Show alert with remaining options
        showExitAlert = true
    }

    // MARK: - User Notifications

    private func notifyUsersOfTransfer(to deviceName: String) {
        sendNotificationToAllUsers(
            type: "room_transfer",
            message: "Room transferred to \(deviceName)",
            data: ["targetDevice": deviceName, "seamless": true]
        )
    }

    private func notifyUsersOfFederatedTransfer(to serverName: String, sameRoom: Bool) {
        sendNotificationToAllUsers(
            type: "federated_transfer",
            message: sameRoom ? "Transferred to \(serverName)" : "Room moved to \(serverName) - new room created",
            data: ["targetServer": serverName, "sameRoom": sameRoom]
        )
    }

    private func notifyUsersOfWaitingRoom() {
        sendNotificationToAllUsers(
            type: "waiting_room",
            message: "Server is restarting - you're in the waiting room",
            data: ["ambienceEnabled": true, "estimatedWait": "A few minutes"]
        )
    }

    private func notifyUsersOfAutoMove(to deviceName: String) {
        sendNotificationToAllUsers(
            type: "auto_move",
            message: "Automatically transferred to \(deviceName)",
            data: ["targetDevice": deviceName]
        )
    }

    private func notifyUsersOfShutdown() {
        sendNotificationToAllUsers(
            type: "server_shutdown",
            message: "Server is shutting down",
            data: [:]
        )
    }

    private func sendNotificationToAllUsers(type: String, message: String, data: [String: Any]) {
        guard let server = pairingManager.linkedServers.first(where: { $0.isOnline }),
              let url = URL(string: "\(server.url)/api/broadcast") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(server.accessToken, forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "type": type,
            "message": message
        ]
        body.merge(data) { _, new in new }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request).resume()
    }

    // MARK: - Audio

    private func setupAudioPlayers() {
        // Setup woosh sound
        if let wooshURL = Bundle.main.url(forResource: "woosh", withExtension: "mp3") {
            wooshPlayer = try? AVAudioPlayer(contentsOf: wooshURL)
            wooshPlayer?.prepareToPlay()
        }

        // Setup meditation ambience
        if let ambienceURL = Bundle.main.url(forResource: "meditation_ambience", withExtension: "mp3") {
            ambiencePlayer = try? AVAudioPlayer(contentsOf: ambienceURL)
            ambiencePlayer?.numberOfLoops = -1  // Loop indefinitely
            ambiencePlayer?.volume = 0.3
            ambiencePlayer?.prepareToPlay()
        }
    }

    func playWooshSound() {
        wooshPlayer?.currentTime = 0
        wooshPlayer?.play()
    }

    func playMeditationAmbience() {
        ambiencePlayer?.play()
    }

    func stopMeditationAmbience() {
        ambiencePlayer?.stop()
    }

    // MARK: - Helpers

    private var currentDeviceId: String {
        UserDefaults.standard.string(forKey: "clientId") ?? ""
    }
}

// MARK: - Federated Server Model

struct FederatedServer: Codable, Identifiable {
    let id: String
    let name: String
    let url: String
    var isOnline: Bool
    var load: Double  // 0-1 load percentage
    var roomCount: Int

    init?(from dictionary: [String: Any]) {
        guard let id = dictionary["id"] as? String,
              let name = dictionary["name"] as? String,
              let url = dictionary["url"] as? String else {
            return nil
        }

        self.id = id
        self.name = name
        self.url = url
        self.isOnline = dictionary["isOnline"] as? Bool ?? false
        self.load = dictionary["load"] as? Double ?? 0
        self.roomCount = dictionary["roomCount"] as? Int ?? 0
    }
}

// MARK: - Exit Alert View

struct ServerExitAlertView: View {
    @ObservedObject private var exitManager = ServerExitManager.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundColor(.orange)

                VStack(alignment: .leading) {
                    Text("Server Has Active Rooms")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Choose what to do with users and rooms")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                Spacer()
            }
            .padding()

            Divider()

            // Options
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(ServerExitManager.ExitOption.allCases, id: \.self) { option in
                        ExitOptionButton(option: option) {
                            exitManager.handleExitOption(option)
                            dismiss()
                        }
                    }
                }
                .padding()
            }

            Divider()

            // Cancel button
            HStack {
                Button("Cancel") {
                    exitManager.exitProgress = .idle
                    exitManager.isExitInProgress = false
                    dismiss()
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding()
        }
        .frame(width: 500, height: 450)
    }
}

struct ExitOptionButton: View {
    let option: ServerExitManager.ExitOption
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: option.icon)
                    .font(.title2)
                    .foregroundColor(optionColor)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text(option.rawValue)
                        .font(.headline)
                        .foregroundColor(.primary)

                    Text(option.description)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundColor(.gray)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    var optionColor: Color {
        switch option {
        case .transferToDevice: return .blue
        case .transferToFederated: return .purple
        case .waitingRoom: return .orange
        case .autoMove: return .green
        case .justExit: return .red
        case .systemReboot: return .red
        }
    }
}

// MARK: - Transfer Progress View

struct TransferProgressView: View {
    @ObservedObject private var exitManager = ServerExitManager.shared

    var body: some View {
        VStack(spacing: 16) {
            if exitManager.isExitInProgress {
                // Progress indicator
                ProgressView()
                    .scaleEffect(1.5)
                    .padding()

                Text(exitManager.exitProgress.description)
                    .font(.headline)

                // Transfer status
                if let status = exitManager.transferStatus {
                    VStack(spacing: 8) {
                        ProgressView(value: status.progress)
                            .progressViewStyle(.linear)

                        Text(status.statusText)
                            .font(.caption)
                            .foregroundColor(.gray)

                        HStack {
                            Label("\(status.transferredRooms)/\(status.totalRooms) rooms", systemImage: "rectangle.stack")
                            Spacer()
                            Label("\(status.transferredUsers)/\(status.totalUsers) users", systemImage: "person.2")
                        }
                        .font(.caption)
                        .foregroundColor(.gray)
                    }
                    .padding()
                }
            }
        }
        .padding()
        .frame(width: 350)
    }
}

// MARK: - Waiting Room View

struct WaitingRoomView: View {
    @ObservedObject private var exitManager = ServerExitManager.shared
    @State private var breathingScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.1, green: 0.1, blue: 0.2),
                    Color(red: 0.15, green: 0.1, blue: 0.25)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 30) {
                // Breathing circle animation
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [
                                Color.purple.opacity(0.5),
                                Color.blue.opacity(0.3),
                                Color.clear
                            ]),
                            center: .center,
                            startRadius: 50,
                            endRadius: 150
                        )
                    )
                    .frame(width: 200, height: 200)
                    .scaleEffect(breathingScale)
                    .animation(
                        Animation.easeInOut(duration: 4)
                            .repeatForever(autoreverses: true),
                        value: breathingScale
                    )
                    .onAppear {
                        breathingScale = 1.3
                    }

                Text("Waiting Room")
                    .font(.largeTitle)
                    .fontWeight(.light)
                    .foregroundColor(.white)

                Text("The server is restarting. Relax while you wait...")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)

                // Status
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)

                    Text("Waiting for server...")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                }
                .padding(.top, 20)
            }
            .padding()
        }
    }
}

// MARK: - Remote Server Control
// Allows clients to control server devices remotely via OpenLink or direct IP

class RemoteServerControl: ObservableObject {
    static let shared = RemoteServerControl()

    @Published var isRemoteControlEnabled = true
    @Published var lastRemoteCommand: RemoteCommand?
    @Published var remoteCommandHistory: [RemoteCommandLog] = []
    @Published var connectionMode: ConnectionMode = .auto
    @Published var detectedIP: String?
    @Published var isDiscovering = false

    private let pairingManager = PairingManager.shared
    private let exitManager = ServerExitManager.shared
    private let roomManager = RoomManager.shared

    // OpenLink connection for remote control
    private var openLinkControlRoom: OpenLinkRoom?
    private var openLinkWebSocket: URLSessionWebSocketTask?
    private var directIPSession: URLSession?

    // Discovery timeout
    private static let discoveryTimeout: TimeInterval = 10.0

    // MARK: - Connection Mode

    enum ConnectionMode: String, CaseIterable {
        case auto = "Auto-Detect"
        case openLink = "OpenLink Only"
        case directIP = "Direct IP Only"
        case hybrid = "Hybrid (Both)"

        var icon: String {
            switch self {
            case .auto: return "wand.and.rays"
            case .openLink: return "link.circle"
            case .directIP: return "network"
            case .hybrid: return "arrow.triangle.branch"
            }
        }

        var description: String {
            switch self {
            case .auto: return "Automatically detect best connection method"
            case .openLink: return "Use OpenLink for secure tunneled connections"
            case .directIP: return "Connect directly via IP address"
            case .hybrid: return "Try OpenLink first, fall back to direct IP"
            }
        }
    }

    // MARK: - Remote Commands

    enum RemoteCommand: String, Codable, CaseIterable {
        case stopServer = "stop_server"
        case restartServer = "restart_server"
        case transferRooms = "transfer_rooms"
        case rebootDevice = "reboot_device"
        case pauseRooms = "pause_rooms"
        case resumeRooms = "resume_rooms"
        case getStatus = "get_status"
        case getActiveRooms = "get_active_rooms"
        case forceDisconnect = "force_disconnect"
        case updateSettings = "update_settings"

        var requiresConfirmation: Bool {
            switch self {
            case .stopServer, .restartServer, .rebootDevice, .forceDisconnect:
                return true
            default:
                return false
            }
        }

        var icon: String {
            switch self {
            case .stopServer: return "stop.circle"
            case .restartServer: return "arrow.clockwise"
            case .transferRooms: return "arrow.right.arrow.left"
            case .rebootDevice: return "arrow.counterclockwise.circle"
            case .pauseRooms: return "pause.circle"
            case .resumeRooms: return "play.circle"
            case .getStatus: return "info.circle"
            case .getActiveRooms: return "rectangle.stack"
            case .forceDisconnect: return "xmark.circle"
            case .updateSettings: return "gear"
            }
        }
    }

    struct RemoteCommandLog: Codable, Identifiable {
        let id: String
        let command: RemoteCommand
        let sourceDeviceId: String
        let sourceDeviceName: String
        let timestamp: Date
        var status: CommandStatus
        var result: String?

        enum CommandStatus: String, Codable {
            case pending = "pending"
            case executing = "executing"
            case completed = "completed"
            case failed = "failed"
        }
    }

    // MARK: - Send Remote Command to Server Device

    func sendCommand(to serverDevice: LinkedServer, command: RemoteCommand, parameters: [String: Any] = [:], completion: @escaping (Bool, String?) -> Void) {
        switch connectionMode {
        case .auto:
            // Auto-detect best method
            autoDetectAndSend(to: serverDevice, command: command, parameters: parameters, completion: completion)
        case .openLink:
            sendViaOpenLink(to: serverDevice, command: command, parameters: parameters, completion: completion)
        case .directIP:
            sendViaDirectIP(to: serverDevice, command: command, parameters: parameters, completion: completion)
        case .hybrid:
            // Try OpenLink first, then direct IP
            sendViaOpenLink(to: serverDevice, command: command, parameters: parameters) { [weak self] success, result in
                if success {
                    completion(success, result)
                } else {
                    // Fall back to direct IP
                    self?.sendViaDirectIP(to: serverDevice, command: command, parameters: parameters, completion: completion)
                }
            }
        }
    }

    // MARK: - Auto-Detect Connection Method

    private func autoDetectAndSend(to serverDevice: LinkedServer, command: RemoteCommand, parameters: [String: Any], completion: @escaping (Bool, String?) -> Void) {
        isDiscovering = true

        // Check if server is on local network first
        discoverLocalIP(for: serverDevice) { [weak self] localIP in
            self?.isDiscovering = false

            if let ip = localIP {
                // Found on local network - use direct IP
                self?.detectedIP = ip
                self?.sendViaDirectIP(to: serverDevice, directIP: ip, command: command, parameters: parameters, completion: completion)
            } else {
                // Not on local network - use OpenLink
                self?.sendViaOpenLink(to: serverDevice, command: command, parameters: parameters, completion: completion)
            }
        }
    }

    // MARK: - Local Network Discovery

    private func discoverLocalIP(for serverDevice: LinkedServer, completion: @escaping (String?) -> Void) {
        // Try mDNS/Bonjour discovery first
        let serviceBrowser = NetServiceBrowser()
        let discoveryDelegate = DeviceDiscoveryDelegate { ip in
            completion(ip)
        }

        // Also try direct probe to known local IP ranges
        probeLocalNetwork(deviceId: serverDevice.id) { ip in
            if let foundIP = ip {
                completion(foundIP)
            }
        }

        // Timeout for discovery
        DispatchQueue.main.asyncAfter(deadline: .now() + RemoteServerControl.discoveryTimeout) {
            if self.detectedIP == nil {
                // Try extracting IP from server URL as fallback
                if let urlComponents = URLComponents(string: serverDevice.url),
                   let host = urlComponents.host,
                   self.isLocalIP(host) {
                    completion(host)
                } else {
                    completion(nil)
                }
            }
        }
    }

    private func probeLocalNetwork(deviceId: String, completion: @escaping (String?) -> Void) {
        // Common local network ranges
        let localRanges = ["192.168.1", "192.168.0", "10.0.0", "10.0.1", "172.16.0"]
        let port = 3000  // VoiceLink server port

        let group = DispatchGroup()
        var foundIP: String?

        for range in localRanges {
            for i in 1...254 {
                let ip = "\(range).\(i)"
                group.enter()

                // Quick probe with short timeout
                probeHost(ip: ip, port: port, deviceId: deviceId) { isMatch in
                    if isMatch && foundIP == nil {
                        foundIP = ip
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            completion(foundIP)
        }
    }

    private func probeHost(ip: String, port: Int, deviceId: String, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://\(ip):\(port)/api/device-id") else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 0.5  // Very short timeout for probing

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseDeviceId = json["deviceId"] as? String,
                  responseDeviceId == deviceId else {
                completion(false)
                return
            }
            completion(true)
        }.resume()
    }

    private func isLocalIP(_ host: String) -> Bool {
        return host.hasPrefix("192.168.") ||
               host.hasPrefix("10.") ||
               host.hasPrefix("172.16.") ||
               host.hasPrefix("172.17.") ||
               host.hasPrefix("172.18.") ||
               host == "localhost" ||
               host == "127.0.0.1"
    }

    // MARK: - Send via OpenLink

    private func sendViaOpenLink(to serverDevice: LinkedServer, command: RemoteCommand, parameters: [String: Any], completion: @escaping (Bool, String?) -> Void) {
        let clientId = currentDeviceId

        // Create or reuse OpenLink control room
        if let existingRoom = openLinkControlRoom, existingRoom.isConnectionActive {
            // Reuse existing connection
            sendCommandViaOpenLinkWebSocket(command: command, parameters: parameters, completion: completion)
        } else {
            // Create new OpenLink connection for remote control
            roomManager.createOpenLinkRoom(initiatorId: clientId, visitorId: serverDevice.id) { [weak self] success, error, room in
                if success, let room = room {
                    self?.openLinkControlRoom = room
                    self?.establishOpenLinkWebSocket(server: serverDevice, room: room) {
                        self?.sendCommandViaOpenLinkWebSocket(command: command, parameters: parameters, completion: completion)
                    }
                } else {
                    // OpenLink failed, try direct connection as fallback
                    self?.sendViaDirectIP(to: serverDevice, command: command, parameters: parameters, completion: completion)
                }
            }
        }
    }

    private func establishOpenLinkWebSocket(server: LinkedServer, room: OpenLinkRoom, completion: @escaping () -> Void) {
        // Connect to OpenLink room via WebSocket for real-time commands
        let wsURLString = server.url.replacingOccurrences(of: "http://", with: "ws://")
                                     .replacingOccurrences(of: "https://", with: "wss://")
        guard let wsURL = URL(string: "\(wsURLString)/openlink/\(room.id)/control") else {
            completion()
            return
        }

        var request = URLRequest(url: wsURL)
        request.setValue(server.accessToken, forHTTPHeaderField: "Authorization")

        openLinkWebSocket = URLSession.shared.webSocketTask(with: request)
        openLinkWebSocket?.resume()

        // Wait for connection
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            completion()
        }

        // Listen for responses
        receiveOpenLinkMessages()
    }

    private func receiveOpenLinkMessages() {
        openLinkWebSocket?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    // Handle response
                    if let data = text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        NotificationCenter.default.post(name: .openLinkCommandResponse, object: json)
                    }
                case .data(let data):
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        NotificationCenter.default.post(name: .openLinkCommandResponse, object: json)
                    }
                @unknown default:
                    break
                }
                // Continue receiving
                self?.receiveOpenLinkMessages()
            case .failure:
                // Connection closed
                self?.openLinkWebSocket = nil
            }
        }
    }

    private func sendCommandViaOpenLinkWebSocket(command: RemoteCommand, parameters: [String: Any], completion: @escaping (Bool, String?) -> Void) {
        guard let ws = openLinkWebSocket else {
            completion(false, "OpenLink connection not established")
            return
        }

        var body: [String: Any] = [
            "type": "remote_command",
            "command": command.rawValue,
            "sourceDeviceId": currentDeviceId,
            "sourceDeviceName": Host.current().localizedName ?? "Unknown",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        body.merge(parameters) { _, new in new }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            completion(false, "Failed to encode command")
            return
        }

        let commandId = UUID().uuidString
        var bodyWithId = body
        bodyWithId["commandId"] = commandId

        // Set up response listener
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(forName: .openLinkCommandResponse, object: nil, queue: .main) { notification in
            if let response = notification.object as? [String: Any],
               response["commandId"] as? String == commandId {
                NotificationCenter.default.removeObserver(observer!)
                let success = response["success"] as? Bool ?? false
                let result = response["result"] as? String
                completion(success, result)
            }
        }

        // Send via WebSocket
        ws.send(.string(jsonString)) { error in
            if let error = error {
                NotificationCenter.default.removeObserver(observer!)
                completion(false, error.localizedDescription)
            }
        }

        // Timeout for response
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            NotificationCenter.default.removeObserver(observer!)
        }
    }

    // MARK: - Send via Direct IP

    private func sendViaDirectIP(to serverDevice: LinkedServer, directIP: String? = nil, command: RemoteCommand, parameters: [String: Any], completion: @escaping (Bool, String?) -> Void) {
        // Use detected IP or extract from server URL
        let targetIP: String
        if let ip = directIP {
            targetIP = ip
        } else if let urlComponents = URLComponents(string: serverDevice.url), let host = urlComponents.host {
            targetIP = host
        } else {
            completion(false, "Cannot determine server IP")
            return
        }

        // Get port from server URL or use default
        let port = URLComponents(string: serverDevice.url)?.port ?? 3000

        guard let url = URL(string: "http://\(targetIP):\(port)/api/remote/command") else {
            completion(false, "Invalid server URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(serverDevice.accessToken, forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "command": command.rawValue,
            "sourceDeviceId": currentDeviceId,
            "sourceDeviceName": Host.current().localizedName ?? "Unknown",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "connectionMethod": "direct_ip"
        ]
        body.merge(parameters) { _, new in new }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = json["success"] as? Bool else {
                    completion(false, error?.localizedDescription ?? "Command failed")
                    return
                }

                let result = json["result"] as? String
                completion(success, result)
            }
        }.resume()
    }

    // MARK: - Connection Management

    func disconnectOpenLink() {
        openLinkWebSocket?.cancel(with: .normalClosure, reason: nil)
        openLinkWebSocket = nil

        if let room = openLinkControlRoom {
            roomManager.endOpenLinkConnection(room, needsExtension: false)
            openLinkControlRoom = nil
        }
    }

    func setConnectionMode(_ mode: ConnectionMode) {
        connectionMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "remoteControlConnectionMode")

        // Disconnect OpenLink if switching to direct IP only
        if mode == .directIP {
            disconnectOpenLink()
        }
    }

    func loadConnectionMode() {
        if let savedMode = UserDefaults.standard.string(forKey: "remoteControlConnectionMode"),
           let mode = ConnectionMode(rawValue: savedMode) {
            connectionMode = mode
        }
    }

    // MARK: - Handle Incoming Remote Command (Server Side)

    func handleIncomingCommand(_ command: RemoteCommand, from sourceDeviceId: String, parameters: [String: Any]) -> (success: Bool, result: String) {
        guard isRemoteControlEnabled else {
            return (false, "Remote control is disabled on this device")
        }

        // Log the command
        let log = RemoteCommandLog(
            id: UUID().uuidString,
            command: command,
            sourceDeviceId: sourceDeviceId,
            sourceDeviceName: parameters["sourceDeviceName"] as? String ?? "Unknown",
            timestamp: Date(),
            status: .executing,
            result: nil
        )
        remoteCommandHistory.append(log)
        lastRemoteCommand = command

        // Execute command
        switch command {
        case .stopServer:
            exitManager.handleExitOption(.justExit)
            return (true, "Server stopping")

        case .restartServer:
            ServerModeManager.shared.restartServer()
            return (true, "Server restarting")

        case .transferRooms:
            if let targetDeviceId = parameters["targetDeviceId"] as? String {
                exitManager.handleExitOption(.transferToDevice)
                return (true, "Rooms transferring to \(targetDeviceId)")
            }
            return (false, "No target device specified")

        case .rebootDevice:
            exitManager.handleExitOption(.systemReboot)
            return (true, "Device rebooting")

        case .pauseRooms:
            exitManager.moveToWaitingRoom()
            return (true, "Rooms paused, users in waiting room")

        case .resumeRooms:
            exitManager.resumeFromWaitingRoom()
            return (true, "Rooms resumed")

        case .getStatus:
            let status = getServerStatus()
            return (true, status)

        case .getActiveRooms:
            let rooms = getActiveRoomsInfo()
            return (true, rooms)

        case .forceDisconnect:
            if let clientId = parameters["clientId"] as? String {
                forceDisconnectClient(clientId)
                return (true, "Client \(clientId) disconnected")
            }
            return (false, "No client ID specified")

        case .updateSettings:
            if let settings = parameters["settings"] as? [String: Any] {
                applyRemoteSettings(settings)
                return (true, "Settings updated")
            }
            return (false, "No settings provided")
        }
    }

    // MARK: - Helper Methods

    private func getServerStatus() -> String {
        let manager = ServerModeManager.shared
        let roomManager = RoomManager.shared

        let status: [String: Any] = [
            "isRunning": manager.isServerRunning,
            "port": manager.serverPort,
            "connectedClients": manager.connectedClients,
            "activeRooms": roomManager.permanentRooms.count,
            "waitingRoomActive": exitManager.waitingRoomActive
        ]

        if let data = try? JSONSerialization.data(withJSONObject: status),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "{}"
    }

    private func getActiveRoomsInfo() -> String {
        let rooms = RoomManager.shared.permanentRooms.map { room -> [String: Any] in
            return [
                "id": room.id,
                "name": room.name,
                "currentMembers": room.currentMembers,
                "maxMembers": room.maxMembers,
                "isOnline": room.isOnline
            ]
        }

        if let data = try? JSONSerialization.data(withJSONObject: rooms),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "[]"
    }

    private func forceDisconnectClient(_ clientId: String) {
        guard let server = pairingManager.linkedServers.first(where: { $0.isOnline }),
              let url = URL(string: "\(server.url)/api/clients/\(clientId)/disconnect") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(server.accessToken, forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request).resume()
    }

    private func applyRemoteSettings(_ settings: [String: Any]) {
        // Apply settings remotely
        if let port = settings["serverPort"] as? Int {
            ServerModeManager.shared.serverPort = port
        }

        if let remoteControlEnabled = settings["remoteControlEnabled"] as? Bool {
            isRemoteControlEnabled = remoteControlEnabled
        }
    }

    private var currentDeviceId: String {
        UserDefaults.standard.string(forKey: "clientId") ?? ""
    }

    // Make moveToWaitingRoom accessible for remote commands
    private func moveToWaitingRoom() {
        exitManager.handleExitOption(.waitingRoom)
    }
}

// MARK: - Remote Control View

struct RemoteServerControlView: View {
    @ObservedObject private var remoteControl = RemoteServerControl.shared
    @ObservedObject private var pairingManager = PairingManager.shared
    @State private var selectedServer: LinkedServer?
    @State private var showConfirmation = false
    @State private var pendingCommand: RemoteServerControl.RemoteCommand?
    @State private var commandResult: String?
    @State private var isExecuting = false
    @State private var showConnectionSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title2)
                        .foregroundColor(.blue)

                    Text("Remote Server Control")
                        .font(.title2)
                        .fontWeight(.bold)

                    Spacer()

                    // Connection settings button
                    Button(action: {
                        showConnectionSettings.toggle()
                    }) {
                        Image(systemName: "gear")
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(.plain)
                    .help("Connection Settings")

                    Toggle("Enabled", isOn: $remoteControl.isRemoteControlEnabled)
                        .labelsHidden()
                }

                // Connection Mode Indicator
                HStack(spacing: 6) {
                    Image(systemName: remoteControl.connectionMode.icon)
                        .font(.caption)
                    Text(remoteControl.connectionMode.rawValue)
                        .font(.caption)

                    if remoteControl.isDiscovering {
                        ProgressView()
                            .scaleEffect(0.6)
                    }

                    if let ip = remoteControl.detectedIP {
                        Text("(\(ip))")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                .foregroundColor(.gray)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(6)

                // Connection Settings (expandable)
                if showConnectionSettings {
                    ConnectionModeSelectorView()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Divider()

                // Server Selection
                if pairingManager.linkedServers.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .font(.largeTitle)
                            .foregroundColor(.gray.opacity(0.5))
                        Text("No servers linked")
                            .foregroundColor(.gray)
                        Text("Link a server to enable remote control")
                            .font(.caption)
                            .foregroundColor(.gray.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                } else {
                    Text("Select Server to Control:")
                        .font(.subheadline)
                        .foregroundColor(.gray)

                    ForEach(pairingManager.linkedServers) { server in
                        ServerSelectionRow(
                            server: server,
                            isSelected: selectedServer?.id == server.id
                        ) {
                            selectedServer = server
                        }
                    }
                }

                Divider()

                // Commands
                if let server = selectedServer {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Commands for \(server.name):")
                                .font(.subheadline)
                                .foregroundColor(.gray)

                            Spacer()

                            if isExecuting {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }
                        }

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(RemoteServerControl.RemoteCommand.allCases, id: \.self) { command in
                                RemoteCommandButton(command: command, isExecuting: isExecuting) {
                                    if command.requiresConfirmation {
                                        pendingCommand = command
                                        showConfirmation = true
                                    } else {
                                        executeCommand(command, on: server)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Text("Select a server above to see available commands")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity)
                        .padding()
                }

                // Result
                if let result = commandResult {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: result.lowercased().contains("fail") || result.lowercased().contains("error") ? "xmark.circle" : "checkmark.circle")
                                .foregroundColor(result.lowercased().contains("fail") || result.lowercased().contains("error") ? .red : .green)
                            Text("Result:")
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.gray)

                        Text(result)
                            .font(.caption)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(6)
                    }
                }
            }
            .padding()
        }
        .animation(.easeInOut(duration: 0.2), value: showConnectionSettings)
        .alert("Confirm Command", isPresented: $showConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingCommand = nil
            }
            Button("Execute", role: .destructive) {
                if let command = pendingCommand, let server = selectedServer {
                    executeCommand(command, on: server)
                }
                pendingCommand = nil
            }
        } message: {
            if let command = pendingCommand {
                Text("Are you sure you want to execute '\(command.rawValue)' on the server? This action may affect connected users.")
            }
        }
        .onAppear {
            remoteControl.loadConnectionMode()
        }
    }

    private func executeCommand(_ command: RemoteServerControl.RemoteCommand, on server: LinkedServer) {
        isExecuting = true
        commandResult = nil

        remoteControl.sendCommand(to: server, command: command) { success, result in
            isExecuting = false
            commandResult = success ? (result ?? "Success") : (result ?? "Failed")
        }
    }
}

// MARK: - Server Selection Row

struct ServerSelectionRow: View {
    let server: LinkedServer
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Circle()
                    .fill(server.isOnline ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .foregroundColor(.primary)
                        .fontWeight(isSelected ? .semibold : .regular)

                    Text(server.isOnline ? "Online" : "Offline")
                        .font(.caption)
                        .foregroundColor(server.isOnline ? .green : .gray)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(!server.isOnline)
        .opacity(server.isOnline ? 1.0 : 0.5)
    }
}

struct RemoteCommandButton: View {
    let command: RemoteServerControl.RemoteCommand
    let isExecuting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: command.icon)
                    .font(.title3)
                    .foregroundColor(command.requiresConfirmation ? .red : .blue)

                Text(command.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption2)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(isExecuting)
        .opacity(isExecuting ? 0.5 : 1)
    }
}

// MARK: - Connection Mode Selector View

struct ConnectionModeSelectorView: View {
    @ObservedObject private var remoteControl = RemoteServerControl.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundColor(.blue)
                Text("Connection Mode")
                    .font(.headline)

                Spacer()

                if remoteControl.isDiscovering {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Detecting...")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            // Connection mode picker
            ForEach(RemoteServerControl.ConnectionMode.allCases, id: \.self) { mode in
                Button(action: {
                    remoteControl.setConnectionMode(mode)
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: mode.icon)
                            .font(.title3)
                            .foregroundColor(remoteControl.connectionMode == mode ? .blue : .gray)
                            .frame(width: 30)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.rawValue)
                                .font(.subheadline)
                                .fontWeight(remoteControl.connectionMode == mode ? .semibold : .regular)
                                .foregroundColor(.primary)

                            Text(mode.description)
                                .font(.caption)
                                .foregroundColor(.gray)
                        }

                        Spacer()

                        if remoteControl.connectionMode == mode {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.blue)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(remoteControl.connectionMode == mode ? Color.blue.opacity(0.1) : Color.clear)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            // Show detected IP if available
            if let ip = remoteControl.detectedIP {
                HStack {
                    Image(systemName: "network")
                        .foregroundColor(.green)
                    Text("Detected: \(ip)")
                        .font(.caption)
                        .foregroundColor(.green)
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
    }
}

// MARK: - Device Discovery Delegate

class DeviceDiscoveryDelegate: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private var completion: ((String?) -> Void)?
    private var resolvedServices: [NetService] = []

    init(completion: @escaping (String?) -> Void) {
        self.completion = completion
        super.init()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        service.resolve(withTimeout: 5.0)
        resolvedServices.append(service)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let addresses = sender.addresses else { return }

        for addressData in addresses {
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            addressData.withUnsafeBytes { ptr in
                let sockaddrPtr = ptr.bindMemory(to: sockaddr.self).baseAddress!
                getnameinfo(sockaddrPtr, socklen_t(addressData.count), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            }

            let ip = String(cString: hostname)
            if !ip.isEmpty && ip.contains(".") && !ip.contains(":") {  // IPv4 only
                completion?(ip)
                completion = nil
                return
            }
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        // Failed to resolve
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        if completion != nil {
            completion?(nil)
            completion = nil
        }
    }
}

// MARK: - Notification Names Extension

extension Notification.Name {
    static let openLinkCommandResponse = Notification.Name("openLinkCommandResponse")
    static let remoteControlConnected = Notification.Name("remoteControlConnected")
    static let remoteControlDisconnected = Notification.Name("remoteControlDisconnected")
}

// MARK: - Linked Server Status Manager

class LinkedServerStatusManager: ObservableObject {
    static let shared = LinkedServerStatusManager()

    @Published var onlineDevices: [LinkedServer] = []
    @Published var lastDeviceCheck: Date?

    private let pairingManager = PairingManager.shared

    func refreshOnlineDevices() {
        // Update online status of all linked devices
        for server in pairingManager.linkedServers {
            checkDeviceOnline(server)
        }
    }

    private func checkDeviceOnline(_ server: LinkedServer) {
        guard let url = URL(string: "\(server.url)/api/health") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5.0

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                let isOnline = (response as? HTTPURLResponse)?.statusCode == 200

                if let index = self?.pairingManager.linkedServers.firstIndex(where: { $0.id == server.id }) {
                    self?.pairingManager.linkedServers[index].isOnline = isOnline
                }

                self?.onlineDevices = self?.pairingManager.linkedServers.filter { $0.isOnline } ?? []
                self?.lastDeviceCheck = Date()
            }
        }.resume()
    }
}
