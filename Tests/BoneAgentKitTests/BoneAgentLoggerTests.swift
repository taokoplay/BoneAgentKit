import XCTest
@testable import BoneAgentKit

final class BoneAgentLoggerTests: XCTestCase {
    func testDebugCanBeEnabledAndContextIsForwarded() {
        let logger = RecordingLogger()
        let config = BoneAgentLoggerConfiguration(isDebugEnabled: true, minimumLevel: .debug, logger: logger)
        config.write(.debug, "request", context: BoneAgentLogContext(["runID": "r1", "provider": "test"]))
        XCTAssertEqual(logger.entries.count, 1)
        XCTAssertEqual(logger.entries[0].context?.values["runID"], "r1")
    }

    func testDebugIsDisabledByDefault() {
        let logger = RecordingLogger()
        BoneAgentLoggerConfiguration(logger: logger).write(.debug, "hidden")
        XCTAssertTrue(logger.entries.isEmpty)
    }
}

private final class RecordingLogger: BoneAgentLogger, @unchecked Sendable {
    struct Entry { let context: BoneAgentLogContext? }
    var entries: [Entry] = []
    func log(_ level: BoneAgentLogLevel, message: @autoclosure @Sendable () -> String, context: BoneAgentLogContext?) {
        entries.append(Entry(context: context))
    }
}
