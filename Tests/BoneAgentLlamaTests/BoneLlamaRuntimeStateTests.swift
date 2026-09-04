import BoneAgentLocalModels
import XCTest
@testable import BoneAgentLlama

final class BoneLlamaRuntimeStateTests: XCTestCase {
    func testInitialRuntimeAndModelSnapshotsAreValueSemantic() {
        let runtime = BoneLlamaRuntimeState(
            phase: .notLoaded,
            revision: 0,
            runtimeVersion: 1
        )
        XCTAssertEqual(runtime.phase, .notLoaded)
        XCTAssertEqual(runtime.revision, 0)
        XCTAssertNil(runtime.configuration)
        XCTAssertNil(runtime.failure)

        let model = BoneLlamaModelState(modelID: "model", runtimeState: runtime)
        XCTAssertEqual(model.modelID, "model")
        XCTAssertEqual(model.phase, .notLoaded)
        XCTAssertEqual(model.revision, 0)
        XCTAssertEqual(model.runtimeVersion, 1)
        XCTAssertNil(model.configuration)
        XCTAssertNil(model.failure)
    }

    func testFailureSnapshotContainsOnlyTypedError() {
        let state = BoneLlamaRuntimeState(
            phase: .failed,
            revision: 7,
            runtimeVersion: 1,
            configuration: .init(plan: .init(
                contextTokens: 512,
                maximumOutputTokens: 64,
                batchTokens: 32,
                threadCount: 2
            )),
            failure: .modelIncompatible
        )

        XCTAssertEqual(state.phase, .failed)
        XCTAssertEqual(state.failure, .modelIncompatible)
        XCTAssertEqual(state.configuration?.contextTokens, 512)
    }
}
