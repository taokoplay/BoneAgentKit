import XCTest
@testable import BoneAgentKit

final class BoneAgentBuilderTests: XCTestCase {
    func testBuilderRunsWithTypedToolAndDefaultConfiguration() async throws {
        let engine = BuilderEngine()
        let agent = try BoneAgentBuilder(inferenceEngine: engine)
            .withTool(BuilderEchoTool())
            .build()

        let result = try await agent.run(
            modelID: "model",
            messages: [.init(role: .user, content: "hello")]
        )

        XCTAssertEqual(result.output, .text("done"))
        let request = await engine.lastRequest
        XCTAssertEqual(request?.availableTools.map(\.id), [BuilderEchoTool.definition.id])
    }

    func testProviderFactorySelectsProtocolSpecificEngine() throws {
        let transport = BoneInferenceURLSessionTransport(
            loader: { _ in
                (Data(), .init(statusCode: 200))
            }
        )

        let google = BoneAgentProviderFactory.makeEngine(
            configuration: .init(
                kind: .google,
                apiKey: "fixture",
                baseURL: URL(string: "https://example.com")!,
                authenticationMode: .googleAPIKey
            ),
            transport: transport
        )
        XCTAssertTrue(google is BoneGeminiInferenceEngine)

        let anthropic = BoneAgentProviderFactory.makeEngine(
            configuration: .init(
                kind: .anthropic,
                apiKey: "fixture",
                baseURL: URL(string: "https://example.com")!,
                authenticationMode: .anthropicDual
            ),
            transport: transport
        )
        XCTAssertTrue(anthropic is BoneAnthropicInferenceEngine)

        let compatible = BoneAgentProviderFactory.makeEngine(
            configuration: .init(
                kind: .custom,
                apiKey: "fixture",
                baseURL: URL(string: "https://example.com")!
            ),
            transport: transport
        )
        XCTAssertTrue(compatible is BoneOpenAIInferenceEngine)
    }

    func testBuilderRejectsDuplicateToolIDsAtBuild() throws {
        let builder = try BoneAgentBuilder(inferenceEngine: BuilderEngine())
            .withTool(BuilderEchoTool())
            .withTool(BuilderEchoTool())

        XCTAssertThrowsError(try builder.build()) { error in
            XCTAssertEqual(
                error as? BoneAgentToolRegistryError,
                .duplicateToolID(BuilderEchoTool.definition.id)
            )
        }
    }
}

private struct BuilderEchoTool: BoneAgentTool {
    struct Input: Codable, Sendable { let value: String }
    struct Output: Codable, Sendable { let value: String }

    static let definition = BoneAgentToolDefinition(
        id: "builder.echo",
        version: "1",
        title: "Echo",
        summary: "Echoes a value"
    )

    func execute(input: Input, context: BoneAgentEmptyContext) async throws -> Output {
        Output(value: input.value)
    }
}

private actor BuilderEngine: BoneInferenceEngine {
    let nonImageCapabilities: Set<BoneInferenceCapability> = [.text, .toolCalling]
    let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    private(set) var lastRequest: BoneInferenceRequest?

    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        lastRequest = request
        return .finish(.init(text: "done"))
    }
}
