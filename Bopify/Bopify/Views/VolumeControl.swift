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
        .buttonStyle(.playerToggle(isOn: presentation.activePopover == .volume))
        .accessibilityLabel(Text("transport.volume"))
        .accessibilityValue(Text("\(Int((player.displayVolume * 100).rounded()))%"))
        .disabled(!player.isEngineReady || !player.state.isActiveDevice)
        .popover(isPresented: isPopoverPresented, arrowEdge: .bottom) {
            VolumePopoverContent(player: player, onEditingBegan: {
                player.beginVolumeEditing()
                presentation.sendAttention(.interaction(.volume, true))
            }, onEditingEnded: finishVolumeEditing)
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

struct VolumePopoverContent: View {
    let player: PlayerModel
    let onEditingBegan: () -> Void
    let onEditingEnded: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: player.toggleMute) {
                Image(systemName: player.displayVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(player.displayVolume == 0 ? "transport.unmute" : "transport.mute"))
            HorizontalVolumeSlider(value: player.displayVolume, onValueChange: player.setVolume,
                onEditingBegan: onEditingBegan, onEditingEnded: onEditingEnded)
                .frame(width: 112, height: 24)
        }
        .padding(8)
    }
}

private struct HorizontalVolumeSlider: NSViewRepresentable {
    let value: Double
    let onValueChange: (Double) -> Void
    let onEditingBegan: () -> Void
    let onEditingEnded: () -> Void
    func makeNSView(context: Context) -> TrackingSlider {
        let slider = TrackingSlider(frame: CGRect(x: 0, y: 0, width: 112, height: 24))
        slider.cell = SlimVolumeSliderCell()
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

private final class SlimVolumeSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let bar = NSRect(x: rect.minX, y: rect.midY - 1.5, width: rect.width, height: 3)
        NSColor.labelColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        guard doubleValue > minValue else { return }
        var filled = bar
        filled.size.width = min(bar.width, max(0, knobRect(flipped: flipped).midX - bar.minX))
        NSColor.labelColor.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: filled, xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        // Keep the native knob's larger tracking geometry while drawing a smaller thumb.
        let thumb = NSRect(x: knobRect.midX - 4, y: knobRect.midY - 4, width: 8, height: 8)
        NSColor.labelColor.setFill()
        NSBezierPath(ovalIn: thumb).fill()
    }
}
