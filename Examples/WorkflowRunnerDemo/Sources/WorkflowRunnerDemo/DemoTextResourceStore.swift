import Foundation
import BoneAgentKit
import BoneAgentTools

struct DemoImportedTextResource: Identifiable, Equatable, Sendable {
    let name: String
    let preview: BoneToolTextResourcePreview
    /// 大附件仅在会话内保留，不支持导出。
    var isDiskBacked: Bool { utf8ByteCount > DemoTextResourceStore.maximumResourceBytes }
    var id: String { preview.reference.id }
    var utf8ByteCount: Int { preview.reference.utf8ByteCount }
}
enum DemoTextResourceStoreError: Error, Equatable, Sendable {
    case invalidName
    case resourceTooLarge
    case capacityReached
    case invalidPrivateState
    case largeResourceCannotBeSaved
}

/// 小附件使用可恢复的内存快照，大附件使用 session 私有磁盘快照。
/// 引用不解析为路径或 URL；只有全部资源可保存时才允许导出旧私有状态。
actor DemoTextResourceStore {
    static let maximumResources = 4
    static let maximumResourceBytes = 512 * 1_024
    /// 单份磁盘快照上限；搜索每次总扫描预算同为 100 MiB。
    static let maximumDiskResourceBytes = 100 * 1_048_576
    static let maximumTotalBytes = 2 * 1_024 * 1_024
    static let maximumNameBytes = 256
    static let previewBytes = 1_024
    // The private envelope stores exact UTF-8 as base64, plus bounded names/references.
    static let maximumPrivateStateBytes = maximumTotalBytes * 2 + 16 * 1_024

    private struct PrivateResource: Codable, Sendable {
        let name: String
        let reference: BoneToolTextResourceReference
        let utf8: Data
    }

    private struct PrivateState: Codable {
        let formatVersion: Int
        let resources: [PrivateResource]
    }

    private struct Entry: Sendable {
        let stored: PrivateResource
        let snapshot: BoneToolTextResourceSnapshot
        let imported: DemoImportedTextResource
    }

    private var active: [Entry] = []
    /// 与旧存档分离的私有快照；移除最后一个引用会释放 SDK 临时文件。
    private var disks: [(resource: BoneDiskTextResource, imported: DemoImportedTextResource)] = []
    /// 页起点按完整引用绑定，只缓存整数而不缓存正文。
    private var pageOffsets: [BoneToolTextResourceReference: [Int]] = [:]

    /// 测试审计仅观察实际读取起点，不记录正文；默认宿主不启用。
    private let observeRead: (@Sendable (Int) -> Void)?

    init(observeRead: (@Sendable (Int) -> Void)? = nil) { self.observeRead = observeRead }

    init(privateState: Data) throws {
        observeRead = nil
        try Task.checkCancellation()
        guard privateState.count <= Self.maximumPrivateStateBytes else {
            throw DemoTextResourceStoreError.invalidPrivateState
        }
        let state: PrivateState
        do { state = try JSONDecoder().decode(PrivateState.self, from: privateState) }
        catch { throw DemoTextResourceStoreError.invalidPrivateState }
        guard state.formatVersion == 1, state.resources.count <= Self.maximumResources else {
            throw DemoTextResourceStoreError.invalidPrivateState
        }
        var restored: [Entry] = []
        var identifiers = Set<String>()
        var totalBytes = 0
        for resource in state.resources {
            try Task.checkCancellation()
            guard Self.isValidName(resource.name),
                  UUID(uuidString: resource.reference.id) != nil,
                  UUID(uuidString: resource.reference.version) != nil,
                  identifiers.insert(resource.reference.id).inserted,
                  resource.utf8.count <= Self.maximumResourceBytes,
                  resource.utf8.count == resource.reference.utf8ByteCount,
                  resource.utf8.count <= Self.maximumTotalBytes - totalBytes else {
                throw DemoTextResourceStoreError.invalidPrivateState
            }
            // String(decoding:) retains an initial BOM. Byte equality also rejects invalid UTF-8.
            let text = String(decoding: resource.utf8, as: UTF8.self)
            guard Data(text.utf8) == resource.utf8 else {
                throw DemoTextResourceStoreError.invalidPrivateState
            }
            let snapshot = try BoneToolTextResourceSnapshot(
                id: resource.reference.id, version: resource.reference.version, text: text
            )
            guard snapshot.reference == resource.reference else {
                throw DemoTextResourceStoreError.invalidPrivateState
            }
            let preview = try snapshot.preview(maximumBytes: Self.previewBytes)
            restored.append(.init(stored: resource, snapshot: snapshot,
                                  imported: .init(name: resource.name, preview: preview)))
            totalBytes += resource.utf8.count
        }
        try Task.checkCancellation()
        active = restored
    }

    @discardableResult
    func add(name: String, text: String) throws -> DemoImportedTextResource {
        try Task.checkCancellation()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidName(name) else { throw DemoTextResourceStoreError.invalidName }
        let byteCount = text.utf8.count
        guard byteCount <= Self.maximumResourceBytes else { throw DemoTextResourceStoreError.resourceTooLarge }
        guard active.count + disks.count < Self.maximumResources,
              byteCount <= Self.maximumTotalBytes - active.reduce(0, { $0 + $1.stored.utf8.count }) else {
            throw DemoTextResourceStoreError.capacityReached
        }
        let snapshot = try BoneToolTextResourceSnapshot(
            id: UUID().uuidString, version: UUID().uuidString, text: text
        )
        let preview = try snapshot.preview(maximumBytes: Self.previewBytes)
        let imported = DemoImportedTextResource(name: name, preview: preview)
        let stored = PrivateResource(name: name, reference: snapshot.reference, utf8: Data(text.utf8))
        try Task.checkCancellation()
        active.append(.init(stored: stored, snapshot: snapshot, imported: imported))
        return imported
    }

    func entries() -> [DemoImportedTextResource] { active.map(\.imported) + disks.map(\.imported) }

    func remove(id: String) {
        active.removeAll { $0.imported.id == id }
        disks.removeAll { $0.imported.id == id }
        pageOffsets = pageOffsets.filter { $0.key.id != id }
    }

    func clear() { active.removeAll(); disks.removeAll(); pageOffsets.removeAll() }

    /// Each read rechecks the active registration, including its version and original byte count.
    func readText(_ request: BoneToolTextResourceReadRequest) throws -> BoneToolTextResourcePage {
        try Task.checkCancellation()
        if let disk = disks.first(where: { $0.imported.id == request.reference.id }) {
            let page = try disk.resource.read(request)
            observeRead?(request.offset)
            return page
        }
        guard let entry = active.first(where: { $0.imported.id == request.reference.id }) else {
            throw BoneToolTextResourceError.unavailable
        }
        guard entry.snapshot.reference == request.reference else {
            throw BoneToolTextResourceError.referenceMismatch
        }
        let page = try entry.snapshot.page(for: request)
        observeRead?(request.offset)
        try Task.checkCancellation()
        return page
    }

    nonisolated func makeReader(access: DemoTextResourceAccess? = nil) -> BoneToolTextResourceReader<BoneAgentEmptyContext> {
        .init { [self] request, _ in
            if let access, !(await access.permits(request.reference)) { throw BoneToolTextResourceError.accessDenied }
            let page = try await readText(request)
            if let access, !(await access.permits(request.reference)) { throw BoneToolTextResourceError.accessDenied }
            return page
        }
    }

    nonisolated func makeReadTool(access: DemoTextResourceAccess? = nil, failureObserver: @escaping DemoToolFailureObserver = { _ in }) -> BoneAnyAgentTool {
        BoneAnyAgentTool(DemoDiagnosedTool(BoneToolTextResourceReadTool(reader: makeReader(access: access)), observe: failureObserver))
    }

    nonisolated func makeQueryTools(access: DemoTextResourceAccess? = nil, failureObserver: @escaping DemoToolFailureObserver = { _ in }) -> [BoneAnyAgentTool] {
        let list = BoneTextResourceListTool<BoneAgentEmptyContext> { [self] request, _ in
            let references = await access?.references()
            let result = try await list(request, allowed: references)
            if let access, Set(await access.references()) != Set(references ?? []) { throw BoneToolTextResourceError.accessDenied }
            return result
        }
        let search = BoneTextResourceSearchTool<BoneAgentEmptyContext> { [self] request, _ in
            let references = await access?.references()
            let result = try await search(request, allowed: references)
            if let access, Set(await access.references()) != Set(references ?? []) { throw BoneToolTextResourceError.accessDenied }
            return result
        }
        return [BoneAnyAgentTool(DemoDiagnosedTool(list, observe: failureObserver)),
                BoneAnyAgentTool(DemoDiagnosedTool(search, observe: failureObserver))]
    }

    private func queryCollection(allowed: [BoneToolTextResourceReference]? = nil) throws -> BoneTextResourceCollection {
        try Task.checkCancellation()
        return try .init(resources: active.filter { entry in allowed?.contains(entry.snapshot.reference) ?? true }.map { entry in
            try .init(name: entry.stored.name, text: String(decoding: entry.stored.utf8, as: UTF8.self),
                      id: entry.stored.reference.id, version: entry.stored.reference.version)
        })
    }

    /// Private content, including exact bytes and opaque references; never suitable for logs.
    func exportPrivateState() throws -> Data {
        try Task.checkCancellation()
        try validatePersistence(preservesConversation: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(PrivateState(formatVersion: 1, resources: active.map(\.stored)))
        guard data.count <= Self.maximumPrivateStateBytes else {
            throw DemoTextResourceStoreError.invalidPrivateState
        }
        try Task.checkCancellation()
        return data
    }

    /// 验证保存开关；磁盘资源存在时整体拒绝保存，绝不静默过滤正文。
    func validatePersistence(preservesConversation: Bool) throws {
        guard !preservesConversation || disks.isEmpty else { throw DemoTextResourceStoreError.largeResourceCannotBeSaved }
    }

    /// 从授权 URL 导入；小附件保持旧存档，大附件仅持有 SDK 私有快照。
    /// 入参包含保存开关，返回有界预览；同步 I/O 在资源 actor 上执行。
    func add(importing url: URL, preservesConversation: Bool) throws -> DemoImportedTextResource {
        try Task.checkCancellation()
        guard active.count + disks.count < Self.maximumResources else { throw DemoTextResourceStoreError.capacityReached }
        // SDK 检查普通文件、UTF-8、实际字节上限并创建不可变快照。
        let disk: BoneDiskTextResource
        do {
            disk = try BoneDiskTextResource(importing: url, name: url.lastPathComponent,
                maximumBytes: preservesConversation ? Self.maximumResourceBytes : Self.maximumDiskResourceBytes)
        } catch BoneDiskTextResourceError.capacityExceeded where preservesConversation {
            throw DemoTextResourceStoreError.largeResourceCannotBeSaved
        }
        // 小附件从已验证快照有界还原，防止源文件在校验后被替换。
        if disk.descriptor.reference.utf8ByteCount <= Self.maximumResourceBytes {
            var bytes = Data()
            var offset = 0
            repeat {
                let page = try disk.read(.init(reference: disk.descriptor.reference, offset: offset, maximumBytes: 65_536))
                bytes.append(contentsOf: page.text.utf8)
                guard let next = page.nextOffset else { break }
                offset = next
            } while true
            return try add(name: disk.descriptor.name, text: String(decoding: bytes, as: UTF8.self))
        }
        guard !preservesConversation else { throw DemoTextResourceStoreError.largeResourceCannotBeSaved }
        // 预览最多 1 KiB；磁盘正文不会进入旧 PrivateState。
        let page = try disk.read(.init(reference: disk.descriptor.reference, maximumBytes: Self.previewBytes))
        let imported = DemoImportedTextResource(name: disk.descriptor.name,
            preview: try .init(reference: disk.descriptor.reference, text: page.text))
        try Task.checkCancellation()
        disks.append((disk, imported))
        return imported
    }

    /// 汇总授权元数据；分页结果不带文件路径或正文。
    private func list(_ request: BoneTextResourceListRequest, allowed: [BoneToolTextResourceReference]?) throws -> BoneTextResourceListResult {
        _ = try request.validated(); try Task.checkCancellation()
        let descriptors = try entries().filter { allowed?.contains($0.preview.reference) ?? true }
            .map { try BoneTextResourceDescriptor(name: $0.name, reference: $0.preview.reference) }
        guard request.offset <= descriptors.count else { throw BoneResourceQueryError.invalidRequest }
        let end = min(descriptors.count, request.offset + request.limit)
        return .init(resources: Array(descriptors[request.offset..<end]), nextOffset: end < descriptors.count ? end : nil)
    }

    /// 小资源沿用旧匹配规则；磁盘资源按原始 UTF-8 字面搜索，总扫描与结果都有限额。
    func search(_ request: BoneTextResourceSearchRequest, allowed: [BoneToolTextResourceReference]? = nil,
                maximumScanBytes: Int = maximumDiskResourceBytes) throws -> BoneTextResourceSearchResult {
        _ = try request.validated()
        guard maximumScanBytes >= 0 else { throw BoneResourceQueryError.invalidRequest }
        // 小附件总量至多 2 MiB；磁盘扫描另有共享预算。
        let memory = try queryCollection(allowed: allowed).search(request)
        var hits = memory.hits
        var truncated = memory.isTruncated
        var remaining = maximumScanBytes
        var snippetBytes = hits.reduce(0) { $0 + $1.snippet.utf8.count }
        let visible = disks.filter { allowed?.contains($0.resource.descriptor.reference) ?? true }
        for disk in visible {
            try Task.checkCancellation()
            guard hits.count < request.limit, remaining > 0 else {
                return .init(hits: hits, isTruncated: true)
            }
            let result = try disk.resource.search(.init(query: request.query, limit: request.limit - hits.count),
                maximumScanBytes: remaining)
            remaining -= min(remaining, disk.imported.utf8ByteCount)
            truncated = truncated || result.isTruncated
            for hit in result.hits {
                guard snippetBytes + hit.snippet.utf8.count <= 32_768 else { return .init(hits: hits, isTruncated: true) }
                hits.append(hit); snippetBytes += hit.snippet.utf8.count
            }
        }
        return .init(hits: hits, isTruncated: truncated)
    }

    /// 读取 Host 页码；已知起点直接读一页，随机旧页码只补齐尚未知晓的起点。
    func readPage(reference: BoneToolTextResourceReference, number: Int) throws -> BoneToolTextResourcePage {
        guard (0...DemoResourcePageInput.maximumPage).contains(number) else { throw DemoResourcePageError.invalidPage }
        // 下标修改使用 Swift 字典的原地修改访问，不复制整张偏移数组。
        if pageOffsets[reference] == nil { pageOffsets[reference] = [0] }
        while pageOffsets[reference]!.count <= number {
            let offset = pageOffsets[reference]!.last!
            let page = try readText(.init(reference: reference, offset: offset, maximumBytes: DemoResourcePageTool.pageBytes))
            guard let next = page.nextOffset else { throw DemoResourcePageError.pagePastEnd }
            pageOffsets[reference, default: [0]].append(next)
        }
        let offset = pageOffsets[reference]![number]
        let page = try readText(.init(reference: reference, offset: offset, maximumBytes: DemoResourcePageTool.pageBytes))
        if let next = page.nextOffset, pageOffsets[reference]!.count == number + 1 {
            pageOffsets[reference, default: [0]].append(next)
        }
        return page
    }

    private static func isValidName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= maximumNameBytes
    }
}
