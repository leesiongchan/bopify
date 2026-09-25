import SwiftUI
import BopifyDomain
import BopifyLibrary
import BopifyPlayback

extension EnvironmentValues {
    @Entry var favoriteEnvironment: AppEnvironment? = nil
}

struct FavoriteButton: View {
    @Environment(\.favoriteEnvironment) private var environment
    @State private var showsDetails = false

    var body: some View {
        if let environment, environment.player?.state.currentTrack?.uri.kind == .track {
            let model = environment.favorite
            Button {
                if model.saved == nil || model.error != nil { showsDetails = true }
                else { Task { await model.toggle() } }
            } label: {
                Group {
                    if model.isPending || environment.isEnablingFavorites { ProgressView().controlSize(.mini) }
                    else { Image(systemName: model.saved == true ? "heart.fill" : model.saved == nil ? "heart.slash" : "heart") }
                }
                .frame(width: 28, height: 24)
            }
            .buttonStyle(PlayerControlStyle())
            .disabled(model.isPending || environment.isEnablingFavorites)
            .accessibilityLabel(Text("favorite.title"))
            .accessibilityValue(Text(model.isPending ? "favorite.pending" : model.saved == true ? "favorite.saved" : model.saved == false ? "favorite.unsaved" : "favorite.unknown"))
            .help(Text(model.saved == true ? "favorite.remove" : "favorite.save"))
            .popover(isPresented: $showsDetails) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(environment.favoriteAuthorizationNotice ?? favoriteNotice(model.error))
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    FavoriteMenuAction()
                }
                .padding(16).frame(width: 260)
            }
        }
    }
}

struct FavoriteMenuAction: View {
    @Environment(\.favoriteEnvironment) private var environment
    var body: some View {
        if let environment, environment.player?.state.currentTrack?.uri.kind == .track {
            let model = environment.favorite
            if model.error == .authorizationRequired {
                Button("favorite.enable") { Task { await environment.enableFavorites() } }
                    .disabled(environment.isEnablingFavorites)
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

private func favoriteNotice(_ error: LibraryError?) -> String {
    switch error {
    case .authorizationRequired: String(localized: "favorite.permission")
    case .forbidden: String(localized: "favorite.forbidden")
    case .rateLimited: String(localized: "favorite.rateLimited")
    case .invalidResponse, .unavailable: String(localized: "favorite.unavailable")
    case nil: String(localized: "favorite.unknown")
    }
}
