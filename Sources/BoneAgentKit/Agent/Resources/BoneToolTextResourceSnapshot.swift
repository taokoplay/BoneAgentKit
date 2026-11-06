import Foundation

/// 可选的内存文本快照辅助器；不落盘、不索引、不授权，也不自动注册给 Agent。
/// 构造时复制完整 UTF-8 字节，适用于 Host 已在内存取得的文本；大存储可自行分页实现 Reader。
public struct BoneToolTextResourceSnapshot: Sendable {
    public let reference: BoneToolTextResourceReference
    private let bytes: Data

    public init(id: String, version: String, text: String) throws {
        let reference = try BoneToolTextResourceReference(id: id, version: version, utf8ByteCount: text.utf8.count)
        self.reference = reference
        bytes = Data(text.utf8)
    }

    /// 构造最多 maximumBytes 字节的真实前缀。零上限允许只暴露引用，完整内容不在预览中。
    /// 不切断 Unicode scalar；组合字符/emoji 序列可能跨页，但合并后原始字节完全相同。
    public func preview(maximumBytes: Int = 1_024) throws -> BoneToolTextResourcePreview {
        guard (0...BoneToolTextResourcePreview.maximumTextBytes).contains(maximumBytes) else {
            throw BoneToolTextResourceError.invalidPreview
        }
        let end = scalarBoundary(atOrBefore: min(bytes.count, maximumBytes))
        return try .init(reference: reference, text: text(in: 0..<end))
    }

    /// Host 应在授权、有效期和 scope 复核后调用；不接受别的版本或 UTF-8 字符内部偏移。
    public func page(for request: BoneToolTextResourceReadRequest) throws -> BoneToolTextResourcePage {
        guard request.reference == reference else { throw BoneToolTextResourceError.referenceMismatch }
        guard isScalarBoundary(request.offset) else { throw BoneToolTextResourceError.invalidOffset }
        // request 已验证 offset <= count；先取剩余额度，再相加以避免溢出。
        let end = scalarBoundary(atOrBefore: request.offset + min(request.maximumBytes, bytes.count - request.offset))
        return try .init(reference: reference, offset: request.offset, text: text(in: request.offset..<end))
    }

    private func isScalarBoundary(_ offset: Int) -> Bool {
        offset == bytes.count || bytes[offset] & 0xC0 != 0x80
    }

    private func scalarBoundary(atOrBefore end: Int) -> Int {
        var boundary = end
        while boundary > 0, !isScalarBoundary(boundary) { boundary -= 1 }
        return boundary
    }

    private func text(in range: Range<Int>) -> String {
        // bytes 来自合法 String，range 两端已按 scalar 对齐；不能用会吞页首 BOM 的 Foundation 解码。
        // 这里的 UTF-8 序列必然有效，不会触发替换字符修复。
        String(decoding: bytes[range], as: UTF8.self)
    }
}
