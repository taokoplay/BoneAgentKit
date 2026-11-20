import Foundation

enum DemoTextFileReadError: Error, Equatable, Sendable { case invalidEncoding, invalidLimit }

/// Host import helper. Metadata is only an early check; the actual read is always bounded.
enum DemoTextFileReader {
    static func readUTF8(url: URL, maximumBytes: Int = DemoTextResourceStore.maximumResourceBytes) throws -> String {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try readBounded(maximumBytes: maximumBytes) { try handle.read(upToCount: $0) }
        // Preserve a UTF-8 BOM and reject malformed sequences rather than repairing them.
        let text = String(decoding: data, as: UTF8.self)
        guard Data(text.utf8) == data else { throw DemoTextFileReadError.invalidEncoding }
        try Task.checkCancellation()
        return text
    }

    static func readBounded(maximumBytes: Int, read: (Int) throws -> Data?) throws -> Data {
        guard (1...DemoTextResourceStore.maximumResourceBytes).contains(maximumBytes) else {
            throw DemoTextFileReadError.invalidLimit
        }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let requested = min(65_536, maximumBytes + 1 - data.count)
            guard requested > 0 else { throw DemoTextResourceStoreError.resourceTooLarge }
            guard let chunk = try read(requested), !chunk.isEmpty else { return data }
            try Task.checkCancellation()
            guard chunk.count <= requested else { throw DemoTextResourceStoreError.resourceTooLarge }
            data.append(chunk)
            guard data.count <= maximumBytes else { throw DemoTextResourceStoreError.resourceTooLarge }
        }
    }
}
