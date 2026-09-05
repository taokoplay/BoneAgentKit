import Foundation

public enum BoneLocalModelCatalogError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case duplicateModelID(String)
    case invalidModel(String)
    case invalidArtifact(modelID: String)
    case invalidDownloadSource(modelID: String, sourceID: String)
    case runtimeVersionUnsupported(modelID: String, required: Int, current: Int)
}

public struct BoneLocalModelCatalog: Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let catalogVersion: Int
    public let runtimeVersion: Int
    public let models: [BoneLocalModelDescriptor]

    private struct Manifest: Decodable {
        let schemaVersion: Int
        let catalogVersion: Int
        let runtimeVersion: Int
        let models: [BoneLocalModelDescriptor]
    }

    public init(data: Data) throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.schemaVersion == Self.supportedSchemaVersion else {
            throw BoneLocalModelCatalogError.unsupportedSchema(manifest.schemaVersion)
        }
        guard manifest.catalogVersion > 0, manifest.runtimeVersion > 0 else {
            throw BoneLocalModelCatalogError.invalidModel("manifest")
        }

        var ids = Set<String>()
        for model in manifest.models {
            try Self.validate(model, runtimeVersion: manifest.runtimeVersion)
            guard ids.insert(model.id).inserted else {
                throw BoneLocalModelCatalogError.duplicateModelID(model.id)
            }
        }
        self.schemaVersion = manifest.schemaVersion
        self.catalogVersion = manifest.catalogVersion
        self.runtimeVersion = manifest.runtimeVersion
        self.models = manifest.models
    }

    public func model(id: String) -> BoneLocalModelDescriptor? {
        models.first { $0.id == id }
    }

    private static func validate(_ model: BoneLocalModelDescriptor, runtimeVersion: Int) throws {
        guard model.minimumRuntimeVersion <= runtimeVersion else {
            throw BoneLocalModelCatalogError.runtimeVersionUnsupported(
                modelID: model.id,
                required: model.minimumRuntimeVersion,
                current: runtimeVersion
            )
        }
        guard BoneLocalModelPathPolicy.isIdentifier(model.id), !model.displayName.isEmpty, !model.family.isEmpty,
              model.parameterCount > 0, model.minimumMemoryBytes > 0,
              model.recommendedContextTokens >= 512,
              model.recommendedContextTokens <= model.contextLimits.contextWindowTokens else {
            throw BoneLocalModelCatalogError.invalidModel(model.id)
        }
        guard BoneLocalModelPathPolicy.isFileName(model.artifact.fileName),
              model.artifact.expectedByteCount > 0,
              model.artifact.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              !model.artifact.sources.isEmpty else {
            throw BoneLocalModelCatalogError.invalidArtifact(modelID: model.id)
        }
        var sourceIDs = Set<String>()
        for source in model.artifact.sources {
            guard sourceIDs.insert(source.id).inserted,
                  isIdentifier(source.id),
                  source.url.scheme?.lowercased() == "https",
                  let host = source.url.host?.lowercased(),
                  !source.allowedHosts.isEmpty,
                  source.allowedHosts.allSatisfy({ isValidAllowedHost($0) }),
                  source.allowedHosts.contains(where: { hostMatches(host, allowed: $0) }) else {
                throw BoneLocalModelCatalogError.invalidDownloadSource(
                    modelID: model.id,
                    sourceID: source.id
                )
            }
        }
        guard model.license.url.scheme?.lowercased() == "https",
              model.license.modelCardURL.scheme?.lowercased() == "https" else {
            throw BoneLocalModelCatalogError.invalidModel(model.id)
        }
    }

    private static func isIdentifier(_ value: String) -> Bool {
        value.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil
    }

    private static func isValidAllowedHost(_ value: String) -> Bool {
        let host = value.lowercased()
        let candidate = host.hasPrefix("*.") ? String(host.dropFirst(2)) : host
        return !candidate.isEmpty && !candidate.contains("/") && !candidate.contains(":")
    }

    private static func hostMatches(_ host: String, allowed: String) -> Bool {
        let value = allowed.lowercased()
        if value == host { return true }
        guard value.hasPrefix("*.") else { return false }
        let suffix = String(value.dropFirst(1))
        return host.hasSuffix(suffix) && host.count > suffix.count
    }
}
