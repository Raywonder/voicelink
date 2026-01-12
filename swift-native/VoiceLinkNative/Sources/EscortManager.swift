import Foundation
import SwiftUI

// MARK: - Escort Me Manager
// Safety feature allowing users to request trusted escorts for voice chat sessions

class EscortManager: ObservableObject {
    static let shared = EscortManager()

    // Active escort requests
    @Published var activeRequest: EscortRequest?
    @Published var assignedEscort: Escort?
    @Published var escortStatus: EscortStatus = .idle

    // User's trusted escorts (friends who can escort)
    @Published var trustedEscorts: [TrustedEscort] = []

    // Available escorts from server (community escorts)
    @Published var availableEscorts: [Escort] = []

    // Settings
    @Published var escortPreferences = EscortPreferences()

    private let pairingManager = PairingManager.shared
    private let authManager = AuthenticationManager.shared

    init() {
        loadTrustedEscorts()
        loadPreferences()
    }

    // MARK: - Escort Status

    enum EscortStatus: Equatable {
        case idle                     // No active escort session
        case requesting               // Requesting an escort
        case waitingForEscort         // Waiting for escort to accept
        case escortAssigned           // Escort has been assigned
        case escortJoined             // Escort is in the room
        case escortEnded              // Escort session ended
        case error(String)            // Error state
    }

    // MARK: - Request Escort

    /// Request an escort for a room session
    func requestEscort(for roomId: String, reason: EscortReason, preferredEscortId: String? = nil, completion: @escaping (Bool, String?) -> Void) {
        guard escortStatus == .idle else {
            completion(false, "An escort request is already active")
            return
        }

        escortStatus = .requesting

        // Get linked server
        guard let server = pairingManager.linkedServers.first(where: { $0.isOnline }) else {
            escortStatus = .error("No server available")
            completion(false, "No server available")
            return
        }

        guard let url = URL(string: "\(server.url)/api/escort/request") else {
            escortStatus = .error("Invalid server URL")
            completion(false, "Invalid server URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(server.accessToken, forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "roomId": roomId,
            "reason": reason.rawValue,
            "userId": authManager.currentUser?.id ?? "",
            "username": authManager.currentUser?.fullHandle ?? "Anonymous",
            "preferences": [
                "gender": escortPreferences.preferredGender?.rawValue ?? "any",
                "language": escortPreferences.preferredLanguage ?? "en",
                "escortType": escortPreferences.escortType.rawValue
            ]
        ]

        if let preferredId = preferredEscortId {
            body["preferredEscortId"] = preferredId
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = json["success"] as? Bool, success,
                      let requestId = json["requestId"] as? String else {
                    let errorMsg = (try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any])?["error"] as? String
                    self?.escortStatus = .error(errorMsg ?? error?.localizedDescription ?? "Failed to request escort")
                    completion(false, errorMsg ?? "Failed to request escort")
                    return
                }

                let escortRequest = EscortRequest(
                    id: requestId,
                    roomId: roomId,
                    reason: reason,
                    requestedAt: Date(),
                    status: .pending
                )

                self?.activeRequest = escortRequest
                self?.escortStatus = .waitingForEscort
                completion(true, nil)

                // Start listening for escort assignment
                self?.listenForEscortAssignment()
            }
        }.resume()
    }

    /// Cancel active escort request
    func cancelEscortRequest(completion: @escaping (Bool) -> Void) {
        guard let request = activeRequest else {
            completion(false)
            return
        }

        guard let server = pairingManager.linkedServers.first(where: { $0.isOnline }),
              let url = URL(string: "\(server.url)/api/escort/cancel") else {
            completion(false)
            return
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(server.accessToken, forHTTPHeaderField: "Authorization")

        let body: [String: Any] = ["requestId": request.id]
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: urlRequest) { [weak self] _, _, _ in
            DispatchQueue.main.async {
                self?.activeRequest = nil
                self?.assignedEscort = nil
                self?.escortStatus = .idle
                completion(true)
            }
        }.resume()
    }

    /// End escort session
    func endEscortSession(completion: @escaping (Bool) -> Void) {
        guard let request = activeRequest else {
            escortStatus = .idle
            completion(true)
            return
        }

        guard let server = pairingManager.linkedServers.first(where: { $0.isOnline }),
              let url = URL(string: "\(server.url)/api/escort/end") else {
            completion(false)
            return
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(server.accessToken, forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "requestId": request.id,
            "escortId": assignedEscort?.id ?? ""
        ]
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: urlRequest) { [weak self] _, _, _ in
            DispatchQueue.main.async {
                self?.activeRequest = nil
                self?.assignedEscort = nil
                self?.escortStatus = .escortEnded

                // Reset to idle after a moment
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self?.escortStatus = .idle
                }

                completion(true)
            }
        }.resume()
    }

    // MARK: - Trusted Escorts

    func addTrustedEscort(_ escort: TrustedEscort) {
        guard !trustedEscorts.contains(where: { $0.id == escort.id }) else { return }
        trustedEscorts.append(escort)
        saveTrustedEscorts()
    }

    func removeTrustedEscort(_ escortId: String) {
        trustedEscorts.removeAll { $0.id == escortId }
        saveTrustedEscorts()
    }

    // MARK: - Fetch Available Escorts

    func fetchAvailableEscorts(completion: @escaping ([Escort]) -> Void) {
        guard let server = pairingManager.linkedServers.first(where: { $0.isOnline }),
              let url = URL(string: "\(server.url)/api/escort/available") else {
            completion([])
            return
        }

        var request = URLRequest(url: url)
        request.setValue(server.accessToken, forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let escortsArray = json["escorts"] as? [[String: Any]] else {
                    completion([])
                    return
                }

                let escorts = escortsArray.compactMap { Escort(from: $0) }
                self?.availableEscorts = escorts
                completion(escorts)
            }
        }.resume()
    }

    // MARK: - Listen for Assignment

    private func listenForEscortAssignment() {
        // This would connect to WebSocket for real-time updates
        // For now, we'll poll the server
        guard activeRequest != nil else { return }

        // Poll every 5 seconds
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            guard let self = self, self.escortStatus == .waitingForEscort else {
                timer.invalidate()
                return
            }

            self.checkEscortAssignment { assigned in
                if assigned {
                    timer.invalidate()
                }
            }
        }
    }

    private func checkEscortAssignment(completion: @escaping (Bool) -> Void) {
        guard let request = activeRequest,
              let server = pairingManager.linkedServers.first(where: { $0.isOnline }),
              let url = URL(string: "\(server.url)/api/escort/status/\(request.id)") else {
            completion(false)
            return
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.setValue(server.accessToken, forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: urlRequest) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(false)
                    return
                }

                if let escortData = json["escort"] as? [String: Any],
                   let escort = Escort(from: escortData) {
                    self?.assignedEscort = escort
                    self?.escortStatus = .escortAssigned
                    completion(true)
                    return
                }

                completion(false)
            }
        }.resume()
    }

    // MARK: - Persistence

    private func saveTrustedEscorts() {
        if let data = try? JSONEncoder().encode(trustedEscorts) {
            UserDefaults.standard.set(data, forKey: "trustedEscorts")
        }
    }

    private func loadTrustedEscorts() {
        if let data = UserDefaults.standard.data(forKey: "trustedEscorts"),
           let escorts = try? JSONDecoder().decode([TrustedEscort].self, from: data) {
            trustedEscorts = escorts
        }
    }

    private func savePreferences() {
        if let data = try? JSONEncoder().encode(escortPreferences) {
            UserDefaults.standard.set(data, forKey: "escortPreferences")
        }
    }

    private func loadPreferences() {
        if let data = UserDefaults.standard.data(forKey: "escortPreferences"),
           let prefs = try? JSONDecoder().decode(EscortPreferences.self, from: data) {
            escortPreferences = prefs
        }
    }
}

// MARK: - Models

struct EscortRequest: Codable, Identifiable {
    let id: String
    let roomId: String
    let reason: EscortReason
    let requestedAt: Date
    var status: RequestStatus

    enum RequestStatus: String, Codable {
        case pending = "pending"
        case assigned = "assigned"
        case completed = "completed"
        case cancelled = "cancelled"
    }
}

enum EscortReason: String, Codable, CaseIterable {
    case safety = "safety"                    // Personal safety concern
    case newUser = "new_user"                 // New user needing guidance
    case accessibility = "accessibility"       // Accessibility assistance
    case moderation = "moderation"            // Moderation support
    case other = "other"                      // Other reason

    var displayName: String {
        switch self {
        case .safety: return "Personal Safety"
        case .newUser: return "New User Help"
        case .accessibility: return "Accessibility Support"
        case .moderation: return "Moderation Needed"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .safety: return "shield.checkered"
        case .newUser: return "person.badge.plus"
        case .accessibility: return "accessibility"
        case .moderation: return "flag"
        case .other: return "ellipsis.circle"
        }
    }
}

struct Escort: Codable, Identifiable {
    let id: String
    let username: String
    let displayName: String
    var isAvailable: Bool
    var rating: Double
    var escortCount: Int
    var languages: [String]
    var gender: Gender?

    enum Gender: String, Codable {
        case male = "male"
        case female = "female"
        case nonBinary = "non_binary"
        case any = "any"
    }

    init?(from dictionary: [String: Any]) {
        guard let id = dictionary["id"] as? String,
              let username = dictionary["username"] as? String else {
            return nil
        }

        self.id = id
        self.username = username
        self.displayName = dictionary["displayName"] as? String ?? username
        self.isAvailable = dictionary["isAvailable"] as? Bool ?? false
        self.rating = dictionary["rating"] as? Double ?? 0
        self.escortCount = dictionary["escortCount"] as? Int ?? 0
        self.languages = dictionary["languages"] as? [String] ?? ["en"]
        if let genderStr = dictionary["gender"] as? String {
            self.gender = Gender(rawValue: genderStr)
        }
    }
}

struct TrustedEscort: Codable, Identifiable {
    let id: String
    let username: String
    let displayName: String
    let addedAt: Date
    var priority: Int  // Higher = more preferred
}

struct EscortPreferences: Codable {
    var preferredGender: Escort.Gender?
    var preferredLanguage: String?
    var escortType: EscortType = .community

    enum EscortType: String, Codable {
        case trustedOnly = "trusted"      // Only from trusted list
        case community = "community"       // Community volunteers
        case any = "any"                  // Anyone available
    }
}

// MARK: - Escort Me View

struct EscortMeView: View {
    @ObservedObject private var escortManager = EscortManager.shared
    @State private var selectedReason: EscortReason = .safety
    @State private var showingTrustedEscorts = false
    let roomId: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Image(systemName: "shield.checkered")
                    .font(.largeTitle)
                    .foregroundColor(.blue)

                VStack(alignment: .leading) {
                    Text("Escort Me")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Request a trusted companion to join your session")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Status-based content
            switch escortManager.escortStatus {
            case .idle:
                requestFormView

            case .requesting:
                ProgressView("Sending request...")
                    .padding()

            case .waitingForEscort:
                waitingView

            case .escortAssigned, .escortJoined:
                escortAssignedView

            case .escortEnded:
                VStack {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundColor(.green)
                    Text("Escort session ended")
                        .font(.headline)
                }
                .padding()

            case .error(let message):
                VStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundColor(.red)
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.red)

                    Button("Try Again") {
                        escortManager.escortStatus = .idle
                    }
                    .buttonStyle(.bordered)
                    .padding(.top)
                }
                .padding()
            }

            Spacer()
        }
        .frame(minWidth: 400, minHeight: 400)
    }

    private var requestFormView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Why do you need an escort?")
                .font(.headline)

            // Reason selection
            ForEach(EscortReason.allCases, id: \.self) { reason in
                Button(action: {
                    selectedReason = reason
                }) {
                    HStack {
                        Image(systemName: selectedReason == reason ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selectedReason == reason ? .blue : .gray)

                        Image(systemName: reason.icon)
                            .foregroundColor(.blue)
                            .frame(width: 24)

                        Text(reason.displayName)
                            .foregroundColor(.primary)

                        Spacer()
                    }
                    .padding()
                    .background(selectedReason == reason ? Color.blue.opacity(0.1) : Color.clear)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Escort source selection
            HStack {
                Text("Request from:")
                    .font(.subheadline)
                Picker("", selection: $escortManager.escortPreferences.escortType) {
                    Text("Trusted Only").tag(EscortPreferences.EscortType.trustedOnly)
                    Text("Community").tag(EscortPreferences.EscortType.community)
                    Text("Anyone").tag(EscortPreferences.EscortType.any)
                }
                .pickerStyle(.segmented)
            }

            // Trusted escorts link
            if !escortManager.trustedEscorts.isEmpty {
                Button(action: { showingTrustedEscorts = true }) {
                    HStack {
                        Image(systemName: "person.2.fill")
                        Text("\(escortManager.trustedEscorts.count) Trusted Escorts")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption)
                    .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Request button
            Button(action: {
                escortManager.requestEscort(for: roomId, reason: selectedReason) { _, _ in }
            }) {
                HStack {
                    Image(systemName: "shield.checkered")
                    Text("Request Escort")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
    }

    private var waitingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Looking for an escort...")
                .font(.headline)

            Text("Someone will join your room shortly")
                .font(.caption)
                .foregroundColor(.gray)

            Button("Cancel Request") {
                escortManager.cancelEscortRequest { _ in }
            }
            .buttonStyle(.bordered)
            .foregroundColor(.red)
        }
        .padding()
    }

    private var escortAssignedView: some View {
        VStack(spacing: 16) {
            if let escort = escortManager.assignedEscort {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.green)

                Text(escort.displayName)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("@\(escort.username)")
                    .font(.caption)
                    .foregroundColor(.gray)

                if escort.rating > 0 {
                    HStack {
                        Image(systemName: "star.fill")
                            .foregroundColor(.yellow)
                        Text(String(format: "%.1f", escort.rating))
                        Text("(\(escort.escortCount) escorts)")
                            .foregroundColor(.gray)
                    }
                    .font(.caption)
                }

                Text(escortManager.escortStatus == .escortJoined ? "In your room" : "Joining your room...")
                    .font(.subheadline)
                    .foregroundColor(.green)
            }

            Spacer()

            Button("End Escort Session") {
                escortManager.endEscortSession { _ in }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
}

// MARK: - Escort Me Button (for room controls)

struct EscortMeButton: View {
    let roomId: String
    @State private var showingEscortSheet = false

    var body: some View {
        Button(action: {
            showingEscortSheet = true
        }) {
            HStack(spacing: 4) {
                Image(systemName: "shield.checkered")
                Text("Escort Me")
            }
            .font(.caption)
        }
        .buttonStyle(.bordered)
        .sheet(isPresented: $showingEscortSheet) {
            EscortMeView(roomId: roomId) {
                showingEscortSheet = false
            }
        }
    }
}

// MARK: - Trusted Escorts Management View

struct TrustedEscortsView: View {
    @ObservedObject private var escortManager = EscortManager.shared
    @State private var showingAddEscort = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Trusted Escorts")
                    .font(.headline)
                Spacer()
                Button(action: { showingAddEscort = true }) {
                    Image(systemName: "plus")
                }
            }

            if escortManager.trustedEscorts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.2.slash")
                        .font(.largeTitle)
                        .foregroundColor(.gray)
                    Text("No trusted escorts yet")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                    Text("Add friends you trust to escort you in rooms")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                ForEach(escortManager.trustedEscorts) { escort in
                    HStack {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.title2)
                            .foregroundColor(.blue)

                        VStack(alignment: .leading) {
                            Text(escort.displayName)
                                .fontWeight(.medium)
                            Text("@\(escort.username)")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }

                        Spacer()

                        Button(action: {
                            escortManager.removeTrustedEscort(escort.id)
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
    }
}
