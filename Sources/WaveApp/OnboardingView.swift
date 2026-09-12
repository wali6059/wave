import SwiftUI
import WaveAudio

/// First run, and every run where macOS is withholding audio capture.
///
/// This screen replaces the mixer entirely rather than sitting above it. That
/// is the point: a fader that cannot do anything is worse than no fader, and a
/// person who has just denied the prompt should not be looking at a control
/// surface that appears to work.
struct OnboardingView: View {

    let status: PermissionController.Status
    let onRequest: () -> Void
    let onOpenSettings: () -> Void
    let onRecheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Text(PermissionController.rationale)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if status == .denied {
                deniedGuidance
            }

            HairlineDivider()

            HStack(spacing: 8) {
                if status == .denied {
                    Button("Open System Settings", action: onOpenSettings)
                        .keyboardShortcut(.defaultAction)
                    Button("Check again", action: onRecheck)
                } else {
                    Button("Allow system audio recording…", action: onRequest)
                        .keyboardShortcut(.defaultAction)
                    Button("Check again", action: onRecheck)
                }
                Spacer()
            }
        }
        .padding(Wave.Metrics.horizontalPadding)
        .frame(width: Wave.Metrics.popoverWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: status == .denied ? "exclamationmark.triangle" : "waveform")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(status == .denied ? AnyShapeStyle(Wave.overload) : AnyShapeStyle(Wave.signal))
                .accessibilityHidden(true)
            Text(status == .denied
                 ? "Wave cannot capture audio yet"
                 : "Wave needs one permission to work")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .accessibilityAddTraits(.isHeader)
    }

    private var deniedGuidance: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How to enable it")
                .font(Wave.Type_.sectionHeader)
                .foregroundStyle(.secondary)
            Text(PermissionController.manualInstructions)
                .font(Wave.Type_.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("macOS only shows the prompt once. After that the switch in System Settings is the only way to change it.")
                .font(Wave.Type_.secondary)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}
