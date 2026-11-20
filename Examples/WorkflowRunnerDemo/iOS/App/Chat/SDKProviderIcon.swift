import SwiftUI
import UIKit

/// The image bytes stay in BoneAgentKit's resource bundle; no copied channel assets.
struct SDKProviderIcon: View {
    let provider: DemoChatProvider
    var size: CGFloat = 24

    var body: some View {
        Group {
            if let image = SDKProviderImageCache.image(for: provider) {
                Image(uiImage: image).renderingMode(.original).resizable().scaledToFit()
            } else {
                Image(systemName: "server.rack").resizable().scaledToFit().foregroundStyle(.gray)
            }
        }
        .frame(width: size, height: size)
        .padding(4)
        .background(.white, in: .rect(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}

@MainActor
private enum SDKProviderImageCache {
    private static var images: [String: UIImage] = [:]

    static func image(for provider: DemoChatProvider) -> UIImage? {
        if let image = images[provider.iconID] { return image }
        guard let catalog = try? DemoChatCatalog(),
              let data = try? catalog.iconData(for: provider),
              let image = UIImage(data: data, scale: 3) else { return nil }
        images[provider.iconID] = image
        return image
    }
}
