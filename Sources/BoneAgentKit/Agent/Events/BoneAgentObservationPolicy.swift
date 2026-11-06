import Foundation

/// Bounds observation overhead, not model context or business history. Aggregate totals cover all records.
public struct BoneAgentObservationPolicy: Equatable, Sendable {
    public let maximumRequestDetails: Int
    public let maximumToolDetails: Int
    public let maximumModelBreakdowns: Int
    public let minimumTokenUpdateInterval: TimeInterval

    public init() {
        maximumRequestDetails = 64
        maximumToolDetails = 128
        maximumModelBreakdowns = 16
        minimumTokenUpdateInterval = 0.1
    }

    /// Limits apply to completed details; in-flight operations remain visible until they finish.
    /// Zero interval explicitly opts into every changed usage snapshot. No background timer is created.
    public init(maximumRequestDetails: Int, maximumToolDetails: Int = 128,
                maximumModelBreakdowns: Int = 16, minimumTokenUpdateInterval: TimeInterval = 0.1) throws {
        guard (1...1_024).contains(maximumRequestDetails), (0...1_024).contains(maximumToolDetails),
              (0...128).contains(maximumModelBreakdowns), minimumTokenUpdateInterval.isFinite,
              (0...60).contains(minimumTokenUpdateInterval) else {
            throw BoneAgentObservationPolicyError.invalidPolicy
        }
        self.maximumRequestDetails = maximumRequestDetails
        self.maximumToolDetails = maximumToolDetails
        self.maximumModelBreakdowns = maximumModelBreakdowns
        self.minimumTokenUpdateInterval = minimumTokenUpdateInterval
    }
}

public enum BoneAgentObservationPolicyError: Error, Equatable, Sendable { case invalidPolicy }

/// Lazily filled ring. Appending never shifts retained history; returned arrays remain immutable by COW.
struct BoneObservationRing<Element> {
    let limit: Int
    private var storage: [Element] = []
    private var next = 0
    var count: Int { storage.count }
    mutating func append(_ value: Element) {
        guard limit > 0 else { return }
        if storage.count < limit { storage.append(value) }
        else { storage[next] = value; next = (next + 1) % limit }
    }
    var values: [Element] {
        guard next > 0 else { return storage }
        return Array(storage[next...]) + storage[..<next]
    }
}

/// Nonnegative count arithmetic and optional durations preserve unknown/overflow rather than wrapping.
enum BoneObservationMath {
    static func add(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : value
    }
    static func duration(_ lhs: TimeInterval?, _ rhs: TimeInterval?) -> TimeInterval? {
        guard let lhs, let rhs, lhs.isFinite, rhs.isFinite, lhs >= 0, rhs >= 0, (lhs + rhs).isFinite else { return nil }
        return lhs + rhs
    }
}

struct BoneUsageSummary: Equatable, Sendable {
    var requests = 0
    var responses = 0
    var reported = 0
    var input = 0
    var output = 0
    var cached: Int? = 0
    var reasoning: Int? = 0
    var cacheCreation: Int? = 0
    var overflowed = false

    mutating func record(_ request: BoneAgentTokenRequest) {
        requests = add(requests, 1)
        guard request.state == .responseReceived else { return }
        responses = add(responses, 1)
        guard let usage = request.finalUsage else { return }
        reported = add(reported, 1)
        input = add(input, usage.inputTokens); output = add(output, usage.outputTokens)
        cached = optionalAdd(cached, usage.cachedInputTokens)
        reasoning = optionalAdd(reasoning, usage.reasoningTokens)
        cacheCreation = optionalAdd(cacheCreation, usage.cacheCreationInputTokens)
    }
    mutating func merge(_ other: Self) {
        requests = add(requests, other.requests); responses = add(responses, other.responses)
        input = add(input, other.input); output = add(output, other.output)
        if other.reported > 0 {
            cached = optionalAdd(cached, other.cached)
            reasoning = optionalAdd(reasoning, other.reasoning)
            cacheCreation = optionalAdd(cacheCreation, other.cacheCreation)
        }
        reported = add(reported, other.reported)
        overflowed = overflowed || other.overflowed
    }
    private mutating func add(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        if overflow { overflowed = true; return Int.max }
        return value
    }
    private mutating func optionalAdd(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard let lhs, let rhs else { return nil }
        return add(lhs, rhs)
    }
}

struct BoneRequestStatisticsSummary: Equatable, Sendable {
    var usage = BoneUsageSummary()
    var duration: TimeInterval? = 0
    var firstTokenTotal: TimeInterval = 0
    var firstTokenSamples = 0
    var throughputTokens = 0.0
    var throughputSeconds = 0.0
    var throughputSamples = 0

    mutating func record(_ request: BoneAgentTokenRequest) {
        usage.record(request)
        duration = BoneObservationMath.duration(duration, request.durationSeconds)
        if let first = request.timeToFirstTokenSeconds {
            firstTokenTotal += first
            firstTokenSamples = BoneObservationMath.add(firstTokenSamples, 1)
        }
        if request.state == .responseReceived, let final = request.finalUsage,
           let interval = request.outputDurationSeconds, interval > 0 {
            throughputTokens += Double(final.outputTokens)
            throughputSeconds += interval
            throughputSamples = BoneObservationMath.add(throughputSamples, 1)
        }
    }
    mutating func merge(_ other: Self) {
        usage.merge(other.usage)
        duration = BoneObservationMath.duration(duration, other.duration)
        firstTokenTotal += other.firstTokenTotal
        firstTokenSamples = BoneObservationMath.add(firstTokenSamples, other.firstTokenSamples)
        throughputTokens += other.throughputTokens; throughputSeconds += other.throughputSeconds
        throughputSamples = BoneObservationMath.add(throughputSamples, other.throughputSamples)
    }
}

/// Fixed-size sufficient statistics: no request/tool/model IDs or history arrays.
struct BoneStatisticsSummary: Equatable, Sendable {
    var rounds = 0
    var successfulRounds = 0
    var business = BoneRequestStatisticsSummary()
    var summaries = BoneRequestStatisticsSummary()
    var toolCount = 0
    var toolDuration: TimeInterval? = 0
    var toolWallDuration: TimeInterval? = 0
    var totalUsage: BoneUsageSummary {
        var value = business.usage; value.merge(summaries.usage); return value
    }
    mutating func record(_ request: BoneAgentTokenRequest) {
        if request.purpose == .business { business.record(request) } else { summaries.record(request) }
    }
    mutating func merge(_ other: Self) {
        rounds = BoneObservationMath.add(rounds, other.rounds)
        successfulRounds = BoneObservationMath.add(successfulRounds, other.successfulRounds)
        business.merge(other.business); summaries.merge(other.summaries)
        toolCount = BoneObservationMath.add(toolCount, other.toolCount)
        toolDuration = BoneObservationMath.duration(toolDuration, other.toolDuration)
        toolWallDuration = BoneObservationMath.duration(toolWallDuration, other.toolWallDuration)
    }
}

/// Conversation callbacks are serialized per Run. Only its current Run and one finished ID are retained.
struct BoneConversationStatisticsAccumulator {
    private var completed = BoneStatisticsSummary()
    private(set) var active: BoneAgentTokenSnapshot?
    private var lastFinishedID: UUID?
    var retainedRunCount: Int { active == nil ? 0 : 1 }
    var activeRunID: UUID? { active?.runID }

    mutating func observe(_ snapshot: BoneAgentTokenSnapshot) {
        guard snapshot.runID != lastFinishedID else { return }
        if let active {
            guard active.runID == snapshot.runID, active.sequence <= snapshot.sequence else { return }
        }
        if snapshot.terminalState != nil {
            completed.merge(snapshot.aggregate)
            lastFinishedID = snapshot.runID
            active = nil
        } else { active = snapshot }
    }
    func statistics(isHistoryComplete: Bool) -> BoneAgentStatistics {
        var value = completed
        if let active { value.merge(active.aggregate) }
        return .init(summary: value, isHistoryComplete: isHistoryComplete)
    }
}
