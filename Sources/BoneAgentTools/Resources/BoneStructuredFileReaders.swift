import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// PDF 和 OOXML 的结构化读取入口；只接收已获 Host 授权的私有快照 URL。
public enum BoneStructuredFileReaders {
    public static let maximumPDFTextBytes = 1 * 1_048_576
    public static let maximumOfficeTextBytes = 4 * 1_048_576
    /// Office 结构化结果允许返回的单次集合元素上限。
    public static let maximumOfficeStructureItems = 100_000

    /// 读取 PDF 页数和基础元数据。
    /// - Parameter url: Host 私有 PDF 快照路径。
    /// - Returns: PDF 页数、标题和作者。
    public static func inspectPDF(at url: URL) throws -> BoneFilePDFInspection {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: url) else { throw BoneFileResourceError.parseFailed }
        return try BoneFilePDFInspection(pageCount: document.pageCount,
                                         title: document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
                                         author: document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String)
        #else
        throw BoneFileResourceError.unsupportedFormat
        #endif
    }

    /// 读取 PDF 的一个页级文本窗口。
    /// - Parameters:
    ///   - url: Host 私有 PDF 快照路径。
    ///   - pageIndex: 从零开始的页索引。
    ///   - maximumBytes: 本页最多返回的 UTF-8 字节数。
    /// - Returns: PDF 页文本。
    public static func readPDFPage(at url: URL, pageIndex: Int, maximumBytes: Int = 65_536) throws -> BoneFilePDFPage {
        guard (1...BoneFileResourceByteReadRequest.maximumPageBytes).contains(maximumBytes), pageIndex >= 0 else {
            throw BoneFileResourceError.invalidRequest
        }
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: url), pageIndex < document.pageCount,
              let page = document.page(at: pageIndex) else {
            throw BoneFileResourceError.parseFailed
        }
        let text = page.string ?? ""
        let bytes = Data(text.utf8)
        let end = utf8Prefix(bytes, maximumBytes: maximumBytes)
        return try BoneFilePDFPage(pageIndex: pageIndex, text: String(decoding: bytes.prefix(end), as: UTF8.self),
                                   isTruncated: end < bytes.count)
        #else
        throw BoneFileResourceError.unsupportedFormat
        #endif
    }

    /// 检查 DOCX/XLSX/PPTX 的安全包目录和参与文本投影的 XML 条目。
    /// - Parameters:
    ///   - url: Host 私有 OOXML 快照路径。
    ///   - fileExtension: 原始扩展名，不含路径。
    /// - Returns: Office 包目录和文本条目。
    public static func inspectOffice(at url: URL, fileExtension: String) throws -> BoneFileOfficeInspection {
        let entries = try BoneFileArchiveReader.listEntries(at: url)
        let normalized = fileExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let xmlNames = entries.filter { !$0.isDirectory && $0.name.lowercased().hasSuffix(".xml") }.map(\.name)
        return try BoneFileOfficeInspection(fileExtension: normalized,
                                            entryNames: entries.map(\.name),
                                            textEntryNames: xmlNames)
    }

    /// 读取 OOXML 包中 XML 条目的文本投影；实体和脚本不会执行。
    /// - Parameters:
    ///   - url: Host 私有 OOXML 快照路径。
    ///   - fileExtension: 原始扩展名。
    ///   - offset: 投影 UTF-8 偏移。
    ///   - maximumBytes: 本次最多返回的字节数。
    /// - Returns: Office XML 文本页。
    public static func readOfficeText(at url: URL, fileExtension: String, offset: Int = 0,
                                      maximumBytes: Int = 65_536) throws -> BoneFileOfficeTextPage {
        guard (1...BoneFileResourceByteReadRequest.maximumPageBytes).contains(maximumBytes), offset >= 0 else {
            throw BoneFileResourceError.invalidRequest
        }
        let inspection = try inspectOffice(at: url, fileExtension: fileExtension)
        var projection = Data()
        for entryName in inspection.textEntryNames {
            let xmlData = try readEntireArchiveEntry(at: url, name: entryName, maximumBytes: maximumOfficeTextBytes)
            guard let xml = String(data: xmlData, encoding: .utf8) else { throw BoneFileResourceError.parseFailed }
            guard projection.count < maximumOfficeTextBytes else { throw BoneFileResourceError.capacityExceeded }
            // 为当前 XML 文本预留一个换行字节，确保总投影不超过预算。
            let textBudget = maximumOfficeTextBytes - projection.count - 1
            guard textBudget >= 0 else { throw BoneFileResourceError.capacityExceeded }
            let text = try XMLTextProjection.project(xml: xml, maximumBytes: textBudget)
            projection.append(contentsOf: Data(text.utf8))
            projection.append(0x0A)
        }
        guard offset <= projection.count,
              offset == projection.count || projection[offset] & 0xC0 != 0x80 else {
            throw BoneFileResourceError.invalidRequest
        }
        let end = min(projection.count, offset + maximumBytes)
        let pageEnd = utf8Prefix(projection.subdata(in: offset..<end), maximumBytes: end - offset)
        return try BoneFileOfficeTextPage(offset: offset,
                                          text: String(decoding: projection[offset..<(offset + pageEnd)], as: UTF8.self),
                                          totalByteCount: projection.count)
    }

    /// 按 Office 文件类型读取段落、工作表/单元格或幻灯片文本。
    /// - Parameters:
    ///   - url: Host 私有 OOXML 快照路径。
    ///   - fileExtension: docx、xlsx 或 pptx。
    /// - Returns: 有界结构化 Office 结果。
    public static func readOfficeStructure(at url: URL, fileExtension: String) throws -> BoneFileOfficeStructure {
        let normalized = fileExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let entries = try inspectOffice(at: url, fileExtension: normalized).entryNames
        switch normalized {
        case "docx":
            let names = entries.filter { $0 == "word/document.xml" || $0.hasPrefix("word/header") || $0.hasPrefix("word/footer") }
                .filter { $0.hasSuffix(".xml") }
                .sorted()
            var paragraphs: [BoneFileOfficeParagraph] = []
            for name in names {
                let data = try readEntireArchiveEntry(at: url, name: name, maximumBytes: maximumOfficeTextBytes)
                paragraphs.append(contentsOf: try DOCXParser.parse(data: data))
                guard paragraphs.count <= maximumOfficeStructureItems else {
                    throw BoneFileResourceError.capacityExceeded
                }
            }
            return try BoneFileOfficeStructure(fileExtension: normalized, paragraphs: paragraphs)
        case "xlsx":
            return try readXLSXStructure(at: url, entries: entries)
        case "pptx":
            let names = entries.filter { $0.range(of: #"^ppt/slides/slide[0-9]+\.xml$"#, options: .regularExpression) != nil }
                .sorted { slideNumber($0) < slideNumber($1) }
            var slides: [BoneFileOfficeSlide] = []
            for name in names {
                let data = try readEntireArchiveEntry(at: url, name: name, maximumBytes: maximumOfficeTextBytes)
                let text = try PPTXParser.parse(data: data)
                slides.append(try BoneFileOfficeSlide(slideIndex: slideNumber(name), text: text))
                guard slides.count <= maximumOfficeStructureItems else {
                    throw BoneFileResourceError.capacityExceeded
                }
            }
            return try BoneFileOfficeStructure(fileExtension: normalized, slides: slides)
        default:
            throw BoneFileResourceError.unsupportedFormat
        }
    }

    /// 读取 XLSX 的共享字符串、工作簿关系和工作表单元格。
    /// - Parameters:
    ///   - url: XLSX 快照路径。
    ///   - entries: 已验证的 ZIP 条目名。
    /// - Returns: 按工作簿顺序排列的工作表结果。
    private static func readXLSXStructure(at url: URL, entries: [String]) throws -> BoneFileOfficeStructure {
        let sharedStrings = try readSharedStrings(at: url, entries: entries)
        let workbookData = try readOfficeEntry(at: url, entries: entries, name: "xl/workbook.xml")
        let relationshipData = try readOfficeEntry(at: url, entries: entries, name: "xl/_rels/workbook.xml.rels")
        let sheets = try XLSXWorkbookParser.parse(data: workbookData)
        let relationships = try XLSXRelationshipParser.parse(data: relationshipData)
        var worksheets: [BoneFileOfficeWorksheet] = []
        // 记录所有工作表的单元格总量，避免多个工作表绕过单表预算。
        var totalCells = 0
        for sheet in sheets {
            guard let target = relationships[sheet.relationshipID] else { throw BoneFileResourceError.parseFailed }
            let targetName = resolveXLSXTarget(target)
            guard entries.contains(targetName) else { throw BoneFileResourceError.parseFailed }
            let data = try readEntireArchiveEntry(at: url, name: targetName, maximumBytes: maximumOfficeTextBytes)
            let cells = try XLSXSheetParser.parser(data: data, sharedStrings: sharedStrings).cells
            guard totalCells <= maximumOfficeStructureItems - cells.count else {
                throw BoneFileResourceError.capacityExceeded
            }
            totalCells += cells.count
            worksheets.append(try BoneFileOfficeWorksheet(name: sheet.name, cells: cells))
            guard worksheets.count <= maximumOfficeStructureItems else {
                throw BoneFileResourceError.capacityExceeded
            }
        }
        return try BoneFileOfficeStructure(fileExtension: "xlsx", worksheets: worksheets)
    }

    /// 读取 XLSX 的 sharedStrings.xml，缺失时返回空表。
    /// - Parameters:
    ///   - url: XLSX 快照路径。
    ///   - entries: 已验证的 ZIP 条目名。
    /// - Returns: 按索引排列的共享字符串。
    private static func readSharedStrings(at url: URL, entries: [String]) throws -> [String] {
        guard entries.contains("xl/sharedStrings.xml") else { return [] }
        let data = try readEntireArchiveEntry(at: url, name: "xl/sharedStrings.xml", maximumBytes: maximumOfficeTextBytes)
        return try XLSXSharedStringsParser.parse(data: data)
    }

    /// 读取一个必须存在的 Office XML 条目。
    /// - Parameters:
    ///   - url: Office 快照路径。
    ///   - entries: 已验证的条目名。
    ///   - name: 目标条目名。
    /// - Returns: 完整 XML 字节。
    private static func readOfficeEntry(at url: URL, entries: [String], name: String) throws -> Data {
        guard entries.contains(name) else { throw BoneFileResourceError.parseFailed }
        return try readEntireArchiveEntry(at: url, name: name, maximumBytes: maximumOfficeTextBytes)
    }

    /// 将 workbook relationship 的目标解析为 ZIP 内部规范路径。
    /// - Parameter target: relationship 中的相对目标。
    /// - Returns: 规范化的 xl 相对路径。
    private static func resolveXLSXTarget(_ target: String) -> String {
        let normalized = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
        return normalized.replacingOccurrences(of: "//", with: "/")
    }

    /// 从 slide*.xml 条目名提取一开始的幻灯片序号。
    /// - Parameter name: 幻灯片条目名。
    /// - Returns: 幻灯片序号，无法提取时返回零。
    private static func slideNumber(_ name: String) -> Int {
        guard let match = name.range(of: #"slide([0-9]+)\.xml$"#, options: .regularExpression),
              let value = Int(name[match].dropFirst(5).dropLast(4)) else { return 0 }
        return value
    }

    /// 分页收集一个 XML 条目，避免把 64 KiB 工具页误当成完整 XML 文档。
    /// - Parameters:
    ///   - url: OOXML 压缩包快照路径。
    ///   - name: 包内 XML 条目名。
    ///   - maximumBytes: 单条 XML 的展开预算。
    /// - Returns: 完整且不超过预算的 XML 字节。
    private static func readEntireArchiveEntry(at url: URL, name: String, maximumBytes: Int) throws -> Data {
        var result = Data()
        var offset = 0
        while true {
            let page = try BoneFileArchiveReader.readEntry(at: url, name: name, offset: offset,
                                                           maximumBytes: BoneFileResourceByteReadRequest.maximumPageBytes)
            guard result.count <= maximumBytes - page.data.count else {
                throw BoneFileResourceError.capacityExceeded
            }
            result.append(page.data)
            guard let nextOffset = page.nextOffset else { return result }
            guard nextOffset > offset else { throw BoneFileResourceError.parseFailed }
            offset = nextOffset
        }
    }

    private static func utf8Prefix(_ bytes: Data, maximumBytes: Int) -> Int {
        var end = min(bytes.count, maximumBytes)
        while end > 0 && end < bytes.count && bytes[end] & 0xC0 == 0x80 { end -= 1 }
        return end
    }
}

/// XMLParser 的公共初始化和统一安全配置。
private func parseOfficeXML<T: NSObject & XMLParserDelegate>(_ data: Data, delegate: T) throws -> T {
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    parser.shouldResolveExternalEntities = false
    parser.shouldProcessNamespaces = false
    guard parser.parse() else { throw BoneFileResourceError.parseFailed }
    return delegate
}

/// 返回 XML 元素或属性的本地名称，兼容带命名空间前缀的 OOXML。
/// - Parameter name: XMLParser 返回的元素或属性名。
/// - Returns: 去掉命名空间前缀的名称。
private func officeLocalName(_ name: String) -> String {
    name.split(separator: ":").last.map(String.init) ?? name
}

/// 从属性字典中读取指定本地名称的值。
/// - Parameters:
///   - attributes: XMLParser 返回的属性字典。
///   - name: 目标属性本地名称。
/// - Returns: 匹配的属性值。
private func officeAttribute(_ attributes: [String: String], named name: String) -> String? {
    attributes.first { officeLocalName($0.key) == name }?.value
}

/// DOCX 段落解析器，仅保留 w:t 文本和 w:p 边界。
private final class DOCXParser: NSObject, XMLParserDelegate {
    private var currentParagraph = ""
    private var paragraphTexts: [String] = []
    private var inParagraph = false

    /// 解析 DOCX 主文档、页眉或页脚 XML。
    /// - Parameter data: XML 条目内容。
    /// - Returns: 文档顺序段落。
    static func parse(data: Data) throws -> [BoneFileOfficeParagraph] {
        let parser = try parseOfficeXML(data, delegate: DOCXParser())
        return try parser.paragraphTexts.compactMap { text in
            text.isEmpty ? nil : try BoneFileOfficeParagraph(text: text)
        }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if officeLocalName(name) == "p" {
            inParagraph = true
            currentParagraph = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inParagraph { currentParagraph.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        guard officeLocalName(name) == "p", inParagraph else { return }
        paragraphTexts.append(currentParagraph)
        currentParagraph = ""
        inParagraph = false
    }
}

/// XLSX 工作簿中的工作表声明。
private struct XLSXSheetDeclaration {
    let name: String
    let relationshipID: String
}

/// XLSX workbook.xml 解析器。
private final class XLSXWorkbookParser: NSObject, XMLParserDelegate {
    private var sheets: [XLSXSheetDeclaration] = []

    /// 解析工作簿中的 sheet 声明。
    /// - Parameter data: workbook.xml 内容。
    /// - Returns: 按工作簿顺序排列的工作表声明。
    static func parse(data: Data) throws -> [XLSXSheetDeclaration] {
        try parseOfficeXML(data, delegate: XLSXWorkbookParser()).sheets
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard officeLocalName(name) == "sheet",
              let sheetName = officeAttribute(attributeDict, named: "name"),
              let relationshipID = officeAttribute(attributeDict, named: "id") else { return }
        sheets.append(XLSXSheetDeclaration(name: sheetName, relationshipID: relationshipID))
    }
}

/// XLSX workbook relationship 解析器。
private final class XLSXRelationshipParser: NSObject, XMLParserDelegate {
    private var relationships: [String: String] = [:]

    /// 解析 workbook.xml.rels 中的工作表目标。
    /// - Parameter data: relationship XML 内容。
    /// - Returns: relationship ID 到目标路径的映射。
    static func parse(data: Data) throws -> [String: String] {
        try parseOfficeXML(data, delegate: XLSXRelationshipParser()).relationships
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard officeLocalName(name) == "Relationship",
              let identifier = officeAttribute(attributeDict, named: "Id"),
              let target = officeAttribute(attributeDict, named: "Target") else { return }
        relationships[identifier] = target
    }
}

/// XLSX sharedStrings.xml 解析器。
private final class XLSXSharedStringsParser: NSObject, XMLParserDelegate {
    private var values: [String] = []
    private var currentValue = ""
    private var inItem = false

    /// 解析共享字符串条目，并合并 rich text 的多个 t 节点。
    /// - Parameter data: sharedStrings.xml 内容。
    /// - Returns: 按索引排列的共享字符串。
    static func parse(data: Data) throws -> [String] {
        try parseOfficeXML(data, delegate: XLSXSharedStringsParser()).values
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if officeLocalName(name) == "si" {
            inItem = true
            currentValue = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inItem { currentValue.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        guard officeLocalName(name) == "si", inItem else { return }
        values.append(currentValue)
        currentValue = ""
        inItem = false
    }
}

/// XLSX worksheet.xml 解析器。
private final class XLSXSheetParser: NSObject, XMLParserDelegate {
    private struct CurrentCell {
        let address: String
        let type: String?
        var value: String
    }

    fileprivate var cells: [BoneFileOfficeCell] = []
    private var currentCell: CurrentCell?
    private var inValue = false

    private var sharedStrings: [String] = []

    override init() {
        super.init()
    }

    convenience init(sharedStrings: [String]) {
        self.init()
        self.sharedStrings = sharedStrings
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch officeLocalName(name) {
        case "c":
            guard let address = officeAttribute(attributeDict, named: "r") else { return }
            currentCell = CurrentCell(address: address, type: officeAttribute(attributeDict, named: "t"), value: "")
        case "v", "t":
            if currentCell != nil { inValue = true }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inValue else { return }
        currentCell?.value.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch officeLocalName(name) {
        case "v", "t":
            inValue = false
        case "c":
            guard let cell = currentCell else { return }
            let resolvedValue: String
            if cell.type == "s", let index = Int(cell.value), sharedStrings.indices.contains(index) {
                resolvedValue = sharedStrings[index]
            } else {
                resolvedValue = cell.value
            }
            if let value = try? BoneFileOfficeCell(address: cell.address, value: resolvedValue) {
                cells.append(value)
            }
            currentCell = nil
        default:
            break
        }
    }

    /// 以 sharedStrings 配置创建 worksheet 解析器。
    /// - Parameter data: worksheet XML 内容。
    /// - Returns: 已完成解析的 worksheet 解析器。
    static func parser(data: Data, sharedStrings: [String]) throws -> XLSXSheetParser {
        try parseOfficeXML(data, delegate: XLSXSheetParser(sharedStrings: sharedStrings))
    }
}

/// PPTX 幻灯片 XML 解析器。
private final class PPTXParser: NSObject, XMLParserDelegate {
    private var text = ""
    private var inText = false

    /// 读取幻灯片中的所有 a:t 文本节点。
    /// - Parameter data: slide XML 内容。
    /// - Returns: 按文档顺序拼接的文本。
    static func parse(data: Data) throws -> String {
        try parseOfficeXML(data, delegate: PPTXParser()).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        inText = officeLocalName(name) == "t"
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { text.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if officeLocalName(name) == "t" { inText = false }
    }
}

private enum XMLTextProjection {
    /// 从 XML 中提取字符数据和属性值，拒绝实体扩展并限制文本总量。
    /// - Parameters:
    ///   - xml: 已从安全 OOXML 条目读取的 UTF-8 XML。
    ///   - maximumBytes: 投影文本预算。
    /// - Returns: 纯文本投影，不执行任何外部实体。
    static func project(xml: String, maximumBytes: Int) throws -> String {
        guard maximumBytes >= 0 else { throw BoneFileResourceError.capacityExceeded }
        let delegate = Delegate(maximumBytes: maximumBytes)
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        guard parser.parse(), !delegate.failed else { throw BoneFileResourceError.parseFailed }
        return delegate.output
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let maximumBytes: Int
        var output = ""
        var failed = false

        init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !failed else { return }
            guard output.utf8.count + string.utf8.count <= maximumBytes else { failed = true; parser.abortParsing(); return }
            output.append(string)
        }

        func parser(_ xmlParser: XMLParser, foundIgnorableWhitespace whitespaceString: String) {
            parser(xmlParser, foundCharacters: whitespaceString)
        }

        func parser(_ parser: XMLParser, foundSkippedEntity name: String) {
            failed = true
            parser.abortParsing()
        }
    }
}
