import Foundation
import BoneAgentKit

/// Explicit host policy, never inferred from a model name or model-discovery result.
enum DemoVisionPolicy: String, Codable, CaseIterable, Sendable {
    case disabled
    case openAI41Mini
    case customLinear

    var title: String {
        switch self {
        case .disabled: return "关闭图片输入"
        case .openAI41Mini: return "OpenAI GPT-4.1 mini"
        case .customLinear: return "自定义 Host 保守预算"
        }
    }

    var sourceDescription: String {
        switch self {
        case .disabled: return "尚未配置图片输入策略。"
        case .openAI41Mini: return "OpenAI 文档：32×32 像素 patch，乘以 1.62 并向上取整；仅用于发送前预算。"
        case .customLinear: return "用户配置的 Host 保守公式；不代表模型已验证支持图片，也不代表服务商实际用量。"
        }
    }

    /// Called before saving or constructing an image-enabled provider. The host
    /// binds visionBindingID only on explicit Settings Save; this never rebinds it.
    func validate(settings: DemoLiveChatSettings) throws {
        guard self == settings.visionPolicy else { throw DemoVisionError.invalidPolicy }
        guard self != .disabled else { return }
        guard !settings.visionBindingID.isEmpty,
              settings.visionBindingID == settings.visionBindingFingerprint else {
            throw DemoVisionError.bindingMismatch
        }
        guard !settings.modelID.isEmpty, settings.modelID.utf8.count <= 256,
              settings.modelID == settings.modelID.trimmingCharacters(in: .whitespacesAndNewlines),
              !settings.modelID.contains(where: { $0.isNewline }) else {
            throw DemoVisionError.unsupportedModel
        }
        guard settings.contextWindowTokens > DemoVisionTokenProvider.safetyMarginTokens,
              settings.maximumOutputTokens > 0,
              settings.maximumOutputTokens < settings.contextWindowTokens else {
            throw DemoVisionError.invalidContextBudget
        }
        do {
            let budget = try BoneContextWindowBudget(contextWindowTokens: settings.contextWindowTokens,
                maximumOutputTokens: settings.maximumOutputTokens, source: .host)
            _ = try budget.availableInputTokens(configuredOutputTokens: settings.maximumOutputTokens,
                preferredOutputTokens: nil, protocolReserveTokens: 128,
                safetyMarginTokens: DemoVisionTokenProvider.safetyMarginTokens)
        } catch { throw DemoVisionError.invalidContextBudget }
        switch self {
        case .disabled: break
        case .openAI41Mini:
            guard settings.provider.kind == .openAI,
                  Self.openAI41MiniModelIDs.contains(settings.modelID) else {
                throw DemoVisionError.unsupportedModel
            }
        case .customLinear:
            guard (1...100_000).contains(settings.visionTokenBase),
                  (1...100_000).contains(settings.visionTokensPerMegapixel) else {
                throw DemoVisionError.invalidCustomParameters
            }
        }
    }

    private static let openAI41MiniModelIDs: Set<String> = [
        "gpt-4.1-mini", "gpt-4.1-mini-2025-04-14"
    ]
}

/// Safe fixed messages: no endpoint, prompt, image bytes, or credentials.
enum DemoVisionError: Error, Equatable, Sendable, LocalizedError {
    case disabled, invalidPolicy, bindingMismatch, unsupportedModel
    case invalidCustomParameters, invalidContextBudget, imageIOUnavailable
    case imageTooLarge, capacityReached, unavailableImage, referenceMismatch, invalidPrivateState

    var message: String {
        switch self {
        case .disabled: return "图片输入尚未启用，请先配置并保存视觉策略。"
        case .invalidPolicy: return "视觉策略无效，请重新配置并保存。"
        case .bindingMismatch: return "视觉策略与当前连接或模型不匹配，请在模型设置中重新配置并保存。"
        case .unsupportedModel: return "当前视觉策略不支持此服务商或精确模型 ID，请选择合适的策略并保存。"
        case .invalidCustomParameters: return "自定义图片预算的基础值和每百万像素值都必须在 1～100000 之间。"
        case .invalidContextBudget: return "上下文与回复上限无效，请为回复、协议及图片安全余量保留足够空间。"
        case .imageIOUnavailable: return "当前平台缺少 ImageIO 图片解码支持，无法安全处理图片。"
        case .imageTooLarge: return "图片超过允许的字节、尺寸或像素上限，请缩小后重试。"
        case .capacityReached: return "最多保留 6 张图片，处理后的图片总大小不得超过 12 MiB。"
        case .unavailableImage: return "图片附件已移除或不可用，请重新添加。"
        case .referenceMismatch: return "图片引用与当前附件不匹配，请重新添加。"
        case .invalidPrivateState: return "保存的私有图片数据无效或已损坏，请重新添加图片。"
        }
    }

    var errorDescription: String? { message }
}

/// Implements the SDK token-provider contract; the profile captures this exact
/// model and policy. These are admission estimates, never provider usage records.
struct DemoVisionTokenProvider: BoneInferenceImageTokenProviding {
    static let safetyMarginTokens = 1_024
    private let modelID: String
    private let policy: DemoVisionPolicy
    private let base: Int
    private let perMegapixel: Int

    init(settings: DemoLiveChatSettings) throws {
        try settings.visionPolicy.validate(settings: settings)
        guard settings.visionPolicy != .disabled else { throw DemoVisionError.disabled }
        modelID = settings.modelID
        policy = settings.visionPolicy
        base = settings.visionTokenBase
        perMegapixel = settings.visionTokensPerMegapixel
    }

    func imageTokens(for image: BoneInferenceImageInput, modelID: String) throws -> Int {
        guard modelID == self.modelID else { throw DemoVisionError.unsupportedModel }
        let metadata = image.reference.metadata
        // The rule below only covers prepared images within this host's bounds.
        try DemoChatImageStore.validatePreparedMetadata(metadata)
        switch policy {
        case .disabled: throw DemoVisionError.disabled
        case .openAI41Mini:
            // OpenAI Images and vision, "Calculating costs", GPT-4.1-mini rule:
            // https://platform.openai.com/docs/guides/images-vision#calculating-costs
            // Model snapshot: gpt-4.1-mini-2025-04-14 (and its exact documented alias).
            // Official docs returned HTTP 403 during implementation; this source
            // reference is not a claim of live verification or actual model usage.
            // ceil(w/32) * ceil(h/32), then mini's 1.62 multiplier.
            // At <=1024x1024 there are <=1024 patches, below the 1536-patch
            // resizing threshold. Integer arithmetic rounds the budget upward.
            let patches = ((metadata.width + 31) / 32) * ((metadata.height + 31) / 32)
            return (patches * 162 + 99) / 100
        case .customLinear:
            // Explicit user-configured HOST estimate, based on actual final pixels.
            let pixels = metadata.width * metadata.height
            let megapixels = (pixels + 999_999) / 1_000_000
            return base + megapixels * perMegapixel
        }
    }

    func imageInputSafetyMarginTokens(for modelID: String) throws -> Int {
        guard modelID == self.modelID else { throw DemoVisionError.unsupportedModel }
        return Self.safetyMarginTokens
    }
}
