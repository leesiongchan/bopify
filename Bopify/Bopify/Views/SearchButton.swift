import SwiftUI
import Observation
import BopifyPlayback
import BopifyDomain
import BopifyLibrary

@MainActor @Observable
final class SearchPopoverController {
    private(set) var focusRevision = 0
    var isVisible: Bool { environment?.presentation.activePopover == .search }
    @ObservationIgnored private weak var environment: AppEnvironment?

    func show(environment: AppEnvironment) {
        self.environment = environment
        focusRevision += 1
        environment.presentation.presentPopover(.search)
    }

    func close() {
        dismiss()
        environment?.search.cancel()
    }

    private func dismiss() {
        if isVisible { environment?.presentation.dismissPopover() }
    }
}

struct SearchButton: View {
    let environment: AppEnvironment
    private var isVisible: Bool { environment.presentation.activePopover == .search }

    private var isPresented: Binding<Bool> {
        Binding(get: { isVisible }, set: { shown in
            if shown { environment.showSearch() }
            else { environment.searchPopover.close() }
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
