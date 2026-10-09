import Foundation
import XCTest
@testable import BoneAgentKit

final class ModelMetadataTests: XCTestCase {
    func testDeclarationPreservesUnknownEmptyAndFalseSeparately() throws {
        let absent = try JSONDecoder().decode(BoneModelMetadata.Declaration.self, from: Data(#"{"id":"m","name":"M"}"#.utf8))
        XCTAssertNil(absent.reasoning)
        XCTAssertNil(absent.reasoningOptions)
        XCTAssertNil(absent.toolCalling)
        let value = try JSONDecoder().decode(BoneModelMetadata.Declaration.self, from: Data(#"{"id":"m","reasoning":true,"reasoning_options":[],"tool_call":false,"temperature":false}"#.utf8))
        XCTAssertEqual(value.reasoningOptions, [])
        XCTAssertEqual(value.toolCalling, false)
        XCTAssertEqual(value.temperature, false)
        XCTAssertEqual(try JSONDecoder().decode(BoneModelMetadata.Declaration.self, from: JSONEncoder().encode(value)), value)
    }

    func testReasoningControlsAndInterleavedUnionsRoundTrip() throws {
        let json = #"{"id":"m","reasoning":true,"reasoning_options":[{"type":"toggle"},{"type":"effort","values":[null,"default","high","future"]},{"type":"budget_tokens","min":-1,"max":32768}],"interleaved":{"field":"reasoning_details"}}"#
        let value = try JSONDecoder().decode(BoneModelMetadata.Declaration.self, from: Data(json.utf8))
        XCTAssertEqual(value.reasoningOptions?[1].values, [nil, "default", "high", "future"])
        XCTAssertEqual(value.interleaved, .field("reasoning_details"))
        XCTAssertEqual(try JSONDecoder().decode(BoneModelMetadata.Declaration.self, from: JSONEncoder().encode(value)), value)
        let flag = try JSONDecoder().decode(BoneModelMetadata.Interleaved.self, from: Data("true".utf8))
        XCTAssertEqual(flag, .supported)
        XCTAssertThrowsError(try JSONDecoder().decode(BoneModelMetadata.Interleaved.self, from: Data("false".utf8)))
    }

    func testPriceTiersAndZeroImageLimitsAreNotExecutionBudgets() throws {
        let json = #"{"id":"image","limit":{"context":0,"input":0,"output":0},"cost":{"input":1,"output":2,"tiers":[{"tier":{"type":"context","size":272000},"input":3,"output":4}]},"status":"future-status","modalities":{"input":["text","image"],"output":["image"]}}"#
        let value = try JSONDecoder().decode(BoneModelMetadata.Declaration.self, from: Data(json.utf8))
        XCTAssertEqual(value.limits?.context, 0)
        XCTAssertEqual(value.cost?.tiers?.first?.tier.size, 272000)
        XCTAssertEqual(value.status, "future-status")
    }

    func testBundledMetadataHasExactChannelIdentityAndNoVerifiedProfile() throws {
        let catalog = try BoneInferenceProviderCatalog.bundled()
        let models = catalog.providers.flatMap(\.models)
        XCTAssertEqual(models.filter { $0.metadata != nil }.count, 33)
        for model in models where model.metadata != nil {
            XCTAssertEqual(model.metadata?.declaration.id, model.id)
            XCTAssertEqual(model.metadata?.provenance.source, .modelsDev)
            XCTAssertEqual(model.metadata?.provenance.retrievedAt, "2026-10-09")
            XCTAssertNil(model.inferenceCapabilityProfile)
        }
        let plan = try XCTUnwrap(catalog.provider(ident: "MiMoTokenPlan"))
        XCTAssertEqual(plan.models.first { $0.id == "mimo-v2.5" }?.metadata?.provenance.providerID, "xiaomi-token-plan-cn")
        XCTAssertNil(plan.models.first { $0.id == "mimo-v2-omni" }?.metadata)
    }
}
