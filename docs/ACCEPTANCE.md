# Manual acceptance checklist

Compilation and unit tests do not prove that audio was captured, attenuated and
rerouted. These steps do. They need a real Mac, real playback and a person
listening.

Work through them in order; each builds on the last. Record the result in the
table at the end.

```sh
make verify        # must pass before you start
```

---

## 0. Setup

- [ ] macOS 14.2 or newer.
- [ ] `make app` completed and **did not** warn about an ad-hoc signature.
      If it did, set `CODESIGN_IDENTITY` and rebuild — otherwise macOS will keep
      forgetting the permission between builds.
- [ ] At least two applications that can play audio (Music, Spotify, a browser
      tab, Zoom's test call).
- [ ] Ideally two output devices. If you only have one, sections 5 and 6 have a
      single-device path.

---

## 1. Permission onboarding

- [ ] Launch Wave with the permission **not yet granted**.
- [ ] The popover shows the explanation and a button. **No mixer, no faders.**
- [ ] Nothing was requested until you pressed the button.
- [ ] Press it; macOS shows its prompt, with Wave's own wording from
      `NSAudioCaptureUsageDescription`.
- [ ] **Deny it.** Wave switches to the denied state and spells out the
      System Settings path. Still no mixer.
- [ ] Grant it in System Settings, press "Check again". The mixer appears.

> Reset for a re-test: `tccutil reset AudioCapture app.wave.mixer`

## 2. The chain, proven headlessly

Start playback in one app, then:

```sh
make spike APP_NAME="Music"
```

- [ ] The pre-gain meter moves. (Flat while the app is playing = capture is
      being withheld; the spike says so explicitly.)
- [ ] The post-gain meter tracks the fader sweep.
- [ ] **You can hear the volume sweep** 100% → 25% → 100%.
- [ ] Audio is coming out of the device the spike named.
- [ ] Audio is **not** also coming out of your normal output at full volume.
- [ ] Ctrl-C. The verdict reports buffers containing audio, not "every tapped
      buffer was silent".
- [ ] Normal playback returns immediately.

## 3. Independent per-app volume — the core claim

With **two** applications playing at once:

- [ ] Both appear under "Playing now" with moving meters.
- [ ] Drag app A to 30%. **A gets quieter; B does not change.**
- [ ] Drag app B to 100% while A stays at 30%. Both hold their own level.
- [ ] Set A to 0%. A is silent, B is unaffected.
- [ ] Mute B. B is silent, A is still at 0%.
- [ ] Unmute B. It returns to its previous level.
- [ ] No click or pop on any of the above — that is what the ramp is for.
- [ ] Drag a fader rapidly back and forth for a few seconds. No crackle, no
      dropout, no stuck level.

## 4. No double audio

- [ ] While app A is routed, its audio comes out **once**, at Wave's level.
- [ ] Set A to 10%. It is quiet everywhere, not quiet in one place and loud in
      another.
- [ ] Quit Wave. A returns to full volume on its normal output immediately.

## 5. Output routing — two devices

*Skip to 5b if you only have one output.*

- [ ] Send app A to device 1 and app B to device 2.
- [ ] **A is audible only on device 1; B only on device 2.**
- [ ] Swap them. The change takes effect (a brief gap in that app's audio is
      expected and documented).
- [ ] Set A back to "System output". It follows the default device again.

### 5b. Single-device path

With one output you can still verify routing is real rather than cosmetic:

- [ ] Create an aggregate or multi-output device in **Audio MIDI Setup**
      (`open -a "Audio MIDI Setup"` → + → Create Multi-Output Device) so a
      second destination exists.
- [ ] It appears in Wave's output picker within a second of being created.
- [ ] Route one app to it; confirm audio follows.
- [ ] Delete it in Audio MIDI Setup while the app is routed there, and continue
      to section 6 — this is a genuine hot-unplug.

## 6. Hot-plug and recovery

- [ ] With an app routed to a removable device (AirPods, USB interface, or the
      multi-output from 5b), **disconnect it while audio is playing**.
- [ ] Audio keeps playing, on the current default output.
- [ ] The row says the saved device disconnected and names what it fell back to.
- [ ] Other applications are unaffected — no glitch, no restart.
- [ ] Reconnect the device. Within a second the app returns to it and the
      warning clears.
- [ ] `~/Library/Application Support/Wave/rules.json` still names the original
      device. The fallback must not have rewritten your choice.
- [ ] Change the system default output in Sound settings. Apps set to
      "System output" follow; apps pinned to a device do not move.

## 7. Persistence

- [ ] Set distinct volumes and devices for two applications.
- [ ] Quit those applications. They move to "Recent and saved" with settings
      intact.
- [ ] Relaunch one and play audio. **Its saved rule is reapplied automatically.**
- [ ] Quit Wave, relaunch it. All rules survive.
- [ ] Reboot. All rules survive.
- [ ] Right-click a row → Forget. The application returns to normal untouched
      playback and the rule is gone from the JSON.

## 8. Helper-process grouping

- [ ] Play audio in a Chrome or Edge tab. It appears as **one** row named after
      the browser, not several helper rows.
- [ ] Open a second audio tab. Still one row; the volume applies to both.
- [ ] Play audio in an Electron app (Slack, Discord, VS Code). One row, named
      after the app.
- [ ] Play a system sound (e.g. set volume to 0 and press volume-down). A
      "System sounds" row appears.

## 9. Cleanup and safety

- [ ] Quit Wave from its menu while three applications are routed. All three
      return to normal instantly.
- [ ] Relaunch. No stray aggregate devices in **Audio MIDI Setup**.
- [ ] Force quit Wave (`killall -9 wave`) while routing. Audio returns anyway —
      the source mute is a property of the tap, so macOS releases it with the
      process.
- [ ] `make list` shows no leftover "Wave Route" devices.

## 10. Interface

Check in **both light and dark**, and with **Increase Contrast** on:

- [ ] Popover reads well at its 420 pt width. Nothing clipped, nothing wrapped
      awkwardly.
- [ ] Long application names truncate; long device names truncate. Neither
      pushes the fader or percentage out of its column.
- [ ] The output picker, mute button, fader and percentage line up in straight
      columns down the whole list.
- [ ] Meters are legible at low level, not just when loud.
- [ ] The empty state ("Nothing is playing") is a sentence, not a blank panel.
- [ ] The disconnected-device state is obvious at a glance.

Accessibility:

- [ ] Tab moves through every control in a sensible order; Space and the arrow
      keys operate them.
- [ ] VoiceOver announces each row's app name, its volume as a percentage, its
      mute state and its output device.
- [ ] With **Reduce Motion** on, the meters update slowly instead of at 30 Hz
      and nothing flickers.

## 11. Behaviour over time

- [ ] Leave Wave routing two applications for 30 minutes. No drift, no
      accumulating latency, no dropouts.
- [ ] CPU in Activity Monitor stays low (single digits) with a few routes.
- [ ] Memory is flat — no growth from the meter or diagnostics ring buffer.
- [ ] Sleep the Mac and wake it. Routes recover or report why they did not.

## 12. Launch at login

- [ ] Enable it from the menu. `System Settings ▸ General ▸ Login Items` lists
      Wave.
- [ ] Log out and back in. Wave starts, in the menu bar, with rules intact.
- [ ] Disable it. It disappears from Login Items.

---

## Result

| Section | Pass / Fail | Notes |
|---|---|---|
| 1 Permission onboarding | | |
| 2 Chain proven headlessly | | |
| 3 Independent per-app volume | | |
| 4 No double audio | | |
| 5 Output routing | | |
| 6 Hot-plug and recovery | | |
| 7 Persistence | | |
| 8 Helper grouping | | |
| 9 Cleanup and safety | | |
| 10 Interface | | |
| 11 Behaviour over time | | |
| 12 Launch at login | | |

Tester: ________________  macOS: ________  Date: ________
Devices used: ______________________________________________
