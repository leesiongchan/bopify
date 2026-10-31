import SwiftUI
import BopifyPlayback

struct VinylDesignPicker: View {
    @State private var model: VinylDesignPickerModel
    var onClose: () -> Void = {}
    @AppStorage(VinylDesign.preferenceKey) private var rawValue = VinylDesign.original.rawValue
    @FocusState private var focusedDesign: VinylDesign?
    private let strings = Bundle(for: VinylDesignWindowController.self)
    private var selected: VinylDesign { .resolve(rawValue) }
    private let palette = ArtworkPalette.marble(
        ArtworkColor(red: 0.9333, green: 0.5098, blue: 0.4510),
        ArtworkColor(red: 0.7255, green: 0.8392, blue: 0.7608),
        ArtworkColor(red: 0.9569, green: 0.8745, blue: 0.6078))

    init(model: VinylDesignPickerModel = VinylDesignPickerModel(), onClose: @escaping () -> Void = {}) {
        _model = State(initialValue: model)
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("vinyl.title", bundle: strings).font(.title2.weight(.semibold))
            Text("vinyl.paletteHelp", bundle: strings).font(.caption).foregroundStyle(.secondary)
            choice(.original)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(VinylDesign.allCases.filter { $0 != .original }, id: \.rawValue) { design in
                    choice(design)
                }
            }
            Text("vinyl.mutedHelp", bundle: strings).font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).padding(.top, 24)
        .frame(width: 540).fixedSize(horizontal: false, vertical: true)
        .background { PlayerSurface(cornerRadius: 22) { Color.clear } }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .ignoresSafeArea()
        .onExitCommand(perform: onClose)
        .defaultFocus($focusedDesign, model.focused)
        .onChange(of: model.focused, initial: true) { _, value in focusedDesign = value }
        .onChange(of: focusedDesign) { _, value in if let value { model.focused = value } }

    }

    private func choice(_ design: VinylDesign) -> some View {
        let isSelected = selected == design
        return Button {
            model.select(design)
        } label: {
            Group {
                if design == .original {
                    HStack {
                        Text(LocalizedStringKey(design.nameKey), bundle: strings)
                        Text("vinyl.originalHelp", bundle: strings).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        checkmark(isSelected)
                    }
                } else {
                    VStack(spacing: 8) {
                        VinylPressingView(seed: 42, palette: palette, design: design, diameter: 124)
                            .overlay {
                                Circle().fill(Color(red: 0.9569, green: 0.8745, blue: 0.6078))
                                    .frame(width: 124 * 0.43, height: 124 * 0.43)
                                    .overlay(Circle().fill(.black.opacity(0.65)).frame(width: 3, height: 3))
                            }
                        HStack(spacing: 4) {
                            Text(LocalizedStringKey(design.nameKey), bundle: strings).font(.caption)
                            checkmark(isSelected)
                        }
                    }.frame(maxWidth: .infinity)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.accentColor.opacity(0.12) : .primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? Color.accentColor : .secondary.opacity(0.22), lineWidth: isSelected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focusedDesign, equals: design)
        .accessibilityLabel(Text(LocalizedStringKey(design.nameKey), bundle: strings))
        .accessibilityValue(isSelected ? Text("vinyl.selected", bundle: strings) : Text("vinyl.notSelected", bundle: strings))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier(design.nameKey)
    }

    private func checkmark(_ selected: Bool) -> some View {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
            .opacity(selected ? 1 : 0).accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Vinyl chooser") { VinylDesignPicker() }
#endif
