import Foundation

/// Stable, value-free errors. URLs, response bodies and credentials are never attached.
public enum BoneWebError: String, Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    case invalidConfiguration = "web_invalid_configuration"
    case invalidInput = "web_invalid_input"
    case invalidURL = "web_invalid_url"
    case hostNotAllowed = "web_host_not_allowed"
    case scopeDenied = "web_scope_denied"
    case requestFailed = "web_request_failed"
    case redirectNotAllowed = "web_redirect_not_allowed"
    case httpFailure = "web_http_failure"
    case responseTooLarge = "web_response_too_large"
    case unsupportedContentType = "web_unsupported_content_type"
    case invalidResponse = "web_invalid_response"

    public var errorDescription: String? { rawValue }
    public var description: String { rawValue }
}

public enum BoneWebLimits {
    public static let maximumPageResponseBytes = 2 * 1_024 * 1_024
    public static let maximumSearchResponseBytes = 1_024 * 1_024
    public static let maximumOutputBytes = 32 * 1_024
    public static let defaultTextBytes = 16 * 1_024
    public static let maximumURLBytes = 8_192
    public static let maximumQueryBytes = 2_048
    public static let maximumTitleBytes = 1_024
    public static let maximumSearchTitleBytes = 512
    public static let maximumSnippetBytes = 2_048
}

/// Exact ASCII DNS hosts, with no wildcards or implicit subdomain permission.
/// This is URL filtering, not complete SSRF protection. The host network layer must
/// enforce public destination addresses on every connection, including DNS rebinding.
public struct BoneWebHostPolicy: Equatable, Sendable {
    public let allowedHosts: Set<String>

    public init(allowedHosts: [String]) throws {
        guard !allowedHosts.isEmpty else { throw BoneWebError.invalidConfiguration }
        var hosts = Set<String>()
        for host in allowedHosts {
            guard BoneWebValidation.isPublicDNSHost(host) else {
                throw BoneWebError.invalidConfiguration
            }
            hosts.insert(host.lowercased())
        }
        self.allowedHosts = hosts
    }

    @discardableResult
    public func validate(url: String) throws -> URL {
        let result = try BoneWebValidation.publicHTTPSURL(url)
        guard let host = result.host?.lowercased(), allowedHosts.contains(host) else {
            throw BoneWebError.hostNotAllowed
        }
        return result
    }
}

/// Text and search results are external data, never instructions or authorization.
public enum BoneWebContentTrust: String, Codable, Equatable, Sendable {
    case untrustedData = "untrusted_data"
}

enum BoneWebValidation {
    static func isPublicDNSHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253, host.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            return false
        }
        let name = host.lowercased()
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }), let suffix = labels.last,
              suffix.utf8.count >= 2,
              suffix.utf8.allSatisfy({ (97...122).contains($0) }) || suffix.hasPrefix("xn--") else {
            return false
        }
        let localSuffixes = ["localhost", "local", "localdomain", "internal", "intranet", "lan",
                             "home", "home.arpa", "arpa", "corp", "private", "onion", "test", "invalid"]
        return !localSuffixes.contains { name == $0 || name.hasSuffix("." + $0) }
    }

    static func publicHTTPSURL(_ value: String) throws -> URL {
        guard !value.isEmpty, value.utf8.count <= BoneWebLimits.maximumURLBytes,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: value),
              parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
              parts.fragment == nil, parts.port == nil || parts.port == 443,
              let host = parts.host, isPublicDNSHost(host),
              let url = parts.url, url.host?.lowercased() == host.lowercased() else {
            throw BoneWebError.invalidURL
        }
        return url
    }

    static func requireKeys(_ decoder: any Decoder, allowed: Set<String>) throws {
        let container = try decoder.container(keyedBy: BoneWebCodingKey.self)
        guard container.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw BoneWebError.invalidInput
        }
    }

    static func finiteDate(_ value: Date) -> Bool { value.timeIntervalSince1970.isFinite }

    static func provider(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count) && value.utf8.allSatisfy {
            (97...122).contains($0) || (65...90).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    static func encodedSize<T: Encodable>(_ value: T) throws -> Int {
        do { return try JSONEncoder().encode(value).count }
        catch { throw BoneWebError.invalidResponse }
    }

    static func prefix(_ value: String, bytes maximum: Int) -> String {
        guard value.utf8.count > maximum else { return value }
        var bytes = Array(value.utf8.prefix(maximum))
        while !bytes.isEmpty {
            if let result = String(bytes: bytes, encoding: .utf8) { return result }
            bytes.removeLast()
        }
        return ""
    }
}

private struct BoneWebCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

func boneWebSafeError(_ error: any Error) -> any Error {
    if error is CancellationError || Task.isCancelled { return CancellationError() }
    if let error = error as? URLError, error.code == .cancelled { return CancellationError() }
    return (error as? BoneWebError) ?? .requestFailed
}
