import Foundation
import Testing
import BoneAgentKit
import BoneAgentTools

struct ResourceAndQuestionTests {
    @Test func literalSearchReturnsExactUnicodeOffsetsAndReadableVersions() throws {
        let text = "前缀🙂 e\u{301}\nAlpha 中文 MATCH 后缀\nmatch 再次"
        let resource = try BoneTextResourceCollection.Resource(name: "示例", text: text, id: "text-1", version: "v1")
        let collection = try BoneTextResourceCollection(resources: [resource])
        let result = try collection.search(.init(query: "match", limit: 10))
        #expect(result.hits.count == 2 && !result.isTruncated)
        let first = try #require(result.hits.first)
        let offset = text[..<(try #require(text.range(of: "MATCH"))).lowerBound].utf8.count
        #expect(first.matchOffset == offset)
        let page = try collection.read(.init(reference: first.resource.reference, offset: offset, maximumBytes: 64))
        #expect(page.text.hasPrefix("MATCH"))
        let limited = try collection.search(.init(query: "match", limit: 1))
        #expect(limited.hits.count == 1 && limited.isTruncated)
        let listed = try collection.list(.init(offset: 0, limit: 1))
        #expect(listed.resources == [resource.descriptor] && listed.nextOffset == nil)
    }

    @Test func boundedSnippetsRespectUTF8AndReferenceBytes() throws {
        let text = String(repeating: "🙂中", count: 500) + "needle" + String(repeating: "末", count: 2_000)
        let resource = try BoneTextResourceCollection.Resource(name: "Unicode", text: text)
        let collection = try BoneTextResourceCollection(resources: [resource])
        let hit = try #require(collection.search(.init(query: "needle")).hits.first)
        #expect(hit.snippet.utf8.count <= 2_048)
        #expect(hit.snippet.contains("needle") && !hit.snippet.contains("�"))
        let original = Data(text.utf8)
        #expect(Data(hit.snippet.utf8) == original.subdata(in: hit.snippetOffset..<(hit.snippetOffset + hit.snippet.utf8.count)))
    }

    @Test func resourceValidationRejectsDecodedInvalidRequestsAndBadResults() async throws {
        let bad = try JSONDecoder().decode(BoneTextResourceListRequest.self, from: Data(#"{"offset":-1,"limit":200}"#.utf8))
        let flag = ResourceProbe()
        let tool = BoneTextResourceListTool<BoneAgentEmptyContext> { _, _ in
            await flag.mark(); return .init(resources: [], nextOffset: nil)
        }
        await #expect(throws: BoneResourceQueryError.invalidRequest) {
            try await tool.execute(input: bad, context: .init())
        }
        #expect(await flag.calls == 0)
        #expect(throws: BoneResourceQueryError.invalidRequest) { try BoneTextResourceSearchRequest(query: " ") }
        #expect(throws: BoneResourceQueryError.capacityExceeded) {
            try BoneTextResourceCollection.Resource(name: "too large", text: String(repeating: "a", count: 2 * 1_048_576 + 1))
        }
        let resource = try BoneTextResourceCollection.Resource(name: "r", text: "abc", id: "r", version: "1")
        #expect(throws: BoneResourceQueryError.duplicateResource) {
            try BoneTextResourceCollection(resources: [resource, resource])
        }
        let malformed = BoneTextResourceListResult(resources: [resource.descriptor], nextOffset: 9)
        #expect(throws: BoneResourceQueryError.invalidResult) { try malformed.validated(for: .init(limit: 1)) }
        let collection = try BoneTextResourceCollection(resources: [resource])
        #expect(throws: BoneToolTextResourceError.referenceMismatch) {
            try collection.read(.init(reference: .init(id: "r", version: "2", utf8ByteCount: 3)))
        }
    }

    @Test func explicitCollectionToolsReauthorizeEveryOperation() async throws {
        let collection = try BoneTextResourceCollection(resources: [.init(name: "r", text: "secret", id: "r", version: "1")])
        let probe = ResourceProbe()
        let tools = collection.tools { (_: BoneAgentEmptyContext) in try await probe.authorize() }
        #expect(tools.map(\.definition.id) == ["resource.list", "resource.search", "resource.readText"])
        for tool in tools { _ = try tool.definition.validatedForModelExposure() }
        let request = try JSONEncoder().encode(BoneTextResourceListRequest())
        _ = try await tools[0].execute(input: request, context: BoneAgentEmptyContext())
        await probe.revoke()
        await #expect(throws: BoneToolTextResourceError.accessDenied) {
            try await tools[0].execute(input: request, context: BoneAgentEmptyContext())
        }
        #expect(await probe.calls == 2)
    }

    @Test func questionsRequireRealMatchingAnswersAndNeverGrantOtherCapabilities() async throws {
        let question = try BoneUserQuestion(question: "选一个", kind: .singleChoice,
            options: [.init(id: "a", label: "甲"), .init(id: "b", label: "乙")])
        let tool = BoneAskUserTool<BoneAgentEmptyContext> { _, _ in .init(selectedOptionIDs: ["b"]) }
        #expect(try await tool.execute(input: question, context: .init()).selectedOptionIDs == ["b"])
        #expect(throws: BoneAskUserError.invalidAnswer) { try BoneUserAnswer(selectedOptionIDs: ["x"]).validated(for: question) }
        #expect(throws: BoneAskUserError.invalidAnswer) { try BoneUserAnswer(selectedOptionIDs: ["a", "a"]).validated(for: question) }
        #expect(throws: BoneAskUserError.invalidAnswer) { try BoneUserAnswer(status: .cancelled, text: "approved").validated(for: question) }
        #expect(try BoneUserAnswer(status: .cancelled).validated(for: question).status == .cancelled)
        let free = try BoneUserQuestion(question: "补充说明", kind: .text)
        #expect(try BoneUserAnswer(text: "真实回答").validated(for: free).text == "真实回答")
        #expect(throws: BoneAskUserError.invalidAnswer) { try BoneUserAnswer(text: " ").validated(for: free) }
        #expect(throws: BoneAskUserError.invalidQuestion) { try BoneUserQuestion(question: "x", kind: .singleChoice) }
        _ = try BoneAskUserTool<BoneAgentEmptyContext>.definition.validatedForModelExposure()
        #expect(BoneAskUserTool<BoneAgentEmptyContext>.definition.impact?.permissionChange == BoneToolPermissionChangeImpact.none)
        #expect(BoneAskUserTool<BoneAgentEmptyContext>.definition.impact?.requiresHostAuthorization == true)
    }

    @Test(.timeLimit(.minutes(1))) func cancellingQuestionCancelsHostWaitAndNeverPublishesLateAnswer() async throws {
        let channel = AsyncStream<Void>.makeStream()
        let tool = BoneAskUserTool<BoneAgentEmptyContext> { _, _ in
            channel.continuation.yield(())
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return .init(text: "late")
        }
        let question = try BoneUserQuestion(question: "等待", kind: .text)
        let task = Task { try await tool.execute(input: question, context: .init()) }
        var iterator = channel.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        channel.continuation.finish()
    }

    @Test func presetsAreMetadataAndNeverInstallTools() {
        #expect(BoneBuiltInToolGroup.allCases.count == 6)
        #expect(BoneBuiltInToolPreset.basic.groups == [.calculator, .dateTime, .askUser])
        #expect(BoneBuiltInToolPreset.research.groups.count == 6)
        #expect(BoneBuiltInToolGroup.resources.toolIDs.contains("resource.readText"))
    }
}

private actor ResourceProbe {
    private(set) var calls = 0
    private var allowed = true
    func mark() { calls += 1 }
    func revoke() { allowed = false }
    func authorize() throws {
        calls += 1
        guard allowed else { throw BoneToolTextResourceError.accessDenied }
    }
}
