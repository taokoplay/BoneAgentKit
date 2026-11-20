import Foundation
import Testing
@testable import WorkflowRunnerDemo

struct TextFileReaderTests {
    @Test func aGrowingSourceCannotReadBeyondLimitPlusOne() {
        let limit = 100_000
        var delivered = 0
        var largestRead = 0
        #expect(throws: DemoTextResourceStoreError.resourceTooLarge) {
            try DemoTextFileReader.readBounded(maximumBytes: limit) { requested in
                largestRead = max(largestRead, requested)
                delivered += requested
                return Data(repeating: 65, count: requested) // Simulates a source that keeps growing.
            }
        }
        #expect(delivered == limit + 1)
        #expect(largestRead <= 65_536)
    }

    @Test func exactLimitAndEmptyFileAreAcceptedButInvalidLimitsAreRejectedBeforeReading() throws {
        let source = Data(repeating: 65, count: 100_000)
        var offset = 0
        let read = try DemoTextFileReader.readBounded(maximumBytes: source.count) { requested in
            guard offset < source.count else { return nil }
            let end = min(offset + requested, source.count)
            defer { offset = end }
            return source.subdata(in: offset..<end)
        }
        #expect(read == source)
        #expect(try DemoTextFileReader.readBounded(maximumBytes: 1) { _ in nil }.isEmpty)
        var calls = 0
        #expect(throws: DemoTextFileReadError.invalidLimit) {
            try DemoTextFileReader.readBounded(maximumBytes: Int.max) { _ in calls += 1; return nil }
        }
        #expect(calls == 0)
    }

    @Test func fileImportRetainsBOMAndRejectsInvalidUTF8AndOversizedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-text-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.txt")
        let data = Data("\u{feff}中文🙂\n原文".utf8)
        try data.write(to: url)
        let text = try DemoTextFileReader.readUTF8(url: url)
        #expect(Data(text.utf8) == data)
        try Data([0xff, 0xfe]).write(to: url)
        #expect(throws: DemoTextFileReadError.invalidEncoding) { try DemoTextFileReader.readUTF8(url: url) }
        try Data(repeating: 65, count: DemoTextResourceStore.maximumResourceBytes + 64).write(to: url)
        #expect(throws: DemoTextResourceStoreError.resourceTooLarge) { try DemoTextFileReader.readUTF8(url: url) }
    }

    @Test func cancellationStopsBeforeOpeningTheReader() async {
        let gate = AsyncStream<Void>.makeStream()
        let task = Task {
            var iterator = gate.stream.makeAsyncIterator()
            _ = await iterator.next()
            return try DemoTextFileReader.readBounded(maximumBytes: 10) { _ in
                Issue.record("Cancelled import still read source bytes")
                return nil
            }
        }
        task.cancel()
        gate.continuation.finish()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
