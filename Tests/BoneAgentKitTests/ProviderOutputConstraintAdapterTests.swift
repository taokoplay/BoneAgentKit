import Foundation
import XCTest
@testable import BoneAgentKit

final class ProviderOutputConstraintAdapterTests: XCTestCase {
    private let enumConstraint = BoneInferenceOutputConstraint.enumChoice(["approve", "reject"])
    private let objectConstraint = BoneInferenceOutputConstraint.jsonSchema(
        .object(
            properties: ["answer": .string(enumValues: ["yes", "no"], minimumLength: nil, maximumLength: nil)],
            required: ["answer"],
            additionalProperties: false
        )
    )

    func testOpenAIAdapterBuildsStrictJSONSchema() throws {
        let fields = try BoneOpenAIOutputConstraintAdapter().requestFields(for: objectConstraint)
        let responseFormat = try XCTUnwrap(fields["response_format"] as? [String: Any])
        XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
        let wrapper = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
        XCTAssertEqual(wrapper["name"] as? String, "bone_output_constraint")
        XCTAssertEqual(wrapper["strict"] as? Bool, true)
        try assertWrappedSchema(wrapper["schema"])
    }

    func testGeminiAdapterBuildsNativeResponseSchema() throws {
        let fields = try BoneGeminiOutputConstraintAdapter().requestFields(for: enumConstraint)
        let config = try XCTUnwrap(fields["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["responseMimeType"] as? String, "application/json")
        try assertWrappedSchema(config["responseSchema"])
    }

    func testAnthropicAdapterBuildsNativeOutputConfig() throws {
        let fields = try BoneAnthropicOutputConstraintAdapter().requestFields(for: enumConstraint)
        let outputConfig = try XCTUnwrap(fields["output_config"] as? [String: Any])
        let format = try XCTUnwrap(outputConfig["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        try assertWrappedSchema(format["schema"])
    }

    func testAdaptersRestoreAndStrictlyValidateUnifiedResults() throws {
        let adapters: [any BoneProviderOutputConstraintAdapter] = [
            BoneOpenAIOutputConstraintAdapter(),
            BoneGeminiOutputConstraintAdapter(),
            BoneAnthropicOutputConstraintAdapter(),
        ]

        for adapter in adapters {
            XCTAssertEqual(
                try adapter.response(from: Data(#"{"value":"approve"}"#.utf8), constraint: enumConstraint),
                .finish(.init(text: "approve"))
            )
            XCTAssertEqual(
                try adapter.response(from: Data(#"{"value":{"answer":"yes"}}"#.utf8), constraint: objectConstraint),
                .structured(.init(data: Data(#"{"answer":"yes"}"#.utf8)))
            )
            for invalid in [
                Data(#"{"value":"Approve"}"#.utf8),
                Data(#"{"value":"approve","extra":true}"#.utf8),
                Data(#"prefix {"value":"approve"}"#.utf8),
                Data(#"{"value":{"answer":"maybe"}}"#.utf8),
            ] {
                XCTAssertThrowsError(try adapter.response(from: invalid, constraint: enumConstraint))
            }
        }
    }

    func testAdaptersRejectUnsupportedSchemaDialectBeforeRequest() {
        let optionalProperty = BoneInferenceOutputConstraint.jsonSchema(
            .object(
                properties: ["answer": .string(enumValues: [], minimumLength: nil, maximumLength: nil)],
                required: [],
                additionalProperties: false
            )
        )
        let openObject = BoneInferenceOutputConstraint.jsonSchema(
            .object(properties: [:], required: [], additionalProperties: true)
        )
        let boundedString = BoneInferenceOutputConstraint.jsonSchema(
            .string(enumValues: [], minimumLength: 1, maximumLength: 8)
        )

        for adapter in Self.adapters {
            for constraint in [optionalProperty, openObject, boundedString] {
                XCTAssertThrowsError(try adapter.requestFields(for: constraint)) { error in
                    XCTAssertEqual(error as? BoneInferenceError, .invalidOutputConstraint)
                }
            }
        }
    }

    private static var adapters: [any BoneProviderOutputConstraintAdapter] {
        [
            BoneOpenAIOutputConstraintAdapter(),
            BoneGeminiOutputConstraintAdapter(),
            BoneAnthropicOutputConstraintAdapter(),
        ]
    }

    private func assertWrappedSchema(_ raw: Any?) throws {
        let schema = try XCTUnwrap(raw as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["required"] as? [String], ["value"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertNotNil((schema["properties"] as? [String: Any])?["value"])
    }
}
