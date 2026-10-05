import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Redirects may keep the original origin only. Authentication and request bodies
/// must never be forwarded to an origin not selected by the Host.
enum BoneInferenceRedirectPolicy {
    static func allows(from original: URL?, to destination: URL?) -> Bool {
        guard let original, let destination,
              let scheme = original.scheme?.lowercased(), ["https", "http"].contains(scheme),
              scheme == destination.scheme?.lowercased(),
              let host = original.host?.lowercased(), host == destination.host?.lowercased(),
              destination.user == nil, destination.password == nil else { return false }
        let defaultPort = scheme == "https" ? 443 : 80
        return (original.port ?? defaultPort) == (destination.port ?? defaultPort)
    }
}
