# Technical notes

Background on how SplitSound works, for anyone wanting to work on the code.

## The core problem

macOS offers no API for setting another app's volume. There is no system-wide
mixer, and no way to tell a running Safari to be quieter.

The way around it is to intercept the audio and emit it again yourself:

1. **Process tap** on the process (`CATapDescription`, macOS 14.4+), with
   `muteBehavior = .mutedWhenTapped`. That kills the app's direct path to the
   speakers; its samples arrive on our input instead.
2. **Private aggregate device** built from the real output device plus that tap.
3. **IOProc** reads the tap input, multiplies by the configured gain, and writes
   the result to the output device.

The net effect is that the user only hears our scaled copy — that is, exactly
the volume the slider dictates.

Only apps that need adjusting are tapped. An app at 100 % without mute keeps its
untouched, lowest-latency path; a tap there would only cost latency and CPU.

## Layout

| File | Responsibility |
|---|---|
| `Sources/Audio/CoreAudio+Properties.swift` | Type-safe wrapper around the `AudioObject*` C API, including property listeners |
| `Sources/Audio/AudioProcess.swift` | Model of an audio-producing app; resolves name and icon |
| `Sources/Audio/AudioProcessMonitor.swift` | Tracks which apps are producing audio, via listeners |
| `Sources/Audio/ProcessTap.swift` | Tap + aggregate device + realtime render for **one** app |
| `Sources/Audio/MixerEngine.swift` | Keeps taps in sync with user settings |
| `Sources/Audio/AppVolumeStore.swift` | Volume/mute per app, persisted by bundle ID |
| `Sources/UI/MixerView.swift` | The menu bar interface |
| `Tests/RenderTests.swift` | Channel mapping in the realtime path, using synthetic buffers |

### One aggregate device per app

A deliberate choice: each adjusted app gets its own aggregate device rather than
sharing one. With a shared device you would have to map input buffers to taps,
which depends on sub-device ordering and fails silently when it is wrong. Per
app there is exactly one input — unambiguous.

The cost: with many apps adjusted simultaneously this is wasteful. A shared
device with multiple taps would be more efficient, but then the mapping has to
be derived properly from the stream configuration.

## Constraints

**No App Sandbox.** Process taps are unreliable under the sandbox according to
current developer reports, which also rules out clean App Store distribution.
`SplitSound.entitlements` deliberately sets `app-sandbox` to `false`;
distribution is notarized, outside the App Store.

**`NSAudioCaptureUsageDescription` is mandatory.** Without that Info.plist key
the system terminates the app on its first tap attempt.

**Signing.** TCC ties the audio permission to the signing identity. With an
ad-hoc signature (`-`) that identity changes on every build, so the permission
may be requested again and again. For comfortable work in Xcode, set a team;
a free Apple ID account is enough.

## Pitfalls

Five things that are not in the documentation and will save you time. All of
them caused real debugging sessions during development.

**A missing recording permission looks exactly like a broken tap.** Without TCC
approval, Core Audio delivers *silence instead of an error*:
`AudioHardwareCreateProcessTap` reports success, the IOProc runs with correctly
shaped buffers, and every sample is still zero. When testing from the command
line, the permission is needed for **Terminal**, not for the app under test.

**A tap on a dead process also delivers silence, without an error.** When
testing with repeatedly restarted players, the tap points at a long-terminated
process. So the first diagnosis for "no sound" should always be
`ProcessTap.peakLevel` and `renderCount`, before suspecting the tap
configuration.

**Safari's audio does not come from Safari.** It comes from the WebKit helper
`com.apple.WebKit.GPU`, which reports itself as "Safari Graphics and Media".
Every WebKit browser shares that bundle ID. `AppIdentity` therefore maps known
helper bundle IDs back to their host app by stripping the display-name suffix
(" Graphics and Media" and friends) and matching the remainder against running
applications. That is a heuristic — macOS exposes no supported way to ask which
app a helper is working for — and it also fixes persistence, which would
otherwise store one shared setting for all WebKit browsers.

**Core Audio reuses process object IDs.** During testing the same ID stood for
several different processes in succession. `MixerEngine` therefore keeps the PID
alongside and discards a tap once it no longer matches.

**Channel counts do not always match.** The tap is always stereo, the output
device may not be. Mapping straight through would write silence on a mono or
multichannel device. `ProcessTap.render` mixes down when the output has fewer
channels and repeats cyclically when it has more; `RenderTests` covers both.

## Status

Verified:

- Live detection of audio-producing apps, including command line processes
- Audibly effective per-app volume control across the whole chain
  (measured: the tap delivers exactly the source amplitude, 0.24997 for 0.25)
- Output device switching at runtime — the chain survives the switch
- Channel mapping for stereo/mono/multichannel, covered by tests
- Clean teardown — no orphaned aggregate devices

Open:

- **Latency** has not been measured.
- **Notarization** for distribution is not set up.
- **Multiple simultaneous apps** work, but cost one aggregate device each (see above).
- **Other virtual audio drivers** in the system solve the same problem their own
  way. As long as such a driver is not the default output they do not interfere;
  if one is, both compete for the same signal path.
- **Level meters**: `MixerEngine.status(for:)` already reports peak levels per
  app, the interface does not display them yet.
- System sounds appear as `systemsoundserverd`; a friendlier name would help.
