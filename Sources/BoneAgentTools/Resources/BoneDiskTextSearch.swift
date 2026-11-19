import Foundation
import BoneAgentKit

extension BoneDiskTextResource {
    /// 从文件开头执行区分大小写的 UTF-8 字节字面搜索，返回不重叠的命中。
    /// 不进行 Unicode 大小写折叠或规范化；中文、emoji、组合字符均按原始字节匹配。
    /// - Parameters:
    ///   - request: 查询字面量（最多 1,024 字节）与结果数量上限。
    ///   - maximumScanBytes: 可参与匹配的文件前缀最大字节数，零表示不扫描。
    ///     定位长文件末端时，Host 必须显式提供覆盖目标位置的预算；不隐式跳到末尾。
    /// - Returns: 原始字节偏移与有界摘要；未扫描完全文或遗漏命中时 isTruncated 为 true。
    /// 扫描页不超过 64 KiB，仅保留 query.count - 1 字节衔接跨页匹配，不按行读取。
    /// read 的最小页为 4 字节，因此最后一页可能额外读取至多 3 字节，但不参与匹配。
    /// 摘要复用已扫描字节，不增加磁盘读取；单条最多 2 KiB，合计最多 32 KiB。
    public func search(
        _ request: BoneTextResourceSearchRequest,
        maximumScanBytes: Int
    ) throws -> BoneTextResourceSearchResult {
        _ = try request.validated()
        guard maximumScanBytes >= 0 else { throw BoneResourceQueryError.invalidRequest }
        try Task.checkCancellation()
        // 查询的原始 UTF-8 表示；非空由请求校验保证。
        let needle = Data(request.query.utf8)
        // 扫描截止位置采用减法预算推进，允许 Int.max 且避免偏移相加溢出。
        let scanEnd = min(maximumScanBytes, descriptor.reference.utf8ByteCount)
        // 已消费的文件前缀长度；始终位于 read 返回的 scalar 边界，最后一页除外。
        var offset = 0
        // 上一页尾部最多 query.count - 1 个字节，可能从 scalar 中间开始。
        var carry = Data()
        // 下一条非重叠命中允许的最小绝对字节偏移，防止跨页重报。
        var nextMatchOffset = 0
        // 返回命中与累计摘要费用；与 DTO 上限保持一致。
        var hits: [BoneTextResourceSearchHit] = []
        var snippetBytes = 0

        while offset < scanEnd {
            try Task.checkCancellation()
            // read 的 API 最小页为 4 字节，多读部分随后裁掉，不计入匹配窗口。
            let page = try read(.init(
                reference: descriptor.reference, offset: offset,
                maximumBytes: max(4, min(65_536, scanEnd - offset))
            ))
            // 当前页被预算允许的原始字节，可能在预算截止处切断最后一个 scalar。
            let bytes = Data(page.text.utf8.prefix(scanEnd - offset))
            guard !bytes.isEmpty else { throw BoneToolTextResourceError.invalidPage }
            // 拼接小尾部与新页，绝对基址由旧 offset 扣除尾部长度得到。
            let base = offset - carry.count
            var window = carry
            window.append(bytes)
            offset += bytes.count
            // 窗口内游标至少跳过已报告命中的末端。
            var cursor = max(0, nextMatchOffset - base)

            while cursor < window.count,
                  let match = window.range(of: needle, in: cursor..<window.count) {
                try Task.checkCancellation()
                // 找到额外命中才认定结果数量截断，刚好等于上限仍可证明扫描完整。
                guard hits.count < request.limit else {
                    return .init(hits: hits, isTruncated: true)
                }
                // 摘要从命中开头截取已扫描原文，完整包含查询，且不超过剩余输出费用。
                var end = min(window.count, match.lowerBound + 2_048)
                // UTF-8 尾部修剪只检查最多四个字节，不逐字节扫描全文。
                if end < window.count {
                    while end > match.upperBound, window[end] & 0xC0 == 0x80 { end -= 1 }
                }
                // 预算可能截在 scalar 内；严格解码失败时最多回退三个尾字节。
                var snippet = String(bytes: window[match.lowerBound..<end], encoding: .utf8)
                while snippet == nil, end > match.upperBound {
                    end -= 1
                    snippet = String(bytes: window[match.lowerBound..<end], encoding: .utf8)
                }
                guard snippet != nil else { throw BoneToolTextResourceError.invalidPage }
                // Foundation 严格解码只用于合法性检查；实际正文解码保留页首 BOM。
                let originalSnippet = String(decoding: window[match.lowerBound..<end], as: UTF8.self)
                guard end - match.lowerBound <= 32_768 - snippetBytes else {
                    return .init(hits: hits, isTruncated: true)
                }
                hits.append(try .init(
                    resource: descriptor, matchOffset: base + match.lowerBound,
                    snippetOffset: base + match.lowerBound, snippet: originalSnippet
                ))
                snippetBytes += end - match.lowerBound
                cursor = match.upperBound
                nextMatchOffset = base + cursor
            }
            carry = Data(window.suffix(needle.count - 1))
        }
        try Task.checkCancellation()
        return .init(hits: hits, isTruncated: scanEnd < descriptor.reference.utf8ByteCount)
    }
}
