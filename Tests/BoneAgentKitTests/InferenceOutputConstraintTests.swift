import XCTest
@testable import BoneAgentKit

final class InferenceOutputConstraintTests: XCTestCase {
    func testValidatesJSONSchemaAndEnumChoice() throws {
        let schema = BoneToolSchema.object(
            properties: ["answer": .string(enumValues: ["yes", "no"], minimumLength: nil, maximumLength: nil)],
            required: ["answer"],
            additionalProperties: false
        )

        XCTAssertEqual(try BoneInferenceOutputConstraint.jsonSchema(schema).validated(), .jsonSchema(schema))
        XCTAssertEqual(try BoneInferenceOutputConstraint.enumChoice(["yes", "no"]).validated(), .enumChoice(["yes", "no"]))
    }

    func testRejectsInvalidEnumChoices() {
        let invalid: [BoneInferenceOutputConstraint] = [
            .enumChoice([]),
            .enumChoice(["yes", "yes"]),
            .enumChoice([""]),
            .enumChoice([String(repeating: "x", count: 257)]),
            .enumChoice((0...128).map(String.init)),
        ]

        for constraint in invalid {
            XCTAssertThrowsError(try constraint.validated()) { error in
                XCTAssertEqual(error as? BoneInferenceError, .invalidOutputConstraint)
            }
        }
    }

    func testRejectsInvalidJSONSchema() {
        let invalid = BoneToolSchema.object(
            properties: [:],
            required: ["missing"],
            additionalProperties: false
        )

        XCTAssertThrowsError(try BoneInferenceOutputConstraint.jsonSchema(invalid).validated()) { error in
            XCTAssertEqual(error as? BoneInferenceError, .invalidOutputConstraint)
        }
    }

    func testLegacyRequestDecodesWithoutOutputConstraint() throws {
        let data = Data(#"{"modelID":"model","messages":[{"role":"user","content":"hello"}]}"#.utf8)

        let request = try JSONDecoder().decode(BoneInferenceRequest.self, from: data)

        XCTAssertNil(request.outputConstraint)
    }

    func testRequestRoundTripsOutputConstraint() throws {
        let request = BoneInferenceRequest(
            modelID: "model",
            messages: [.init(role: .user, content: "hello")],
            outputConstraint: .enumChoice(["yes", "no"])
        )

        let decoded = try JSONDecoder().decode(
            BoneInferenceRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
    }

    func testRejectsConstraintCombinedWithStructuredFormatOrTools() throws {
        let schema = BoneToolSchema.object(properties: [:], required: [], additionalProperties: false)
        let structured = BoneInferenceRequest(
            modelID: "model",
            messages: [.init(role: .user, content: "hello")],
            responseFormat: .jsonObject(fallback: .requireNative),
            outputConstraint: .enumChoice(["yes", "no"])
        )
        let withTools = BoneInferenceRequest(
            modelID: "model",
            messages: [.init(role: .user, content: "hello")],
            availableTools: [Self.toolDefinition(schema: schema)],
            outputConstraint: .jsonSchema(schema)
        )

        for request in [structured, withTools] {
            XCTAssertThrowsError(try BoneInferenceRequirements(request: request)) { error in
                XCTAssertEqual(error as? BoneInferenceError, .invalidOutputConstraint)
            }
        }
    }

    func testEnumResultRequiresExactCompleteMatch() throws {
        let constraint = BoneInferenceOutputConstraint.enumChoice(["yes", "NO"])

        for valid in ["yes", "NO"] {
            let response = try BoneInferenceOutputConstraintResult.response(
                from: Data(valid.utf8),
                constraint: constraint
            )
            XCTAssertEqual(response, .finish(.init(text: valid)))
        }
        for invalid in [" yes", "yes\n", "Yes", "yes because"] {
            XCTAssertThrowsError(try BoneInferenceOutputConstraintResult.response(
                from: Data(invalid.utf8),
                constraint: constraint
            )) { error in
                XCTAssertEqual(error as? BoneInferenceTransportError, .invalidResponse)
            }
        }
    }

    func testJSONSchemaResultAcceptsAndValidatesCompleteJSONValue() throws {
        let constraint = BoneInferenceOutputConstraint.jsonSchema(
            .string(enumValues: ["yes"], minimumLength: nil, maximumLength: nil)
        )
        let data = Data(#""yes""#.utf8)

        XCTAssertEqual(
            try BoneInferenceOutputConstraintResult.response(from: data, constraint: constraint),
            .structured(.init(data: data))
        )
        for invalid in [Data(#""no""#.utf8), Data(#""yes" "no""#.utf8)] {
            XCTAssertThrowsError(try BoneInferenceOutputConstraintResult.response(
                from: invalid,
                constraint: constraint
            )) { error in
                XCTAssertEqual(error as? BoneInferenceTransportError, .invalidResponse)
            }
        }
    }

    private static func toolDefinition(schema: BoneToolSchema) -> BoneAgentToolDefinition {
        BoneAgentToolDefinition(
            id: "test.echo",
            version: "1",
            title: "Echo",
            summary: "Echo",
            wireName: "echo",
            schemaVersion: 1,
            inputSchema: schema
        )
    }
}
