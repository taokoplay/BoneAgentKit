import Foundation
import BoneAgentKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Owned offline input shared by core tests and the explicitly isolated phone diagnostic.
/// This transport never forwards requests or retains their bodies/credentials.
enum DemoFileRecoveryFixture {
    static let key = "owned-offline-fixture-key"
    static let initialQuestion = "接收附件，先确认"
    static let question = "查看文件"
    static let nextQuestion = "下一条独立草稿"
    static let futureText = "OWNED_FUTURE_DRAFT_MUST_NOT_BE_SENT"
    static let tail = "OWNED_FILE_RECOVERY_TAIL"
    static let partial = "【离线模拟】已读取文件，但这段回答尚未完成"
    static let answer = "【离线模拟】已完整分页读取 22000 字节，包含末尾标记；文件内容概览已完成。"
    static var text: String {
        // A four-byte scalar crosses the nominal first-page boundary.
        let prefix = "\u{FEFF}" + String(repeating: "a", count: 16_379) + "🙂中e\u{301}\r\n"
        let suffix = "\n" + tail
        return prefix + String(repeating: "b", count: 22_000 - prefix.utf8.count - suffix.utf8.count) + suffix
    }
    static var settings: DemoLiveChatSettings {
        var settings = DemoLiveChatSettings()
        settings.selectProvider(.init(rawValue: "MiniMax"))
        settings.modelID = "MiniMax-M3.1-Flash"
        settings.enablesTextResources = true
        settings.maximumOutputTokens = 1_024
        settings.usesStreaming = true
        settings.managesContext = false
        settings.preservesConversation = false
        return settings
    }

    private struct Preview: Decodable {
        let preview: BoneToolTextResourcePreview
        let firstRead: DemoResourcePageInput
    }
    struct Step: Sendable {
        let events: [BoneInferenceEventStreamEvent]
        let maximumTokens: Int
        let references: [BoneToolTextResourceReference]
        let pages: [BoneToolTextResourcePage]
    }
    static func step(_ request: URLRequest) throws -> Step {
        guard let data = request.httpBody,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = body["messages"] as? [[String: Any]],
              let maximum = body["max_tokens"] as? Int else { throw BoneInferenceTransportError.invalidResponse }
        var references: [BoneToolTextResourceReference] = []
        var pages: [BoneToolTextResourcePage] = []
        var currentQuestion = ""
        var nextRead: DemoResourcePageInput?
        for message in messages {
            let blocks = message["content"] as? [[String: Any]] ?? []
            let texts = (message["content"] as? String).map { [$0] } ?? blocks.compactMap { $0["text"] as? String }
            for text in texts where message["role"] as? String == "user" {
                if text.hasPrefix(initialQuestion) || text.hasPrefix(question) { currentQuestion = text }
                let marker = "Read the text-resource tool using firstRead; copy nextRead verbatim for following pages.\n"
                if let range = text.range(of: marker),
                   let previews = try? JSONDecoder().decode([Preview].self, from: Data(text[range.upperBound...].utf8)) {
                    references += previews.map { $0.preview.reference }
                    nextRead = previews.first?.firstRead
                }
            }
            for block in blocks where block["type"] as? String == "tool_result" {
                let contents = (block["content"] as? String).map { [$0] } ??
                    (block["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                for content in contents {
                    if let output = try? JSONDecoder().decode(DemoResourcePageOutput.self, from: Data(content.utf8)) {
                        pages.append(try .init(reference: output.reference, offset: output.offset, text: output.text))
                        nextRead = output.nextRead
                    }
                }
            }
        }
        let events: [BoneInferenceEventStreamEvent]
        if currentQuestion.hasPrefix(initialQuestion) {
            events = try textEvents("【离线模拟】附件已接收。", truncated: false)
        } else {
            guard currentQuestion.hasPrefix(question), let reference = references.first,
                  reference.utf8ByteCount == 22_000 else { throw BoneInferenceTransportError.invalidResponse }
            if let page = pages.last {
                guard page.reference == reference else { throw BoneInferenceTransportError.invalidResponse }
                if page.nextOffset != nil, let nextRead { events = try readEvents(nextRead) }
                else {
                    let combined = pages.map(\.text).joined()
                    guard pages.first?.offset == 0, Data(combined.utf8) == Data(text.utf8), combined.hasSuffix(tail) else {
                        throw BoneInferenceTransportError.invalidResponse
                    }
                    events = try textEvents(maximum < 4_096 ? partial : answer, truncated: maximum < 4_096)
                }
            } else {
                guard let nextRead else { throw BoneInferenceTransportError.invalidResponse }
                events = try readEvents(nextRead)
            }
        }
        return .init(events: events, maximumTokens: maximum, references: references, pages: pages)
    }
    private static func readEvents(_ request: DemoResourcePageInput) throws -> [BoneInferenceEventStreamEvent] {
        let input = try JSONEncoder().encode(request)
        guard let name = DemoResourcePageTool.definition.wireName else {
            throw BoneInferenceTransportError.invalidResponse
        }
        return try events(start: ["type": "tool_use", "id": "file-page-\(request.page)", "name": name, "input": [:]],
                          delta: ["type": "input_json_delta", "partial_json": String(decoding: input, as: UTF8.self)], reason: "tool_use")
    }
    private static func textEvents(_ text: String, truncated: Bool) throws -> [BoneInferenceEventStreamEvent] {
        try events(start: ["type": "text", "text": ""], delta: ["type": "text_delta", "text": text],
                   reason: truncated ? "max_tokens" : "end_turn")
    }
    private static func events(start: [String: Any], delta: [String: Any], reason: String) throws -> [BoneInferenceEventStreamEvent] {
        func json(_ value: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        return [
            .init(event: "message_start", data: #"{"type":"message_start","message":{"id":"file-offline","type":"message","role":"assistant","content":[],"usage":{"input_tokens":3,"output_tokens":0}}}"#),
            .init(event: "content_block_start", data: try json(["type": "content_block_start", "index": 0, "content_block": start])),
            .init(event: "content_block_delta", data: try json(["type": "content_block_delta", "index": 0, "delta": delta])),
            .init(event: "content_block_stop", data: #"{"type":"content_block_stop","index":0}"#),
            .init(event: "message_delta", data: try json(["type": "message_delta", "delta": ["stop_reason": reason], "usage": ["output_tokens": 2]])),
            .init(event: "message_stop", data: #"{"type":"message_stop"}"#)
        ]
    }
}

actor DemoFileRecoveryTransport: BoneInferenceHTTPTransport {
    struct Audit: Sendable {
        let requests: Int
        let nonStreamingCalls: Int
        let replyLimits: [Int]
        let previewReferences: Set<BoneToolTextResourceReference>
        let pageReferences: Set<BoneToolTextResourceReference>
        let sawForbiddenMaterial: Bool
    }
    private var requests = 0
    private var nonStreamingCalls = 0
    private var replyLimits: [Int] = []
    private var previewReferences = Set<BoneToolTextResourceReference>()
    private var pageReferences = Set<BoneToolTextResourceReference>()
    private var forbidden = [DemoFileRecoveryFixture.futureText]
    private var sawForbiddenMaterial = false

    func forbid(_ value: String) { forbidden.append(value) }
    func audit() -> Audit {
        .init(requests: requests, nonStreamingCalls: nonStreamingCalls, replyLimits: replyLimits,
              previewReferences: previewReferences, pageReferences: pageReferences, sawForbiddenMaterial: sawForbiddenMaterial)
    }
    func send(_ request: URLRequest) throws -> BoneInferenceHTTPResponse {
        nonStreamingCalls += 1
        throw BoneInferenceTransportError.invalidResponse
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
                    for event in try await responseEvents(request) {
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
    private func responseEvents(_ request: URLRequest) throws -> [BoneInferenceEventStreamEvent] {
        requests += 1
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        sawForbiddenMaterial = sawForbiddenMaterial || forbidden.contains { body.contains($0) }
        let step = try DemoFileRecoveryFixture.step(request)
        replyLimits.append(step.maximumTokens)
        previewReferences.formUnion(step.references)
        pageReferences.formUnion(step.pages.map(\.reference))
        return step.events
    }
}
