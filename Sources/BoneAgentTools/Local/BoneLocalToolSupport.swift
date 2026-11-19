import Foundation
import BoneAgentKit

/// Implementation details shared by the local tools; no mutable global state.
enum BoneLocalToolSupport {
    static let impact = BoneToolImpact(
        dataAccess: .none,
        externalTransmission: .none,
        stateChange: .none,
        economic: .none,
        userVisible: .none,
        permissionChange: .none
    )

    static func containsOnlyKeys(_ decoder: Decoder, allowed: Set<String>) throws -> Bool {
        let container = try decoder.container(keyedBy: AnyKey.self)
        return container.allKeys.allSatisfy { allowed.contains($0.stringValue) }
    }

    /// An omitted optional field is accepted; explicit JSON null is not in these schemas.
    static func decodeOptional<Value: Decodable, Key: CodingKey>(
        _ type: Value.Type,
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> Value? {
        guard container.contains(key) else { return nil }
        return try container.decode(type, forKey: key)
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}
