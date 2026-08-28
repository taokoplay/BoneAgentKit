import Foundation

/// 防止调用方覆盖认证、路由和消息边界 Header。
public enum BoneInferenceHeaderPolicy {
    private static let reservedNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "x-api-key",
        "api-key",
        "x-goog-api-key",
        "cookie",
        "set-cookie",
        "host",
        "content-length",
        "content-type",
    ]

    public static func validated(_ headers: [String: String]) throws -> [String: String] {
        for name in headers.keys {
            guard isValidToken(name), !reservedNames.contains(name.lowercased()) else {
                throw BoneInferenceTransportError.reservedHeader
            }
        }
        return headers
    }

    private static func isValidToken(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count == value.count else { return false }
        let allowedPunctuation = Set("!#$%&'*+-.^_`|~".utf8)
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || allowedPunctuation.contains(byte)
        }
    }
}
