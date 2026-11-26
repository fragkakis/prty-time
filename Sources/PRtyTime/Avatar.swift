import AppKit
import SwiftUI

/// A round avatar, grey until the image loads.
struct Avatar: View {
    let url: URL?
    var size: CGFloat = 22
    private let store = AvatarStore.shared

    var body: some View {
        Group {
            if let url, let image = store.images[url] {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Circle().fill(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.primary.opacity(0.1), lineWidth: 0.5))
        .accessibilityHidden(true)
        .task(id: url) {
            if let url { await store.load(url) }
        }
    }
}

/// Keeps downloaded avatars in memory, so rows don't flash grey each time the panel opens.
@MainActor @Observable
final class AvatarStore {
    static let shared = AvatarStore()

    private(set) var images: [URL: NSImage] = [:]
    @ObservationIgnored private var loading: Set<URL> = []

    func load(_ url: URL) async {
        guard images[url] == nil, loading.insert(url).inserted else { return }
        defer { loading.remove(url) }
        // On failure (offline, cancelled) nothing is stored, so the next appearance retries.
        guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else { return }
        images[url] = image
    }

    #if DEMO
    /// For `Screenshot`, whose avatars aren't downloaded.
    func preload(_ image: NSImage, for url: URL) {
        images[url] = image
    }
    #endif
}
