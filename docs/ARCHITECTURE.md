# Architecture

The short version: Wave creates a Core Audio **process tap** over an
application's processes, puts that tap and the user's chosen **output device**
into one private **aggregate device**, and runs a single **IO callback** on that
aggregate which reads the tapped audio, multiplies it by a smoothed gain, and
writes it to the device. Because the tap is created with
`muteBehavior = .mutedWhenTapped`, macOS stops sending that application to its
normal destination for as long as the tap exists.

That last property is the load-bearing one. It is what stops audio playing
twice, and it is what makes cleanup safe: destroy the tap and normal playback
resumes on its own, including after a crash.

---

## The audio path

```
   Spotify (+ its helper processes)
        │
        │  kAudioHardwarePropertyProcessObjectList
        │  → grouped into one AppGroupKey
        ▼
   CATapDescription(stereoMixdownOfProcesses: [ids…])
        muteBehavior = .mutedWhenTapped   ← original path is cut here
        isPrivate    = true
        │
        │  AudioHardwareCreateProcessTap
        ▼
   Private aggregate device
        subDeviceList = [ chosen output device ]   ← clock master
        tapList       = [ this tap ]
        │
        │  AudioDeviceCreateIOProcIDWithBlock
        ▼
   waveRender()                        ← the only real-time code
        read target gain (1 atomic load)
        per sample: ramp → multiply → clamp
        publish peaks + counters (a few atomic stores)
        │
        ▼
   Studio speakers
```

### Why one aggregate device per route

The alternative is one aggregate per *output device*, with every application
routed there sharing its tap list. That is fewer objects and one mixing point,
but adding or removing a single application means rebuilding the aggregate,
which glitches every other application using that device.

One aggregate per route trades object count for isolation: changing Spotify
cannot interrupt Zoom. It also means a route that fails to build fails alone.
The cost is N aggregate devices for N routed applications, which is the right
trade for the handful of applications a person actually routes.

### Why formats are read from the aggregate, not from the tap

`kAudioTapPropertyFormat` reports the tap's own format. The IO callback,
however, talks to the *aggregate*, whose input side is the tap after any
conversion the HAL performed to put it on the aggregate's clock. Reading both
formats from the aggregate — `kAudioStreamPropertyVirtualFormat` on the input
and output scopes — is what guarantees the two sides agree on sample rate,
which is what lets Wave avoid resampling entirely.

If they ever disagree, `RenderPlanBuilder` refuses the route with a specific
reason rather than resampling in the callback. A mismatch there means an
assumption has broken; papering over it would hide the break.

## The real-time contract

`waveRender()` in `Sources/WaveAudio/RealtimeRenderer.swift` is the only code
that runs on the audio thread. It must never allocate, lock, log, take an
Objective-C message send, touch a Swift class, or do UI work. Missing that by
even a little produces dropouts that are hard to attribute later.

Four things enforce it structurally rather than by discipline:

**1. The render context is plain old data.** `RenderContextStorage` holds raw
pointers and scalars only, allocated once at setup with
`UnsafeMutablePointer.allocate`. The IO block captures that one pointer and
nothing else, so invoking it involves no retain, release or exclusivity check.

**2. The channel map is precomputed.** Every decision about how tapped channels
line up with device channels — mono fan-out, stereo fold-down, pass-through,
which channels stay silent — is resolved by `RenderPlanBuilder` on the control
thread and baked into a fixed array of `ChannelTap` values. The callback reads
them; it never decides anything.

**3. The scratch tables are preallocated.** The per-channel base pointers and
strides change every callback (the HAL hands over different buffers), so they
are refilled each time — into buffers allocated at setup, never grown.

**4. Shared state is C11 atomics.** `WaveRTSupport` exposes an opaque
`WaveRTBlockRef` with wait-free accessors. The fader writes one float; the
callback loads it **once per buffer**, not per sample. Peaks go the other way
through a raise-if-greater compare-exchange, and the UI drains them with an
atomic exchange-to-zero so a transient is never lost between frames. It is C
because Swift's `Synchronization.Atomic` is macOS 15+ and Wave targets 14.2, and
because a C struct with `_Atomic` members cannot be imported into Swift — which
is convenient, since keeping it opaque also keeps the discipline honest.

### Gain, clicks and clipping

A fader change applied directly to the multiplier is a step discontinuity in the
waveform, which is a click. `GainSmoother` walks the applied gain towards the
target with a one-pole filter over roughly 15 ms, stepped once per frame. Mute
is folded into the same value rather than branched around it, so muting and
unmuting ramp exactly like a fader move and cannot click either.

`VolumeCurve` maps the 0–1 slider onto amplitude with a square law, and pins two
values exactly: `gain(1) == 1` and `gain(0) == 0`. Unity at the top means **Wave
can only ever attenuate**, which is what makes it impossible for the mixer
itself to introduce clipping. `waveClampSample` is still applied as a safety
net, for sources that are already hot, and counts what it catches.

### Frame counts

The callback never trusts the output frame count when reading the input. Inside
one aggregate the two sides run on the same clock and agree, but treating that
as a guarantee would turn any disagreement into a read past the end of the tap
buffer on the audio thread. It renders `min(inputFrames, outputFrames)`,
silences any remainder, and counts the mismatch.

## Detecting a silent permission denial

This is the single most important correctness property in the app, so it gets
its own section.

macOS enforces System Audio Recording **silently**.
`AudioHardwareCreateProcessTap`, `AudioHardwareCreateAggregateDevice` and
`AudioDeviceStart` all return `noErr` when it is denied. The IO callback fires
on schedule. Every tapped sample is zero, forever. There is no error anywhere.

A mixer built against the return codes alone would look completely healthy while
doing nothing — precisely the "functioning-looking mixer" this app must not
present. Wave uses two independent signals:

1. **TCC preflight** (`PermissionController`). `TCCAccessPreflight` and
   `TCCAccessRequest` are SPI, reached by `dlopen` so a future macOS that
   renames or removes them degrades rather than fails to launch. This is what
   lets Wave explain the situation *before* asking, and know the answer without
   starting audio.

2. **The silence watchdog** (`SilenceWatchdog`), which needs no SPI. If Core
   Audio reports an application as producing output
   (`kAudioProcessPropertyIsRunningOutput`) while its tap has delivered nothing
   but digital silence for several seconds, capture is being withheld. Once a
   tap has demonstrably carried audio, the watchdog stops suspecting permission
   — later silence is the application's own.

The watchdog deliberately observes the **pre-gain** peak. Metering the output
would make every muted application look like a permission failure.

Either signal is enough to put the app into its onboarding state; neither can be
overridden by the other's optimism.

## Components

| Component | Responsibility | Layer |
|---|---|---|
| `AudioProcessDiscovery` | Process objects → named, iconned applications | HAL |
| `ProcessGrouping` | Helper processes → their owning application | Core |
| `AudioDeviceRegistry` | Output devices, hot-plug, default-device changes | HAL |
| `DeviceFallbackPolicy` | Which device a rule plays through right now | Core |
| `ProcessTapController` | Tap + aggregate lifecycle | HAL |
| `RenderPlanBuilder` | Format acceptance and channel mapping | Core |
| `RealtimeRenderer` | The IO proc and the render callback | HAL |
| `GainSmoother` / `VolumeCurve` | Gain maths and click-free ramps | Core |
| `AudioRoutingEngine` | Orchestration, state machine, reconciliation | HAL |
| `RoutingRuleStore` | Persistence by bundle ID and device UID | Core |
| `PermissionController` | Preflight, request, and the honest failure mode | HAL |
| `SilenceWatchdog` | The backstop against a silent denial | Core |
| `MeterBallistics` | Attack, release, peak-hold — all UI-side | Core |
| `MixerViewModel` | The only place audio and SwiftUI meet | UI |
| `Diagnostics` | Local ring-buffer log. Never called from the audio thread. | Core |

`WaveCore` deliberately contains no Core Audio, AppKit or SwiftUI. That is not
tidiness for its own sake: it is what makes the interesting behaviour — what
happens when AirPods are yanked out mid-track, what a helper process should be
called, whether a format is safe to render — testable without a machine, a
device or a person listening.

## Threading

| Thread | What runs there |
|---|---|
| Audio (HAL) | `waveRender` only. Never blocks, allocates or logs. |
| `app.wave.routing-engine` | All route state and all Core Audio object lifecycle. One serial queue, so out-of-order notifications resolve by construction rather than by locking. |
| `app.wave.device-registry` | Device enumeration and its listeners |
| `app.wave.process-discovery` | Process enumeration and its listeners |
| Main | SwiftUI, `MixerViewModel`, meter ballistics |

The engine publishes plain values; `MixerViewModel` hops them to the main actor.
The engine has no idea SwiftUI exists, which is what stops a slow view update
from ever reaching audio.

## Teardown order

Getting this wrong is how you leave somebody's Spotify silent with no visible
cause, so it is written down and centralised in
`AudioRoutingEngine.teardownResources`:

1. Clear the active flag — the callback starts emitting silence.
2. `AudioDeviceStop`.
3. `AudioDeviceDestroyIOProcID` — after this the callback cannot run again.
4. Free the render context — only safe now.
5. `AudioHardwareDestroyAggregateDevice` — before the tap, or the aggregate is
   left pointing at nothing.
6. `AudioHardwareDestroyProcessTap` — **this is what unmutes the application.**
7. Dispose the control block.

Every step is idempotent, so an explicit stop followed by `deinit` is harmless.
`RouteLifecycle` enumerates the states that own resources, and a test sweeps
every state/event pair to confirm nothing can acquire resources without passing
through `preparing`.

The backstop: because the source mute is a property of the tap and not a
separate setting Wave has to remember to undo, a crash or a force quit restores
audio by itself when macOS reaps the process's taps. Explicit teardown is what
makes normal quitting deterministic, not what makes it recoverable.
