import Foundation

struct BoneOpenAIOutputConstraintAdapter: BoneProviderOutputConstraintAdapter {
    let identity = BoneProviderOutputConstraintAdapterIdentity(
        id: "bone.openai.chat-completions.constraint",
        version: "1"
    )

    func supports(_ constraint: BoneInferenceOutputConstraint) -> Bool {
        (try? BoneProviderOutputConstraintSupport.wrappedSchema(for: constraint)) != nil
    }

    func requestFields(for constraint: BoneInferenceOutputConstraint) throws -> [String: Any] {
        [
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "bone_output_constraint",
                    "strict": true,
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
