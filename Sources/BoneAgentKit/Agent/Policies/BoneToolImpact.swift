import Foundation

public enum BoneToolDataAccessImpact: Int, Codable, Comparable, Sendable {
    case none = 0
    case `public` = 1
    case userPrivate = 2
    case credential = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum BoneToolExternalTransmissionImpact: Int, Codable, Comparable, Sendable {
    case none = 0
    case approvedProvider = 1
    case arbitraryNetwork = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum BoneToolStateChangeImpact: Int, Codable, Comparable, Sendable {
    case none = 0
    case reversible = 1
    case irreversible = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum BoneToolEconomicImpact: Int, Codable, Comparable, Sendable {
    case none = 0
    case metered = 1
    case purchase = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum BoneToolUserVisibleImpact: Int, Codable, Comparable, Sendable {
    case none = 0
    case notification = 1
    case publication = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum BoneToolPermissionChangeImpact: Int, Codable, Comparable, Sendable {
    case none = 0
    case grantsAccess = 1
    case securityBoundary = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Tool 的正交影响声明。新增维度无法被旧 Host 解码时会自然 fail-closed。
public struct BoneToolImpact: Codable, Equatable, Sendable {
    public let dataAccess: BoneToolDataAccessImpact
    public let externalTransmission: BoneToolExternalTransmissionImpact
    public let stateChange: BoneToolStateChangeImpact
    public let economic: BoneToolEconomicImpact
    public let userVisible: BoneToolUserVisibleImpact
    public let permissionChange: BoneToolPermissionChangeImpact

    public init(
        dataAccess: BoneToolDataAccessImpact,
        externalTransmission: BoneToolExternalTransmissionImpact,
        stateChange: BoneToolStateChangeImpact,
        economic: BoneToolEconomicImpact,
        userVisible: BoneToolUserVisibleImpact,
        permissionChange: BoneToolPermissionChangeImpact
    ) {
        self.dataAccess = dataAccess
        self.externalTransmission = externalTransmission
        self.stateChange = stateChange
        self.economic = economic
        self.userVisible = userVisible
        self.permissionChange = permissionChange
    }

    public static let ordinaryPublicRead = Self(
        dataAccess: .public,
        externalTransmission: .none,
        stateChange: .none,
        economic: .none,
        userVisible: .none,
        permissionChange: .none
    )

    public var isOrdinaryReadOnly: Bool {
        dataAccess <= .public && isLocalReadOnly
    }

    /// 不产生外传、状态、费用、用户可见或权限影响的本地读取。
    /// userPrivate/credential 仍必须先通过 Host policy 授权，但不需要副作用事务管线。
    public var isLocalReadOnly: Bool {
        externalTransmission == .none &&
        stateChange == .none &&
        economic == .none &&
        userVisible == .none &&
        permissionChange == .none
    }

    public var requiresHostAuthorization: Bool {
        dataAccess >= .userPrivate ||
        externalTransmission != .none ||
        stateChange != .none ||
        economic != .none ||
        userVisible != .none ||
        permissionChange != .none
    }

    func isWithin(_ maximum: Self) -> Bool {
        dataAccess <= maximum.dataAccess &&
        externalTransmission <= maximum.externalTransmission &&
        stateChange <= maximum.stateChange &&
        economic <= maximum.economic &&
        userVisible <= maximum.userVisible &&
        permissionChange <= maximum.permissionChange
    }
}

public enum BoneToolPolicyError: Error, Codable, Equatable, Sendable {
    case undeclaredImpact
    case impactExceedsHostPolicy
}

/// Host 可上调允许的影响边界，但 Tool 声明不能覆盖或降低该边界。
public struct BoneToolImpactPolicy: Codable, Equatable, Sendable {
    public let maximumAllowed: BoneToolImpact

    public init(maximumAllowed: BoneToolImpact) {
        self.maximumAllowed = maximumAllowed
    }

    public func authorize(_ impact: BoneToolImpact) throws {
        guard impact.isWithin(maximumAllowed) else {
            throw BoneToolPolicyError.impactExceedsHostPolicy
        }
    }
}
