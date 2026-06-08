import SwiftUI

// MARK: - Rooms Section
struct AdminRoomsSection: View {
    @ObservedObject var adminManager = AdminServerManager.shared
    @State private var showCreateRoom = false
    @State private var roomBeingEdited: AdminRoomInfo?
    @State private var roomSearchText = ""
    @State private var roomPendingDelete: AdminRoomInfo?

    private var filteredRooms: [AdminRoomInfo] {
        let query = roomSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return adminManager.serverRooms }
        return adminManager.serverRooms.filter { room in
            room.name.lowercased().contains(query)
                || room.description.lowercased().contains(query)
                || room.id.lowercased().contains(query)
                || (room.visibility?.lowercased().contains(query) ?? false)
                || (room.accessType?.lowercased().contains(query) ?? false)
                || (room.hostServerName?.lowercased().contains(query) ?? false)
                || (room.serverSource?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Server Rooms (\(adminManager.serverRooms.count))")
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()

                Button(action: { showCreateRoom = true }) {
                    Label("Create Room", systemImage: "plus")
                }
                .buttonStyle(.bordered)

                Button(action: {
                    Task { await adminManager.fetchRooms() }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Room Management Permissions")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Global Policy")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.9))
                    Text("Server roles (admin/moderator/owner) control who can manage rooms across the server.")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Individual Room Override")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.9))
                    Text("Each room can still require owner identity match. Use the room row menu to edit room-level metadata/access.")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                Text("If users report \"settings denied\", verify both global role assignment and per-room ownership identity.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(12)
            .background(Color.white.opacity(0.05))
            .cornerRadius(10)

            VStack(alignment: .leading, spacing: 10) {
                TextField("Search rooms by name, ID, visibility, or access level", text: $roomSearchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Room search")
                    .accessibilityHint("Filter the room list by room name, room ID, visibility, or access settings.")

                Text("Showing \(filteredRooms.count) of \(adminManager.serverRooms.count) rooms")
                    .font(.caption)
                    .foregroundColor(.gray)
                Text("Only one room per server/source is shown here. Duplicate entries from the same server are merged.")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            LazyVStack(spacing: 10) {
                ForEach(filteredRooms) { room in
                    RoomAdminRow(room: room) { action in
                        switch action {
                        case .delete:
                            roomPendingDelete = room
                        case .edit:
                            roomBeingEdited = room
                        }
                    }
                }
            }
        }
        .sheet(item: $roomBeingEdited) { room in
            AdminRoomEditSheet(room: room) { updatedRoom in
                Task {
                    _ = await adminManager.updateRoom(updatedRoom)
                    await adminManager.fetchRooms()
                }
                roomBeingEdited = nil
            }
        }
        .task {
            await adminManager.fetchRooms()
        }
        .confirmationDialog(
            roomPendingDelete == nil ? "Delete room" : "Delete \(roomPendingDelete?.name ?? "room")?",
            isPresented: Binding(
                get: { roomPendingDelete != nil },
                set: { if !$0 { roomPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let room = roomPendingDelete, room.userCount > 0 {
                Button("Disable Room Instead") {
                    Task {
                        var disabled = room
                        disabled.hidden = true
                        disabled.enabled = false
                        disabled.locked = true
                        _ = await adminManager.updateRoom(disabled)
                        await adminManager.fetchRooms()
                    }
                    roomPendingDelete = nil
                }
            }

            Button("Delete Room", role: .destructive) {
                guard let room = roomPendingDelete else { return }
                Task {
                    _ = await adminManager.deleteRoom(room.id)
                    await adminManager.fetchRooms()
                }
                roomPendingDelete = nil
            }

            Button("Cancel", role: .cancel) {
                roomPendingDelete = nil
            }
        } message: {
            if let room = roomPendingDelete, room.userCount > 0 {
                Text("This room currently has \(room.userCount) user(s). Disable it first or move users to another room before deleting.")
            } else {
                Text("This permanently removes the room from the server.")
            }
        }
    }
}

// MARK: - Room Admin Row
struct RoomAdminRow: View {
    let room: AdminRoomInfo
    let onAction: (RoomAction) -> Void

    enum RoomAction {
        case edit, delete
    }

    private var roomSourceLabel: String {
        room.hostServerName ?? room.serverSource ?? "Current Server"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(room.name)
                        .foregroundColor(.white)
                    if room.isPrivate {
                        Image(systemName: "lock.fill")
                            .foregroundColor(.yellow)
                            .font(.caption)
                    }
                    if room.isPermanent {
                        Image(systemName: "pin.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                    }
                    if room.locked == true {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                    }
                }
                Text(room.description)
                    .font(.caption)
                    .foregroundColor(.gray)
                Text("Displayed from: \(roomSourceLabel)")
                    .font(.caption2)
                    .foregroundColor(.mint)
                if let owner = room.hostServerOwner, !owner.isEmpty {
                    Text("Server owner: \(owner)")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                if let updatedBy = room.updatedBy, !updatedBy.isEmpty {
                    Text("Last updated by: \(updatedBy)\(room.updatedAt.map { " on \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")")
                        .font(.caption2)
                        .foregroundColor(.orange)
                } else if let updatedAt = room.updatedAt {
                    Text("Last updated: \(updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
                if !room.previousNames.isEmpty {
                    Text("Prior names: \(room.previousNames.prefix(5).joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundColor(.purple)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    Text("Visibility: \(room.visibility ?? (room.isPrivate ? "private" : "public"))")
                    Text("Access: \(room.accessType ?? "hybrid")")
                    if room.hidden == true {
                        Text("Hidden")
                    }
                    if room.enabled == false {
                        Text("Disabled")
                    }
                }
                .font(.caption2)
                .foregroundColor(.blue)
            }

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "person.fill")
                Text("Total users in room: \(room.userCount) of \(room.maxUsers) max")
            }
            .font(.caption)
            .foregroundColor(.white.opacity(0.6))

            Menu {
                Button(action: { onAction(.edit) }) {
                    Label("Edit", systemImage: "pencil")
                }
                Button(role: .destructive, action: { onAction(.delete) }) {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundColor(.gray)
            }
            .menuStyle(.borderlessButton)
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(10)
    }
}

struct AdminRoomEditSheet: View {
    @State private var draft: AdminRoomInfo
    let onSave: (AdminRoomInfo) -> Void
    @Environment(\.dismiss) private var dismiss

    init(room: AdminRoomInfo, onSave: @escaping (AdminRoomInfo) -> Void) {
        _draft = State(initialValue: room)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Room")
                .font(.headline)

            ConfigTextField(label: "Name", text: Binding(
                get: { draft.name },
                set: { draft.name = $0 }
            ))

            ConfigTextField(label: "Description", text: Binding(
                get: { draft.description },
                set: { draft.description = $0 }
            ))

            ConfigTextField(
                label: "Room Welcome Message",
                placeholder: "Optional room-specific greeting, links, or instructions for people who open this room.",
                helpText: "Shown in room details and in-room welcome messaging when configured.",
                text: Binding(
                    get: { draft.welcomeMessage ?? "" },
                    set: { draft.welcomeMessage = $0.isEmpty ? nil : $0 }
                )
            )

            HStack(spacing: 16) {
                ConfigNumberField(label: "Max Users", value: Binding(
                    get: { draft.maxUsers },
                    set: { draft.maxUsers = max(1, $0) }
                ))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Visibility")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Picker("Visibility", selection: Binding(
                        get: { draft.visibility ?? (draft.isPrivate ? "private" : "public") },
                        set: {
                            draft.visibility = $0
                            draft.isPrivate = ($0 == "private")
                        }
                    )) {
                        Text("Public").tag("public")
                        Text("Unlisted").tag("unlisted")
                        Text("Private").tag("private")
                    }
                    .pickerStyle(.segmented)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Room Type")
                    .font(.caption)
                    .foregroundColor(.gray)
                Picker("Room Type", selection: Binding(
                    get: { draft.accessType ?? "hybrid" },
                    set: { draft.accessType = $0 }
                )) {
                    Text("Hybrid").tag("hybrid")
                    Text("App Only").tag("app-only")
                    Text("Web Only").tag("web-only")
                    Text("Hidden").tag("hidden")
                }
                .pickerStyle(.segmented)
            }

            ConfigToggle(label: "Private", isOn: Binding(
                get: { draft.isPrivate },
                set: {
                    draft.isPrivate = $0
                    draft.visibility = $0 ? "private" : (draft.visibility == "private" ? "public" : draft.visibility)
                }
            ))
            ConfigToggle(label: "Hidden", isOn: Binding(
                get: { draft.hidden ?? false },
                set: { draft.hidden = $0 }
            ))
            ConfigToggle(label: "Locked", isOn: Binding(
                get: { draft.locked ?? false },
                set: { draft.locked = $0 }
            ))
            ConfigTextField(
                label: "Room PIN",
                placeholder: "Optional PIN for quick locked-room entry",
                helpText: "When set, members can use this PIN to enter a locked room without waiting for approval. Leave blank to remove it.",
                text: Binding(
                    get: { draft.accessPin ?? "" },
                    set: { draft.accessPin = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                )
            )
            ConfigToggle(label: "Allow Recording in This Room", isOn: Binding(
                get: { draft.recordingAllowed ?? AdminServerManager.shared.serverConfig?.recordingEnabled ?? false },
                set: { draft.recordingAllowed = $0 }
            ))
            ConfigToggle(label: "Enabled", isOn: Binding(
                get: { draft.enabled ?? true },
                set: { draft.enabled = $0 }
            ))
            ConfigToggle(label: "Default Room", isOn: Binding(
                get: { draft.isDefault ?? false },
                set: { draft.isDefault = $0 }
            ))

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Save") {
                    onSave(draft)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
    }
}
