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
    @AppStorage("voicelink.authToken") private var authToken = ""
    @AppStorage("voicelink.audio.inputGain") private var inputGain: Double = 1.0
    @AppStorage("voicelink.audio.outputGain") private var outputGain: Double = 1.0
    @AppStorage("voicelink.audio.mediaMuted") private var mediaMuted = false
    let destination: RoomSessionDestination
    @State private var showChat = true
    @State private var showDetails = false
    @State private var showControls = false

    private var isSignedIn: Bool {
        !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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
                        showChat: showChat,
                        inputGain: inputGain,
                        outputGain: outputGain,
                        mediaMuted: mediaMuted
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
                    Menu {
                        Button(showChat ? "Hide Chat" : "Show Chat") {
                            showChat.toggle()
                            IOSActionSoundPlayer.playToggle()
                        }
                        Button("Room Controls") {
                            showControls = true
                            IOSActionSoundPlayer.playConfirm()
                        }
                        Button("Room Details") {
                            showDetails = true
                            IOSActionSoundPlayer.playConfirm()
                        }
                        Divider()
                        Button("Leave Room", role: .destructive) {
                            IOSActionSoundPlayer.playClose()
                            NotificationCenter.default.post(
                                name: .iosRequestLeaveRoom,
                                object: nil,
                                userInfo: [
                                    "roomId": destination.roomId,
                                    "roomName": destination.roomName
                                ]
                            )
                            dismiss()
                        }

                        if isSignedIn {
                            // Reserved for future signed-in room actions parity.
                        }
                    } label: {
                        Label("Room Menu", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showDetails) {
                NavigationStack {
                    List {
                        Section("Room") {
                            LabeledContent("Name", value: destination.roomName)
                            LabeledContent("Room ID", value: destination.roomId)
                            if !destination.roomDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(destination.roomDescription)
                            }
                        }
                    }
                    .navigationTitle("Room Details")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { showDetails = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $showControls) {
                NavigationStack {
                    Form {
                        Section("Room Controls") {
                            Toggle("Show Chat", isOn: $showChat)
                                .onChange(of: showChat) { _ in
                                    IOSActionSoundPlayer.playToggle()
                                }
                        }

                        Section("Audio") {
                            Slider(value: $inputGain, in: 0...2) {
                                Text("Mic Level")
                            } minimumValueLabel: {
                                Text("0%")
                            } maximumValueLabel: {
                                Text("200%")
                            }
                            .accessibilityValue("\(Int(inputGain * 100)) percent")

                            Slider(value: $outputGain, in: 0...2) {
                                Text("Master Output")
                            } minimumValueLabel: {
                                Text("0%")
                            } maximumValueLabel: {
                                Text("200%")
                            }
                            .accessibilityValue("\(Int(outputGain * 100)) percent")

                            Toggle("Mute Media Playback", isOn: $mediaMuted)
                                .onChange(of: mediaMuted) { _ in
                                    IOSActionSoundPlayer.playToggle()
                                }
                        }
                    }
                    .navigationTitle("Room Controls")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { showControls = false }
                        }
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
    @AppStorage("voicelink.displayName") private var displayName = ""
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
            Group {
                if let previewURL {
                    VoiceLinkWebView(
                        url: previewURL,
                        displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Guest" : displayName,
                        showChat: false,
                        inputGain: 1.0,
                        outputGain: 1.0,
                        mediaMuted: false
                    )
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Preview Unavailable")
                            .font(.headline)
                        Text("The preview link could not be prepared.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            IOSAudioSessionManager.shared.activateForRoomSession()
        }
        .onDisappear {
            IOSAudioSessionManager.shared.deactivateRoomSessionIfPossible()
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
