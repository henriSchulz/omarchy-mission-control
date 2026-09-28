# Animation Spec – Mission Control (Omarchy)

Sep 26, 2026 · @AVA

## Grundprinzipien

Animationen in Mission Control sind kurz, gedämpft und funktional: Sie zeigen, woher etwas kommt und wohin es geht, und sind danach sofort weg. Alles, was nach „Effekt“ aussieht, ist falsch.

1. **Zweck vor Dekoration.** Jede Animation beantwortet eine Frage: Was ist neu? Was ist ausgewählt? Wohin ist das Fenster verschwunden? Ohne Antwort wird nicht animiert.
2. **Schnell.** Nichts im Interface dauert länger als 300 ms. Die meisten Übergänge liegen bei 120–220 ms. Omarchy ist ein Keyboard-first-Setup, Animationen dürfen den Nutzer nie ausbremsen.
3. **Ruhig.** Keine Bounce-, Elastic- oder Overshoot-Kurven. Kleine Distanzen (4–16 px), kleine Skalierungen (0.96–1.0).
4. **Konsistent.** Nur die Tokens aus Abschnitt „Motion-Tokens“ verwenden. Keine frei erfundenen Dauern oder Kurven pro Komponente.
5. **Flüssig.** Nur `transform` und `opacity` animieren. Ziel sind stabile 60 fps (bzw. die Bildwiederholrate des Monitors) ohne Layout-Neuberechnung.
6. **Unterbrechbar.** Jede Animation muss jederzeit von einer neuen Eingabe abgelöst werden können, ohne Sprung oder Flackern.
7. **Asymmetrisch.** Rein etwas langsamer als raus. Schließen fühlt sich sofort an.

## Motion-Tokens

Es gibt genau fünf Dauern, drei Kurven und drei Distanzen. Alles andere ist verboten.

| Token | Dauer (ms) | Einsatz |
| --- | --- | --- |
| `duration-instant` | 80 | Hover, Pressed-State, Farbwechsel |
| `duration-fast` | 140 | Fokuswechsel, Tooltips, kleine Elemente ein/aus, Schließen |
| `duration-base` | 200 | Kacheln, Panels, Listeneinträge einblenden |
| `duration-slow` | 260 | Mission-Control-Overview öffnen, große Flächen |
| `duration-stagger` | 20 | Versatz pro Element in Listen/Grids |

| Token | cubic-bezier | Einsatz |
| --- | --- | --- |
| `ease-out` | 0.23, 1, 0.32, 1 | Standard für alles, was erscheint oder sich bewegt (easeOutQuint) |
| `ease-in` | 0.4, 0, 1, 1 | Nur für Elemente, die verschwinden |
| `ease-in-out` | 0.65, 0, 0.35, 1 | Nur für Elemente, die auf dem Bildschirm von A nach B wandern |

| Token | Wert | Einsatz |
| --- | --- | --- |
| `distance-sm` | 4 px | Hover-Lift, Fokus |
| `distance-md` | 8 px | Einblenden von Kacheln und Listeneinträgen |
| `distance-lg` | 16 px | Panels, Overview-Einstieg |
| `scale-enter` | 0.96 → 1.0 | Overview, Popups |
| `scale-hover` | 1.0 → 1.02 | Kachel-Hover (Maximum) |

Faustregeln: Schließen nutzt `duration-fast` + `ease-in`. Linear ist nur für Spinner und Fortschrittsbalken erlaubt. Springs sind nur erlaubt, wenn sie kritisch gedämpft sind (kein Überschwingen).

## Erlaubte Eigenschaften und Verbote

Animiert werden ausschließlich `transform` (translate, scale) und `opacity`. Farbe und Rahmen dürfen nur mit `duration-instant` wechseln.

| Erlaubt | Verboten | Warum |
| --- | --- | --- |
| `transform: translate` | `top`, `left`, `margin` | Layout-Neuberechnung, Ruckeln |
| `transform: scale` | `width`, `height`, `padding` | Text springt, Nachbarn verschieben sich |
| `opacity` | `display` / `visibility` ohne Opacity-Übergang | harter Sprung |
| `background-color`, `border-color` (80 ms) | `box-shadow` animieren | teuer; stattdessen Schatten-Pseudoelement per Opacity einblenden |
| — | `filter: blur()` animieren | teuer, auf Wayland/GTK oft ruckelig |
| — | `transition: all` | animiert ungewollt Layout-Eigenschaften |
| — | Rotation, Bounce, Shake, Pulsieren | wirkt verspielt, nicht clean |
| — | Endlos-Animationen (außer Ladeindikator) | lenkt ab, kostet CPU |

Zusätzlich gilt:

- Höhe von aufklappenden Bereichen nie animieren. Stattdessen Inhalt per Opacity + `translateY(-4px)` einblenden, Höhe springt sofort.
- Text wird nie skaliert, nur verschoben und eingeblendet.
- Maximal zwei Eigenschaften gleichzeitig pro Element (z. B. Opacity + Translate).

## Muster pro Komponente

Jede Komponente hat genau ein festgelegtes Rein- und Raus-Verhalten. Agenten übernehmen diese Tabelle 1:1.

| Komponente | Rein (von → nach) | Raus (von → nach) | Dauer rein / raus | Kurve rein / raus |
| --- | --- | --- | --- | --- |
| Overview-Hintergrund (Dim/Backdrop) | opacity 0 → 1 | 1 → 0 | 200 / 140 | ease-out / ease-in |
| Overview-Container | opacity 0 → 1, scale 0.96 → 1 | opacity 1 → 0, scale 1 → 0.98 | 260 / 140 | ease-out / ease-in |
| Kacheln (Fenster, Workspaces, Widgets) | opacity 0 → 1, translateY 8 px → 0 | opacity 1 → 0 (ohne Bewegung) | 200 / 140 | ease-out / ease-in |
| Kachel-Hover | scale 1 → 1.02, translateY 0 → −2 px | zurück | 80 / 80 | ease-out |
| Fokus-Ring (Tastatur-Auswahl) | opacity 0 → 1, Ring-Rahmen gleitet per translate zur neuen Kachel | — | 140 | ease-in-out |
| Seitenpanel | opacity 0 → 1, translateX 16 px → 0 | opacity 1 → 0, translateX 0 → 8 px | 200 / 140 | ease-out / ease-in |
| Listeneintrag neu | opacity 0 → 1, translateY 4 px → 0 | opacity 1 → 0 | 200 / 140 | ease-out / ease-in |
| Toast / Notification | opacity 0 → 1, translateY −8 px → 0 | opacity 1 → 0 | 200 / 140 | ease-out / ease-in |
| Tooltip | opacity 0 → 1 (nach 400 ms Verzögerung) | opacity 1 → 0 | 140 / 80 | ease-out / ease-in |
| Zahlen / Statuswerte | Crossfade alter/neuer Wert | — | 140 | ease-out |
| Tab-/Ansichtswechsel | Crossfade, neuer Inhalt translateX 8 px → 0 in Richtung der Navigation | alter Inhalt opacity 1 → 0 | 200 / 140 | ease-out / ease-in |

Sonderfälle:

- **Fenster-Kachel zu echtem Fenster** (Enter in der Overview): Die Kachel skaliert per `transform` in Richtung Fensterposition, gleichzeitig blendet die Overview aus. Dauer 200 ms, `ease-in-out`. Kein Nachbauen des Fensters in voller Größe.
- **Drag & Drop:** Gezogenes Element folgt der Maus ohne Verzögerung (keine Transition während des Ziehens). Beim Loslassen gleitet es in 140 ms `ease-out` an den Zielplatz.
- **Ladezustand:** Skeleton mit statischer Farbe oder ein einzelner Spinner. Kein Shimmer-Effekt.

## Choreografie

Eine Aktion löst höchstens eine sichtbare Animationswelle aus, und die ist nach spätestens 400 ms komplett fertig.

**Reihenfolge beim Öffnen der Overview:** Backdrop und Container starten gleichzeitig (t = 0). Die Kacheln starten bei t = 40 ms mit 20 ms Versatz pro Kachel. Der Fokus-Ring erscheint zusammen mit der ersten Kachel.

**Stagger-Regeln:**

- Versatz 20 ms pro Element, Gesamtversatz maximal 120 ms. Ab dem 7. Element starten alle übrigen gleichzeitig.
- Reihenfolge = Lesereihenfolge (links oben nach rechts unten), nie zufällig.
- Beim Schließen kein Stagger: alles blendet gemeinsam aus.

**Richtung:** Bewegung zeigt immer die räumliche Logik. Nächster Workspace kommt von rechts, vorheriger von links. Panels kommen von der Seite, an der sie andocken. Toasts kommen von der Bildschirmkante, an der sie stehen.

**Unterbrechbarkeit:**

- Neue Eingabe während einer Animation startet vom aktuellen Zwischenwert, nie vom Anfangswert (kein Zurückspringen).
- Schnelles Öffnen/Schließen hintereinander darf keine Animationen stapeln. Laufende Animation wird abgelöst, nicht in eine Warteschlange gestellt.
- Tastatur-Navigation (Pfeiltasten, Tab) wird nie durch Animationen blockiert. Der Fokus-Zustand wechselt sofort, nur die Darstellung animiert.
- Gedrückt gehaltene Pfeiltasten: Fokus-Ring-Animation auf 80 ms verkürzen oder ganz weglassen.

**Reduzierte Bewegung:** Es gibt einen globalen Schalter (Umgebungsvariable oder Config-Flag, z. B. `MC_REDUCED_MOTION=1`). Ist er aktiv, werden alle Translate- und Scale-Anteile entfernt, es bleiben nur Opacity-Fades mit 80 ms.

## Implementierung

Die Tokens werden an genau einer Stelle definiert und überall importiert. Die folgenden Snippets sind die Referenz, je nachdem womit Mission Control gebaut ist.

### Web / Electron / Tauri (CSS)

```css
:root {
  --duration-instant: 80ms;
  --duration-fast: 140ms;
  --duration-base: 200ms;
  --duration-slow: 260ms;
  --duration-stagger: 20ms;
  --ease-out: cubic-bezier(0.23, 1, 0.32, 1);
  --ease-in: cubic-bezier(0.4, 0, 1, 1);
  --ease-in-out: cubic-bezier(0.65, 0, 0.35, 1);
}

.tile {
  transition: transform var(--duration-instant) var(--ease-out),
              opacity var(--duration-base) var(--ease-out);
}
.tile:hover { transform: translateY(-2px) scale(1.02); }

.tile[data-state="entering"] {
  animation: tile-in var(--duration-base) var(--ease-out) both;
  animation-delay: calc(min(var(--i), 6) * var(--duration-stagger) + 40ms);
}
@keyframes tile-in {
  from { opacity: 0; transform: translateY(8px); }
}

@media (prefers-reduced-motion: reduce) {
  * { animation-duration: 80ms !important; transition-duration: 80ms !important; }
  .tile, .tile:hover { transform: none !important; }
}
```

`--i` ist der Index der Kachel, per Inline-Style gesetzt. Für Unterbrechbarkeit Transitions statt Keyframes nutzen, wo ein Zustand hin und zurück wechselt (Transitions starten vom aktuellen Wert).

### Quickshell / QML

```qml
// Motion.qml (Singleton)
pragma Singleton
import QtQuick
QtObject {
  readonly property int instant: 80
  readonly property int fast: 140
  readonly property int base: 200
  readonly property int slow: 260
  readonly property list<real> easeOut: [0.23, 1, 0.32, 1, 1, 1]
  readonly property list<real> easeIn: [0.4, 0, 1, 1, 1, 1]
}

// Verwendung
Behavior on opacity {
  NumberAnimation {
    duration: Motion.base
    easing.type: Easing.BezierSpline
    easing.bezierCurve: Motion.easeOut
  }
}
```

`Behavior` statt manuell gestarteter Animationen nutzen, weil `Behavior` automatisch vom aktuellen Wert aus unterbricht. Bewegung über `transform: Translate` / `Scale` oder `x`/`y` innerhalb eines festen Containers, nie über `width`/`height` oder Anchors.

### AGS / Astal (GTK4-CSS)

```css
.tile {
  transition: opacity 200ms cubic-bezier(0.23, 1, 0.32, 1),
              transform 80ms cubic-bezier(0.23, 1, 0.32, 1);
}
.tile:hover { transform: translateY(-2px); }
```

GTK-CSS kennt keine Variablen für Dauern wie im Web. Die Werte werden daher aus einer zentralen SCSS-Datei mit `$duration-base` usw. generiert. Für Ein-/Ausblenden `Gtk.Revealer` mit `transition-type: crossfade` und `transition-duration` aus den Tokens verwenden, nicht `slide-down` (animiert Höhe).

### Hyprland (Omarchy)

Fensterwechsel und Workspaces, die Hyprland selbst animiert, auf dieselben Kurven bringen. In deiner Hyprland-Userconfig (bei Omarchy üblicherweise die Look-and-Feel-Datei unter `~/.config/hypr/`):

```ini
bezier = mcOut, 0.23, 1, 0.32, 1
bezier = mcIn, 0.4, 0, 1, 1
bezier = mcInOut, 0.65, 0, 0.35, 1

# Geschwindigkeit in Zehntelsekunden: 2 = 200 ms
animation = windowsIn, 1, 2, mcOut, popin 96%
animation = windowsOut, 1, 1.4, mcIn, popin 98%
animation = windowsMove, 1, 2, mcInOut
animation = fade, 1, 1.4, mcOut
animation = layersIn, 1, 2, mcOut, fade
animation = layersOut, 1, 1.4, mcIn, fade
animation = workspaces, 1, 2.6, mcInOut, slide
```

Wichtig: Wenn Mission Control ein eigenes Layer-Shell-Fenster ist, animiert Hyprland es beim Öffnen zusätzlich zu deiner eigenen Animation. Das erzeugt doppelte, ruckelige Übergänge. Für den Namespace von Mission Control die Layer-Animation per `layerrule` abschalten (`noanim`) und nur die interne Animation laufen lassen. Die genaue `layerrule`-Syntax hat sich in neueren Hyprland-Versionen geändert, daher gegen `hyprctl version` und das Hyprland-Wiki prüfen.

## Regeln für KI-Agenten und Abnahme

Dieser Abschnitt gehört wörtlich in `CLAUDE.md` bzw. die Agent-Instruktionen des Repos. Agenten scheitern meist nicht an der Technik, sondern daran, dass sie zu viel, zu lang und zu frei animieren.

**Harte Regeln für Agenten:**

1. Nur Werte aus den Motion-Tokens verwenden. Keine neuen Dauern, Kurven oder Distanzen erfinden. Fehlt ein Token, nachfragen statt raten.
2. Nur `transform` und `opacity` animieren. `transition: all` ist verboten.
3. Keine Bounce-, Elastic-, Back- oder Overshoot-Kurven, keine unterdämpften Springs.
4. Pro Änderung nur eine Komponente animieren. Nicht „nebenbei“ weitere Elemente animieren.
5. Vor dem Hinzufügen einer Animation prüfen, ob die Komponente in der Tabelle „Muster pro Komponente“ steht, und exakt dieses Muster übernehmen.
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
