import SwiftUI

struct ArtworkView: View {
    let image: Image?
    var diameter: CGFloat = 204

    var body: some View {
        Group {
            if let image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Color(white: 0.12))
                    Image(systemName: "music.note")
                        .font(.system(size: diameter * 0.25, weight: .light))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}
