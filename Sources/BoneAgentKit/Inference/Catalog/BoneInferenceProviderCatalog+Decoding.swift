import Foundation

public extension BoneInferenceProviderCatalog {
    /// 解码、展开继承并校验 Provider Catalog。
    static func decode(data: Data) throws -> Self {
        let raw = try JSONDecoder().decode(RawCatalog.self, from: data)
        guard raw.schemaVersion == 1 else {
            throw Error.unsupportedSchema(raw.schemaVersion)
        }

        var sourceByIdent: [String: RawProvider] = [:]
        for provider in raw.providers {
            guard sourceByIdent[provider.ident] == nil else {
                throw Error.duplicateProvider(provider.ident)
            }
            sourceByIdent[provider.ident] = provider
        }

        var resolved: [String: RawProvider] = [:]
        var visiting: [String] = []

        func resolve(_ ident: String) throws -> RawProvider {
            if let existing = resolved[ident] {
                return existing
            }
            if let cycleStart = visiting.firstIndex(of: ident) {
                throw Error.inheritanceCycle(Array(visiting[cycleStart...]) + [ident])
            }
            guard let provider = sourceByIdent[ident] else {
                throw Error.missingParent(provider: visiting.last ?? ident, parent: ident)
            }

            visiting.append(ident)
            defer { visiting.removeLast() }

            let expanded: RawProvider
            if let parentIdent = provider.inherits {
                guard sourceByIdent[parentIdent] != nil else {
                    throw Error.missingParent(provider: ident, parent: parentIdent)
                }
                expanded = provider.merging(parent: try resolve(parentIdent))
            } else {
                expanded = provider
            }
            resolved[ident] = expanded
            return expanded
        }

        let providers = try raw.providers
            .map { try makeEntry(from: resolve($0.ident)) }
            .sorted {
                if $0.sortOrder == $1.sortOrder {
                    return $0.ident < $1.ident
                }
                return $0.sortOrder < $1.sortOrder
            }

        return Self(
            schemaVersion: raw.schemaVersion,
            catalogVersion: raw.catalogVersion,
            verifiedAt: raw.verifiedAt,
            providers: providers
        )
    }

    private static func makeEntry(from raw: RawProvider) throws -> Entry {
        let ident = raw.ident
        let title = try required(raw.title, provider: ident, field: "title")
        let iconID = try required(raw.icon, provider: ident, field: "icon")
        let protocolValue = try required(raw.adapter, provider: ident, field: "adapter")
        guard let providerProtocol = ProviderProtocol(rawValue: protocolValue) else {
            throw Error.unknownProviderProtocol(provider: ident, value: protocolValue)
        }
        let authenticationValue = try required(
            raw.authenticationMode,
            provider: ident,
            field: "authenticationMode"
        )
        guard let authenticationMode = BoneInferenceAuthenticationMode(
            rawValue: authenticationValue
        ) else {
            throw Error.unknownAuthenticationMode(provider: ident, value: authenticationValue)
        }
        let catalogModeValue = try required(
            raw.modelCatalogMode,
            provider: ident,
            field: "modelCatalogMode"
        )
        guard let catalogMode = CatalogMode(rawValue: catalogModeValue) else {
            throw Error.unknownCatalogMode(provider: ident, value: catalogModeValue)
        }
        let sortOrder = try required(raw.sortOrder, provider: ident, field: "sortOrder")

        let defaultBaseURL = try validatedURL(
            raw.defaultBaseURL,
            provider: ident,
            field: "defaultBaseURL"
        )
        let inviteURL = try validatedURL(raw.inviteURL, provider: ident, field: "inviteURL")
        let documentationURL = try validatedURL(
            raw.documentationURL,
            provider: ident,
            field: "documentationURL"
        )
        if catalogMode == .local, defaultBaseURL == nil {
            throw Error.missingField(provider: ident, field: "defaultBaseURL")
        }

        let discovery = try makeDiscovery(
            raw.modelDiscovery,
            provider: ident,
            catalogMode: catalogMode
        )
        let models = try makeModels(raw.models ?? [], provider: ident)

        return Entry(
            ident: ident,
            title: title,
            iconID: iconID,
            providerKind: providerKind(ident: ident, protocol: providerProtocol),
            providerProtocol: providerProtocol,
            authenticationMode: authenticationMode,
            defaultBaseURL: defaultBaseURL,
            inviteURL: inviteURL,
            documentationURL: documentationURL,
            catalogMode: catalogMode,
            sortOrder: sortOrder,
            apiPaths: raw.apiPaths ?? [:],
            discovery: discovery,
            models: models
        )
    }

    private static func makeDiscovery(
        _ raw: RawDiscovery?,
        provider: String,
        catalogMode: CatalogMode
    ) throws -> Discovery? {
        guard let raw else { return nil }
        guard catalogMode == .local else {
            throw Error.discoveryNotAllowed(provider: provider, mode: catalogMode.rawValue)
        }
        guard let endpoint = try validatedURL(
            raw.endpoint,
            provider: provider,
            field: "modelDiscovery.endpoint"
        ) else {
            throw Error.missingField(provider: provider, field: "modelDiscovery.endpoint")
        }
        guard let discoveryProtocol = Discovery.ProtocolKind(rawValue: raw.adapter) else {
            throw Error.unknownDiscoveryProtocol(provider: provider, value: raw.adapter)
        }
        guard let authentication = BoneInferenceAuthenticationMode(
            rawValue: raw.authenticationMode
        ) else {
            throw Error.unknownAuthenticationMode(
                provider: provider,
                value: raw.authenticationMode
            )
        }
        return Discovery(
            endpoint: endpoint,
            protocol: discoveryProtocol,
            authenticationMode: authentication
        )
    }

    private static func makeModels(
        _ rawModels: [RawModel],
        provider: String
    ) throws -> [Model] {
        var modelIDs = Set<String>()
        return try rawModels.map { raw in
            guard modelIDs.insert(raw.id).inserted else {
                throw Error.duplicateModel(provider: provider, modelID: raw.id)
            }
            guard !raw.capabilities.isEmpty else {
                throw Error.missingCapability(provider: provider, modelID: raw.id)
            }
            let capabilities = try Set(raw.capabilities.map { value in
                guard let capability = Capability(rawValue: value) else {
                    throw Error.unknownCapability(
                        provider: provider,
                        modelID: raw.id,
                        value: value
                    )
                }
                return capability
            })
            guard let protocolVariant = BoneInferenceProtocolVariant(
                rawValue: raw.protocolVariant
            ) else {
                throw Error.unknownProtocolVariant(
                    provider: provider,
                    modelID: raw.id,
                    value: raw.protocolVariant
                )
            }

            let options = BoneInferenceGenerationOptions(
                temperature: raw.parameters?.temperature,
                maximumOutputTokens: raw.parameters?.maximumOutputTokens
            )
            do {
                _ = try options.validated()
            } catch {
                let field = raw.parameters?.temperature.map { !(0...2).contains($0) } == true
                    ? "temperature"
                    : "max_tokens"
                throw Error.invalidModelParameter(
                    provider: provider,
                    modelID: raw.id,
                    field: field
                )
            }

            let tokenLimits = try makeTokenLimits(raw.tokenLimits, provider: provider, modelID: raw.id)

            let sizes = try (raw.supportedImageSizes ?? []).map { size in
                do {
                    return try BoneInferenceImageSize(
                        width: size.width,
                        height: size.height,
                        requestSizeValue: size.requestSizeValue,
                        requestRatioValue: size.requestRatioValue
                    )
                } catch {
                    throw Error.invalidImageSize(provider: provider, modelID: raw.id)
                }
            }
            let counts = try (raw.supportedImageCounts ?? []).map { count in
                do {
                    _ = try BoneInferenceImageCount(count)
                    return count
                } catch {
                    throw Error.invalidImageCount(
                        provider: provider,
                        modelID: raw.id,
                        value: count
                    )
                }
            }

            return Model(
                id: raw.id,
                displayName: raw.displayName,
                capabilities: capabilities,
                protocolVariant: protocolVariant,
                supportedImageSizes: sizes,
                supportedImageCounts: counts,
                generationOptions: options,
                tokenLimits: tokenLimits,
                deprecated: raw.deprecated
            )
        }
    }

    private static func makeTokenLimits(
        _ raw: RawModel.RawTokenLimits?,
        provider: String,
        modelID: String
    ) throws -> BoneModelContextLimits? {
        guard let raw else { return nil }
        guard raw.contextWindowTokens > 0 else {
            throw Error.invalidModelTokenLimit(
                provider: provider,
                modelID: modelID,
                field: "contextWindowTokens"
            )
        }
        if let maximumInputTokens = raw.maximumInputTokens,
           maximumInputTokens <= 0 || maximumInputTokens > raw.contextWindowTokens {
            throw Error.invalidModelTokenLimit(
                provider: provider,
                modelID: modelID,
                field: "maximumInputTokens"
            )
        }
        if let maximumOutputTokens = raw.maximumOutputTokens,
           maximumOutputTokens <= 0 {
            throw Error.invalidModelTokenLimit(
                provider: provider,
                modelID: modelID,
                field: "maximumOutputTokens"
            )
        }
        guard let source = BoneModelContextLimits.Source(rawValue: raw.source) else {
            throw Error.invalidModelTokenLimit(
                provider: provider,
                modelID: modelID,
                field: "source"
            )
        }
        guard !raw.verifiedAt.isEmpty else {
            throw Error.invalidModelTokenLimit(
                provider: provider,
                modelID: modelID,
                field: "verifiedAt"
            )
        }
        guard let documentationURL = try validatedURL(
            raw.documentationURL,
            provider: provider,
            field: "models.\(modelID).tokenLimits.documentationURL"
        ) else {
            throw Error.invalidModelTokenLimit(
                provider: provider,
                modelID: modelID,
                field: "documentationURL"
            )
        }
        do {
            return try BoneModelContextLimits(
                contextWindowTokens: raw.contextWindowTokens,
                maximumInputTokens: raw.maximumInputTokens,
                maximumOutputTokens: raw.maximumOutputTokens,
                source: source,
                verifiedAt: raw.verifiedAt,
                documentationURL: documentationURL
            )
        } catch {
            throw Error.invalidModelTokenLimit(
                provider: provider,
                modelID: modelID,
                field: "tokenLimits"
            )
        }
    }

    private static func providerKind(
        ident: String,
        protocol providerProtocol: ProviderProtocol
    ) -> BoneInferenceProviderKind {
        switch ident.caseInsensitiveCompare("MiniMax") {
        case .orderedSame: return .miniMax
        default: break
        }
        switch ident.caseInsensitiveCompare("Agnes") {
        case .orderedSame: return .agnes
        default: break
        }
        switch ident.caseInsensitiveCompare("Zhipu") {
        case .orderedSame: return .zhipu
        default: break
        }
        switch ident.caseInsensitiveCompare("SiliconFlow") {
        case .orderedSame: return .siliconFlow
        default: break
        }
        switch providerProtocol {
        case .anthropic: return .anthropic
        case .google: return .google
        case .newAPI: return .newAPI
        case .customOpenAI: return .custom
        case .openAI: return .openAI
        }
    }

    private static func validatedURL(
        _ value: String?,
        provider: String,
        field: String
    ) throws -> URL? {
        guard let value, !value.isEmpty else { return nil }
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            throw Error.invalidURL(provider: provider, field: field)
        }
        return url
    }

    private static func required<Value>(
        _ value: Value?,
        provider: String,
        field: String
    ) throws -> Value {
        guard let value else {
            throw Error.missingField(provider: provider, field: field)
        }
        return value
    }
}

private struct RawCatalog: Decodable {
    let schemaVersion: Int
    let catalogVersion: Int
    let verifiedAt: String
    let providers: [RawProvider]
}

private struct RawProvider: Decodable {
    let ident: String
    let inherits: String?
    let title: String?
    let icon: String?
    let adapter: String?
    let authenticationMode: String?
    let defaultBaseURL: String?
    let inviteURL: String?
    let documentationURL: String?
    let modelCatalogMode: String?
    let sortOrder: Int?
    let apiPaths: [String: String]?
    let modelDiscovery: RawDiscovery?
    let models: [RawModel]?

    func merging(parent: Self) -> Self {
        Self(
            ident: ident,
            inherits: nil,
            title: title ?? parent.title,
            icon: icon ?? parent.icon,
            adapter: adapter ?? parent.adapter,
            authenticationMode: authenticationMode ?? parent.authenticationMode,
            defaultBaseURL: defaultBaseURL ?? parent.defaultBaseURL,
            inviteURL: inviteURL ?? parent.inviteURL,
            documentationURL: documentationURL ?? parent.documentationURL,
            modelCatalogMode: modelCatalogMode ?? parent.modelCatalogMode,
            sortOrder: sortOrder ?? parent.sortOrder,
            apiPaths: apiPaths ?? parent.apiPaths,
            modelDiscovery: modelDiscovery,
            models: models ?? parent.models
        )
    }
}

private struct RawDiscovery: Decodable {
    let endpoint: String
    let adapter: String
    let authenticationMode: String
}

private struct RawModel: Decodable {
    struct RawSize: Decodable {
        let width: Int
        let height: Int
        let requestSizeValue: String?
        let requestRatioValue: String?
    }

    struct RawTokenLimits: Decodable {
        let contextWindowTokens: Int
        let maximumInputTokens: Int?
        let maximumOutputTokens: Int?
        let source: String
        let verifiedAt: String
        let documentationURL: String
    }

    struct RawParameters: Decodable {
        private enum CodingKeys: String, CodingKey {
            case temperature
            case maximumOutputTokens = "max_tokens"
        }

        let temperature: Double?
        let maximumOutputTokens: Int?
    }

    let id: String
    let displayName: String
    let capabilities: [String]
    let protocolVariant: String
    let supportedImageSizes: [RawSize]?
    let supportedImageCounts: [Int]?
    let parameters: RawParameters?
    let tokenLimits: RawTokenLimits?
    let deprecated: Bool
}
