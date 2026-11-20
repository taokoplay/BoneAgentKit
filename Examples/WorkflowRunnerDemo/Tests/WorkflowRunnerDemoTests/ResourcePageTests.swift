import Foundation
import Testing
import BoneAgentKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import WorkflowRunnerDemo

struct ResourcePageTests {
    /// 验证直接命中扩读只沿 offset 续读，传入最大页码也不会产生越界 nextRead。
    @Test func directWindowsContinueWithoutInventingFilePageNumbers() async throws {
        let store = DemoTextResourceStore()
        let item = try await store.add(name: "命中窗口", text: String(repeating: "中🙂", count: 10_000))
        let tool = DemoResourcePageTool(store: store, access: nil)
        let first = try await tool.execute(input: .init(resourceID: item.id,
            page: DemoResourcePageInput.maximumPage, offset: 7), context: .init())
        let next = try #require(first.nextRead)
        #expect(next.page == 0 && next.offset == first.nextOffset)
        let second = try await tool.execute(input: next, context: .init())
        #expect(second.offset == first.nextOffset)
        #expect(second.nextRead?.offset == second.nextOffset)
        try BoneToolSchemaValidator.validate(arguments: JSONEncoder().encode(next),
            against: #require(DemoResourcePageTool.definition.inputSchema))
        await #expect(throws: DemoResourcePageError.invalidPage) {
            try await store.readPage(reference: item.preview.reference, number: -1)
        }
    }

    @Test func hostPagesUseScalarBoundariesAndSupplyCompleteNextArguments() async throws {
        let store = DemoTextResourceStore()
        let item = try await store.add(name: "owned-22000.txt", text: DemoFileRecoveryFixture.text)
        let access = DemoTextResourceAccess()
        await access.allow([item.preview.reference])
        let tool = DemoResourcePageTool(store: store, access: access)
        // The previous contract rejected a plausible, but hand-computed, UTF-8 offset.
        await #expect(throws: BoneToolTextResourceError.invalidOffset) {
            try await store.readText(.init(reference: item.preview.reference, offset: 16_384, maximumBytes: 16_384))
        }
        let first = try await tool.execute(input: .init(resourceID: item.id), context: .init())
        let next = try #require(first.nextRead)
        #expect(first.offset == 0 && first.text.utf8.count == 16_382)
        #expect(next == (try DemoResourcePageInput(resourceID: item.id, page: 1)))
        let second = try await tool.execute(input: next, context: .init())
        #expect(second.offset == 16_382 && second.nextRead == nil && second.nextOffset == nil)
        #expect(Data((first.text + second.text).utf8) == Data(DemoFileRecoveryFixture.text.utf8))
        let encoded = try JSONEncoder().encode(second)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["nextRead"] is NSNull && object["nextOffset"] is NSNull)
        #expect(try JSONDecoder().decode(BoneToolTextResourcePage.self, from: encoded).text == second.text)
        let schema = try #require(DemoResourcePageTool.definition.inputSchema)
        try BoneToolSchemaValidator.validate(arguments: JSONEncoder().encode(next), against: schema)
    }

    @Test func pageReadsKeepExactVersionScopeAndRevocationChecks() async throws {
        let store = DemoTextResourceStore()
        let sent = try await store.add(name: "sent.txt", text: "owned sent")
        let pending = try await store.add(name: "pending.txt", text: "owned pending")
        let access = DemoTextResourceAccess()
        await access.allow([sent.preview.reference])
        let tool = DemoResourcePageTool(store: store, access: access)
        await #expect(throws: BoneToolTextResourceError.accessDenied) {
            try await tool.execute(input: .init(resourceID: pending.id), context: .init())
        }
        let foreign = try BoneToolTextResourceReference(id: sent.id, version: UUID().uuidString, utf8ByteCount: sent.utf8ByteCount)
        await access.allow([foreign])
        await #expect(throws: BoneToolTextResourceError.referenceMismatch) {
            try await tool.execute(input: .init(resourceID: sent.id), context: .init())
        }
        await access.allow([sent.preview.reference])
        #expect(try await tool.execute(input: .init(resourceID: sent.id), context: .init()).text == "owned sent")
        await store.remove(id: sent.id)
        await #expect(throws: BoneToolTextResourceError.unavailable) {
            try await tool.execute(input: .init(resourceID: sent.id), context: .init())
        }
    }

    @Test func emptyAndMaximumSizedFilesHaveBoundedPagesAndNoPastEndFallback() async throws {
        let store = DemoTextResourceStore()
        let empty = try await store.add(name: "empty.txt", text: "")
        let tiny = try await store.add(name: "tiny.txt", text: "中🙂")
        let maximumText = String(repeating: "中", count: 174_762) + "aa"
        let maximum = try await store.add(name: "maximum.txt", text: maximumText)
        #expect(maximum.utf8ByteCount == DemoTextResourceStore.maximumResourceBytes)
        let tool = DemoResourcePageTool(store: store, access: nil)
        let emptyPage = try await tool.execute(input: .init(resourceID: empty.id), context: .init())
        #expect(emptyPage.text.isEmpty && emptyPage.nextRead == nil)
        await #expect(throws: DemoResourcePageError.pagePastEnd) {
            try await tool.execute(input: .init(resourceID: tiny.id, page: 1), context: .init())
        }
        let last = try await tool.execute(input: .init(resourceID: maximum.id, page: 32), context: .init())
        #expect(last.nextRead == nil && last.nextOffset == nil && !last.text.isEmpty)
        #expect(last.offset + last.text.utf8.count == maximum.utf8ByteCount)
        #expect(throws: DemoResourcePageError.invalidPage) { try DemoResourcePageInput(resourceID: tiny.id, page: -1) }
        #expect(throws: DemoResourcePageError.invalidPage) { try DemoResourcePageInput(resourceID: tiny.id, page: DemoResourcePageInput.maximumPage + 1) }
        let defaultPage = try JSONDecoder().decode(DemoResourcePageInput.self, from: Data("{\"resourceID\":\"\(tiny.id)\"}".utf8))
        #expect(defaultPage.page == 0)
    }

    struct InvalidCall: Sendable {
        let arguments: String
        let expected: DemoResourceReadIssue
    }
    @Test(arguments: [
        InvalidCall(arguments: #"{"reference":{"id":"PRIVATE-MARKER","version":"v1","utf8ByteCount":22000},"offset":16384,"maximumBytes":16384}"#, expected: .missingResourceID),
        InvalidCall(arguments: #"{"resourceID":"PRIVATE-MARKER","page":"1"}"#, expected: .invalidFieldType),
        InvalidCall(arguments: #"{"resourceID":"PRIVATE-MARKER","page":8193}"#, expected: .pageOutOfRange),
        InvalidCall(arguments: #"{"resourceID":"PRIVATE-MARKER","page":0,"maximumBytes":999999}"#, expected: .unexpectedField)
    ])
    func badModelArgumentsProduceSpecificSafeDiagnosticsWithoutAutomaticRetry(value: InvalidCall) async throws {
        let transport = ResourceArgumentTransport(arguments: value.arguments)
        let session = try await DemoLiveChatSession.make(settings: DemoFileRecoveryFixture.settings,
            apiKey: DemoFileRecoveryFixture.key, transport: transport, textResources: DemoTextResourceStore())
        await #expect(throws: DemoLiveChatFailure.toolFailed) { try await session.send("查看文件") }
        let failure = try #require(await session.toolFailureDiagnostic())
        #expect(failure.tool == .resourceRead && failure.reason == .invalidArguments && failure.resourceIssue == value.expected)
        #expect(failure.title == "资料读取参数有误")
        let diagnostic = try #require(await session.failureDiagnostic())
        #expect(diagnostic.completedTools == 0 && diagnostic.maximumReplyTokens == 1_024)
        #expect(!String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self).contains("PRIVATE-MARKER"))
        #expect(!diagnostic.text.contains("PRIVATE-MARKER"))
        await #expect(throws: DemoLiveChatFailure.toolFailed) { try await session.send("不会自动重发") }
        #expect(await transport.requests == 1)
    }

    @Test func legacyRecordsStillDecodeAndUnknownSchemaPathsNeverEnterDiagnostics() throws {
        let old = try JSONDecoder().decode(DemoToolFailure.self,
            from: Data(#"{"tool":"resource.readText","reason":"invalidArguments","requiresOutcomeReview":false}"#.utf8))
        #expect(old.resourceIssue == nil && old.title == "资料读取参数有误")
        #expect(old.message.contains("文件仍保留"))
        let issue = DemoResourceReadIssue.schema(.init(path: "$.PRIVATE-MARKER", rule: .missingRequired))
        #expect(issue == .invalidShape && !issue.message.contains("PRIVATE-MARKER"))
    }
}

private actor ResourceArgumentTransport: BoneInferenceHTTPTransport {
    let arguments: String
    private(set) var requests = 0
    init(arguments: String) { self.arguments = arguments }
    func send(_ request: URLRequest) throws -> BoneInferenceHTTPResponse { throw BoneInferenceTransportError.invalidResponse }
    func sendRetryableForModels(_ request: URLRequest) throws -> BoneInferenceHTTPResponse { try send(request) }
    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) throws -> BoneInferenceEventStreamResponse {
        requests += 1
        func json(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        return .init(statusCode: 200, events: [
            .init(event: "message_start", data: #"{"type":"message_start","message":{"id":"resource-bad-input","type":"message","role":"assistant","content":[],"usage":{"input_tokens":3,"output_tokens":0}}}"#),
            .init(event: "content_block_start", data: #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"read-1","name":"resource_read_text","input":{}}}"#),
            .init(event: "content_block_delta", data: try json(["type": "content_block_delta", "index": 0,
                "delta": ["type": "input_json_delta", "partial_json": arguments]])),
            .init(event: "content_block_stop", data: #"{"type":"content_block_stop","index":0}"#),
            .init(event: "message_delta", data: #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":2}}"#),
            .init(event: "message_stop", data: #"{"type":"message_stop"}"#)
        ])
    }
}
