import BoneAgentKit
import Foundation

public enum BoneLocalModelFormat: String, Codable, Sendable {
    case gguf
}

public struct BoneLocalModelDownloadSource: Codable, Equatable, Sendable {
    public let id: String
    public let url: URL
    public let allowedHosts: [String]
    public let priority: Int
}

public struct BoneLocalModelArtifact: Codable, Equatable, Sendable {
    public let fileName: String
    public let expectedByteCount: Int64
    public let sha256: String
    public let sources: [BoneLocalModelDownloadSource]
}

public struct BoneLocalModelLicense: Codable, Equatable, Sendable {
    public let name: String
    public let url: URL
    public let modelCardURL: URL
}

public struct BoneLocalModelDescriptor: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let family: String
    public let format: BoneLocalModelFormat
    public let parameterCount: Int64
    public let quantization: String
    public let minimumMemoryBytes: UInt64
    public let recommendedContextTokens: Int
    public let minimumRuntimeVersion: Int
    public let contextLimits: BoneModelContextLimits
    public let artifact: BoneLocalModelArtifact
    public let license: BoneLocalModelLicense
}
