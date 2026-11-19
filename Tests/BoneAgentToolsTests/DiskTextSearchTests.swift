import Foundation
import Testing
import BoneAgentKit
@testable import BoneAgentTools

struct DiskTextSearchTests {
    /// 长单行随机回读仍严格受页大小约束。
    @Test func readsDiskTextWithoutReadingAnEntireLine() throws {
        let text = String(repeating: "x", count: 120_000) + "needle" + String(repeating: "y", count: 120_000)
        let resource = try makeResource(text)
        defer { remove(resource.url) }

        let disk = try BoneDiskTextResource(importing: resource.url, name: "长行")
        let page = try disk.read(.init(reference: disk.descriptor.reference, offset: 120_000, maximumBytes: 64))

        #expect(page.text.hasPrefix("needle"))
        #expect(page.text.utf8.count <= 64)
    }

    /// 查询横跨 64 KiB 块边界，返回原始绝对字节偏移。
    @Test func findsMatchesAcrossDiskBlocksAndReportsByteOffsets() throws {
        let text = String(repeating: "a", count: 65_535) + "needle" + " tail"
        let resource = try makeResource(text)
        defer { remove(resource.url) }

        let disk = try BoneDiskTextResource(importing: resource.url, name: "跨块")
        let result = try disk.search(.init(query: "needle"), maximumScanBytes: text.utf8.count)

        #expect(!result.isTruncated)
        #expect(result.hits.map(\.matchOffset) == [65_535])
        #expect(result.hits.first?.snippet == "needle tail")
    }

    /// ASCII 大小写与非 ASCII 字符均保持精确字节匹配。
    @Test func matchesUtf8BytesWithoutCaseOrNormalizationFolding() throws {
        let text = "Ä a A α À"
        let resource = try makeResource(text)
        defer { remove(resource.url) }

        let disk = try BoneDiskTextResource(importing: resource.url, name: "字节")
        let result = try disk.search(.init(query: "a"), maximumScanBytes: text.utf8.count)

        #expect(result.hits.count == 1)
        #expect(result.hits.allSatisfy { $0.snippet.first == "a" })
    }

    /// 未覆盖全文与遗漏额外命中分别产生截断标记。
    @Test func marksBudgetAndResultLimitAsTruncated() throws {
        let text = "prefix needle suffix"
        let resource = try makeResource(text)
        defer { remove(resource.url) }

        let disk = try BoneDiskTextResource(importing: resource.url, name: "预算")
        let budgetResult = try disk.search(.init(query: "needle"), maximumScanBytes: 7)
        let limitedResult = try disk.search(.init(query: "e", limit: 1), maximumScanBytes: text.utf8.count)
        let completeResult = try disk.search(.init(query: "needle"), maximumScanBytes: text.utf8.count)

        #expect(budgetResult.hits.isEmpty && budgetResult.isTruncated)
        #expect(limitedResult.hits.count == 1 && limitedResult.isTruncated)
        #expect(completeResult.hits.count == 1 && !completeResult.isTruncated)
    }

    /// 在同一任务内部取消，避免外部 cancel 与搜索完成之间的竞态。
    @Test func cancellationIsPropagatedBeforeScanning() async throws {
        let resource = try makeResource(String(repeating: "needle ", count: 100_000))
        defer { remove(resource.url) }
        let disk = try BoneDiskTextResource(importing: resource.url, name: "取消")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try disk.search(.init(query: "needle"), maximumScanBytes: resource.text.utf8.count)
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    /// 在真实 pread 完成时取消当前任务，验证扫描进行中取消不会被转为空结果。
    @Test func cancellationDuringDiskReadPropagates() async throws {
        let resource = try makeResource(String(repeating: "z", count: 150_000))
        defer { remove(resource.url) }
        let disk = try BoneDiskTextResource(importing: resource.url, name: "扫描中取消",
            maximumBytes: 1_048_576, observeRead: { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
            })
        let task = Task {
            try disk.search(.init(query: "missing"), maximumScanBytes: Int.max)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 负预算在访问文件前被拒绝。
    @Test func rejectsNegativeScanBudget() throws {
        let resource = try makeResource("text")
        defer { remove(resource.url) }
        let disk = try BoneDiskTextResource(importing: resource.url, name: "非法预算")

        #expect(throws: BoneResourceQueryError.invalidRequest) {
            _ = try disk.search(.init(query: "text"), maximumScanBytes: -1)
        }
    }

    /// 查询跨页且以组合字符的一部分结束时，按 UTF-8 前缀验证。
    @Test func unicodeQueriesSpanBlocksAndKeepExactOriginalSnippets() throws {
        let text = String(repeating: "z", count: 65_533) + "中🙂文\u{301}尾巴"
        let resource = try makeResource(text)
        defer { remove(resource.url) }
        let disk = try BoneDiskTextResource(importing: resource.url, name: "跨块中文")
        for query in ["中🙂文", "🙂文\u{301}", "文\u{301}尾"] {
            let result = try disk.search(.init(query: query), maximumScanBytes: Int.max)
            let hit = try #require(result.hits.first)
            let original = Data(text.utf8)
            #expect(result.hits.count == 1 && !result.isTruncated)
            #expect(hit.snippet.utf8.starts(with: query.utf8))
            #expect(Data(hit.snippet.utf8) == original.subdata(in: hit.snippetOffset..<(hit.snippetOffset + hit.snippet.utf8.count)))
            _ = try result.validated(for: .init(query: query))
        }
    }

    /// 预算切入 emoji 或中文 scalar 时不构造替换字符或虚假命中。
    @Test func budgetsInsideScalarsNeverInventMatchesOrReplacementCharacters() throws {
        let resource = try makeResource("a🙂中tail")
        defer { remove(resource.url) }
        let disk = try BoneDiskTextResource(importing: resource.url, name: "scalar预算")
        for budget in 0...7 {
            let result = try disk.search(.init(query: "🙂"), maximumScanBytes: budget)
            #expect(result.isTruncated)
            #expect(result.hits.count == (budget >= 5 ? 1 : 0))
            #expect(result.hits.allSatisfy { !$0.snippet.contains("�") })
        }
    }

    /// 一至三字节文件、空文件及末尾 ASCII 均可完成全量扫描。
    @Test func findsShortFilesAndTailMatchesWithinSmallBudgets() throws {
        for text in ["a", "ab", "abc", "🙂a", "中", ""] {
            let resource = try makeResource(text)
            defer { remove(resource.url) }
            let disk = try BoneDiskTextResource(importing: resource.url, name: "短文件")
            let result = try disk.search(.init(query: "a"), maximumScanBytes: text.utf8.count)
            #expect(!result.isTruncated)
            #expect(result.hits.count == (text.contains("a") ? 1 : 0))
        }
    }

    /// BOM、NUL、正则标点和换行均保留原始字节含义。
    @Test func preservesBomNullBytesAndLiteralPunctuation() throws {
        let text = "\u{FEFF}A\0B.*[x]\n末"
        let resource = try makeResource(text)
        defer { remove(resource.url) }
        let disk = try BoneDiskTextResource(importing: resource.url, name: "字面量")
        for query in ["\u{FEFF}A", "\0B", ".*[x]\n"] {
            let result = try disk.search(.init(query: query), maximumScanBytes: Int.max)
            let hit = try #require(result.hits.first)
            #expect(hit.snippet.utf8.starts(with: query.utf8))
            #expect(Data(hit.snippet.utf8) == Data(text.utf8).subdata(in: hit.snippetOffset..<(hit.snippetOffset + hit.snippet.utf8.count)))
        }
    }

    /// 规范等价文本、非 ASCII 大小写与展开形式互不替代。
    @Test func unicodeCanonicalAndCaseVariantsRemainDistinct() throws {
        let resource = try makeResource("é É e\u{301} Ä ä ß ss")
        defer { remove(resource.url) }
        let disk = try BoneDiskTextResource(importing: resource.url, name: "精确Unicode")
        for query in ["é", "É", "e\u{301}", "Ä", "ä", "ß", "ss"] {
            let result = try disk.search(.init(query: query), maximumScanBytes: Int.max)
            #expect(result.hits.count == 1)
            #expect(result.hits.first?.snippet.utf8.starts(with: query.utf8) == true)
        }
    }

    /// 刚好达到结果上限而无额外命中时，保持完整结果状态。
    @Test func exactLimitAndNonoverlappingMatchesDoNotClaimTruncation() throws {
        let resource = try makeResource("aaaaa")
        defer { remove(resource.url) }
        let disk = try BoneDiskTextResource(importing: resource.url, name: "非重叠")
        let result = try disk.search(.init(query: "aa", limit: 2), maximumScanBytes: Int.max)
        #expect(result.hits.map(\.matchOffset) == [0, 2])
        #expect(!result.isTruncated)
    }

    /// 密集命中约束单条摘要与总输出费用，溢出时显式截断。
    @Test func outputCostCapAndSnippetBoundariesAreEnforced() throws {
        let text = String(repeating: "needle" + String(repeating: "中🙂", count: 400), count: 20)
        let resource = try makeResource(text)
        defer { remove(resource.url) }
        let disk = try BoneDiskTextResource(importing: resource.url, name: "输出费用")
        let result = try disk.search(.init(query: "needle", limit: 20), maximumScanBytes: Int.max)
        #expect(result.isTruncated && result.hits.count < 20)
        #expect(result.hits.reduce(0) { $0 + $1.snippet.utf8.count } <= 32_768)
        #expect(result.hits.allSatisfy { $0.snippet.utf8.count <= 2_048 && !$0.snippet.contains("�") })
        _ = try result.validated(for: .init(query: "needle", limit: 20))
    }

    /// 最长合法查询跨越块边界，重复前缀不会漏掉最终命中。
    @Test func longestQueryAndRepeatedCrossBlockPrefixesAreHandled() throws {
        let query = String(repeating: "a", count: 1_023) + "b"
        let text = String(repeating: "a", count: 66_000) + "b"
        let resource = try makeResource(text)
        defer { remove(resource.url) }
        let disk = try BoneDiskTextResource(importing: resource.url, name: "最长查询")
        let result = try disk.search(.init(query: query), maximumScanBytes: Int.max)
        #expect(result.hits.map(\.matchOffset) == [66_000 - 1_023])
        #expect(!result.isTruncated)
    }

    /// 反序列化绕过构造器的非法请求仍需在搜索入口拒绝。
    @Test func decodedInvalidRequestIsRevalidated() throws {
        let resource = try makeResource("text")
        defer { remove(resource.url) }
        let disk = try BoneDiskTextResource(importing: resource.url, name: "请求校验")
        let request = try JSONDecoder().decode(BoneTextResourceSearchRequest.self,
            from: Data(#"{"query":"","limit":100}"#.utf8))
        #expect(throws: BoneResourceQueryError.invalidRequest) {
            _ = try disk.search(request, maximumScanBytes: Int.max)
        }
    }

    /// 8 MiB 单行末端只有足够扫描预算才能定位。
    @Test func locatesEndOfLargeSingleLineOnlyWithSufficientScanBudget() throws {
        let text = String(repeating: "z", count: 8 * 1_048_576) + "TAIL🙂"
        let resource = try makeResource(text)
        defer { remove(resource.url) }
        let disk = try BoneDiskTextResource(importing: resource.url, name: "末端定位")
        let partial = try disk.search(.init(query: "TAIL🙂"), maximumScanBytes: 1_048_576)
        let complete = try disk.search(.init(query: "TAIL🙂"), maximumScanBytes: text.utf8.count)
        #expect(partial.hits.isEmpty && partial.isTruncated)
        #expect(complete.hits.map(\.matchOffset) == [8 * 1_048_576])
        #expect(!complete.isTruncated)
    }

    private struct TemporaryResource {
        // 唯一临时文件位置。
        let url: URL
        // 夹具原文，用于计算 UTF-8 扫描预算。
        let text: String
    }

    /// 将输入文本写入唯一临时文件，返回文件 URL 与原文供断言和清理使用。
    private func makeResource(_ text: String) throws -> TemporaryResource {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bone-disk-search-\(UUID().uuidString)")
        try Data(text.utf8).write(to: url, options: .atomic)
        return TemporaryResource(url: url, text: text)
    }

    /// 删除传入的临时文件；测试结束后执行，无返回值。
    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
