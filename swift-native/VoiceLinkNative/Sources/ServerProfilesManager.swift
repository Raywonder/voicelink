import Foundation

struct ServerProfile: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var url: String
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String, url: String, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
    }
}

final class ServerProfilesManager: ObservableObject {
    static let shared = ServerProfilesManager()

    @Published private(set) var profiles: [ServerProfile] = []
    @Published var multiServerDirectoryEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(multiServerDirectoryEnabled, forKey: "multiServerDirectoryEnabled")
        }
    }

    private let storageKey = "serverProfiles"

    private init() {
        load()
    }

    func addProfile(name: String, url: String) -> Bool {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleanedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty, !cleanedURL.isEmpty else { return false }

        if !cleanedURL.hasPrefix("http://") && !cleanedURL.hasPrefix("https://") {
            cleanedURL = "https://" + cleanedURL
        }

        guard URL(string: cleanedURL) != nil else { return false }
        guard !profiles.contains(where: { $0.url.caseInsensitiveCompare(cleanedURL) == .orderedSame }) else {
            return false
        }

        profiles.append(ServerProfile(name: cleanedName, url: cleanedURL))
        save()
        return true
    }

    func removeProfile(_ profile: ServerProfile) {
        profiles.removeAll { $0.id == profile.id }
        save()
    }

    func updateEnabled(_ profile: ServerProfile, enabled: Bool) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].isEnabled = enabled
        save()
    }

    func enabledProfiles() -> [ServerProfile] {
        profiles.filter { $0.isEnabled }
    }

    private func load() {
        multiServerDirectoryEnabled = UserDefaults.standard.bool(forKey: "multiServerDirectoryEnabled")
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data) else {
            profiles = []
            return
        }
        profiles = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
