import BoneAgentKit
import Foundation

private struct DryRunProvider: Encodable {
    let provider: String
    let model: String
    let status: String
}

@main
enum BoneAgentLiveProviderSmokeMain {
    static func main() throws {
        guard CommandLine.arguments == [CommandLine.arguments[0], "--dry-run"] else {
            FileHandle.standardError.write(Data(
                "当前 runner 只实现 --dry-run；真实联网 Smoke 必须在签发环境另行授权。\n".utf8
            ))
            Foundation.exit(2)
        }

        let transport = RejectingDryRunTransport()
        let fixtures: [(DryRunProvider, any BoneInferenceEngine)] = [
            (
                .init(provider: "openai", model: "smoke-openai", status: "dry-run"),
                BoneOpenAIInferenceEngine(
                    configuration: configuration(kind: .openAI, baseURL: "https://api.openai.com"),
                    transport: transport
                )
            ),
            (
                .init(provider: "anthropic", model: "smoke-anthropic", status: "dry-run"),
                BoneAnthropicInferenceEngine(
                    configuration: configuration(
                        kind: .anthropic,
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

    private static func configuration(
        kind: BoneInferenceProviderKind,
        baseURL: String,
        authentication: BoneInferenceAuthenticationMode = .bearer
    ) -> BoneInferenceProviderConfiguration {
        .init(
            kind: kind,
            apiKey: "dry-run-placeholder-not-a-credential",
            baseURL: URL(string: baseURL)!,
            authenticationMode: authentication,
            endpointSecurityPolicy: .builtIn
        )
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
