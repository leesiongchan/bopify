import SwiftUI

struct ArtworkView: View {
    let image: Image?
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            Circle()
                .fill(.primary.opacity(0.025))
                .overlay(Circle().strokeBorder(.primary.opacity(contrast == .increased ? 0.5 : 0.12)))
                .frame(width: 188, height: 188)
            Circle()
                .strokeBorder(.primary.opacity(contrast == .increased ? 0.4 : 0.08))
                .frame(width: 170, height: 170)
            Group {
                if let image {
                    image.resizable().scaledToFill()
                } else {
                    ZStack {
                        Circle().fill(.primary.opacity(0.06))
                        Image(systemName: "music.note")
                            .font(.system(size: 42, weight: .light))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 148, height: 148)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 188)
        // The adjacent title and artist already identify this decoration.
        .accessibilityHidden(true)
    }
}
