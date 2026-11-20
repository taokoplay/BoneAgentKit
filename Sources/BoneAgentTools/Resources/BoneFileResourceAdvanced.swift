import Foundation

#if canImport(PDFKit)
import PDFKit
#endif

#if canImport(Vision)
import Vision
#endif

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// PDF 页面坐标中的矩形，原点位于页面左下角。
public struct BoneFilePDFRectangle: Codable, Equatable, Sendable {
    /// 矩形左下角的横坐标。
    public let x: Double
    /// 矩形左下角的纵坐标。
    public let y: Double
    /// 矩形宽度。
    public let width: Double
    /// 矩形高度。
    public let height: Double

    /// 创建 PDF 页面坐标矩形。
    /// - Parameters:
    ///   - x: 左下角横坐标。
    ///   - y: 左下角纵坐标。
    ///   - width: 矩形宽度。
    ///   - height: 矩形高度。
    public init(x: Double, y: Double, width: Double, height: Double) throws {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width >= 0, height >= 0 else {
            throw BoneFileResourceError.parseFailed
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    #if canImport(CoreGraphics)
    /// 把 Core Graphics 矩形转换为资源协议矩形。
    /// - Parameter rect: PDFKit 返回的页面坐标矩形。
    /// - Returns: 可编码的 PDF 页面矩形。
    fileprivate init(rect: CGRect) throws {
        try self.init(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }
    #endif
}

/// PDF 页面上的文本行布局，保留每个 UTF-16 单元对应的字符框。
public struct BoneFilePDFLayoutText: Codable, Equatable, Sendable {
    /// 文本内容。
    public let text: String
    /// 包含该文本行的总体矩形。
    public let bounds: BoneFilePDFRectangle
    /// 与文本 UTF-16 单元顺序对应的字符矩形。
    public let characterBounds: [BoneFilePDFRectangle]

    /// 创建一个 PDF 文本布局行。
    /// - Parameters:
    ///   - text: 文本内容。
    ///   - bounds: 文本行总体矩形。
    ///   - characterBounds: 字符级矩形。
    public init(text: String, bounds: BoneFilePDFRectangle,
                characterBounds: [BoneFilePDFRectangle]) throws {
        guard !text.isEmpty, text.utf8.count <= BoneStructuredFileReaders.maximumPDFTextBytes,
              characterBounds.count == text.utf16.count else {
            throw BoneFileResourceError.parseFailed
        }
        self.text = text
        self.bounds = bounds
        self.characterBounds = characterBounds
    }
}

/// PDF 页面布局结果，保留页面几何、文本框、注释框和可选单页 PDF 数据。
public struct BoneFilePDFLayoutPage: Codable, Equatable, Sendable {
    /// 从零开始的页面序号。
    public let pageIndex: Int
    /// 页面媒体框。
    public let mediaBox: BoneFilePDFRectangle
    /// 页面裁剪框。
    public let cropBox: BoneFilePDFRectangle
    /// 页面旋转角度。
    public let rotation: Int
    /// 页面文本布局行。
    public let text: [BoneFilePDFLayoutText]
    /// 页面注释框。
    public let annotationBounds: [BoneFilePDFRectangle]
    /// 可选的单页 PDF 数据，用于保留原始矢量布局。
    public let pageData: Data?

    /// 创建 PDF 页面布局结果。
    /// - Parameters:
    ///   - pageIndex: 从零开始的页面序号。
    ///   - mediaBox: 页面媒体框。
    ///   - cropBox: 页面裁剪框。
    ///   - rotation: 页面旋转角度。
    ///   - text: 文本布局行。
    ///   - annotationBounds: 注释框。
    ///   - pageData: 可选的单页 PDF 数据。
    public init(pageIndex: Int, mediaBox: BoneFilePDFRectangle, cropBox: BoneFilePDFRectangle,
                rotation: Int, text: [BoneFilePDFLayoutText],
                annotationBounds: [BoneFilePDFRectangle], pageData: Data? = nil) throws {
        guard pageIndex >= 0, [0, 90, 180, 270].contains(rotation),
              text.count <= 100_000, annotationBounds.count <= 100_000,
              pageData.map({ $0.count <= 4 * 1_048_576 }) ?? true else {
            throw BoneFileResourceError.invalidRequest
        }
        self.pageIndex = pageIndex
        self.mediaBox = mediaBox
        self.cropBox = cropBox
        self.rotation = rotation
        self.text = text
        self.annotationBounds = annotationBounds
        self.pageData = pageData
    }
}

/// PDF 布局读取请求；密码由 Host 授权上下文提供，不进入模型工具参数。
public struct BoneFileResourcePDFLayoutRequest: Codable, Equatable, Sendable {
    /// 精确资源版本引用。
    public let reference: BoneFileResourceReference
    /// 读取起始页。
    public let startPage: Int
    /// 本次读取页数。
    public let pageCount: Int
    /// 文本布局最大 UTF-8 字节数。
    public let maximumTextBytes: Int
    /// 本次读取最多返回的文本行和注释元素总数。
    public let maximumElements: Int
    /// 是否携带单页 PDF 数据。
    public let includePageData: Bool
    /// 单页 PDF 数据最大字节数。
    public let maximumPageDataBytes: Int

    /// 创建 PDF 布局读取请求。
    /// - Parameters:
    ///   - reference: 精确 PDF 资源引用。
    ///   - startPage: 起始页。
    ///   - pageCount: 页数。
    ///   - maximumTextBytes: 文本预算。
    ///   - maximumElements: 元素预算。
    ///   - includePageData: 是否返回单页 PDF 数据。
    ///   - maximumPageDataBytes: 单页 PDF 数据预算。
    public init(reference: BoneFileResourceReference, startPage: Int = 0, pageCount: Int = 1,
                maximumTextBytes: Int = 1_048_576, maximumElements: Int = 100_000,
                includePageData: Bool = false, maximumPageDataBytes: Int = 4 * 1_048_576) throws {
        guard reference.kind == .pdf, startPage >= 0, (1...100).contains(pageCount),
              (1...BoneStructuredFileReaders.maximumPDFTextBytes).contains(maximumTextBytes),
              (1...100_000).contains(maximumElements),
              maximumPageDataBytes >= 1, maximumPageDataBytes <= 4 * 1_048_576 else {
            throw BoneFileResourceError.invalidRequest
        }
        self.reference = reference
        self.startPage = startPage
        self.pageCount = pageCount
        self.maximumTextBytes = maximumTextBytes
        self.maximumElements = maximumElements
        self.includePageData = includePageData
        self.maximumPageDataBytes = maximumPageDataBytes
    }

    /// 从不可信工具输入恢复 PDF 布局请求并重新执行限制校验。
    /// - Parameter decoder: 外部工具调用解码器。
    /// - Throws: 请求字段不符合资源合同。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(reference: container.decode(BoneFileResourceReference.self, forKey: .reference),
                      startPage: container.decodeIfPresent(Int.self, forKey: .startPage) ?? 0,
                      pageCount: container.decodeIfPresent(Int.self, forKey: .pageCount) ?? 1,
                      maximumTextBytes: container.decodeIfPresent(Int.self, forKey: .maximumTextBytes) ?? 1_048_576,
                      maximumElements: container.decodeIfPresent(Int.self, forKey: .maximumElements) ?? 100_000,
                      includePageData: container.decodeIfPresent(Bool.self, forKey: .includePageData) ?? false,
                      maximumPageDataBytes: container.decodeIfPresent(Int.self, forKey: .maximumPageDataBytes) ?? 4 * 1_048_576)
    }

    private enum CodingKeys: String, CodingKey {
        case reference, startPage, pageCount, maximumTextBytes, maximumElements, includePageData, maximumPageDataBytes
    }
}

/// PDF 布局工具返回值。
public struct BoneFileResourcePDFLayoutResult: Codable, Equatable, Sendable {
    /// 原始资源引用。
    public let reference: BoneFileResourceReference
    /// 返回的页面布局。
    public let pages: [BoneFilePDFLayoutPage]
    /// 下一次读取的起始页，已到文档末尾时为 nil。
    public let nextPage: Int?

    /// 创建 PDF 布局工具结果。
    /// - Parameters:
    ///   - reference: 原始资源引用。
    ///   - pages: 页面布局。
    ///   - nextPage: 下一页游标。
    public init(reference: BoneFileResourceReference, pages: [BoneFilePDFLayoutPage], nextPage: Int?) {
        self.reference = reference
        self.pages = pages
        self.nextPage = nextPage
    }

    /// 按原始布局请求校验返回结果。
    /// - Parameter request: 原始 PDF 布局请求。
    /// - Returns: 通过引用、页序和预算校验的结果。
    public func validated(for request: BoneFileResourcePDFLayoutRequest) throws -> Self {
        let textBytes = pages.reduce(0) { total, page in
            total + page.text.reduce(0) { $0 + $1.text.utf8.count }
        }
        let elementCount = pages.reduce(0) { total, page in
            total + page.text.count + page.annotationBounds.count
        }
        let pageDataValid = pages.allSatisfy { page in
            guard request.includePageData else { return page.pageData == nil }
            return page.pageData.map { $0.count <= request.maximumPageDataBytes } ?? false
        }
        guard reference == request.reference, pages.count <= request.pageCount,
              textBytes <= request.maximumTextBytes, elementCount <= request.maximumElements,
              pageDataValid,
              pages.enumerated().allSatisfy({ $0.element.pageIndex == request.startPage + $0.offset }),
              nextPage == nil || nextPage == request.startPage + pages.count else {
            throw BoneFileResourceError.referenceMismatch
        }
        return self
    }
}

/// OCR 识别精度。
public enum BoneFileResourceOCRRecognitionLevel: String, Codable, CaseIterable, Sendable {
    /// 优先速度。
    case fast
    /// 优先准确率。
    case accurate
}

/// OCR 识别请求；密码由 Host 授权上下文提供，不进入模型工具参数。
public struct BoneFileResourceOCRRequest: Codable, Equatable, Sendable {
    /// 精确 PDF 资源引用。
    public let reference: BoneFileResourceReference
    /// 起始页。
    public let startPage: Int
    /// 本次识别页数。
    public let pageCount: Int
    /// OCR 识别语言，例如 en-US 或 zh-Hans。
    public let languages: [String]
    /// 识别精度等级。
    public let recognitionLevel: BoneFileResourceOCRRecognitionLevel
    /// 识别结果最大 UTF-8 字节数。
    public let maximumBytes: Int
    /// 最多返回的识别框数量。
    public let maximumObservations: Int

    /// 创建 PDF OCR 请求。
    /// - Parameters:
    ///   - reference: 精确 PDF 资源引用。
    ///   - startPage: 起始页。
    ///   - pageCount: 页数。
    ///   - languages: 识别语言列表。
    ///   - recognitionLevel: 识别精度。
    ///   - maximumBytes: 结果字节预算。
    ///   - maximumObservations: 识别框预算。
    public init(reference: BoneFileResourceReference, startPage: Int = 0, pageCount: Int = 1,
                languages: [String] = [], recognitionLevel: BoneFileResourceOCRRecognitionLevel = .accurate,
                maximumBytes: Int = 1_048_576, maximumObservations: Int = 10_000) throws {
        guard reference.kind == .pdf, startPage >= 0, (1...100).contains(pageCount),
              languages.count <= 16, languages.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 32 }),
              (1...BoneStructuredFileReaders.maximumPDFTextBytes).contains(maximumBytes),
              (1...100_000).contains(maximumObservations) else {
            throw BoneFileResourceError.invalidRequest
        }
        self.reference = reference
        self.startPage = startPage
        self.pageCount = pageCount
        self.languages = languages
        self.recognitionLevel = recognitionLevel
        self.maximumBytes = maximumBytes
        self.maximumObservations = maximumObservations
    }

    /// 从不可信工具输入恢复 OCR 请求并重新执行限制校验。
    /// - Parameter decoder: 外部工具调用解码器。
    /// - Throws: 请求字段不符合资源合同。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(reference: container.decode(BoneFileResourceReference.self, forKey: .reference),
                      startPage: container.decodeIfPresent(Int.self, forKey: .startPage) ?? 0,
                      pageCount: container.decodeIfPresent(Int.self, forKey: .pageCount) ?? 1,
                      languages: container.decodeIfPresent([String].self, forKey: .languages) ?? [],
                      recognitionLevel: container.decodeIfPresent(BoneFileResourceOCRRecognitionLevel.self, forKey: .recognitionLevel) ?? .accurate,
                      maximumBytes: container.decodeIfPresent(Int.self, forKey: .maximumBytes) ?? 1_048_576,
                      maximumObservations: container.decodeIfPresent(Int.self, forKey: .maximumObservations) ?? 10_000)
    }

    private enum CodingKeys: String, CodingKey {
        case reference, startPage, pageCount, languages, recognitionLevel, maximumBytes, maximumObservations
    }
}

/// 单个 OCR 识别结果。
public struct BoneFilePDFOCRObservation: Codable, Equatable, Sendable {
    /// 识别文本。
    public let text: String
    /// 文本在 PDF 页面中的坐标框。
    public let bounds: BoneFilePDFRectangle
    /// Vision 返回的置信度。
    public let confidence: Double

    /// 创建 OCR 识别结果。
    /// - Parameters:
    ///   - text: 识别文本。
    ///   - bounds: 页面坐标框。
    ///   - confidence: 识别置信度。
    public init(text: String, bounds: BoneFilePDFRectangle, confidence: Double) throws {
        guard !text.isEmpty, text.utf8.count <= 16_384, confidence.isFinite,
              (0...1).contains(confidence) else {
            throw BoneFileResourceError.parseFailed
        }
        self.text = text
        self.bounds = bounds
        self.confidence = confidence
    }
}

/// 单页 OCR 结果。
public struct BoneFilePDFOCRPage: Codable, Equatable, Sendable {
    /// 从零开始的页面序号。
    public let pageIndex: Int
    /// 识别框列表。
    public let observations: [BoneFilePDFOCRObservation]
    /// 按阅读顺序拼接的 OCR 文本。
    public let text: String

    /// 创建单页 OCR 结果。
    /// - Parameters:
    ///   - pageIndex: 页面序号。
    ///   - observations: 识别框。
    ///   - text: 拼接文本。
    public init(pageIndex: Int, observations: [BoneFilePDFOCRObservation], text: String) throws {
        guard pageIndex >= 0, observations.count <= 100_000,
              text.utf8.count <= BoneStructuredFileReaders.maximumPDFTextBytes else {
            throw BoneFileResourceError.invalidRequest
        }
        self.pageIndex = pageIndex
        self.observations = observations
        self.text = text
    }
}

/// OCR 工具返回值。
public struct BoneFileResourceOCRResult: Codable, Equatable, Sendable {
    /// 原始资源引用。
    public let reference: BoneFileResourceReference
    /// OCR 页面结果。
    public let pages: [BoneFilePDFOCRPage]
    /// 下一次读取页游标。
    public let nextPage: Int?

    /// 创建 OCR 工具结果。
    /// - Parameters:
    ///   - reference: 原始资源引用。
    ///   - pages: OCR 页面。
    ///   - nextPage: 下一页游标。
    public init(reference: BoneFileResourceReference, pages: [BoneFilePDFOCRPage], nextPage: Int?) {
        self.reference = reference
        self.pages = pages
        self.nextPage = nextPage
    }

    /// 按 OCR 请求校验返回结果。
    /// - Parameter request: 原始 OCR 请求。
    /// - Returns: 通过引用、页序和元素预算校验的结果。
    public func validated(for request: BoneFileResourceOCRRequest) throws -> Self {
        let observationCount = pages.reduce(0) { $0 + $1.observations.count }
        let byteCount = pages.reduce(0) { $0 + $1.text.utf8.count }
        guard reference == request.reference, pages.count <= request.pageCount,
              observationCount <= request.maximumObservations, byteCount <= request.maximumBytes,
              pages.enumerated().allSatisfy({ $0.element.pageIndex == request.startPage + $0.offset }),
              nextPage == nil || nextPage == request.startPage + pages.count else {
            throw BoneFileResourceError.referenceMismatch
        }
        return self
    }
}

extension BoneStructuredFileReaders {
    /// 读取 PDF 的页面布局和可选单页矢量数据。
    /// - Parameters:
    ///   - url: Host 私有 PDF 快照路径。
    ///   - request: 布局读取请求。
    ///   - password: Host 临时提供的 PDF 密码。
    /// - Returns: 有界页面布局结果。
    public static func readPDFLayout(at url: URL, request: BoneFileResourcePDFLayoutRequest,
                                     password: String? = nil) throws -> BoneFileResourcePDFLayoutResult {
        #if canImport(PDFKit)
        let document = try openPDF(at: url, password: password)
        guard request.startPage < document.pageCount else {
            throw BoneFileResourceError.invalidRequest
        }
        let endPage = min(document.pageCount, request.startPage + request.pageCount)
        var pages: [BoneFilePDFLayoutPage] = []
        var textBytes = 0
        var elementCount = 0
        for pageIndex in request.startPage..<endPage {
            try Task.checkCancellation()
            guard textBytes < request.maximumTextBytes && elementCount < request.maximumElements else { break }
            guard let page = document.page(at: pageIndex) else { throw BoneFileResourceError.parseFailed }
            let layout = try makePDFLayoutPage(page: page, pageIndex: pageIndex,
                                               includePageData: request.includePageData,
                                               maximumPageDataBytes: request.maximumPageDataBytes,
                                               maximumElements: request.maximumElements - elementCount,
                                               maximumTextBytes: request.maximumTextBytes - textBytes)
            textBytes += layout.text.reduce(0) { $0 + $1.text.utf8.count }
            elementCount += layout.text.count + layout.annotationBounds.count
            pages.append(layout)
        }
        let nextPage: Int?
        if request.startPage + pages.count < endPage {
            nextPage = request.startPage + pages.count
        } else if endPage < document.pageCount {
            nextPage = endPage
        } else {
            nextPage = nil
        }
        return BoneFileResourcePDFLayoutResult(reference: request.reference, pages: pages, nextPage: nextPage)
        #else
        _ = url
        _ = request
        _ = password
        throw BoneFileResourceError.unsupportedFormat
        #endif
    }

    /// 对 PDF 页面执行 Vision OCR。
    /// - Parameters:
    ///   - url: Host 私有 PDF 快照路径。
    ///   - request: OCR 请求。
    ///   - password: Host 临时提供的 PDF 密码。
    /// - Returns: 有界 OCR 页面结果。
    public static func recognizePDF(at url: URL, request: BoneFileResourceOCRRequest,
                                    password: String? = nil) throws -> BoneFileResourceOCRResult {
        #if canImport(PDFKit) && canImport(Vision)
        let document = try openPDF(at: url, password: password)
        guard request.startPage < document.pageCount else {
            throw BoneFileResourceError.invalidRequest
        }
        let endPage = min(document.pageCount, request.startPage + request.pageCount)
        var pages: [BoneFilePDFOCRPage] = []
        var totalBytes = 0
        var totalObservations = 0
        for pageIndex in request.startPage..<endPage {
            try Task.checkCancellation()
            guard totalBytes < request.maximumBytes && totalObservations < request.maximumObservations else { break }
            guard let page = document.page(at: pageIndex) else { throw BoneFileResourceError.parseFailed }
            let pageResult = try recognizePDFPage(page: page, pageIndex: pageIndex,
                                                  languages: request.languages,
                                                  recognitionLevel: request.recognitionLevel,
                                                  maximumBytes: request.maximumBytes - totalBytes,
                                                  maximumObservations: request.maximumObservations - totalObservations)
            totalBytes += pageResult.text.utf8.count
            totalObservations += pageResult.observations.count
            pages.append(pageResult)
            guard totalBytes <= request.maximumBytes,
                  totalObservations <= request.maximumObservations else {
                throw BoneFileResourceError.capacityExceeded
            }
        }
        let nextPage: Int?
        if request.startPage + pages.count < endPage {
            nextPage = request.startPage + pages.count
        } else if endPage < document.pageCount {
            nextPage = endPage
        } else {
            nextPage = nil
        }
        return BoneFileResourceOCRResult(reference: request.reference, pages: pages, nextPage: nextPage)
        #else
        _ = url
        _ = request
        _ = password
        throw BoneFileResourceError.unsupportedFormat
        #endif
    }

    #if canImport(PDFKit)
    /// 打开 PDF 并根据 Host 提供的临时密码解锁。
    /// - Parameters:
    ///   - url: PDF 快照路径。
    ///   - password: 可选的临时密码。
    /// - Returns: 已打开且可读取的 PDFDocument。
    static func openPDF(at url: URL, password: String?) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw BoneFileResourceError.parseFailed }
        if document.isLocked {
            guard let password else { throw BoneFileResourceError.passwordRequired }
            guard document.unlock(withPassword: password) else { throw BoneFileResourceError.invalidPassword }
        }
        guard document.allowsContentAccessibility else { throw BoneFileResourceError.protectedContent }
        return document
    }

    /// 创建一个有界的 PDF 页面布局结果。
    /// - Parameters:
    ///   - page: PDFKit 页面对象。
    ///   - pageIndex: 页面序号。
    ///   - includePageData: 是否保留单页 PDF 数据。
    ///   - maximumPageDataBytes: 单页数据预算。
    ///   - maximumElements: 元素预算。
    ///   - maximumTextBytes: 文本预算。
    /// - Returns: 页面几何和文本布局。
    private static func makePDFLayoutPage(page: PDFPage, pageIndex: Int, includePageData: Bool,
                                          maximumPageDataBytes: Int, maximumElements: Int,
                                          maximumTextBytes: Int) throws -> BoneFilePDFLayoutPage {
        let mediaBox = try BoneFilePDFRectangle(rect: page.bounds(for: .mediaBox))
        let cropBox = try BoneFilePDFRectangle(rect: page.bounds(for: .cropBox))
        let text = try makePDFLayoutText(page: page, maximumElements: maximumElements,
                                         maximumTextBytes: maximumTextBytes)
        let annotationBounds = try page.annotations.prefix(maximumElements).map {
            try BoneFilePDFRectangle(rect: $0.bounds)
        }
        guard text.count + annotationBounds.count <= maximumElements else {
            throw BoneFileResourceError.capacityExceeded
        }
        let pageData: Data?
        if includePageData {
            guard let data = page.dataRepresentation, data.count <= maximumPageDataBytes else {
                throw BoneFileResourceError.capacityExceeded
            }
            pageData = data
        } else {
            pageData = nil
        }
        return try BoneFilePDFLayoutPage(pageIndex: pageIndex, mediaBox: mediaBox, cropBox: cropBox,
                                         rotation: page.rotation, text: text,
                                         annotationBounds: annotationBounds, pageData: pageData)
    }

    /// 按 PDFKit 字符框重建页面文本行和字符布局。
    /// - Parameters:
    ///   - page: PDFKit 页面对象。
    ///   - maximumElements: 文本行预算。
    ///   - maximumTextBytes: 文本字节预算。
    /// - Returns: 页面文本布局行。
    private static func makePDFLayoutText(page: PDFPage, maximumElements: Int,
                                          maximumTextBytes: Int) throws -> [BoneFilePDFLayoutText] {
        guard let pageString = page.string else { return [] }
        let units = Array(pageString.utf16)
        var lines: [(units: [UInt16], bounds: CGRect, characters: [CGRect])] = []
        var currentUnits: [UInt16] = []
        var currentCharacters: [CGRect] = []
        var currentBounds = CGRect.null
        var currentBaseline: CGFloat?
        var textBytes = 0

        /// 提交当前行，保持字符框和文本 UTF-16 单元一一对应。
        func flushLine() throws {
            guard !currentUnits.isEmpty else { return }
            let lineText = String(decoding: currentUnits, as: UTF16.self)
            textBytes += lineText.utf8.count
            guard textBytes <= maximumTextBytes, lines.count < maximumElements else {
                throw BoneFileResourceError.capacityExceeded
            }
            lines.append((currentUnits, currentBounds.isNull ? .zero : currentBounds, currentCharacters))
            currentUnits.removeAll(keepingCapacity: true)
            currentCharacters.removeAll(keepingCapacity: true)
            currentBounds = .null
            currentBaseline = nil
        }

        for index in units.indices {
            try Task.checkCancellation()
            let unit = units[index]
            let character = page.characterBounds(at: index)
            if unit == 10 || unit == 13 {
                try flushLine()
                continue
            }
            let height = max(character.height, 1)
            let baseline = character.midY
            let startsNewLine = currentBaseline.map { abs($0 - baseline) > max(2, height * 0.6) } ?? false
            if startsNewLine { try flushLine() }
            currentUnits.append(unit)
            currentCharacters.append(character)
            currentBounds = currentBounds.isNull ? character : currentBounds.union(character)
            currentBaseline = currentBaseline.map { ($0 + baseline) / 2 } ?? baseline
        }
        try flushLine()
        return try lines.map { line in
            try BoneFilePDFLayoutText(text: String(decoding: line.units, as: UTF16.self),
                                      bounds: try BoneFilePDFRectangle(rect: line.bounds),
                                      characterBounds: try line.characters.map { try BoneFilePDFRectangle(rect: $0) })
        }
    }
    #endif

    #if canImport(PDFKit) && canImport(Vision)
    /// 渲染 PDF 页面并执行一次 Vision 文本识别。
    /// - Parameters:
    ///   - page: PDFKit 页面对象。
    ///   - pageIndex: 页面序号。
    ///   - languages: 识别语言。
    ///   - recognitionLevel: Vision 识别精度。
    ///   - maximumBytes: 文本预算。
    ///   - maximumObservations: 识别框预算。
    /// - Returns: 单页 OCR 结果。
    private static func recognizePDFPage(page: PDFPage, pageIndex: Int,
                                         languages: [String],
                                         recognitionLevel: BoneFileResourceOCRRecognitionLevel,
                                         maximumBytes: Int,
                                         maximumObservations: Int) throws -> BoneFilePDFOCRPage {
        guard let rendered = renderPDFPage(page: page) else { throw BoneFileResourceError.parseFailed }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel == .accurate ? .accurate : .fast
        request.usesLanguageCorrection = true
        if !languages.isEmpty { request.recognitionLanguages = languages }
        let handler = VNImageRequestHandler(cgImage: rendered.image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        var values: [BoneFilePDFOCRObservation] = []
        var textParts: [String] = []
        var bytes = 0
        for observation in observations.prefix(maximumObservations) {
            try Task.checkCancellation()
            guard let candidate = observation.topCandidates(1).first else { continue }
            let value = candidate.string
            let valueBytes = value.utf8.count + (textParts.isEmpty ? 0 : 1)
            guard bytes + valueBytes <= maximumBytes else { break }
            let rectangle = try pdfRectangle(for: observation.boundingBox,
                                              pageBounds: rendered.pageBounds,
                                              imageSize: rendered.imageSize,
                                              pageToImage: rendered.pageToImage)
            values.append(try BoneFilePDFOCRObservation(text: value, bounds: rectangle,
                                                        confidence: Double(candidate.confidence)))
            textParts.append(value)
            bytes += valueBytes
        }
        return try BoneFilePDFOCRPage(pageIndex: pageIndex, observations: values,
                                      text: textParts.joined(separator: "\n"))
    }

    /// PDF 渲染结果，同时保留图像坐标到 PDF 页面坐标的反变换信息。
    private struct RenderedPDFPage {
        let image: CGImage
        let pageBounds: CGRect
        let imageSize: CGSize
        let pageToImage: CGAffineTransform
    }

    /// 把 Vision 的归一化框转换回 PDF 页面坐标，适配页面旋转和非零 crop box 原点。
    /// - Parameters:
    ///   - normalizedBounds: Vision 左下角原点的归一化矩形。
    ///   - pageBounds: PDF 页面裁剪框。
    ///   - imageSize: OCR 图像的像素尺寸。
    ///   - pageToImage: PDF 页面坐标到图像坐标的变换。
    /// - Returns: PDF 页面坐标中的轴对齐矩形。
    private static func pdfRectangle(for normalizedBounds: CGRect,
                                    pageBounds: CGRect,
                                    imageSize: CGSize,
                                    pageToImage: CGAffineTransform) throws -> BoneFilePDFRectangle {
        let imageBounds = CGRect(x: normalizedBounds.minX * imageSize.width,
                                 y: normalizedBounds.minY * imageSize.height,
                                 width: normalizedBounds.width * imageSize.width,
                                 height: normalizedBounds.height * imageSize.height)
        let imageToPage = pageToImage.inverted()
        let pageRect = imageBounds.applying(imageToPage).intersection(pageBounds).standardized
        guard !pageRect.isNull, pageRect.width >= 0, pageRect.height >= 0 else {
            throw BoneFileResourceError.parseFailed
        }
        return try BoneFilePDFRectangle(rect: pageRect)
    }

    /// 把 PDF 页面渲染成 Vision 可读取的 RGB 图像，并保留坐标变换。
    /// - Parameter page: PDFKit 页面对象。
    /// - Returns: 页面图像及其 PDF 到图像坐标变换，渲染失败时返回 nil。
    private static func renderPDFPage(page: PDFPage) -> RenderedPDFPage? {
        let bounds = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        let swapsAxes = rotation == 90 || rotation == 270
        let scale = min(3.0, max(1.0, 2048.0 / max(bounds.width, bounds.height)))
        let displayBounds = CGRect(x: 0, y: 0,
                                   width: (swapsAxes ? bounds.height : bounds.width) * scale,
                                   height: (swapsAxes ? bounds.width : bounds.height) * scale)
        let width = max(1, Int(ceil(displayBounds.width)))
        let height = max(1, Int(ceil(displayBounds.height)))
        guard let pageRef = page.pageRef,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        let pageToImage = pageRef.getDrawingTransform(.cropBox, rect: displayBounds,
                                                       rotate: 0, preserveAspectRatio: true)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.concatenate(pageToImage)
        context.drawPDFPage(pageRef)
        context.restoreGState()
        guard let image = context.makeImage() else { return nil }
        return RenderedPDFPage(image: image, pageBounds: bounds,
                               imageSize: CGSize(width: width, height: height),
                               pageToImage: pageToImage)
    }
    #endif
}
