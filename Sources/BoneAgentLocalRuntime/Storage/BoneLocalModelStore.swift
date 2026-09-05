import CryptoKit
import Foundation
import Darwin

public enum BoneLocalModelInstallationState: Equatable, Sendable {
    case notInstalled
    case installed(URL)
    case invalid(BoneLocalModelStoreError)
}

public enum BoneLocalModelStoreError: Error, Equatable, Sendable {
    case invalidModelID
    case invalidArtifactFileName
    case sizeMismatch
    case checksumMismatch
}

public final class BoneLocalModelStore: @unchecked Sendable {
    public let rootURL: URL

    private let mutationLock = NSLock()
    private let fileManager: FileManager
    private let canonicalRootURL: URL
    private let beforeInstallCommit: @Sendable (URL, URL) throws -> Void

    public convenience init(rootURL: URL, fileManager: FileManager = .default) throws {
        try self.init(rootURL: rootURL, fileManager: fileManager, beforeInstallCommit: { _, _ in })
    }

    /// Internal fault/visibility seam; not part of the public storage contract.
    init(rootURL: URL, fileManager: FileManager = .default,
         beforeInstallCommit: @escaping @Sendable (URL, URL) throws -> Void) throws {
        self.beforeInstallCommit = beforeInstallCommit
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        try fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        self.canonicalRootURL = self.rootURL.resolvingSymlinksInPath().standardizedFileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = self.rootURL
        try? mutableRoot.setResourceValues(values)
    }

    public func modelURL(for model: BoneLocalModelDescriptor) throws -> URL {
        try artifactURL(for: model, name: model.artifact.fileName)
    }

    public func partialURL(for model: BoneLocalModelDescriptor) throws -> URL {
        try artifactURL(for: model, name: "\(model.artifact.fileName).partial")
    }

    public func installationState(
        for model: BoneLocalModelDescriptor,
        verifyChecksum: Bool = false
    ) -> BoneLocalModelInstallationState {
        guard let finalURL = try? modelURL(for: model), fileManager.fileExists(atPath: finalURL.path) else {
            return .notInstalled
        }
        do {
            let size = try fileSize(at: finalURL)
            guard size == model.artifact.expectedByteCount else { return .invalid(.sizeMismatch) }
            if verifyChecksum {
                guard try sha256(of: finalURL) == model.artifact.sha256 else {
                    return .invalid(.checksumMismatch)
                }
            }
            return .installed(finalURL)
        } catch let error as BoneLocalModelStoreError {
            return .invalid(error)
        } catch {
            return .invalid(.invalidArtifactFileName)
        }
    }

    @discardableResult
    public func installDownloadedFile(
        at temporaryURL: URL,
        for model: BoneLocalModelDescriptor
    ) throws -> URL {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let directory = try modelDirectory(for: model)
        let final = try modelURL(for: model)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceValues = try temporaryURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else {
            throw BoneLocalModelStoreError.invalidArtifactFileName
        }
        guard Int64(sourceValues.fileSize ?? -1) == model.artifact.expectedByteCount else {
            throw BoneLocalModelStoreError.sizeMismatch
        }
        // Copy into the destination volume. The source remains retryable until commit succeeds.
        let stagingDirectory = try installStagingDirectory()
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let staging = stagingDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: temporaryURL, to: staging)
        let stagingValues = try staging.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard stagingValues.isRegularFile == true, stagingValues.isSymbolicLink != true else {
            throw BoneLocalModelStoreError.invalidArtifactFileName
        }
        guard try fileSize(at: staging) == model.artifact.expectedByteCount else {
            throw BoneLocalModelStoreError.sizeMismatch
        }
        guard try sha256(of: staging) == model.artifact.sha256 else {
            throw BoneLocalModelStoreError.checksumMismatch
        }
        try beforeInstallCommit(staging, final)
        // Revalidate immediately before publication; path checks are not a hostile-process sandbox.
        _ = try modelURL(for: model)
        let result = staging.withUnsafeFileSystemRepresentation { source in
            final.withUnsafeFileSystemRepresentation { destination in
                Darwin.rename(source!, destination!)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Publication is complete. Cleanup failure must not turn a committed install into a failure.
        if temporaryURL.resolvingSymlinksInPath().standardizedFileURL.path != final.resolvingSymlinksInPath().standardizedFileURL.path {
            try? fileManager.removeItem(at: temporaryURL)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
        return final
    }

    public func removeModel(_ model: BoneLocalModelDescriptor) throws {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let directory = try modelDirectory(for: model)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    /// Startup-only cleanup. The Host must ensure no other Store/process is using this root.
    public func cleanIncompleteDownloads() throws {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        guard rootURL.resolvingSymlinksInPath().standardizedFileURL.path == canonicalRootURL.path else {
            throw BoneLocalModelStoreError.invalidModelID
        }
        for name in [BoneLocalModelPathPolicy.stagingDirectoryName, BoneLocalModelPathPolicy.downloadDirectoryName] {
            let staging = try stagingDirectory(name: name)
            if fileManager.fileExists(atPath: staging.path) {
                for url in try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
                    try fileManager.removeItem(at: url)
                }
            }
        }
        // Only the reserved legacy partial suffix, never model directories or final artifacts.
        guard let enumerator = fileManager.enumerator(
            at: rootURL, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []
        ) else { return }
        for case let url as URL in enumerator where url.lastPathComponent.lowercased().hasSuffix(".partial") || url.lastPathComponent.lowercased().hasSuffix(".partial.download") {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true, values.isSymbolicLink != true {
                try fileManager.removeItem(at: url)
            }
        }
    }

    /// One unique path per transport attempt; caller owns cleanup after the operation is quiescent.
    func downloadStagingURL() throws -> URL {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let directory = try stagingDirectory(name: BoneLocalModelPathPolicy.downloadDirectoryName)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString)
    }

    private func installStagingDirectory() throws -> URL {
        try stagingDirectory(name: BoneLocalModelPathPolicy.stagingDirectoryName)
    }

    private func stagingDirectory(name: String) throws -> URL {
        guard rootURL.resolvingSymlinksInPath().standardizedFileURL.path == canonicalRootURL.path else {
            throw BoneLocalModelStoreError.invalidModelID
        }
        let url = rootURL.appendingPathComponent(name, isDirectory: true)
        let expected = canonicalRootURL.appendingPathComponent(name).path
        guard url.resolvingSymlinksInPath().standardizedFileURL.path == expected,
              (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil else {
            throw BoneLocalModelStoreError.invalidModelID
        }
        return url
    }

    private func modelDirectory(for model: BoneLocalModelDescriptor) throws -> URL {
        guard BoneLocalModelPathPolicy.isIdentifier(model.id),
              rootURL.resolvingSymlinksInPath().standardizedFileURL.path == canonicalRootURL.path else {
            throw BoneLocalModelStoreError.invalidModelID
        }
        guard BoneLocalModelPathPolicy.isFileName(model.artifact.fileName) else {
            throw BoneLocalModelStoreError.invalidArtifactFileName
        }
        let directory = rootURL.appendingPathComponent(model.id, isDirectory: true)
        let expected = canonicalRootURL.appendingPathComponent(model.id, isDirectory: true).standardizedFileURL
        guard directory.resolvingSymlinksInPath().standardizedFileURL.path == expected.path,
              (try? fileManager.destinationOfSymbolicLink(atPath: directory.path)) == nil else {
            throw BoneLocalModelStoreError.invalidModelID
        }
        return directory
    }

    private func artifactURL(for model: BoneLocalModelDescriptor, name: String) throws -> URL {
        let directory = try modelDirectory(for: model)
        let url = directory.appendingPathComponent(name, isDirectory: false)
        let expected = canonicalRootURL.appendingPathComponent(model.id, isDirectory: true)
            .appendingPathComponent(name, isDirectory: false).standardizedFileURL
        guard url.resolvingSymlinksInPath().standardizedFileURL.path == expected.path,
              (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil else {
            throw BoneLocalModelStoreError.invalidArtifactFileName
        }
        return url
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? -1)
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = handle.readData(ofLength: 1_048_576)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Shared lexical boundary for catalog and direct Store clients. This is not an OS sandbox.
enum BoneLocalModelPathPolicy {
    static let stagingDirectoryName = ".bone-install-staging"
    static let downloadDirectoryName = ".bone-download-staging"
    static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.lowercased() != stagingDirectoryName && value.lowercased() != downloadDirectoryName &&
            value.utf8.allSatisfy { byte in
                (65...90).contains(byte) || (97...122).contains(byte) ||
                    (48...57).contains(byte) || byte == 46 || byte == 95 || byte == 45
            }
    }

    static func isFileName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." &&
            !value.lowercased().hasSuffix(".partial") && !value.lowercased().hasSuffix(".partial.download") &&
            !value.contains("/") && !value.contains("\\") && !value.utf8.contains(0) &&
            value == URL(fileURLWithPath: value).lastPathComponent
    }
}
