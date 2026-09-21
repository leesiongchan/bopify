//
//  BopifyApp.swift
//  Bopify
//
//  Created by Harvey on 22/09/2026.
//

import SwiftUI

@main
struct BopifyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment = AppEnvironment()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(content: MiniPlayerView(environment: environment))
        Task { await environment.restoreOrPromptSignIn() }
    }
}
