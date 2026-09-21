import SwiftUI
import BopifyDomain

/// Async image with a deliberate placeholder when there is no artwork, or
/// while it loads.
struct ArtworkView: View {
    let artwork: Artwork?

    var body: some View {
        Group {
            if let artwork {
                AsyncImage(url: artwork.url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel(Text("artwork.placeholder"))
    }
}
