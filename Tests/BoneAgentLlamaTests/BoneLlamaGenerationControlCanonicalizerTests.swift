import BoneAgentKit
import XCTest
@testable import BoneAgentLlama

final class BoneLlamaGenerationControlCanonicalizerTests: XCTestCase {
    func testCanonicalDataAndDigestAreDeterministic() throws {
        let first = try BoneLlamaGenerationControl(
            stopTokenIDs: [2, 3, 2],
            stopStrings: ["<eog>", "停止", "<eog>"],
            constraint: .enumChoice(["yes", "no"])
        )
        let second = try BoneLlamaGenerationControl(
            stopTokenIDs: [2, 3],
            stopStrings: ["<eog>", "停止"],
            constraint: .enumChoice(["yes", "no"])
        )

        XCTAssertEqual(
            try BoneLlamaGenerationControlCanonicalizer.canonicalData(first),
            try BoneLlamaGenerationControlCanonicalizer.canonicalData(second)
        )
        XCTAssertEqual(
            try BoneLlamaGenerationControlCanonicalizer.digest(first),
            try BoneLlamaGenerationControlCanonicalizer.digest(second)
        )
    }

    func testEveryControlDimensionChangesDigest() throws {
        let base = try BoneLlamaGenerationControl(
            stopTokenIDs: [2],
            stopStrings: ["<eog>"],
            constraint: .enumChoice(["yes", "no"])
        )
        let variants = [
            try BoneLlamaGenerationControl(stopTokenIDs: [3], stopStrings: ["<eog>"], constraint: .enumChoice(["yes", "no"])),
            try BoneLlamaGenerationControl(stopTokenIDs: [2], stopStrings: ["<stop>"], constraint: .enumChoice(["yes", "no"])),
            try BoneLlamaGenerationControl(stopTokenIDs: [2], stopStrings: ["<eog>"], constraint: .enumChoice(["no", "yes"])),
            try BoneLlamaGenerationControl(stopTokenIDs: [2], stopStrings: ["<eog>"], constraint: .jsonSchema(.boolean)),
        ]
        let baseDigest = try BoneLlamaGenerationControlCanonicalizer.digest(base)

        for variant in variants {
            XCTAssertNotEqual(baseDigest, try BoneLlamaGenerationControlCanonicalizer.digest(variant))
        }
    }

    func testCanonicalDataDoesNotContainStopStringPlaintext() throws {
        let canary = "private-stop-canary"
        let control = try BoneLlamaGenerationControl(stopStrings: [canary])
        let data = try BoneLlamaGenerationControlCanonicalizer.canonicalData(control)

        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(canary))
        XCTAssertEqual(try BoneLlamaGenerationControlCanonicalizer.digest(control).count, 64)
    }

    func testSchemaDictionaryOrderDoesNotChangeControlDigest() throws {
        let first = try BoneLlamaGenerationControl(constraint: .jsonSchema(.object(
            properties: ["b": .boolean, "a": .integer(minimum: nil, maximum: nil)],
            required: ["b", "a"],
            additionalProperties: false
        )))
        let second = try BoneLlamaGenerationControl(constraint: .jsonSchema(.object(
            properties: ["a": .integer(minimum: nil, maximum: nil), "b": .boolean],
            required: ["a", "b"],
            additionalProperties: false
        )))

        XCTAssertEqual(
            try BoneLlamaGenerationControlCanonicalizer.digest(first),
            try BoneLlamaGenerationControlCanonicalizer.digest(second)
        )
    }
}
