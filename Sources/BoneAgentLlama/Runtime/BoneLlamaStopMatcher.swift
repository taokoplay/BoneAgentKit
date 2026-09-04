import Foundation

public enum BoneLlamaStopMatch: Equatable, Sendable {
    case none(deliverable: Data)
    case partial(deliverable: Data)
    case matched(index: Int, deliverable: Data)
}

/// 按 UTF-8 bytes 增量识别 Stop String，只保留可能成为 Stop 的最长后缀。
public struct BoneLlamaStopMatcher: Sendable {
    private let stops: [[UInt8]]
    private var pending: [UInt8] = []
    private var isFinished = false

    public var pendingByteCount: Int { pending.count }

    public init(stopStrings: [String]) throws {
        guard !stopStrings.isEmpty,
              stopStrings.count <= BoneLlamaGenerationControl.maximumStopStringCount,
              Set(stopStrings).count == stopStrings.count,
              stopStrings.allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= BoneLlamaGenerationControl.maximumStopStringByteCount
              }) else {
            throw BoneLlamaAdapterError.invalidGenerationControl
        }
        stops = stopStrings.map { Array($0.utf8) }
    }

    public mutating func consume(_ bytes: Data) -> BoneLlamaStopMatch {
        guard !isFinished else { return .none(deliverable: Data()) }
        pending.append(contentsOf: bytes)

        if let match = earliestMatch() {
            let deliverable = Data(pending[..<match.offset])
            pending.removeAll(keepingCapacity: false)
            isFinished = true
            return .matched(index: match.index, deliverable: deliverable)
        }

        let held = longestSuffixThatIsStopPrefix()
        let deliverableCount = pending.count - held
        let deliverable = Data(pending.prefix(deliverableCount))
        if deliverableCount > 0 { pending.removeFirst(deliverableCount) }
        return pending.isEmpty
            ? .none(deliverable: deliverable)
            : .partial(deliverable: deliverable)
    }

    public mutating func finish() -> Data {
        guard !isFinished else { return Data() }
        isFinished = true
        let result = Data(pending)
        pending.removeAll(keepingCapacity: false)
        return result
    }

    private func earliestMatch() -> (offset: Int, index: Int)? {
        var winner: (offset: Int, index: Int)?
        for (index, stop) in stops.enumerated() where stop.count <= pending.count {
            for offset in 0...(pending.count - stop.count) where pending[offset..<(offset + stop.count)].elementsEqual(stop) {
                if winner == nil || offset < winner!.offset || (offset == winner!.offset && index < winner!.index) {
                    winner = (offset, index)
                }
                break
            }
        }
        return winner
    }

    private func longestSuffixThatIsStopPrefix() -> Int {
        let maximum = min(pending.count, stops.map(\.count).max() ?? 0)
        guard maximum > 0 else { return 0 }
        for length in stride(from: maximum, through: 1, by: -1) {
            let suffix = pending.suffix(length)
            if stops.contains(where: { $0.count >= length && $0.prefix(length).elementsEqual(suffix) }) {
                return length
            }
        }
        return 0
    }
}
