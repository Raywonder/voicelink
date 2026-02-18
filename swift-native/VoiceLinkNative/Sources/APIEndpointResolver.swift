import Foundation

enum APIEndpointResolver {
    static let canonicalMainBase = "https://voicelink.devinecreations.net"
    static let localBase = "http://localhost:4004"

    // Ordered fallback list for production API/domain outages.
    private static let mainFallbackBases = [
        "https://64.20.46.178",
        "https://64.20.46.179"
    ]

    static func normalize(_ base: String) -> String {
        base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func mainBaseCandidates(preferred: String? = nil) -> [String] {
        var candidates: [String] = []
        candidates.append(canonicalMainBase)
        candidates.append(contentsOf: mainFallbackBases)
        if let preferred, !preferred.isEmpty {
            candidates.append(normalize(preferred))
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    static func apiBaseCandidates(preferred: String? = nil) -> [String] {
        mainBaseCandidates(preferred: preferred)
    }

    static func url(base: String, path: String) -> URL? {
        let normalizedBase = normalize(base)
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(string: "\(normalizedBase)/\(normalizedPath)")
    }
}
