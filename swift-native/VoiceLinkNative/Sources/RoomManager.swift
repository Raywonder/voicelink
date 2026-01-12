import Foundation
import SwiftUI

// MARK: - Room Manager
// Handles permanent rooms, device rotation, and capacity limits

class RoomManager: ObservableObject {
    static let shared = RoomManager()

    // User's permanent rooms
    @Published var permanentRooms: [PermanentRoom] = []

    // Guest/temporary rooms
    @Published var guestRooms: [GuestRoom] = []

    // OpenLink visitor rooms (auto-created for remote connections)
    @Published var openLinkRooms: [OpenLinkRoom] = []

    // Server capacity settings
    @Published var serverRoomCapacity: Int = 50  // Starts at 50, max 5000
    @Published var serverCurrentRooms: Int = 0

    // Device rotation settings
    @Published var rotationMode: RotationMode = .random
    @Published var preferredHostDevice: String?

    private let pairingManager = PairingManager.shared
    private let authManager = AuthenticationManager.shared

    init() {
        loadRooms()
        setupNotifications()
        cleanupExpiredGuestRooms()
        cleanupExpiredOpenLinkRooms()
    }

    // MARK: - Guest Mode

    // Check if user is a guest (not logged in)
    var isGuestMode: Bool {
        authManager.currentUser == nil
    }

    // Guest room settings
    static let guestRoomMinDuration = 10  // minutes
    static let guestRoomMaxDuration = 30  // minutes
    static let guestRoomMaxMembers = 15   // max members in guest rooms

    // Get random duration for guest room (10-30 minutes)
    func randomGuestDuration() -> Int {
        Int.random(in: RoomManager.guestRoomMinDuration...RoomManager.guestRoomMaxDuration)
    }

    // Can guest create a room?
    var canGuestCreateRoom: Bool {
        // Guests can create rooms but with limitations
        guestRooms.count < 1  // Only 1 guest room at a time
    }

    // MARK: - OpenLink Visitor Mode

    // OpenLink room settings
    static let openLinkGracePeriod = 5      // minutes after connection ends
    static let openLinkMaxExtension = 10    // additional minutes if needed
    static let openLinkAbsoluteMax = 15     // absolute max minutes after connection

    // Check if user is a visitor (not logged in, different from guest)
    var isVisitorMode: Bool {
        // Visitors haven't interacted with the app at all, just received OpenLink
        authManager.currentUser == nil && !hasUsedAppBefore
    }

    private var hasUsedAppBefore: Bool {
        UserDefaults.standard.bool(forKey: "hasUsedAppBefore")
    }

    func markAsUsedApp() {
        UserDefaults.standard.set(true, forKey: "hasUsedAppBefore")
    }

    // MARK: - Room Limits Calculation

    // Base permanent rooms from membership level
    var basePermanentRooms: Int {
        pairingManager.membershipLevel.maxRooms
    }

    // Bonus rooms from paid tier
    var paidTierBonusRooms: Int {
        pairingManager.paidTier.bonusRooms
    }

    // Bonus rooms from Mastodon reputation
    var reputationBonusRooms: Int {
        authManager.currentUser?.bonusPermanentRooms ?? 0
    }

    // Total permanent rooms user can create
    var maxPermanentRooms: Int {
        basePermanentRooms + paidTierBonusRooms + reputationBonusRooms
    }

    // Current permanent room count
    var currentPermanentRoomCount: Int {
        permanentRooms.count
    }

    // Can create more rooms?
    var canCreateRoom: Bool {
        currentPermanentRoomCount < maxPermanentRooms &&
        pairingManager.trustLevel != .banned
    }

    // MARK: - Room Member Capacity

    // Base member capacity per room based on level
    var baseRoomCapacity: Int {
        switch pairingManager.membershipLevel {
        case .newbie: return 2      // Level 1: 2 members per room
        case .regular: return 10    // Level 2: 10 members per room
        case .outstanding: return 50 // Level 3: 50 members per room
        }
    }

    // Bonus capacity from paid tier
    var paidTierBonusCapacity: Int {
        switch pairingManager.paidTier {
        case .none: return 0
        case .supporter: return 25   // +25 members
        case .unlimited: return 950  // Effectively unlimited (1000 total)
        }
    }

    // Bonus capacity from Mastodon reputation
    var reputationBonusCapacity: Int {
        authManager.currentUser?.bonusRoomCapacity ?? 0
    }

    // Total max members per room
    var maxMembersPerRoom: Int {
        baseRoomCapacity + paidTierBonusCapacity + reputationBonusCapacity
    }

    // Check if capacity is effectively unlimited
    var hasUnlimitedCapacity: Bool {
        maxMembersPerRoom >= 1000
    }

    // MARK: - Server Capacity

    // Minimum server capacity
    static let minServerCapacity = 50

    // Maximum server capacity
    static let maxServerCapacity = 5000

    // Calculate server capacity based on factors
    var calculatedServerCapacity: Int {
        var capacity = RoomManager.minServerCapacity

        // Add capacity for membership level
        switch pairingManager.membershipLevel {
        case .newbie: break  // No bonus
        case .regular: capacity += 50
        case .outstanding: capacity += 150
        }

        // Add capacity for paid tier
        switch pairingManager.paidTier {
        case .none: break
        case .supporter: capacity += 200
        case .unlimited: capacity += 1000
        }

        // Add capacity for trust score
        if pairingManager.trustScore >= 90 { capacity += 100 }
        else if pairingManager.trustScore >= 80 { capacity += 50 }
        else if pairingManager.trustScore >= 70 { capacity += 25 }

        // Add capacity for Mastodon reputation
        switch authManager.currentUser?.accountReputation {
        case .veteran: capacity += 500
        case .established: capacity += 200
        case .active: capacity += 100
        case .standard: capacity += 50
        default: break
        }

        // Add capacity for activity (days active)
        let daysActive = pairingManager.membershipStats.daysActive
        capacity += min(daysActive * 2, 500)  // Max +500 from activity

        return min(capacity, RoomManager.maxServerCapacity)
    }

    // Available room slots on server
    var availableServerSlots: Int {
        serverRoomCapacity - serverCurrentRooms
    }

    // MARK: - Device Rotation

    enum RotationMode: String, Codable, CaseIterable {
        case random = "Random"           // Random device hosts each room
        case roundRobin = "Round Robin"  // Rotate through devices
        case preferred = "Preferred"     // Use preferred device if online
        case loadBalanced = "Load Balanced" // Based on device load

        var description: String {
            switch self {
            case .random: return "Randomly select a device for each room"
            case .roundRobin: return "Rotate hosting between devices in order"
            case .preferred: return "Use your preferred device when available"
            case .loadBalanced: return "Distribute based on device capacity"
            }
        }

        var icon: String {
            switch self {
            case .random: return "dice"
            case .roundRobin: return "arrow.triangle.2.circlepath"
            case .preferred: return "star"
            case .loadBalanced: return "scale.3d"
            }
        }
    }

    // Get next device for hosting based on rotation mode
    func getHostDevice(for room: PermanentRoom) -> LinkedServer? {
        let linkedServers = pairingManager.linkedServers.filter { $0.isOnline }

        guard !linkedServers.isEmpty else { return nil }

        switch rotationMode {
        case .random:
            return linkedServers.randomElement()

        case .roundRobin:
            // Track which device was last used
            let lastHostId = UserDefaults.standard.string(forKey: "lastHostDevice")
            if let lastIndex = linkedServers.firstIndex(where: { $0.id == lastHostId }) {
                let nextIndex = (lastIndex + 1) % linkedServers.count
                let nextDevice = linkedServers[nextIndex]
                UserDefaults.standard.set(nextDevice.id, forKey: "lastHostDevice")
                return nextDevice
            }
            let first = linkedServers.first
            UserDefaults.standard.set(first?.id, forKey: "lastHostDevice")
            return first

        case .preferred:
            if let preferredId = preferredHostDevice,
               let preferred = linkedServers.first(where: { $0.id == preferredId }) {
                return preferred
            }
            // Fall back to first online device
            return linkedServers.first

        case .loadBalanced:
            // In production, this would check actual load on each device
            // For now, distribute evenly based on current room assignments
            let roomCounts = permanentRooms.reduce(into: [String: Int]()) { counts, room in
                counts[room.hostDeviceId ?? "", default: 0] += 1
            }
            return linkedServers.min { a, b in
                (roomCounts[a.id] ?? 0) < (roomCounts[b.id] ?? 0)
            }
        }
    }

    // MARK: - Room Operations

    func createRoom(name: String, description: String, isPrivate: Bool, password: String? = nil, completion: @escaping (Bool, String?) -> Void) {
        guard canCreateRoom else {
            if pairingManager.trustLevel == .banned {
                completion(false, "Your account is banned from creating rooms")
            } else {
                completion(false, "Maximum permanent rooms reached (\(maxPermanentRooms))")
            }
            return
        }

        // Get host device
        guard let hostDevice = getHostDevice(for: PermanentRoom(
            id: UUID().uuidString,
            name: name,
            description: description,
            ownerId: authManager.currentUser?.id ?? "",
            ownerUsername: authManager.currentUser?.fullHandle ?? "Unknown",
            isPrivate: isPrivate,
            maxMembers: maxMembersPerRoom,
            createdAt: Date()
        )) else {
            completion(false, "No online devices available to host")
            return
        }

        // Create room via server API
        guard let url = URL(string: "\(hostDevice.url)/api/rooms/create") else {
            completion(false, "Invalid server URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(hostDevice.accessToken, forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "name": name,
            "description": description,
            "isPrivate": isPrivate,
            "maxMembers": maxMembersPerRoom,
            "ownerId": authManager.currentUser?.id ?? "",
            "ownerUsername": authManager.currentUser?.fullHandle ?? "",
            "permanent": true  // This is a permanent room
        ]

        if let password = password {
            body["password"] = password
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = json["success"] as? Bool, success,
                      let roomId = json["roomId"] as? String else {
                    let errorMsg = (try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any])?["error"] as? String
                    completion(false, errorMsg ?? error?.localizedDescription ?? "Failed to create room")
                    return
                }

                let room = PermanentRoom(
                    id: roomId,
                    name: name,
                    description: description,
                    ownerId: self?.authManager.currentUser?.id ?? "",
                    ownerUsername: self?.authManager.currentUser?.fullHandle ?? "",
                    isPrivate: isPrivate,
                    maxMembers: self?.maxMembersPerRoom ?? 2,
                    createdAt: Date(),
                    hostDeviceId: hostDevice.id,
                    hasPassword: password != nil
                )

                self?.permanentRooms.append(room)
                self?.saveRooms()
                completion(true, nil)
            }
        }.resume()
    }

    func deleteRoom(_ room: PermanentRoom, completion: @escaping (Bool) -> Void) {
        // Find the host device
        guard let hostDevice = pairingManager.linkedServers.first(where: { $0.id == room.hostDeviceId }) else {
            // Room host not found, just remove locally
            permanentRooms.removeAll { $0.id == room.id }
            saveRooms()
            completion(true)
            return
        }

        // Delete from server
        guard let url = URL(string: "\(hostDevice.url)/api/rooms/\(room.id)/delete") else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(hostDevice.accessToken, forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.permanentRooms.removeAll { $0.id == room.id }
                self?.saveRooms()
                completion(true)
            }
        }.resume()
    }

    func migrateRoom(_ room: PermanentRoom, toDevice device: LinkedServer, completion: @escaping (Bool) -> Void) {
        // Move room hosting to a different device
        guard let index = permanentRooms.firstIndex(where: { $0.id == room.id }) else {
            completion(false)
            return
        }

        // TODO: Implement actual migration via server API
        // For now, just update the host device ID
        var updatedRoom = room
        updatedRoom.hostDeviceId = device.id
        permanentRooms[index] = updatedRoom
        saveRooms()
        completion(true)
    }

    // MARK: - Guest Room Operations

    func createGuestRoom(name: String, description: String, completion: @escaping (Bool, String?, Int?) -> Void) {
        guard isGuestMode else {
            // Not a guest, use regular room creation
            completion(false, "Use createRoom for logged-in users", nil)
            return
        }

        guard canGuestCreateRoom else {
            completion(false, "You can only have one room at a time as a guest", nil)
            return
        }

        // Get random duration for this guest room
        let duration = randomGuestDuration()
        let expiresAt = Date().addingTimeInterval(Double(duration * 60))

        // Get first available server for hosting
        guard let hostServer = pairingManager.linkedServers.first(where: { $0.isOnline }) else {
            completion(false, "No server available to host room", nil)
            return
        }

        // Create room via server API
        guard let url = URL(string: "\(hostServer.url)/api/rooms/create-guest") else {
            completion(false, "Invalid server URL", nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "name": name,
            "description": description,
            "maxMembers": RoomManager.guestRoomMaxMembers,
            "durationMinutes": duration,
            "isGuest": true,
            "deviceId": UserDefaults.standard.string(forKey: "clientId") ?? ""
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = json["success"] as? Bool, success,
                      let roomId = json["roomId"] as? String else {
                    let errorMsg = (try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any])?["error"] as? String
                    completion(false, errorMsg ?? error?.localizedDescription ?? "Failed to create guest room", nil)
                    return
                }

                let guestRoom = GuestRoom(
                    id: roomId,
                    name: name,
                    description: description,
                    createdAt: Date(),
                    expiresAt: expiresAt,
                    durationMinutes: duration,
                    maxMembers: RoomManager.guestRoomMaxMembers,
                    hostServerId: hostServer.id
                )

                self?.guestRooms.append(guestRoom)
                self?.saveGuestRooms()

                // Schedule cleanup timer
                self?.scheduleGuestRoomExpiry(guestRoom)

                completion(true, nil, duration)
            }
        }.resume()
    }

    private func scheduleGuestRoomExpiry(_ room: GuestRoom) {
        let timeUntilExpiry = room.expiresAt.timeIntervalSinceNow
        guard timeUntilExpiry > 0 else {
            removeExpiredGuestRoom(room)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeUntilExpiry) { [weak self] in
            self?.removeExpiredGuestRoom(room)
        }
    }

    private func removeExpiredGuestRoom(_ room: GuestRoom) {
        guestRooms.removeAll { $0.id == room.id }
        saveGuestRooms()

        // Notify server to remove room
        if let hostServer = pairingManager.linkedServers.first(where: { $0.id == room.hostServerId }),
           let url = URL(string: "\(hostServer.url)/api/rooms/\(room.id)/expire") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            URLSession.shared.dataTask(with: request).resume()
        }

        // Post notification
        NotificationCenter.default.post(name: .guestRoomExpired, object: room)
    }

    func cleanupExpiredGuestRooms() {
        let now = Date()
        let expired = guestRooms.filter { $0.expiresAt <= now }
        for room in expired {
            removeExpiredGuestRoom(room)
        }

        // Schedule expiry for remaining rooms
        for room in guestRooms {
            scheduleGuestRoomExpiry(room)
        }
    }

    private func saveGuestRooms() {
        if let data = try? JSONEncoder().encode(guestRooms) {
            UserDefaults.standard.set(data, forKey: "guestRooms")
        }
    }

    private func loadGuestRooms() {
        if let data = UserDefaults.standard.data(forKey: "guestRooms"),
           let rooms = try? JSONDecoder().decode([GuestRoom].self, from: data) {
            guestRooms = rooms
        }
    }

    // MARK: - OpenLink Visitor Room Operations

    /// Creates a hidden room for OpenLink remote connection with a visitor
    func createOpenLinkRoom(initiatorId: String, visitorId: String, completion: @escaping (Bool, String?, OpenLinkRoom?) -> Void) {
        // Get first available server for hosting
        guard let hostServer = pairingManager.linkedServers.first(where: { $0.isOnline }) else {
            completion(false, "No server available to host room", nil)
            return
        }

        // Create room via server API
        guard let url = URL(string: "\(hostServer.url)/api/rooms/create-openlink") else {
            completion(false, "Invalid server URL", nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "initiatorId": initiatorId,
            "visitorId": visitorId,
            "isHidden": true,
            "type": "openlink",
            "deviceId": UserDefaults.standard.string(forKey: "clientId") ?? ""
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = json["success"] as? Bool, success,
                      let roomId = json["roomId"] as? String else {
                    let errorMsg = (try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any])?["error"] as? String
                    completion(false, errorMsg ?? error?.localizedDescription ?? "Failed to create OpenLink room", nil)
                    return
                }

                let openLinkRoom = OpenLinkRoom(
                    id: roomId,
                    initiatorId: initiatorId,
                    visitorId: visitorId,
                    createdAt: Date(),
                    hostServerId: hostServer.id
                )

                self?.openLinkRooms.append(openLinkRoom)
                self?.saveOpenLinkRooms()

                completion(true, nil, openLinkRoom)
            }
        }.resume()
    }

    /// Called when OpenLink connection ends - starts grace period timer
    func endOpenLinkConnection(_ room: OpenLinkRoom, needsExtension: Bool = false) {
        guard let index = openLinkRooms.firstIndex(where: { $0.id == room.id }) else { return }

        var updatedRoom = room
        updatedRoom.connectionEndedAt = Date()
        updatedRoom.isConnectionActive = false

        // Calculate removal time based on whether extension is needed
        let gracePeriod = needsExtension ?
            Double((RoomManager.openLinkGracePeriod + Int.random(in: 5...RoomManager.openLinkMaxExtension)) * 60) :
            Double(RoomManager.openLinkGracePeriod * 60)

        updatedRoom.scheduledRemovalAt = Date().addingTimeInterval(gracePeriod)
        openLinkRooms[index] = updatedRoom
        saveOpenLinkRooms()

        // Schedule removal
        scheduleOpenLinkRoomRemoval(updatedRoom)
    }

    private func scheduleOpenLinkRoomRemoval(_ room: OpenLinkRoom) {
        guard let removalTime = room.scheduledRemovalAt else { return }

        let delay = max(0, removalTime.timeIntervalSinceNow)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.removeOpenLinkRoom(room)
        }
    }

    private func removeOpenLinkRoom(_ room: OpenLinkRoom) {
        openLinkRooms.removeAll { $0.id == room.id }
        saveOpenLinkRooms()

        // Notify server to remove room
        if let hostServer = pairingManager.linkedServers.first(where: { $0.id == room.hostServerId }),
           let url = URL(string: "\(hostServer.url)/api/rooms/\(room.id)/remove-openlink") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            URLSession.shared.dataTask(with: request).resume()
        }

        // Post notification
        NotificationCenter.default.post(name: .openLinkRoomRemoved, object: room)
    }

    /// Extend OpenLink room grace period (max 15 minutes total after connection ends)
    func extendOpenLinkRoom(_ room: OpenLinkRoom, additionalMinutes: Int) -> Bool {
        guard let index = openLinkRooms.firstIndex(where: { $0.id == room.id }),
              let connectionEndedAt = room.connectionEndedAt else { return false }

        let maxRemovalTime = connectionEndedAt.addingTimeInterval(Double(RoomManager.openLinkAbsoluteMax * 60))
        let requestedTime = Date().addingTimeInterval(Double(additionalMinutes * 60))

        // Can't extend beyond absolute max
        let newRemovalTime = min(requestedTime, maxRemovalTime)

        var updatedRoom = room
        updatedRoom.scheduledRemovalAt = newRemovalTime
        openLinkRooms[index] = updatedRoom
        saveOpenLinkRooms()

        // Reschedule removal
        scheduleOpenLinkRoomRemoval(updatedRoom)

        return true
    }

    private func saveOpenLinkRooms() {
        if let data = try? JSONEncoder().encode(openLinkRooms) {
            UserDefaults.standard.set(data, forKey: "openLinkRooms")
        }
    }

    private func loadOpenLinkRooms() {
        if let data = UserDefaults.standard.data(forKey: "openLinkRooms"),
           let rooms = try? JSONDecoder().decode([OpenLinkRoom].self, from: data) {
            openLinkRooms = rooms
        }
    }

    func cleanupExpiredOpenLinkRooms() {
        let now = Date()
        let expired = openLinkRooms.filter {
            if let removalTime = $0.scheduledRemovalAt {
                return removalTime <= now
            }
            return false
        }
        for room in expired {
            removeOpenLinkRoom(room)
        }

        // Schedule removal for remaining rooms
        for room in openLinkRooms where room.scheduledRemovalAt != nil {
            scheduleOpenLinkRoomRemoval(room)
        }
    }

    // MARK: - Sync

    func syncRoomsAcrossDevices() {
        // Sync permanent room list across all linked devices
        let roomData = permanentRooms.map { room -> [String: Any] in
            return [
                "id": room.id,
                "name": room.name,
                "description": room.description,
                "hostDeviceId": room.hostDeviceId ?? "",
                "maxMembers": room.maxMembers,
                "currentMembers": room.currentMembers
            ]
        }

        for server in pairingManager.linkedServers where server.isOnline {
            guard let url = URL(string: "\(server.url)/api/rooms/sync") else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(server.accessToken, forHTTPHeaderField: "Authorization")

            let body: [String: Any] = [
                "rooms": roomData,
                "clientId": UserDefaults.standard.string(forKey: "clientId") ?? ""
            ]

            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            URLSession.shared.dataTask(with: request).resume()
        }
    }

    // MARK: - Persistence

    private func loadRooms() {
        if let data = UserDefaults.standard.data(forKey: "permanentRooms"),
           let rooms = try? JSONDecoder().decode([PermanentRoom].self, from: data) {
            permanentRooms = rooms
        }

        // Load guest rooms
        loadGuestRooms()

        // Load OpenLink rooms
        loadOpenLinkRooms()

        if let modeRaw = UserDefaults.standard.string(forKey: "rotationMode"),
           let mode = RotationMode(rawValue: modeRaw) {
            rotationMode = mode
        }

        preferredHostDevice = UserDefaults.standard.string(forKey: "preferredHostDevice")
        serverRoomCapacity = UserDefaults.standard.integer(forKey: "serverRoomCapacity")
        if serverRoomCapacity == 0 {
            serverRoomCapacity = RoomManager.minServerCapacity
        }
    }

    private func saveRooms() {
        if let data = try? JSONEncoder().encode(permanentRooms) {
            UserDefaults.standard.set(data, forKey: "permanentRooms")
        }
        UserDefaults.standard.set(rotationMode.rawValue, forKey: "rotationMode")
        UserDefaults.standard.set(preferredHostDevice, forKey: "preferredHostDevice")
        UserDefaults.standard.set(serverRoomCapacity, forKey: "serverRoomCapacity")
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(forName: .mastodonAccountLoaded, object: nil, queue: .main) { [weak self] _ in
            // Recalculate capacity when Mastodon account loads
            self?.serverRoomCapacity = self?.calculatedServerCapacity ?? 50
            self?.saveRooms()
        }

        NotificationCenter.default.addObserver(forName: .membershipLevelChanged, object: nil, queue: .main) { [weak self] _ in
            self?.serverRoomCapacity = self?.calculatedServerCapacity ?? 50
            self?.saveRooms()
        }
    }
}

// MARK: - Permanent Room Model

struct PermanentRoom: Codable, Identifiable {
    let id: String
    var name: String
    var description: String
    let ownerId: String
    let ownerUsername: String
    var isPrivate: Bool
    var maxMembers: Int
    let createdAt: Date
    var hostDeviceId: String?
    var hasPassword: Bool = false
    var currentMembers: Int = 0
    var isOnline: Bool = true

    // Capacity display
    var capacityDisplay: String {
        if maxMembers >= 1000 {
            return "\(currentMembers)/\u{221E}"  // Infinity symbol
        }
        return "\(currentMembers)/\(maxMembers)"
    }

    var isFull: Bool {
        currentMembers >= maxMembers
    }
}

// MARK: - Guest Room Model

struct GuestRoom: Codable, Identifiable {
    let id: String
    var name: String
    var description: String
    let createdAt: Date
    let expiresAt: Date
    let durationMinutes: Int
    let maxMembers: Int  // Always 15 for guest rooms
    let hostServerId: String
    var currentMembers: Int = 0
    var isOnline: Bool = true

    // Features NOT available for guest rooms
    var canLock: Bool { false }
    var canUnlock: Bool { false }
    var canSetPassword: Bool { false }

    // Time remaining display
    var timeRemaining: String {
        let remaining = expiresAt.timeIntervalSinceNow
        guard remaining > 0 else { return "Expired" }

        let minutes = Int(remaining / 60)
        let seconds = Int(remaining.truncatingRemainder(dividingBy: 60))

        if minutes > 0 {
            return "\(minutes)m \(seconds)s remaining"
        }
        return "\(seconds)s remaining"
    }

    var isExpired: Bool {
        Date() >= expiresAt
    }

    var capacityDisplay: String {
        "\(currentMembers)/\(maxMembers)"
    }
}

// MARK: - OpenLink Room Model

struct OpenLinkRoom: Codable, Identifiable {
    let id: String
    let initiatorId: String       // User who started the OpenLink
    let visitorId: String         // Visitor receiving the call
    let createdAt: Date
    let hostServerId: String
    var isConnectionActive: Bool = true
    var connectionEndedAt: Date?
    var scheduledRemovalAt: Date?
    var isHidden: Bool = true     // Always hidden from public lists

    // Some VoiceLink features available
    var hasBasicVoice: Bool { true }
    var hasScreenShare: Bool { false }  // Not available for visitors
    var hasRecording: Bool { false }    // Not available for visitors

    // Time until removal
    var timeUntilRemoval: String? {
        guard let removalTime = scheduledRemovalAt else { return nil }
        let remaining = removalTime.timeIntervalSinceNow
        guard remaining > 0 else { return "Removing..." }

        let minutes = Int(remaining / 60)
        let seconds = Int(remaining.truncatingRemainder(dividingBy: 60))
        return "\(minutes)m \(seconds)s"
    }

    // Grace period status
    var gracePeriodStatus: GracePeriodStatus {
        guard let endedAt = connectionEndedAt, let removalAt = scheduledRemovalAt else {
            return .active
        }

        let totalGrace = removalAt.timeIntervalSince(endedAt)
        let elapsed = Date().timeIntervalSince(endedAt)

        if elapsed < 0 { return .active }
        if totalGrace <= 300 { return .standard }  // 5 min standard
        return .extended
    }

    enum GracePeriodStatus: String {
        case active = "Active"
        case standard = "Grace Period"
        case extended = "Extended"
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let guestRoomExpired = Notification.Name("guestRoomExpired")
    static let guestRoomWarning = Notification.Name("guestRoomWarning")  // 5 min warning
    static let openLinkRoomRemoved = Notification.Name("openLinkRoomRemoved")
    static let openLinkConnectionEnded = Notification.Name("openLinkConnectionEnded")
}

// MARK: - Guest Room Info View

struct GuestRoomInfoView: View {
    @ObservedObject private var roomManager = RoomManager.shared
    @State private var timeRemaining: String = ""
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Guest Mode Banner
            HStack {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundColor(.orange)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Guest Mode")
                        .font(.headline)
                    Text("Sign in to unlock full features")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                Spacer()

                Button("Sign In") {
                    NotificationCenter.default.post(name: .showAuthenticationSheet, object: nil)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding()
            .background(Color.orange.opacity(0.1))
            .cornerRadius(10)

            // Guest Room Limitations
            VStack(alignment: .leading, spacing: 8) {
                Text("Guest Limitations")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                GuestLimitationRow(icon: "clock", text: "Rooms expire after 10-30 minutes (random)")
                GuestLimitationRow(icon: "person.2", text: "Maximum 15 members per room")
                GuestLimitationRow(icon: "lock.slash", text: "No lock/unlock features")
                GuestLimitationRow(icon: "rectangle.stack.badge.minus", text: "1 room at a time")
            }
            .padding()
            .background(Color.white.opacity(0.05))
            .cornerRadius(10)

            // Active Guest Room (if any)
            if let guestRoom = roomManager.guestRooms.first {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .foregroundColor(.green)
                        Text(guestRoom.name)
                            .fontWeight(.semibold)
                        Spacer()

                        // Live countdown
                        Text(timeRemaining)
                            .font(.caption)
                            .foregroundColor(guestRoom.expiresAt.timeIntervalSinceNow < 300 ? .red : .orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.2))
                            .cornerRadius(8)
                    }

                    HStack {
                        Image(systemName: "person.2")
                            .foregroundColor(.gray)
                        Text(guestRoom.capacityDisplay)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }

                    // Progress bar for time remaining
                    let progress = max(0, min(1, guestRoom.expiresAt.timeIntervalSinceNow / Double(guestRoom.durationMinutes * 60)))
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(height: 6)
                                .cornerRadius(3)

                            Rectangle()
                                .fill(progress < 0.2 ? Color.red : Color.orange)
                                .frame(width: geometry.size.width * CGFloat(progress), height: 6)
                                .cornerRadius(3)
                        }
                    }
                    .frame(height: 6)
                }
                .padding()
                .background(Color.green.opacity(0.1))
                .cornerRadius(10)
                .onAppear {
                    startTimer()
                }
                .onDisappear {
                    timer?.invalidate()
                }
            }
        }
    }

    private func startTimer() {
        updateTimeRemaining()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            updateTimeRemaining()
        }
    }

    private func updateTimeRemaining() {
        if let room = roomManager.guestRooms.first {
            timeRemaining = room.timeRemaining
        }
    }
}

struct GuestLimitationRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.gray)
                .frame(width: 20)
            Text(text)
                .font(.caption)
                .foregroundColor(.gray)
        }
    }
}

// MARK: - Show Authentication Sheet Notification

extension Notification.Name {
    static let showAuthenticationSheet = Notification.Name("showAuthenticationSheet")
}

// MARK: - Room Capacity Info View

struct RoomCapacityInfoView: View {
    @ObservedObject private var roomManager = RoomManager.shared
    @ObservedObject private var pairingManager = PairingManager.shared
    @ObservedObject private var authManager = AuthenticationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Permanent Rooms
            HStack {
                Image(systemName: "rectangle.stack.fill")
                    .foregroundColor(.blue)
                Text("Permanent Rooms")
                    .fontWeight(.semibold)
                Spacer()
                Text("\(roomManager.currentPermanentRoomCount)/\(roomManager.maxPermanentRooms)")
                    .foregroundColor(.blue)
            }

            // Breakdown
            VStack(alignment: .leading, spacing: 4) {
                CapacityRow(label: "Base (Level \(pairingManager.membershipLevel.rawValue))", value: roomManager.basePermanentRooms)
                if roomManager.paidTierBonusRooms > 0 {
                    CapacityRow(label: "Paid Tier Bonus", value: roomManager.paidTierBonusRooms, color: .orange)
                }
                if roomManager.reputationBonusRooms > 0 {
                    CapacityRow(label: "Mastodon Bonus", value: roomManager.reputationBonusRooms, color: .purple)
                }
            }
            .font(.caption)
            .foregroundColor(.gray)

            Divider()

            // Members Per Room
            HStack {
                Image(systemName: "person.3.fill")
                    .foregroundColor(.green)
                Text("Members Per Room")
                    .fontWeight(.semibold)
                Spacer()
                if roomManager.hasUnlimitedCapacity {
                    Text("Unlimited")
                        .foregroundColor(.green)
                } else {
                    Text("\(roomManager.maxMembersPerRoom)")
                        .foregroundColor(.green)
                }
            }

            // Breakdown
            VStack(alignment: .leading, spacing: 4) {
                CapacityRow(label: "Base (Level \(pairingManager.membershipLevel.rawValue))", value: roomManager.baseRoomCapacity)
                if roomManager.paidTierBonusCapacity > 0 {
                    CapacityRow(label: "Paid Tier Bonus", value: roomManager.paidTierBonusCapacity, color: .orange)
                }
                if roomManager.reputationBonusCapacity > 0 {
                    CapacityRow(label: "Mastodon Bonus", value: roomManager.reputationBonusCapacity, color: .purple)
                }
            }
            .font(.caption)
            .foregroundColor(.gray)

            Divider()

            // Server Capacity
            HStack {
                Image(systemName: "server.rack")
                    .foregroundColor(.orange)
                Text("Server Capacity")
                    .fontWeight(.semibold)
                Spacer()
                Text("\(roomManager.serverCurrentRooms)/\(roomManager.serverRoomCapacity)")
                    .foregroundColor(.orange)
            }

            // Mastodon reputation if available
            if let user = authManager.currentUser, user.authMethod == .mastodon {
                HStack {
                    Image(systemName: user.accountReputation.icon)
                        .foregroundColor(reputationColor(user.accountReputation))
                    Text("Mastodon: \(user.accountReputation.rawValue)")
                        .font(.caption)
                    Spacer()
                    Text("\(user.followersCount) followers")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }

    func reputationColor(_ rep: AccountReputation) -> Color {
        switch rep {
        case .new: return .gray
        case .standard: return .blue
        case .active: return .green
        case .established: return .purple
        case .veteran: return .yellow
        }
    }
}

struct CapacityRow: View {
    let label: String
    let value: Int
    var color: Color = .gray

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text("+\(value)")
                .foregroundColor(color)
        }
    }
}

// MARK: - Device Rotation Settings View

struct DeviceRotationSettingsView: View {
    @ObservedObject private var roomManager = RoomManager.shared
    @ObservedObject private var pairingManager = PairingManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Device Rotation")
                .font(.headline)

            Text("How rooms are distributed across your linked devices")
                .font(.caption)
                .foregroundColor(.gray)

            ForEach(RoomManager.RotationMode.allCases, id: \.self) { mode in
                Button(action: {
                    roomManager.rotationMode = mode
                }) {
                    HStack {
                        Image(systemName: roomManager.rotationMode == mode ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(roomManager.rotationMode == mode ? .blue : .gray)

                        Image(systemName: mode.icon)
                            .foregroundColor(.blue)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.rawValue)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                            Text(mode.description)
                                .font(.caption)
                                .foregroundColor(.gray)
                        }

                        Spacer()
                    }
                    .padding()
                    .background(roomManager.rotationMode == mode ? Color.blue.opacity(0.1) : Color.white.opacity(0.05))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }

            // Preferred device selector (when in preferred mode)
            if roomManager.rotationMode == .preferred {
                Divider()

                Text("Preferred Host Device")
                    .font(.subheadline)
                    .foregroundColor(.gray)

                ForEach(pairingManager.linkedServers) { server in
                    Button(action: {
                        roomManager.preferredHostDevice = server.id
                    }) {
                        HStack {
                            Image(systemName: roomManager.preferredHostDevice == server.id ? "star.fill" : "star")
                                .foregroundColor(roomManager.preferredHostDevice == server.id ? .yellow : .gray)
                            Text(server.name)
                            Spacer()
                            Circle()
                                .fill(server.isOnline ? Color.green : Color.gray)
                                .frame(width: 8, height: 8)
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
    }
}
