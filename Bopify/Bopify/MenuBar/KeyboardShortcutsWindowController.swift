import AppKit
import SwiftUI
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let togglePlayer = Self("togglePlayer")
    static let searchMusic = Self("searchMusic")
    static let toggleLiveLyrics = Self("toggleLiveLyrics", initial: .init(.l, modifiers: [.control, .option]))
}

@MainActor
final class KeyboardShortcutsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: KeyboardShortcutsView()))
            window.title = String(localized: "shortcuts.title")
            window.identifier = NSUserInterfaceItemIdentifier("keyboard-shortcuts")
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = .clear
            window.isOpaque = false
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct KeyboardShortcutsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("shortcuts.title").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                Text("shortcuts.global").font(.headline)
                recorder("shortcuts.showPlayer", name: .togglePlayer)
                recorder("search.title", name: .searchMusic)
                recorder("shortcuts.lyrics", name: .toggleLiveLyrics)
                Text("shortcuts.global.help").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("shortcuts.player").font(.headline)
                row("shortcuts.playPause", keys: "Space")
                row("shortcuts.seek", keys: "←  →")
                row("shortcuts.changeTrack", keys: "⌘←  ⌘→")
                row("search.title", keys: "⌘F")
                row("shortcuts.title", keys: "⌘/")
                row("shortcuts.dismiss", keys: "Esc")
                Text("shortcuts.player.help").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("shortcuts.browsing").font(.headline)
                row("shortcuts.select", keys: "↑  ↓")
                row("shortcuts.browseCovers", keys: "←  →")
                row("shortcuts.playSelection", keys: "Return")
                Text("shortcuts.lyrics.help").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .padding(.top, 24)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .background { PlayerSurface(cornerRadius: 22) { Color.clear } }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .ignoresSafeArea()
    }

    private func row(_ title: LocalizedStringKey, keys: LocalizedStringKey) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 16)
            Text(keys).monospaced().foregroundStyle(.secondary)
        }
    }

    private func recorder(_ title: LocalizedStringKey, name: KeyboardShortcuts.Name) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 16)
            KeyboardShortcuts.Recorder(for: name)
            .shortcutValidation { shortcut in
                let others: [KeyboardShortcuts.Name] = [.togglePlayer, .searchMusic, .toggleLiveLyrics]
                if others.contains(where: { $0 != name && $0.shortcut == shortcut }) {
                    return .disallow(reason: String(localized: "shortcuts.conflict"))
                }
                return .allow
            }
            .accessibilityLabel(Text(title))
        }
    }
}

#if DEBUG
#Preview("Keyboard shortcuts") { KeyboardShortcutsView() }
#endif
