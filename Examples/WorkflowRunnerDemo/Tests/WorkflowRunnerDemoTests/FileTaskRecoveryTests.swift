import Foundation
import Testing
import BoneAgentKit
import BoneAgentTools
@testable import WorkflowRunnerDemo

struct FileTaskRecoveryTests {
    @Test func recoveryKeepsOriginalAttachmentsAndTreatsAttachmentOnlyDraftAsOccupied() {
        let original = DemoChatTaskBundle(text: "查看文件", materials: .init(resourceIDs: ["file-A"]))
        #expect(DemoTaskRecovery.destination(for: original, draft: .init(text: ""), retained: nil) == .draft)
        #expect(DemoTaskRecovery.destination(for: original, draft: .init(text: "查看文件"), retained: nil) == .draft)
        let next = DemoChatTaskBundle(text: "下一条", materials: .init(resourceIDs: ["file-B"]))
        #expect(DemoTaskRecovery.destination(for: original, draft: next, retained: nil) == .retained)
        let attachmentOnly = DemoChatTaskBundle(text: "", materials: next.materials)
        #expect(!attachmentOnly.isEmpty)
        #expect(DemoTaskRecovery.destination(for: original, draft: attachmentOnly, retained: nil) == .retained)
        let sameTextDifferentFile = DemoChatTaskBundle(text: original.text, materials: next.materials)
        #expect(DemoTaskRecovery.destination(for: original, draft: sameTextDifferentFile, retained: nil) == .retained)
        #expect(DemoTaskRecovery.destination(for: original, draft: next, retained: .init(text: "第三条")) == .full)
        #expect(DemoTaskRecovery.destination(for: original, draft: next, retained: original) == .alreadyPresent)
        #expect(DemoTaskRecovery.destination(for: original, draft: .init(text: original.text, materials: original.materials), retained: nil) == .alreadyPresent)
        #expect(next.text == "下一条" && next.materials.resourceIDs == ["file-B"])
    }

    @Test func materialsDeduplicateInStableOrderWithoutMergingTaskIdentity() {
        let first = DemoChatMaterials(imageIDs: ["i2", "i1", "i2"], resourceIDs: ["b", "a", "b"])
        let second = DemoChatMaterials(imageIDs: ["i1", "i3"], resourceIDs: ["a", "c"])
        #expect(first.union(second) == .init(imageIDs: ["i2", "i1", "i3"], resourceIDs: ["b", "a", "c"]))
        #expect(first.subtracting(second) == .init(imageIDs: ["i2"], resourceIDs: ["b"]))
        #expect(second.isSubset(of: first.union(second)))
        let task = DemoChatTaskBundle(text: "相同问题", materials: first)
        let duplicate = DemoChatTaskBundle(text: task.text, materials: task.materials)
        #expect(task.id != duplicate.id && task.hasSameContents(as: duplicate))
    }

    @Test func scopedResourceToolsExcludeUnsentFilesAndRequireTheExactReference() async throws {
        let store = DemoTextResourceStore()
        let first = try await store.add(name: "原文件", text: "original searchable")
        let future = try await store.add(name: "下一条附件", text: "future searchable")
        let access = DemoTextResourceAccess()
        let reader = store.makeReader(access: access)
        let queryTools = store.makeQueryTools(access: access)
        let list = try #require(queryTools.first { $0.definition.id == "resource.list" })
        let search = try #require(queryTools.first { $0.definition.id == "resource.search" })
        func listed() async throws -> BoneTextResourceListResult {
            try JSONDecoder().decode(BoneTextResourceListResult.self,
                from: await list.execute(input: JSONEncoder().encode(BoneTextResourceListRequest()), context: BoneAgentEmptyContext()))
        }
        #expect(try await listed().resources.isEmpty)
        await #expect(throws: BoneToolTextResourceError.accessDenied) {
            try await reader.read(.init(reference: first.preview.reference), context: BoneAgentEmptyContext())
        }
        await access.allow([first.preview.reference])
        #expect(try await listed().resources.map(\.reference) == [first.preview.reference])
        let results = try await search.execute(input: JSONEncoder().encode(BoneTextResourceSearchRequest(query: "searchable")), context: BoneAgentEmptyContext())
        #expect(try JSONDecoder().decode(BoneTextResourceSearchResult.self, from: results).hits.map(\.resource.reference) == [first.preview.reference])
        #expect(try await reader.read(.init(reference: first.preview.reference), context: BoneAgentEmptyContext()).text == "original searchable")
        await #expect(throws: BoneToolTextResourceError.accessDenied) {
            try await reader.read(.init(reference: future.preview.reference), context: BoneAgentEmptyContext())
        }
        let changed = try BoneToolTextResourceReference(id: first.id, version: UUID().uuidString, utf8ByteCount: first.utf8ByteCount)
        await #expect(throws: BoneToolTextResourceError.accessDenied) {
            try await reader.read(.init(reference: changed), context: BoneAgentEmptyContext())
        }
        let newScope = store.makeReader(access: DemoTextResourceAccess())
        await #expect(throws: BoneToolTextResourceError.accessDenied) {
            try await newScope.read(.init(reference: first.preview.reference), context: BoneAgentEmptyContext())
        }
        // Explicit local preview remains available independently of model access.
        #expect(try await store.readText(.init(reference: future.preview.reference)).text == "future searchable")
    }

    @Test func local22kPreviewUsesSDKOffsetsAndPreservesEveryUTF8Byte() async throws {
        let store = DemoTextResourceStore()
        let entry = try await store.add(name: "owned-22000.txt", text: DemoFileRecoveryFixture.text)
        #expect(entry.utf8ByteCount == 22_000)
        #expect(entry.preview.text.utf8.count <= 1_024)
        var offset = 0
        var bytes = Data()
        var offsets: [Int] = []
        repeat {
            let page = try await store.readText(.init(reference: entry.preview.reference, offset: offset, maximumBytes: 16_384))
            offsets.append(page.offset)
            bytes.append(contentsOf: page.text.utf8)
            guard let next = page.nextOffset else { break }
            #expect(next > offset && next == offset + page.text.utf8.count)
            offset = next
        } while true
        #expect(offsets == [0, 16_382])
        #expect(bytes == Data(DemoFileRecoveryFixture.text.utf8))
    }

    @Test func earlierFileSurvivesTruncationAndExplicit4096RetryWithoutFutureDraftLeak() async throws {
        let store = DemoTextResourceStore()
        let first = try await store.add(name: "owned-22000.txt", text: DemoFileRecoveryFixture.text)
        let transport = DemoFileRecoveryTransport()
        let settings = DemoFileRecoveryFixture.settings
        let updates = FileRecoveryUpdates()
        let session = try await DemoLiveChatSession.make(settings: settings, apiKey: DemoFileRecoveryFixture.key,
            transport: transport, observer: { await updates.receive($0) }, textResources: store)
        #expect(await transport.audit().requests == 0)
        _ = try await session.send(DemoFileRecoveryFixture.initialQuestion, resources: [first])
        await #expect(throws: DemoLiveChatFailure.limitReached) { try await session.send(DemoFileRecoveryFixture.question) }
        #expect(await session.failureDiagnostic()?.code == .outputTruncated)
        #expect(await session.failureDiagnostic()?.completedTools == 2)
        #expect(await session.statistics().successfulRoundCount == 1)
        #expect(await updates.lastDraft == DemoFileRecoveryFixture.partial)
        #expect(await transport.audit().requests == 4)
        #expect(settings.maximumOutputTokens == 1_024)
        await #expect(throws: DemoLiveChatFailure.limitReached) { try await session.send("不应自动重试") }
        #expect(await transport.audit().requests == 4)
        await #expect(throws: DemoLiveChatFailure.limitReached) { try await session.exportPrivateState() }
        let future = try await store.add(name: "future.txt", text: DemoFileRecoveryFixture.futureText)
        await transport.forbid(future.id)
        var expanded = settings
        expanded.maximumOutputTokens = 4_096
        let retry = try await DemoLiveChatSession.make(settings: expanded, apiKey: DemoFileRecoveryFixture.key,
            transport: transport, textResources: store)
        // Constructing the new configuration and previewing locally do not dispatch.
        _ = try await store.readText(.init(reference: first.preview.reference, maximumBytes: 16_384))
        #expect(await transport.audit().requests == 4)
        let reply = try await retry.send(DemoFileRecoveryFixture.question, resources: [first])
        #expect(reply.text == DemoFileRecoveryFixture.answer && reply.toolCalls == 2 && reply.steps == 3)
        #expect(await retry.statistics().successfulRoundCount == 1)
        let audit = await transport.audit()
        #expect(audit.requests == 7 && audit.nonStreamingCalls == 0)
        #expect(audit.replyLimits == [1_024, 1_024, 1_024, 1_024, 4_096, 4_096, 4_096])
        #expect(audit.previewReferences == [first.preview.reference] && audit.pageReferences == [first.preview.reference])
        #expect(!audit.sawForbiddenMaterial)
        #expect(await store.entries() == [first, future])
    }

    @Test func maximumLengthFollowUpCanRetryWithItsPriorTurnFile() async throws {
        let store = DemoTextResourceStore()
        let resource = try await store.add(name: "owned-22000.txt", text: DemoFileRecoveryFixture.text)
        let transport = DemoFileRecoveryTransport()
        let settings = DemoFileRecoveryFixture.settings
        let session = try await DemoLiveChatSession.make(settings: settings, apiKey: DemoFileRecoveryFixture.key,
            transport: transport, textResources: store)
        _ = try await session.send(DemoFileRecoveryFixture.initialQuestion, resources: [resource])
        let question = DemoFileRecoveryFixture.question + String(repeating: "x",
            count: DemoLiveChatSession.maximumUserMessageBytes - DemoFileRecoveryFixture.question.utf8.count)
        #expect(question.utf8.count == 16_384)
        await #expect(throws: DemoLiveChatFailure.limitReached) { try await session.send(question) }
        #expect(await session.failureDiagnostic()?.code == .outputTruncated)
        var expanded = settings
        expanded.maximumOutputTokens = 4_096
        let retry = try await DemoLiveChatSession.make(settings: expanded, apiKey: DemoFileRecoveryFixture.key,
            transport: transport, textResources: store)
        let reply = try await retry.send(question, resources: [resource])
        #expect(reply.text == DemoFileRecoveryFixture.answer && reply.toolCalls == 2)
        #expect(await transport.audit().requests == 7)
    }
}

private actor FileRecoveryUpdates {
    private(set) var lastDraft = ""
    func receive(_ update: DemoLiveChatUpdate) {
        switch update {
        case .inferenceStarted: lastDraft = ""
        case .textDelta(let text): lastDraft += text
        default: break
        }
    }
}
