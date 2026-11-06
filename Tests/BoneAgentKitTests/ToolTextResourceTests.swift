import Foundation
import XCTest
import BoneAgentKit

final class ToolTextResourceTests: XCTestCase {
    private typealias Reference = BoneToolTextResourceReference
    private typealias Preview = BoneToolTextResourcePreview
    private typealias Request = BoneToolTextResourceReadRequest
    private typealias Page = BoneToolTextResourcePage
    private typealias Snapshot = BoneToolTextResourceSnapshot
    private typealias ResourceError = BoneToolTextResourceError

    func testReferenceAcceptsASCIITokensAtBothLengthBoundaries() throws {
        for token in ["a", "Z", "0", "_", "-", "Az09_-", String(repeating: "x", count: 128)] {
            let reference = try Reference(id: token, version: token, utf8ByteCount: 0)
            XCTAssertEqual(reference.id, token)
            XCTAssertEqual(reference.version, token)
            XCTAssertEqual(reference.utf8ByteCount, 0)
            try assertRoundTrip(reference)
        }
    }

    func testReferenceRejectsPathsURLsWhitespaceUnicodeAndInvalidLengthsInInitAndDecode() throws {
        let invalid = ["", String(repeating: "x", count: 129), ".", "..", "a.b", "/private/body",
            "a/b", "a\\b", "https://example.invalid/body", "file:///private/body", "a b", "\t", "a\n",
            "中文", "é", "e\u{301}", "🙂", "Ａ", "a\u{0}"]
        for token in invalid {
            assertResourceError(.invalidReference) { try Reference(id: token, version: "v1", utf8ByteCount: 1) }
            assertResourceError(.invalidReference) { try Reference(id: "id", version: token, utf8ByteCount: 1) }
            for key in ["id", "version"] {
                var object = try jsonObject(Reference(id: "id", version: "v1", utf8ByteCount: 1))
                object[key] = token
                assertResourceError(.invalidReference) { try decode(Reference.self, object: object) }
            }
        }
        for count in [-1, Int.min] {
            assertResourceError(.invalidReference) { try Reference(id: "id", version: "v1", utf8ByteCount: count) }
            assertResourceError(.invalidReference) {
                try decode(Reference.self, object: ["id": "id", "version": "v1", "utf8ByteCount": count])
            }
        }
    }

    func testPreviewBoundsAndCompletenessUseUTF8Bytes() throws {
        XCTAssertEqual(Preview.maximumTextBytes, 4_096)
        let reference = try makeReference(4_097)
        for count in [0, 1, 4_096] {
            let preview = try Preview(reference: reference, text: String(repeating: "x", count: count))
            XCTAssertTrue(preview.isTruncated)
            XCTAssertEqual(preview.nextOffset, count)
        }
        let full = try Preview(reference: makeReference(3), text: "中")
        XCTAssertFalse(full.isTruncated)
        XCTAssertNil(full.nextOffset)
        assertResourceError(.invalidPreview) { try Preview(reference: makeReference(2), text: "中") }
        assertResourceError(.invalidPreview) {
            try Preview(reference: reference, text: String(repeating: "x", count: 4_097))
        }
        assertResourceError(.invalidPreview) {
            try Preview(reference: makeReference(8_192), text: String(repeating: "🙂", count: 1_025))
        }
    }

    func testPreviewDecoderRejectsFalseCompletenessAndForgedContinuation() throws {
        let partial = try Preview(reference: makeReference(8), text: "中")
        let complete = try Preview(reference: makeReference(3), text: "中")
        let mutations: [(Preview, String, Any)] = [
            (partial, "isTruncated", false), (partial, "nextOffset", NSNull()),
            (partial, "nextOffset", 0), (partial, "nextOffset", 4), (partial, "nextOffset", 8),
            (partial, "nextOffset", Int.max), (partial, "nextOffset", -1),
            (complete, "isTruncated", true), (complete, "nextOffset", 3),
            (partial, "text", String(repeating: "x", count: 4_097)),
        ]
        for (preview, key, value) in mutations {
            var object = try jsonObject(preview)
            object[key] = value
            assertResourceError(.invalidPreview) { try decode(Preview.self, object: object) }
        }
    }

    func testReadRequestChecksOffsetAndPageSizeInInitAndDecode() throws {
        XCTAssertEqual(Request.minimumPageBytes, 4)
        XCTAssertEqual(Request.maximumPageBytes, 65_536)
        let reference = try makeReference(9)
        let defaults = try Request(reference: reference)
        XCTAssertEqual(defaults.offset, 0)
        XCTAssertEqual(defaults.maximumBytes, 4_096)
        for offset in [0, 1, 9] {
            for limit in [4, 5, 7, 65_536] {
                try assertRoundTrip(Request(reference: reference, offset: offset, maximumBytes: limit))
            }
        }
        let invalid: [(Int, Int)] = [(-1, 4), (Int.min, 4), (10, 4), (Int.max, 4),
            (0, Int.min), (0, -1), (0, 0), (0, 3), (0, 65_537), (0, Int.max)]
        for (offset, limit) in invalid {
            assertResourceError(.invalidReadRequest) {
                try Request(reference: reference, offset: offset, maximumBytes: limit)
            }
            var object = try jsonObject(defaults)
            object["offset"] = offset
            object["maximumBytes"] = limit
            assertResourceError(.invalidReadRequest) { try decode(Request.self, object: object) }
        }
    }

    func testPageAllowsEmptyOnlyAtEOFAndRequiresNonEOFProgress() throws {
        let reference = try makeReference(8)
        let first = try Page(reference: reference, offset: 0, text: "a")
        XCTAssertEqual(first.nextOffset, 1)
        let last = try Page(reference: reference, offset: 7, text: "z")
        XCTAssertNil(last.nextOffset)
        let eof = try Page(reference: reference, offset: 8, text: "")
        XCTAssertNil(eof.nextOffset)
        let empty = try Page(reference: makeReference(0), offset: 0, text: "")
        XCTAssertNil(empty.nextOffset)
        for (offset, text) in [(-1, "a"), (Int.min, "a"), (9, ""), (0, ""), (7, ""), (8, "a"), (7, "ab")] {
            assertResourceError(.invalidPage) { try Page(reference: reference, offset: offset, text: text) }
        }
    }

    func testPageMaximumUsesByteCountAndDecoderRevalidatesBounds() throws {
        let reference = try makeReference(70_000)
        let maxPage = try Page(reference: reference, offset: 0, text: String(repeating: "x", count: 65_536))
        XCTAssertEqual(maxPage.nextOffset, 65_536)
        let emojiPage = try Page(reference: reference, offset: 0, text: String(repeating: "🙂", count: 16_384))
        XCTAssertEqual(emojiPage.text.utf8.count, 65_536)
        assertResourceError(.invalidPage) {
            try Page(reference: reference, offset: 0, text: maxPage.text + "x")
        }
        assertResourceError(.invalidPage) {
            try Page(reference: reference, offset: 0, text: emojiPage.text + "🙂")
        }
        let valid = try Page(reference: makeReference(8), offset: 0, text: "abcd")
        for (key, value): (String, Any) in [("offset", -1), ("offset", 9), ("text", ""), ("text", "123456789")] {
            var object = try jsonObject(valid)
            object[key] = value
            assertResourceError(.invalidPage) { try decode(Page.self, object: object) }
        }
    }

    func testPageDecoderRejectsSkippedRepeatedBackwardAndFalseFinalOffsets() throws {
        let partial = try Page(reference: makeReference(10), offset: 2, text: "abcd")
        for next: Any in [NSNull(), -1, 0, 2, 5, 7, 10, Int.max] {
            var object = try jsonObject(partial)
            object["nextOffset"] = next
            assertResourceError(.invalidPage) { try decode(Page.self, object: object) }
        }
        let complete = try Page(reference: makeReference(6), offset: 2, text: "abcd")
        var object = try jsonObject(complete)
        object["nextOffset"] = 6
        assertResourceError(.invalidPage) { try decode(Page.self, object: object) }
    }

    func testIntMaxByteCountsAndOffsetsDoNotOverflow() throws {
        let reference = try makeReference(Int.max)
        try assertRoundTrip(reference)
        try assertRoundTrip(Request(reference: reference, offset: Int.max, maximumBytes: 65_536))
        let beforeEnd = try Page(reference: reference, offset: Int.max - 2, text: "a")
        XCTAssertEqual(beforeEnd.nextOffset, Int.max - 1)
        try assertRoundTrip(beforeEnd)
        let last = try Page(reference: reference, offset: Int.max - 1, text: "b")
        XCTAssertNil(last.nextOffset)
        try assertRoundTrip(last)
        let eof = try Page(reference: reference, offset: Int.max, text: "")
        XCTAssertNil(eof.nextOffset)
        try assertRoundTrip(eof)
        assertResourceError(.invalidPage) { try Page(reference: reference, offset: Int.max, text: "a") }
        assertResourceError(.invalidPage) { try Page(reference: reference, offset: Int.max - 1, text: "ab") }
        let preview = try Preview(reference: reference, text: "🙂")
        XCTAssertTrue(preview.isTruncated)
        XCTAssertEqual(preview.nextOffset, 4)
        try assertRoundTrip(preview)
    }

    func testAllDTOsRequireTheirEncodedFieldsIncludingNullContinuation() throws {
        let reference = try makeReference(4)
        try assertRequiredFields(reference, keys: ["id", "version", "utf8ByteCount"])
        try assertRequiredFields(Request(reference: reference), keys: ["reference", "offset", "maximumBytes"])
        for text in ["a", "abcd"] {
            try assertRequiredFields(Preview(reference: reference, text: text),
                keys: ["reference", "text", "isTruncated", "nextOffset"])
            try assertRequiredFields(Page(reference: reference, offset: 0, text: text),
                keys: ["reference", "offset", "text", "nextOffset"])
        }
    }

    func testPreviewRequestAndPageJSONRoundTripsPreserveOriginalUTF8() throws {
        let text = "中文👩‍💻e\u{301}\u{0}\n"
        let snapshot = try Snapshot(id: "source_1", version: "v-2", text: text)
        for limit in [0, 4, 7, 4_096] {
            let preview = try snapshot.preview(maximumBytes: limit)
            let decoded = try JSONDecoder().decode(Preview.self, from: JSONEncoder().encode(preview))
            XCTAssertEqual(decoded, preview)
            XCTAssertEqual(Data(decoded.text.utf8), Data(preview.text.utf8))
        }
        for offset in [0, snapshot.reference.utf8ByteCount] {
            let request = try Request(reference: snapshot.reference, offset: offset, maximumBytes: 7)
            try assertRoundTrip(request)
            let page = try snapshot.page(for: request)
            let decoded = try JSONDecoder().decode(Page.self, from: JSONEncoder().encode(page))
            XCTAssertEqual(decoded, page)
            XCTAssertEqual(Data(decoded.text.utf8), Data(page.text.utf8))
        }
    }

    func testSnapshotPreviewIsExactBoundedPrefixWithoutSemanticSummary() throws {
        let text = "中🙂e\u{301}原文\n" + String(repeating: "do not summarize ", count: 300)
        let bytes = Data(text.utf8)
        let snapshot = try Snapshot(id: "original", version: "v1", text: text)
        XCTAssertEqual(snapshot.reference.utf8ByteCount, bytes.count)
        XCTAssertLessThanOrEqual(try snapshot.preview().text.utf8.count, 1_024)
        for limit in [0, 1, 2, 3, 4, 5, 7, 4_095, 4_096] {
            let preview = try snapshot.preview(maximumBytes: limit)
            let actual = Data(preview.text.utf8)
            XCTAssertLessThanOrEqual(actual.count, limit)
            XCTAssertEqual(actual, Data(bytes.prefix(actual.count)))
            XCTAssertTrue(preview.isTruncated)
            XCTAssertEqual(preview.nextOffset, actual.count)
            XCTAssertLessThan(limit - actual.count, 4)
        }
        XCTAssertEqual(try snapshot.preview(maximumBytes: 7).text, "中🙂")
        for limit in [Int.min, -1, 4_097, Int.max] {
            assertResourceError(.invalidPreview) { try snapshot.preview(maximumBytes: limit) }
        }
    }

    func testSnapshotSequentialPagesReconstructExactMultilingualAndControlBytes() throws {
        let texts = ["", "ASCII\r\n\t\u{0}", "中文原文", "🙂🚀", "👩‍💻👨‍👩‍👧‍👦",
            "abce\u{301}é\u{301}", "A中🙂e\u{301}👩‍💻\nZ"]
        for text in texts {
            let snapshot = try Snapshot(id: "source", version: "v1", text: text)
            for limit in [4, 5, 7, 65_536] {
                let recovered = try readRemainder(snapshot, offset: 0, maximumBytes: limit)
                XCTAssertEqual(recovered, Data(text.utf8))
                let eof = try snapshot.page(for: Request(reference: snapshot.reference,
                    offset: snapshot.reference.utf8ByteCount, maximumBytes: limit))
                XCTAssertEqual(eof.text, "")
                XCTAssertNil(eof.nextOffset)
            }
        }
    }

    func testSnapshotPreservesBOMScalarsAtResourceAndNonzeroPageStarts() throws {
        for text in ["\u{FEFF}", "\u{FEFF}Z", "abcd\u{FEFF}Z", "abcd\u{FEFF}🙂Z", "ab\u{FEFF}\u{FEFF}end"] {
            let snapshot = try Snapshot(id: "bom", version: "v1", text: text)
            let fullPreview = try snapshot.preview()
            XCTAssertEqual(Data(fullPreview.text.utf8), Data(text.utf8))
            XCTAssertFalse(fullPreview.isTruncated)
            for limit in [4, 5, 7] {
                XCTAssertEqual(try readRemainder(snapshot, offset: 0, maximumBytes: limit), Data(text.utf8))
            }
        }
    }

    func testSnapshotMaySplitGraphemeSequencesButNeverRepairsOrNormalizesThem() throws {
        let combining = try Snapshot(id: "combining", version: "v1", text: "abce\u{301}")
        let first = try combining.page(for: Request(reference: combining.reference, maximumBytes: 4))
        let second = try combining.page(for: Request(reference: combining.reference, offset: 4, maximumBytes: 4))
        XCTAssertEqual(Data(first.text.utf8), Data("abce".utf8))
        XCTAssertEqual(Data(second.text.utf8), Data("\u{301}".utf8))
        XCTAssertEqual(Data((first.text + second.text).utf8), Data("abce\u{301}".utf8))
        XCTAssertNotEqual(Data((first.text + second.text).utf8), Data("abcé".utf8))

        let zwj = try Snapshot(id: "zwj", version: "v1", text: "👩‍💻")
        let woman = try zwj.page(for: Request(reference: zwj.reference, maximumBytes: 4))
        let joiner = try zwj.page(for: Request(reference: zwj.reference, offset: 4, maximumBytes: 4))
        let laptop = try zwj.page(for: Request(reference: zwj.reference, offset: 7, maximumBytes: 4))
        XCTAssertEqual(Data(woman.text.utf8), Data("👩".utf8))
        XCTAssertEqual(Data(joiner.text.utf8), Data("\u{200D}".utf8))
        XCTAssertEqual(Data(laptop.text.utf8), Data("💻".utf8))
        XCTAssertEqual(Data((woman.text + joiner.text + laptop.text).utf8), Data("👩‍💻".utf8))
    }

    func testSnapshotRejectsOffsetsInsideUTF8Scalars() throws {
        let text = "A中🙂e\u{301}👩‍💻"
        let bytes = Array(text.utf8)
        let snapshot = try Snapshot(id: "source", version: "v1", text: text)
        for offset in bytes.indices {
            let request = try Request(reference: snapshot.reference, offset: offset, maximumBytes: 4)
            if bytes[offset] & 0xC0 == 0x80 {
                assertResourceError(.invalidOffset) { try snapshot.page(for: request) }
            } else {
                let page = try snapshot.page(for: request)
                XCTAssertEqual(Data(page.text.utf8), Data(bytes[offset..<(offset + page.text.utf8.count)]))
                XCTAssertFalse(page.text.isEmpty)
            }
        }
    }

    func testSnapshotRejectsDifferentIDVersionOrClaimedLength() throws {
        let snapshot = try Snapshot(id: "source", version: "v1", text: "abcd")
        let references = [try Reference(id: "other", version: "v1", utf8ByteCount: 4),
            try Reference(id: "source", version: "v2", utf8ByteCount: 4),
            try Reference(id: "source", version: "v1", utf8ByteCount: 3),
            try Reference(id: "source", version: "v1", utf8ByteCount: 5),
            try Reference(id: "source", version: "v1", utf8ByteCount: Int.max)]
        for reference in references {
            assertResourceError(.referenceMismatch) {
                try snapshot.page(for: Request(reference: reference, maximumBytes: 4))
            }
        }
    }

    func testPreviewPlusContinuationReconstructsOriginalBytesIncludingZeroPreview() throws {
        let text = "中🙂e\u{301}👩‍💻原文\r\n" + String(repeating: "tail ", count: 900)
        let snapshot = try Snapshot(id: "source", version: "v1", text: text)
        for previewLimit in [0, 1, 2, 3, 4, 5, 7, 4_096] {
            let preview = try snapshot.preview(maximumBytes: previewLimit)
            let offset = try XCTUnwrap(preview.nextOffset)
            for pageLimit in [4, 5, 7] {
                var recovered = Data(preview.text.utf8)
                recovered.append(try readRemainder(snapshot, offset: offset, maximumBytes: pageLimit))
                XCTAssertEqual(recovered, Data(text.utf8))
            }
        }
        let empty = try Snapshot(id: "empty", version: "v1", text: "").preview(maximumBytes: 0)
        XCTAssertEqual(empty.text, "")
        XCTAssertFalse(empty.isTruncated)
        XCTAssertNil(empty.nextOffset)
    }

    func testWorstCaseEscapedPageWithMaximumReferenceFitsToolResultLimit() throws {
        let reference = try Reference(id: String(repeating: "i", count: 128),
            version: String(repeating: "v", count: 128), utf8ByteCount: Int.max)
        let text = String(repeating: "\u{0}", count: Request.maximumPageBytes)
        let page = try Page(reference: reference, offset: Int.max - Request.maximumPageBytes - 1, text: text)
        let encoded = try JSONEncoder().encode(page)
        XCTAssertGreaterThan(encoded.count, 6 * Request.maximumPageBytes)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\\u0000"))
        XCTAssertLessThan(encoded.count, BoneInferenceToolResult.maximumResultByteCount)
        let decoded = try JSONDecoder().decode(Page.self, from: encoded)
        XCTAssertEqual(Data(decoded.text.utf8), Data(text.utf8))
        XCTAssertEqual(decoded.nextOffset, Int.max - 1)
        let result = try BoneInferenceToolResult(callID: "call", toolID: "resource.readText",
            content: .json(encoded), isError: false, ordinal: 0)
        XCTAssertEqual(result.legacyResult, encoded)
    }

    private func makeReference(_ count: Int) throws -> Reference {
        try Reference(id: "resource", version: "v1", utf8ByteCount: count)
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private func decode<T: Decodable>(_ type: T.Type, object: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }

    private func assertRoundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let decoded = try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value, file: file, line: line)
    }

    private func assertRequiredFields<T: Codable>(_ value: T, keys: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        let original = try jsonObject(value)
        for key in keys {
            var object = original
            object.removeValue(forKey: key)
            XCTAssertThrowsError(try decode(T.self, object: object), file: file, line: line) { error in
                guard case DecodingError.keyNotFound(let missing, _) = error else {
                    return XCTFail("Expected missing required field", file: file, line: line)
                }
                XCTAssertEqual(missing.stringValue, key, file: file, line: line)
            }
        }
    }

    private func assertResourceError<T>(_ expected: ResourceError, file: StaticString = #filePath, line: UInt = #line,
        _ operation: () throws -> T) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? ResourceError, expected, file: file, line: line)
        }
    }

    private func readRemainder(_ snapshot: Snapshot, offset: Int, maximumBytes: Int) throws -> Data {
        var offset = offset
        var bytes = Data()
        var pieces: [String] = []
        // A byte-based bound makes a regression to repeated pages fail instead of looping forever.
        for _ in 0...snapshot.reference.utf8ByteCount {
            let request = try Request(reference: snapshot.reference, offset: offset, maximumBytes: maximumBytes)
            let page = try snapshot.page(for: request)
            XCTAssertEqual(page.reference, snapshot.reference)
            XCTAssertEqual(page.offset, offset)
            XCTAssertLessThanOrEqual(page.text.utf8.count, maximumBytes)
            bytes.append(contentsOf: page.text.utf8)
            pieces.append(page.text)
            guard let next = page.nextOffset else {
                XCTAssertEqual(offset + page.text.utf8.count, snapshot.reference.utf8ByteCount)
                XCTAssertEqual(Data(pieces.joined().utf8), bytes)
                return bytes
            }
            XCTAssertGreaterThan(next, offset)
            XCTAssertEqual(next, offset + page.text.utf8.count)
            if next <= offset { break }
            offset = next
        }
        XCTFail("Pagination did not reach EOF")
        return bytes
    }
}

extension ToolTextResourceTests {
    func testReaderWithVoidContextCallsHostForEveryRequestWithoutCaching() async throws {
        let snapshot = try Snapshot(id: "source", version: "v1", text: "abcdefgh")
        let trace = Trace()
        let reader = BoneToolTextResourceReader<Void> { request, _ in
            await trace.record("read:\(request.offset)")
            return try snapshot.page(for: request)
        }
        let firstRequest = try Request(reference: snapshot.reference, maximumBytes: 4)
        let first = try await reader.read(firstRequest, context: ())
        let repeated = try await reader.read(firstRequest, context: ())
        XCTAssertEqual(first, repeated)
        let next = try Request(reference: snapshot.reference, offset: XCTUnwrap(first.nextOffset), maximumBytes: 4)
        let last = try await reader.read(next, context: ())
        XCTAssertEqual(first.text + last.text, "abcdefgh")
        let events = await trace.events()
        XCTAssertEqual(events, ["read:0", "read:0", "read:4"])
    }

    func testReaderForwardsTrustedCustomContextAndHostDeniesCrossScopeBeforeReading() async throws {
        let context = ResourceContext(tenant: "owner", principal: "alice")
        let snapshot = try Snapshot(id: "source", version: "v1", text: "abcdefgh")
        let host = Host(snapshot: snapshot, allowedContext: context)
        let reader = BoneToolTextResourceReader<ResourceContext> { try await host.read($0, context: $1) }
        let request = try Request(reference: snapshot.reference, maximumBytes: 4)
        let page = try await reader.read(request, context: context)
        XCTAssertEqual(page.text, "abcd")
        let otherContexts = [ResourceContext(tenant: "other", principal: "alice"),
            ResourceContext(tenant: "owner", principal: "bob")]
        for other in otherContexts {
            do {
                _ = try await reader.read(request, context: other)
                XCTFail("Cross-scope access must be refused by Host")
            } catch { XCTAssertEqual(error as? ResourceError, .accessDenied) }
        }
        let report = await host.report()
        XCTAssertEqual(report.contexts, [context] + otherContexts)
        XCTAssertEqual(report.requests, [request, request, request])
        XCTAssertEqual(report.pagesRead, 1)
    }

    func testHostRevocationExpiryAndUnavailabilityBlockSecondPageWithoutCachedFallback() async throws {
        let context = ResourceContext(tenant: "owner", principal: "alice")
        for failure: ResourceError in [.accessDenied, .expired, .unavailable] {
            let snapshot = try Snapshot(id: "source", version: "v1", text: "abcdefgh")
            let host = Host(snapshot: snapshot, allowedContext: context)
            let reader = BoneToolTextResourceReader<ResourceContext> { try await host.read($0, context: $1) }
            let initial = try Request(reference: snapshot.reference, maximumBytes: 4)
            let first = try await reader.read(initial, context: context)
            let second = try Request(reference: snapshot.reference, offset: XCTUnwrap(first.nextOffset), maximumBytes: 4)
            await host.deny(with: failure)
            // Both a new page and a previously read page must be checked again by Host.
            for request in [second, initial] {
                do {
                    _ = try await reader.read(request, context: context)
                    XCTFail("Expected current Host refusal")
                } catch { XCTAssertEqual(error as? ResourceError, failure) }
            }
            let report = await host.report()
            XCTAssertEqual(report.requests, [initial, second, initial])
            XCTAssertEqual(report.pagesRead, 1)
        }
    }

    func testOldReferenceCannotFallBackToReplacementVersion() async throws {
        let context = ResourceContext(tenant: "owner", principal: "alice")
        let old = try Snapshot(id: "source", version: "v1", text: "abcdefgh")
        let replacement = try Snapshot(id: "source", version: "v2", text: "ABCDEFGH")
        let host = Host(snapshot: old, allowedContext: context)
        let reader = BoneToolTextResourceReader<ResourceContext> { try await host.read($0, context: $1) }
        let firstRequest = try Request(reference: old.reference, maximumBytes: 4)
        let first = try await reader.read(firstRequest, context: context)
        await host.replace(with: replacement)
        let stale = try Request(reference: old.reference, offset: XCTUnwrap(first.nextOffset), maximumBytes: 4)
        do {
            _ = try await reader.read(stale, context: context)
            XCTFail("The reader must not retry with a newer reference")
        } catch { XCTAssertEqual(error as? ResourceError, .referenceMismatch) }
        let report = await host.report()
        XCTAssertEqual(report.requests, [firstRequest, stale])
        XCTAssertEqual(report.pagesRead, 1)
        let current = try await reader.read(Request(reference: replacement.reference, offset: 4, maximumBytes: 4), context: context)
        XCTAssertEqual(current.text, "EFGH")
        XCTAssertEqual(current.reference, replacement.reference)
    }

    func testReaderRejectsReturnedIDVersionLengthOffsetAndRequestLimitMismatches() async throws {
        let reference = try makeReference(12)
        let request = try Request(reference: reference, offset: 4, maximumBytes: 4)
        let wrongReferences = [try Reference(id: "other", version: reference.version, utf8ByteCount: 12),
            try Reference(id: reference.id, version: "v2", utf8ByteCount: 12),
            try Reference(id: reference.id, version: reference.version, utf8ByteCount: 11),
            try Reference(id: reference.id, version: reference.version, utf8ByteCount: 13)]
        var invalid: [(Page, ResourceError)] = try wrongReferences.map {
            (try Page(reference: $0, offset: 4, text: "abcd"), .referenceMismatch)
        }
        invalid.append((try Page(reference: reference, offset: 5, text: "abcd"), .invalidOffset))
        invalid.append((try Page(reference: reference, offset: 0, text: "abcd"), .invalidOffset))
        invalid.append((try Page(reference: reference, offset: 4, text: "abcde"), .pageExceedsRequest))
        for (page, expected) in invalid {
            let trace = Trace()
            let reader = BoneToolTextResourceReader<Void> { _, _ in
                await trace.record("read")
                return page
            }
            do { _ = try await reader.read(request, context: ()); XCTFail("Expected mechanical mismatch") }
            catch { XCTAssertEqual(error as? ResourceError, expected) }
            let events = await trace.events()
            XCTAssertEqual(events, ["read"])
        }
    }

    func testReaderPreservesMechanicallyValidHostPageWithoutRewritingText() async throws {
        let reference = try makeReference(4)
        let page = try Page(reference: reference, offset: 0, text: "e\u{301}\n")
        let reader = BoneToolTextResourceReader<Void> { _, _ in page }
        let result = try await reader.read(Request(reference: reference, maximumBytes: 4), context: ())
        XCTAssertEqual(Data(result.text.utf8), Data(page.text.utf8))
        XCTAssertNil(result.nextOffset)
        // No source bytes are supplied to Reader: this proves the mechanical contract, not provenance.
    }

    func testExternalErrorPreservesIdentityAndPrivateFieldsWithoutRetry() async throws {
        let original = PrivateHostError(body: "CANARY-private-host-body")
        let trace = Trace()
        let reader = BoneToolTextResourceReader<Void> { _, _ in
            await trace.record("read")
            throw original
        }
        let request = try Request(reference: makeReference(4), maximumBytes: 4)
        do {
            _ = try await reader.read(request, context: ())
            XCTFail("Expected the original Host error")
        } catch {
            let received = try XCTUnwrap(error as? PrivateHostError)
            XCTAssertTrue(received === original)
            XCTAssertEqual(received.body, original.body)
            XCTAssertTrue(String(describing: error).contains(original.body))
        }
        let events = await trace.events()
        XCTAssertEqual(events, ["read"])
    }

    func testCancellationBeforeReadNeverCallsHost() async throws {
        let trace = Trace()
        let snapshot = try Snapshot(id: "source", version: "v1", text: "abcd")
        let reader = BoneToolTextResourceReader<Void> { request, _ in
            await trace.record("unexpected read")
            return try snapshot.page(for: request)
        }
        let request = try Request(reference: snapshot.reference, maximumBytes: 4)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reader.read(request, context: ())
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let events = await trace.events()
        XCTAssertEqual(events, [])
    }

    func testCancellationWhileHostSuspendedDiscardsPageReturnedAfterCancellation() async throws {
        let gate = ReadGate()
        let trace = Trace()
        let snapshot = try Snapshot(id: "source", version: "v1", text: "abcd")
        let reader = BoneToolTextResourceReader<Void> { request, _ in
            await trace.record("read:start")
            await gate.suspend()
            let page = try snapshot.page(for: request)
            await trace.record("read:return")
            return page
        }
        let request = try Request(reference: snapshot.reference, maximumBytes: 4)
        let task = Task { try await reader.read(request, context: ()) }
        await gate.waitUntilSuspended()
        let suspendedEvents = await trace.events()
        XCTAssertEqual(suspendedEvents, ["read:start"])
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("A cancelled read must not return its page") }
        catch { XCTAssertTrue(error is CancellationError) }
        let events = await trace.events()
        XCTAssertEqual(events, ["read:start", "read:return"])
    }

    func testReadToolDefinitionHasValidSchemaAndPrivateLocalReadOnlySerialDefaults() throws {
        let definition = BoneToolTextResourceReadTool<ResourceContext>.definition
        XCTAssertEqual(try definition.validatedForModelExposure(), definition)
        XCTAssertEqual(definition.id, "resource.readText")
        XCTAssertEqual(definition.wireName, "resource_read_text")
        XCTAssertEqual(definition.schemaVersion, 1)
        // An absent execution policy is the SDK's serial default, not a parallel-safe declaration.
        XCTAssertNil(definition.executionPolicy)
        let impact = try definition.requiredImpact()
        XCTAssertEqual(impact.dataAccess, .userPrivate)
        XCTAssertEqual(impact.externalTransmission, .none)
        XCTAssertEqual(impact.stateChange, .none)
        XCTAssertEqual(impact.economic, .none)
        XCTAssertEqual(impact.userVisible, .none)
        XCTAssertEqual(impact.permissionChange, .none)
        XCTAssertTrue(impact.isLocalReadOnly)
        XCTAssertTrue(impact.requiresHostAuthorization)
        try assertRoundTrip(definition)
    }

    func testRegistryExecutesRealReadToolThroughJSONInputAndOutput() async throws {
        let context = ResourceContext(tenant: "owner", principal: "alice")
        let snapshot = try Snapshot(id: "source", version: "v1", text: "中🙂e\u{301}")
        let host = Host(snapshot: snapshot, allowedContext: context)
        let registry = try makeRegistry(host: host)
        XCTAssertEqual(registry.definitions, [BoneToolTextResourceReadTool<ResourceContext>.definition])
        XCTAssertNotNil(registry.tool(id: "resource.readText"))
        var offset = 0
        var bytes = Data()
        var requests: [Request] = []
        for _ in 0...snapshot.reference.utf8ByteCount {
            let request = try Request(reference: snapshot.reference, offset: offset, maximumBytes: 4)
            requests.append(request)
            let data = try await registry.execute(id: "resource.readText", input: JSONEncoder().encode(request), context: context)
            let page = try JSONDecoder().decode(Page.self, from: data)
            XCTAssertEqual(page, try snapshot.page(for: request))
            bytes.append(contentsOf: page.text.utf8)
            guard let next = page.nextOffset else { break }
            XCTAssertGreaterThan(next, offset)
            if next <= offset { break }
            offset = next
        }
        XCTAssertEqual(bytes, Data("中🙂e\u{301}".utf8))
        let report = await host.report()
        XCTAssertEqual(report.requests, requests)
        XCTAssertEqual(report.contexts, Array(repeating: context, count: requests.count))
        XCTAssertEqual(report.pagesRead, requests.count)
    }

    func testRegistryMalformedCodableParametersFailBeforeReadingClosure() async throws {
        let context = ResourceContext(tenant: "owner", principal: "alice")
        let snapshot = try Snapshot(id: "source", version: "v1", text: "abcd")
        let host = Host(snapshot: snapshot, allowedContext: context)
        let registry = try makeRegistry(host: host)
        let valid = try jsonObject(Request(reference: snapshot.reference, maximumBytes: 4))
        var inputs = [Data("{broken".utf8), Data("null".utf8), Data("[]".utf8)]
        for key in ["reference", "offset", "maximumBytes"] {
            var object = valid
            object.removeValue(forKey: key)
            inputs.append(try JSONSerialization.data(withJSONObject: object))
        }
        for (key, value): (String, Any) in [("offset", -1), ("offset", 5), ("offset", "zero"),
            ("maximumBytes", 3), ("maximumBytes", 65_537), ("maximumBytes", NSNull())] {
            var object = valid
            object[key] = value
            inputs.append(try JSONSerialization.data(withJSONObject: object))
        }
        for (key, value): (String, Any) in [("id", "../private"), ("version", "v.1"), ("utf8ByteCount", -1)] {
            var object = valid
            var reference = try XCTUnwrap(object["reference"] as? [String: Any])
            reference[key] = value
            object["reference"] = reference
            inputs.append(try JSONSerialization.data(withJSONObject: object))
        }
        for input in inputs {
            do {
                _ = try await registry.execute(id: "resource.readText", input: input, context: context)
                XCTFail("Expected Codable argument rejection")
            } catch { XCTAssertEqual(error as? BoneAgentToolError, .invalidArguments(toolID: "resource.readText")) }
        }
        let report = await host.report()
        XCTAssertEqual(report.requests.count, 0)
        XCTAssertEqual(report.pagesRead, 0)
    }

    func testRegistryUsesTrustedContextEvenWhenModelAddsScopeFields() async throws {
        let owner = ResourceContext(tenant: "owner", principal: "alice")
        let other = ResourceContext(tenant: "other", principal: "bob")
        let snapshot = try Snapshot(id: "source", version: "v1", text: "abcd")
        let host = Host(snapshot: snapshot, allowedContext: owner)
        let registry = try makeRegistry(host: host)
        var object = try jsonObject(Request(reference: snapshot.reference, maximumBytes: 4))
        object["scope"] = owner.tenant
        object["context"] = ["tenant": owner.tenant, "principal": owner.principal]
        let input = try JSONSerialization.data(withJSONObject: object)
        // Registry does Codable decoding, not full schema validation; unknown keys cannot supply Context.
        do {
            _ = try await registry.execute(id: "resource.readText", input: input, context: other)
            XCTFail("Model-supplied scope must not replace trusted Context")
        } catch { XCTAssertEqual(error as? ResourceError, .accessDenied) }
        let denied = await host.report()
        XCTAssertEqual(denied.contexts, [other])
        XCTAssertEqual(denied.pagesRead, 0)
        let data = try await registry.execute(id: "resource.readText", input: input, context: owner)
        XCTAssertEqual(try JSONDecoder().decode(Page.self, from: data).text, "abcd")
        let accepted = await host.report()
        XCTAssertEqual(accepted.contexts, [other, owner])
        XCTAssertEqual(accepted.pagesRead, 1)
    }

    func testRegistryWrongContextTypeFailsBeforeHostCall() async throws {
        let context = ResourceContext(tenant: "owner", principal: "alice")
        let snapshot = try Snapshot(id: "source", version: "v1", text: "abcd")
        let host = Host(snapshot: snapshot, allowedContext: context)
        let registry = try makeRegistry(host: host)
        do {
            _ = try await registry.execute(id: "resource.readText",
                input: JSONEncoder().encode(Request(reference: snapshot.reference, maximumBytes: 4)),
                context: BoneAgentEmptyContext())
            XCTFail("Expected Context type rejection")
        } catch { XCTAssertEqual(error as? BoneAgentToolError, .invalidContext(toolID: "resource.readText")) }
        let report = await host.report()
        XCTAssertEqual(report.requests.count, 0)
        XCTAssertEqual(report.pagesRead, 0)
    }

    func testResourceErrorsAreFixedCategoriesWithoutPrivateText() throws {
        let secret = "CANARY-private-body-path"
        do {
            _ = try Reference(id: "/\(secret)", version: "v1", utf8ByteCount: 0)
            XCTFail("Expected invalid reference")
        } catch {
            XCTAssertEqual(error as? ResourceError, .invalidReference)
            XCTAssertFalse(String(describing: error).contains(secret))
            XCTAssertFalse(String(reflecting: error).contains(secret))
        }
        do {
            _ = try Preview(reference: makeReference(0), text: secret)
            XCTFail("Expected invalid preview")
        } catch {
            XCTAssertEqual(error as? ResourceError, .invalidPreview)
            XCTAssertFalse(String(describing: error).contains(secret))
            XCTAssertFalse(String(reflecting: error).contains(secret))
        }
        let categories: [(ResourceError, String)] = [(.invalidReference, "invalidReference"),
            (.invalidPreview, "invalidPreview"), (.invalidReadRequest, "invalidReadRequest"),
            (.invalidPage, "invalidPage"), (.referenceMismatch, "referenceMismatch"),
            (.invalidOffset, "invalidOffset"), (.pageExceedsRequest, "pageExceedsRequest"),
            (.accessDenied, "accessDenied"), (.unavailable, "unavailable"), (.expired, "expired")]
        for (error, name) in categories {
            XCTAssertEqual(String(describing: error), name)
            XCTAssertEqual(Mirror(reflecting: error).children.count, 0)
            XCTAssertFalse(String(reflecting: error).contains(secret))
        }
    }

    private func makeRegistry(host: Host) throws -> BoneAgentToolRegistry {
        let reader = BoneToolTextResourceReader<ResourceContext> { try await host.read($0, context: $1) }
        return try BoneAgentToolRegistry(tools: [BoneAnyAgentTool(BoneToolTextResourceReadTool(reader: reader))])
    }

    private struct ResourceContext: BoneAgentToolContext, Equatable {
        let tenant: String
        let principal: String
    }

    private struct HostReport: Sendable {
        let requests: [Request]
        let contexts: [ResourceContext]
        let pagesRead: Int
    }

    private actor Host {
        private var snapshot: Snapshot
        private let allowedContext: ResourceContext
        private var failure: ResourceError?
        private var requests: [Request] = []
        private var contexts: [ResourceContext] = []
        private var pagesRead = 0

        init(snapshot: Snapshot, allowedContext: ResourceContext) {
            self.snapshot = snapshot
            self.allowedContext = allowedContext
        }

        func read(_ request: Request, context: ResourceContext) throws -> Page {
            requests.append(request)
            contexts.append(context)
            guard context == allowedContext else { throw ResourceError.accessDenied }
            if let failure { throw failure }
            let page = try snapshot.page(for: request)
            pagesRead += 1
            return page
        }

        func deny(with error: ResourceError) { failure = error }
        func replace(with snapshot: Snapshot) { self.snapshot = snapshot }
        func report() -> HostReport { .init(requests: requests, contexts: contexts, pagesRead: pagesRead) }
    }

    private actor Trace {
        private var values: [String] = []
        func record(_ value: String) { values.append(value) }
        func events() -> [String] { values }
    }

    private final class PrivateHostError: Error, Sendable, CustomStringConvertible {
        let body: String
        init(body: String) { self.body = body }
        var description: String { "Host failure: \(body)" }
    }

    // Intentionally returns after cancellation so Reader's post-await check is exercised.
    private actor ReadGate {
        private var suspended: CheckedContinuation<Void, Never>?
        private var observer: CheckedContinuation<Void, Never>?

        func suspend() async {
            await withCheckedContinuation { continuation in
                suspended = continuation
                observer?.resume()
                observer = nil
            }
        }

        func waitUntilSuspended() async {
            if suspended != nil { return }
            await withCheckedContinuation { observer = $0 }
        }

        func release() {
            suspended?.resume()
            suspended = nil
        }
    }
}
