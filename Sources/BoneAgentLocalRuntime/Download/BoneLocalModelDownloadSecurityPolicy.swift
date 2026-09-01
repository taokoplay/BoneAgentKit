import Foundation

public enum BoneLocalModelDownloadSecurityPolicy {
    public static func validate(
        _ url: URL,
        for source: BoneLocalModelDownloadSource
    ) throws {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              source.allowedHosts.contains(where: { hostMatches(host, allowed: $0) }) else {
            throw BoneLocalModelDownloadError.untrustedURL
        }
    }

    public static func orderedSources(
        _ sources: [BoneLocalModelDownloadSource]
    ) -> [BoneLocalModelDownloadSource] {
        sources.enumerated().sorted {
            if $0.element.priority == $1.element.priority {
                return $0.offset < $1.offset
            }
            return $0.element.priority < $1.element.priority
        }.map(\.element)
    }

    private static func hostMatches(_ host: String, allowed: String) -> Bool {
        let value = allowed.lowercased()
        if value == host { return true }
        guard value.hasPrefix("*.") else { return false }
        let suffix = String(value.dropFirst(1))
        return host.hasSuffix(suffix) && host.count > suffix.count
    }
}
