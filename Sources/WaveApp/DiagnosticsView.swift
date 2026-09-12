import SwiftUI
import AppKit
import WaveCore

/// The log, for when something is not behaving and a person needs to see why.
///
/// Entirely local: this is a window onto the in-memory ring buffer, with a copy
/// button. Nothing is uploaded, and there is nowhere for it to go.
struct DiagnosticsView: View {

    @ObservedObject var model: MixerViewModel
    @State private var entries: [Diagnostics.Entry] = []
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Diagnostics")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.diagnostics.exportText(), forType: .string)
                }
                Button("Clear") {
                    model.diagnostics.clear()
                    entries = []
                }
                Button("Done") { model.isShowingDiagnostics = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Wave.Metrics.horizontalPadding)

            HairlineDivider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(entries.reversed()) { entry in
                        HStack(alignment: .top, spacing: 6) {
                            Text(entry.category)
                                .font(.system(size: 10, weight: .medium).monospaced())
                                .foregroundStyle(color(for: entry.level))
                                .frame(width: 74, alignment: .leading)
                            Text(entry.message)
                                .font(.system(size: 10).monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                    if entries.isEmpty {
                        Text("Nothing logged yet.")
                            .font(Wave.Type_.secondary)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(Wave.Metrics.horizontalPadding)
            }
            .frame(height: 280)
        }
        .frame(width: Wave.Metrics.popoverWidth)
        .onAppear {
            entries = model.diagnostics.recent
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task { @MainActor in entries = model.diagnostics.recent }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private func color(for level: Diagnostics.Level) -> Color {
        switch level {
        case .error: return Wave.overload
        case .warning: return Wave.overload.opacity(0.8)
        default: return .secondary
        }
    }
}
