import CryptoKit
import Foundation

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

    private let fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        try fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = self.rootURL
        try? mutableRoot.setResourceValues(values)
    }

    public func modelURL(for model: BoneLocalModelDescriptor) throws -> URL {
        try modelDirectory(for: model).appendingPathComponent(model.artifact.fileName, isDirectory: false)
    }

    public func partialURL(for model: BoneLocalModelDescriptor) throws -> URL {
        try modelDirectory(for: model).appendingPathComponent("\(model.artifact.fileName).partial")
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
        guard try fileSize(at: temporaryURL) == model.artifact.expectedByteCount else {
            throw BoneLocalModelStoreError.sizeMismatch
        }
        guard try sha256(of: temporaryURL) == model.artifact.sha256 else {
            throw BoneLocalModelStoreError.checksumMismatch
        }

        let directory = try modelDirectory(for: model)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = try partialURL(for: model)
        let final = try modelURL(for: model)
        try? fileManager.removeItem(at: partial)
        try fileManager.moveItem(at: temporaryURL, to: partial)
        try? fileManager.removeItem(at: final)
        try fileManager.moveItem(at: partial, to: final)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
        return final
    }

    public func removeModel(_ model: BoneLocalModelDescriptor) throws {
        let directory = try modelDirectory(for: model)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    public func cleanIncompleteDownloads() throws {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let url as URL in enumerator where url.pathExtension == "partial" {
            try fileManager.removeItem(at: url)
        }
    }

    private func modelDirectory(for model: BoneLocalModelDescriptor) throws -> URL {
        guard model.id.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil else {
            throw BoneLocalModelStoreError.invalidModelID
        }
        guard model.artifact.fileName == URL(fileURLWithPath: model.artifact.fileName).lastPathComponent else {
            throw BoneLocalModelStoreError.invalidArtifactFileName
        }
        return rootURL.appendingPathComponent(model.id, isDirectory: true)
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
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
