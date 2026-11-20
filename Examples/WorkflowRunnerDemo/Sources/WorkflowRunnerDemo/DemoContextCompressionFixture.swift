import Foundation
import BoneAgentKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Owned long-task fixture for the real Conversation/context pipeline; never a network fallback.
enum DemoContextCompressionFixture {
    static let question = "离线验证：读取全部四页并根据摘要给出简短概览"
    static let answer = "【离线模拟】四页读取完成，已保留当前问题和最近两组工具记录。"
    static let summary = "OWNED_CONTEXT_SUMMARY: earlier file pages were read; retain the four-page goal and verified facts."
    static let text = String(repeating: "p", count: 65_536)
    static var settings: DemoLiveChatSettings {
        var settings = DemoLiveChatSettings()
        settings.selectProvider(.customOpenAI)
        settings.baseURL = "https://context-fixture.invalid/v1"
        settings.modelID = "owned-context-fixture"
        settings.systemPrompt = "保留当前用户问题，按真实工具结果作答。"
        settings.enablesTextResources = true
        settings.managesContext = true
        settings.summarizesContext = true
        settings.contextToolHistoryCompaction = true
        settings.contextSummaryOutputTokens = 512
        settings.contextWindowTokens = 16_384
        settings.maximumOutputTokens = 128
        settings.usesStreaming = true
        return settings
    }
}

actor DemoContextCompressionTransport: BoneInferenceHTTPTransport {
    struct Audit: Sendable {
        let mainRequests: Int
        let summaryRequests: Int
        let mainOutputLimits: [Int]
        let summaryOutputLimit: Int?
        let finalRetainedPages: [Int]
        let finalHasSummary: Bool
        let finalHasQuestion: Bool
    }
    private var mainRequests = 0
    private var summaryRequests = 0
    private var mainOutputLimits: [Int] = []
    private var summaryOutputLimit: Int?
    private var finalRetainedPages: [Int] = []
    private var finalHasSummary = false
    private var finalHasQuestion = false

    func audit() -> Audit {
        .init(mainRequests: mainRequests, summaryRequests: summaryRequests, mainOutputLimits: mainOutputLimits,
              summaryOutputLimit: summaryOutputLimit, finalRetainedPages: finalRetainedPages,
              finalHasSummary: finalHasSummary, finalHasQuestion: finalHasQuestion)
    }
    func send(_ request: URLRequest) throws -> BoneInferenceHTTPResponse {
        let body = try object(request)
        guard body["tools"] == nil else { throw BoneInferenceTransportError.invalidResponse }
        summaryRequests += 1
        summaryOutputLimit = body["max_tokens"] as? Int ?? body["max_completion_tokens"] as? Int
        let response: [String: Any] = ["id": "context-summary", "choices": [["index": 0,
            "message": ["role": "assistant", "content": DemoContextCompressionFixture.summary], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 3, "completion_tokens": 2, "total_tokens": 5]]
        return .init(statusCode: 200, data: try JSONSerialization.data(withJSONObject: response))
    }
    func sendRetryableForModels(_ request: URLRequest) throws -> BoneInferenceHTTPResponse { try send(request) }
    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) async throws -> BoneInferenceEventStreamResponse {
        var events: [BoneInferenceEventStreamEvent] = []
        for try await event in eventStream(request, options: options) { events.append(event) }
        return .init(statusCode: 200, events: events)
    }
    nonisolated func eventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) -> BoneInferenceRawEventStream {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for event in try await mainEvents(request) {
                        try Task.checkCancellation(); continuation.yield(event)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
    private func object(_ request: URLRequest) throws -> [String: Any] {
        guard let data = request.httpBody, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BoneInferenceTransportError.invalidResponse
        }
        return object
    }
    private func mainEvents(_ request: URLRequest) throws -> [BoneInferenceEventStreamEvent] {
        let body = try object(request)
        guard let messages = body["messages"] as? [[String: Any]],
              let limit = body["max_tokens"] as? Int ?? body["max_completion_tokens"] as? Int else {
            throw BoneInferenceTransportError.invalidResponse
        }
        mainRequests += 1; mainOutputLimits.append(limit)
        let texts = messages.compactMap { $0["content"] as? String }
        let pages = messages.filter { $0["role"] as? String == "tool" }.compactMap { message -> DemoResourcePageOutput? in
            guard let text = message["content"] as? String else { return nil }
            return try? JSONDecoder().decode(DemoResourcePageOutput.self, from: Data(text.utf8))
        }
        let delta: [String: Any]
        let finish: String
        if mainRequests <= 4 {
            let input: DemoResourcePageInput
            if let next = pages.last?.nextRead { input = next }
            else {
                struct Preview: Decodable { let firstRead: DemoResourcePageInput }
                let marker = "Read the text-resource tool using firstRead; copy nextRead verbatim for following pages.\n"
                guard let source = texts.first(where: { $0.contains(marker) }), let range = source.range(of: marker),
                      let preview = try JSONDecoder().decode([Preview].self, from: Data(source[range.upperBound...].utf8)).first else {
                    throw BoneInferenceTransportError.invalidResponse
                }
                input = preview.firstRead
            }
            guard input.page == mainRequests - 1 else { throw BoneInferenceTransportError.invalidResponse }
            let arguments = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
            delta = ["role": "assistant", "tool_calls": [["index": 0, "id": "context-page-\(input.page)", "type": "function",
                "function": ["name": "resource_read_text", "arguments": arguments]]]]
            finish = "tool_calls"
        } else {
            guard mainRequests == 5 else { throw BoneInferenceTransportError.invalidResponse }
            finalRetainedPages = pages.map(\.page)
            finalHasSummary = texts.contains { $0.contains(DemoContextCompressionFixture.summary) }
            finalHasQuestion = texts.contains { $0.hasPrefix(DemoContextCompressionFixture.question) }
            delta = ["role": "assistant", "content": DemoContextCompressionFixture.answer]
            finish = "stop"
        }
        func json(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        return [
            .init(data: try json(["id": "owned-context", "choices": [["index": 0, "delta": delta, "finish_reason": NSNull()]]])),
            .init(data: try json(["id": "owned-context", "choices": [["index": 0, "delta": [:], "finish_reason": finish]],
                "usage": ["prompt_tokens": 3, "completion_tokens": 2, "total_tokens": 5]])),
            .init(data: "[DONE]")
        ]
    }
}
