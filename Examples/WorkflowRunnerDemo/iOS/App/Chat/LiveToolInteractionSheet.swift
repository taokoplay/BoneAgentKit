import SwiftUI
import BoneAgentTools

struct LiveToolInteractionSheet: View {
    let model: LiveToolInteractionModel
    let request: LiveToolInteractionModel.Pending
    @State private var selectedOptionIDs: Set<String> = []
    @State private var text = ""
    @State private var password = ""
    @FocusState private var editing: Bool

    private var isQuestion: Bool {
        if case .question = request.content { return true }
        return false
    }

    private var isPDFPassword: Bool {
        if case .pdfPassword = request.content { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                switch request.content {
                case .question(let question):
                    questionForm(question)
                case .authorization(let authorization):
                    authorizationForm(authorization)
                case .pdfPassword(let passwordRequest):
                    pdfPasswordForm(passwordRequest)
                }
            }
            .disabled(model.pending?.id != request.id)
            .accessibilityIdentifier(isQuestion ? "toolQuestionSheet" : (isPDFPassword ? "pdfPasswordSheet" : "toolAuthorizationSheet"))
            .navigationTitle(isQuestion ? "回答问题" : (isPDFPassword ? "输入 PDF 密码" : "确认工具调用"))
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                if isQuestion || isPDFPassword {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消", role: .cancel) {
                            editing = false
                            model.cancel(requestID: request.id)
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier(isPDFPassword ? "pdfPasswordToolbarCancel" : "toolQuestionCancel")
                    }
                }
                if editing {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("收起键盘", systemImage: "keyboard.chevron.compact.down") { editing = false }
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("dismissToolQuestionKeyboard")
                    }
                }
            }
        }
        .tint(LabStyle.accent)
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func questionForm(_ question: BoneUserQuestion) -> some View {
        Section {
            Text(question.question)
                .font(.headline)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("模型的问题")
        }

        switch question.kind {
        case .text:
            Section {
                TextField("填写你的回答", text: $text, axis: .vertical)
                    .lineLimit(4...12)
                    .focused($editing)
                    .frame(minHeight: 44)
                    .accessibilityLabel("你的回答")
                    .accessibilityIdentifier("toolQuestionText")
            } header: {
                Text("文本回答")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("请输入非空回答，最多 8 KiB（8,192 字节）。")
                    Text("\(text.utf8.count) / 8,192 字节")
                        .monospacedDigit()
                        .foregroundStyle(text.utf8.count > 8_192 ? Color.red : Color.secondary)
                }
            }
        case .singleChoice, .multipleChoice:
            Section {
                ForEach(question.options) { option in
                    optionButton(option, allowsMultiple: question.kind == .multipleChoice)
                }
            } header: {
                Text(question.kind == .singleChoice ? "请选择一项" : "请选择一项或多项")
            }
        }

        Section {
            Button {
                guard let answer = validAnswer(for: question) else { return }
                editing = false
                model.answer(answer, requestID: request.id)
            } label: {
                Text("提交回答")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(validAnswer(for: question) == nil)
            .accessibilityIdentifier("toolQuestionSubmit")
        } footer: {
            Text("回答将回传模型，不授予其他工具权限。取消或 90 秒内未完成会中止本次等待。")
        }
    }

    private func optionButton(_ option: BoneUserQuestion.Option, allowsMultiple: Bool) -> some View {
        let selected = selectedOptionIDs.contains(option.id)
        return Button {
            if allowsMultiple {
                if selected { selectedOptionIDs.remove(option.id) }
                else { selectedOptionIDs.insert(option.id) }
            } else {
                selectedOptionIDs = [option.id]
            }
        } label: {
            HStack(spacing: LabStyle.itemSpacing) {
                Text(option.label)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: allowsMultiple
                      ? (selected ? "checkmark.square.fill" : "square")
                      : (selected ? "checkmark.circle.fill" : "circle"))
                    .foregroundStyle(LabStyle.accent)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("toolOption_\(option.id)")
    }

    /// 展示一次性 PDF 密码输入，不把密码转换为 BoneUserQuestion。
    /// - Parameter request: 只包含展示文案的密码请求。
    @ViewBuilder
    private func pdfPasswordForm(_ request: DemoPDFPasswordRequest) -> some View {
        Section {
            Text(request.title).font(.headline)
            Text(request.detail).fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("受保护的 PDF")
        }
        Section {
            SecureField("输入本次读取密码", text: $password)
                .focused($editing)
                .textContentType(.password)
                .frame(minHeight: 44)
                .accessibilityIdentifier("pdfPasswordInput")
            Button("继续读取") {
                editing = false
                model.submitPDFPassword(password, requestID: request.id)
            }
            .buttonStyle(.borderedProminent)
            .disabled(password.isEmpty)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityIdentifier("pdfPasswordSubmit")
            Button("取消", role: .cancel) {
                editing = false
                model.cancel(requestID: request.id)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityIdentifier("pdfPasswordCancel")
        } footer: {
            Text("密码只用于当前 PDF 读取，不会保存到会话或诊断记录。")
        }
    }

    @ViewBuilder
    private func authorizationForm(_ authorization: DemoToolAuthorizationRequest) -> some View {
        Section {
            Text(authorization.title).font(.headline)
            Text(authorization.detail)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("核对本次请求与目标")
        } footer: {
            Text("请核对实际地址、搜索服务和查询内容。请求会发送至对应网站或服务，结果会回传当前模型；API 搜索可能计费。")
        }
        Section {
            Button {
                model.authorize(true, requestID: request.id)
            } label: {
                Text("允许本次调用").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("toolAuthorizationAllow")
            Button(role: .cancel) {
                model.authorize(false, requestID: request.id)
            } label: {
                Text("拒绝本次调用").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("toolAuthorizationDeny")
        } footer: {
            Text("仅授权本次展示的调用，不会缓存授权，也不会授权其他工具。关闭此页或超时不会视为允许。")
        }
    }

    private func validAnswer(for question: BoneUserQuestion) -> BoneUserAnswer? {
        let answer: BoneUserAnswer
        switch question.kind {
        case .text:
            answer = BoneUserAnswer(status: .answered, text: text)
        case .singleChoice, .multipleChoice:
            answer = BoneUserAnswer(status: .answered, selectedOptionIDs: question.options
                .filter { selectedOptionIDs.contains($0.id) }.map(\.id))
        }
        return try? answer.validated(for: question)
    }
}

struct LiveToolInteractionPresenter: ViewModifier {
    let model: LiveToolInteractionModel
    @State private var displayedRequest: LiveToolInteractionModel.Pending?
    @State private var showsSheet = false
    @State private var isDismissing = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: presentation, onDismiss: didDismiss) {
                if let request = displayedRequest {
                    LiveToolInteractionSheet(model: model, request: request)
                        .id(request.id)
                }
            }
            .onChange(of: model.pending?.id, initial: true) { _, _ in synchronizePresentation() }
    }

    private var presentation: Binding<Bool> {
        // Keep the identity that belonged to this binding, even if SwiftUI closes it later.
        let requestID = displayedRequest?.id
        return Binding(get: { showsSheet }, set: { presented in
            guard !presented, let requestID else { return }
            beginDismissal(requestID: requestID)
        })
    }

    private func synchronizePresentation() {
        // Freeze the closing sheet; a replacement waits until its dismissal completes.
        guard !isDismissing else { return }
        if let request = model.pending {
            displayedRequest = request
            showsSheet = true
        } else if let request = displayedRequest, showsSheet {
            beginDismissal(requestID: request.id)
        }
    }

    private func beginDismissal(requestID: UUID) {
        guard !isDismissing else { return }
        isDismissing = true
        showsSheet = false
        model.cancel(requestID: requestID)
    }

    private func didDismiss() {
        displayedRequest = nil
        showsSheet = false
        isDismissing = false
        // Dismissal completion must not cancel a request that arrived during the animation.
        synchronizePresentation()
    }
}
