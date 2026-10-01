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

/// Tabs, Explore's station menu and the shared Cover Flow in the sleeve's lower frame.
struct LibraryShelf: View {
    let environment: AppEnvironment
    let artworkStore: ArtworkStore
    /// How far the controls column starts right of this shelf; the tabs centre on that column so they line up with it.
    let tabsInset: CGFloat
    /// How far the sleeve's glass reaches past each side of this shelf; Cover Flow runs out to it.
    let coverBleed: CGFloat
    let onPlay: (PlayRequest) -> Void
    @AppStorage("library.tab") private var tab: LibraryTab = .liked
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 4) {
            LibraryTabBar(tab: $tab)
                .frame(maxWidth: .infinity)
                .padding(.leading, tabsInset)
            shelf.padding(.horizontal, -coverBleed).clipped()
                .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .scale(scale: 0.94)))
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
                    StationMenu(model: environment.explore)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PlayerBackgroundDragRegion())
                // No Cover Flow here to reveal Explore, yet retry and consent refresh still need it shown.
                .task { await environment.explore.reveal(at: Date()) }
                .onDisappear { environment.explore.hide(at: Date()) }
            } else {
                CoverFlowView(model: environment.explore, copy: .explore, artworkStore: artworkStore,
                              onPlay: { onPlay(environment.explore.playRequest(for: $0)) },
                              onEnable: { await environment.enableListeningHistory() }) {
                    StationMenu(model: environment.explore)
                }
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

/// Glass tabs with a sliding highlight, in the same glass as the player's other floating controls.
private struct LibraryTabBar: View {
    @Binding var tab: LibraryTab
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 0) {
            ForEach(LibraryTab.allCases) { item in
                Button { tab = item } label: {
                    Text(item.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(item == tab ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background {
                            if item == tab {
                                Capsule().fill(Color.primary.opacity(0.14)).matchedGeometryEffect(id: "tab", in: highlight)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item == tab ? .isSelected : [])
            }
        }
        .padding(2)
        .playerGlass(prominent: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("library.tabs"))
    }
}

/// "from ♪ station" after the artist, like Music's "Playing from": a glass button that opens every station.
private struct StationMenu: View {
    let model: ExploreModel

    var body: some View {
        if let selected = model.chips.first(where: { $0.uri == model.selectedSeed }) {
            Menu {
                Picker("explore.stations", selection: Binding(get: { model.selectedSeed }, set: { seed in
                    if let seed { Task { await model.selectChip(seed) } }
                })) {
                    ForEach(model.chips) { seed in
                        Label(seed.name, systemImage: glyph(seed)).tag(Optional(seed.uri))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 3) {
                    Text("explore.from")
                    Image(systemName: glyph(selected)).font(.system(size: 7, weight: .semibold)).opacity(0.7)
                    Text(selected.name).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 6, weight: .bold)).opacity(0.6)
                }
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .playerGlass(prominent: true)
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .layoutPriority(1)
            .help(Text("explore.stations"))
            .accessibilityLabel(Text("explore.station \(selected.name)"))
        }
    }

    private func glyph(_ seed: StationSeed) -> String {
        model.stationFailures[seed.uri] != nil ? "arrow.clockwise" : seed.isArtist ? "person.fill" : "music.note"
    }
}
