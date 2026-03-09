import SwiftUI
import UserNotifications

struct ContentView: View {
    @Binding var serverURL: String
    @State private var selectedTab: Tab = .home
    @StateObject private var roomState = IOSRoomMessagingState()

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeTab(
                serverURL: $serverURL,
                roomState: roomState,
                openMessagesTab: { selectedTab = .messages }
            )
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag(Tab.home)

            FederationTab(serverURL: $serverURL)
                .tabItem {
                    Label("Federation", systemImage: "network")
                }
                .tag(Tab.federation)

            MessagesTab(serverURL: $serverURL, roomState: roomState)
                .tabItem {
                    Label("Messages", systemImage: "bubble.left.and.bubble.right.fill")
                }
                .tag(Tab.messages)

            SettingsTab()
                .tabItem {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
                .tag(Tab.settings)
        }
        .onReceive(NotificationCenter.default.publisher(for: .iosOpenMessagesTab)) { notification in
            roomState.handleOpenMessagesRequest(notification.userInfo)
            selectedTab = .messages
        }
        .onReceive(NotificationCenter.default.publisher(for: .iosShowUserProfile)) { notification in
            roomState.handleProfileRequest(notification.userInfo)
            selectedTab = .messages
        }
    }
}

private enum Tab {
    case home
    case federation
    case messages
    case settings
}

private struct IOSDirectMessageTarget: Identifiable, Hashable {
    let id: String
    let name: String
}

private struct IOSRoomMessageItem: Identifiable, Hashable {
    let id: String
    let roomId: String
    let roomName: String
    let author: String
    let body: String
    let timestamp: Date
}

@MainActor
private final class IOSRoomMessagingState: ObservableObject {
    @Published var isInRoom = false
    @Published var activeRoomId = ""
    @Published var activeRoomName = ""
    @Published var roomMessages: [IOSRoomMessageItem] = []
    @Published var directTargets: [IOSDirectMessageTarget] = []
    @Published var selectedDirectTarget: IOSDirectMessageTarget?
    @Published var selectedProfileName: String?
    @Published var statusText = ""

    init() {
        NotificationCenter.default.addObserver(
            forName: .iosRoomJoined,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleRoomJoined(notification.userInfo)
        }
        NotificationCenter.default.addObserver(
            forName: .iosRoomLeft,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleRoomLeft(notification.userInfo)
        }
        NotificationCenter.default.addObserver(
            forName: .iosRoomUsersUpdated,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleRoomUsers(notification.userInfo)
        }
        NotificationCenter.default.addObserver(
            forName: .iosRoomMessageEvent,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleRoomMessage(notification.userInfo)
        }
        NotificationCenter.default.addObserver(
            forName: .iosDirectMessageEvent,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleDirectMessage(notification.userInfo)
        }
    }

    func requestLeaveActiveRoom() {
        guard isInRoom else { return }
        NotificationCenter.default.post(
            name: .iosRequestLeaveRoom,
            object: nil,
            userInfo: ["roomId": activeRoomId]
        )
    }

    func sendDirectMessage(_ text: String) {
        guard isInRoom else {
            statusText = "Join a room first to send direct messages."
            return
        }
        guard let target = selectedDirectTarget else {
            statusText = "Select a user first."
            return
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        NotificationCenter.default.post(
            name: .iosSendDirectMessage,
            object: nil,
            userInfo: [
                "roomId": activeRoomId,
                "roomName": activeRoomName,
                "userId": target.id,
                "userName": target.name,
                "body": body
            ]
        )
        statusText = "Sent to \(target.name)."
    }

    func handleOpenMessagesRequest(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        if let roomId = info["roomId"] as? String, !roomId.isEmpty {
            activeRoomId = roomId
        }
        if let roomName = info["roomName"] as? String, !roomName.isEmpty {
            activeRoomName = roomName
        }
        if let userId = info["userId"] as? String, !userId.isEmpty {
            let userName = (info["userName"] as? String ?? "User")
            selectedDirectTarget = IOSDirectMessageTarget(id: userId, name: userName)
            upsertDirectTarget(selectedDirectTarget!)
        }
    }

    func handleProfileRequest(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        if let userName = info["userName"] as? String, !userName.isEmpty {
            selectedProfileName = userName
            statusText = "Profile viewed: \(userName)"
        }
    }

    private func handleRoomJoined(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        let roomId = (info["roomId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let roomName = (info["roomName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !roomId.isEmpty {
            activeRoomId = roomId
            isInRoom = true
        }
        if !roomName.isEmpty {
            activeRoomName = roomName
        }
    }

    private func handleRoomLeft(_ info: [AnyHashable: Any]?) {
        let roomId = (info?["roomId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if roomId.isEmpty || roomId == activeRoomId {
            isInRoom = false
            activeRoomId = ""
            activeRoomName = ""
            selectedDirectTarget = nil
            statusText = "Left room."
        }
    }

    private func handleRoomUsers(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        let roomId = (info["roomId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard roomId == activeRoomId || activeRoomId.isEmpty else { return }
        guard let users = info["users"] as? [[String: String]] else { return }
        let mapped = users.compactMap { entry -> IOSDirectMessageTarget? in
            guard let id = entry["id"], !id.isEmpty, let name = entry["name"], !name.isEmpty else { return nil }
            return IOSDirectMessageTarget(id: id, name: name)
        }
        if isInRoom {
            directTargets = mapped.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } else {
            for target in mapped {
                upsertDirectTarget(target)
            }
        }
        if let selected = selectedDirectTarget, !directTargets.contains(selected) {
            selectedDirectTarget = directTargets.first
        }
    }

    private func handleRoomMessage(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        let roomId = (info["roomId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let roomName = (info["roomName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let author = (info["author"] as? String ?? "User").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (info["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ts = info["timestamp"] as? TimeInterval ?? Date().timeIntervalSince1970
        guard !roomId.isEmpty, !body.isEmpty else { return }
        roomMessages.append(
            IOSRoomMessageItem(
                id: UUID().uuidString,
                roomId: roomId,
                roomName: roomName.isEmpty ? "Room" : roomName,
                author: author.isEmpty ? "User" : author,
                body: body,
                timestamp: Date(timeIntervalSince1970: ts)
            )
        )
        if roomMessages.count > 400 {
            roomMessages = Array(roomMessages.suffix(400))
        }
    }

    private func handleDirectMessage(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        let userId = (info["userId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let userName = (info["userName"] as? String ?? "User").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userId.isEmpty else { return }
        let target = IOSDirectMessageTarget(id: userId, name: userName.isEmpty ? "User" : userName)
        upsertDirectTarget(target)
        if selectedDirectTarget == nil {
            selectedDirectTarget = target
        }
    }

    private func upsertDirectTarget(_ target: IOSDirectMessageTarget) {
        if let idx = directTargets.firstIndex(where: { $0.id == target.id }) {
            directTargets[idx] = target
        } else {
            directTargets.append(target)
        }
        directTargets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private enum RoomSortMode: String, CaseIterable, Identifiable {
    case activity
    case recent
    case name

    var id: String { rawValue }

    var label: String {
        switch self {
        case .activity: return "Activity"
        case .recent: return "Recent"
        case .name: return "Name"
        }
    }
}

struct RoomSummary: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    let description: String
    let userCount: Int
    let visibility: String
    let accessType: String
    let serverSource: String
    let serverTitle: String
    let serverApiBase: String
    let serverDomain: String
    let federated: Bool
    let federationTier: String

    private enum CodingKeys: String, CodingKey {
        case id, name, description, users, userCount, visibility, accessType, serverSource, serverTitle, serverApiBase, serverDomain, federated, federationTier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = RoomSummary.decodeString(container, forKey: .id) ?? UUID().uuidString
        name = (try? container.decode(String.self, forKey: .name)) ?? "Untitled Room"
        description = (try? container.decode(String.self, forKey: .description)) ?? ""
        let users = RoomSummary.decodeInt(container, forKey: .users) ?? 0
        let explicitUserCount = RoomSummary.decodeInt(container, forKey: .userCount)
        userCount = explicitUserCount ?? users
        visibility = (try? container.decode(String.self, forKey: .visibility)) ?? "public"
        accessType = (try? container.decode(String.self, forKey: .accessType)) ?? "open"
        serverSource = (try? container.decode(String.self, forKey: .serverSource)) ?? "unknown"
        serverTitle = (try? container.decode(String.self, forKey: .serverTitle)) ?? ""
        serverApiBase = (try? container.decode(String.self, forKey: .serverApiBase)) ?? ""
        serverDomain = (try? container.decode(String.self, forKey: .serverDomain)) ?? ""
        federated = (try? container.decode(Bool.self, forKey: .federated)) ?? false
        federationTier = (try? container.decode(String.self, forKey: .federationTier)) ?? "none"
    }

    private static func decodeString(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> String? {
        if let value = try? container.decode(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Int.self, forKey: key) {
            return String(value)
        }
        return nil
    }

    private static func decodeInt(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(String.self, forKey: key), let intValue = Int(value) {
            return intValue
        }
        return nil
    }
}

private struct FederatedRoomChoice: Identifiable, Hashable {
    let id: String
    let room: RoomSummary
    let serverLabel: String
    let baseURL: String
}

private struct FederatedRoomGroup: Identifiable, Hashable {
    let id: String
    let displayName: String
    let totalUsers: Int
    let choices: [FederatedRoomChoice]
}

private struct ClientVisibilitySettings: Equatable {
    let desktop: Bool
    let ios: Bool
    let web: Bool
    let frontendOpen: Bool

    static let allVisible = ClientVisibilitySettings(
        desktop: true,
        ios: true,
        web: true,
        frontendOpen: true
    )
}

private struct HomeTab: View {
    @Environment(\.openURL) private var openURL
    @Binding var serverURL: String
    @ObservedObject var roomState: IOSRoomMessagingState
    let openMessagesTab: () -> Void
    @State private var rooms: [RoomSummary] = []
    @State private var isLoading = false
    @State private var errorMessage = ""
    @State private var activeSession: RoomSessionDestination?
    @State private var activePreview: RoomPreviewDestination?
    @State private var isAdmin = false
    @State private var showAdmin = false
    @State private var roomSortMode: RoomSortMode = .activity
    @State private var clientVisibility: ClientVisibilitySettings = .allVisible

    private var normalizedBaseURL: String { normalizeBaseURL(serverURL) }
    private var roomsEndpoint: String { "\(normalizedBaseURL)/api/rooms?source=app&sort=\(roomSortMode.rawValue)" }

    var body: some View {
        NavigationStack {
            List {
                if !errorMessage.isEmpty {
                    Section("Status") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section("Room") {
                    if roomState.isInRoom {
                        Text("Active room: \(roomState.activeRoomName.isEmpty ? "Unknown Room" : roomState.activeRoomName)")
                        HStack {
                            Button("Open Messages") {
                                openMessagesTab()
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Leave Room") {
                                roomState.requestLeaveActiveRoom()
                            }
                            .buttonStyle(.bordered)
                        }
                    } else {
                        Text("Tap a room to join.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Client Access") {
                    if clientVisibility.ios {
                        Text("iOS client access is enabled for this server.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("This server has iOS visibility disabled by server policy.")
                            .foregroundStyle(.orange)
                    }

                    HStack {
                        Text("Web Frontend")
                        Spacer()
                        Text(clientVisibility.frontendOpen ? "Open" : "Closed")
                            .foregroundStyle(clientVisibility.frontendOpen ? .green : .secondary)
                    }

                    Button("Open Web Frontend") {
                        guard let url = URL(string: normalizedBaseURL) else { return }
                        openURL(url)
                    }
                    .disabled(!clientVisibility.frontendOpen)
                }

                Section("Rooms") {
                    Text("Tap a room to join. Use the info button for room details.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Picker("Sort Rooms", selection: $roomSortMode) {
                        ForEach(RoomSortMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if !clientVisibility.ios {
                        Text("Rooms are hidden on iOS by server settings.")
                            .foregroundStyle(.secondary)
                    } else if isLoading {
                        HStack {
                            ProgressView()
                            Text("Loading rooms…")
                                .foregroundStyle(.secondary)
                        }
                    } else if rooms.isEmpty {
                        Text("No rooms found yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(rooms) { room in
                            HStack(spacing: 10) {
                                Button {
                                    openRoom(room, action: "join")
                                } label: {
                                    RoomRow(room: room)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Tap to join this room.")

                                Spacer(minLength: 0)

                                NavigationLink(value: room) {
                                    Image(systemName: "info.circle")
                                        .imageScale(.large)
                                }
                                .accessibilityLabel("Room details")
                                .accessibilityHint("Opens room details and settings.")
                            }
                        }
                    }
                }
            }
            .navigationTitle("VoiceLink")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: RoomSummary.self) { room in
                RoomDetailView(
                    room: room,
                    baseURL: normalizedBaseURL,
                    onJoin: { openRoom(room, action: "join") },
                    onPreview: { openRoom(room, action: "preview") }
                )
            }
            .toolbar {
                if isAdmin {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showAdmin = true
                        } label: {
                            Label("Admin", systemImage: "gearshape.2.fill")
                        }
                    }
                }
            }
            .onAppear {
                Task {
                    await refreshRooms()
                    await refreshAdminAccess()
                }
            }
            .refreshable {
                await refreshRooms()
                await refreshAdminAccess()
            }
            .onChange(of: roomSortMode) { _ in
                Task { await refreshRooms() }
            }
            .sheet(item: $activeSession) { session in
                RoomSessionView(destination: session)
            }
            .sheet(item: $activePreview) { preview in
                RoomPreviewView(destination: preview)
            }
            .sheet(isPresented: $showAdmin) {
                AdminTabView(serverURL: $serverURL)
            }
        }
    }

    private func openRoom(_ room: RoomSummary, action: String) {
        guard clientVisibility.ios else { return }
        guard activeSession == nil, activePreview == nil else { return }
        if action == "join" {
            activePreview = nil
            activeSession = RoomSessionDestination(
                roomId: room.id,
                roomName: room.name,
                roomDescription: room.description,
                baseURL: normalizedBaseURL
            )
            return
        }

        activeSession = nil
        activePreview = RoomPreviewDestination(
            roomId: room.id,
            roomName: room.name,
            roomDescription: room.description,
            baseURL: normalizedBaseURL,
            room: room
        )
    }

    @MainActor
    private func refreshRooms() async {
        clientVisibility = await fetchClientVisibility(baseURL: normalizedBaseURL)
        guard clientVisibility.ios else {
            rooms = []
            errorMessage = "iOS client access is disabled for this server."
            return
        }

        guard let url = URL(string: roomsEndpoint) else {
            errorMessage = "Invalid server URL."
            rooms = []
            return
        }
        isLoading = true
        errorMessage = ""
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                errorMessage = "Server returned status \(http.statusCode)."
                rooms = []
            } else {
                rooms = try JSONDecoder().decode([RoomSummary].self, from: data)
            }
        } catch {
            rooms = []
            errorMessage = "Could not load rooms. Check server URL and network."
        }
        isLoading = false
    }

    @MainActor
    private func refreshAdminAccess() async {
        guard let url = URL(string: "\(normalizedBaseURL)/api/admin/status") else {
            isAdmin = false
            return
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            let token = (UserDefaults.standard.string(forKey: "voicelink.authToken") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue(token, forHTTPHeaderField: "x-session-token")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                isAdmin = false
                return
            }
            let json = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            isAdmin = (json["isAdmin"] as? Bool) ?? false
        } catch {
            isAdmin = false
        }
    }
}

private struct RoomRow: View {
    let room: RoomSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(room.name)
                .font(.headline)
            if !room.description.isEmpty {
                Text(room.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("\(room.userCount) users • \(displayVisibilityLabel(room.visibility)) • \(displayAccessTypeLabel(room.accessType))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(room.name), \(room.userCount) users")
        .accessibilityHint("Tap to join. Room details are on the info button.")
    }
}

private struct RoomDetailView: View {
    let room: RoomSummary
    let baseURL: String
    let onJoin: () -> Void
    let onPreview: () -> Void
    @AppStorage("voicelink.authToken") private var authToken = ""
    @State private var federatedEnabled = false
    @State private var federationTier = "standard"
    @State private var federationStatus = ""
    @State private var isSavingFederation = false

    var body: some View {
        List {
            Section("Room Details") {
                LabeledContent("Room ID", value: room.id)
                LabeledContent("Name", value: room.name)
                LabeledContent("Users", value: "\(room.userCount)")
                LabeledContent("Visibility", value: displayVisibilityLabel(room.visibility))
                LabeledContent("Client Access", value: displayAccessTypeLabel(room.accessType))
                LabeledContent(
                    "Federation",
                    value: room.federated
                        ? "Enabled (\(room.federationTier.isEmpty ? "standard" : room.federationTier))"
                        : "Disabled"
                )
                if !room.serverTitle.isEmpty {
                    LabeledContent("Server", value: room.serverTitle)
                }
                if !room.serverDomain.isEmpty {
                    LabeledContent("Server Domain", value: room.serverDomain)
                }
                if !room.serverSource.isEmpty {
                    LabeledContent("Server Source", value: room.serverSource)
                }
                if !room.description.isEmpty {
                    Text(room.description)
                }
            }

            Section("Actions") {
                Button("Join Room", action: onJoin)
                    .buttonStyle(.borderedProminent)
                Button("Preview Room", action: onPreview)
                    .buttonStyle(.bordered)
            }

            Section("Federation") {
                Toggle("Show This Room Across Federated Servers", isOn: $federatedEnabled)

                Picker("Federation Tier", selection: $federationTier) {
                    Text("None").tag("none")
                    Text("Standard").tag("standard")
                    Text("Promoted").tag("promoted")
                }
                .disabled(!federatedEnabled)

                Button(isSavingFederation ? "Saving…" : "Save Federation Settings") {
                    Task { await saveFederationSettings() }
                }
                .disabled(isSavingFederation)

                if !federationStatus.isEmpty {
                    Text(federationStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(room.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            federatedEnabled = room.federated
            federationTier = room.federated ? (room.federationTier.isEmpty ? "standard" : room.federationTier) : "none"
            federationStatus = ""
        }
        .accessibilityAction(named: Text("Join Room"), onJoin)
        .accessibilityAction(named: Text("Preview Room"), onPreview)
    }

    @MainActor
    private func saveFederationSettings() async {
        guard let url = URL(string: "\(baseURL)/api/rooms/\(room.id)/federation") else {
            federationStatus = "Invalid server URL."
            return
        }
        isSavingFederation = true
        defer { isSavingFederation = false }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(token, forHTTPHeaderField: "x-session-token")
        }

        let payload: [String: Any] = [
            "federated": federatedEnabled,
            "federationTier": federatedEnabled ? federationTier : "none"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                federationStatus = "Unknown server response."
                return
            }
            if (200...299).contains(http.statusCode) {
                federationStatus = federatedEnabled
                    ? "Federation enabled for this room (\(federationTier))."
                    : "Federation disabled for this room."
            } else {
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                federationStatus = message ?? "Could not save federation settings (HTTP \(http.statusCode))."
            }
        } catch {
            federationStatus = "Could not save federation settings right now."
        }
    }
}

private struct FederationTab: View {
    @Binding var serverURL: String
    @State private var roomGroups: [FederatedRoomGroup] = []
    @State private var isLoading = false
    @State private var errorMessage = ""
    @State private var activeSession: RoomSessionDestination?
    @State private var activePreview: RoomPreviewDestination?
    @State private var clientVisibility: ClientVisibilitySettings = .allVisible

    private var normalizedBaseURL: String { normalizeBaseURL(serverURL) }

    var body: some View {
        NavigationStack {
            List {
                if !errorMessage.isEmpty {
                    Section("Status") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                if isLoading {
                    ProgressView("Loading federated rooms…")
                } else {
                    if !clientVisibility.ios {
                        Section("Rooms") {
                            Text("Federated rooms are hidden on iOS by server settings.")
                                .foregroundStyle(.secondary)
                        }
                    } else if roomGroups.isEmpty {
                        Section("Rooms") {
                            Text("No federated rooms found.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Section("Rooms Across Servers") {
                            ForEach(roomGroups) { group in
                                NavigationLink(value: group) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(group.displayName)
                                            .font(.headline)
                                        Text("\(group.totalUsers) users across \(group.choices.count) server\(group.choices.count == 1 ? "" : "s")")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .accessibilityLabel("\(group.displayName), \(group.totalUsers) users across \(group.choices.count) servers")
                                .accessibilityHint("Double-tap to choose server and join.")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Federation")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: FederatedRoomGroup.self) { group in
                FederationRoomChoicesView(group: group) { choice, action in
                    openRoom(choice, action: action)
                }
            }
            .onAppear { Task { await refreshRooms() } }
            .refreshable { await refreshRooms() }
            .sheet(item: $activeSession) { session in
                RoomSessionView(destination: session)
            }
            .sheet(item: $activePreview) { preview in
                RoomPreviewView(destination: preview)
            }
        }
    }

    private func openRoom(_ choice: FederatedRoomChoice, action: String) {
        guard activeSession == nil, activePreview == nil else { return }
        if action == "join" {
            activePreview = nil
            activeSession = RoomSessionDestination(
                roomId: choice.room.id,
                roomName: choice.room.name,
                roomDescription: choice.room.description,
                baseURL: choice.baseURL
            )
            return
        }

        activeSession = nil
        activePreview = RoomPreviewDestination(
            roomId: choice.room.id,
            roomName: choice.room.name,
            roomDescription: choice.room.description,
            baseURL: choice.baseURL,
            room: choice.room
        )
    }

    @MainActor
    private func refreshRooms() async {
        clientVisibility = await fetchClientVisibility(baseURL: normalizedBaseURL)
        guard clientVisibility.ios else {
            roomGroups = []
            errorMessage = ""
            return
        }

        isLoading = true
        errorMessage = ""
        defer { isLoading = false }

        do {
            let bases = await fetchFederationBases()
            let allRooms = try await fetchRoomsAcrossServers(bases: bases)
            roomGroups = groupRooms(allRooms: allRooms, fallbackBase: normalizedBaseURL)
        } catch {
            roomGroups = []
            errorMessage = "Could not load federated rooms."
        }
    }

    private func fetchFederationBases() async -> [String] {
        var bases: [String] = [normalizedBaseURL]
        guard let statusURL = URL(string: "\(normalizedBaseURL)/api/federation/status") else {
            return bases
        }
        var request = URLRequest(url: statusURL)
        request.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return bases
            }
            let raw = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let trusted = (raw["trustedServers"] as? [String]) ?? []
            let normalizedTrusted = trusted.map { normalizeBaseURL($0) }
            bases.append(contentsOf: normalizedTrusted)
        } catch {
            // Keep base list with current server only.
        }
        return Array(Set(bases)).sorted()
    }

    private func fetchRoomsAcrossServers(bases: [String]) async throws -> [(RoomSummary, String)] {
        try await withThrowingTaskGroup(of: [(RoomSummary, String)].self) { group in
            for base in bases {
                group.addTask {
                    let endpoint = "\(base)/api/rooms?source=app&sort=activity"
                    guard let url = URL(string: endpoint) else { return [] }
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 12
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        return []
                    }
                    let rooms = try JSONDecoder().decode([RoomSummary].self, from: data)
                    return rooms.map { ($0, base) }
                }
            }

            var combined: [(RoomSummary, String)] = []
            for try await entries in group {
                combined.append(contentsOf: entries)
            }
            return combined
        }
    }

    private func groupRooms(allRooms: [(RoomSummary, String)], fallbackBase: String) -> [FederatedRoomGroup] {
        var dedupedByExactKey: [String: (RoomSummary, String)] = [:]
        for (room, fetchedBase) in allRooms {
            let resolvedBase = room.serverApiBase.isEmpty ? fetchedBase : normalizeBaseURL(room.serverApiBase)
            let exactKey = "\(canonicalRoomName(room.name))|\(resolvedBase)|\(room.id)"
            dedupedByExactKey[exactKey] = (room, resolvedBase)
        }

        let grouped = Dictionary(grouping: dedupedByExactKey.values) { entry in
            canonicalRoomName(entry.0.name)
        }

        return grouped.map { key, entries in
            let sortedChoices = entries
                .map { room, resolvedBase in
                    FederatedRoomChoice(
                        id: "\(resolvedBase)|\(room.id)",
                        room: room,
                        serverLabel: displayServerName(room: room, fallbackBase: resolvedBase),
                        baseURL: resolvedBase.isEmpty ? fallbackBase : resolvedBase
                    )
                }
                .sorted {
                    if $0.serverLabel == $1.serverLabel {
                        return $0.room.userCount > $1.room.userCount
                    }
                    return $0.serverLabel.localizedCaseInsensitiveCompare($1.serverLabel) == .orderedAscending
                }

            let displayName = sortedChoices.first?.room.name ?? "Untitled Room"
            let totalUsers = sortedChoices.reduce(0) { $0 + $1.room.userCount }
            return FederatedRoomGroup(
                id: key,
                displayName: displayName,
                totalUsers: totalUsers,
                choices: sortedChoices
            )
        }
        .sorted { lhs, rhs in
            if lhs.totalUsers == rhs.totalUsers {
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            return lhs.totalUsers > rhs.totalUsers
        }
    }
}

private struct FederationRoomChoicesView: View {
    let group: FederatedRoomGroup
    let onOpen: (FederatedRoomChoice, String) -> Void

    var body: some View {
        List {
            Section("Room") {
                LabeledContent("Name", value: group.displayName)
                LabeledContent("Servers", value: "\(group.choices.count)")
                LabeledContent("Users", value: "\(group.totalUsers)")
            }

            Section("Choose Server") {
                ForEach(group.choices) { choice in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(choice.serverLabel)
                            .font(.headline)
                        Text("\(choice.room.userCount) users")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Join") { onOpen(choice, "join") }
                                .buttonStyle(.borderedProminent)
                            Button("Preview") { onOpen(choice, "preview") }
                                .buttonStyle(.bordered)
                        }
                    }
                    .contextMenu {
                        Button("Join Room") { onOpen(choice, "join") }
                        Button("Preview Room") { onOpen(choice, "preview") }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(group.displayName) on \(choice.serverLabel), \(choice.room.userCount) users")
                    .accessibilityAction(named: Text("Join Room")) { onOpen(choice, "join") }
                    .accessibilityAction(named: Text("Preview Room")) { onOpen(choice, "preview") }
                }
            }
        }
        .navigationTitle(group.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MessagesTab: View {
    @Binding var serverURL: String
    @ObservedObject var roomState: IOSRoomMessagingState
    @State private var directMessageDraft = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Room Messages") {
                    if roomState.isInRoom {
                        if roomState.roomMessages.isEmpty {
                            Text("No room messages yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(roomState.roomMessages.suffix(150).reversed()) { message in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(message.author)
                                            .font(.subheadline.weight(.semibold))
                                        Spacer()
                                        Text(message.roomName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(message.body)
                                        .font(.body)
                                    Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    } else {
                        Text("Not in a room. Tap a room to join.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section(roomState.isInRoom ? "Direct Message User" : "Direct Message Contacts") {
                    if roomState.directTargets.isEmpty {
                        Text("No direct-message contacts available yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(roomState.directTargets) { target in
                            Button {
                                roomState.selectedDirectTarget = target
                            } label: {
                                HStack {
                                    Text(target.name)
                                    Spacer()
                                    if roomState.selectedDirectTarget?.id == target.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                    }

                    if let selected = roomState.selectedDirectTarget {
                        Text("Selected: \(selected.name)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        TextField("Message user…", text: $directMessageDraft, axis: .vertical)
                            .lineLimit(1...4)
                        Button("Send") {
                            roomState.sendDirectMessage(directMessageDraft)
                            directMessageDraft = ""
                        }
                        .disabled(
                            !roomState.isInRoom ||
                            roomState.selectedDirectTarget == nil ||
                            directMessageDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    }

                    if !roomState.isInRoom {
                        Text("Tap a room to join before sending direct messages.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let profile = roomState.selectedProfileName {
                    Section("Profile") {
                        Text(profile)
                        Text("Profile actions are shown from room user actions.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if !roomState.statusText.isEmpty {
                    Section("Status") {
                        Text(roomState.statusText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Messages")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct AdminTabView: View {
    @Binding var serverURL: String
    @AppStorage("voicelink.authToken") private var authToken = ""
    @State private var isLoading = false
    @State private var statusText = "Not checked"
    @State private var serverName = "Unknown"
    @State private var maxUsers = "—"
    @State private var maxRooms = "—"
    @State private var draftAdminURL = ""
    @State private var isAdmin = false
    @State private var adminRole = "user"
    @State private var adminAccessMessage = "Checking access..."

    private var normalizedBaseURL: String { normalizeBaseURL(serverURL) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Access") {
                    LabeledContent("Role", value: adminRole.capitalized)
                    LabeledContent("Admin Access", value: isAdmin ? "Granted" : "Restricted")
                    Text(adminAccessMessage)
                        .font(.footnote)
                        .foregroundColor(isAdmin ? .secondary : .orange)
                }

                if isAdmin {
                    Section("Server Configuration") {
                        TextField("Server URL", text: $draftAdminURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .submitLabel(.go)
                            .onSubmit { applyAdminServerURL() }
                        Button("Apply Server URL") {
                            applyAdminServerURL()
                        }
                    }
                }

                Section("Server Health") {
                    LabeledContent("Status", value: statusText)
                    Button("Refresh Status") { Task { await refreshStatus() } }
                        .disabled(isLoading)
                }

                Section("Server Config") {
                    LabeledContent("Name", value: serverName)
                    LabeledContent("Max Users", value: maxUsers)
                    LabeledContent("Max Rooms", value: maxRooms)
                }
            }
            .navigationTitle("Admin")
            .onAppear {
                draftAdminURL = serverURL
                Task { await refreshStatus() }
            }
        }
    }

    private func applyAdminServerURL() {
        let trimmed = draftAdminURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        serverURL = trimmed
        Task { await refreshStatus() }
    }

    @MainActor
    private func refreshStatus() async {
        isLoading = true
        defer { isLoading = false }

        guard let healthURL = URL(string: "\(normalizedBaseURL)/api/health"),
              let configURL = URL(string: "\(normalizedBaseURL)/api/config"),
              let adminStatusURL = URL(string: "\(normalizedBaseURL)/api/admin/status") else {
            statusText = "Invalid server URL"
            return
        }

        do {
            let (_, response) = try await URLSession.shared.data(from: healthURL)
            if let http = response as? HTTPURLResponse {
                statusText = (200...299).contains(http.statusCode) ? "Online" : "HTTP \(http.statusCode)"
            } else {
                statusText = "Unknown"
            }
        } catch {
            statusText = "Offline"
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: configURL)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            serverName = (json["serverName"] as? String) ?? serverName
            if let value = json["maxUsers"] as? Int { maxUsers = "\(value)" }
            if let value = json["maxRooms"] as? Int { maxRooms = "\(value)" }
        } catch {
            // keep previous values
        }

        do {
            var request = URLRequest(url: adminStatusURL)
            request.timeoutInterval = 12
            if !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
                request.setValue(authToken, forHTTPHeaderField: "x-session-token")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                isAdmin = false
                adminRole = "user"
                adminAccessMessage = "Not authenticated for admin API access."
                return
            }
            isAdmin = (json["isAdmin"] as? Bool) ?? false
            adminRole = String((json["role"] as? String) ?? "user")
            adminAccessMessage = isAdmin
                ? "Server API confirms this account can manage settings."
                : "Signed-in role is not admin."
        } catch {
            isAdmin = false
            adminRole = "user"
            adminAccessMessage = "Could not verify admin role right now."
        }
    }
}

private struct SettingsTab: View {
    @Environment(\.openURL) private var openURL
    @AppStorage("voicelink.audio.inputGain") private var inputGain: Double = 1.0
    @AppStorage("voicelink.audio.outputGain") private var outputGain: Double = 1.0
    @AppStorage("voicelink.audio.mediaMuted") private var mediaMuted = false
    @AppStorage("showUserStatusesInRoomList") private var showUserStatusesInRoomList = true
    @AppStorage("allowVoiceInRoomPreview") private var allowVoiceInRoomPreview = true
    @AppStorage("systemActionNotifications") private var systemActionNotificationsEnabled = true
    @AppStorage("systemActionNotificationSound") private var systemActionNotificationSoundEnabled = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Audio") {
                    Toggle("Mute Media Playback", isOn: $mediaMuted)
                    VStack(alignment: .leading) {
                        Text("Input Level")
                        Slider(value: $inputGain, in: 0...2)
                    }
                    VStack(alignment: .leading) {
                        Text("Output Level")
                        Slider(value: $outputGain, in: 0...2)
                    }
                }

                Section("Interface") {
                    Toggle("Show User Statuses in Room Lists", isOn: $showUserStatusesInRoomList)
                    Toggle("Allow My Voice in Room Preview", isOn: $allowVoiceInRoomPreview)
                    Text("Room screens support VoiceOver actions. In a room, use two-finger double-tap to hear who is speaking.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Notifications") {
                    Toggle("Enable System Action Push Notifications", isOn: $systemActionNotificationsEnabled)
                        .onChange(of: systemActionNotificationsEnabled) { enabled in
                            if enabled {
                                requestNotificationAuthorizationIfNeeded()
                            }
                    }
                    Toggle("Play Sound for System Action Notifications", isOn: $systemActionNotificationSoundEnabled)
                }

                Section("Help and Policies") {
                    Link("Privacy Policy", destination: URL(string: "https://voicelink.devinecreations.net/docs/privacy-policy.html")!)
                    Link("User Privacy Choices", destination: URL(string: "https://voicelink.devinecreations.net/docs/user-privacy-choices.html")!)
                    Link("Support and Contact", destination: URL(string: "https://voicelink.devinecreations.net/docs/contact.html")!)
                    Link("Downloads and Getting Started", destination: URL(string: "https://voicelink.devinecreations.net/downloads/")!)
                    Button("Open Main Website") {
                        guard let url = URL(string: "https://voicelink.devinecreations.net") else { return }
                        openURL(url)
                    }
                }

            }
            .navigationTitle("Settings")
        }
    }

    private func requestNotificationAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
            }
        }
    }
}

private func normalizeBaseURL(_ rawURL: String) -> String {
    let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return "https://voicelink.devinecreations.net"
    }
    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
        return trimmed.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }
    return "https://\(trimmed)"
}

private func canonicalRoomName(_ name: String) -> String {
    let lowered = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return lowered.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
}

private func displayServerName(room: RoomSummary, fallbackBase: String) -> String {
    let trimmedTitle = room.serverTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedTitle.isEmpty {
        return trimmedTitle
    }
    let trimmedDomain = room.serverDomain.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedDomain.isEmpty {
        return trimmedDomain
    }
    if let host = URL(string: fallbackBase)?.host, !host.isEmpty {
        return host
    }
    return room.serverSource.isEmpty ? "Unknown Server" : room.serverSource.capitalized
}

private func displayVisibilityLabel(_ raw: String) -> String {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "public":
        return "Public"
    case "private":
        return "Private"
    case "unlisted":
        return "Unlisted"
    default:
        return raw.isEmpty ? "Public" : raw.capitalized
    }
}

private func displayAccessTypeLabel(_ raw: String) -> String {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "hybrid":
        return "Desktop, iOS, Web"
    case "app-only":
        return "Desktop, iOS"
    case "web-only":
        return "Web"
    case "hidden":
        return "Hidden"
    default:
        return raw.isEmpty ? "Desktop, iOS, Web" : raw.capitalized
    }
}

private func fetchClientVisibility(baseURL: String) async -> ClientVisibilitySettings {
    guard let url = URL(string: "\(normalizeBaseURL(baseURL))/api/config") else {
        return .allVisible
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 10

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return .allVisible
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let visibility = json["serverVisibility"] as? [String: Any]
        else {
            return .allVisible
        }

        return ClientVisibilitySettings(
            desktop: (visibility["desktop"] as? Bool) ?? true,
            ios: (visibility["ios"] as? Bool) ?? true,
            web: (visibility["web"] as? Bool) ?? true,
            frontendOpen: (visibility["frontendOpen"] as? Bool) ?? true
        )
    } catch {
        return .allVisible
    }
}
