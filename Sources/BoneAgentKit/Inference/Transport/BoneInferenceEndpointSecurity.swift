import Foundation

/// 统一在端点解析后校验最终 URL，防止绝对 operation endpoint 绕过策略。
public enum BoneInferenceEndpointSecurity {
    public static func resolveAndValidate(
        baseURL: URL,
        endpoint: String,
        policy: BoneInferenceEndpointSecurityPolicy
    ) throws -> URL {
        guard !endpoint.isEmpty else {
            return try validate(baseURL, policy: policy)
        }
        guard baseURL.query == nil, baseURL.fragment == nil else {
            throw BoneInferenceTransportError.invalidEndpoint
        }
        let resolved: URL?
        if let absolute = URL(string: endpoint), absolute.scheme != nil {
            resolved = absolute
        } else {
            let normalizedPath = "/" + endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let basePath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !basePath.isEmpty,
               normalizedPath == "/\(basePath)" || normalizedPath.hasPrefix("/\(basePath)/") {
                var components = URLComponents()
                components.scheme = baseURL.scheme
                components.host = baseURL.host
                components.port = baseURL.port
                components.path = normalizedPath
                resolved = components.url
            } else {
                var components = URLComponents()
                components.scheme = baseURL.scheme
                components.host = baseURL.host
                components.port = baseURL.port
                let normalizedBasePath = basePath.isEmpty ? "" : "/\(basePath)"
                components.path = normalizedBasePath + normalizedPath
                resolved = components.url
            }
        }
        guard let resolved else { throw BoneInferenceTransportError.invalidEndpoint }
        return try validate(resolved, policy: policy)
    }

    @discardableResult
    public static func validate(
        _ url: URL,
        policy: BoneInferenceEndpointSecurityPolicy
    ) throws -> URL {
        guard let scheme = url.scheme?.lowercased(),
              let rawHost = url.host,
              !rawHost.isEmpty,
              scheme == "https" || scheme == "http"
        else {
            throw BoneInferenceTransportError.insecureEndpoint
        }
        if scheme == "https" { return url }
        guard policy == .custom, isPrivateHTTPHost(rawHost) else {
            throw BoneInferenceTransportError.insecureEndpoint
        }
        return url
    }

    private static func isPrivateHTTPHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host == "::1" { return true }
        if let firstIPv6Group = firstIPv6Group(host) {
            return (0xFC00 ... 0xFDFF).contains(firstIPv6Group)
                || (0xFE80 ... 0xFEBF).contains(firstIPv6Group)
        }
        guard let octets = ipv4Octets(host) else { return false }
        switch octets {
        case let value where value[0] == 10:
            return true
        case let value where value[0] == 127:
            return true
        case let value where value[0] == 169 && value[1] == 254:
            return true
        case let value where value[0] == 172 && (16 ... 31).contains(value[1]):
            return true
        case let value where value[0] == 192 && value[1] == 168:
            return true
        default:
            return false
        }
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let values = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part), (0 ... 255).contains(value) else {
                return nil
            }
            return value
        }
        return values.count == 4 ? values : nil
    }

    private static func firstIPv6Group(_ host: String) -> Int? {
        guard host.contains(":"), let group = host.split(separator: ":", omittingEmptySubsequences: true).first else {
            return nil
        }
        return Int(group, radix: 16)
    }
}
