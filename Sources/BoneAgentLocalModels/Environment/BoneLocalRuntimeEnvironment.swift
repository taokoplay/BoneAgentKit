import Foundation

public struct BoneLocalRuntimeEnvironment: Equatable, Sendable {
    public enum ThermalState: Int, Codable, Comparable, Sendable {
        case nominal
        case fair
        case serious
        case critical

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let physicalMemoryBytes: UInt64
    public let availableDiskBytes: Int64
    public let activeProcessorCount: Int
    public let isSimulator: Bool
    public let isLowPowerModeEnabled: Bool
    public let thermalState: ThermalState

    public init(
        physicalMemoryBytes: UInt64,
        availableDiskBytes: Int64,
        activeProcessorCount: Int,
        isSimulator: Bool,
        isLowPowerModeEnabled: Bool,
        thermalState: ThermalState
    ) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.availableDiskBytes = availableDiskBytes
        self.activeProcessorCount = max(1, activeProcessorCount)
        self.isSimulator = isSimulator
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalState = thermalState
    }

    public static func current(
        storageURL: URL,
        processInfo: ProcessInfo = .processInfo
    ) throws -> Self {
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        let available = try storageURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage ?? 0
        return Self(
            physicalMemoryBytes: processInfo.physicalMemory,
            availableDiskBytes: available,
            activeProcessorCount: processInfo.activeProcessorCount,
            isSimulator: simulator,
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            thermalState: ThermalState(processInfo.thermalState)
        )
    }
}

private extension BoneLocalRuntimeEnvironment.ThermalState {
    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .critical
        }
    }
}
