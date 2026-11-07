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
    @Environment(\.colorScheme) private var colorScheme

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
                .frame(minHeight: 20)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
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
                .environment(\.colorScheme, reduceTransparency || contrast == .increased ? colorScheme : .dark)
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

/// Preserve the original full-window Aurora and glass, with semantic solid accessibility fallbacks.
struct StartupSurface<Content: View>: View {
    var isAnimating = true
    var isDimmed = false
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var usesSolidSurface: Bool { reduceTransparency || contrast == .increased }

    var body: some View {
        PlayerSurface {
            content()
                .background {
                    AuroraBackground(isAnimating: isAnimating, isDimmed: isDimmed)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                }
        }
        .foregroundStyle(usesSolidSurface ? Color.primary : .white)
        .tint(usesSolidSurface ? .accentColor : Color(red: 0.69, green: 0.86, blue: 1))
    }
}
