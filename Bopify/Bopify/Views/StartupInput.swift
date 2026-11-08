import AppKit
import SwiftUI

/// The native editor keeps keyboard and secure-entry behavior; only its chrome is customized.
struct StartupInput<Content: View>: View {
    let label: String
    let identifier: String
    let isFocused: Bool
    let onActivate: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content()
            .textFieldStyle(.plain)
            .font(.body)
            .startupPrimary()
            .frame(minHeight: 20)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                StartupInputBackground(reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased)
                StartupInputAccessibility(label: SoloistResources.string(label), identifier: identifier)
                    .allowsHitTesting(false)
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

/// Hosted native text-field cells can omit SwiftUI's AX metadata. Attach the permanent
/// purpose to the existing editor without changing secure entry, focus, or keyboard handling.
private struct StartupInputAccessibility: NSViewRepresentable {
    let label: String
    let identifier: String

    func makeNSView(context: Context) -> MetadataView { MetadataView() }

    func updateNSView(_ view: MetadataView, context: Context) {
        view.label = label
        view.identifierValue = identifier
        view.scheduleUpdate()
    }

    final class MetadataView: NSView {
        var label = ""
        var identifierValue = ""
        private var pending: Task<Void, Never>?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { pending?.cancel() } else { scheduleUpdate() }
        }

        override func layout() {
            super.layout()
            applyMetadata()
        }

        func scheduleUpdate() {
            setAccessibilityElement(false)
            pending?.cancel()
            pending = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled else { return }
                self?.applyMetadata()
            }
        }

        private func applyMetadata() {
            guard window != nil, !bounds.isEmpty, !identifierValue.isEmpty else { return }
            var scope = superview
            while let ancestor = scope {
                let inputBounds = convert(bounds, to: ancestor)
                func editors(in view: NSView) -> [NSTextField] {
                    if let field = view as? NSTextField, field.isEditable,
                       field.convert(field.bounds, to: ancestor).intersects(inputBounds) { return [field] }
                    return view.subviews.flatMap(editors)
                }
                let matches = editors(in: ancestor)
                if matches.count == 1, let field = matches.first {
                    field.setAccessibilityLabel(label)
                    field.setAccessibilityIdentifier(identifierValue)
                    field.cell?.setAccessibilityLabel(label)
                    field.cell?.setAccessibilityIdentifier(identifierValue)
                    return
                }
                // Never associate this purpose with an ambiguous or unrelated editor.
                if matches.count > 1 { return }
                scope = ancestor.superview
            }
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
    var surfaceOpacity: Double = 1
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var usesSolidSurface: Bool { reduceTransparency || contrast == .increased }

    var body: some View {
        PlayerSurface(surfaceOpacity: surfaceOpacity) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    AuroraBackground(isAnimating: isAnimating, isDimmed: isDimmed)
                        .overlay {
                            if !usesSolidSurface {
                                // Viewport depth has no form-sized edge as the instructions change or scroll.
                                LinearGradient(colors: [Color(red: 0.08, green: 0.21, blue: 0.17).opacity(0.06),
                                                        Color(red: 0.08, green: 0.21, blue: 0.17).opacity(0.24)],
                                               startPoint: .top, endPoint: .bottom)
                            }
                        }
                        .opacity(surfaceOpacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .startupPrimary()
        .tint(usesSolidSurface ? .accentColor : Color(red: 0.69, green: 0.86, blue: 1))
    }
}

/// Each role keeps its hierarchy over Aurora and returns to semantic colors on solid surfaces.
private struct StartupForeground: ViewModifier {
    enum Role { case primary, supporting, status, action }
    let role: Role
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var color: Color {
        if reduceTransparency || contrast == .increased {
            return switch role {
            case .primary, .status: .primary
            case .supporting: .secondary
            case .action: .accentColor
            }
        }
        return switch role {
        case .primary: Color(red: 1, green: 0.973, blue: 0.933)
        case .supporting: Color(red: 0.882, green: 0.933, blue: 0.890)
        case .status: Color(red: 0.957, green: 0.839, blue: 0.647)
        case .action: Color(red: 0.694, green: 0.863, blue: 1)
        }
    }

    func body(content: Content) -> some View { content.foregroundStyle(color) }
}

private struct StartupActionGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .modifier(StartupForeground(role: .action))
                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.5), lineWidth: 1).allowsHitTesting(false))
        } else {
            content
                .modifier(StartupForeground(role: .action))
                .glassEffect(.regular.interactive(), in: Capsule())
        }
    }
}

extension View {
    func startupPrimary() -> some View { modifier(StartupForeground(role: .primary)) }
    func startupSupporting() -> some View { modifier(StartupForeground(role: .supporting)) }
    func startupStatus() -> some View { modifier(StartupForeground(role: .status)) }
    func startupActionGlass() -> some View { modifier(StartupActionGlass()) }
}
