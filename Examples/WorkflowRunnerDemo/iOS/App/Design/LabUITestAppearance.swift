#if DEBUG
import SwiftUI

/// Deterministic appearance for explicitly isolated UI tests only.
struct LabUITestAppearance: ViewModifier {
    let isTesting: Bool
    @Environment(\.dynamicTypeSize) private var systemTypeSize
    private let arguments = ProcessInfo.processInfo.arguments

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(isTesting && arguments.contains("--ui-test-dark") ? .dark : nil)
            .dynamicTypeSize(isTesting && arguments.contains("--ui-test-large-text") ? .xxxLarge : systemTypeSize)
    }
}
#endif
