import Foundation
import Testing
import BoneAgentKit
@testable import WorkflowRunnerDemo

struct SDKChatAdapterTests {
    @Test(arguments: [DemoChatProvider.deepSeek, .openAI, .anthropic, .gemini])
    func selectedSDKDefaultsCanCompleteAChat(provider: DemoChatProvider) async throws {
        var settings = DemoLiveChatSettings()
        settings.selectProvider(provider)
        settings.usesStreaming = false
        settings.managesContext = false
        let response: Data
        switch provider.kind {
        case .anthropic, .miniMax:
            response = Data(#"{"id":"fixture","type":"message","role":"assistant","content":[{"type":"text","text":"SDK adapter reply"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#.utf8)
        case .google:
            response = Data(#"{"candidates":[{"content":{"role":"model","parts":[{"text":"SDK adapter reply"}]},"finishReason":"STOP"}]}"#.utf8)
        default:
            response = Data(#"{"id":"fixture","choices":[{"index":0,"message":{"role":"assistant","content":"SDK adapter reply"},"finish_reason":"stop"}]}"#.utf8)
        }
        let transport = BoneInferenceURLSessionTransport(loader: { _ in
            (response, .init(statusCode: 200, headers: ["content-type": "application/json"]))
        })
        let session = try await DemoLiveChatSession.make(settings: settings, apiKey: "unit-test-key", transport: transport)
        let reply = try await session.send("Hello")
        #expect(reply.text == "SDK adapter reply")
        #expect(reply.steps == 1)
        #expect(reply.toolCalls == 0)
    }
}
