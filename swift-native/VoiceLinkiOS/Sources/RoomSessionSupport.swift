import SwiftUI

struct RoomSessionDestination: Identifiable, Hashable {
    let roomId: String
    let roomName: String
    let roomDescription: String
    let baseURL: String
    let displayName: String

    var id: String { "\(baseURL)|\(roomId)|join" }
}

struct RoomPreviewDestination: Identifiable, Hashable {
    let roomId: String
    let roomName: String
    let roomDescription: String
    let baseURL: String
    let room: RoomSummary

    var id: String { "\(baseURL)|\(roomId)|preview" }
}

struct RoomSessionView: View {
    @Environment(\.dismiss) private var dismiss
    let destination: RoomSessionDestination
    @State private var showChat = true

    private var roomURL: URL? {
        var components = URLComponents(string: normalizedRoomBaseURL(destination.baseURL))
        let existingItems = components?.queryItems ?? []
        components?.queryItems = existingItems + [
            URLQueryItem(name: "room", value: destination.roomId),
            URLQueryItem(name: "join", value: "1"),
            URLQueryItem(name: "client", value: "ios")
        ]
        return components?.url
    }

    var body: some View {
        NavigationStack {
            Group {
                if let roomURL {
                    VoiceLinkWebView(
                        url: roomURL,
                        displayName: destination.displayName,
                        showChat: showChat
                    )
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Room Unavailable")
                            .font(.headline)
                        Text("The room link could not be prepared.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                }
            }
            .navigationTitle(destination.roomName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(showChat ? "Hide Chat" : "Show Chat") {
                        showChat.toggle()
                    }
                }
            }
        }
        .onAppear {
            IOSAudioSessionManager.shared.activateForRoomSession()
            NotificationCenter.default.post(
                name: .iosRoomJoined,
                object: nil,
                userInfo: ["roomId": destination.roomId, "roomName": destination.roomName]
            )
        }
        .onChange(of: showChat) { visible in
            NotificationCenter.default.post(
                name: .iosSetRoomChatVisibility,
                object: nil,
                userInfo: ["visible": visible]
            )
        }
        .onDisappear {
            IOSAudioSessionManager.shared.deactivateRoomSessionIfPossible()
            NotificationCenter.default.post(
                name: .iosRoomLeft,
                object: nil,
                userInfo: ["roomId": destination.roomId, "roomName": destination.roomName]
            )
        }
    }
}

struct RoomPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let destination: RoomPreviewDestination

    private var previewURL: URL? {
        var components = URLComponents(string: normalizedRoomBaseURL(destination.baseURL))
        let existingItems = components?.queryItems ?? []
        components?.queryItems = existingItems + [
            URLQueryItem(name: "room", value: destination.roomId),
            URLQueryItem(name: "preview", value: "1"),
            URLQueryItem(name: "client", value: "ios")
        ]
        return components?.url
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Room") {
                    LabeledContent("Name", value: destination.roomName)
                    LabeledContent("Room ID", value: destination.roomId)
                    LabeledContent("Users", value: "\(destination.room.userCount)")
                    if !destination.roomDescription.isEmpty {
                        Text(destination.roomDescription)
                    }
                }

                Section("Actions") {
                    if let previewURL {
                        Link("Open Preview in Web Room", destination: previewURL)
                    }
                    Button("Close") { dismiss() }
                }
            }
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

extension Notification.Name {
    static let iosOpenMessagesTab = Notification.Name("iosOpenMessagesTab")
    static let iosShowUserProfile = Notification.Name("iosShowUserProfile")
    static let iosRoomJoined = Notification.Name("iosRoomJoined")
    static let iosRoomLeft = Notification.Name("iosRoomLeft")
    static let iosRoomUsersUpdated = Notification.Name("iosRoomUsersUpdated")
    static let iosRoomMessageEvent = Notification.Name("iosRoomMessageEvent")
    static let iosDirectMessageEvent = Notification.Name("iosDirectMessageEvent")
    static let iosRequestLeaveRoom = Notification.Name("iosRequestLeaveRoom")
    static let iosSendDirectMessage = Notification.Name("iosSendDirectMessage")
    static let iosSetRoomChatVisibility = Notification.Name("iosSetRoomChatVisibility")
}

private func normalizedRoomBaseURL(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return "https://voicelink.devinecreations.net"
    }
    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
        return trimmed.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }
    return "https://\(trimmed)"
}
