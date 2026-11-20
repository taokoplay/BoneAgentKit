import Foundation

/// One App-owned private snapshot. Actor serialization covers this App instance only.
actor DemoConversationArchiveStore {
    static let maximumArchiveBytes = 64 * 1_048_576
    private let directory: URL
    nonisolated let fileURL: URL

    init(directory: URL) {
        self.directory = directory
        fileURL = directory.appendingPathComponent("conversation-private-v1.json", isDirectory: false)
    }

    func load(bindingID: String) throws -> DemoConversationArchive? {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw DemoConversationStorageError.invalidArchive
            }
            guard let size = values.fileSize, size <= Self.maximumArchiveBytes else {
                throw DemoConversationStorageError.tooLarge
            }
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            guard data.count <= Self.maximumArchiveBytes else { throw DemoConversationStorageError.tooLarge }
            let archive: DemoConversationArchive
            do { archive = try JSONDecoder().decode(DemoConversationArchive.self, from: data) }
            catch { throw DemoConversationStorageError.invalidArchive }
            try archive.validated()
            guard archive.bindingID == bindingID else { throw DemoConversationStorageError.bindingMismatch }
            return archive
        } catch let error as DemoConversationStorageError { throw error }
        catch { throw DemoConversationStorageError.unavailable }
    }

    func save(_ archive: DemoConversationArchive) throws {
        try Task.checkCancellation()
        try archive.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(archive)
        guard data.count <= Self.maximumArchiveBytes else { throw DemoConversationStorageError.tooLarge }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let root = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard root.isDirectory == true, root.isSymbolicLink != true else {
                throw DemoConversationStorageError.invalidArchive
            }
            if FileManager.default.fileExists(atPath: fileURL.path),
               try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw DemoConversationStorageError.invalidArchive
            }
            #if os(iOS)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: fileURL, options: .atomic)
            #endif
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            var location = directory
            var flags = URLResourceValues()
            flags.isExcludedFromBackup = true
            try location.setResourceValues(flags)
        } catch let error as DemoConversationStorageError { throw error }
        catch { throw DemoConversationStorageError.unavailable }
    }

    func clear() throws {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory != true else { throw DemoConversationStorageError.invalidArchive }
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as DemoConversationStorageError { throw error }
        catch { throw DemoConversationStorageError.unavailable }
    }
}
