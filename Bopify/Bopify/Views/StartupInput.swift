import SwiftUI

/// The native editor keeps keyboard and secure-entry behavior; only its chrome is customized.
struct StartupInput<Content: View>: View {
    let label: LocalizedStringKey
    let labelIdentifier: String
    let isFocused: Bool
    let onActivate: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label, bundle: SoloistResources.bundle)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(labelIdentifier)
            content()
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(minHeight: 22)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background {
                    StartupInputBackground(reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isFocused ? Color.accentColor : Color(nsColor: .separatorColor),
                                      lineWidth: isFocused ? 2.5 : contrast == .increased ? 1.5 : 1)
                        .allowsHitTesting(false)
                }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .simultaneousGesture(TapGesture().onEnded { _ in onActivate() })
        }
    }
}

struct StartupInputBackground: View {
    let reduceTransparency: Bool
    let increasedContrast: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if reduceTransparency || increasedContrast {
            shape.fill(Color(nsColor: .controlBackgroundColor))
        } else {
            Color.clear.glassEffect(.regular.interactive(), in: shape)
        }
    }
}

/// Content remains opaque; the record's decorative light never sits behind instructional text.
struct StartupSurface<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}
