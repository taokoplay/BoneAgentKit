import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BoneAgentKit

/// 非流式 Tool 路径的截断归类回归。
///
/// 命中输出预算上限（OpenAI `finish_reason=length`、Anthropic `stop_reason=max_tokens`）时必须报
/// `outputTruncated`：既不能被 `invalidResponse` 提前吃掉，也不能被 `hasCalls` 分支吞成成功的
/// Assistant Turn，否则调用方拿不到"提高 max_tokens 后重试"这个可执行信号。
final class NonStreamingToolTruncationTests: XCTestCase {
    private static let tool = BoneAgentToolDefinition(
        id: "probe",
        version: "1.0.0",
        title: "Probe",
        summary: "Probe",
        wireName: "probe",
        schemaVersion: 1,
        inputSchema: .object(properties: [:], required: [], additionalProperties: true)
    )

    private func request() -> BoneInferenceRequest {
        BoneInferenceRequest(
            modelID: "model",
            messages: [.init(role: .user, content: "scan")],
            availableTools: [Self.tool]
        )
    }

    private func openAIEngine(_ body: String) -> BoneOpenAIInferenceEngine {
        BoneOpenAIInferenceEngine(
            configuration: .init(
                kind: .agnes,
                apiKey: "test",
                baseURL: URL(string: "https://synthetic.invalid/v1")!
            ),
            transport: FixedResponseTransport(response: Data(body.utf8))
        )
    }

    private func anthropicEngine(_ body: String) -> BoneAnthropicInferenceEngine {
        BoneAnthropicInferenceEngine(
            configuration: .init(
                kind: .anthropic,
                apiKey: "test",
                baseURL: URL(string: "https://synthetic.invalid/v1")!
            ),
            transport: FixedResponseTransport(response: Data(body.utf8))
        )
    }

    private func assertTruncated(
        _ body: () async throws -> Void,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("截断响应必须失败：\(label)", file: file, line: line)
        } catch {
            XCTAssertNil(
                error as? BoneInferenceProtocolShapeError,
                "截断不是协议形状失败：\(label)",
                file: file,
                line: line
            )
            XCTAssertEqual(
                error as? BoneInferenceTransportError,
                .outputTruncated,
                label,
                file: file,
                line: line
            )
        }
    }

    // MARK: - OpenAI 兼容 Tool wire

    func testOpenAITruncatedWithoutToolCallsIsTruncation() async {
        // 真实场景：输出预算全部消耗在推理 token 上，finish_reason 为 length 且没有任何 tool call。
        let body = #"{"choices":[{"index":0,"message":{"role":"assistant"},"finish_reason":"length"}],"usage":{"prompt_tokens":6634,"completion_tokens":16384,"completion_tokens_details":{"reasoning_tokens":16388}}}"#
        await assertTruncated({ _ = try await self.openAIEngine(body).infer(request: self.request()) }, "openai-truncated-no-calls")
    }

    func testOpenAITruncatedWithCompleteToolCallIsTruncation() async {
        let body = #"{"choices":[{"index":0,"message":{"role":"assistant","tool_calls":[{"id":"call_1","type":"function","function":{"name":"probe","arguments":"{}"}}]},"finish_reason":"length"}],"usage":{"prompt_tokens":10,"completion_tokens":16384}}"#
        await assertTruncated({ _ = try await self.openAIEngine(body).infer(request: self.request()) }, "openai-truncated-complete-call")
    }

    func testOpenAITruncatedWithCutOffArgumentsIsTruncation() async {
        // 参数 JSON 被截断，原因仍是预算耗尽，不能报成形状错误。
        let body = #"{"choices":[{"index":0,"message":{"role":"assistant","tool_calls":[{"id":"call_1","type":"function","function":{"name":"probe","arguments":"{\"value\":"}}]},"finish_reason":"length"}]}"#
        await assertTruncated({ _ = try await self.openAIEngine(body).infer(request: self.request()) }, "openai-truncated-cut-off-arguments")
    }

    func testOpenAIToolTurnIsDeliveredWhenNotTruncated() async throws {
        let body = #"{"choices":[{"index":0,"message":{"role":"assistant","tool_calls":[{"id":"call_1","type":"function","function":{"name":"probe","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":20}}"#
        let result = try await openAIEngine(body).inferDetailed(request: request())
        guard case let .assistantTurn(turn, finishReason, _, _, _) = result.response else {
            return XCTFail("expected assistant turn")
        }
        XCTAssertEqual(finishReason, .toolCalls)
        XCTAssertEqual(turn.toolCalls.count, 1)
    }

    // MARK: - Anthropic Tool wire

    func testAnthropicTruncatedTextOnlyIsTruncation() async {
        let body = #"{"content":[{"type":"text","text":"partial"}],"stop_reason":"max_tokens"}"#
        await assertTruncated({ _ = try await self.anthropicEngine(body).infer(request: self.request()) }, "anthropic-truncated-text-only")
    }

    func testAnthropicTruncatedToolUseIsTruncation() async {
        // hasCalls 分支曾把 stop_reason 吞成 .other(providerCode: "max_tokens") 并当作成功轮次交付。
        let body = #"{"content":[{"type":"tool_use","id":"call_1","name":"probe","input":{}}],"stop_reason":"max_tokens"}"#
        await assertTruncated({ _ = try await self.anthropicEngine(body).infer(request: self.request()) }, "anthropic-truncated-with-tool-use")
    }

    func testAnthropicTruncatedThinkingOnlyIsTruncation() async {
        // 仅剩 thinking block 时旧顺序会在内容构造处抛 invalidResponse。
        let body = #"{"content":[{"type":"thinking","thinking":"PRIVATE_THINKING"}],"stop_reason":"max_tokens"}"#
        await assertTruncated({ _ = try await self.anthropicEngine(body).infer(request: self.request()) }, "anthropic-truncated-thinking-only")
    }

    func testAnthropicTruncatedWithoutContentBlocksIsTruncation() async {
        let body = #"{"content":[],"stop_reason":"max_tokens"}"#
        await assertTruncated({ _ = try await self.anthropicEngine(body).infer(request: self.request()) }, "anthropic-truncated-empty-blocks")
    }

    func testAnthropicToolTurnIsDeliveredWhenNotTruncated() async throws {
        let body = #"{"content":[{"type":"tool_use","id":"call_1","name":"probe","input":{}}],"stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":20}}"#
        let result = try await anthropicEngine(body).inferDetailed(request: request())
        guard case let .assistantTurn(turn, finishReason, _, _, _) = result.response else {
            return XCTFail("expected assistant turn")
        }
        XCTAssertEqual(finishReason, .toolCalls)
        XCTAssertEqual(turn.toolCalls.count, 1)
    }

    // MARK: - 状态码映射

    func testForbiddenIsNotCredentialFailure() {
        XCTAssertEqual(BoneInferenceProviderResponseValidator.mappedError(statusCode: 401), .invalidCredential)
        XCTAssertEqual(BoneInferenceProviderResponseValidator.mappedError(statusCode: 403), .httpStatus(403))
    }
}

private struct FixedResponseTransport: BoneInferenceHTTPTransport {
    let response: Data

    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        .init(statusCode: 200, data: response)
    }

    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        try await send(request)
    }

    func sendEventStream(
        _ request: URLRequest,
        options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceEventStreamResponse {
        .init(statusCode: 200, events: [])
    }
}
