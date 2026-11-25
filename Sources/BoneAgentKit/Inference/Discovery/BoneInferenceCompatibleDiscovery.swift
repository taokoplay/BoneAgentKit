import Foundation

/// Discovery rules for user-configured compatible gateways, separate from chat routing.
enum BoneInferenceCompatibleDiscovery: Sendable {
    case openAI
    case anthropic

    init?(entry: BoneInferenceProviderCatalog.Entry) {
        guard entry.catalogMode == .remote, entry.discovery == nil else { return nil }
        switch (entry.ident, entry.providerProtocol, entry.apiPaths["models"]) {
        case ("OpenAICompatible", .customOpenAI, "/models"): self = .openAI
        case ("AnthropicCompatible", .anthropic, "/v1/models"): self = .anthropic
        default: return nil
        }
    }

    func endpoint(baseURL: URL, requiresOperation: Bool = false) throws -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw BoneInferenceTransportError.invalidEndpoint
        }
        var path = components.percentEncodedPath
        while path.last == "/" { path.removeLast() }
        let suffixes = ["/chat/completions", "/responses", "/messages", "/models"]
        if let operation = suffixes.first(where: { path.hasSuffix($0) }) {
            switch (self, operation) {
            case (_, "/models"), (.openAI, "/chat/completions"), (.anthropic, "/messages"):
                path.removeLast(operation.count)
            default: return nil
            }
        } else if requiresOperation {
            return nil
        }
        if self == .anthropic {
            if !path.hasSuffix("/v1") { path += "/v1" }
            components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
        }
        components.percentEncodedPath = path + "/models"
        guard let url = components.url, BoneInferenceRedirectPolicy.allows(from: baseURL, to: url) else {
            throw BoneInferenceTransportError.invalidEndpoint
        }
        return url
    }

    func fallback(after endpoint: URL) -> URL? {
        guard self == .openAI,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              components.percentEncodedPath.hasSuffix("/models"),
              !components.percentEncodedPath.hasSuffix("/v1/models") else { return nil }
        components.percentEncodedPath = components.percentEncodedPath.dropLast("/models".count) + "/v1/models"
        guard let url = components.url, BoneInferenceRedirectPolicy.allows(from: endpoint, to: url) else { return nil }
        return url
    }
}
