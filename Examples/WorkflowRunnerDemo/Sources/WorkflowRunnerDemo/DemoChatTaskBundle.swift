import Foundation

/// Attachment identities only; contents stay in the private in-memory stores.
struct DemoChatMaterials: Equatable, Sendable {
    var imageIDs: [String]
    var resourceIDs: [String]
    /// 统一文件资源的独立身份列表，避免与旧文本资源混用。
    var fileResourceIDs: [String]

    /// 创建附件身份集合，并按类别去重。
    /// - Parameters:
    ///   - imageIDs: 图片资源身份。
    ///   - resourceIDs: 旧文本资源身份。
    ///   - fileResourceIDs: 统一文件资源身份。
    init(imageIDs: [String] = [], resourceIDs: [String] = [], fileResourceIDs: [String] = []) {
        self.imageIDs = Self.unique(imageIDs)
        self.resourceIDs = Self.unique(resourceIDs)
        self.fileResourceIDs = Self.unique(fileResourceIDs)
    }

    var isEmpty: Bool { imageIDs.isEmpty && resourceIDs.isEmpty && fileResourceIDs.isEmpty }

    /// 合并两组附件身份。
    func union(_ other: Self) -> Self {
        .init(imageIDs: imageIDs + other.imageIDs,
              resourceIDs: resourceIDs + other.resourceIDs,
              fileResourceIDs: fileResourceIDs + other.fileResourceIDs)
    }

    /// 移除另一组附件身份。
    func subtracting(_ other: Self) -> Self {
        .init(imageIDs: imageIDs.filter { !other.imageIDs.contains($0) },
              resourceIDs: resourceIDs.filter { !other.resourceIDs.contains($0) },
              fileResourceIDs: fileResourceIDs.filter { !other.fileResourceIDs.contains($0) })
    }

    /// 判断当前附件身份是否完整包含在另一组附件中。
    func isSubset(of other: Self) -> Bool {
        imageIDs.allSatisfy(other.imageIDs.contains) &&
        resourceIDs.allSatisfy(other.resourceIDs.contains) &&
        fileResourceIDs.allSatisfy(other.fileResourceIDs.contains)
    }
    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

struct DemoChatTaskBundle: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let materials: DemoChatMaterials
    init(id: UUID = UUID(), text: String, materials: DemoChatMaterials = .init()) {
        self.id = id; self.text = text; self.materials = materials
    }
    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && materials.isEmpty }
    func hasSameContents(as other: Self) -> Bool { text == other.text && materials == other.materials }
}
