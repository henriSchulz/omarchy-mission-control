# Mission Control — Agent-Regeln

Animationen in diesem Plugin folgen ausschließlich `docs/ANIMATION-SPEC.md`.
Die Tokens daraus stehen in `Motion.qml` (Singleton, per `qmldir` registriert)
und werden überall importiert; keine Dauer, Kurve oder Distanz steht sonst
irgendwo als Zahl. Henris zentrale henri-ui-Bibliothek gilt hier bewusst
**nicht** — nichts daraus importieren oder übernehmen.

Reduced Motion: folgt dem systemweiten Schalter (System Settings › Bedienungshilfen ›
Bewegung reduzieren = `var reduceMotion = true` in `~/.local/share/henri-ui/Prefs.js`;
`Motion.qml` liest die Datei per `FileView` als Text — das ist kein henri-ui-Import).
Zusätzlich `MC_REDUCED_MOTION=1` (an) bzw. `=0` (aus, übersteuert) in der Umgebung der Shell — auf Omarchy per
`hl.env("MC_REDUCED_MOTION", "1")` in `~/.config/hypr/looknfeel.lua` (Session neu
starten; `omarchy-restart-shell` reicht Variablen nicht durch). Zum Testen ohne
Session-Neustart: `MC_REDUCED_MOTION=1 tests/harness.sh start`.

Testen, ohne den Bildschirm anzufassen: `tests/harness.sh` (siehe README,
„Testing without touching the screen"). Plugin-Änderungen brauchen
`omarchy restart shell`; die Mount-Zeile im Journal nennt den Build.

## Regeln für KI-Agenten und Abnahme

Dieser Abschnitt gehört wörtlich in `CLAUDE.md` bzw. die Agent-Instruktionen des Repos. Agenten scheitern meist nicht an der Technik, sondern daran, dass sie zu viel, zu lang und zu frei animieren.

**Harte Regeln für Agenten:**

1. Nur Werte aus den Motion-Tokens verwenden. Keine neuen Dauern, Kurven oder Distanzen erfinden. Fehlt ein Token, nachfragen statt raten.
2. Nur `transform` und `opacity` animieren. `transition: all` ist verboten.
3. Keine Bounce-, Elastic-, Back- oder Overshoot-Kurven, keine unterdämpften Springs.
4. Pro Änderung nur eine Komponente animieren. Nicht „nebenbei" weitere Elemente animieren.
5. Vor dem Hinzufügen einer Animation prüfen, ob die Komponente in der Tabelle „Muster pro Komponente" steht, und exakt dieses Muster übernehmen.
6. Bestehende, doppelte Animationen entfernen (z. B. Hyprland-Layer-Animation plus interne Animation), statt eine dritte hinzuzufügen.
7. Keine Animation darf Tastatureingaben verzögern oder blockieren.
8. Reduced-Motion-Pfad bei jeder neuen Animation mitliefern.
9. Nach jeder Änderung die Abnahme-Checkliste durchgehen und das Ergebnis im Commit bzw. in der Antwort auflisten.

**Abnahme-Checkliste:**

- [ ] Alle Dauern und Kurven stammen aus den Tokens
- [ ] Keine Animation länger als 300 ms, gesamte Welle unter 400 ms
- [ ] Nur `transform` und `opacity` animiert
- [ ] Schließen ist schneller als Öffnen
- [ ] Overview 10× schnell hintereinander öffnen/schließen: kein Flackern, kein Stapeln, kein Zurückspringen
- [ ] Pfeiltaste gedrückt halten: Fokus folgt ohne Verzögerung
- [ ] Keine doppelte Animation durch Hyprland und App gleichzeitig
- [ ] Stagger maximal 120 ms, Reihenfolge = Lesereihenfolge
- [ ] Reduced-Motion-Schalter getestet
- [ ] Flüssig auf dem langsamsten Monitor/GPU im Setup (keine sichtbaren Ruckler)

Wenn eine Animation die Checkliste nicht besteht, wird sie entfernt statt nachgebessert. Keine Animation ist besser als eine unsaubere.
