import Foundation
import Testing
@testable import WorkflowRunnerDemo

struct ConversationArchiveTests {
    private func fixture(inFlight: Bool = false) -> DemoConversationArchive {
        .init(bindingID: String(repeating: "a", count: 64), sdkState: Data("private-sdk-state".utf8),
              textResourceState: Data(), imageState: Data(),
              messages: [.init(role: .user, text: "私有问题"), .init(role: .assistant, text: "已完成回复")],
              requestInFlight: inFlight)
    }

    @Test func privateSnapshotReopensAndPreservesInterruptedMarker() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = DemoConversationArchiveStore(directory: directory)
        try await first.save(fixture(inFlight: true))
        let reopened = DemoConversationArchiveStore(directory: directory)
        let value = try #require(try await reopened.load(bindingID: String(repeating: "a", count: 64)))
        #expect(value.requestInFlight)
        #expect(value.messages.map(\.text) == ["私有问题", "已完成回复"])
        #expect(value.sdkState == Data("private-sdk-state".utf8))
        try await reopened.clear()
        #expect(try await reopened.load(bindingID: value.bindingID) == nil)
    }

    @Test func differentBindingCannotLoadAndDoesNotDestroySavedConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DemoConversationArchiveStore(directory: directory)
        try await store.save(fixture())
        await #expect(throws: DemoConversationStorageError.bindingMismatch) {
            try await store.load(bindingID: String(repeating: "b", count: 64))
        }
        #expect(try await store.load(bindingID: String(repeating: "a", count: 64)) != nil)
    }

    @Test func malformedAndOversizedLogicalStateIsRejectedBeforeReplacingGoodState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DemoConversationArchiveStore(directory: directory)
        let good = fixture()
        try await store.save(good)
        var invalid = good
        invalid.schemaVersion = 99
        await #expect(throws: DemoConversationStorageError.invalidArchive) { try await store.save(invalid) }
        let existing = try #require(try await store.load(bindingID: good.bindingID))
        #expect(existing.schemaVersion == 1)
        #expect(existing.messages == good.messages)
        let file = store.fileURL
        try Data("not json".utf8).write(to: file)
        await #expect(throws: DemoConversationStorageError.invalidArchive) { try await store.load(bindingID: good.bindingID) }
    }
}
