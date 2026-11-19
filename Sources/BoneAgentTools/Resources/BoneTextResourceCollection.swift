import Foundation
import BoneAgentKit

/// Bounded immutable in-memory texts. Import/parsing, storage, scope and revocation belong to the Host.
public struct BoneTextResourceCollection: Sendable {
    public struct Resource: Sendable {
        public let descriptor: BoneTextResourceDescriptor
        fileprivate let text: String
        fileprivate let snapshot: BoneToolTextResourceSnapshot
        public init(name: String, text: String, id: String = UUID().uuidString,
                    version: String = UUID().uuidString) throws {
            guard text.utf8.count <= 2 * 1_048_576 else { throw BoneResourceQueryError.capacityExceeded }
            snapshot = try .init(id: id, version: version, text: text)
            descriptor = try .init(name: name, reference: snapshot.reference)
            self.text = text
        }
    }
    private let resources: [Resource]
    public init(resources: [Resource]) throws {
        guard resources.count <= 64,
              resources.reduce(0, { $0 + $1.descriptor.reference.utf8ByteCount }) <= 8 * 1_048_576 else {
            throw BoneResourceQueryError.capacityExceeded
        }
        guard Set(resources.map { $0.descriptor.reference.id }).count == resources.count else {
            throw BoneResourceQueryError.duplicateResource
        }
        self.resources = resources
    }
    public func list(_ request: BoneTextResourceListRequest) throws -> BoneTextResourceListResult {
        _ = try request.validated(); try Task.checkCancellation()
        guard request.offset <= resources.count else { throw BoneResourceQueryError.invalidRequest }
        let end = min(resources.count, request.offset + request.limit)
        return .init(resources: resources[request.offset..<end].map(\.descriptor),
                     nextOffset: end < resources.count ? end : nil)
    }
    public func read(_ request: BoneToolTextResourceReadRequest) throws -> BoneToolTextResourcePage {
        try Task.checkCancellation()
        guard let resource = resources.first(where: { $0.descriptor.reference.id == request.reference.id }) else {
            throw BoneToolTextResourceError.unavailable
        }
        return try resource.snapshot.page(for: request)
    }
    /// Literal case-insensitive search, in Host-provided resource order; not semantic ranking.
    public func search(_ request: BoneTextResourceSearchRequest) throws -> BoneTextResourceSearchResult {
        _ = try request.validated(); try Task.checkCancellation()
        var hits: [BoneTextResourceSearchHit] = []
        var snippetBytes = 0
        for resource in resources {
            try Task.checkCancellation()
            let text = resource.text
            var cursor = text.startIndex
            while cursor < text.endIndex,
                  let range = text.range(of: request.query, options: [.caseInsensitive],
                      range: cursor..<text.endIndex, locale: Locale(identifier: "en_US_POSIX")) {
                try Task.checkCancellation()
                // An empty folding match must not loop forever.
                guard range.upperBound > range.lowerBound else { throw BoneResourceQueryError.invalidRequest }
                if hits.count == request.limit { return .init(hits: hits, isTruncated: true) }
                let offset = text[..<range.lowerBound].utf8.count
                let bytes = Data(text.utf8)
                var start = max(0, offset - 96)
                while start < offset && bytes[start] & 0xC0 == 0x80 { start += 1 }
                var end = min(bytes.count, start + 2_048)
                while end > offset && end < bytes.count && bytes[end] & 0xC0 == 0x80 { end -= 1 }
                let snippet = String(decoding: bytes[start..<end], as: UTF8.self)
                if snippetBytes + snippet.utf8.count > 32_768 { return .init(hits: hits, isTruncated: true) }
                hits.append(try .init(resource: resource.descriptor, matchOffset: offset,
                                      snippetOffset: start, snippet: snippet))
                snippetBytes += snippet.utf8.count
                cursor = range.upperBound
            }
        }
        return .init(hits: hits, isTruncated: false)
    }
    /// Explicitly checks Host authorization before EACH operation. Capturing a collection never grants access.
    /// If any contained resource is revoked, the Host must reject access or supply a fresh scoped collection.
    public func tools<Context: BoneAgentToolContext>(
        authorize: @escaping @Sendable (Context) async throws -> Void
    ) -> [BoneAnyAgentTool] {
        [
            BoneAnyAgentTool(BoneTextResourceListTool<Context> { request, context in
                try await authorize(context); try Task.checkCancellation()
                return try list(request)
            }),
            BoneAnyAgentTool(BoneTextResourceSearchTool<Context> { request, context in
                try await authorize(context); try Task.checkCancellation()
                return try search(request)
            }),
            BoneAnyAgentTool(BoneToolTextResourceReadTool<Context>(reader: .init { request, context in
                try await authorize(context); try Task.checkCancellation()
                return try read(request)
            }))
        ]
    }
}
