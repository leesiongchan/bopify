import SwiftUI
import BopifyDomain
import BopifyLibrary
import BopifyPlayback

struct FavoriteButton: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment?

    var body: some View {
        if let environment, environment.player?.state.currentTrack?.uri.kind == .track {
            let model = environment.favorite
            Button {
                if model.saved == nil || model.error != nil { environment.presentation.presentPopover(.favorite) }
                else { Task { await model.toggle() } }
            } label: {
                Group {
                    if model.isPending || environment.isEnablingLibrary { ProgressView().controlSize(.mini) }
                    else { Image(systemName: model.saved == true ? "heart.fill" : model.saved == nil ? "heart.slash" : "heart") }
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.playerControl)
            .disabled(model.isPending || environment.isEnablingLibrary || model.uri != environment.player?.state.currentTrack?.uri)
            .accessibilityLabel(Text("favorite.title"))
            .accessibilityValue(Text(model.isPending ? "favorite.pending" : model.saved == true ? "favorite.saved" : model.saved == false ? "favorite.unsaved" : "favorite.unknown"))
            .help(Text(model.saved == true ? "favorite.remove" : "favorite.save"))
            .popover(isPresented: Binding(get: { environment.presentation.activePopover == .favorite },
                                           set: { if !$0 && environment.presentation.activePopover == .favorite { environment.presentation.dismissPopover() } })) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(environment.libraryAuthorizationNotice ?? favoriteNotice(for: model.error))
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    FavoriteMenuAction()
                        .disabled(model.uri != environment.player?.state.currentTrack?.uri)
                }
                .padding(16).frame(width: 260)
                .onExitCommand { environment.presentation.dismissPopover() }
            }
            .onDisappear {
                if environment.presentation.activePopover == .favorite { environment.presentation.dismissPopover() }
            }
        }
    }
}

struct FavoriteMenuAction: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment?
    var body: some View {
        if let environment, environment.player?.state.currentTrack?.uri.kind == .track {
            let model = environment.favorite
            if model.error == .authorizationRequired {
                Button("favorite.enable") { Task { await environment.enableFavorites() } }
                    .disabled(environment.isEnablingLibrary)
            } else if model.saved == nil || model.error != nil {
                Button("favorite.retry") { Task { await environment.refreshFavorite() } }
                    .disabled(model.isPending)
            } else {
                Button(model.saved == true ? "favorite.remove" : "favorite.save") { Task { await model.toggle() } }
                    .disabled(model.isPending)
            }
        }
    }
}

private func favoriteNotice(for error: LibraryError?) -> String {
    switch error {
    case .authorizationRequired: String(localized: "favorite.permission")
    case .forbidden: String(localized: "favorite.forbidden")
    case .rateLimited: String(localized: "favorite.rateLimited")
    case .quotaExceeded: String(localized: "library.quotaExceeded")
    case .invalidResponse, .unavailable: String(localized: "favorite.unavailable")
    case nil: String(localized: "favorite.unknown")
    }
}
