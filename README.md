# SplitSound

Ein Lautstärkemixer für die macOS-Menüleiste — wie der Lautstärkemixer unter
Windows. Regelt den Ton einzelner Apps (Safari, FaceTime, Spotify …) getrennt
voneinander.

## Wie es funktioniert

macOS hat keinen Mixer und keine API, mit der man die Lautstärke einer fremden
App direkt setzen könnte. Der Trick besteht darin, den Ton abzufangen und
selbst neu auszugeben:

1. **Process Tap** auf den Prozess legen (`CATapDescription`, seit macOS 14.4),
   mit `muteBehavior = .mutedWhenTapped`. Damit ist der direkte Weg der App zum
   Lautsprecher stumm, ihre Samples kommen stattdessen bei uns an.
2. **Privates Aggregate Device** aus dem echten Ausgabegerät plus diesem Tap.
3. **IOProc**: liest den Tap-Eingang, multipliziert mit dem eingestellten Gain,
   schreibt das Ergebnis aufs Ausgabegerät.

Netto hört der Nutzer nur noch unsere skalierte Kopie — also genau die
Lautstärke, die der Slider vorgibt.

Getappt wird nur, was auch geregelt werden soll. Eine App auf 100 % ohne Mute
läuft unangetastet über den schnellsten Weg; ein Tap würde dort nur Latenz und
CPU kosten.

### Aufbau

| Datei | Aufgabe |
|---|---|
| `Sources/Audio/CoreAudio+Properties.swift` | Typsicherer Wrapper um die `AudioObject*`-C-API inkl. Property-Listenern |
| `Sources/Audio/AudioProcess.swift` | Modell einer tonausgebenden App; löst Name und Icon auf |
| `Sources/Audio/AudioProcessMonitor.swift` | Verfolgt per Listener, welche Apps gerade Ton ausgeben |
| `Sources/Audio/ProcessTap.swift` | Tap + Aggregate Device + Realtime-Render für **eine** App |
| `Sources/Audio/MixerEngine.swift` | Hält die Taps im Einklang mit den Nutzereinstellungen |
| `Sources/Audio/AppVolumeStore.swift` | Lautstärke/Mute pro App, persistiert nach Bundle-ID |
| `Sources/UI/MixerView.swift` | Die Menüleisten-Oberfläche |

## Bauen und starten

```sh
xcodegen generate                     # erzeugt SplitSound.xcodeproj aus project.yml
open SplitSound.xcodeproj             # dort Signing-Team setzen, dann Run
```

Oder von der Kommandozeile:

```sh
xcodebuild -project SplitSound.xcodeproj -scheme SplitSound \
  -configuration Debug -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" build
open build/Build/Products/Debug/SplitSound.app
```

Die App ist eine reine Menüleisten-App (`LSUIElement`), es erscheint also kein
Fenster und kein Dock-Symbol — nur das Schieberegler-Symbol oben rechts.

### Release und DMG

```sh
./scripts/build-release.sh                    # -> dist/SplitSound-<version>.dmg
```

Standardmäßig ad-hoc signiert; auf fremden Rechnern blockiert Gatekeeper die App
dann (Abhilfe: Rechtsklick → Öffnen). Mit Developer-ID-Zertifikat:

```sh
SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./scripts/build-release.sh
```

## Wichtige Randbedingungen

**Keine App Sandbox.** Process Taps sind unter Sandbox laut aktuellen
Entwicklerberichten unzuverlässig, und ein App-Store-Vertrieb ist damit derzeit
nicht sauber möglich. `SplitSound.entitlements` setzt `app-sandbox` bewusst auf
`false`; die Verteilung läuft notarisiert außerhalb des App Store.

**`NSAudioCaptureUsageDescription` ist Pflicht.** Ohne diesen Info.plist-Key
beendet das System die App beim ersten Tap-Versuch.

**Signierung.** TCC hängt die Audio-Berechtigung an die Signing-Identität. Mit
Ad-hoc-Signatur (`-`) ändert sich diese bei jedem Build, die Berechtigung kann
also immer wieder neu abgefragt werden. Für ruhiges Arbeiten in Xcode ein
Team hinterlegen (ein kostenloser Apple-ID-Account genügt).

## Erkenntnisse aus der Entwicklung

Drei Dinge, die nicht in der Dokumentation stehen und beim Weiterbauen Zeit sparen:

- **Safaris Ton kommt nicht aus Safari.** Er stammt vom WebKit-Hilfsprozess
  `com.apple.WebKit.GPU` und erscheint als „Safari Graphics and Media". Alle
  WebKit-Apps teilen sich diese Bundle-ID — die Persistenz in
  `AppVolumeStore` kann sie deshalb nicht auseinanderhalten.
- **Core Audio vergibt Prozess-Objekt-IDs wieder.** Dieselbe ID stand im Test
  nacheinander für mehrere verschiedene Prozesse. `MixerEngine` legt deshalb
  die PID daneben und verwirft einen Tap, wenn sie nicht mehr passt.
- **Ein Tap auf einen toten Prozess liefert Stille, keinen Fehler.** Beim
  Testen war das die Ursache scheinbar kaputter Taps: `activate()` meldete
  Erfolg, der Callback lief mit korrekt geformten Puffern, und trotzdem kam
  nichts an — der getappte Prozess war zwischenzeitlich beendet worden. Wer
  hier debuggt, sollte zuerst `ProcessTap.peakLevel` und `renderCount` prüfen,
  bevor er die Tap-Konfiguration verdächtigt.

## Stand und offene Punkte

Verifiziert:

- Live-Erkennung tonausgebender Apps inklusive Kommandozeilen-Prozesse
- Hörbar wirksame Lautstärkeregelung pro App über die volle Kette
- Sauberes Aufräumen — keine verwaisten Aggregate Devices

Noch offen:

- **Gerätewechsel** (Kopfhörer ein-/ausstecken): `MixerEngine.rebuildAll()`
  ist implementiert, aber nicht getestet.
- **Mehrere Apps gleichzeitig geregelt**: jede bekommt derzeit ein eigenes
  Aggregate Device. Funktioniert, ist bei vielen Apps aber verschwenderisch —
  ein gemeinsames Gerät mit mehreren Taps wäre effizienter. Dann muss die
  Zuordnung der Eingangspuffer zu den Taps sorgfältig aus der
  Stream-Konfiguration abgeleitet werden, statt sich auf die Reihenfolge zu
  verlassen.
- **Latenz** wurde nicht gemessen.
- **Notarisierung** für die Weitergabe ist nicht eingerichtet.
- **Andere virtuelle Audiotreiber** im System lösen dieselbe Aufgabe auf
  eigenem Weg. Solange so ein Treiber nicht als Standardausgabe gesetzt ist,
  stört er nicht — ist er es doch, konkurrieren beide um denselben Signalweg.
- Systemtöne erscheinen als `systemsoundserverd`; ein sprechender Name wie
  „Systemtöne" wäre freundlicher.

## Lizenz

[MIT](LICENSE)
