import XCTest
@testable import BoneAgentKit

/// 直接从其他文件构造内部环，锁定跨工具链可见性与既有留存预算；无外部输入或返回值。
final class ObservationRingCompatibilityTests: XCTestCase {
    /// 覆盖空环、超过两圈后的 FIFO 顺序和返回快照的独立性。
    func testInternalInitializerPreservesBoundedFIFOAndSnapshot() {
        // 环最多留存三个整数，不预分配载荷。
        var ring = BoneObservationRing<Int>(limit: 3)
        XCTAssertEqual(ring.count, 0)
        XCTAssertEqual(ring.values, [])
        for value in 1...3 { ring.append(value) }
        // 返回数组必须保持值语义，后续覆盖不改写历史快照。
        let snapshot = ring.values
        for value in 4...10 { ring.append(value) }
        XCTAssertEqual(ring.count, 3)
        XCTAssertEqual(ring.values, [8, 9, 10])
        XCTAssertEqual(snapshot, [1, 2, 3])
    }

    /// 零预算不留存任何事件，也不进入取模路径。
    func testZeroLimitRetainsNothing() {
        // 工具明细允许零预算，初始化不得改变此策略。
        var ring = BoneObservationRing<Int>(limit: 0)
        ring.append(1)
        XCTAssertEqual(ring.count, 0)
        XCTAssertEqual(ring.values, [])
    }
}
