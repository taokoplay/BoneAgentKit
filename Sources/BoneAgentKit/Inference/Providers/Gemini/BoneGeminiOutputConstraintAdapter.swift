import Foundation

struct BoneGeminiOutputConstraintAdapter: BoneProviderOutputConstraintAdapter {
    let identity = BoneProviderOutputConstraintAdapterIdentity(
        id: "bone.gemini.generate-content.constraint",
        version: "1"
    )

    func supports(_ constraint: BoneInferenceOutputConstraint) -> Bool {
        (try? BoneProviderOutputConstraintSupport.wrappedSchema(for: constraint)) != nil
    }

    func requestFields(for constraint: BoneInferenceOutputConstraint) throws -> [String: Any] {
        [
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": try BoneProviderOutputConstraintSupport.wrappedSchema(for: constraint),
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
