import SwiftUI
import AppKit
import WaveCore
import WaveAudio

/// One application's row.
///
/// Two lines, deliberately:
///
///     [icon] Name                              [stereo meter]
///            Output ▾   [mute]  [———fader———]         72%
///
/// The second line is indented to the name's leading edge so the pair reads as
/// one block, and the meter and the percentage share a trailing edge so the eye
/// can run down either column. Nothing is boxed; the row is separated from its
/// neighbours by space alone.
struct ChannelStripView: View {

    let channel: MixerChannel
    let devices: [OutputDeviceSnapshot]
    let icon: NSImage
    let destinationLabel: String

    let onVolume: (Float) -> Void
    let onToggleMute: () -> Void
    let onSelectDevice: (OutputDeviceSnapshot?) -> Void
    let onForget: () -> Void

    @State private var isHovering = false
    @Environment(\.colorSchemeContrast) private var contrast

    private var isRouting: Bool { channel.routeState.isLive }
    private var isDimmed: Bool { !channel.isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            topLine
            controlLine
            if let message = channel.statusMessage {
                statusLine(message)
            }
        }
        .padding(.horizontal, Wave.Metrics.horizontalPadding)
        .padding(.vertical, Wave.Metrics.rowVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: Wave.Metrics.rowCornerRadius, style: .continuous)
                .fill(isHovering ? Wave.rowHighlight : Color.clear)
                .padding(.horizontal, Wave.Metrics.horizontalPadding - 6)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .opacity(isDimmed ? 0.62 : 1)
        .contextMenu {
            Button("Reset to 100% on system output") {
                onSelectDevice(nil)
                onVolume(1)
            }
            Button("Forget \(channel.name)", role: .destructive, action: onForget)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(channel.name)
    }

    // MARK: - Line one: identity and level

    private var topLine: some View {
        HStack(spacing: Wave.Metrics.iconGap) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: Wave.Metrics.iconSize, height: Wave.Metrics.iconSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(channel.name)
                    .font(Wave.Type_.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                if !channel.isRunning {
                    Text("Not running")
                        .font(Wave.Type_.secondary)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            LevelMeterView(meter: channel.meter,
                           isEnabled: isRouting,
                           placeholder: !isRouting)
        }
    }

    // MARK: - Line two: output, mute, fader, readout

    private var controlLine: some View {
        HStack(spacing: 8) {
            outputPicker
            muteButton
            fader
            Text("\(VolumeCurve.percent(forPosition: channel.rule.volume))%")
                .font(Wave.Type_.readout)
                .foregroundStyle(channel.rule.isMuted ? AnyShapeStyle(Color.secondary.opacity(0.65)) : AnyShapeStyle(Color.secondary))
                .frame(width: Wave.Metrics.percentWidth, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .padding(.leading, Wave.Metrics.contentIndent)
    }

    private var outputPicker: some View {
        Menu {
            Button {
                onSelectDevice(nil)
            } label: {
                if channel.rule.outputDeviceUID == nil {
                    Label("System output", systemImage: "checkmark")
                } else {
                    Text("System output")
                }
            }
            Divider()
            ForEach(devices) { device in
                Button {
                    onSelectDevice(device)
                } label: {
                    if channel.rule.outputDeviceUID == device.uid {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
            if devices.isEmpty {
                Text("No output devices")
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: deviceSymbol)
                    .font(.system(size: 9))
                Text(destinationLabel)
                    .font(Wave.Type_.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(channel.isDegraded ? AnyShapeStyle(Wave.overload) : AnyShapeStyle(Color.secondary))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        // A fixed width rather than an intrinsic one: it is what keeps the
        // mute button, fader and percentage in a straight column down the
        // popover regardless of how long a device is called.
        .frame(width: 150, alignment: .leading)
        .help("Choose where \(channel.name) plays")
        .accessibilityLabel("Output device for \(channel.name)")
        .accessibilityValue(destinationLabel)
    }

    private var muteButton: some View {
        Button(action: onToggleMute) {
            Image(systemName: channel.rule.isMuted ? "speaker.slash.fill" : "speaker.wave.2")
                .font(.system(size: 11))
                .frame(width: 18, height: Wave.Metrics.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(channel.rule.isMuted ? AnyShapeStyle(Wave.signal) : AnyShapeStyle(Color.secondary))
        .help(channel.rule.isMuted ? "Unmute \(channel.name)" : "Mute \(channel.name)")
        .accessibilityLabel("Mute \(channel.name)")
        .accessibilityValue(channel.rule.isMuted ? "Muted" : "Not muted")
        .accessibilityAddTraits(channel.rule.isMuted ? [.isSelected] : [])
    }

    private var fader: some View {
        Slider(value: Binding(get: { Double(channel.rule.volume) },
                              set: { onVolume(Float($0)) }),
               in: 0...1)
            .controlSize(.small)
            .tint(channel.rule.isMuted ? Color.secondary : Wave.signal)
            .frame(minWidth: 60)
            .accessibilityLabel("Volume for \(channel.name)")
            .accessibilityValue("\(VolumeCurve.percent(forPosition: channel.rule.volume)) percent")
    }

    private func statusLine(_ message: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: statusSymbol)
                .font(.system(size: 9))
            Text(message)
                .font(Wave.Type_.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(channel.isDegraded ? AnyShapeStyle(Wave.overload) : AnyShapeStyle(Color.secondary))
        .padding(.leading, Wave.Metrics.contentIndent)
        .accessibilityLabel("Status: \(message)")
    }

    private var statusSymbol: String {
        if case .preparing = channel.routeState { return "clock" }
        return "exclamationmark.triangle"
    }

    private var deviceSymbol: String {
        guard let transport = channel.resolution?.device?.transport
                ?? devices.first(where: { $0.uid == channel.rule.outputDeviceUID })?.transport else {
            return "speaker.wave.2"
        }
        switch transport {
        case .bluetooth: return "wave.3.right"
        case .airPlay: return "airplayaudio"
        case .hdmi, .displayPort: return "display"
        case .usb, .thunderbolt: return "cable.connector"
        case .builtIn: return "laptopcomputer"
        default: return "speaker.wave.2"
        }
    }
}
