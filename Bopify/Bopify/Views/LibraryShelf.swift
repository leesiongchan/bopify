import SwiftUI
import os
import BopifyDomain
import BopifyLibrary

enum LibraryTab: String, CaseIterable, Identifiable {
    case recents, explore, liked
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .recents: "library.tab.recents"
        case .explore: "library.tab.explore"
        case .liked: "library.tab.liked"
        }
    }
}

/// Tabs, Explore's station chips and the shared Cover Flow in the sleeve's lower frame.
struct LibraryShelf: View {
    let environment: AppEnvironment
    let artworkStore: ArtworkStore
    let onPlay: (PlayRequest) -> Void
    @AppStorage("library.tab") private var tab: LibraryTab = .liked
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 4) {
            Picker("library.tabs", selection: $tab) {
                ForEach(LibraryTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            if tab == .explore { StationChips(model: environment.explore) }
            shelf.transition(reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .scale(scale: 0.94)))
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy, value: tab)
        .onChange(of: tab) { _, tab in
            BopifyLog.library.debug("library tab changed tab=\(tab.rawValue, privacy: .public)")
        }
    }

    /// Each source gets its own identity so Cover Flow's position and fling never carry across tabs or stations.
    @ViewBuilder private var shelf: some View {
        switch tab {
        case .recents:
            CoverFlowView(model: environment.recents, copy: .recents, artworkStore: artworkStore,
                          onPlay: { onPlay(environment.recents.playRequest(for: $0)) },
                          onEnable: { await environment.enableListeningHistory() })
                .id(LibraryTab.recents)
        case .explore:
            if environment.explore.stationFailure != nil {
                VStack(spacing: 8) {
                    Text(environment.explore.stationFailure == .unavailable ? "explore.stationsUnavailable" : "explore.stationFailed")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("explore.retryStation") { Task { await environment.explore.retryStation() } }.font(.caption)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PlayerBackgroundDragRegion())
                // No Cover Flow here to reveal Explore, yet retry and consent refresh still need it shown.
                .task { await environment.explore.reveal(at: Date()) }
                .onDisappear { environment.explore.hide(at: Date()) }
            } else {
                CoverFlowView(model: environment.explore, copy: .explore, artworkStore: artworkStore,
                              onPlay: { onPlay(environment.explore.playRequest(for: $0)) },
                              onEnable: { await environment.enableListeningHistory() })
                    .id(environment.explore.selectedSeed)
            }
        case .liked:
            CoverFlowView(model: environment.likedSongs, copy: .liked, artworkStore: artworkStore,
                          onPlay: { onPlay(environment.likedSongs.playRequest(for: $0)) },
                          onEnable: { await environment.enableLikedSongs() })
                .id(LibraryTab.liked)
        }
    }
}

/// Up to ten station chips: ♪ for a track seed, ● for an artist, a retry arrow for a failed station.
private struct StationChips: View {
    let model: ExploreModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(model.chips) { seed in chip(seed) }
                }
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.never)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                         .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .onAppear {
                // The row is recreated on every switch into Explore, so the selection must be revealed here too.
                if let seed = model.selectedSeed { proxy.scrollTo(seed, anchor: .center) }
            }
            .onChange(of: model.selectedSeed) { _, seed in
                // Chips are identified by non-optional URIs, so an optional would never match.
                if let seed { withAnimation(.snappy) { proxy.scrollTo(seed, anchor: .center) } }
            }
        }
        .frame(height: 20)
    }

    private func chip(_ seed: StationSeed) -> some View {
        let selected = seed.uri == model.selectedSeed
        let failed = model.stationFailures[seed.uri] != nil
        return Button {
            Task {
                if selected && failed { await model.retryStation() } else { await model.selectChip(seed.uri) }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: failed ? "arrow.clockwise" : seed.isArtist ? "circle.fill" : "music.note")
                    .font(.system(size: failed ? 8 : 6, weight: .semibold))
                    .opacity(0.7)
                Text(seed.name).lineLimit(1)
            }
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(selected ? Color.black : Color.primary)
            .background(Capsule().fill(selected ? Color.white.opacity(0.92) : Color.clear))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(selected ? 0 : 0.2)))
        }
        .buttonStyle(.plain)
        .id(seed.uri)
        .accessibilityLabel(Text("explore.station \(seed.name)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
