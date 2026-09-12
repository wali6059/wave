import SwiftUI
import AppKit
import WaveCore
import WaveAudio

/// Wave: per-app volume and output routing for macOS.
///
/// A menu-bar-only app (`LSUIElement`), so there is no Dock icon and no main
/// window. Everything lives in the popover.
@main
struct WaveApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = MixerViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarMixerView(model: model)
                .onAppear {
                    model.start()
                    delegate.model = model
                }
        } label: {
            // A waveform glyph rather than a level readout: a menu-bar item
            // that animates constantly is a distraction, and the meters are one
            // click away.
            Image(systemName: "waveform")
                .accessibilityLabel("Wave audio mixer")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the one thing SwiftUI's lifecycle does not give us: a guaranteed
/// teardown before the process exits.
///
/// Releasing taps matters more here than in most apps. A tap created with
/// `mutedWhenTapped` keeps its target application muted for as long as it
/// exists, so leaving one behind would leave somebody's Spotify silent with no
/// visible cause. macOS does clean up a dead process's taps, and that is the
/// backstop that makes even a crash recoverable — but doing it explicitly on
/// the way out is what makes normal quitting deterministic.
final class AppDelegate: NSObject, NSApplicationDelegate {

    weak var model: MixerViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only. Also set in Info.plist via LSUIElement; doing both
        // means an unbundled debug run behaves the same way.
        NSApp.setActivationPolicy(.accessory)
        Diagnostics.shared.info("App", "Wave launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            model?.shutdown()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
