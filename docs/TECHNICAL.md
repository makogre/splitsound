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
| `Sources/UI/SettingsView.swift` | Settings window |
| `Sources/App/AppSettings.swift` | Preferences, login item, audio-access reporting |
| `Tests/RenderTests.swift` | Channel mapping in the realtime path, using synthetic buffers |
| `Tests/AppIdentityTests.swift` | The path rule attributing helper executables to their host app |

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

Nine things that are not in the documentation and will save you time. All of
them caused real debugging sessions during development.

**Feeding Core Audio an uninitialized *typed* buffer is undefined behaviour,
and it only bites in Release.** The property readers used to do this:

```swift
withUnsafeTemporaryAllocation(of: T.self, capacity: 1) { buffer in
    AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer.baseAddress!)
    return buffer.baseAddress!.pointee     // reading memory Swift thinks is uninitialized
}
```

Swift considers that memory never written, so the optimiser may reason the
read away. Debug builds worked perfectly; Release builds discarded every
process object and the mixer stayed empty forever — the shipped configuration
was the broken one. The fix is raw memory plus an explicit `load(as:)`, which
is the defined way to read something C wrote.

Two things about catching it are worth knowing. Unit tests do **not**: with the
bug reintroduced the whole suite stays green in Debug *and* Release, because
the test bundle is optimised differently from the app target. And running the
tests against Release at all needs `ENABLE_HARDENED_RUNTIME=NO`, since library
validation otherwise refuses to load the test bundle. What does catch it is the
smoke check in `scripts/build-release.sh`: it launches the built app and fails
the build if the app reports audio objects but zero usable ones. That guard was
verified both ways — green with the fix, red with the bug restored.

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

**The process making the sound is often not the app the user recognises.**
Two different shapes of this problem exist, and they need different answers:

*Nested helpers.* Electron apps (Discord, Teams, VS Code, Slack) ship their
audio in a helper inside the main bundle, at
`Foo.app/Contents/Frameworks/Foo Helper.app/Contents/MacOS/Foo Helper`.
`AppIdentity.outermostAppBundle(forExecutableAt:)` walks the executable path
upwards and attributes the process to the *outermost* `.app` — generically, with
no per-app list. Outermost matters: stopping at the first bundle found would
label the row "Foo Helper".

*XPC services.* Safari's audio comes from `com.apple.WebKit.GPU`, which lives in
WebKit.framework — outside Safari's bundle, so the path rule cannot find the
host. It reports itself as "Safari Graphics and Media", and every WebKit browser
shares that bundle ID. Here `AppIdentity` strips the known display-name suffix
(" Graphics and Media" and friends) and matches the remainder against running
apps. That one is a heuristic; macOS exposes no supported way to ask which app a
service is working for.

Both also fix persistence: without them, every WebKit browser would share a
single setting, so turning Safari down would turn Mail down too.

**The microphone permission is not the gate for process taps.**
`AVCaptureDevice.authorizationStatus(for: .audio)` reports `notDetermined` for
SplitSound while its taps are demonstrably delivering audio. A settings row
built on it therefore claimed "permission not yet granted" on a perfectly
working install. There appears to be no public API for the permission that
actually applies, so the settings window reports observed samples instead —
whether audio is arriving is the only signal that cannot lie.

**`proc_name` fails where `proc_pidpath` succeeds.** For several system daemons
`proc_name` returns nothing, which produced rows labelled "PID 25382". It also
truncates long names. The last path component of `proc_pidpath` is the better
source, with `proc_name` only as a fallback.

**Login items are recorded by path, not by bundle identifier.** With several
copies of the same bundle ID on disk — the installed app plus Debug and Release
build products — `SMAppService.mainApp` registered the *build product*, so the
login item would have launched a stale binary from a directory that gets wiped.
`lsregister -dump | grep SplitSound` lists the copies the system knows about and
`lsregister -u <path>` removes the unwanted ones; the BTM record itself is only
rewritten when the item is toggled off and on again (`sfltool dumpbtm` shows it).
The settings window now warns when the app runs from outside Applications, which
is also what happens when someone launches it straight from the mounted DMG.

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
- Helper attribution: Safari and Mail resolve to their own icon and their own
  persistence key, rather than sharing one WebKit entry
- Clean teardown — no orphaned aggregate devices
- Monitoring and saved volumes apply from launch, without opening the menu

Open:

- **Latency** has not been measured.
- **Notarization** for distribution is not set up.
- **Multiple simultaneous apps** work, but cost one aggregate device each (see above).
- **Other virtual audio drivers** in the system solve the same problem their own
  way. As long as such a driver is not the default output they do not interfere;
  if one is, both compete for the same signal path.
- **Level meters**: `MixerEngine.status(for:)` already reports peak levels per
  app, the interface does not display them yet.
- **Nested-helper attribution** is covered by tests but has not been exercised
  against a running Electron app end to end.
- **Launch at login** works with an ad-hoc signature: verified via
  `sfltool dumpbtm`, which shows the item enabled and pointing at
  `/Applications/SplitSound.app`. Whether it survives across rebuilds, where
  the signature changes, is untested.
