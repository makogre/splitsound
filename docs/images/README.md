# Bilder für die Dokumentation

| Datei | Inhalt |
|---|---|
| `mixer.png` | Der geöffnete Mixer in der Menüleiste |
| `zeile.png` | Nahaufnahme einer einzelnen Kanalzeile |

## Neu aufnehmen

Beide Bilder sind Ausschnitte aus einer Vollbildaufnahme. Menü öffnen, dann aus
einem zweiten Terminal heraus mit Verzögerung aufnehmen, damit das Menü nicht
durch den Klick geschlossen wird:

```sh
sleep 10 && screencapture -x /tmp/shot.png
```

Anschließend den Bereich des Menüs zuschneiden. Die Bilder sind in doppelter
Auflösung abgelegt (ca. 690 px breit) und werden im README auf 360 px
dargestellt — so bleiben sie auf Retina-Displays scharf.
