import SwiftUI
import BopifyPlayback

struct RecordDesignPicker: View {
    @State private var model: RecordDesignPickerModel
    var onClose: () -> Void = {}
    @AppStorage(RecordDesign.preferenceKey) private var rawValue = RecordDesign.classic.rawValue
    @FocusState private var focusedDesign: RecordDesign?
    private let strings = Bundle(for: RecordDesignWindowController.self)

    init(model: RecordDesignPickerModel = RecordDesignPickerModel(), onClose: @escaping () -> Void = {}) {
        _model = State(initialValue: model)
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("record.title", bundle: strings).font(.title2.weight(.semibold))
            Text("record.help", bundle: strings).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(RecordDesign.allCases, id: \.rawValue) { design in choice(design) }
            }
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

    private func choice(_ design: RecordDesign) -> some View {
        let selected = RecordDesign.resolve(rawValue) == design
        return Button { model.select(design) } label: {
            VStack(spacing: 8) {
                ZStack {
                    // Two quiet tones make the alpha visible without a special preview mode.
                    Circle().fill(LinearGradient(stops: [
                        .init(color: Color(red: 0.67, green: 0.70, blue: 0.62), location: 0.49),
                        .init(color: Color(red: 0.29, green: 0.36, blue: 0.32), location: 0.51)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing))
                    VinylPressingView(seed: 42, palette: .neutral, recordDesign: design, diameter: 124)
                    RecordMaterialSheen(design: design, diameter: 124, labelRatio: 0.43)
                    Circle().fill(Color(white: 0.56)).frame(width: 124 * 0.43, height: 124 * 0.43)
                        .overlay {
                            Image(systemName: "mountain.2.fill").font(.system(size: 23))
                                .foregroundStyle(Color(white: 0.27))
                        }
                        .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 0.5))
                    Circle().fill(.black.opacity(0.75)).frame(width: 3, height: 3)
                }
                .frame(width: 124, height: 124)
                .clipShape(Circle())
                HStack(spacing: 4) {
                    Text(LocalizedStringKey(design.nameKey), bundle: strings).font(.caption)
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                        .opacity(selected ? 1 : 0).accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.12) : .primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .secondary.opacity(0.22),
                                                                   lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focusedDesign, equals: design)
        .accessibilityLabel(Text(LocalizedStringKey(design.nameKey), bundle: strings))
        .accessibilityValue(selected ? Text("vinyl.selected", bundle: strings) : Text("vinyl.notSelected", bundle: strings))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier(design.nameKey)
    }
}
