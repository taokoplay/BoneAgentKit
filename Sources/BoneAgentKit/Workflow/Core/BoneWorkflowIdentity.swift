import Foundation

private func validatedWorkflowIdentity(_ value: String) throws -> String {
    guard (1...128).contains(value.count),
          value.unicodeScalars.allSatisfy({
              CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._")).contains($0)
          }) else {
        throw BoneWorkflowFailure.invalidIdentity
    }
    return value
}

public struct BoneRunID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) throws { self.rawValue = try validatedWorkflowIdentity(rawValue) }
    public init?(rawValue: String) { guard let value = try? Self(rawValue) else { return nil }; self = value }
}
public struct BoneStepID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) throws { self.rawValue = try validatedWorkflowIdentity(rawValue) }
    public init?(rawValue: String) { guard let value = try? Self(rawValue) else { return nil }; self = value }
}
public struct BoneAttemptID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) throws { self.rawValue = try validatedWorkflowIdentity(rawValue) }
    public init?(rawValue: String) { guard let value = try? Self(rawValue) else { return nil }; self = value }
}
public struct BoneToolCallID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) throws { self.rawValue = try validatedWorkflowIdentity(rawValue) }
    public init?(rawValue: String) { guard let value = try? Self(rawValue) else { return nil }; self = value }
}
public struct BoneAuthorizationTicketID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) throws { self.rawValue = try validatedWorkflowIdentity(rawValue) }
    public init?(rawValue: String) { guard let value = try? Self(rawValue) else { return nil }; self = value }
}
public struct BoneEffectID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) throws { self.rawValue = try validatedWorkflowIdentity(rawValue) }
    public init?(rawValue: String) { guard let value = try? Self(rawValue) else { return nil }; self = value }
}
