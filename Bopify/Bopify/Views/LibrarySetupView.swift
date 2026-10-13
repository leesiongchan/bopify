import AppKit
import SwiftUI
import BopifyAuth

/// Spotify allows a Development Mode app only five users, so each user registers their own app for library access.
struct LibrarySetupView: View {
    let environment: AppEnvironment
    @State private var clientID = ""
    @State private var isSaving = false
    private static let redirectURI = "http://127.0.0.1:8898/callback"

    var body: some View {
        let isValid = LibraryAuthorization.normalized(clientID) != nil
        VStack(alignment: .leading, spacing: 14) {
            Text("librarySetup.intro").fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Text("librarySetup.step1")
                Link("librarySetup.openDashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                Text("librarySetup.step2")
                HStack {
                    Text(verbatim: Self.redirectURI).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Button("librarySetup.copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.redirectURI, forType: .string)
                    }
                }
                Text("librarySetup.step3").fixedSize(horizontal: false, vertical: true)
                Text("librarySetup.step4")
            }
            TextField("librarySetup.clientID", text: $clientID)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            if !clientID.isEmpty && !isValid {
                Text("librarySetup.invalid").font(.caption).foregroundStyle(.secondary)
            }
            if let error = environment.librarySetupError {
                error.localizedText.font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("librarySetup.save") {
                    isSaving = true
                    Task { await environment.setLibraryClientID(clientID); isSaving = false }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || !isValid)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { clientID = environment.libraryClientID ?? "" }
    }
}
