# Technische Dokumentation

Hintergrund zur Funktionsweise von SplitSound — gedacht für alle, die am Code
arbeiten wollen.

## Das Grundproblem

macOS bietet keine API, mit der sich die Lautstärke einer fremden App setzen
ließe. Es gibt keinen systemweiten Mixer und keinen Weg, einem laufenden Safari
zu sagen „sei leiser".

Der Ausweg besteht darin, den Ton abzufangen und selbst neu auszugeben:

1. **Process Tap** auf den Prozess legen (`CATapDescription`, seit macOS 14.4),
   mit `muteBehavior = .mutedWhenTapped`. Damit ist der direkte Weg der App zum
   Lautsprecher stumm, ihre Samples kommen stattdessen bei uns an.
2. **Privates Aggregate Device** aus dem echten Ausgabegerät plus diesem Tap.
3. **IOProc**: liest den Tap-Eingang, multipliziert mit dem eingestellten Gain,
   schreibt das Ergebnis aufs Ausgabegerät.

Netto hört der Nutzer nur noch unsere skalierte Kopie — also genau die
Lautstärke, die der Regler vorgibt.

Getappt wird nur, was auch geregelt werden soll. Eine App auf 100 % ohne Mute
läuft unangetastet über den schnellsten Weg; ein Tap würde dort nur Latenz und
CPU kosten.

## Aufbau

| Datei | Aufgabe |
|---|---|
| `Sources/Audio/CoreAudio+Properties.swift` | Typsicherer Wrapper um die `AudioObject*`-C-API inkl. Property-Listenern |
| `Sources/Audio/AudioProcess.swift` | Modell einer tonausgebenden App; löst Name und Icon auf |
| `Sources/Audio/AudioProcessMonitor.swift` | Verfolgt per Listener, welche Apps gerade Ton ausgeben |
| `Sources/Audio/ProcessTap.swift` | Tap + Aggregate Device + Realtime-Render für **eine** App |
| `Sources/Audio/MixerEngine.swift` | Hält die Taps im Einklang mit den Nutzereinstellungen |
| `Sources/Audio/AppVolumeStore.swift` | Lautstärke/Mute pro App, persistiert nach Bundle-ID |
| `Sources/UI/MixerView.swift` | Die Menüleisten-Oberfläche |
| `Tests/RenderTests.swift` | Kanalzuordnung im Realtime-Pfad, mit synthetischen Puffern |

### Ein Aggregate Device pro App

Bewusste Entscheidung: Jede geregelte App bekommt ein eigenes Aggregate Device
statt eines gemeinsamen. Bei einem gemeinsamen Gerät müsste man die
Eingangspuffer den Taps zuordnen, was von der Reihenfolge der Sub-Devices
abhängt und leicht still danebengeht. Pro App gibt es genau einen Eingang —
eindeutig.

Der Preis: bei vielen gleichzeitig geregelten Apps ist das verschwenderisch.
Ein gemeinsames Gerät mit mehreren Taps wäre effizienter, verlangt dann aber,
die Zuordnung sauber aus der Stream-Konfiguration abzuleiten.

## Randbedingungen

**Keine App Sandbox.** Process Taps sind unter Sandbox laut aktuellen
Entwicklerberichten unzuverlässig, und ein App-Store-Vertrieb ist damit derzeit
nicht sauber möglich. `SplitSound.entitlements` setzt `app-sandbox` bewusst auf
`false`; die Verteilung läuft notarisiert außerhalb des App Store.

**`NSAudioCaptureUsageDescription` ist Pflicht.** Ohne diesen Info.plist-Key
beendet das System die App beim ersten Tap-Versuch.

**Signierung.** TCC hängt die Audio-Berechtigung an die Signing-Identität. Mit
Ad-hoc-Signatur (`-`) ändert sich diese bei jedem Build, die Berechtigung kann
also immer wieder neu abgefragt werden. Für ruhiges Arbeiten in Xcode ein Team
hinterlegen; ein kostenloser Apple-ID-Account genügt.

## Fallstricke

Vier Dinge, die nicht in der Dokumentation stehen und beim Weiterbauen Zeit
sparen. Alle vier haben in der Entwicklung echte Fehlersuchen verursacht.

**Fehlende Aufnahmeberechtigung sieht aus wie ein kaputter Tap.** Ohne
erteilte TCC-Erlaubnis liefert Core Audio *Stille statt eines Fehlers*:
`AudioHardwareCreateProcessTap` meldet Erfolg, der IOProc läuft mit korrekt
geformten Puffern, und trotzdem sind alle Samples null. Wer von der
Kommandozeile aus testet, braucht die Berechtigung für das **Terminal**, nicht
für die getestete App.

**Ein Tap auf einen toten Prozess liefert ebenfalls Stille, ohne Fehler.**
Beim Testen mit wiederholt neu gestarteten Playern zeigt der Tap auf einen
längst beendeten Prozess. Erste Diagnose bei „kein Ton" sollte deshalb immer
`ProcessTap.peakLevel` und `renderCount` sein, bevor man die Tap-Konfiguration
verdächtigt.

**Safaris Ton kommt nicht aus Safari.** Er stammt vom WebKit-Hilfsprozess
`com.apple.WebKit.GPU` und erscheint als „Safari Graphics and Media". Alle
WebKit-Apps teilen sich diese Bundle-ID — die Persistenz in `AppVolumeStore`
kann sie deshalb nicht auseinanderhalten.

**Core Audio vergibt Prozess-Objekt-IDs wieder.** Dieselbe ID stand im Test
nacheinander für mehrere verschiedene Prozesse. `MixerEngine` legt deshalb die
PID daneben und verwirft einen Tap, wenn sie nicht mehr passt.

## Stand

Verifiziert:

- Live-Erkennung tonausgebender Apps inklusive Kommandozeilen-Prozesse
- Hörbar wirksame Lautstärkeregelung pro App über die volle Kette
  (gemessen: Tap liefert exakt die Quellamplitude, 0.24997 bei 0.25)
- Gerätewechsel zur Laufzeit — die Kette läuft über den Wechsel hinweg weiter
- Kanalzuordnung stereo/mono/mehrkanalig, durch Tests abgedeckt
- Sauberes Aufräumen — keine verwaisten Aggregate Devices

Offen:

- **Latenz** wurde nicht gemessen.
- **Notarisierung** für die Weitergabe ist nicht eingerichtet.
- **Mehrere Apps gleichzeitig** funktionieren, kosten aber je ein Aggregate
  Device (siehe oben).
- **Andere virtuelle Audiotreiber** im System lösen dieselbe Aufgabe auf
  eigenem Weg. Solange so ein Treiber nicht als Standardausgabe gesetzt ist,
  stört er nicht — ist er es doch, konkurrieren beide um denselben Signalweg.
- **Pegelanzeige**: `MixerEngine.status(for:)` liefert bereits Spitzenpegel je
  App, die Oberfläche zeigt sie noch nicht an.
- Systemtöne erscheinen als `systemsoundserverd`; ein sprechender Name wie
  „Systemtöne" wäre freundlicher.
