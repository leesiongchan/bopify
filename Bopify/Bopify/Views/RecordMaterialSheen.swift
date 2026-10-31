import SwiftUI

/// Lighting stays in player coordinates while the material turns beneath it.
struct RecordMaterialSheen: View {
    let design: RecordDesign
    let diameter: CGFloat
    let labelRatio: CGFloat

    var body: some View {
        if design != .classic {
            Circle().fill(AngularGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .white.opacity(0.02), location: 0.058),
                .init(color: Color(red: 0.94, green: 1, blue: 0.98).opacity(0.28), location: 0.108),
                .init(color: .white.opacity(0.02), location: 0.161),
                .init(color: .clear, location: 0.264),
                .init(color: .clear, location: 0.50),
                .init(color: Color(red: 0.95, green: 0.92, blue: 0.86).opacity(0.16), location: 0.608),
                .init(color: .clear, location: 0.694),
                .init(color: .clear, location: 1)
            ], center: .center, startAngle: .degrees(-45), endAngle: .degrees(315)))
            .opacity(design == .glass ? 0.65 : 0.8)
            .mask(Circle().strokeBorder(lineWidth: diameter * (1 - labelRatio) / 2))
            .overlay {
                Circle().strokeBorder(.white.opacity(design == .glass ? 0.28 : 0.38), lineWidth: 0.7)
                    .padding(2)
            }
            .frame(width: diameter, height: diameter)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
