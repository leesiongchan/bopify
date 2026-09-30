import SwiftUI
import BopifyPlayback
import BopifyDomain

struct VolumeControl: View {
    let player: PlayerModel
    let presentation: PlayerPresentation
    private var isPopoverPresented: Binding<Bool> {
        Binding(get: { presentation.activePopover == .volume }, set: { value in
            if value { presentation.presentPopover(.volume) }
            else if presentation.activePopover == .volume { presentation.dismissPopover() }
        })
    }
    var body: some View {
        Button { isPopoverPresented.wrappedValue.toggle() } label: {
            Image(systemName: player.displayVolume == 0 ? "speaker.slash" : "speaker.wave.2")
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
        }
        .accessibilityLabel(Text("transport.volume"))
        .accessibilityValue(Text("\(Int((player.displayVolume * 100).rounded()))%"))
        .disabled(!player.state.isActiveDevice)
        .popover(isPresented: isPopoverPresented, arrowEdge: .bottom) {
            VStack(spacing: 10) {
                Text("\(Int((player.displayVolume * 100).rounded()))%")
                    .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                VerticalVolumeSlider(value: player.displayVolume, onValueChange: player.setVolume, onEditingBegan: {
                    player.beginVolumeEditing()
                    presentation.sendAttention(.interaction(.volume, true))
                }, onEditingEnded: finishVolumeEditing)
                    .frame(width: 24, height: 112)
                Button(action: player.toggleMute) {
                    Image(systemName: player.displayVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(player.displayVolume == 0 ? "transport.unmute" : "transport.mute"))
            }
            .padding(14)
            .onExitCommand { presentation.dismissPopover() }
            .onDisappear { finishVolumeEditing() }
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
    private func finishVolumeEditing() {
        if presentation.isVisible { player.endVolumeEditing() } else { player.cancelVolumeEditing() }
        presentation.sendAttention(.interaction(.volume, false))
    }
}

private struct VerticalVolumeSlider: NSViewRepresentable {
    let value: Double
    let onValueChange: (Double) -> Void
    let onEditingBegan: () -> Void
    let onEditingEnded: () -> Void
    func makeNSView(context: Context) -> TrackingSlider {
        let slider = TrackingSlider(frame: CGRect(x: 0, y: 0, width: 24, height: 112))
        slider.minValue = 0; slider.maxValue = 1
        slider.isContinuous = true
        slider.target = slider
        slider.action = #selector(TrackingSlider.valueChanged(_:))
        slider.setAccessibilityLabel(String(localized: "transport.volume"))
        return slider
    }
    func updateNSView(_ slider: TrackingSlider, context: Context) {
        slider.doubleValue = value
        slider.onValueChange = onValueChange; slider.onEditingBegan = onEditingBegan; slider.onEditingEnded = onEditingEnded
    }
    final class TrackingSlider: NSSlider {
        var onValueChange: ((Double) -> Void)?
        var onEditingBegan: (() -> Void)?
        var onEditingEnded: (() -> Void)?
        private var isTracking = false
        override func mouseDown(with event: NSEvent) {
            isTracking = true
            onEditingBegan?()
            defer { isTracking = false; onEditingEnded?() }
            super.mouseDown(with: event)
        }
        @objc func valueChanged(_ sender: Any?) {
            onValueChange?(doubleValue)
            if !isTracking { onEditingEnded?() }
        }
    }
}
