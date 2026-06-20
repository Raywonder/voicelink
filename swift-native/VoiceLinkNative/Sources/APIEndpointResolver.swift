import Foundation

enum APIEndpointResolver {
    static let canonicalMainBase = "https://voicelinkapp.app"
    static let communityNode2Base = "https://community.voicelinkapp.app"
    static let devineCreationsComBase = "https://devine-creations.com/voicelink"
    static let devineCreationsNetBase = "https://devinecreations.net/voicelink"
    static let localBase = "http://127.0.0.1:3010"
    static let localSecondaryBase = "http://127.0.0.1:3011"
    static let localStagingBase = "http://127.0.0.1:3012"

    private static let localBases = [
        localBase,
        localSecondaryBase,
        localStagingBase
    ]

    // Trusted federated peers should be preferred before public fallbacks.
    private static let federatedBases = [
        communityNode2Base,
        devineCreationsComBase,
        devineCreationsNetBase,
    ]

    // Do not use public IP HTTPS fallbacks in app/admin flows. The certificate
    // is issued for domains, so IP-based HTTPS creates false SSL failures.
    private static let publicFallbackBases: [String] = []

    static func normalize(_ base: String) -> String {
        base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func transportFallbackCandidates(for base: String) -> [String] {
        let normalized = normalize(base)
        guard !normalized.isEmpty else { return [] }

        if let components = URLComponents(string: normalized), let scheme = components.scheme?.lowercased() {
            switch scheme {
            case "https":
                if isLocalOrPrivate(normalized) {
                    var httpComponents = components
                    httpComponents.scheme = "http"
                    let httpVariant = httpComponents.url.map { normalize($0.absoluteString) }
                    return [httpVariant, normalized].compactMap { $0 }.removingDuplicates()
                }
                return [normalized]
            case "http":
                if isLocalOrPrivate(normalized) {
                    var httpsComponents = components
                    httpsComponents.scheme = "https"
                    let httpsVariant = httpsComponents.url.map { normalize($0.absoluteString) }
                    return [normalized, httpsVariant].compactMap { $0 }.removingDuplicates()
                }
                var httpsComponents = components
                httpsComponents.scheme = "https"
                let httpsVariant = httpsComponents.url.map { normalize($0.absoluteString) }
                return [httpsVariant].compactMap { $0 }.removingDuplicates()
            default:
                return [normalized]
            }
        }

        if isLocalOrPrivate(normalized) {
            return [
                "http://\(normalized)",
                "https://\(normalized)"
            ].removingDuplicates()
        }

        return [
            "https://\(normalized)"
        ].removingDuplicates()
    }

    static func preferredSecureCandidate(for base: String) -> String? {
        transportFallbackCandidates(for: base).first { candidate in
            URLComponents(string: candidate)?.scheme?.lowercased() == "https"
        }
    }

    private static func isLocalOrPrivate(_ base: String) -> Bool {
        guard let host = URL(string: normalize(base))?.host?.lowercased(), !host.isEmpty else {
            return false
        }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" {
            return true
        }
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("100.") {
            return true
        }
        if host.hasPrefix("172."),
           let secondOctet = host.split(separator: ".").dropFirst().first,
           let value = Int(secondOctet),
           (16...31).contains(value) {
            return true
        }
        return false
    }

    static func mainBaseCandidates(preferred: String? = nil) -> [String] {
        var candidates: [String] = []
        if let preferred, !preferred.isEmpty {
            candidates.append(normalize(preferred))
        }
        if preferred == nil || !isLocalOrPrivate(preferred ?? "") {
            candidates.append(contentsOf: localBases)
        }
        candidates.append(contentsOf: federatedBases)
        candidates.append(canonicalMainBase)
        candidates.append(contentsOf: publicFallbackBases)

        var expanded: [String] = []
        for candidate in candidates {
            expanded.append(contentsOf: transportFallbackCandidates(for: candidate))
        }

        var seen = Set<String>()
        return expanded.filter { seen.insert($0).inserted }
    }

    static func apiBaseCandidates(preferred: String? = nil) -> [String] {
        mainBaseCandidates(preferred: preferred)
    }

    static func remoteMainBaseCandidates(preferred: String? = nil) -> [String] {
        var candidates: [String] = []
        if let preferred, !preferred.isEmpty, !isLocalOrPrivate(preferred) {
            candidates.append(normalize(preferred))
        }
        candidates.append(contentsOf: federatedBases)
        candidates.append(canonicalMainBase)
        candidates.append(contentsOf: publicFallbackBases)

        var expanded: [String] = []
        for candidate in candidates {
            expanded.append(contentsOf: transportFallbackCandidates(for: candidate))
        }

        var seen = Set<String>()
        return expanded.filter { seen.insert($0).inserted }
    }

    static func url(base: String, path: String) -> URL? {
        let normalizedBase = normalize(base)
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(string: "\(normalizedBase)/\(normalizedPath)")
    }
}

private extension Array where Element == String {
    func removingDuplicates() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
