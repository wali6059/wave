# Wave

Per-app volume and output routing for macOS, as a menu-bar utility.

Set Spotify to 65% on your studio speakers, Chrome to 30% on the MacBook
speakers, Zoom to 100% on your AirPods, and system sounds to 40% on the
display — all at the same time, all remembered.

Wave does this by actually intercepting each application's audio with Core
Audio process taps, applying gain to the samples, and rendering the result to
the device you chose. It does **not** change your Mac's global output device or
global volume and call that per-app control.

Everything runs locally. No accounts, no analytics, no network access.

---

## Requirements

| | |
|---|---|
| macOS | 14.2 or newer (`CATapDescription` and `AudioHardwareCreateProcessTap` are 14.2+) |
| Xcode / toolchain | Xcode 15.3+ or a Swift 5.9+ toolchain with the macOS 14.2 SDK |
| Signing | A stable code-signing identity. See [Why signing matters](#why-signing-matters). |
| Permission | System Audio Recording |

## Build

```sh
make app          # build and sign build/Wave.app
make run          # build, sign and launch
make test         # unit tests
make verify       # strict build + tests + bundle + permission report
```

`make verify` is the one to run first. It builds with warnings escalated to
errors, runs the test suite, assembles the bundle, checks that the audio-capture
usage description actually made it into the compiled `Info.plist`, and then
tells you the manual steps that a machine cannot do for you.

Wave is a Swift Package rather than an Xcode project, so there is no generated
project file to drift out of sync. `Scripts/build-app.sh` does the small amount
of bundling a menu-bar app needs on top of `swift build`.

To work on it in Xcode, open `Package.swift` directly (`xed .`). Build the
`wave` product there for editing and debugging, but use `make app` for anything
that needs the real bundle identity — which is anything touching audio capture.

### Why signing matters

macOS keys the System Audio Recording privilege to your app's **code-signing
identity**. This has three practical consequences:

1. **An unsigned build cannot hold the permission.** The prompt will not
   appear, and every Core Audio call will return success while delivering
   silence.
2. **An ad-hoc signature (`-`) is not stable across rebuilds.** macOS may
   forget the grant every time you rebuild. `build-app.sh` warns when it falls
   back to ad-hoc.
3. **Set a real identity to avoid the churn:**

   ```sh
   CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" make app
   ```

   Any Apple Development or Developer ID Application certificate works; a free
   Apple ID gives you one. The script picks one up automatically if it finds it
   in your keychain.

## Permission

On first launch Wave shows what it needs and why, and asks for nothing until
you press the button. There is no mixer behind that screen — a fader that
cannot do anything is worse than no fader.

If you deny it, macOS will not ask again. Wave then shows you the exact path:

> System Settings ▸ Privacy & Security ▸ System Audio Recording, then switch
> Wave on.

**Important:** this privilege is enforced *silently*. With it denied, every Core
Audio API returns `noErr`, the audio callback fires on schedule, and the tapped
buffers contain nothing but zeros. Wave detects this two ways — a TCC preflight,
and a watchdog that notices when an application macOS reports as playing yields
only silence — and refuses to show a working-looking mixer either way. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#detecting-a-silent-permission-denial).

## Using it

- **Playing now** lists applications currently producing audio. Everything you
  adjust is saved.
- **Recent and saved** holds applications with saved settings that are not
  playing right now, so you can set Zoom up before your call starts.
- Each row has an output picker, a mute button, a fader and a percentage.
- **100% is unity** — the application's own level, untouched. Wave only ever
  attenuates, which is why it cannot itself introduce clipping.
- Right-click a row to reset it, or to forget it entirely and give the
  application its normal, uninterrupted audio path back.
- Rules are keyed on bundle identifier and device UID, never on PID, so they
  survive quitting, relaunching, rebooting and re-plugging.
- If a saved device is unplugged, Wave falls back to your current default
  output, says so on the row, and **leaves the rule alone** so your real choice
  comes back the moment the device does.

Settings live in `~/Library/Application Support/Wave/rules.json`.

## Verifying it actually works

Compiling proves nothing about audio. The spike does:

```sh
# What can Wave see?
make list

# Prove the whole chain on one app.
make spike APP_NAME="Music"

# Route it somewhere specific.
make spike APP_NAME="Music" DEVICE="AirPods" SECONDS=45
```

`wave-spike` uses the exact production components — same tap controller, same
renderer, same C control block — so a green spike is evidence about the shipping
code, not about a parallel toy. It sweeps the fader 100% → 25% → 100% so the
gain change is *audible*, prints pre-gain and post-gain meters side by side, and
finishes with a verdict.

The full checklist is in [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md).

## Troubleshooting

**The mixer says permission is missing, but System Settings shows Wave enabled.**
The grant is tied to a signing identity. If you rebuilt with an ad-hoc
signature, the new binary is a different principal. Toggle Wave off and on in
System Settings, or rebuild with a stable `CODESIGN_IDENTITY`.

**An app appears but its meter never moves.**
Run `make spike APP_NAME="<app>"`. If the pre-gain meter is flat while the app
is playing, capture is being withheld — that is the silent denial described
above. If the pre-gain meter moves but the post-gain one does not, check the
fader and mute.

**An app is silent and Wave is not running.**
This should be impossible: the source mute is a property of the tap, so it is
released when the tap is destroyed, including if Wave crashes or is force
quit. If it ever happens, quit Wave, then run:

```sh
sudo killall coreaudiod   # restarts the audio daemon; all taps are dropped
```

**Chrome or Slack shows up as several rows, or under a helper's name.**
Report it — the grouping rules are in
`Sources/WaveCore/ProcessGrouping.swift` and are unit-tested, so a
misgrouped app is a one-line fix plus a test.

**Nothing appears in the list at all.**
Wave only lists processes Core Audio knows about. Start playback first;
`make list` shows the raw view.

## Known limitations

These are real, and stated plainly rather than buried.

- **Safari attribution is a best guess.** Safari plays through
  `com.apple.WebKit.GPU`, which also serves `WKWebView`s hosted by *other*
  applications. Wave attributes it to Safari, which is right most of the time
  and wrong when another app embeds a web view that plays audio.
- **Permission preflight uses private API.** `TCCAccessPreflight` /
  `TCCAccessRequest` are SPI, reached by `dlopen` so a future macOS that
  removes them degrades instead of crashing. Build with
  `-D WAVE_DISABLE_TCC_SPI` to drop them and rely on the silence watchdog
  alone. This is fine for a local tool and would not pass App Store review.
- **One aggregate device per route.** Adding or removing one application does
  not disturb the others, but N routed applications means N aggregate devices.
  Fine for the handful of apps a person actually routes; not a design for
  dozens.
- **Changing an app's output device restarts its route,** which produces a
  short gap in that app's audio. Volume and mute changes do not — those are a
  single atomic store.
- **Master output is genuinely global.** It is the hardware volume of your
  current default device, labelled as such. Devices without a software volume
  control (most HDMI, many aggregates) show it disabled rather than pretending.
- **System sounds grouping is best-effort.** Core Audio attributes UI sounds to
  `coreaudiod`; Wave surfaces that as "System sounds". Some system audio may not
  be attributable at all.
- **Sample-rate conversion is the HAL's job, not Wave's.** Both sides of the
  render pass come from one aggregate device, so they share a clock by
  construction. If they ever disagree, Wave refuses the route and says why
  rather than resampling in the callback.
- **No sandbox.** Reading the process list, resolving executable paths and
  reading other apps' bundles for names and icons are all blocked by the App
  Sandbox. See `Resources/Wave.entitlements`.

## Deliberately out of scope for v1

EQ, recording, microphone and input routing, per-browser-tab mixing, audio
effects, remote control, and synchronised multi-output groups. The component
boundaries leave room for them (`GainProcessor` is the obvious place for an
effect chain; `AudioRoutingEngine` already models one route per app, which a
multi-output group would generalise) but none of it is here.

## Layout

```
Sources/
  WaveRTSupport/   C11 lock-free cells shared with the audio thread
  WaveCore/        Domain logic. No Core Audio, no AppKit, no SwiftUI.
  WaveAudio/       Core Audio HAL: discovery, taps, aggregates, render loop
  WaveApp/         SwiftUI menu-bar front end
  WaveSpike/       Headless CLI that proves the audio chain
Tests/WaveCoreTests/
docs/
  ARCHITECTURE.md  The real-time audio path
  ACCEPTANCE.md    Manual acceptance checklist
  VERIFICATION.md  What has and has not been verified, and by whom
```
