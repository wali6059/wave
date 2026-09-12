import SwiftUI
import AppKit
import WaveCore
import WaveAudio

/// The popover.
///
/// Structure, top to bottom: a compact header, the applications currently
/// making noise, then anything saved or idle, then the master strip. Hierarchy
/// comes from that order and from which rows have live meters — not from
/// headings, cards or rules.
struct MenuBarMixerView: View {

    @ObservedObject var model: MixerViewModel
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Group {
            if model.isShowingDiagnostics {
                DiagnosticsView(model: model)
            } else if !model.canShowMixer {
                OnboardingView(status: model.permissionStatus,
                               onRequest: model.requestPermission,
                               onOpenSettings: model.openPermissionSettings,
                               onRecheck: model.recheckPermission)
            } else {
                mixer
            }
        }
        .background(Wave.surface)
    }

    // MARK: - Mixer

    private var mixer: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HairlineDivider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.activeChannels.isEmpty && model.savedChannels.isEmpty {
                        emptyState
                    } else {
                        activeSection
                        savedSection
                    }
                }
                .padding(.bottom, 6)
            }
            .frame(maxHeight: Wave.Metrics.maxPopoverHeight)

            HairlineDivider()
            masterStrip
        }
        .frame(width: Wave.Metrics.popoverWidth)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Wave.signal)
                .accessibilityHidden(true)
            Text("Wave")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            Menu {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { launchAtLogin = LaunchAtLogin.set($0) }
                ))
                .disabled(!LaunchAtLogin.isAvailable)

                if LaunchAtLogin.requiresApproval {
                    Text("Approve Wave in System Settings ▸ General ▸ Login Items")
                }

                Divider()
                Button("Diagnostics…") { model.isShowingDiagnostics = true }
                Button("Recheck permission", action: model.recheckPermission)
                Divider()
                Button("Quit Wave") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Wave settings")
        }
        .padding(.horizontal, Wave.Metrics.horizontalPadding)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var activeSection: some View {
        if !model.activeChannels.isEmpty {
            SectionHeader(title: "Playing now",
                          trailing: model.activeChannels.count > 1 ? "\(model.activeChannels.count) apps" : nil)
            ForEach(model.activeChannels) { channel in
                strip(for: channel)
            }
        }
    }

    @ViewBuilder
    private var savedSection: some View {
        if !model.savedChannels.isEmpty {
            SectionHeader(title: model.activeChannels.isEmpty ? "Saved and recent" : "Recent and saved")
            ForEach(model.savedChannels) { channel in
                strip(for: channel)
            }
        }
    }

    private func strip(for channel: MixerChannel) -> some View {
        ChannelStripView(channel: channel,
                         devices: model.outputDevices,
                         icon: model.icon(for: channel),
                         destinationLabel: model.destinationLabel(for: channel),
                         onVolume: { model.setVolume($0, for: channel.key) },
                         onToggleMute: { model.toggleMute(for: channel.key) },
                         onSelectDevice: { model.setOutput($0, for: channel.key) },
                         onForget: { model.forget(channel.key) })
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing is playing")
                .font(Wave.Type_.name)
            Text("Start audio in an app and it will appear here. Anything you adjust is remembered and reapplied the next time that app plays.")
                .font(Wave.Type_.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Wave.Metrics.horizontalPadding)
        .padding(.vertical, 22)
    }

    // MARK: - Master

    private var masterStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.3")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: Wave.Metrics.iconSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Master output")
                    .font(Wave.Type_.secondary)
                    .foregroundStyle(.secondary)
                Text(model.masterDeviceName ?? "No output device")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(width: 120, alignment: .leading)

            Button {
                model.toggleMasterMute()
            } label: {
                Image(systemName: model.masterMuted ? "speaker.slash.fill" : "speaker.wave.2")
                    .font(.system(size: 11))
                    .frame(width: 18, height: Wave.Metrics.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.masterMuted ? AnyShapeStyle(Wave.signal) : AnyShapeStyle(Color.secondary))
            .disabled(!model.masterAvailable)
            .accessibilityLabel("Mute master output")

            Slider(value: Binding(get: { Double(model.masterVolume) },
                                  set: { model.setMasterVolume(Float($0)) }),
                   in: 0...1)
                .controlSize(.small)
                .tint(Wave.signal)
                .disabled(!model.masterAvailable)
                .accessibilityLabel("Master output volume")

            Text("\(Int((model.masterVolume * 100).rounded()))%")
                .font(Wave.Type_.readout)
                .foregroundStyle(.secondary)
                .frame(width: Wave.Metrics.percentWidth, alignment: .trailing)
        }
        .padding(.horizontal, Wave.Metrics.horizontalPadding)
        .padding(.vertical, 9)
        .opacity(model.masterAvailable ? 1 : 0.55)
        .help(model.masterAvailable
              ? "Hardware volume of the current system output device"
              : "This output device has no software volume control")
    }
}
