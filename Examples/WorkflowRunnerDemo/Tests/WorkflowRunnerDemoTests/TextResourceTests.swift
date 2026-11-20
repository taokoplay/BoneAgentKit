import Foundation
import Testing
import BoneAgentKit
import BoneAgentTools
@testable import WorkflowRunnerDemo

struct TextResourceTests: Sendable {

    /// 无入参；验证超限导入失败不会修改已有小附件的存档字节或引用。
    @Test func rejectedLargeTextLeavesExistingArchiveUnchanged() async throws {
        // 小附件存储与基准存档，代表导入前已经可恢复的状态。
        let store = DemoTextResourceStore()
        let original = try await store.add(name: "保留.txt", text: "原始小附件🙂")
        let archive = try await store.exportPrivateState()
        // 超过旧存档单份上限一个字节，禁止扩大旧格式以容纳长正文。
        let oversized = String(repeating: "a", count: DemoTextResourceStore.maximumResourceBytes + 1)
        await #expect(throws: DemoTextResourceStoreError.resourceTooLarge) {
            try await store.add(name: "超限.txt", text: oversized)
        }
        #expect(await store.entries() == [original])
        #expect(try await store.exportPrivateState() == archive)
        // 从原存档恢复，确认失败导入没有影响既有恢复路径。
        let restored = try DemoTextResourceStore(privateState: archive)
        #expect(try await restored.readText(.init(reference: original.preview.reference)).text == "原始小附件🙂")
    }

    /// 无入参；验证尾部命中可直接按偏移回读，并在删除后复核列表、搜索和读取权限。
    @Test func tailSearchHitReadsDirectlyAndRetainedToolsObserveRemoval() async throws {
        // 使用接近小附件上限的 Unicode 原文，避免命中落在首段。
        let store = DemoTextResourceStore()
        let prefix = String(repeating: "中🙂\n", count: 60_000)
        let entry = try await store.add(name: "尾部.txt", text: prefix + "唯一尾部标记")
        let access = DemoTextResourceAccess()
        await access.allow([entry.preview.reference])
        // 工具在撤销前创建，之后不得继续访问被删除的快照。
        let tools = store.makeQueryTools(access: access)
        let search = try #require(tools.first { $0.definition.id == "resource.search" })
        let list = try #require(tools.first { $0.definition.id == "resource.list" })
        let reader = store.makeReader(access: access)
        let query = try JSONEncoder().encode(BoneTextResourceSearchRequest(query: "唯一尾部标记"))
        let result = try JSONDecoder().decode(BoneTextResourceSearchResult.self,
            from: await search.execute(input: query, context: BoneAgentEmptyContext()))
        let hit = try #require(result.hits.first)
        #expect(!result.isTruncated)
        #expect(hit.matchOffset == prefix.utf8.count)
        // 只请求命中片段起点；不把字节偏移转换为页码后从头扫描。
        let page = try await reader.read(.init(reference: hit.resource.reference,
            offset: hit.snippetOffset, maximumBytes: 2_048), context: BoneAgentEmptyContext())
        #expect(page.offset == hit.snippetOffset)
        #expect(page.text.contains("唯一尾部标记"))
        await store.remove(id: entry.id)
        await #expect(throws: BoneToolTextResourceError.unavailable) {
            try await reader.read(.init(reference: hit.resource.reference, offset: hit.snippetOffset),
                                  context: BoneAgentEmptyContext())
        }
        // 删除后的查询必须重新使用当前注册集合，不能复用旧结果作为授权。
        let after = try JSONDecoder().decode(BoneTextResourceSearchResult.self,
            from: await search.execute(input: query, context: BoneAgentEmptyContext()))
        let listed = try JSONDecoder().decode(BoneTextResourceListResult.self,
            from: await list.execute(input: JSONEncoder().encode(BoneTextResourceListRequest()), context: BoneAgentEmptyContext()))
        #expect(after.hits.isEmpty && !after.isTruncated)
        #expect(listed.resources.isEmpty)
    }

    /// 无入参；验证真实大文件的导入、保存冲突、查询隔离、命中扩读与续页读取成本。
    @Test func diskImportSearchReadAndPersistenceAreSessionScoped() async throws {
        // 真实磁盘输入使用分块写入，避免测试把大正文同时保存在内存。
        let url = try Self.diskFixture(bytes: 600_000, suffix: "唯一磁盘尾部🙂")
        defer { try? FileManager.default.removeItem(at: url) }
        let audit = ReadAudit()
        let store = DemoTextResourceStore(observeRead: { audit.append($0) })
        let small = try await store.add(name: "旧附件", text: "保留旧存档")
        let archived = try await store.exportPrivateState()
        await #expect(throws: DemoTextResourceStoreError.largeResourceCannotBeSaved) {
            try await store.add(importing: url, preservesConversation: true)
        }
        #expect(try await store.exportPrivateState() == archived)
        let imported = try await store.add(importing: url, preservesConversation: false)
        #expect(imported.isDiskBacked && imported.utf8ByteCount == 600_000)
        #expect(imported.preview.text.utf8.count <= 1_024)
        await #expect(throws: DemoTextResourceStoreError.largeResourceCannotBeSaved) {
            try await store.exportPrivateState()
        }
        await #expect(throws: DemoTextResourceStoreError.largeResourceCannotBeSaved) {
            try await store.validatePersistence(preservesConversation: true)
        }
        try await store.validatePersistence(preservesConversation: false)
        // 修改原文件后，已导入资源仍指向私有快照版本。
        try Data("changed source".utf8).write(to: url)
        let access = DemoTextResourceAccess()
        let tools = store.makeQueryTools(access: access)
        let list = try #require(tools.first { $0.definition.id == "resource.list" })
        let search = try #require(tools.first { $0.definition.id == "resource.search" })
        let query = try JSONEncoder().encode(BoneTextResourceSearchRequest(query: "唯一磁盘尾部"))
        let hidden = try JSONDecoder().decode(BoneTextResourceSearchResult.self,
            from: await search.execute(input: query, context: BoneAgentEmptyContext()))
        #expect(hidden.hits.isEmpty)
        await access.allow([imported.preview.reference])
        let listed = try JSONDecoder().decode(BoneTextResourceListResult.self,
            from: await list.execute(input: JSONEncoder().encode(BoneTextResourceListRequest()), context: BoneAgentEmptyContext()))
        #expect(listed.resources.map(\.reference) == [imported.preview.reference])
        let partial = try await store.search(.init(query: "唯一磁盘尾部"), maximumScanBytes: 1_024)
        #expect(partial.hits.isEmpty && partial.isTruncated)
        let result = try JSONDecoder().decode(BoneTextResourceSearchResult.self,
            from: await search.execute(input: query, context: BoneAgentEmptyContext()))
        let hit = try #require(result.hits.first)
        #expect(!result.isTruncated && hit.matchOffset > 590_000)
        // 同一个模型工具可从搜索原始匹配偏移直接扩读，无需换算页码。
        let tool = DemoResourcePageTool(store: store, access: access)
        let input = try DemoResourcePageInput(resourceID: imported.id, offset: hit.matchOffset)
        try BoneToolSchemaValidator.validate(arguments: JSONEncoder().encode(input),
            against: #require(DemoResourcePageTool.definition.inputSchema))
        let tail = try await tool.execute(input: input, context: .init())
        #expect(tail.text == "唯一磁盘尾部🙂")
        #expect(audit.offsets == [hit.matchOffset])
        // firstRead 保持原来两字段契约；每次 nextRead 只增加一次实际页读取。
        let first = try await tool.execute(input: .init(resourceID: imported.id), context: .init())
        let next = try #require(first.nextRead)
        let second = try await tool.execute(input: next, context: .init())
        #expect(audit.offsets == [hit.matchOffset, 0, first.nextOffset!])
        #expect(second.offset == first.nextOffset)
        // 授权撤销后，已存在的分页工具和查询闭包都必须拒绝/隐藏该资源。
        await access.revoke(id: imported.id)
        await #expect(throws: BoneToolTextResourceError.accessDenied) {
            try await tool.execute(input: input, context: .init())
        }
        let revoked = try JSONDecoder().decode(BoneTextResourceSearchResult.self,
            from: await search.execute(input: query, context: BoneAgentEmptyContext()))
        #expect(revoked.hits.isEmpty)
        await access.allow([imported.preview.reference])
        await store.remove(id: imported.id)
        await #expect(throws: BoneToolTextResourceError.unavailable) {
            try await tool.execute(input: input, context: .init())
        }
        #expect(await store.entries() == [small])
        #expect(try await store.exportPrivateState() == archived)
    }

    /// 无入参；验证上限文件真实落盘可导入并直接读取末端，超限文件不污染已导入资源。
    @Test func diskMaximumAndSmallFileImportKeepSeparateStorage() async throws {
        let maximum = DemoTextResourceStore.maximumDiskResourceBytes
        let url = try Self.diskFixture(bytes: maximum, suffix: "END🙂")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DemoTextResourceStore()
        let item = try await store.add(importing: url, preservesConversation: false)
        let page = try await store.readText(.init(reference: item.preview.reference,
            offset: maximum - "END🙂".utf8.count, maximumBytes: 16))
        #expect(page.text == "END🙂" && page.nextOffset == nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0x61])); try handle.close()
        await #expect(throws: BoneDiskTextResourceError.capacityExceeded) {
            try await store.add(importing: url, preservesConversation: false)
        }
        #expect(await store.entries() == [item])
        await store.clear()
        // 小文件即使通过文件入口导入，也保持可恢复的旧存档。
        try Data("小文件🙂".utf8).write(to: url)
        let small = try await store.add(importing: url, preservesConversation: true)
        #expect(!small.isDiskBacked)
        let restored = try DemoTextResourceStore(privateState: await store.exportPrivateState())
        #expect(try await restored.readText(.init(reference: small.preview.reference)).text == "小文件🙂")
    }

    /// 写入指定字节总量及 UTF-8 尾部；返回测试临时路径，调用者负责删除源文件。
    private static func diskFixture(bytes: Int, suffix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let block = Data(repeating: 0x61, count: 65_536)
        var remaining = bytes - suffix.utf8.count
        while remaining > 0 {
            let count = min(remaining, block.count)
            try handle.write(contentsOf: block.prefix(count)); remaining -= count
        }
        try handle.write(contentsOf: Data(suffix.utf8))
        return url
    }

    /// 同步读取审计；锁保护跨 actor 回调，输出只含 offset，不保留私有正文。
    private final class ReadAudit: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func append(_ offset: Int) { lock.lock(); defer { lock.unlock() }; values.append(offset) }
        var offsets: [Int] { lock.lock(); defer { lock.unlock() }; return values }
    }

    @Test
    func unicodePagesAndPreviewRetainExactUTF8ThroughSDKTool() async throws {
        let text = "\u{FEFF}" + String(repeating: "中🙂e\u{301}👨‍👩‍👧‍👦\r\n", count: 90)
        let store = DemoTextResourceStore()
        let entry = try await store.add(name: "Unicode", text: text)
        #expect(UUID(uuidString: entry.id) != nil)
        #expect(UUID(uuidString: entry.preview.reference.version) != nil)
        #expect(entry.utf8ByteCount == text.utf8.count)
        #expect(entry.preview.isTruncated)
        #expect(entry.preview.text.utf8.count <= DemoTextResourceStore.previewBytes)
        #expect(Data(text.utf8).starts(with: Data(entry.preview.text.utf8)))
        #expect(entry.preview.nextOffset == entry.preview.text.utf8.count)

        let tool = store.makeReadTool()
        #expect(tool.definition.id == "resource.readText")
        let registry = try BoneAgentToolRegistry(tools: [tool, BoneAnyAgentTool(DemoCalculatorTool())])
        _ = registry
        var offset = 0
        var assembled = Data()
        repeat {
            let request = try BoneToolTextResourceReadRequest(reference: entry.preview.reference, offset: offset, maximumBytes: 7)
            let result = try await tool.execute(input: JSONEncoder().encode(request), context: BoneAgentEmptyContext())
            let page = try JSONDecoder().decode(BoneToolTextResourcePage.self, from: result)
            #expect(page.offset == offset)
            #expect(page.text.utf8.count <= 7)
            assembled.append(contentsOf: page.text.utf8)
            guard let next = page.nextOffset else { break }
            #expect(next > offset)
            #expect(next == offset + page.text.utf8.count)
            offset = next
        } while true
        #expect(assembled == Data(text.utf8))
        #expect(!String(decoding: assembled, as: UTF8.self).contains("\u{FFFD}"))
    }

    @Test
    func tamperedUnknownAndInsideScalarReferencesFail() async throws {
        let store = DemoTextResourceStore()
        let entry = try await store.add(name: "注册文本", text: "中🙂abc")
        let reference = entry.preview.reference
        let reader = store.makeReader()
        let tampered = [
            try BoneToolTextResourceReference(id: reference.id, version: UUID().uuidString, utf8ByteCount: reference.utf8ByteCount),
            try BoneToolTextResourceReference(id: reference.id, version: reference.version, utf8ByteCount: reference.utf8ByteCount + 1)
        ]
        for reference in tampered {
            do {
                _ = try await reader.read(.init(reference: reference), context: BoneAgentEmptyContext())
                Issue.record("Tampered reference unexpectedly resolved")
            } catch {
                #expect(error as? BoneToolTextResourceError == .referenceMismatch)
            }
        }
        let unknown = try BoneToolTextResourceReference(id: UUID().uuidString, version: UUID().uuidString, utf8ByteCount: 0)
        do {
            _ = try await reader.read(.init(reference: unknown), context: BoneAgentEmptyContext())
            Issue.record("Unknown reference unexpectedly resolved")
        } catch { #expect(error as? BoneToolTextResourceError == .unavailable) }
        do {
            _ = try await reader.read(.init(reference: reference, offset: 1), context: BoneAgentEmptyContext())
            Issue.record("A byte offset inside a scalar unexpectedly succeeded")
        } catch { #expect(error as? BoneToolTextResourceError == .invalidOffset) }
    }

    @Test
    func existingReaderAndToolCannotReadRemovedResources() async throws {
        let store = DemoTextResourceStore()
        let first = try await store.add(name: "一", text: "first")
        let second = try await store.add(name: "二", text: "second")
        let reader = store.makeReader()
        let tool = store.makeReadTool()
        await store.remove(id: first.id)
        do {
            _ = try await reader.read(.init(reference: first.preview.reference), context: BoneAgentEmptyContext())
            Issue.record("Removed resource unexpectedly resolved")
        } catch { #expect(error as? BoneToolTextResourceError == .unavailable) }
        let secondPage = try await reader.read(.init(reference: second.preview.reference), context: BoneAgentEmptyContext())
        #expect(secondPage.text == "second")
        await store.clear()
        #expect(await store.entries().isEmpty)
        do {
            let request = try BoneToolTextResourceReadRequest(reference: second.preview.reference)
            _ = try await tool.execute(input: JSONEncoder().encode(request), context: BoneAgentEmptyContext())
            Issue.record("Cleared resource unexpectedly resolved through retained tool")
        } catch { #expect(error as? BoneToolTextResourceError == .unavailable) }
        let replacement = try await store.add(name: "二", text: "second")
        #expect(replacement.id != second.id)
    }

    @Test
    func exactCapacityAndPerResourceLimitAreEnforced() async throws {
        let store = DemoTextResourceStore()
        let exact = String(repeating: "x", count: DemoTextResourceStore.maximumResourceBytes)
        do {
            _ = try await store.add(name: "oversized", text: exact + "x")
            Issue.record("Oversized resource unexpectedly accepted")
        } catch { #expect(error as? DemoTextResourceStoreError == .resourceTooLarge) }
        for index in 0..<DemoTextResourceStore.maximumResources {
            try await store.add(name: "\(index)", text: exact)
        }
        let entries = await store.entries()
        #expect(entries.count == 4)
        #expect(entries.reduce(0) { $0 + $1.utf8ByteCount } == DemoTextResourceStore.maximumTotalBytes)
        do {
            _ = try await store.add(name: "fifth", text: "")
            Issue.record("A fifth resource unexpectedly accepted")
        } catch { #expect(error as? DemoTextResourceStoreError == .capacityReached) }
        let data = try await store.exportPrivateState()
        let restored = try DemoTextResourceStore(privateState: data)
        #expect(await restored.entries() == entries)
        #expect(try await restored.exportPrivateState() == data)
    }

    @Test
    func privateRestorePreservesReferencesBOMAndNonNormalizedText() async throws {
        let text = "\u{FEFF}e\u{301}\r\n\u{0}🙂\u{FEFF}"
        let store = DemoTextResourceStore()
        let original = try await store.add(name: "原始字节", text: text)
        let exported = try await store.exportPrivateState()
        let restored = try DemoTextResourceStore(privateState: exported)
        #expect(await restored.entries() == [original])
        let page = try await restored.makeReader().read(.init(reference: original.preview.reference), context: BoneAgentEmptyContext())
        #expect(Data(page.text.utf8) == Data(text.utf8))
        #expect(try await restored.exportPrivateState() == exported)
    }

    @Test
    func boundedPrivateRestoreRejectsMalformedSnapshots() async throws {
        let store = DemoTextResourceStore()
        try await store.add(name: "private", text: "abc")
        let data = try await store.exportPrivateState()
        let base = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let resource = try #require((base["resources"] as? [[String: Any]])?.first)
        let reference = try #require(resource["reference"] as? [String: Any])
        var invalid: [Data] = [Data("not JSON".utf8), Data(count: DemoTextResourceStore.maximumPrivateStateBytes + 1)]
        for count in [3, 5] {
            var object = base
            object["resources"] = Array(repeating: resource, count: count)
            invalid.append(try JSONSerialization.data(withJSONObject: object))
        }
        var wrongVersion = base
        wrongVersion["formatVersion"] = 2
        invalid.append(try JSONSerialization.data(withJSONObject: wrongVersion))
        let mutations: [(String, Any)] = [
            ("name", String(repeating: "n", count: 257)),
            ("utf8", Data([0xff, 0xfe, 0xfd]).base64EncodedString()),
            ("utf8", Data(repeating: 0x78, count: DemoTextResourceStore.maximumResourceBytes + 1).base64EncodedString())
        ]
        for (key, value) in mutations {
            var changed = resource
            changed[key] = value
            var object = base
            object["resources"] = [changed]
            invalid.append(try JSONSerialization.data(withJSONObject: object))
        }
        for (key, value): (String, Any) in [("utf8ByteCount", 4), ("id", "file_path"), ("version", "https://invalid")] {
            var changedReference = reference
            changedReference[key] = value
            var changed = resource
            changed["reference"] = changedReference
            var object = base
            object["resources"] = [changed]
            invalid.append(try JSONSerialization.data(withJSONObject: object))
        }
        for encoded in invalid {
            do {
                _ = try DemoTextResourceStore(privateState: encoded)
                Issue.record("Invalid private snapshot unexpectedly restored")
            } catch { #expect(error as? DemoTextResourceStoreError == .invalidPrivateState) }
        }
    }

    @Test
    func cancellationBeforeReadDoesNotReturnText() async throws {
        let store = DemoTextResourceStore()
        let entry = try await store.add(name: "cancel", text: "private text")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.makeReader().read(.init(reference: entry.preview.reference), context: BoneAgentEmptyContext())
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled read unexpectedly returned text")
        } catch { #expect(error is CancellationError) }
    }
}
