import Foundation
#if canImport(os)
import os
#endif

enum DemoFailureLogError: Error { case unavailable, invalidData }

/// Stores only safe diagnostic values; this is independent of optional private chat archives.
actor DemoFailureLogStore {
    static let maximumRecords = 20
    static let maximumBytes = 65_536
    private let directory: URL
    private var file: URL { directory.appendingPathComponent("failures.json") }
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.taokoplay.BoneAgentLab", category: "RunDiagnostics")
    #endif

    init(directory: URL) { self.directory = directory }

    func records() throws -> [DemoRunFailureDiagnostic] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        do {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size <= Self.maximumBytes else {
                throw DemoFailureLogError.invalidData
            }
            let records = try JSONDecoder().decode([DemoRunFailureDiagnostic].self, from: Data(contentsOf: file))
            guard records.count <= Self.maximumRecords, records.allSatisfy(\.isValid) else { throw DemoFailureLogError.invalidData }
            return records
        } catch let error as DemoFailureLogError { throw error }
        catch { throw DemoFailureLogError.unavailable }
    }

    func record(_ diagnostic: DemoRunFailureDiagnostic) throws {
        guard diagnostic.isValid else { throw DemoFailureLogError.invalidData }
        var records = try records()
        records.append(diagnostic)
        records = Array(records.suffix(Self.maximumRecords))
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(records)
            guard data.count <= Self.maximumBytes else { throw DemoFailureLogError.invalidData }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            var protectedDirectory = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try protectedDirectory.setResourceValues(values)
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            try data.write(to: file, options: options)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            #if canImport(os)
            Self.logger.error("run_failed id=\(diagnostic.id.uuidString, privacy: .public) code=\(diagnostic.code.rawValue, privacy: .public) responses=\(diagnostic.inferenceResponses) tools_prepared=\(diagnostic.toolPreparations) tools_completed=\(diagnostic.completedTools) network_confirmations=\(diagnostic.networkConfirmations)")
            #endif
        } catch let error as DemoFailureLogError { throw error }
        catch { throw DemoFailureLogError.unavailable }
    }
}
