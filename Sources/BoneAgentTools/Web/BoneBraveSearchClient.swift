import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Brave's JSON API adapter. The subscription key is constructor-only, is sent only
/// in X-Subscription-Token, and is excluded from Codable configuration and descriptions.
/// The endpoint is fixed; redirects are refused, including same-host redirects.
public struct BoneBraveSearchClient: BoneWebSearchClient, CustomStringConvertible, CustomDebugStringConvertible {
    private let apiKey: String
    private let policy: BoneWebHostPolicy
    private let transport: any BoneWebHTTPTransport
    private let maximumResponseBytes: Int
    private let maximumOutputBytes: Int
    private static let endpoint = "https://api.search.brave.com/res/v1/web/search"

    public var description: String { "BoneBraveSearchClient(provider: brave)" }
    public var debugDescription: String { description }

    public init(apiKey: String, policy: BoneWebHostPolicy,
                transport: any BoneWebHTTPTransport = BoneURLSessionWebTransport(),
                maximumResponseBytes: Int = BoneWebLimits.maximumSearchResponseBytes,
                maximumOutputBytes: Int = BoneWebLimits.maximumOutputBytes) throws {
        guard (1...4_096).contains(apiKey.utf8.count), apiKey.unicodeScalars.allSatisfy({
            $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
        }), (1...BoneWebLimits.maximumSearchResponseBytes).contains(maximumResponseBytes),
              (1...BoneWebLimits.maximumOutputBytes).contains(maximumOutputBytes),
              (try? policy.validate(url: Self.endpoint)) != nil else { throw BoneWebError.invalidConfiguration }
        self.apiKey = apiKey
        self.policy = policy
        self.transport = transport
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumOutputBytes = maximumOutputBytes
    }

    public func search(input: BoneWebSearchInput) async throws -> BoneWebSearchOutput {
        do {
            try Task.checkCancellation()
            guard var components = URLComponents(string: Self.endpoint) else { throw BoneWebError.invalidConfiguration }
            // Brave uses a zero-based page offset, not page * count.
            components.queryItems = [URLQueryItem(name: "q", value: input.query),
                                     URLQueryItem(name: "count", value: String(input.count)),
                                     URLQueryItem(name: "offset", value: String(input.page))]
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let requestedURL = components.url else { throw BoneWebError.invalidInput }
            _ = try policy.validate(url: requestedURL.absoluteString)
            var request = URLRequest(url: requestedURL)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
            let response = try await transport.send(request: request, maximumResponseBytes: maximumResponseBytes)
            try Task.checkCancellation()
            try boneWebCheckResponse(response, requestedURL: requestedURL, policy: policy, maximumBytes: maximumResponseBytes)
            let mime = response.header("Content-Type")?.split(separator: ";").first?
                .trimmingCharacters(in: .whitespaces).lowercased()
            guard mime == "application/json" else { throw BoneWebError.unsupportedContentType }
            let envelope: BraveEnvelope
            do { envelope = try JSONDecoder().decode(BraveEnvelope.self, from: response.body) }
            catch { throw BoneWebError.invalidResponse }
            guard envelope.type == "search", envelope.web != nil || envelope.query != nil else {
                throw BoneWebError.invalidResponse
            }
            let items = envelope.web?.results ?? []
            guard items.count <= input.count else { throw BoneWebError.invalidResponse }
            let results = try items.map { item in
                try Task.checkCancellation()
                let title = try BoneWebStaticText.extract(item.title).text
                let snippet = try BoneWebStaticText.extract(item.description).text
                // Do not expose even an upstream echo of the constructor credential.
                guard !title.contains(apiKey), !snippet.contains(apiKey), !item.url.contains(apiKey) else {
                    throw BoneWebError.invalidResponse
                }
                return try BoneWebSearchResult(
                    title: BoneWebValidation.prefix(title, bytes: BoneWebLimits.maximumSearchTitleBytes),
                    url: item.url,
                    snippet: BoneWebValidation.prefix(snippet, bytes: BoneWebLimits.maximumSnippetBytes))
            }
            let more = envelope.query?.moreResultsAvailable == true
            let output = try BoneWebSearchOutput(results: results, provider: "brave",
                                                 nextPage: more && input.page < 9 ? input.page + 1 : nil)
            guard try BoneWebValidation.encodedSize(output) <= maximumOutputBytes else { throw BoneWebError.responseTooLarge }
            try Task.checkCancellation()
            return output
        } catch { throw boneWebSafeError(error) }
    }
}

private struct BraveEnvelope: Decodable {
    let type: String
    let query: Query?
    let web: Web?

    struct Query: Decodable {
        let moreResultsAvailable: Bool?
        enum CodingKeys: String, CodingKey { case moreResultsAvailable = "more_results_available" }
    }
    struct Web: Decodable { let results: [Result] }
    struct Result: Decodable {
        let title: String
        let url: String
        let description: String
    }
}
