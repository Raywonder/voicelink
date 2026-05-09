import Foundation
import SwiftUI
import Combine
import UserNotifications
import Contacts

/// User Status Manager
/// Manages custom status (online, away, busy, etc.) and status messages
/// - Syncs across web app and desktop apps
/// - Supports status messages up to 1000 characters
/// - Supports clickable links in messages
class StatusManager: ObservableObject {
    static let shared = StatusManager()

    // MARK: - State

    @Published var currentStatus: UserStatus = .online
    @Published var statusMessage: String = ""
    @Published var customStatuses: [CustomStatus] = []
    @Published var syncWithSystemFocus: Bool = false
    @Published var syncWithContactCard: Bool = false

    private var focusSyncTimer: Timer?
    private var contactSyncTimer: Timer?
    private var focusAppliedDND = false
    private var statusBeforeFocusDND: UserStatus = .online
    private var messageBeforeFocusDND: String = ""

    // MARK: - Types

    enum UserStatus: String, Codable, CaseIterable {
        case online = "online"
        case away = "away"
        case busy = "busy"
        case doNotDisturb = "dnd"
        case invisible = "invisible"
        case custom = "custom"

        var displayName: String {
            switch self {
            case .online: return "Online"
            case .away: return "Away"
            case .busy: return "Busy"
            case .doNotDisturb: return "Do Not Disturb"
            case .invisible: return "Invisible"
            case .custom: return "Custom"
            }
        }

        var icon: String {
            switch self {
            case .online: return "circle.fill"
            case .away: return "moon.fill"
            case .busy: return "minus.circle.fill"
            case .doNotDisturb: return "bell.slash.fill"
            case .invisible: return "eye.slash"
            case .custom: return "star.fill"
            }
        }

        var color: Color {
            switch self {
            case .online: return .green
            case .away: return .yellow
            case .busy: return .orange
            case .doNotDisturb: return .red
            case .invisible: return .gray
            case .custom: return .purple
            }
        }
    }

    struct CustomStatus: Codable, Identifiable, Equatable {
        let id: String
        var name: String
        var icon: String      // SF Symbol name
        var colorHex: String
        var message: String

        init(name: String, icon: String = "star.fill", colorHex: String = "#9B59B6", message: String = "") {
            self.id = UUID().uuidString
            self.name = name
            self.icon = icon
            self.colorHex = colorHex
            self.message = message
        }

        var color: Color {
            Color(hex: colorHex) ?? .purple
        }
    }

    struct StatusUpdate: Codable {
        let status: String
        let message: String
        let customStatusId: String?
        let timestamp: Date
    }

    // MARK: - Constants

    static let maxMessageLength = 1000
    static let presetMessages = [
        "Back in 5 minutes",
        "In a meeting",
        "Working from home",
        "On vacation",
        "Streaming - twitch.tv/username",
        "Check out my project: https://github.com/username/project"
    ]

    // MARK: - Initialization

    init() {
        loadSettings()
        setupNotifications()
        configureFocusSync()
        configureContactCardSync()
    }

    // MARK: - Status Management

    /// Set user status
    func setStatus(_ status: UserStatus, message: String? = nil) {
        currentStatus = status

        if let msg = message {
            statusMessage = String(msg.prefix(StatusManager.maxMessageLength))
        }

        // Play sound feedback
        AppSoundManager.shared.playButtonClickSound()

        // Broadcast to server
        broadcastStatusUpdate()

        // Save settings
        saveSettings()

        print("StatusManager: Status set to \(status.displayName)" +
              (statusMessage.isEmpty ? "" : " with message"))
    }

    /// Set status message only (keeps current status)
    func setMessage(_ message: String) {
        statusMessage = String(message.prefix(StatusManager.maxMessageLength))
        broadcastStatusUpdate()
        saveSettings()
    }

    /// Clear status message
    func clearMessage() {
        statusMessage = ""
        broadcastStatusUpdate()
        saveSettings()
    }

    /// Set online status (convenience method)
    func goOnline() {
        setStatus(.online)
    }

    /// Set away status
    func goAway(message: String? = nil) {
        setStatus(.away, message: message)
    }

    /// Set busy status
    func goBusy(message: String? = nil) {
        setStatus(.busy, message: message)
    }

    /// Set do not disturb
    func setDoNotDisturb(message: String? = nil) {
        setStatus(.doNotDisturb, message: message)
    }

    /// Go invisible
    func goInvisible() {
        setStatus(.invisible)
    }

    // MARK: - Custom Statuses

    /// Add a custom status
    func addCustomStatus(_ customStatus: CustomStatus) {
        customStatuses.append(customStatus)
        saveSettings()
    }

    /// Remove a custom status
    func removeCustomStatus(id: String) {
        customStatuses.removeAll { $0.id == id }
        saveSettings()
    }

    /// Update a custom status
    func updateCustomStatus(_ customStatus: CustomStatus) {
        if let index = customStatuses.firstIndex(where: { $0.id == customStatus.id }) {
            customStatuses[index] = customStatus
            saveSettings()
        }
    }

    /// Set a custom status as active
    func setCustomStatus(_ customStatus: CustomStatus) {
        currentStatus = .custom
        statusMessage = customStatus.message
        broadcastStatusUpdate(customStatusId: customStatus.id)
        saveSettings()
    }

    // MARK: - Server Communication

    private func broadcastStatusUpdate(customStatusId: String? = nil) {
        let update = StatusUpdate(
            status: currentStatus.rawValue,
            message: statusMessage,
            customStatusId: customStatusId,
            timestamp: Date()
        )

        // Send via socket
        NotificationCenter.default.post(
            name: .statusChanged,
            object: nil,
            userInfo: [
                "status": currentStatus.rawValue,
                "message": statusMessage,
                "customStatusId": customStatusId as Any
            ]
        )

        // Also send to server if connected
        if let data = try? JSONEncoder().encode(update) {
            // ServerManager will handle the actual socket emit
            NotificationCenter.default.post(
                name: .sendStatusToServer,
                object: nil,
                userInfo: ["data": data]
            )
        }
    }

    // MARK: - Link Detection

    /// Extract links from status message
    func extractLinks(from message: String) -> [URL] {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: message, range: NSRange(message.startIndex..., in: message)) ?? []

        return matches.compactMap { match in
            guard let range = Range(match.range, in: message) else { return nil }
            return URL(string: String(message[range]))
        }
    }

    /// Create attributed string with clickable links
    func attributedMessage(_ message: String) -> AttributedString {
        if let markdownAttributed = attributedMarkdownMessage(message) {
            return markdownAttributed
        }

        var attributed = AttributedString(message)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: message, range: NSRange(message.startIndex..., in: message)) ?? []

        for match in matches.reversed() {
            guard let range = Range(match.range, in: message),
                  let url = match.url,
                  let attrRange = Range(range, in: attributed) else { continue }

            attributed[attrRange].link = url
            attributed[attrRange].foregroundColor = .blue
            attributed[attrRange].underlineStyle = .single
        }

        return attributed
    }

    private func attributedMarkdownMessage(_ message: String) -> AttributedString? {
        let pattern = #"\[([^\]]+)\]\((https?://[^\s)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let nsRange = NSRange(message.startIndex..., in: message)
        let matches = regex.matches(in: message, range: nsRange)
        guard !matches.isEmpty else { return nil }

        var plainMessage = ""
        var cursor = message.startIndex
        var linkRanges: [(range: Range<String.Index>, url: URL)] = []

        for match in matches {
            guard
                let fullRange = Range(match.range(at: 0), in: message),
                let titleRange = Range(match.range(at: 1), in: message),
                let urlRange = Range(match.range(at: 2), in: message),
                let url = URL(string: String(message[urlRange]))
            else {
                continue
            }

            plainMessage.append(contentsOf: message[cursor..<fullRange.lowerBound])
            let linkStart = plainMessage.endIndex
            plainMessage.append(contentsOf: message[titleRange])
            let linkEnd = plainMessage.endIndex
            linkRanges.append((linkStart..<linkEnd, url))
            cursor = fullRange.upperBound
        }

        plainMessage.append(contentsOf: message[cursor...])
        var attributed = AttributedString(plainMessage)

        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let autoLinkMatches = detector?.matches(in: plainMessage, range: NSRange(plainMessage.startIndex..., in: plainMessage)) ?? []
        for match in autoLinkMatches.reversed() {
            guard
                let range = Range(match.range, in: plainMessage),
                let url = match.url,
                let attrRange = Range(range, in: attributed)
            else {
                continue
            }
            attributed[attrRange].link = url
            attributed[attrRange].foregroundColor = .blue
            attributed[attrRange].underlineStyle = .single
        }

        for (range, url) in linkRanges {
            guard let attrRange = Range(range, in: attributed) else { continue }
            attributed[attrRange].link = url
            attributed[attrRange].foregroundColor = .blue
            attributed[attrRange].underlineStyle = .single
        }

        return attributed
    }

    // MARK: - Notifications

    private func setupNotifications() {
        // Listen for server status updates (from other clients)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleIncomingStatusUpdate),
            name: .incomingStatusUpdate,
            object: nil
        )
    }

    private func configureFocusSync() {
        focusSyncTimer?.invalidate()
        guard syncWithSystemFocus else {
            focusAppliedDND = false
            return
        }

        evaluateSystemFocusAndApplyStatus()
        focusSyncTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.evaluateSystemFocusAndApplyStatus()
        }
    }

    func setSyncWithSystemFocus(_ enabled: Bool) {
        syncWithSystemFocus = enabled
        if !enabled, focusAppliedDND {
            focusAppliedDND = false
            setStatus(statusBeforeFocusDND, message: messageBeforeFocusDND)
        }
        saveSettings()
    }

    private func applyFocusSyncedStatus(sourceLabel: String) {
        let syncedMessage = "Synced with \(sourceLabel) Do Not Disturb"
        if !focusAppliedDND && currentStatus != .doNotDisturb {
            statusBeforeFocusDND = currentStatus
            messageBeforeFocusDND = statusMessage
        }
        focusAppliedDND = true
        setDoNotDisturb(message: syncedMessage)
    }

    private func evaluateSystemFocusAndApplyStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            guard let self = self else { return }

            // Best-effort: if alerts are disabled, mirror as DND.
            let alertsSuppressed = settings.authorizationStatus == .denied || settings.alertSetting == .disabled

            DispatchQueue.main.async {
                guard self.syncWithSystemFocus else { return }

                if alertsSuppressed {
                    if !self.focusAppliedDND || self.currentStatus != .doNotDisturb || self.statusMessage != "Synced with macOS Focus Do Not Disturb" {
                        self.applyFocusSyncedStatus(sourceLabel: "macOS Focus")
                    }
                } else if self.focusAppliedDND {
                    self.focusAppliedDND = false
                    self.setStatus(self.statusBeforeFocusDND, message: self.messageBeforeFocusDND)
                }
            }
        }
    }

    private func configureContactCardSync() {
        contactSyncTimer?.invalidate()
        guard syncWithContactCard else { return }

        contactSyncTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.syncFromContactCard()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard self?.syncWithContactCard == true else { return }
            self?.syncFromContactCard()
        }
    }

    func setSyncWithContactCard(_ enabled: Bool) {
        syncWithContactCard = enabled
        saveSettings()
    }

    func syncContactCardNow() {
        syncFromContactCard()
    }

    private func syncFromContactCard() {
        let store = CNContactStore()
        let auth = CNContactStore.authorizationStatus(for: .contacts)

        func normalizedProfileURL(_ raw: String) -> String? {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let lower = value.lowercased()
            if !lower.hasPrefix("http://") &&
                !lower.hasPrefix("https://") &&
                !lower.hasPrefix("mailto:") &&
                !lower.hasPrefix("tel:") {
                value = "https://\(value)"
            }
            guard let components = URLComponents(string: value),
                  let scheme = components.scheme,
                  !scheme.isEmpty else { return nil }
            return components.string
        }

        func socialProfileURL(_ profile: CNSocialProfile) -> String? {
            let directURL = profile.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !directURL.isEmpty, let normalized = normalizedProfileURL(directURL) {
                return normalized
            }

            let username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !username.isEmpty else { return nil }
            let clean = username.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            let service = profile.service.lowercased()

            if service.contains("mastodon") {
                let parts = clean.split(separator: "@", omittingEmptySubsequences: true).map(String.init)
                if parts.count >= 2 {
                    let user = parts[0]
                    let host = parts[1]
                    return "https://\(host)/@\(user)"
                }
                return "https://mastodon.social/@\(clean)"
            }
            if service.contains("github") {
                return "https://github.com/\(clean)"
            }
            if service.contains("twitter") || service == "x" {
                return "https://x.com/\(clean)"
            }
            if service.contains("bluesky") {
                return "https://bsky.app/profile/\(clean)"
            }
            if service.contains("linkedin") {
                return "https://www.linkedin.com/in/\(clean)"
            }
            if service.contains("youtube") {
                return "https://www.youtube.com/@\(clean)"
            }
            if service.contains("instagram") {
                return "https://www.instagram.com/\(clean)"
            }
            return nil
        }

        func applyMeCardProfile(_ contact: CNContact) {
            let nickname = contact.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            let given = contact.givenName.trimmingCharacters(in: .whitespacesAndNewlines)
            let family = contact.familyName.trimmingCharacters(in: .whitespacesAndNewlines)
            let full = "\(given) \(family)".trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = !nickname.isEmpty ? nickname : (!full.isEmpty ? full : given)
            let primaryEmail = contact.emailAddresses.first?.value as String?
            let primaryPhone = contact.phoneNumbers.first?.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let company = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
            let jobTitle = contact.jobTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let postal = contact.postalAddresses.first?.value
            let address = [postal?.street, postal?.city, postal?.state, postal?.postalCode, postal?.country]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")

            var links: [String] = []
            if contact.isKeyAvailable(CNContactUrlAddressesKey) {
                for item in contact.urlAddresses {
                    let value = String(item.value)
                    if let normalized = normalizedProfileURL(value) {
                        links.append(normalized)
                    }
                }
            }
            if contact.isKeyAvailable(CNContactSocialProfilesKey) {
                for item in contact.socialProfiles {
                    if let normalized = socialProfileURL(item.value) {
                        links.append(normalized)
                    }
                }
            }

            var deduped: [String] = []
            var seen = Set<String>()
            for link in links {
                let key = link.lowercased()
                if !seen.contains(key) {
                    seen.insert(key)
                    deduped.append(link)
                }
            }

            DispatchQueue.main.async {
                if !resolved.isEmpty {
                    SettingsManager.shared.userNickname = resolved
                }
                SettingsManager.shared.mergeProfileLinks(deduped)
                SettingsManager.shared.saveSettings()

                 let contactCard = AuthenticatedUser.ContactCard(
                    fullName: full.isEmpty ? nil : full,
                    firstName: given.isEmpty ? nil : given,
                    lastName: family.isEmpty ? nil : family,
                    nickname: nickname.isEmpty ? nil : nickname,
                    company: company.isEmpty ? nil : company,
                    email: primaryEmail?.isEmpty == false ? primaryEmail : nil,
                    phone: primaryPhone?.isEmpty == false ? primaryPhone : nil,
                    address: address.isEmpty ? nil : address,
                    city: postal?.city.isEmpty == false ? postal?.city : nil,
                    state: postal?.state.isEmpty == false ? postal?.state : nil,
                    postalCode: postal?.postalCode.isEmpty == false ? postal?.postalCode : nil,
                    country: postal?.country.isEmpty == false ? postal?.country : nil,
                    website: deduped.first,
                    // Accessing the Me card note has caused Contacts to fault during startup on macOS 15.
                    // Keep launch safe and leave notes unset for contact-card auto-sync.
                    notes: nil,
                    organisationRole: jobTitle.isEmpty ? nil : jobTitle,
                    source: "macos-contact-card",
                    importFormats: ["auto", "contact-card", "vcard"],
                    autoSyncedAt: Date()
                )
                AuthenticationManager.shared.syncCurrentUserContactCard(contactCard) { _, _ in }
            }
        }

        let fetchMeCard: () -> Void = {
            do {
                let keys: [CNKeyDescriptor] = [
                    CNContactNicknameKey as NSString,
                    CNContactGivenNameKey as NSString,
                    CNContactFamilyNameKey as NSString,
                    CNContactOrganizationNameKey as NSString,
                    CNContactJobTitleKey as NSString,
                    CNContactEmailAddressesKey as NSString,
                    CNContactPhoneNumbersKey as NSString,
                    CNContactPostalAddressesKey as NSString,
                    CNContactUrlAddressesKey as NSString,
                    CNContactSocialProfilesKey as NSString
                ]
                let me = try store.unifiedMeContactWithKeys(toFetch: keys)
                applyMeCardProfile(me)
            } catch {
                // Best effort; leave current nickname unchanged.
            }
        }

        switch auth {
        case .authorized:
            fetchMeCard()
        case .notDetermined:
            store.requestAccess(for: .contacts) { granted, _ in
                if granted { fetchMeCard() }
            }
        default:
            break
        }
    }

    @objc private func handleIncomingStatusUpdate(_ notification: Notification) {
        guard let data = notification.userInfo?["data"] as? Data,
              let update = try? JSONDecoder().decode(StatusUpdate.self, from: data) else { return }

        DispatchQueue.main.async {
            // Handle incoming status from other user (for displaying in UI)
            NotificationCenter.default.post(
                name: .userStatusUpdated,
                object: nil,
                userInfo: [
                    "status": update.status,
                    "message": update.message
                ]
            )
        }
    }

    // MARK: - Persistence

    private func loadSettings() {
        if let statusRaw = UserDefaults.standard.string(forKey: "userStatus"),
           let status = UserStatus(rawValue: statusRaw) {
            currentStatus = status
        }

        statusMessage = UserDefaults.standard.string(forKey: "statusMessage") ?? ""

        if let data = UserDefaults.standard.data(forKey: "customStatuses"),
           let statuses = try? JSONDecoder().decode([CustomStatus].self, from: data) {
            customStatuses = statuses
        } else {
            // Create default custom statuses
            customStatuses = [
                CustomStatus(name: "Gaming", icon: "gamecontroller.fill", colorHex: "#9B59B6"),
                CustomStatus(name: "Streaming", icon: "video.fill", colorHex: "#E74C3C"),
                CustomStatus(name: "Coding", icon: "chevron.left.forwardslash.chevron.right", colorHex: "#3498DB")
            ]
        }

        syncWithSystemFocus = UserDefaults.standard.object(forKey: "syncWithSystemFocus") as? Bool ?? false
        syncWithContactCard = UserDefaults.standard.object(forKey: "syncWithContactCard") as? Bool ?? false
    }

    private func saveSettings() {
        UserDefaults.standard.set(currentStatus.rawValue, forKey: "userStatus")
        UserDefaults.standard.set(statusMessage, forKey: "statusMessage")

        if let data = try? JSONEncoder().encode(customStatuses) {
            UserDefaults.standard.set(data, forKey: "customStatuses")
        }

        UserDefaults.standard.set(syncWithSystemFocus, forKey: "syncWithSystemFocus")
        UserDefaults.standard.set(syncWithContactCard, forKey: "syncWithContactCard")
        configureFocusSync()
        configureContactCardSync()
    }

    // MARK: - Status

    func getStatusInfo() -> [String: Any] {
        return [
            "status": currentStatus.rawValue,
            "statusDisplayName": currentStatus.displayName,
            "message": statusMessage,
            "hasLinks": !extractLinks(from: statusMessage).isEmpty
        ]
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let statusChanged = Notification.Name("statusChanged")
    static let sendStatusToServer = Notification.Name("sendStatusToServer")
    static let incomingStatusUpdate = Notification.Name("incomingStatusUpdate")
    static let userStatusUpdated = Notification.Name("userStatusUpdated")
    static let masterVolumeChanged = Notification.Name("masterVolumeChanged")
}

// MARK: - Color Extension

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - SwiftUI Views

/// Status indicator circle
struct StatusIndicator: View {
    let status: StatusManager.UserStatus

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 10, height: 10)
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
            )
    }
}

/// Current status display with message
struct CurrentStatusView: View {
    @ObservedObject var statusManager = StatusManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                StatusIndicator(status: statusManager.currentStatus)

                Text(statusManager.currentStatus.displayName)
                    .font(.caption.bold())
                    .foregroundColor(statusManager.currentStatus.color)
            }

            if !statusManager.statusMessage.isEmpty {
                Text(statusManager.attributedMessage(statusManager.statusMessage))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

/// Status picker for changing status
struct StatusPickerView: View {
    @ObservedObject var statusManager = StatusManager.shared
    @State private var messageText: String = ""
    @State private var showCustomStatuses = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Built-in statuses
            Text("Set Status")
                .font(.headline)

            ForEach(StatusManager.UserStatus.allCases.filter { $0 != .custom }, id: \.self) { status in
                Button(action: { statusManager.setStatus(status) }) {
                    HStack {
                        Image(systemName: status.icon)
                            .foregroundColor(status.color)
                            .frame(width: 20)

                        Text(status.displayName)

                        Spacer()

                        if statusManager.currentStatus == status {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }

            Divider()

            // Custom statuses
            DisclosureGroup("Custom Statuses", isExpanded: $showCustomStatuses) {
                ForEach(statusManager.customStatuses) { customStatus in
                    Button(action: { statusManager.setCustomStatus(customStatus) }) {
                        HStack {
                            Image(systemName: customStatus.icon)
                                .foregroundColor(customStatus.color)
                                .frame(width: 20)

                            Text(customStatus.name)

                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                }
            }

            Divider()

            // Status message
            Text("Status Message")
                .font(.headline)

            TextField("What are you up to?", text: $messageText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    statusManager.setMessage(messageText)
                }

            Text("\(messageText.count)/\(StatusManager.maxMessageLength) characters")
                .font(.caption2)
                .foregroundColor(messageText.count > StatusManager.maxMessageLength ? .red : .gray)

            // Preset messages
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(StatusManager.presetMessages, id: \.self) { preset in
                        Button(preset) {
                            messageText = preset
                            statusManager.setMessage(preset)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(12)
                    }
                }
            }

            HStack {
                Button("Set Message") {
                    statusManager.setMessage(messageText)
                }
                .buttonStyle(.borderedProminent)
                .disabled(messageText.isEmpty || messageText.count > StatusManager.maxMessageLength)

                if !statusManager.statusMessage.isEmpty {
                    Button("Clear") {
                        messageText = ""
                        statusManager.clearMessage()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .onAppear {
            messageText = statusManager.statusMessage
        }
    }
}

/// Compact status selector for menu bar/toolbar
struct CompactStatusPicker: View {
    @ObservedObject var statusManager = StatusManager.shared

    var body: some View {
        Menu {
            ForEach(StatusManager.UserStatus.allCases.filter { $0 != .custom }, id: \.self) { status in
                Button(action: { statusManager.setStatus(status) }) {
                    Label(status.displayName, systemImage: status.icon)
                }
            }

            Divider()

            if !statusManager.customStatuses.isEmpty {
                ForEach(statusManager.customStatuses) { customStatus in
                    Button(action: { statusManager.setCustomStatus(customStatus) }) {
                        Label(customStatus.name, systemImage: customStatus.icon)
                    }
                }

                Divider()
            }

            if !statusManager.statusMessage.isEmpty {
                Button("Clear Status Message") {
                    statusManager.clearMessage()
                }
            }
        } label: {
            HStack(spacing: 4) {
                StatusIndicator(status: statusManager.currentStatus)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
        }
    }
}

/// User status display for user list items
struct UserStatusBadge: View {
    let status: StatusManager.UserStatus
    let message: String?

    var body: some View {
        HStack(spacing: 4) {
            StatusIndicator(status: status)

            if let msg = message, !msg.isEmpty {
                Text(msg)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}
