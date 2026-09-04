import BoneAgentKit
import XCTest
@testable import BoneAgentLlama

final class BoneLlamaGBNFSchemaCompilerTests: XCTestCase {
    func testCompilesSupportedSchemaCasesDeterministically() throws {
        let schema = BoneToolSchema.object(
            properties: [
                "name": .string(enumValues: [], minimumLength: nil, maximumLength: nil),
                "scores": .array(
                    items: .number(minimum: nil, maximum: nil),
                    minimumItems: nil,
                    maximumItems: nil
                ),
                "active": .boolean,
                "count": .integer(minimum: nil, maximum: nil),
            ],
            required: ["scores", "count", "name", "active"],
            additionalProperties: false
        )
        let compiler = BoneLlamaGBNFCompiler()

        let first = try compiler.compile(.jsonSchema(schema))
        let second = try compiler.compile(.jsonSchema(schema))

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.source.hasPrefix("root ::= node-0\n"))
        XCTAssertTrue(first.source.contains(#"\"active\""#))
        XCTAssertTrue(first.source.contains(#"\"count\""#))
        XCTAssertTrue(first.source.contains(#"\"name\""#))
        XCTAssertTrue(first.source.contains(#"\"scores\""#))
        XCTAssertLessThan(
            first.source.range(of: #"\"active\""#)!.lowerBound,
            first.source.range(of: #"\"scores\""#)!.lowerBound
        )
    }

    func testCompilesStringEnumAndTaggedUnion() throws {
        let schema = BoneToolSchema.taggedUnion(
            discriminator: "kind",
            variants: [
                .object(
                    properties: [
                        "kind": .string(enumValues: ["b"], minimumLength: nil, maximumLength: nil),
                        "value": .number(minimum: nil, maximum: nil),
                    ],
                    required: ["kind", "value"],
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

        let compiled = try BoneLlamaGBNFCompiler().compile(.jsonSchema(schema))

        XCTAssertTrue(compiled.source.contains(" | "))
        XCTAssertLessThan(
            compiled.source.range(of: #"\"a\""#)!.lowerBound,
            compiled.source.range(of: #"\"b\""#)!.lowerBound
        )
    }

    func testRejectsUnsupportedSchemaDialectBeforeGrammar() {
        let unsupported: [BoneToolSchema] = [
            .object(properties: ["optional": .boolean], required: [], additionalProperties: false),
            .object(properties: ["value": .boolean], required: ["value"], additionalProperties: true),
            .string(enumValues: [], minimumLength: 1, maximumLength: nil),
            .array(items: .boolean, minimumItems: 1, maximumItems: nil),
            .integer(minimum: 0, maximum: nil),
            .number(minimum: nil, maximum: 1),
        ]

        for schema in unsupported {
            XCTAssertThrowsError(try BoneLlamaGBNFCompiler().compile(.jsonSchema(schema))) { error in
                XCTAssertEqual(error as? BoneLlamaConstraintCompilerError, .unsupportedSchema)
            }
        }
    }

    func testEnforcesRuleAndExpandedNodeBudgetsDuringTraversal() {
        let schema = BoneToolSchema.object(
            properties: ["a": .boolean, "b": .boolean],
            required: ["a", "b"],
            additionalProperties: false
        )
        let compiler = BoneLlamaGBNFCompiler(limits: .init(
            maximumGrammarByteCount: 1_024,
            maximumRuleCount: 2,
            maximumExpandedNodeCount: 2,
            maximumEnumTerminalByteCount: 1_024
        ))

        XCTAssertThrowsError(try compiler.compile(.jsonSchema(schema))) { error in
            XCTAssertEqual(error as? BoneLlamaConstraintCompilerError, .resourceLimitExceeded)
        }
    }
}
