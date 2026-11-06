import AppKit
import BopifyPlayback

enum SoloistInstallationAccessError: Error { case permissionRequired }

/// A user-granted folder scope permits downloaded code without weakening the app sandbox.
@MainActor final class SoloistInstallationAccess {
    static let bookmarkKey = "soloist.installationBookmark"
    private let defaults: UserDefaults
    private let directory: URL
    private var accessedRoot: URL?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        directory = SoloistInstaller.defaultDirectory.deletingLastPathComponent()
    }

    /// Launch and background updates restore permission silently; only an explicit setup action prompts.
    func restore() throws {
        if accessedRoot != nil { return }
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { throw SoloistInstallationAccessError.permissionRequired }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
            relativeTo: nil, bookmarkDataIsStale: &stale)
        guard matchesDirectory(url), url.startAccessingSecurityScopedResource() else { throw SoloistInstallationAccessError.permissionRequired }
        do {
            if stale { defaults.set(try url.bookmarkData(options: .withSecurityScope), forKey: Self.bookmarkKey) }
            accessedRoot = url
        } catch { url.stopAccessingSecurityScopedResource(); throw error }
    }

    func request() async throws {
        if (try? restore()) != nil { return }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let panel = NSOpenPanel()
        panel.title = SoloistResources.string("soloist.permission.title")
        panel.message = SoloistResources.string("soloist.permission.message")
        panel.prompt = SoloistResources.string("soloist.permission.allow")
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false; panel.directoryURL = directory
        NSApp.activate()
        let response = await withTaskCancellationHandler {
            await panel.begin()
        } onCancel: { Task { @MainActor in panel.cancel(nil) } }
        try Task.checkCancellation()
        guard response == .OK, let url = panel.url else { throw CancellationError() }
        guard matchesDirectory(url), url.startAccessingSecurityScopedResource() else { throw SoloistInstallationAccessError.permissionRequired }
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope)
            defaults.set(bookmark, forKey: Self.bookmarkKey)
            accessedRoot?.stopAccessingSecurityScopedResource()
            accessedRoot = url
        } catch { url.stopAccessingSecurityScopedResource(); throw error }
    }

    private func matchesDirectory(_ url: URL) -> Bool {
        url.standardizedFileURL.resolvingSymlinksInPath() == directory.standardizedFileURL.resolvingSymlinksInPath()
    }

    deinit { accessedRoot?.stopAccessingSecurityScopedResource() }
}
