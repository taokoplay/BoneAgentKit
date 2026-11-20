import Foundation
import BoneAgentTools

/// Search results belong to the manual browser/API flow, not the static-page reader.
enum DemoWebFetchNavigationPolicy {
    static func validate(url: String, policy: BoneWebHostPolicy) throws -> URL {
        let result = try policy.validate(url: url)
        let path = result.path.lowercased()
        let keys = Set(URLComponents(url: result, resolvingAgainstBaseURL: false)?.queryItems?.map { $0.name.lowercased() } ?? [])
        let isHome = path.isEmpty || path == "/"
        let searchPage: Bool
        switch result.host?.lowercased() {
        case "baidu.com", "www.baidu.com":
            searchPage = ["/s", "/s/", "/baidu"].contains(path) || (isHome && !keys.isDisjoint(with: ["wd", "word"]))
        case "bing.com", "www.bing.com":
            searchPage = ["/search", "/search/"].contains(path) || (isHome && keys.contains("q"))
        default: searchPage = false
        }
        guard !searchPage else { throw DemoSearchError.manualSearchRequired }
        return result
    }
}
