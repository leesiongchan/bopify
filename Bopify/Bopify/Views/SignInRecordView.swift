import SwiftUI
import BopifyDomain
import os

enum SignInRecordPose: Equatable { case out, spinning, tucked }
enum RecordSide: Equatable { case a, b }
enum LibrarySetupStatus: Hashable { case idle, authorizing, refused }

/// Everything shown before the player, on one record: sign-in and library setup are its two sides, so moving
/// between them, or on to connecting, never swaps the scene.
enum StartupStep: Hashable {
    case signIn(SignInStatus)
    case library(LibrarySetupStatus)
    /// The message key is part of the step so a change of wording cross-fades like any other step.
    case connection(messageKey: String, isFailure: Bool)

    /// The setup step shown in the header, or nil for returning users who are only being reconnected.
    var progress: Int? {
        switch self {
        case .signIn(.idle), .signIn(.authenticating), .signIn(.error): 1
        case .library: 2
        case .signIn(.restoring), .signIn(.removingCredentials), .connection: nil
        }
    }

    /// Nil keeps whichever side is showing, so connecting after setup doesn't flip the record back.
    var side: RecordSide? {
        switch self {
        case .signIn: .a
        case .library: .b
        case .connection: nil
        }
    }

    /// Library setup needs the room for its list, so the record steps back rather than leaving.
    var isCompact: Bool {
        if case .library = self { true } else { false }
    }

    var recordPose: SignInRecordPose {
        switch self {
        case .signIn(.idle), .library(.idle): .out
        case .signIn(.authenticating), .signIn(.restoring), .signIn(.removingCredentials), .library(.authorizing): .spinning
        case .signIn(.error), .library(.refused): .tucked
        case let .connection(_, isFailure): isFailure ? .tucked : .spinning
        }
    }
}

/// The logo acted out: the record slides out of its frosted sleeve to invite sign-in, spins while work is in
/// progress, sinks back in on failure, and turns over to side B for library setup.
struct SignInRecordView: View {
    let step: StartupStep
    var isVisible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var lift = Metrics.insideLift
    @State private var turn = 0.0
    @State private var spinStart: Date?
    @State private var isPresented = false
    @State private var shownSide: RecordSide?
    @State private var flip: CGFloat = 1

    private var pose: SignInRecordPose { step.recordPose }
    private var scale: CGFloat { step.isCompact ? 0.55 : 0.88 }

    private enum Metrics {
        static let stage = CGSize(width: 250, height: 324)
        static let sleeve = CGSize(width: 232, height: 200)
        /// The record rests this far above the sleeve's bottom edge, inside the sleeve's thickness.
        static let well: CGFloat = 8
        static let insideLift: CGFloat = 2
        static let tuckedLift: CGFloat = 28
        static let outLift: CGFloat = 112
        /// 33⅓ rpm.
        static let spinDegreesPerSecond = 200.0
    }

    private struct Trigger: Equatable {
        let pose: SignInRecordPose
        let isVisible: Bool
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: spinStart == nil || !isVisible || reduceMotion)) { context in
            let angle = Angle.degrees(turn + spunDegrees(at: context.date))
            ZStack(alignment: .bottom) {
                Ellipse().fill(.black.opacity(0.6))
                    .frame(width: 236, height: 26)
                    .blur(radius: 5)
                    .offset(y: 8)
                placedRecord(angle)
                    .mask {
                        ZStack(alignment: .bottom) {
                            Rectangle()
                            SleeveShape().frame(width: Metrics.sleeve.width, height: Metrics.sleeve.height)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
                // What shows through the plastic: the same record, frosted, clipped exactly to the sleeve.
                placedRecord(angle)
                    .blur(radius: 6)
                    .brightness(-0.12)
                    .mask(alignment: .bottom) {
                        SleeveShape().frame(width: Metrics.sleeve.width, height: Metrics.sleeve.height)
                    }
                Sleeve(isOpaque: reduceTransparency)
                    .frame(width: Metrics.sleeve.width, height: Metrics.sleeve.height)
            }
            .frame(width: Metrics.stage.width, height: Metrics.stage.height)
            .rotation3DEffect(.degrees(10), axis: (x: 1, y: 0, z: 0), anchor: UnitPoint(x: 0.5, y: 0.9), perspective: 0.35)
        }
        .scaleEffect(scale)
        .frame(width: Metrics.stage.width * scale, height: Metrics.stage.height * scale)
        .animation(reduceMotion ? nil : .spring(duration: 0.8, bounce: 0.15), value: scale)
        .accessibilityHidden(true)
        .task(id: Trigger(pose: pose, isVisible: isVisible)) { await settle() }
        .onAppear { if shownSide == nil { shownSide = step.side ?? .a } }
        .onChange(of: step.side) { _, side in
            // The shown side only changes once the record is edge-on.
            if let side, side != shownSide { turnOver(to: side) }
        }
    }

    private func placedRecord(_ angle: Angle) -> some View {
        RecordDisc(angle: angle, side: shownSide ?? step.side ?? .a, isSad: pose == .tucked)
            .scaleEffect(x: flip, y: 1)
            .saturation(pose == .tucked ? 0.2 : 1)
            .brightness(pose == .tucked ? -0.12 : 0)
            .animation(.easeInOut(duration: reduceMotion ? 0.16 : 0.8), value: pose)
            .offset(y: -lift)
            .padding(.bottom, Metrics.well)
            .frame(width: Metrics.stage.width, height: Metrics.stage.height, alignment: .bottom)
    }

    private func spunDegrees(at date: Date) -> Double {
        spinStart.map { date.timeIntervalSince($0) * Metrics.spinDegreesPerSecond } ?? 0
    }

    private func upright(_ degrees: Double) -> Double { (degrees / 360).rounded(.up) * 360 }

    private func turnOver(to side: RecordSide) {
        guard !reduceMotion else {
            shownSide = side
            return
        }
        withAnimation(.easeIn(duration: 0.3)) { flip = 0 } completion: {
            shownSide = side
            withAnimation(.easeOut(duration: 0.35)) { flip = 1 }
        }
    }

    private func settle() async {
        // Fold any spin into the resting angle so the label carries on from where it is.
        turn += spunDegrees(at: .now)
        spinStart = nil
        guard isVisible else {
            isPresented = false
            return
        }
        BopifyLog.auth.debug("startup record pose=\(String(describing: pose), privacy: .public) progress=\(step.progress ?? 0)")
        let animation: (Animation) -> Animation? = { reduceMotion ? nil : $0 }
        switch pose {
        case .out where !isPresented && !reduceMotion:
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                lift = Metrics.insideLift
                turn = upright(turn) - 660
            }
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            withAnimation(.spring(duration: 1.9, bounce: 0.12)) { lift = Metrics.outLift }
            withAnimation(.timingCurve(0.15, 0.7, 0.25, 1, duration: 1.9)) { turn += 660 }
        case .out:
            withAnimation(animation(.spring(duration: 0.9, bounce: 0.1))) {
                lift = Metrics.outLift
                turn = upright(turn)
            }
        case .spinning:
            withAnimation(animation(.spring(duration: 0.9, bounce: 0.1))) { lift = Metrics.outLift }
            if !reduceMotion { spinStart = .now }
        case .tucked:
            withAnimation(animation(.easeInOut(duration: 1))) {
                lift = Metrics.tuckedLift
                turn = upright(turn) - 8
            }
        }
        isPresented = true
    }
}

private struct RecordDisc: View {
    let angle: Angle
    let side: RecordSide
    let isSad: Bool
    private let size: CGFloat = 200
    private let label: CGFloat = 66

    var body: some View {
        ZStack {
            // The tilt exposes the disc's edge below its face.
            Circle().fill(Color(white: 0.016))
                .offset(y: 2.5)
                .shadow(color: .black.opacity(0.55), radius: 8, y: 8)
            // Lighting is fixed, so the grooves don't turn; only the label and dust reveal the spin.
            VinylPressingView(diameter: size)
            ZStack {
                RecordDust()
                RecordLabel(side: side, isSad: isSad).frame(width: label, height: label)
            }
            .rotationEffect(angle)
            Circle().fill(RadialGradient(colors: [.white.opacity(0.22), .clear], center: UnitPoint(x: 0.32, y: 0.28),
                                         startRadius: 0, endRadius: label * 0.5))
                .overlay(Circle().fill(RadialGradient(colors: [Color(red: 0.24, green: 0.08, blue: 0).opacity(0.28), .clear],
                                                      center: UnitPoint(x: 0.7, y: 0.8), startRadius: 0, endRadius: label * 0.6)))
                .frame(width: label, height: label)
            Circle().fill(RadialGradient(colors: [Color(white: 0.1), .black], center: UnitPoint(x: 0.5, y: 0.65),
                                         startRadius: 0, endRadius: 3))
                .frame(width: 6, height: 6)
                .shadow(color: .white.opacity(0.25), radius: 0, y: 0.5)
        }
        .frame(width: size, height: size)
    }
}

private struct RecordLabel: View {
    let side: RecordSide
    let isSad: Bool
    private var sideLetter: String { side == .a ? "A" : "B" }

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(stops: [
                .init(color: Color(red: 1, green: 0.54, blue: 0.18), location: 0),
                .init(color: Color(red: 1, green: 0.48, blue: 0.1), location: 0.6),
                .init(color: Color(red: 0.93, green: 0.42, blue: 0.05), location: 1),
            ], center: .center, startRadius: 0, endRadius: 33))
            Canvas { context, size in draw(in: &context, unit: size.width / 100) }
        }
        .colorEffect(ShaderLibrary.paperGrain())
        .clipShape(Circle())
        .overlay(Circle().stroke(.black.opacity(0.55), lineWidth: 1))
    }

    /// Drawn on a 100-unit grid.
    private func draw(in context: inout GraphicsContext, unit: CGFloat) {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * unit, y: y * unit) }
        func ring(_ radius: CGFloat) -> Path { Path(ellipseIn: CGRect(x: (50 - radius) * unit, y: (50 - radius) * unit,
                                                                     width: radius * 2 * unit, height: radius * 2 * unit)) }
        let ink = Color(red: 0.24, green: 0.08, blue: 0)
        context.stroke(ring(46.5), with: .color(ink.opacity(0.35)), lineWidth: 0.5 * unit)
        context.stroke(ring(44.5), with: .color(ink.opacity(0.25)), lineWidth: 0.3 * unit)

        // Ring text starts at nine o'clock and runs clockwise over the top.
        let radius = 39 * unit
        var angle = Double.pi * 1.02
        for character in "BOPIFY RECORDS · SIDE \(sideLetter) · 33⅓ RPM · STEREO · BOP-001 ·" {
            let glyph = context.resolve(Text(verbatim: String(character))
                .font(.system(size: 5.4 * unit, weight: .bold)).foregroundStyle(ink.opacity(0.55)))
            let advance = glyph.measure(in: CGSize(width: 100, height: 100)).width + 1.4 * unit
            let middle = angle + Double(advance / 2 / radius)
            var glyphContext = context
            glyphContext.translateBy(x: 50 * unit + radius * cos(middle), y: 50 * unit + radius * sin(middle))
            glyphContext.rotate(by: .radians(middle + .pi / 2))
            glyphContext.draw(glyph, at: .zero, anchor: .bottom)
            angle += Double(advance / radius)
        }

        func print(_ text: String, size: CGFloat, weight: Font.Weight, opacity: Double, at x: CGFloat, _ y: CGFloat) {
            context.draw(Text(verbatim: text).font(.system(size: size * unit, weight: weight)).foregroundStyle(ink.opacity(opacity)),
                         at: point(x, y), anchor: .bottom)
        }
        print("Bopify", size: 9, weight: .heavy, opacity: 0.85, at: 50, 32)
        print("SIDE", size: 4.2, weight: .semibold, opacity: 0.55, at: 22, 53.5)
        print(sideLetter, size: 6, weight: .heavy, opacity: 0.6, at: 22, 60)
        print("33⅓", size: 4.6, weight: .bold, opacity: 0.55, at: 78, 57)

        var mouth = Path()
        if isSad {
            mouth.move(to: point(35, 76))
            mouth.addQuadCurve(to: point(65, 76), control: point(50, 64))
        } else {
            mouth.move(to: point(33, 64))
            mouth.addQuadCurve(to: point(67, 64), control: point(50, 81))
        }
        context.stroke(mouth, with: .color(Color(red: 0.11, green: 0.08, blue: 0.06)),
                       style: StrokeStyle(lineWidth: 4.6 * unit, lineCap: .round))
    }
}

/// Dust and hairline scratches: the only asymmetric marks on the disc, so they turn with the label.
struct RecordDust: View {
    private static func hash(_ n: Double) -> Double {
        let s = sin(n * 127.1) * 43758.5453
        return s - s.rounded(.down)
    }

    var body: some View {
        Canvas { context, size in
            let radius = size.width / 2
            for k in 0..<70 {
                let r = radius * (0.4 + Self.hash(Double(k) + 1) * 0.55), t = Self.hash(Double(k) + 99) * 2 * .pi
                let dot = 0.2 + Self.hash(Double(k) + 3) * 0.35
                context.fill(Path(ellipseIn: CGRect(x: radius + r * cos(t) - dot, y: radius + r * sin(t) - dot, width: dot * 2, height: dot * 2)),
                             with: .color(.white.opacity(0.12 + Self.hash(Double(k) + 7) * 0.3)))
            }
            for k in 0..<4 {
                let start = Self.hash(Double(k) + 60) * 2 * .pi
                var scratch = Path()
                scratch.addArc(center: CGPoint(x: radius + 1.5, y: radius - 1), radius: radius * (0.45 + Self.hash(Double(k) + 50) * 0.45),
                               startAngle: .radians(start), endAngle: .radians(start + 0.35 + Self.hash(Double(k) + 70) * 0.5), clockwise: false)
                context.stroke(scratch, with: .color(.white.opacity(0.1)), lineWidth: 0.3)
            }
        }
    }
}

/// Smoky mint polypropylene with a rolled lip, a diagonal glare, and a shadow where the record enters.
private struct Sleeve: View {
    let isOpaque: Bool

    var body: some View {
        let shape = SleeveShape()
        ZStack(alignment: .bottom) {
            shape.fill(LinearGradient(stops: [
                .init(color: Color(red: 0.47, green: 0.63, blue: 0.56).opacity(isOpaque ? 1 : 0.42), location: 0),
                .init(color: Color(red: 0.35, green: 0.5, blue: 0.44).opacity(isOpaque ? 1 : 0.4), location: 0.6),
                .init(color: Color(red: 0.27, green: 0.43, blue: 0.38).opacity(isOpaque ? 1 : 0.48), location: 1),
            ], startPoint: .top, endPoint: .bottom))
            .colorEffect(ShaderLibrary.paperGrain())
            shape.fill(LinearGradient(colors: [.black.opacity(0.3), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.28)))
            shape.fill(LinearGradient(stops: [
                .init(color: .clear, location: 0.24),
                .init(color: .white.opacity(0.13), location: 0.35),
                .init(color: .white.opacity(0.02), location: 0.46),
                .init(color: .clear, location: 0.52),
            ], startPoint: UnitPoint(x: 0, y: 0.3), endPoint: UnitPoint(x: 1, y: 0.7)))
            shape.stroke(.white.opacity(0.36), lineWidth: 1)
            SleeveShape(isLip: true).stroke(.white.opacity(0.14), lineWidth: 2)
            Rectangle().fill(.black.opacity(0.3)).frame(height: 2).padding(.horizontal, 14).offset(y: -1)
        }
    }
}

/// The logo's sleeve outline, with its scalloped thumb cut, on a 232×200 grid.
private nonisolated struct SleeveShape: Shape {
    var isLip = false

    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 232, sy = rect.height / 200
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var path = Path()
        if isLip {
            // The rolled edge, just inside the opening.
            path.move(to: p(3, 19))
            path.addQuadCurve(to: p(17, 6), control: p(3, 6))
            path.addLine(to: p(62, 6))
            path.addCurve(to: p(116, 44), control1: p(84, 6), control2: p(89, 44))
            path.addCurve(to: p(170, 6), control1: p(143, 44), control2: p(148, 6))
            path.addLine(to: p(215, 6))
            path.addQuadCurve(to: p(229, 19), control: p(229, 6))
            return path
        }
        path.move(to: p(0, 18))
        path.addQuadCurve(to: p(16, 2), control: p(0, 2))
        path.addLine(to: p(62, 2))
        path.addCurve(to: p(116, 40), control1: p(86, 2), control2: p(90, 40))
        path.addCurve(to: p(170, 2), control1: p(142, 40), control2: p(146, 2))
        path.addLine(to: p(216, 2))
        path.addQuadCurve(to: p(232, 18), control: p(232, 2))
        path.addLine(to: p(232, 184))
        path.addQuadCurve(to: p(216, 200), control: p(232, 200))
        path.addLine(to: p(16, 200))
        path.addQuadCurve(to: p(0, 184), control: p(0, 200))
        path.closeSubpath()
        return path
    }
}

#Preview("Sign-in record") {
    HStack(spacing: 24) {
        SignInRecordView(step: .signIn(.idle))
        SignInRecordView(step: .signIn(.authenticating))
        SignInRecordView(step: .signIn(.error(.credentialCorrupt)))
        SignInRecordView(step: .library(.idle))
    }
    .padding(24)
    .background(LinearGradient(colors: [Color(red: 0.4, green: 0.6, blue: 0.5), Color(red: 0.8, green: 0.45, blue: 0.2)],
                               startPoint: .topLeading, endPoint: .bottomTrailing))
}
