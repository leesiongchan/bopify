import Nuke
import SwiftUI
import NukeUI

struct RemoteArtworkView<Placeholder: View>: View {
    let url: URL?
    let store: ArtworkStore
    let size: CGFloat
    @ViewBuilder let placeholder: () -> Placeholder
    @Environment(\.displayScale) private var displayScale
    @StateObject private var fetch = FetchImage()
    @State private var displayedIdentity: Identity?

    private struct Identity: Equatable {
        let url: URL?
        let pixelSize: Int
        let sessionRevision: Int
    }

    private var identity: Identity {
        Identity(url: url, pixelSize: size * displayScale <= 64 ? 64 : 160,
                 sessionRevision: store.sessionRevision)
    }

    var body: some View {
        Group {
            if displayedIdentity == identity, let image = fetch.image {
                image.resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: ArtworkLoadRequest(url: url, retryRevision: store.retryRevision,
                                    pixelSize: identity.pixelSize, sessionRevision: identity.sessionRevision)) {
            guard !Task.isCancelled, displayedIdentity != identity || fetch.imageContainer == nil else { return }
            displayedIdentity = identity
            guard let url else { fetch.reset(); return }
            let pixelSize = identity.pixelSize
            fetch.load {
                guard let response = await store.load(url, pixelSize: pixelSize) else {
                    throw URLError(.resourceUnavailable)
                }
                return response
            }
        }
        .onDisappear { fetch.cancel() }
    }
}
