# Verification status

Read this before trusting anything else in the repository.

## The short version

**The audio chain has not been run.** This code was written in a Linux
container with no macOS, no macOS SDK, no Swift toolchain and no audio
hardware. Nothing here has been compiled, no test has been executed, and no
sample has passed through the render callback.

The brief asked for a working application and said explicitly not to claim
completion on compilation or mocked UI alone. So: this is not complete. It is a
full implementation against verified API contracts, and it needs one build and
one listening session on a Mac before anyone should believe it.

## What the environment actually was

```
$ uname -a
Linux vm 6.18.44-fc-v24 ... x86_64 GNU/Linux
$ swift --version
no swift toolchain
```

Installing one was not possible either — `download.swift.org` is blocked by
this session's egress policy:

```
"detail": "gateway answered 403 to CONNECT (policy denial or upstream failure)",
"host": "download.swift.org:443"
```

So not even the platform-independent `WaveCore` tests could be run, which is
the part that would otherwise have executed anywhere.

## What *was* verified

Every Core Audio symbol used here was checked against Apple's live
documentation rather than written from memory. The exact declarations were
pulled from `developer.apple.com`'s documentation API and matched against the
code:

| Symbol | Verified declaration | Availability |
|---|---|---|
| `AudioHardwareCreateProcessTap` | `(_ inDescription: CATapDescription!, _ outTapID: UnsafeMutablePointer<AudioObjectID>!) -> OSStatus` | macOS 14.2 |
| `AudioHardwareDestroyProcessTap` | `(_ inTapID: AudioObjectID) -> OSStatus` | macOS 14.2 |
| `AudioHardwareCreateAggregateDevice` | `(_ inDescription: CFDictionary, _ outDeviceID: UnsafeMutablePointer<AudioObjectID>) -> OSStatus` | macOS 10.9 |
| `AudioDeviceIOBlock` | `(UnsafePointer<AudioTimeStamp>, UnsafePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>, UnsafeMutablePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>) -> Void` | — |
| `AudioDeviceCreateIOProcIDWithBlock` | `(UnsafeMutablePointer<AudioDeviceIOProcID?>, AudioObjectID, dispatch_queue_t?, @escaping AudioDeviceIOBlock) -> OSStatus` | macOS 10.7 |
| `AudioObjectPropertyListenerBlock` | `(UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void` | — |
| `CATapDescription.init(stereoMixdownOfProcesses:)` | `[AudioObjectID]` — **not** `[NSNumber]` | class is 14.2 |
| `CATapDescription` properties | `muteBehavior`, `isPrivate`, `isExclusive`, `isMixdown`, `isMono`, `name`, `uuid`, `processes`, `bundleIDs`, `deviceUID`, `stream` | |
| `CATapMuteBehavior` | `.muted`, `.mutedWhenTapped`, `.unmuted` | macOS 13.0 |
| `NSAudioCaptureUsageDescription` | Info.plist key | macOS 14.2 |

Confirmed present as documented: `kAudioAggregateDeviceTapListKey`,
`kAudioAggregateDeviceTapAutoStartKey`, `kAudioAggregateDeviceIsPrivateKey`,
`kAudioSubTapUIDKey`, `kAudioTapPropertyFormat`, `kAudioTapPropertyUID`,
`kAudioHardwarePropertyProcessObjectList`,
`kAudioHardwarePropertyTranslatePIDToProcessObject`,
`kAudioProcessPropertyPID`, `kAudioProcessPropertyBundleID`,
`kAudioProcessPropertyIsRunningOutput`.

The aggregate-device dictionary shape and the tap/aggregate creation order were
cross-checked against Apple engineer Guilherme Rambo's `AudioCap` sample
(`github.com/insidegui/AudioCap`), which is the reference implementation for
process taps on macOS 14.4+, and the TCC preflight approach in
`PermissionController` follows the same SPI it uses.

The single most consequential thing that research turned up is documented in
`ARCHITECTURE.md` and handled in the code: **the System Audio Recording
privilege is enforced silently.** Denied, every Core Audio call still returns
`noErr` and the buffers are simply zeros. That is why `SilenceWatchdog` exists.

## What was reviewed by hand instead of compiled

Since no compiler was available, the code was reviewed statically for the
mistakes a compiler would have caught. Issues found and fixed this way:

- `AudioStreamID` and `AudioObjectID` are both `UInt32`, so a second
  `static let unknown` on the former was a redeclaration.
- Swift's C importer maps a forward-declared struct unpredictably; the control
  block was reshaped into the `sqlite3 *`-style `typedef struct … *Ref` that
  maps reliably to `OpaquePointer`.
- `for (key, var channel) in dictionary` is not valid Swift, and the loop it
  appeared in also mutated the dictionary it was iterating.
- `AnyShapeStyle(.secondary)` is ambiguous between `Color` and
  `HierarchicalShapeStyle`.
- A `@available(macOS 14.2)` API cannot be used with a 14.0 deployment target,
  so `Package.swift` pins `.macOS("14.2")`.
- `String(format: "%d", someInt)` passes 64 bits to a 32-bit conversion.
- Registering a Core Audio listener touched `self` before initialisation
  completed.
- Tautological `enum < 0` comparisons in C that `-Werror` would reject.

And one genuine logic bug that a compiler would *not* have caught: the render
callback derived its frame count from the output buffer and used it to index
the input buffer. Inside one aggregate device those agree, but treating that as
a guarantee turns any disagreement into a read past the end of the tap buffer
on the audio thread. It now renders `min(inputFrames, outputFrames)` and
silences the remainder.

None of that is a substitute for building it. There will be more.

## What you need to do

```sh
make verify
```

That builds with warnings as errors, runs the unit tests, assembles and signs
the bundle, and checks the usage description survived into the compiled plist.
Expect to fix some compile errors on the first pass — nobody writes this much
Swift blind without any.

Then the part no machine can do:

```sh
make list
make spike APP_NAME="Music"
```

and listen. Then work `docs/ACCEPTANCE.md` top to bottom.

## Screenshots

`screenshots/` is empty, deliberately. Producing images of an interface that has
never been rendered would mean drawing mockups and presenting them as the
product — the exact failure the brief warned about. `Scripts/capture-screenshots.sh`
captures the required states (permission, multiple active apps, output picker
open, disconnected-device recovery, empty state) in both light and dark once you
have it running.

## Honest summary of confidence

| Area | Confidence | Why |
|---|---|---|
| Core Audio API usage | High | Every signature checked against Apple's docs and a reference implementation |
| Architecture and teardown ordering | High | Follows the documented contracts; the risky ordering is centralised and enumerated |
| `WaveCore` logic | High | Small, pure, and covered by ~120 assertions — which have not been run |
| Swift compiles first time | **Low** | ~4,500 lines written without a compiler |
| SwiftUI layout is pixel-right | **Low** | Never rendered; the column budget is arithmetic, not observation |
| Audio actually flows end to end | **Unverified** | This is the claim that needs your Mac |
