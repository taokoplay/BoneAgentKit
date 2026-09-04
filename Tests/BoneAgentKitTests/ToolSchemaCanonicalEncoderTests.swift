import XCTest
@testable import BoneAgentKit

final class ToolSchemaCanonicalEncoderTests: XCTestCase {
    func testCanonicalizesUnorderedSchemaCollections() throws {
        let first = BoneToolSchema.taggedUnion(
            discriminator: "kind",
            variants: [
                .object(
                    properties: [
                        "value": .integer(minimum: 0, maximum: 9),
                        "kind": .string(enumValues: ["b"], minimumLength: nil, maximumLength: nil),
                    ],
                    required: ["value", "kind"],
                    additionalProperties: false
                ),
                .object(
                    properties: [
                        "kind": .string(enumValues: ["a"], minimumLength: nil, maximumLength: nil),
                        "flag": .boolean,
                    ],
                    required: ["kind", "flag"],
                    additionalProperties: false
                ),
            ]
        )
        let second = BoneToolSchema.taggedUnion(
            discriminator: "kind",
            variants: [
                .object(
                    properties: [
                        "flag": .boolean,
                        "kind": .string(enumValues: ["a"], minimumLength: nil, maximumLength: nil),
                    ],
                    required: ["flag", "kind"],
                    additionalProperties: false
                ),
                .object(
                    properties: [
                        "kind": .string(enumValues: ["b"], minimumLength: nil, maximumLength: nil),
                        "value": .integer(minimum: 0, maximum: 9),
                    ],
                    required: ["kind", "value"],
                    additionalProperties: false
                ),
            ]
        )

        XCTAssertEqual(
            try BoneToolSchemaCanonicalEncoder.encode(first),
            try BoneToolSchemaCanonicalEncoder.encode(second)
        )
        XCTAssertEqual(
            try BoneToolSchemaCanonicalEncoder.digest(first),
            try BoneToolSchemaCanonicalEncoder.digest(second)
        )
    }

    func testPreservesEnumChoiceOrder() throws {
        let first = BoneToolSchema.string(enumValues: ["yes", "no"], minimumLength: nil, maximumLength: nil)
        let second = BoneToolSchema.string(enumValues: ["no", "yes"], minimumLength: nil, maximumLength: nil)

        XCTAssertNotEqual(
            try BoneToolSchemaCanonicalEncoder.encode(first),
            try BoneToolSchemaCanonicalEncoder.encode(second)
        )
    }

    func testProducesVersionedExplicitCanonicalSnapshot() throws {
        let schema = BoneToolSchema.object(
            properties: [
                "z": .array(
                    items: .number(minimum: 1.5, maximum: 20),
                    minimumItems: 1,
                    maximumItems: 3
                ),
                "line\"\\雪": .taggedUnion(
                    discriminator: "种类",
                    variants: [
                        .object(
                            properties: [
                                "种类": .string(enumValues: ["🐟"], minimumLength: 1, maximumLength: 2),
                                "ok": .boolean,
                            ],
                            required: ["ok", "种类"],
                            additionalProperties: false
                        ),
                    ]
                ),
            ],
            required: ["z", "line\"\\雪"],
            additionalProperties: false
        )

        XCTAssertEqual(
            String(decoding: try BoneToolSchemaCanonicalEncoder.encode(schema), as: UTF8.self),
            #"{"formatVersion":1,"schema":{"type":"object","properties":[["line\"\\雪",{"type":"taggedUnion","discriminator":"种类","variants":[{"type":"object","properties":[["ok",{"type":"boolean"}],["种类",{"type":"string","enum":["🐟"],"minimumLength":1,"maximumLength":2}]],"required":["ok","种类"],"additionalProperties":false}]}],["z",{"type":"array","items":{"type":"number","minimum":1.5,"maximum":20.0},"minimumItems":1,"maximumItems":3}]],"required":["line\"\\雪","z"],"additionalProperties":false}}"#
        )
    }

    func testRejectsInvalidSchemaWithoutLeakingFieldNames() {
        let canary = "secret-field-canary"
        let schema = BoneToolSchema.object(
            properties: [canary: .boolean],
            required: [canary, canary],
            additionalProperties: false
        )

        XCTAssertThrowsError(try BoneToolSchemaCanonicalEncoder.encode(schema)) { error in
            XCTAssertEqual(error as? BoneToolSchemaError, .invalidSchema)
            XCTAssertFalse(String(describing: error).contains(canary))
        }
    }

    func testDigestIsLowercaseSHA256() throws {
        let digest = try BoneToolSchemaCanonicalEncoder.digest(.boolean)
        XCTAssertEqual(digest.count, 64)
        XCTAssertTrue(digest.allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) })
    }
}
