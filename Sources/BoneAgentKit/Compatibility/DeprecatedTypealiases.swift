import Foundation

/// 旧名称仅用于源码迁移；新代码请使用 Context Window 术语。
@available(*, deprecated, renamed: "BoneModelContextLimits")
public typealias BoneInferenceModelTokenLimits = BoneModelContextLimits

@available(*, deprecated, renamed: "BoneTokenEstimator")
public typealias BoneInferenceTokenEstimator = BoneTokenEstimator

@available(*, deprecated, renamed: "BoneContextWindowPlanner")
public typealias BoneInferenceTokenBudgetPlanner = BoneContextWindowPlanner

@available(*, deprecated, renamed: "BoneContextWindowPlan")
public typealias BoneInferenceTokenBudgetPlan = BoneContextWindowPlan

@available(*, deprecated, renamed: "BoneContextWindowError")
public typealias BoneInferenceTokenBudgetError = BoneContextWindowError

@available(*, deprecated, renamed: "BoneModelContextLimitsError")
public typealias BoneInferenceModelTokenLimitsError = BoneModelContextLimitsError
