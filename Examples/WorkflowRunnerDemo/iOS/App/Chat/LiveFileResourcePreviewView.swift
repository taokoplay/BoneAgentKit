import SwiftUI
import BoneAgentTools
#if canImport(PDFKit)
import PDFKit
#endif

/// 展示统一文件资源的格式信息和有界内容窗口。
/// - Note: 视图只保留当前窗口结果，下一页通过游标重新读取。
struct LiveFileResourcePreviewView: View {
    let resource: DemoImportedFileResource
    let model: LiveChatModel

    @State private var inspection: BoneFileResourceInspection?
    @State private var format: BoneFileResourceFormatInspection?
    @State private var textWindow: BoneFileResourceWindowResult?
    @State private var office: BoneFileResourceOfficeStructureResult?
    @State private var entries: [BoneFileArchiveEntry] = []
    @State private var selectedEntry: BoneFileArchiveEntry?
    @State private var bytes: BoneFileResourceBytePage?
    @State private var pdfLayout: BoneFileResourcePDFLayoutResult?
    @State private var ocr: BoneFileResourceOCRResult?
    @State private var offset = 0
    @State private var pageIndex = 0
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var password = ""
    @State private var asksForPassword = false
    @State private var retryOperation: RetryOperation?

    private enum RetryOperation {
        case text
        case pdfLayout
        case ocr
        case archive
    }

    var body: some View {
        List {
            resourceSummary
            if let errorMessage {
                Section("读取状态") {
                    Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
                    Button("重试") { Task { await load() } }
                        .disabled(isLoading)
                }
            }
            contentSection
        }
        .navigationTitle(resource.name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading { ProgressView("读取中…") }
        }
        .task { await load() }
        .alert("输入 PDF 密码", isPresented: $asksForPassword) {
            SecureField("本次读取密码", text: $password)
            Button("继续") {
                let operation = retryOperation
                retryOperation = nil
                Task { await retry(operation) }
            }
            Button("取消", role: .cancel) {
                password = ""
                retryOperation = nil
            }
        } message: {
            Text("密码只用于当前预览读取，不会保存到会话或诊断记录。")
        }
    }

    private var resourceSummary: some View {
        Section("文件信息") {
            LabeledContent("文件名", value: resource.name)
            LabeledContent("类型", value: resource.kind.title)
            LabeledContent("大小", value: resource.byteCount.formatted(.byteCount(style: .file)))
            if let format {
                LabeledContent("格式", value: "\(format.subtype) · \(format.mimeType)")
                if let encoding = format.encoding {
                    LabeledContent("编码", value: encoding.rawValue)
                }
                LabeledContent("保护", value: format.protectionStatus.rawValue)
                if !format.capabilities.isEmpty {
                    LabeledContent("能力", value: format.capabilities.map(\.rawValue).joined(separator: "、"))
                }
            }
            if let pdf = inspection?.pdf {
                LabeledContent("PDF 页数", value: "\(pdf.pageCount)")
                if pdf.isEncrypted { LabeledContent("PDF 加密", value: pdf.isLocked ? "已锁定" : "已加密") }
            }
            if let office = inspection?.office {
                LabeledContent("Office", value: office.fileExtension.uppercased())
                LabeledContent("包条目", value: "\(office.entryNames.count)")
            }
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        switch resource.kind {
        case .text:
            textSection
        case .pdf:
            pdfSection
        case .officeOpenXML:
            officeSection
        case .archive:
            archiveSection
        case .binary:
            binarySection
        }
    }

    private var textSection: some View {
        Section("文本窗口") {
            if let textWindow, let text = textWindow.text {
                Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                pageControls(nextOffset: textWindow.nextOffset, onNext: {
                    offset = textWindow.nextOffset ?? offset
                    Task { await readText() }
                })
            } else {
                Button("读取首段") { Task { await readText() } }
            }
        }
    }

    private var pdfSection: some View {
        Section("PDF 页面") {
            if let pdfLayout {
                ForEach(pdfLayout.pages, id: \.pageIndex) { page in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("第 \(page.pageIndex + 1) 页 · \(page.text.count) 行").font(.headline)
                        PDFPageLayoutView(page: page)
                            .frame(maxHeight: 560)
                        DisclosureGroup("查看页面文本") {
                            ForEach(Array(page.text.enumerated()), id: \.offset) { _, line in
                                Text(line.text).textSelection(.enabled)
                            }
                        }
                    }
                }
                pageControls(nextOffset: pdfLayout.nextPage, onNext: {
                    pageIndex = pdfLayout.nextPage ?? pageIndex
                    Task { await readPDFLayout() }
                })
                Button("执行本页 OCR") { Task { await recognizePDF() } }
                if let ocr {
                    ForEach(ocr.pages, id: \.pageIndex) { page in
                        Text("OCR 第 \(page.pageIndex + 1) 页\n\(page.text)").textSelection(.enabled)
                    }
                }
            } else {
                Button("读取首屏布局") { Task { await readPDFLayout() } }
            }
        }
    }

    private var officeSection: some View {
        Section("Office 结构") {
            if let office {
                if !office.structure.paragraphs.isEmpty {
                    ForEach(Array(office.structure.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph.text).textSelection(.enabled)
                    }
                }
                ForEach(office.structure.worksheets, id: \.name) { sheet in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sheet.name).font(.headline)
                        ForEach(sheet.cells, id: \.address) { cell in
                            Text("\(cell.address)  \(cell.value)").font(.system(.body, design: .monospaced))
                        }
                    }
                }
                ForEach(office.structure.slides, id: \.slideIndex) { slide in
                    Text("第 \(slide.slideIndex) 页\n\(slide.text)").textSelection(.enabled)
                }
            } else {
                Button("读取 Office 结构") { Task { await readOffice() } }
            }
        }
    }

    private var archiveSection: some View {
        Section("压缩包条目") {
            if entries.isEmpty {
                Button("列出条目") { Task { await listEntries() } }
            } else {
                ForEach(entries, id: \.name) { entry in
                    Button {
                        selectedEntry = entry
                        offset = 0
                        Task { await readArchiveEntry(entry) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.name)
                            Text("\(entry.uncompressedByteCount.formatted(.byteCount(style: .file))) · \(entry.isEncrypted ? "已加密" : "可读取")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(entry.isDirectory || entry.isSymbolicLink || entry.isEncrypted)
                }
                if let textWindow, let data = textWindow.data {
                    Text(data.base64EncodedString()).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    pageControls(nextOffset: textWindow.nextOffset, onNext: {
                        offset = textWindow.nextOffset ?? offset
                        if let selectedEntry { Task { await readArchiveEntry(selectedEntry) } }
                    })
                }
            }
        }
    }

    private var binarySection: some View {
        Section("二进制窗口") {
            if let bytes {
                Text(bytes.data.map { String(format: "%02X", $0) }.joined(separator: " "))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                pageControls(nextOffset: bytes.nextOffset, onNext: {
                    offset = bytes.nextOffset ?? offset
                    Task { await readBytes() }
                })
            } else {
                Button("读取首段字节") { Task { await readBytes() } }
            }
        }
    }

    /// 展示连续窗口的下一页按钮，避免预览一次性累计全文。
    /// - Parameters:
    ///   - nextOffset: 下一页游标，nil 表示已读到末尾。
    ///   - onNext: 点击下一页时执行的读取动作。
    /// - Returns: 带有游标状态的分页控件。
    private func pageControls(nextOffset: Int?, onNext: @escaping () -> Void) -> some View {
        HStack {
            Text(nextOffset == nil ? "已到当前内容末尾" : "当前内容已按窗口读取")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if nextOffset != nil { Button("下一页", action: onNext) }
        }
    }

    /// 读取资源元数据和格式探测结果，并按资源类型准备轻量目录。
    /// - Returns: 无返回值，结果写入当前视图状态。
    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            inspection = try await model.inspectFileResource(resource)
            format = try await model.detectFileResourceFormat(resource)
            if resource.kind == .archive { entries = try await model.listFileResourceEntries(resource) }
        } catch {
            await handle(error, operation: nil)
        }
    }

    /// 读取文本窗口。
    private func readText() async { await perform(.text) {
        let request = try BoneFileResourceWindowRequest(reference: resource.reference, kind: .text, offset: offset, maximumBytes: 16_384)
        textWindow = try await model.readFileResourceWindow(request, password: password.isEmpty ? nil : password)
    } }

    /// 读取 PDF 布局窗口。
    private func readPDFLayout() async { await perform(.pdfLayout) {
        let request = try BoneFileResourcePDFLayoutRequest(
            reference: resource.reference,
            startPage: pageIndex,
            pageCount: 1,
            maximumTextBytes: 256_000,
            maximumElements: 20_000,
            includePageData: true,
            maximumPageDataBytes: 4 * 1_024 * 1_024
        )
        pdfLayout = try await model.readFileResourcePDFLayout(request, password: password.isEmpty ? nil : password)
    } }

    /// 对当前 PDF 页面执行 OCR。
    private func recognizePDF() async { await perform(.ocr) {
        let request = try BoneFileResourceOCRRequest(reference: resource.reference, startPage: pageIndex, pageCount: 1, maximumBytes: 256_000, maximumObservations: 10_000)
        ocr = try await model.recognizeFileResourcePDF(request, password: password.isEmpty ? nil : password)
    } }

    /// 读取 Office 结构化内容。
    private func readOffice() async { await perform(nil) {
        let request = try BoneFileResourceOfficeStructureRequest(reference: resource.reference)
        office = try await model.readFileResourceOffice(request)
    } }

    /// 列出归档条目。
    private func listEntries() async { await perform(.archive) {
        entries = try await model.listFileResourceEntries(resource)
    } }

    /// 读取选中的归档条目窗口。
    /// - Parameter entry: 已通过安全目录校验的归档条目。
    private func readArchiveEntry(_ entry: BoneFileArchiveEntry) async { await perform(.archive) {
        let request = try BoneFileResourceWindowRequest(reference: resource.reference, kind: .archiveEntry, offset: offset, maximumBytes: 16_384, entryName: entry.name)
        textWindow = try await model.readFileResourceWindow(request)
    } }

    /// 读取二进制窗口。
    private func readBytes() async { await perform(nil) {
        let request = try BoneFileResourceByteReadRequest(reference: resource.reference, offset: offset, maximumBytes: 4_096)
        bytes = try await model.readFileResourceBytes(request)
    } }

    /// 统一执行预览读取并处理受保护 PDF 的一次性密码请求。
    /// - Parameters:
    ///   - operation: 失败后需要重试的 PDF 或归档操作。
    ///   - action: 有界读取动作。
    private func perform(_ operation: RetryOperation?, action: () async throws -> Void) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do { try await action() }
        catch { await handle(error, operation: operation) }
    }

    /// 识别密码错误并在当前预览内发起一次性重试。
    private func handle(_ error: Error, operation: RetryOperation?) async {
        if let fileError = error as? BoneFileResourceError,
           fileError == .passwordRequired || fileError == .invalidPassword {
            retryOperation = operation
            asksForPassword = true
            return
        }
        errorMessage = error is CancellationError ? "读取已取消。" : "文件内容暂时无法读取。"
    }

    /// 使用当前输入的 PDF 密码重试一次读取。
    /// - Parameter operation: 需要重试的读取操作。
    private func retry(_ operation: RetryOperation?) async {
        guard let operation else { return }
        switch operation {
        case .text: await readText()
        case .pdfLayout: await readPDFLayout()
        case .ocr: await recognizePDF()
        case .archive: if let selectedEntry { await readArchiveEntry(selectedEntry) }
        }
        password = ""
    }
}

/// 按 PDF 页面坐标绘制页面框、文本行、字符框和注释框，供 Demo 预览完整布局信息。
private struct PDFPageLayoutView: View {
    let page: BoneFilePDFLayoutPage

    var body: some View {
        GeometryReader { geometry in
            let crop = page.cropBox
            let scale = min(
                geometry.size.width / max(crop.width, 1),
                geometry.size.height / max(crop.height, 1)
            )
            let pageSize = CGSize(width: crop.width * scale, height: crop.height * scale)

            ZStack(alignment: .topLeading) {
                if let pageData = page.pageData {
                    PDFPagePreview(data: pageData)
                } else {
                    Color.white
                }
                Canvas { context, _ in
                    for annotation in page.annotationBounds {
                        context.stroke(
                            Path(scaledRect(annotation, crop: crop, scale: scale)),
                            with: .color(.orange.opacity(0.8)),
                            lineWidth: 1
                        )
                    }
                    for line in page.text {
                        context.stroke(
                            Path(scaledRect(line.bounds, crop: crop, scale: scale)),
                            with: .color(.blue.opacity(0.7)),
                            lineWidth: 1
                        )
                        for character in line.characterBounds {
                            context.stroke(
                                Path(scaledRect(character, crop: crop, scale: scale)),
                                with: .color(.gray.opacity(0.45)),
                                lineWidth: 0.5
                            )
                        }
                    }
                }
                ForEach(Array(page.text.enumerated()), id: \.offset) { _, line in
                    Text(line.text)
                        .font(.system(size: max(6, min(24, line.bounds.height * scale * 0.72))))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                        .fixedSize()
                        .position(textPosition(line.bounds, crop: crop, scale: scale))
                }
            }
            .frame(width: pageSize.width, height: pageSize.height)
            .clipShape(.rect)
            .overlay { Rectangle().stroke(.gray.opacity(0.5), lineWidth: 1) }
            .rotationEffect(.degrees(Double(page.rotation)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(
            CGFloat(max(page.cropBox.width, 1)) / CGFloat(max(page.cropBox.height, 1)),
            contentMode: .fit
        )
        .background(Color.white)
        .clipShape(.rect)
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PDF 第 \(page.pageIndex + 1) 页布局预览")
        .accessibilityValue("包含 \(page.text.count) 行文本和 \(page.annotationBounds.count) 个注释框")
    }

    /// 将 PDF 左下角坐标转换为 SwiftUI 左上角坐标，并按页面比例缩放。
    /// - Parameters:
    ///   - rectangle: PDF 页面中的矩形。
    ///   - crop: 页面裁剪框。
    ///   - scale: 当前预览缩放比例。
    /// - Returns: SwiftUI 坐标系中的矩形。
    private func scaledRect(_ rectangle: BoneFilePDFRectangle, crop: BoneFilePDFRectangle, scale: Double) -> CGRect {
        CGRect(
            x: (rectangle.x - crop.x) * scale,
            y: (crop.y + crop.height - rectangle.y - rectangle.height) * scale,
            width: rectangle.width * scale,
            height: rectangle.height * scale
        )
    }

    /// 返回一行文本在页面预览中的中心点。
    /// - Parameters:
    ///   - rectangle: 文本行边界。
    ///   - crop: 页面裁剪框。
    ///   - scale: 当前预览缩放比例。
    /// - Returns: SwiftUI 坐标系中的文本中心点。
    private func textPosition(_ rectangle: BoneFilePDFRectangle, crop: BoneFilePDFRectangle, scale: Double) -> CGPoint {
        let rect = scaledRect(rectangle, crop: crop, scale: scale)
        return CGPoint(x: rect.midX, y: rect.midY)
    }
}

/// 使用 SDK 返回的单页 PDF 数据显示原始页面，保留字体、图片和矢量内容。
#if canImport(PDFKit)
private struct PDFPagePreview: UIViewRepresentable {
    let data: Data

    /// 创建不可编辑的单页 PDF 预览。
    /// - Parameter context: SwiftUI 更新上下文。
    /// - Returns: 已加载单页 PDF 的 PDFView。
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePage
        view.displayDirection = .horizontal
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.document = PDFDocument(data: data)
        return view
    }

    /// 页面数据由请求结果固定，不需要在 SwiftUI 重绘时重新装载文档。
    /// - Parameters:
    ///   - view: 当前 PDFView。
    ///   - context: SwiftUI 更新上下文。
    func updateUIView(_ view: PDFView, context: Context) {}
}
#endif

private extension BoneFileResourceKind {
    /// 返回预览中的中文资源类型标签。
    var title: String {
        switch self {
        case .text: "文本"
        case .pdf: "PDF"
        case .officeOpenXML: "Office"
        case .archive: "压缩包"
        case .binary: "二进制"
        }
    }
}
