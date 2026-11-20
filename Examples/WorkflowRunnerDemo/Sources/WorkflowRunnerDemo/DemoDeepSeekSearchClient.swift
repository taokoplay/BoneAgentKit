import Foundation
import BoneAgentTools
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Official standalone Search API. Independent of the selected chat Provider/model.
struct DemoDeepSeekSearchClient: BoneWebSearchClient, CustomStringConvertible, CustomDebugStringConvertible {
    private let apiKey: String
    private let transport: any BoneWebHTTPTransport
    static let endpoint = URL(string: "https://api.deepseek.com/v1/tools/search")!
    var description: String { "DemoDeepSeekSearchClient(provider: deepseek)" }
    var debugDescription: String { description }

    init(apiKey: String, transport: any BoneWebHTTPTransport = DemoSearchPOSTTransport()) throws {
        guard !apiKey.isEmpty, apiKey.utf8.count <= 4_096,
              apiKey.utf8.allSatisfy({ (33...126).contains($0) }) else { throw BoneWebError.invalidConfiguration }
        self.apiKey = apiKey
        self.transport = transport
    }
    func search(input: BoneWebSearchInput) async throws -> BoneWebSearchOutput {
        do {
            try Task.checkCancellation()
            guard input.page == 0 else { throw DemoSearchError.unsupportedPage }
            guard !input.query.isEmpty, input.query.unicodeScalars.count <= 128 else { throw DemoSearchError.invalidQuery }
            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(SearchBody(query: input.query, count: input.count, need_content: false))
            let response = try await transport.send(request: request, maximumResponseBytes: 1_048_576)
            try Task.checkCancellation()
            guard response.url == Self.endpoint, !(300...399).contains(response.statusCode) else { throw BoneWebError.redirectNotAllowed }
            guard response.statusCode == 200 else { throw BoneWebError.httpFailure }
            guard response.body.count <= 1_048_576 else { throw BoneWebError.responseTooLarge }
            guard response.header("Content-Type")?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else {
                throw BoneWebError.unsupportedContentType
            }
            let envelope = try JSONDecoder().decode(Envelope.self, from: response.body)
            guard envelope.results.count <= input.count else { throw BoneWebError.invalidResponse }
            let results = try envelope.results.map { item in
                try Task.checkCancellation()
                guard !item.title.contains(apiKey), !item.snippet.contains(apiKey), !item.url.contains(apiKey) else { throw BoneWebError.invalidResponse }
                return try BoneWebSearchResult(title: prefix(item.title, maximumBytes: 512), url: item.url,
                                               snippet: prefix(item.snippet, maximumBytes: 2_048))
            }
            return try .init(results: results, provider: "deepseek", nextPage: nil)
        } catch is CancellationError { throw CancellationError() }
        catch let error as DemoSearchError { throw error }
        catch let error as BoneWebError { throw error }
        catch { throw BoneWebError.requestFailed }
    }
    private func prefix(_ value: String, maximumBytes: Int) -> String {
        var bytes = Array(value.utf8.prefix(maximumBytes))
        while !bytes.isEmpty {
            if let text = String(bytes: bytes, encoding: .utf8) { return text }
            bytes.removeLast()
        }
        return ""
    }
    private struct SearchBody: Encodable { let query: String; let count: Int; let need_content: Bool }
    private struct Envelope: Decodable {
        let results: [Item]
        struct Item: Decodable { let title: String; let url: String; let snippet: String }
    }
}
