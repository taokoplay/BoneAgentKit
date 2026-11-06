import Foundation

/// Actual Tool body interval, excluding authorization/pipeline preparation. No arguments or result data.
public struct BoneAgentToolTiming: Equatable, Sendable {
    public let id: UUID
    public let callID: String
    public let toolID: String
    public let step: Int
    public let isRunning: Bool
    public let durationSeconds: TimeInterval?
}

/// Statistics over observed Runs. A round is an accepted user Run; a step is a business Engine invocation.
/// Provider token counts are not interchangeable with current context occupancy or invoice amounts.
public struct BoneAgentStatistics: Equatable, Sendable {
    public let roundCount: Int
    public let successfulRoundCount: Int
    public let stepCount: Int
    public let summaryCallCount: Int
    public let toolCallCount: Int
    /// Engine invocation intervals, including failed/cancelled and currently active requests.
    public let modelDurationSeconds: TimeInterval?
    public let summaryDurationSeconds: TimeInterval?
    /// Sum of all Tool body intervals. Parallel overlap is intentionally counted more than once.
    public let toolDurationSeconds: TimeInterval?
    /// Union of Tool body intervals within each Run, then summed across rounds.
    public let toolWallDurationSeconds: TimeInterval?
    public let averageTimeToFirstTokenSeconds: TimeInterval?
    public let timeToFirstTokenSampleCount: Int
    /// Weighted rate: sum(final reported output tokens) / sum(first-fragment-to-stream-end seconds).
    /// Uses only completed, live-timed business requests with a positive output interval; not mean(TPS).
    public let outputTokensPerSecond: Double?
    public let throughputSampleCount: Int
    public let tokens: BoneAgentTokenTotals
    /// False for a restored Conversation whose earlier runtime timing/usage was not persisted.
    public let isHistoryComplete: Bool

    public init(snapshots: [BoneAgentTokenSnapshot], isHistoryComplete: Bool = true) {
        // Latest sequence wins; passing successive UI updates never adds the same Run twice.
        var latest: [UUID: BoneAgentTokenSnapshot] = [:]
        for value in snapshots where latest[value.runID].map({ $0.sequence <= value.sequence }) ?? true {
            latest[value.runID] = value
        }
        var summary = BoneStatisticsSummary()
        for run in latest.values { summary.merge(run.aggregate) }
        self.init(summary: summary, isHistoryComplete: isHistoryComplete)
    }

    init(summary: BoneStatisticsSummary, isHistoryComplete: Bool) {
        roundCount = summary.rounds
        successfulRoundCount = summary.successfulRounds
        stepCount = summary.business.usage.requests
        summaryCallCount = summary.summaries.usage.requests
        toolCallCount = summary.toolCount
        modelDurationSeconds = summary.business.duration
        summaryDurationSeconds = summary.summaries.duration
        toolDurationSeconds = summary.toolDuration
        toolWallDurationSeconds = summary.toolWallDuration
        let business = summary.business
        timeToFirstTokenSampleCount = business.firstTokenSamples
        averageTimeToFirstTokenSeconds = business.firstTokenSamples > 0 && business.firstTokenTotal.isFinite
            ? business.firstTokenTotal / Double(business.firstTokenSamples) : nil
        throughputSampleCount = business.throughputSamples
        let rate = business.throughputTokens / business.throughputSeconds
        outputTokensPerSecond = business.throughputSamples > 0 && business.throughputSeconds > 0
            && business.throughputSeconds.isFinite && business.throughputTokens.isFinite && rate.isFinite ? rate : nil
        tokens = .init(summary: summary.totalUsage)
        self.isHistoryComplete = isHistoryComplete
    }
}

struct BoneAgentRequestClock: Equatable, Sendable {
    let started: TimeInterval
    var ended: TimeInterval?
    var transportStarted: TimeInterval?
    var firstOutput: TimeInterval?
    var streamEnded: TimeInterval?
    var live = false
    mutating func observe(_ event: BoneInferenceTelemetryEvent, now: TimeInterval) {
        switch event {
        case .requestStarted(let liveTiming):
            if transportStarted == nil { transportStarted = now; live = liveTiming }
        case .firstOutputToken:
            if live, firstOutput == nil, streamEnded == nil { firstOutput = now }
        case .responseFinished:
            if streamEnded == nil { streamEnded = now }
        case .usage: break
        }
    }
    static func duration(_ start: TimeInterval?, _ end: TimeInterval?) -> TimeInterval? {
        guard let start, let end, start.isFinite, end.isFinite, end >= start, (end - start).isFinite else { return nil }
        return end - start
    }
}

struct BoneAgentToolClock {
    let id: UUID
    let callID: String
    let toolID: String
    let step: Int
    let started: TimeInterval
    var ended: TimeInterval?
    func snapshot(now: TimeInterval) -> BoneAgentToolTiming {
        .init(id: id, callID: callID, toolID: toolID, step: step, isRunning: ended == nil,
              durationSeconds: BoneAgentRequestClock.duration(started, ended ?? now))
    }
    static func unionDuration(_ values: [Self], now: TimeInterval) -> TimeInterval? {
        let intervals = values.map { ($0.started, $0.ended ?? now) }.sorted { $0.0 < $1.0 }
        guard intervals.allSatisfy({ BoneAgentRequestClock.duration($0.0, $0.1) != nil }) else { return nil }
        var result = 0.0
        var current: (TimeInterval, TimeInterval)?
        for next in intervals {
            if let previous = current {
                if next.0 <= previous.1 { current = (previous.0, max(previous.1, next.1)) }
                else { result += previous.1 - previous.0; current = next }
            } else { current = next }
        }
        if let current { result += current.1 - current.0 }
        return result.isFinite ? result : nil
    }
}
