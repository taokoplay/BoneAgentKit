import BoneAgentKit
import XCTest
@testable import BoneAgentLlama

final class BoneLlamaConstraintSemanticCorpusTests: XCTestCase {
    func testSupportedCorpusCompilesAndEveryCanonicalSamplePassesValidator() throws {
        let corpus: [(BoneToolSchema, [String])] = [
            (.boolean, ["true", "false"]),
            (.integer(minimum: nil, maximum: nil), ["0", "-12", "900719925"]),
            (.number(minimum: nil, maximum: nil), ["0", "-1.25", "6.02e23"]),
            (.string(enumValues: [], minimumLength: nil, maximumLength: nil), [#""text""#, #""雪🐟""#, #""quote\"slash\\""#]),
            (.string(enumValues: ["red", "蓝"], minimumLength: nil, maximumLength: nil), [#""red""#, #""蓝""#]),
            (.array(items: .boolean, minimumItems: nil, maximumItems: nil), ["[]", "[true,false]"]),
            (
                .object(
                    properties: ["a": .boolean, "b": .integer(minimum: nil, maximum: nil)],
                    required: ["a", "b"],
                    additionalProperties: false
                ),
                [#"{"a":true,"b":2}"#]
            ),
            (
                .taggedUnion(
                    discriminator: "kind",
                    variants: [
                        .object(
                            properties: ["kind": .string(enumValues: ["a"], minimumLength: nil, maximumLength: nil), "value": .boolean],
                            required: ["kind", "value"],
                            additionalProperties: false
                        ),
                        .object(
                            properties: ["kind": .string(enumValues: ["b"], minimumLength: nil, maximumLength: nil), "count": .integer(minimum: nil, maximum: nil)],
                            required: ["kind", "count"],
                            additionalProperties: false
                        ),
                    ]
                ),
                [#"{"kind":"a","value":true}"#, #"{"count":1,"kind":"b"}"#]
            ),
        ]

        for (schema, samples) in corpus {
            XCTAssertNoThrow(try BoneLlamaGBNFCompiler().compile(.jsonSchema(schema)))
            for sample in samples {
                XCTAssertNoThrow(try BoneToolSchemaValidator.validate(arguments: Data(sample.utf8), against: schema))
            }
        }
    }

    func testValidatorRejectsRepresentativeValuesOutsideCompiledLanguageOrSchema() throws {
        let schema = BoneToolSchema.object(
            properties: ["a": .boolean, "b": .integer(minimum: nil, maximum: nil)],
            required: ["a", "b"],
            additionalProperties: false
        )
        _ = try BoneLlamaGBNFCompiler().compile(.jsonSchema(schema))

        for invalid in [
            #"{"a":true}"#,
            #"{"a":true,"b":1,"extra":0}"#,
            #"{"a":"true","b":1}"#,
            #"{"a":true,"b":1.5}"#,
            #"{"a":true,"b":01}"#,
        ] {
            XCTAssertThrowsError(
                try BoneToolSchemaValidator.validate(arguments: Data(invalid.utf8), against: schema)
            )
        }
    }

    func testObjectGrammarUsesOneCanonicalKeyOrderRatherThanPermutations() throws {
        let schema = BoneToolSchema.object(
            properties: ["z": .boolean, "a": .boolean, "m": .boolean],
            required: ["m", "z", "a"],
            additionalProperties: false
        )
        let source = try BoneLlamaGBNFCompiler().compile(.jsonSchema(schema)).source
        let node = source.split(separator: "\n").first { $0.hasPrefix("node-0 ::=") }.map(String.init)!

        XCTAssertLessThan(node.range(of: #"\"a\""#)!.lowerBound, node.range(of: #"\"m\""#)!.lowerBound)
        XCTAssertLessThan(node.range(of: #"\"m\""#)!.lowerBound, node.range(of: #"\"z\""#)!.lowerBound)
        XCTAssertEqual(node.components(separatedBy: " | ").count, 1)
    }
}
