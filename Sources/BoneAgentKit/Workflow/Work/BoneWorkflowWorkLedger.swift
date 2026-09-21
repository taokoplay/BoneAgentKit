import Foundation

public enum BoneWorkflowWorkLedgerError: Error, Codable, Equatable, Sendable {
    case invalidInput, missingUnit, missingLedger, revisionConflict, leaseConflict, pageConflict
    case invalidTransition, inFlight, recoveryRequired, planMismatch, counterOverflow
}

/// Run scope 的分页/拆分账本，aggregate revision 保证跨单元 split 原子性。
/// payload/response/cursor/artifact 均为不透明字节，Host 负责数据分类与存储策略。
/// 无任意状态构造或合成 Codable 解码；可信 Host 可按持久命令重放恢复，不能反序列化绕过不变量。
public struct BoneWorkflowWorkLedger: Equatable, Sendable {
    public static let maximumDataByteCount = 4 * 1_048_576
    public struct Seed: Codable, Equatable, Sendable {
        public let id: String
        public let payload: Data
        public init(id: String, payload: Data) throws {
            guard !id.isEmpty, id.count <= 128,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  payload.count <= BoneWorkflowWorkLedger.maximumDataByteCount else { throw BoneWorkflowWorkLedgerError.invalidInput }
            self.id = id
            self.payload = payload
        }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(id: c.decode(String.self, forKey: .id), payload: c.decode(Data.self, forKey: .payload))
        }
    }
    public enum State: String, Codable, Sendable { case pending, partial, completed, split, blocked }
    public enum StopReason: String, Codable, Sendable { case noProgress, cursorLimit }
    public struct Page: Equatable, Sendable {
        public enum Phase: String, Codable, Sendable { case reserved, dispatched, responseRecorded, committed, knownFailure }
        public let number: UInt64
        public let leaseGeneration: UInt64
        public fileprivate(set) var phase: Phase
        public fileprivate(set) var response: Data?
        /// 首次成功对账的完整目标及Host依据引用；不会改写原页 generation。
        public fileprivate(set) var reconciliation: Reconciliation? = nil
        fileprivate var inFlight: Bool { phase == .reserved || phase == .dispatched || phase == .responseRecorded }
    }
    public struct Unit: Equatable, Sendable {
        public let id: String
        public let payload: Data
        public fileprivate(set) var state: State
        public fileprivate(set) var nextPage: UInt64
        public fileprivate(set) var cursor: Data?
        public fileprivate(set) var artifact: Data?
        public fileprivate(set) var pages: [Page]
        public fileprivate(set) var children: [String]
        public fileprivate(set) var stopReason: StopReason?
        public var requestCount: UInt64 { UInt64(pages.count) }
        fileprivate init(_ seed: Seed) {
            id = seed.id; payload = seed.payload; state = .pending; nextPage = 0
            cursor = nil; artifact = nil; pages = []; children = []; stopReason = nil
        }
    }
    public enum Preflight: Equatable, Sendable {
        case ready
        case inFlight(page: UInt64, phase: Page.Phase)
        case recoveryRequired(page: UInt64)
        case terminal(State)
    }
    /// Codable 仅用于可信 Host 命令日志；解码后必须 applying 重新验证，不代表命令已执行或获授权。
    public enum Command: Codable, Equatable, Sendable {
        case reserve(unitID: String, page: UInt64)
        case dispatch(unitID: String, page: UInt64)
        case recordResponse(unitID: String, page: UInt64, response: Data)
        case commit(unitID: String, page: UInt64, cursor: Data?, artifact: Data, completed: Bool)
        /// Host 已确认失败且无未知副作用；超时/无 Worker 不构成该证明。
        case finishKnownFailure(unitID: String, page: UInt64)
        case stop(unitID: String, reason: StopReason)
        case split(unitID: String, children: [Seed])
        fileprivate var unitID: String {
            switch self {
            case .reserve(let id, _), .dispatch(let id, _), .recordResponse(let id, _, _),
                 .commit(let id, _, _, _, _), .finishKnownFailure(let id, _), .stop(let id, _), .split(let id, _): return id
            }
        }
    }
    public let runID: BoneRunID
    public private(set) var revision: UInt64
    public private(set) var leaseGeneration: UInt64
    /// 原始准备计划，open 等值校验不把 split 的后续子单元误当新初始计划。
    public let preparedUnits: [Seed]
    public private(set) var units: [Unit]

    public init(runID: BoneRunID, leaseGeneration: UInt64, units: [Seed]) throws {
        guard leaseGeneration > 0, !units.isEmpty, Set(units.map(\.id)).count == units.count else {
            throw BoneWorkflowWorkLedgerError.invalidInput
        }
        self.runID = runID
        self.revision = 1
        self.leaseGeneration = leaseGeneration
        self.preparedUnits = units
        self.units = units.map(Unit.init)
    }
    public func unit(id: String) throws -> Unit {
        guard let unit = units.first(where: { $0.id == id }) else { throw BoneWorkflowWorkLedgerError.missingUnit }
        return unit
    }
    public func preflight(unitID: String) throws -> Preflight {
        let unit = try unit(id: unitID)
        if let page = unit.pages.last, page.inFlight {
            return page.leaseGeneration == leaseGeneration ? .inFlight(page: page.number, phase: page.phase) : .recoveryRequired(page: page.number)
        }
        if unit.state == .pending || unit.state == .partial { return .ready }
        return .terminal(unit.state)
    }
    /// Host 取得真实 Run 接管授权后推进本账本围栏；不清掉在途页，不自动恢复未知请求。
    public func advancingLease(expectedGeneration: UInt64, newGeneration: UInt64) throws -> Self {
        guard expectedGeneration == leaseGeneration, newGeneration > leaseGeneration else { throw BoneWorkflowWorkLedgerError.leaseConflict }
        var next = self
        next.revision = try increment(revision)
        next.leaseGeneration = newGeneration
        return next
    }
    /// 纯状态推进，不发请求、不扣 P4 预算。Host 需以 revision/generation CAS 原子保存返回值。
    public func applying(_ command: Command, leaseGeneration: UInt64) throws -> Self {
        guard leaseGeneration == self.leaseGeneration else { throw BoneWorkflowWorkLedgerError.leaseConflict }
        guard let index = units.firstIndex(where: { $0.id == command.unitID }) else { throw BoneWorkflowWorkLedgerError.missingUnit }
        var next = self
        next.revision = try increment(revision)
        var unit = units[index]
        guard unit.state == .pending || unit.state == .partial else { throw BoneWorkflowWorkLedgerError.invalidTransition }
        switch command {
        case .reserve(_, let page):
            try requireIdle(unit)
            guard page == unit.nextPage else { throw BoneWorkflowWorkLedgerError.pageConflict }
            unit.nextPage = try increment(unit.nextPage)
            unit.pages.append(.init(number: page, leaseGeneration: leaseGeneration, phase: .reserved, response: nil))
            unit.state = .partial
        case .dispatch(_, let page):
            let p = try currentPage(unit, number: page)
            guard unit.pages[p].phase == .reserved else { throw BoneWorkflowWorkLedgerError.invalidTransition }
            unit.pages[p].phase = .dispatched
        case .recordResponse(_, let page, let response):
            try validate(response)
            let p = try currentPage(unit, number: page)
            guard unit.pages[p].phase == .dispatched else { throw BoneWorkflowWorkLedgerError.invalidTransition }
            unit.pages[p].response = response
            unit.pages[p].phase = .responseRecorded
        case .commit(_, let page, let cursor, let artifact, let completed):
            if let cursor { try validate(cursor) }
            try validate(artifact)
            let p = try currentPage(unit, number: page)
            guard unit.pages[p].phase == .responseRecorded else { throw BoneWorkflowWorkLedgerError.invalidTransition }
            unit.pages[p].phase = .committed
            unit.cursor = cursor
            unit.artifact = artifact
            unit.state = completed ? .completed : .partial
        case .finishKnownFailure(_, let page):
            let p = try currentPage(unit, number: page)
            guard unit.pages[p].phase == .reserved || unit.pages[p].phase == .dispatched else {
                throw BoneWorkflowWorkLedgerError.invalidTransition
            }
            unit.pages[p].phase = .knownFailure
            // Remain partial; do not roll back unique page identity, cursor or applied artifact.
        case .stop(_, let reason):
            try requireIdle(unit)
            unit.state = .blocked
            unit.stopReason = reason
        case .split(_, let children):
            try requireIdle(unit)
            guard children.count >= 2, Set(children.map(\.id)).count == children.count,
                  children.allSatisfy({ child in !units.contains(where: { $0.id == child.id }) }) else {
                throw BoneWorkflowWorkLedgerError.invalidInput
            }
            unit.state = .split
            unit.children = children.map(\.id)
            next.units.append(contentsOf: children.map(Unit.init))
        }
        next.units[index] = unit
        return next
    }
    /// 只写回 Host 已确认的旧在途页；不发请求、不转移页所有权、不推断未知结果。
    /// revision 是整个 Run 账本的CAS；外部业务应用/Effect收口仍需Host事务协调。
    public func reconciling(_ request: Reconciliation) throws -> Self {
        guard request.runID == runID else { throw BoneWorkflowWorkLedgerError.invalidInput }
        guard request.expectedRevision == revision else { throw BoneWorkflowWorkLedgerError.revisionConflict }
        guard request.resolvingGeneration == leaseGeneration else { throw BoneWorkflowWorkLedgerError.leaseConflict }
        guard let index = units.firstIndex(where: { $0.id == request.unitID }) else { throw BoneWorkflowWorkLedgerError.missingUnit }
        var unit = units[index]
        guard unit.state == .partial else { throw BoneWorkflowWorkLedgerError.invalidTransition }
        guard let page = unit.pages.last, page.number == request.page else { throw BoneWorkflowWorkLedgerError.pageConflict }
        guard page.leaseGeneration == request.sourceGeneration, page.leaseGeneration < leaseGeneration else {
            throw BoneWorkflowWorkLedgerError.leaseConflict
        }
        guard page.inFlight, page.reconciliation == nil else { throw BoneWorkflowWorkLedgerError.invalidTransition }
        let p = unit.pages.count - 1
        switch request.outcome {
        case .knownFailure:
            guard page.phase == .reserved || page.phase == .dispatched else { throw BoneWorkflowWorkLedgerError.invalidTransition }
            unit.pages[p].phase = .knownFailure
        case .committed(let response, let cursor, let artifact, let completed):
            guard page.phase == .dispatched || page.phase == .responseRecorded else { throw BoneWorkflowWorkLedgerError.invalidTransition }
            if page.phase == .responseRecorded, page.response != response { throw BoneWorkflowWorkLedgerError.invalidInput }
            unit.pages[p].response = response
            unit.pages[p].phase = .committed
            unit.cursor = cursor
            unit.artifact = artifact
            unit.state = completed ? .completed : .partial
        }
        unit.pages[p].reconciliation = request
        var next = self
        next.revision = try increment(revision)
        next.units[index] = unit
        return next
    }

    private func currentPage(_ unit: Unit, number: UInt64) throws -> Int {
        guard let page = unit.pages.last, page.number == number else { throw BoneWorkflowWorkLedgerError.pageConflict }
        guard page.leaseGeneration == leaseGeneration else { throw BoneWorkflowWorkLedgerError.recoveryRequired }
        return unit.pages.count - 1
    }
    private func requireIdle(_ unit: Unit) throws {
        if let page = unit.pages.last, page.inFlight {
            throw page.leaseGeneration == leaseGeneration ? BoneWorkflowWorkLedgerError.inFlight : .recoveryRequired
        }
    }
    private func validate(_ data: Data) throws {
        guard data.count <= Self.maximumDataByteCount else { throw BoneWorkflowWorkLedgerError.invalidInput }
    }
    private func increment(_ value: UInt64) throws -> UInt64 {
        let (next, overflow) = value.addingReportingOverflow(1)
        guard !overflow else { throw BoneWorkflowWorkLedgerError.counterOverflow }
        return next
    }
}
