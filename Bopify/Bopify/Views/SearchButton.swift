import SwiftUI
import Observation
import os
import BopifyPlayback
import BopifyDomain
import BopifyLibrary

@MainActor @Observable
final class SearchPopoverController {
    private(set) var focusRevision = 0
    var isVisible: Bool { environment?.presentation.activePopover == .search }
    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private var resumesAfterAuthorization = false

    func show(environment: AppEnvironment) {
        self.environment = environment
        focusRevision += 1
        environment.presentation.presentPopover(.search)
    }

    func close() {
        resumesAfterAuthorization = false
        dismiss()
        environment?.search.cancel()
    }

    func didDismiss(environment: AppEnvironment) {
        if environment.isEnablingLibrary || environment.librarySetupWindow.isVisible {
            resumesAfterAuthorization = true
            dismiss()
        } else { close() }
    }

    func authorizationFinished(environment: AppEnvironment) {
        guard resumesAfterAuthorization else { return }
        resumesAfterAuthorization = false
        environment.showSearch()
    }

    private func dismiss() {
        if isVisible { environment?.presentation.dismissPopover() }
        BopifyLog.library.debug("catalog search dismissed")
    }
}

struct SearchButton: View {
    let environment: AppEnvironment
    private var isVisible: Bool { environment.presentation.activePopover == .search }

    private var isPresented: Binding<Bool> {
        Binding(get: { isVisible }, set: { shown in
            if shown { environment.showSearch() }
            else { environment.searchPopover.didDismiss(environment: environment) }
        })
    }

    var body: some View {
        Button {
            if isVisible { environment.searchPopover.close() }
            else { environment.showSearch() }
        } label: {
            Image(systemName: "magnifyingglass").frame(width: 28, height: 28)
        }
        .buttonStyle(.playerToggle(isOn: isVisible))
        .accessibilityLabel(Text("search.title"))
        .help(Text("search.help"))
        .disabled(environment.isPreparingForQuit || environment.authState != .signedIn)
        .popover(isPresented: isPresented, arrowEdge: .bottom) {
            SearchView(environment: environment)
        }
    }
}
