import BoneAgentKit
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct DryRunProvider: Encodable {
    let provider: String
    let model: String
    let status: String
}

private enum LiveProvider: String {
    case openai, anthropic, gemini

    var kind: BoneInferenceProviderKind {
        switch self {
        case .openai: return .openAI
        case .anthropic: return .anthropic
        case .gemini: return .google
        }
    }

    var credentialVariable: String {
        switch self {
        case .openai: return "OPENAI_API_KEY"
        case .anthropic: return "ANTHROPIC_API_KEY"
        case .gemini: return "GEMINI_API_KEY"
        }
    }
}

private struct LiveArguments {
    let provider: LiveProvider
    let modelID: String
    let iterations: Int
    let invocation: BoneInferenceInvocationMode

    init(arguments: [String]) throws {
        let flagOptions: Set<String> = ["--live", "--confirm-network-and-costs"]
        let valueOptions: Set<String> = ["--provider", "--model", "--iterations", "--invocation"]
        var flags = Set<String>()
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            if flagOptions.contains(option) {
                guard flags.insert(option).inserted else {
                    throw BoneInferenceTransportError.invalidConfiguration
                }
                index += 1
            } else if valueOptions.contains(option) {
                guard values[option] == nil,
                      arguments.indices.contains(index + 1),
                      !arguments[index + 1].hasPrefix("--") else {
                    throw BoneInferenceTransportError.invalidConfiguration
                }
                values[option] = arguments[index + 1]
                index += 2
            } else {
                throw BoneInferenceTransportError.invalidConfiguration
            }
        }
        guard flags == flagOptions,
              values.count == valueOptions.count,
              let providerValue = values["--provider"],
              let provider = LiveProvider(rawValue: providerValue),
              let modelID = values["--model"],
              Self.isValidModelID(modelID),
              let iterationsText = values["--iterations"],
              let iterations = Int(iterationsText),
              (1...1_000).contains(iterations),
              let invocationText = values["--invocation"] else {
            throw BoneInferenceTransportError.invalidConfiguration
        }
        switch invocationText {
        case "non-streaming": invocation = .nonStreaming
        case "streaming": invocation = .streaming
        default: throw BoneInferenceTransportError.invalidConfiguration
        }
        self.provider = provider
        self.modelID = modelID
        self.iterations = iterations
    }

    private static func isValidModelID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128
            && value.range(of: "^[A-Za-z0-9][A-Za-z0-9._/-]*$", options: .regularExpression) != nil
            && !value.contains("://") && !value.contains("//")
    }
}

@main
enum BoneAgentLiveProviderSmokeMain {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--dry-run"] {
            try dryRun()
            return
        }

        let live: LiveArguments
        do {
            live = try LiveArguments(arguments: arguments)
        } catch {
            writeUsage()
            Foundation.exit(2)
        }
        guard let rawAPIKey = getenv(live.provider.credentialVariable),
              let apiKey = String(validatingCString: rawAPIKey),
              !apiKey.isEmpty else {
            FileHandle.standardError.write(Data("缺少所选 Provider 的固定凭据变量。\n".utf8))
            Foundation.exit(2)
        }

        let transport = BoneInferenceURLSessionTransport()
        let (engine, identity) = try makeVerifiedEngine(
            provider: live.provider,
            modelID: live.modelID,
            apiKey: apiKey,
            invocation: live.invocation,
            transport: transport
        )
        let report = try await BoneLiveConstraintSmoke.run(
            provider: live.provider.kind,
            modelID: live.modelID,
            invocation: live.invocation,
            engine: engine,
            identity: identity,
            iterations: live.iterations
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
        guard report.succeededCount == report.attemptedCount else { Foundation.exit(1) }
    }

    private static func dryRun() throws {
        let transport = RejectingDryRunTransport()
        let fixtures: [(DryRunProvider, any BoneInferenceEngine)] = [
            (
                .init(provider: "openai", model: "smoke-openai", status: "dry-run"),
                BoneOpenAIInferenceEngine(
                    configuration: configuration(kind: .openAI, apiKey: "dry-run", baseURL: "https://api.openai.com"),
                    transport: transport
                )
            ),
            (
                .init(provider: "anthropic", model: "smoke-anthropic", status: "dry-run"),
                BoneAnthropicInferenceEngine(
                    configuration: configuration(
                        kind: .anthropic,
                        apiKey: "dry-run",
                        baseURL: "https://api.anthropic.com",
                        authentication: .anthropicDual
                    ),
                    transport: transport
                )
            ),
            (
                .init(provider: "gemini", model: "smoke-gemini", status: "dry-run"),
                BoneGeminiInferenceEngine(
                    configuration: configuration(
                        kind: .google,
                        apiKey: "dry-run",
                        baseURL: "https://generativelanguage.googleapis.com",
                        authentication: .googleAPIKey
                    ),
                    transport: transport
                )
            ),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for (report, engine) in fixtures {
            let request = BoneInferenceRequest(
                modelID: report.model,
                messages: [.init(role: .user, content: "dry-run")]
            )
            _ = try engine.resolvedCapabilities(for: request, invocation: .nonStreaming)
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        }
    }

    private static func makeVerifiedEngine(
        provider: LiveProvider,
        modelID: String,
        apiKey: String,
        invocation: BoneInferenceInvocationMode,
        transport: any BoneInferenceHTTPTransport
    ) throws -> (any BoneInferenceEngine, BoneProviderCapabilityVerificationIdentity) {
        switch provider {
        case .openai:
            let config = configuration(kind: .openAI, apiKey: apiKey, baseURL: "https://api.openai.com")
            let base = BoneOpenAIInferenceEngine(configuration: config, transport: transport)
            let identity = try base.constraintVerificationIdentity(modelID: modelID, invocation: invocation)
            let profile = try verifiedProfile(identity: identity)
            return (BoneOpenAIInferenceEngine(configuration: config, transport: transport, modelCapabilityProfiles: [modelID: profile]), identity)
        case .anthropic:
            let config = configuration(kind: .anthropic, apiKey: apiKey, baseURL: "https://api.anthropic.com", authentication: .anthropicDual)
            let base = BoneAnthropicInferenceEngine(configuration: config, transport: transport)
            let identity = try base.constraintVerificationIdentity(modelID: modelID, invocation: invocation)
            let profile = try verifiedProfile(identity: identity)
            return (BoneAnthropicInferenceEngine(configuration: config, transport: transport, modelCapabilityProfiles: [modelID: profile]), identity)
        case .gemini:
            let config = configuration(kind: .google, apiKey: apiKey, baseURL: "https://generativelanguage.googleapis.com", authentication: .googleAPIKey)
            let base = BoneGeminiInferenceEngine(configuration: config, transport: transport)
            let identity = try base.constraintVerificationIdentity(modelID: modelID, invocation: invocation)
            let profile = try verifiedProfile(identity: identity)
            return (BoneGeminiInferenceEngine(configuration: config, transport: transport, modelCapabilityProfiles: [modelID: profile]), identity)
        }
    }

    private static func verifiedProfile(
        identity: BoneProviderCapabilityVerificationIdentity
    ) throws -> BoneModelCapabilityProfile {
        try .init(
            capabilities: [.text, .constrainedOutput, .streaming],
            source: .providerSmoke,
            verifiedAt: utcDateString(),
            providerVerificationIdentities: [identity]
        )
    }

    private static func configuration(
        kind: BoneInferenceProviderKind,
        apiKey: String,
        baseURL: String,
        authentication: BoneInferenceAuthenticationMode = .bearer
    ) -> BoneInferenceProviderConfiguration {
        .init(
            kind: kind,
            apiKey: apiKey,
            baseURL: URL(string: baseURL)!,
            authenticationMode: authentication,
            endpointSecurityPolicy: .builtIn
        )
    }

    private static func utcDateString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func writeUsage() {
        let usage = """
        Usage:
          BoneAgentLiveProviderSmoke --dry-run
          BoneAgentLiveProviderSmoke --live --confirm-network-and-costs --provider <openai|anthropic|gemini> --model <exact-model-id> --iterations <1...1000> --invocation <non-streaming|streaming>
        """
        FileHandle.standardError.write(Data((usage + "\n").utf8))
    }
}

private actor RejectingDryRunTransport: BoneInferenceHTTPTransport {
    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        throw BoneInferenceTransportError.invalidConfiguration
    }

    func sendEventStream(
        _ request: URLRequest,
        options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceEventStreamResponse {
        throw BoneInferenceTransportError.invalidConfiguration
    }

    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        throw BoneInferenceTransportError.invalidConfiguration
    }
}
