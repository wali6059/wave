# Verification status

What has actually been proven, what has not, and by whom. Read this before
trusting any claim elsewhere in the repository.

## Summary

| | |
|---|---|
| Compiles against the macOS SDK | **Yes** — macOS 15.5 SDK, Swift 6.1.2, Xcode 16.4, clean under `-warnings-as-errors -Werror` |
| Unit tests | **Yes** — 130 tests, 0 failures |
| App bundle assembles and signs | **Yes** — passes `codesign --verify --deep --strict` |
| Device and process discovery against the real HAL | **Yes** — see below |
| Process tap + private aggregate device created, format negotiated, torn down | **Yes** — on every push |
| **Audio captured, attenuated and rerouted** | **No. Unverified.** Needs a human at a Mac. |
| Interface rendered | **No.** Never displayed on a screen. |

The headline claim of this app — that it intercepts an application's audio,
applies gain, and plays it out of a device you chose — **has not been
demonstrated**. Everything underneath it has.

## How this was built

The code was written in a Linux container with no macOS, no macOS SDK and no
Swift toolchain (`download.swift.org` is blocked by the session's egress
policy), so nothing could be compiled while it was being written. Every Core
Audio symbol was instead checked against Apple's documentation API and against
Apple engineer Guilherme Rambo's `AudioCap` sample before use.

Compilation and testing are now done by a macOS runner on GitHub Actions
(`.github/workflows/build.yml`), which is what closed most of the gap.

## What CI proves

Every push runs, on `macos-15`:

1. `swift build`
2. `swift test` — **130 tests, 0 failures**
3. `swift build -Xswiftc -warnings-as-errors -Xcc -Werror` — clean
4. `Scripts/build-app.sh` — assembles `Wave.app`, signs it, and
   `codesign --verify --deep --strict` reports *valid on disk* and *satisfies
   its Designated Requirement*
5. `PlistBuddy` confirms `NSAudioCaptureUsageDescription` survived into the
   compiled `Info.plist` (a silent omission here is the single most common way
   to get a silent permission denial)
6. A smoke test that runs the spike's read-only commands
7. `wave-spike selftest --graph-only`, which builds the real Core Audio object
   graph and releases it

Step 6 is more informative than a smoke test usually is. On the runner,
`wave-spike list` produced:

```
Output devices
--------------
  Apple Virtual Sound Device *default*
      uid=AVIODevice  channels=2  transport=builtIn
  Null Audio Device
      uid=NullAudioDevice_UID  channels=2  transport=virtual

Audio processes (grouped by application)
----------------------------------------
  [idle   ] Control Center
      key=com.apple.controlcenter  pids=313
  [idle   ] corespeechd
      key=com.apple.CoreSpeech  pids=368
  [idle   ] systemstats
      key=exec:/usr/sbin/systemstats  pids=741
  … 9 applications in total
```

That output exercises, against the real Core Audio HAL rather than a mock:

- `kAudioHardwarePropertyDevices`, device UID reading, output channel counting
  via `kAudioDevicePropertyStreamConfiguration`, transport-type mapping, and
  default-device detection.
- `kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyPID`,
  `kAudioProcessPropertyBundleID` and `kAudioProcessPropertyIsRunningOutput`.
- PID to friendly-name resolution (`Control Center`, not `controlcenter`).
- The `exec:` fallback identity for a process with no bundle (`systemstats`).
- Grouping producing one row per application.

`wave-spike permission` reports `undetermined` and exits cleanly, so the TCC
`dlopen`/`dlsym` path runs without crashing on a machine that has never been
asked.

Step 7 is the one that matters most, because it exercises the calls the whole
design rests on:

```
-> AudioHardwareCreateProcessTap + AudioHardwareCreateAggregateDevice
tap        : #107  uuid=F418A125-1C00-494B-B01F-710102052E89
aggregate  : #108  buffer=512 frames
format     : 2ch in -> 2ch out @ 48000 Hz

Results (graph only)
  tap created            : yes  (#107)
  aggregate created      : yes  (#108)
  render plan resolved   : yes  (2ch -> 2ch @ 48000 Hz)
  teardown completed     : yes
```

So, verified on real macOS rather than argued from documentation:

- `AudioHardwareCreateProcessTap` accepts a `CATapDescription` built with
  `stereoMixdownOfProcesses:` over a real process group and returns a tap.
- A **private aggregate device accepts that tap in its tap list** alongside an
  output sub-device. This is the arrangement the entire routing design depends
  on and the part with the least public documentation.
- Reading the formats **from the aggregate** rather than from the tap and the
  device separately works, and the two sides agree on sample rate — which is
  the reasoning that lets Wave avoid resampling altogether.
- `AudioHardwareDestroyAggregateDevice` and `AudioHardwareDestroyProcessTap`
  release cleanly in that order.

### A finding worth knowing

The first version of this self-test also tried to start IO. On the runner it
blocked in `AudioDeviceCreateIOProcIDWithBlock` and had to be killed — that
being the first call which would make tapped audio actually flow, and a
runner having no logged-in session in which to answer a permission prompt.

The consequence on a real Mac: **the first route may block until the prompt is
answered.** Wave makes that call on its routing queue, never the main thread,
so the interface stays responsive — but it is worth expecting rather than
mistaking for a hang.

## What CI cannot prove

A GitHub runner has no real audio hardware, no TCC grant, no logged-in window
server and nobody listening. So none of the following has been exercised, by
anyone, ever:

- `muteBehavior = .mutedWhenTapped` actually silencing the source — the
  mechanism the whole "no double audio" guarantee rests on.
- The IO callback firing, and `waveRender` producing correct samples.
- Gain being audible, ramps being click-free.
- Audio arriving at a chosen device and only that device.
- Teardown restoring normal playback.
- Hot-plug recovery.
- A single pixel of the SwiftUI interface.

`docs/ACCEPTANCE.md` is the checklist for all of it.

## Bugs found, and by what

**Found by static review, before any compiler ran:**

- Render callback derived its frame count from the output buffer and used it to
  index the input buffer — a read past the end of the tap buffer on the audio
  thread whenever the two disagreed.
- Restarting a suspended route left it stuck: `.startRequested` is only legal
  from `.idle`/`.failed`, so a route resuming after its device returned built
  its tap and never reached `.running`.
- Four components exposed a single assignable `onChange`, and both the routing
  engine and the view model subscribe. The engine's `start()` ran last and
  silently disconnected the UI from every hot-plug event.
- Metering shared a channel with structural status, rebuilding every row's
  model 30 times a second.

**Found by the compiler:**

- `FormatIncompatibility` used as a `Result` failure type without conforming to
  `Error`.
- `withUnsafeMutableBytes` yields an optional `baseAddress`.
- `kAudioObjectPropertyStreams` does not exist; it is
  `kAudioDevicePropertyStreams`.
- `error as? CustomStringConvertible` always succeeds on an existential
  `Error`.
- Forming an `UnsafeRawPointer` from an inout generic in the property writer.

**Found by running the tests — the one static review could never have caught:**

The gain ramp never reached its target. A one-pole step is
`delta * coefficient`; both shrink as the ramp converges, and once their
product falls below half a ULP the addition rounds to no change. At 48 kHz with
a 15 ms time constant the step went under half a ULP of 1.0 while `delta` was
still ~2.1e-5 — above the 1e-5 snap threshold, so the snap never fired. The
gain sat 2.1e-5 below unity forever, the smoother never reported settled, and
the render loop ran ramp arithmetic on every buffer for the life of a route.
`advance()` now detects a step that made no progress and finishes the ramp.

**Found by reading CI output instead of trusting its exit code:**

The spike smoke test originally invoked `/usr/bin/timeout`, which does not
exist on macOS. Both commands failed instantly, `|| true` swallowed it, and the
step reported success having executed nothing.

## Screenshots

`screenshots/` is empty. The interface has never been rendered, and drawing
mockups to fill the directory would misrepresent the state of the work.
`Scripts/capture-screenshots.sh` captures the required states once Wave is
running on a Mac.

## Honest confidence

| Area | Confidence | Basis |
|---|---|---|
| Core Audio API usage | High | Signatures verified against Apple docs; discovery demonstrably works against the real HAL |
| `WaveCore` logic | High | 130 tests passing |
| Compiles and links | Certain | CI, every push |
| Tap and aggregate creation succeed | **Verified** | Executed on macOS 15.5 on every push; tap, private aggregate and format negotiation all succeed and release cleanly |
| Render callback produces correct audio | Medium | Carefully reviewed, unit-testable parts tested, never run |
| Interface looks right | Low | Never rendered; the column budget is arithmetic, not observation |
| **End-to-end audio routing** | **Unverified** | This is the claim that needs your Mac |
