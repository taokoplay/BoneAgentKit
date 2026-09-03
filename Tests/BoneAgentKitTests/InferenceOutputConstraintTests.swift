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
}
