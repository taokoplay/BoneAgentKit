import XCTest
import BoneAgentKit
import BoneAgentTesting

final class BoneAgentTestingTests: XCTestCase {
    func testScriptedEngineConsumesResponsesAndRecordsRequests() async throws {
        let engine = BoneScriptedInferenceEngine(script: [.finish(.init(text: "synthetic"))])
        let response = try await engine.infer(request: .init(
            modelID: "synthetic-model",
            messages: [.init(role: .user, content: "synthetic")]
        ))
        XCTAssertEqual(response, .finish(.init(text: "synthetic")))
        let requests = await engine.receivedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testRecorderProvidesCompatibleEventSink() async {
        let recorder = BoneAgentEventRecorder()
        await recorder.eventSink().receive(.runStarted)
        await recorder.eventSink().receive(.runFinished(.succeeded))
        let events = await recorder.events()
        XCTAssertEqual(events, [.runStarted, .runFinished(.succeeded)])
    }
}
