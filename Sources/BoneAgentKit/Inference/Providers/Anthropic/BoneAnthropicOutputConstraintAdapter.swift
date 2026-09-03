import Foundation

struct BoneAnthropicOutputConstraintAdapter: BoneProviderOutputConstraintAdapter {
    let identity = BoneProviderOutputConstraintAdapterIdentity(
        id: "bone.anthropic.messages.constraint",
        version: "1"
    )

    func supports(_ constraint: BoneInferenceOutputConstraint) -> Bool {
        (try? BoneProviderOutputConstraintSupport.wrappedSchema(for: constraint)) != nil
    }

    func requestFields(for constraint: BoneInferenceOutputConstraint) throws -> [String: Any] {
        [
            "output_config": [
                "format": [
                    "type": "json_schema",
                    "schema": try BoneProviderOutputConstraintSupport.wrappedSchema(for: constraint),
                ],
            ],
        ]
    }

    func response(
        from providerPayload: Data,
        constraint: BoneInferenceOutputConstraint
    ) throws -> BoneInferenceResponse {
        try BoneProviderOutputConstraintSupport.response(
            from: providerPayload,
            constraint: constraint
        )
    }
}
