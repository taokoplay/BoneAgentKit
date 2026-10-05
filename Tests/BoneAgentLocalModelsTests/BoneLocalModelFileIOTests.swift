import Foundation
import XCTest
@testable import BoneAgentLocalModels

final class BoneLocalModelFileIOTests: XCTestCase {
    func testChunkedReadWritePreservesBytesAndEndsAtEOF() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let payload = Data((0..<131_079).map { UInt8($0 % 251) })
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        try BoneLocalModelFileIO.write(Data(), to: output)
        for offset in stride(from: 0, to: payload.count, by: 8_192) {
            try BoneLocalModelFileIO.write(payload.subdata(in: offset..<min(offset + 8_192, payload.count)), to: output)
        }
        try output.close()
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var actual = Data()
        while let data = try BoneLocalModelFileIO.read(upToCount: 4_096, from: input), !data.isEmpty {
            XCTAssertLessThanOrEqual(data.count, 4_096)
            actual.append(data)
        }
        XCTAssertEqual(actual, payload)
        XCTAssertTrue(try BoneLocalModelFileIO.read(upToCount: 4_096, from: input)?.isEmpty ?? true)
    }

    func testReadFailureThrowsInsteadOfBeingTreatedAsEOF() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("fixture".utf8).write(to: url)
        let input = try FileHandle(forReadingFrom: url)
        try input.close()
        XCTAssertThrowsError(try BoneLocalModelFileIO.read(upToCount: 4, from: input))
    }

    func testWriteFailureThrowsAndPreservesExistingBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("fixture".utf8)
        try original.write(to: url)
        let readOnly = try FileHandle(forReadingFrom: url)
        defer { try? readOnly.close() }
        XCTAssertThrowsError(try BoneLocalModelFileIO.write(Data("overwrite".utf8), to: readOnly))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
