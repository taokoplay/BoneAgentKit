import Foundation

/// iOS 13.0-compatible, error-reporting FileHandle operations.
/// The Swift read(upToCount:)/write(contentsOf:) overlays require iOS 13.4.
/// These NS_REFINED_FOR_SWIFT Foundation entry points are available on iOS 13.0
/// and import NSError as throws; the legacy readData/write APIs can raise ObjC
/// exceptions instead. Keep the bridge isolated and covered by the iOS 13 gate.
enum BoneLocalModelFileIO {
    static func read(upToCount count: Int, from handle: FileHandle) throws -> Data? {
        try handle.__readDataUp(toLength: count)
    }

    static func write(_ data: Data, to handle: FileHandle) throws {
        try handle.__write(data, error: ())
    }
}
