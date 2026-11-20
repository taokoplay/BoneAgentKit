#if DEBUG
import Foundation
import BoneAgentTools

/// Explicit Agent-authorized public renderer check when XCTest cannot attach.
/// Uses isolated app settings, visits only the fixed public Baidu query, and never invokes a model.
enum BaiduPublicPageDiagnostic {
    @MainActor static func run(reader: LiveBrowserSearchModel) async {
        do {
            let query = "今天深圳天气"
            let output = try await reader.handler(BoneWebSearchInput(query: query, count: 1))
            guard output.provider == "baidu-web", let result = output.results.first,
                  DemoBrowserSearchSnapshot.matchesQuery(pageURL: result.url, query: query),
                  reader.lastSnapshot != nil, reader.lastReadWasUnpresented else { throw DemoBrowserSearchError.invalidSnapshot }
            let encoded = try JSONEncoder().encode(output)
            let decoded = try JSONDecoder().decode(BoneWebSearchOutput.self, from: encoded)
            guard decoded == output else { throw DemoBrowserSearchError.invalidSnapshot }
            print("BAIDU_PUBLIC_DIAGNOSTIC_SUCCESS results=\(output.results.count) snippetBytes=\(result.snippet.utf8.count) modelCalls=0 unpresented=1 structured=1")
        } catch {
            let code = error is CancellationError ? "cancelled" : (error as? DemoBrowserSearchError)?.rawValue ?? "unknown"
            print("BAIDU_PUBLIC_DIAGNOSTIC_FAILURE code=\(code) modelCalls=0")
        }
    }
}
#endif
