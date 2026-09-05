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

    public init(id: String, url: URL, allowedHosts: [String], priority: Int) {
        self.id = id
        self.url = url
        self.allowedHosts = allowedHosts
        self.priority = priority
    }
}

public struct BoneLocalModelArtifact: Codable, Equatable, Sendable {
    public let fileName: String
    public let expectedByteCount: Int64
    public let sha256: String
    public let sources: [BoneLocalModelDownloadSource]

    public init(
        fileName: String,
        expectedByteCount: Int64,
        sha256: String,
        sources: [BoneLocalModelDownloadSource]
    ) {
        self.fileName = fileName
        self.expectedByteCount = expectedByteCount
        self.sha256 = sha256
        self.sources = sources
    }
}

public struct BoneLocalModelLicense: Codable, Equatable, Sendable {
    public let name: String
    public let url: URL
    public let modelCardURL: URL

    public init(name: String, url: URL, modelCardURL: URL) {
        self.name = name
        self.url = url
        self.modelCardURL = modelCardURL
    }
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
    /// Catalog 中有证据的模型级能力；nil 表示尚未验证，而不是不支持。
    public let inferenceCapabilityProfile: BoneModelCapabilityProfile?
    public let artifact: BoneLocalModelArtifact
    public let license: BoneLocalModelLicense

    public init(
        id: String,
        displayName: String,
        family: String,
        format: BoneLocalModelFormat,
        parameterCount: Int64,
        quantization: String,
        minimumMemoryBytes: UInt64,
        recommendedContextTokens: Int,
        minimumRuntimeVersion: Int,
        contextLimits: BoneModelContextLimits,
        inferenceCapabilityProfile: BoneModelCapabilityProfile? = nil,
        artifact: BoneLocalModelArtifact,
        license: BoneLocalModelLicense
    ) {
        self.id = id
        self.displayName = displayName
        self.family = family
        self.format = format
        self.parameterCount = parameterCount
        self.quantization = quantization
        self.minimumMemoryBytes = minimumMemoryBytes
        self.recommendedContextTokens = recommendedContextTokens
        self.minimumRuntimeVersion = minimumRuntimeVersion
        self.contextLimits = contextLimits
        self.inferenceCapabilityProfile = inferenceCapabilityProfile
        self.artifact = artifact
        self.license = license
    }
}
