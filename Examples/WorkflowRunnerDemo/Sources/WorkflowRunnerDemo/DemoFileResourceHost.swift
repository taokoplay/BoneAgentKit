import Foundation
import BoneAgentKit
import BoneAgentTools

/// Demo 中统一承载文件导入、持久快照、格式解析和有界读取的资源描述。
struct DemoImportedFileResource: Identifiable, Equatable, Sendable, Codable {
    let name: String
    let metadata: BoneFileResourceMetadata
    var id: String { metadata.reference.id }
    var reference: BoneFileResourceReference { metadata.reference }
    var kind: BoneFileResourceKind { reference.kind }
    var byteCount: Int { reference.byteCount }
}

/// Demo 文件资源 Host 的固定失败分类，避免将底层路径或解析器错误暴露给模型。
enum DemoFileResourceHostError: Error, Equatable, Sendable {
    case invalidState
    case capacityReached
    case resourceUnavailable
    case unsupportedOperation
}

/// 资源访问授权账本。每次工具调用都会重新校验完整引用和撤销状态。
actor DemoFileResourceAccess {
    private var allowed: [String: BoneFileResourceReference] = [:]

    /// 授权一组资源引用。
    /// - Parameter references: 当前会话允许模型读取的精确资源版本。
    func allow(_ references: [BoneFileResourceReference]) {
        for reference in references { allowed[reference.id] = reference }
    }

    /// 撤销指定资源授权。
    /// - Parameter id: 资源不透明标识。
    func revoke(id: String) { allowed.removeValue(forKey: id) }

    /// 检查资源引用是否仍然拥有当前会话授权。
    /// - Parameter reference: 模型提交的资源引用。
    /// - Returns: 引用身份和版本都匹配时返回 true。
    func permits(_ reference: BoneFileResourceReference) -> Bool {
        allowed[reference.id] == reference
    }

    /// 返回当前会话已经授权的资源引用。
    /// - Returns: 授权引用列表。
    func references() -> [BoneFileResourceReference] { Array(allowed.values) }
}

/// Demo 对 SDK 文件资源 Store 的薄 Host 包装，统一处理恢复、授权和 UI 所需元数据。
actor DemoFileResourceStore {
    static let maximumResources = 16

    private struct PrivateState: Codable, Sendable {
        let formatVersion: Int
        let resources: [DemoImportedFileResource]
    }

    private let store: BoneFileResourceStore
    private var active: [String: DemoImportedFileResource] = [:]

    /// 创建一个使用 SDK 内容寻址存储的 Demo Host。
    /// - Parameter directory: 应用私有且可跨进程保留的资源目录。
    init(directory: URL) {
        store = BoneFileResourceStore(directory: directory)
    }

    /// 从会话存档恢复 Host 中的不透明资源引用。
    /// - Parameters:
    ///   - privateState: 仅包含资源元数据和引用的有界状态。
    ///   - directory: SDK 资源快照目录。
    init(privateState: Data, directory: URL) throws {
        store = BoneFileResourceStore(directory: directory)
        guard privateState.count <= 4 * 1_048_576 else { throw DemoFileResourceHostError.invalidState }
        // 旧会话在统一文件资源接入前没有该字段，空状态应恢复为空 Store。
        guard !privateState.isEmpty else { return }
        let state: PrivateState
        do { state = try JSONDecoder().decode(PrivateState.self, from: privateState) }
        catch { throw DemoFileResourceHostError.invalidState }
        guard state.formatVersion == 1, state.resources.count <= Self.maximumResources else {
            throw DemoFileResourceHostError.invalidState
        }
        var values: [String: DemoImportedFileResource] = [:]
        for resource in state.resources {
            guard values[resource.id] == nil else { throw DemoFileResourceHostError.invalidState }
            values[resource.id] = resource
        }
        active = values
    }

    /// 导入文件并生成持久、内容寻址的资源快照。
    /// - Parameters:
    ///   - url: 已由系统文件选择器授权的本地文件 URL。
    ///   - kind: 可选的资源类型覆盖。
    ///   - encoding: 文本编码选择，支持 UTF-8、UTF-16、GBK 和 GB18030。
    /// - Returns: 可发送给模型的资源元数据和不透明引用。
    func add(importing url: URL, kind: BoneFileResourceKind? = nil,
             encoding: BoneFileResourceEncoding = .automatic) async throws -> DemoImportedFileResource {
        guard active.count < Self.maximumResources else { throw DemoFileResourceHostError.capacityReached }
        let metadata = try await store.importFile(source: url, name: url.lastPathComponent, kind: kind, encoding: encoding)
        let resource = DemoImportedFileResource(name: metadata.name, metadata: metadata)
        active[resource.id] = resource
        return resource
    }

    /// 恢复并重新校验一个已保存的资源引用。
    /// - Parameter reference: 存档中的资源引用。
    /// - Returns: 重新从 SDK Store 读取后的资源元数据。
    func restore(_ reference: BoneFileResourceReference) async throws -> DemoImportedFileResource {
        let metadata = try await store.restore(reference)
        let resource = DemoImportedFileResource(name: metadata.name, metadata: metadata)
        active[resource.id] = resource
        return resource
    }

    /// 返回当前 Host 中的资源列表。
    /// - Returns: 按资源 ID 排序的确定性列表，避免 Dictionary 枚举顺序影响 UI 和归档。
    func entries() -> [DemoImportedFileResource] { active.values.sorted { $0.id < $1.id } }

    /// 删除资源元数据和 SDK 快照。
    /// - Parameter id: 待删除资源标识。
    func remove(id: String) async throws {
        guard let resource = active.removeValue(forKey: id) else { return }
        try await store.remove(resource.reference)
    }

    /// 导出可跨进程恢复的资源引用状态，不包含文件正文。
    /// - Returns: 有界 JSON 状态。
    func exportPrivateState() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // 使用与 entries 相同的确定性顺序，确保跨进程导出结果稳定。
        let data = try encoder.encode(PrivateState(formatVersion: 1, resources: entries()))
        guard data.count <= 4 * 1_048_576 else { throw DemoFileResourceHostError.invalidState }
        return data
    }

    /// 检查资源结构和格式。
    /// - Parameter reference: 精确资源引用。
    /// - Returns: SDK 解析出的结构化检查结果。
    func inspect(_ reference: BoneFileResourceReference) async throws -> BoneFileResourceInspection {
        try await ensureActive(reference)
        return try await store.inspect(reference)
    }

    /// 探测格式、编码、保护状态和可用能力。
    /// - Parameter reference: 精确资源引用。
    /// - Returns: SDK 格式探测结果。
    func detectFormat(_ reference: BoneFileResourceReference) async throws -> BoneFileResourceFormatInspection {
        try await ensureActive(reference)
        return try await store.detectFormat(reference)
    }

    /// 读取文本、PDF、Office 或归档条目的有界窗口。
    /// - Parameters:
    ///   - request: SDK 有界窗口请求。
    ///   - password: 当前调用临时提供的 PDF 密码。
    /// - Returns: SDK 结构化窗口结果。
    func readWindow(_ request: BoneFileResourceWindowRequest, password: String? = nil) async throws -> BoneFileResourceWindowResult {
        try await ensureActive(request.reference)
        return try await store.readWindow(request, password: password)
    }

    /// 读取 Office 结构化内容。
    /// - Parameter request: DOCX、XLSX 或 PPTX 读取请求。
    /// - Returns: Office 结构化结果。
    func readOffice(_ request: BoneFileResourceOfficeStructureRequest) async throws -> BoneFileResourceOfficeStructureResult {
        try await ensureActive(request.reference)
        return try await store.readOfficeStructure(request)
    }

    /// 列出 ZIP 或 GZIP 的安全条目。
    /// - Parameter reference: 压缩包资源引用。
    /// - Returns: 安全归档条目列表。
    func listEntries(_ reference: BoneFileResourceReference) async throws -> [BoneFileArchiveEntry] {
        try await ensureActive(reference)
        return try await store.listEntries(reference)
    }

    /// 读取原始二进制有界窗口。
    /// - Parameter request: 二进制范围请求。
    /// - Returns: Base64 可编码的二进制页。
    func readBytes(_ request: BoneFileResourceByteReadRequest) async throws -> BoneFileResourceBytePage {
        try await ensureActive(request.reference)
        return try await store.readBytes(request)
    }

    /// 读取 PDF 页面几何和字符布局。
    /// - Parameters:
    ///   - request: PDF 布局预算请求。
    ///   - password: 当前调用临时提供的 PDF 密码。
    /// - Returns: 有界 PDF 页面布局。
    func readPDFLayout(_ request: BoneFileResourcePDFLayoutRequest, password: String? = nil) async throws -> BoneFileResourcePDFLayoutResult {
        try await ensureActive(request.reference)
        return try await store.readPDFLayout(request, password: password)
    }

    /// 对 PDF 页面执行 OCR。
    /// - Parameters:
    ///   - request: OCR 页范围和预算请求。
    ///   - password: 当前调用临时提供的 PDF 密码。
    /// - Returns: 有界 OCR 识别结果。
    func ocr(_ request: BoneFileResourceOCRRequest, password: String? = nil) async throws -> BoneFileResourceOCRResult {
        try await ensureActive(request.reference)
        return try await store.recognizePDF(request, password: password)
    }

    /// 读取已规范化的文本页，供旧 UI 预览使用。
    /// - Parameters:
    ///   - reference: 文本资源引用。
    ///   - offset: UTF-8 字节偏移。
    ///   - maximumBytes: 本页最大字节数。
    /// - Returns: 与旧文本资源协议兼容的页面。
    func readText(reference: BoneFileResourceReference, offset: Int = 0, maximumBytes: Int = 16_384) async throws -> BoneToolTextResourcePage {
        try await ensureActive(reference)
        return try await store.readText(reference: reference, offset: offset, maximumBytes: maximumBytes)
    }

    /// 验证资源在当前 Store 中仍然有效。
    /// - Parameter reference: 待校验资源引用。
    private func ensureActive(_ reference: BoneFileResourceReference) async throws {
        guard active[reference.id]?.reference == reference else { throw BoneFileResourceError.accessDenied }
        _ = try await store.restore(reference)
    }
}
