import SwiftUI

struct RecordAppearanceDeck: View {
    let geometry: RecordAppearanceGeometry
    let snapshot: RecordAppearanceMotion.Snapshot
    var hardwareOnly = false
    private var compact: Bool { geometry.sceneWidth < 820 }
    private let metal = Color(red: 0.80, green: 0.82, blue: 0.78)

    var body: some View {
        ZStack(alignment: .topLeading) {
            if hardwareOnly {
                ForEach(RecordAppearanceFamily.allCases, id: \.self) { family in hardware(family) }
            } else {
                if let image = RecordAppearanceResources.deck {
                    Image(nsImage: image).resizable().interpolation(.high)
                        .frame(width: geometry.deckFrame.width, height: geometry.deckFrame.height)
                        .position(x: geometry.deckFrame.midX, y: geometry.deckFrame.midY)
                } else {
                    RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.16))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(metal.opacity(0.4)))
                        .frame(width: geometry.deckFrame.width, height: geometry.deckFrame.height)
                        .position(x: geometry.deckFrame.midX, y: geometry.deckFrame.midY)
                }
                nameplate.position(geometry.sourcePoint(754.5, 165))
                ForEach(RecordAppearanceFamily.allCases, id: \.self) { family in
                    Text(LocalizedStringKey(snapshot.deck(in: family).labelChoice.nameKey), bundle: RecordAppearanceResources.bundle)
                        .font(RecordAppearanceResources.recordFont(compact: compact))
                        .foregroundStyle(Color(red: 0.875, green: 0.831, blue: 0.741))
                        .position(geometry.sourcePoint(family == .material ? 428 : 1082, 876))
                }
            }
        }
        .frame(width: geometry.sceneWidth, height: geometry.sceneHeight)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
    private var nameplate: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(LinearGradient(colors: [Color(white: 0.14), Color(white: 0.055)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(metal.opacity(0.8), lineWidth: 0.7))
            HStack {
                screw(size: 2.4)
                Spacer(minLength: 0)
                Text(verbatim: "BOPIFY").font(RecordAppearanceResources.plateFont(compact: compact))
                    .tracking(compact ? 0.85 : 1.05).foregroundStyle(metal)
                Spacer(minLength: 0)
                screw(size: 2.4)
            }.padding(.horizontal, 3)
        }.frame(width: compact ? 48 : 54, height: compact ? 16 : 18)
    }
    private func screw(size: CGFloat) -> some View {
        Circle().fill(LinearGradient(colors: [metal, Color(white: 0.22)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Rectangle().fill(.black.opacity(0.75)).frame(width: size * 0.65, height: 0.5).rotationEffect(.degrees(-28)))
            .frame(width: size, height: size)
    }
    private func hardware(_ family: RecordAppearanceFamily) -> some View {
        let pivot = geometry.tonearmPivot(in: family)
        let deck = snapshot.deck(in: family)
        return ZStack(alignment: .topLeading) {
            Circle().fill(.black.opacity(0.85)).frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(metal.opacity(0.55), lineWidth: 1))
                .overlay(Circle().strokeBorder(.black, lineWidth: 2).padding(3))
                .shadow(color: .black.opacity(0.7), radius: 2, x: 1, y: 2)
                .position(pivot)
            RoundedRectangle(cornerRadius: 1).fill(metal.opacity(0.7)).frame(width: 4, height: 10)
                .overlay(Rectangle().fill(.black).frame(width: 1, height: 6))
                .position(x: pivot.x + (family == .material ? 10 : -10), y: pivot.y + 37)
            RecordAppearanceTonearm(pivot: pivot, length: geometry.armLength,
                                    angle: deck.armAngle, lift: deck.needleLift)
            Circle().fill(RadialGradient(colors: [.white, metal, Color(white: 0.22)], center: .topLeading, startRadius: 0, endRadius: 3))
                .frame(width: 5, height: 5).position(geometry.platterCenter(in: family))
        }
    }
}

private struct RecordAppearanceTonearm: View {
    let pivot: CGPoint
    let length: CGFloat
    let angle: Double
    let lift: Double
    var body: some View {
        Canvas { context, _ in
            context.translateBy(x: pivot.x, y: pivot.y)
            context.rotate(by: .degrees(angle))
            context.addFilter(.shadow(color: .black.opacity(0.6), radius: 1.4 + lift * 1.6,
                                      x: 1 + lift, y: 2 + lift * 2))
            func rectangle(_ rect: CGRect, radius: CGFloat, colors: [Color]) {
                context.fill(Path(roundedRect: rect, cornerRadius: radius),
                             with: .linearGradient(Gradient(colors: colors), startPoint: CGPoint(x: rect.minX, y: 0), endPoint: CGPoint(x: rect.maxX, y: 0)))
            }
            let dark = Color(red: 0.10, green: 0.15, blue: 0.14)
            let bright = Color(red: 0.51, green: 0.59, blue: 0.55)
            rectangle(CGRect(x: -3, y: -15, width: 6, height: length + 15), radius: 2, colors: [.black, bright, dark, .black])
            rectangle(CGRect(x: -6, y: -16, width: 12, height: 12), radius: 4, colors: [.black, bright.opacity(0.6), dark, .black])
            for y in stride(from: -14.0, through: -6.0, by: 3) {
                context.stroke(Path(CGRect(x: -5, y: y, width: 10, height: 0.3)), with: .color(.black.opacity(0.7)), lineWidth: 0.4)
            }
            rectangle(CGRect(x: -5, y: length - 10, width: 10, height: 18), radius: 2, colors: [.black, bright, dark])
            rectangle(CGRect(x: -3.5, y: length + 3, width: 7, height: 5), radius: 1, colors: [Color(white: 0.15), Color(white: 0.5), .black])
            for y in [length - 6, length + 1] {
                context.fill(Path(ellipseIn: CGRect(x: -1, y: y, width: 2, height: 2)), with: .color(Color(white: 0.75)))
            }
            var stylus = Path()
            stylus.move(to: CGPoint(x: 0, y: length + 7)); stylus.addLine(to: CGPoint(x: 1, y: length + 10))
            context.stroke(stylus, with: .color(Color(white: 0.8)), lineWidth: 0.6)
            context.fill(Path(ellipseIn: CGRect(x: -5, y: -5, width: 10, height: 10)),
                         with: .radialGradient(Gradient(colors: [bright, dark, .black]), center: CGPoint(x: -2, y: -2), startRadius: 0, endRadius: 7))
        }
    }
}
