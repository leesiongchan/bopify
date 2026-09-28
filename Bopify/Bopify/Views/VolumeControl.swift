import SwiftUI
import BopifyPlayback
import BopifyDomain

struct VolumeControl: View {
    let player: PlayerModel
    let presentation: PlayerPresentation
    private var open: Binding<Bool> {
        Binding(get: { presentation.activePopover == .volume }, set: { value in
            if value { presentation.presentPopover(.volume) }
            else if presentation.activePopover == .volume { presentation.dismissPopover() }
        })
    }
    var body: some View {
        Button { open.wrappedValue.toggle() } label: {
            Image(systemName: player.displayVolume == 0 ? "speaker.slash" : "speaker.wave.2")
                .frame(width: 28, height: 28)
        }
        .accessibilityLabel(Text("transport.volume"))
        .accessibilityValue(Text("\(Int((player.displayVolume * 100).rounded()))%"))
        .disabled(!player.state.isActiveDevice)
        .popover(isPresented: open, arrowEdge: .bottom) {
            VStack(spacing: 10) {
                Text("\(Int((player.displayVolume * 100).rounded()))%")
                    .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                VerticalVolumeSlider(value: player.displayVolume, change: player.setVolume, begin: {
                    player.beginVolumeEditing()
                    presentation.sendAttention(.interaction(.volume, true))
                }, end: finish)
                    .frame(width: 24, height: 112)
                Button(action: player.toggleMute) {
                    Image(systemName: player.displayVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(player.displayVolume == 0 ? "transport.unmute" : "transport.mute"))
            }
            .padding(14)
            .onExitCommand { presentation.dismissPopover() }
            .onDisappear { finish() }
        }
        .onChange(of: presentation.isVisible) { _, visible in
            if !visible { player.cancelVolumeEditing(); presentation.sendAttention(.interaction(.volume, false)) }
        }
        .onChange(of: player.state.isActiveDevice) { _, active in
            if !active {
                player.cancelVolumeEditing()
                if presentation.activePopover == .volume { presentation.dismissPopover() }
            }
        }
    }
    private func finish() {
        if presentation.isVisible { player.endVolumeEditing() } else { player.cancelVolumeEditing() }
        presentation.sendAttention(.interaction(.volume, false))
    }
}

private struct VerticalVolumeSlider: NSViewRepresentable {
    let value: Double
    let change: (Double) -> Void
    let begin: () -> Void
    let end: () -> Void
    func makeNSView(context: Context) -> TrackingSlider {
        let slider = TrackingSlider(frame: CGRect(x: 0, y: 0, width: 24, height: 112))
        slider.minValue = 0; slider.maxValue = 1
        slider.isContinuous = true
        slider.target = slider
        slider.action = #selector(TrackingSlider.changed)
        slider.setAccessibilityLabel(String(localized: "transport.volume"))
        return slider
    }
    func updateNSView(_ slider: TrackingSlider, context: Context) {
        slider.doubleValue = value
        slider.change = change; slider.begin = begin; slider.end = end
    }
    final class TrackingSlider: NSSlider {
        var change: ((Double) -> Void)?
        var begin: (() -> Void)?
        var end: (() -> Void)?
        private var tracking = false
        override func mouseDown(with event: NSEvent) {
            tracking = true
            begin?()
            defer { tracking = false; end?() }
            super.mouseDown(with: event)
        }
        @objc func changed() {
            change?(doubleValue)
            if !tracking { end?() }
        }
    }
}
