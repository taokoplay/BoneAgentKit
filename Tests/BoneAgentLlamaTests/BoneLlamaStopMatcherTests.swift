import Foundation
import XCTest
@testable import BoneAgentLlama

final class BoneLlamaStopMatcherTests: XCTestCase {
    func testMatchesSameChunkAndDoesNotDeliverStopOrTrailingBytes() throws {
        var matcher = try BoneLlamaStopMatcher(stopStrings: ["<stop>"])

        XCTAssertEqual(
            matcher.consume(Data("hello<stop>ignored".utf8)),
            .matched(index: 0, deliverable: Data("hello".utf8))
        )
    }

    func testMatchesAcrossChunksAndUTF8ScalarBoundaries() throws {
        var matcher = try BoneLlamaStopMatcher(stopStrings: ["停止🐟"])
        let bytes = Array("before停止🐟after".utf8)
        var delivered = Data()
        var match: Int?

        for byte in bytes {
            switch matcher.consume(Data([byte])) {
            case let .none(chunk), let .partial(chunk): delivered.append(chunk)
            case let .matched(index, chunk):
                delivered.append(chunk)
                match = index
            }
            if match != nil { break }
        }

        XCTAssertEqual(String(decoding: delivered, as: UTF8.self), "before")
        XCTAssertEqual(match, 0)
    }

    func testHandlesOverlappingAndPrefixStopsDeterministically() throws {
        var prefix = try BoneLlamaStopMatcher(stopStrings: ["a", "ab"])
        XCTAssertEqual(prefix.consume(Data("a".utf8)), .matched(index: 0, deliverable: Data()))

        var overlap = try BoneLlamaStopMatcher(stopStrings: ["abab", "bab"])
        XCTAssertEqual(
            overlap.consume(Data("xxabab".utf8)),
            .matched(index: 0, deliverable: Data("xx".utf8))
        )
    }

    func testWithholdsOnlyPossibleStopPrefixAndFinishFlushesIt() throws {
        var matcher = try BoneLlamaStopMatcher(stopStrings: ["<stop>"])

        XCTAssertEqual(
            matcher.consume(Data("hello<st".utf8)),
            .partial(deliverable: Data("hello".utf8))
        )
        XCTAssertEqual(matcher.pendingByteCount, 3)
        XCTAssertEqual(matcher.finish(), Data("<st".utf8))
        XCTAssertEqual(matcher.pendingByteCount, 0)
    }

    func testRandomChunkingProducesSameMatchAndOutput() throws {
        let stream = Data("prefix-data-停止🐟trailing".utf8)
        let baseline = try run(stream: stream, chunkSizes: [stream.count])
        for seed in 1...50 {
            var sizes: [Int] = []
            var remaining = stream.count
            var state = UInt64(seed)
            while remaining > 0 {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                let size = min(remaining, Int(state % 5) + 1)
                sizes.append(size)
                remaining -= size
            }
            let chunked = try run(stream: stream, chunkSizes: sizes)
            XCTAssertEqual(chunked.0, baseline.0)
            XCTAssertEqual(chunked.1, baseline.1)
        }
    }

    func testRejectsInvalidStopConfiguration() {
        XCTAssertThrowsError(try BoneLlamaStopMatcher(stopStrings: []))
        XCTAssertThrowsError(try BoneLlamaStopMatcher(stopStrings: [""]))
        XCTAssertThrowsError(try BoneLlamaStopMatcher(stopStrings: ["x", "x"]))
        XCTAssertThrowsError(try BoneLlamaStopMatcher(
            stopStrings: [String(repeating: "x", count: BoneLlamaGenerationControl.maximumStopStringByteCount + 1)]
        ))
    }

    private func run(stream: Data, chunkSizes: [Int]) throws -> (Data, Int?) {
        var matcher = try BoneLlamaStopMatcher(stopStrings: ["停止🐟", "<stop>"])
        var delivered = Data()
        var matched: Int?
        var offset = 0
        for size in chunkSizes where matched == nil {
            let end = min(stream.count, offset + size)
            let chunk = stream.subdata(in: offset..<end)
            offset = end
            switch matcher.consume(chunk) {
            case let .none(data), let .partial(data): delivered.append(data)
            case let .matched(index, data):
                delivered.append(data)
                matched = index
            }
        }
        if matched == nil { delivered.append(matcher.finish()) }
        return (delivered, matched)
    }
}
